#!/usr/bin/perl -w

package File::Cache;

use strict;
use Carp;
use Storable qw(freeze thaw dclone);
use Digest::MD5  qw(md5_hex);
use File::Path;
use File::Find;
use vars qw($VERSION);


$VERSION = '0.05';

my $sEXPIRES_NOW = 0;
my $sEXPIRES_NEVER = -1;
my $sSUCCESS = 1;
my $sFAILURE = 0;
my $sTRUE = 1;
my $sFALSE = 0;


# The default cache key is used to address the temp filesystem

my $sDEFAULT_CACHE_KEY = '/tmp/File::Cache';


# if a namespace is not specified, use this as a default

my $sDEFAULT_NAMESPACE = "_default";



# create a new Cache object that can be used to persist
# data across processes

sub new 
{
    my ($proto, $options) = @_;
    my $class = ref($proto) || $proto;
    my $self  = {};
    bless ($self, $class);


    # this instance will use the namespace specified or the default

    my $namespace = $options->{namespace} || $sDEFAULT_NAMESPACE;

    $self->{_namespace} = $namespace;


    # remember the expiration delta to be used for all objects if specified

    $self->{_expires_in} = $options->{expires_in} || $sEXPIRES_NEVER;


    # verify that the cache space exists

    my $cache_key = $options->{cache_key} || $sDEFAULT_CACHE_KEY;

    _verify_directory($cache_key, 0000) or
	croak("Couldn't verify directory $cache_key");

    $self->{_cache_key} = $cache_key;


    # create a path for this particular user, and verify that it exists

    my $username = _get_username();

    my $cache_path = _build_path($cache_key, $username);

    _verify_directory($cache_path) or
	croak("Couldn't verify directory $cache_path");

    $self->{_cache_path} = $cache_path;



    # create a path for this namespace, and verify that it exists

    my $namespace_path = _build_path($cache_path, $namespace) or
	croak("Couldn't build namespace path");

    _verify_directory($namespace_path) or
	croak("Couldn't verify directory $cache_path");

    $self->{_namespace_path} = $namespace_path;
    

    return $self;
}



# store an object in the cache associated with the identifier

sub set 
{
    my ($self, $identifier, $object, $expires_in) = @_;

    $identifier or
	croak("identifier required");

    $identifier = md5_hex($identifier);

    my $namespace_path = $self->{_namespace_path} or
	croak("namespace path required");

    _verify_directory($namespace_path) or
	croak("Couldn't verify directory $namespace_path");

    my $file_path = _build_path($namespace_path, $identifier);

    # expiration time is based on a delta from the current time
    # if expires_in is defined, the object will expire in that number of seconds from now
    #  else if expires_in is undefined, it will expire based on the global _expires_in
    
    my $expires_at;

    if (defined $expires_in) {
	$expires_at = time() + $expires_in;
    } elsif ($self->{_expires_in} ne $sEXPIRES_NEVER) {
	$expires_at = time() + $self->{_expires_in};
    } else {
	$expires_at = $sEXPIRES_NEVER;
    }


    # add the new object to the cache in this instance's namespace

    my %object_data = ( object => $object, expires_at => $expires_at );
    
    my $frozen_object_data = freeze(\%object_data);

    _write_file($file_path, \$frozen_object_data);


    return $sSUCCESS;
}



# retrieve an object from the cache associated with the identifier

sub get 
{
    my ($self, $identifier) = @_;

    $identifier or
	croak("identifier required");

    $identifier = md5_hex($identifier);

    my $namespace_path = $self->{_namespace_path} or
	croak("namespace path required");

    _verify_directory($namespace_path) or
	croak("Couldn't verify directory $namespace_path");

    my $file_path = _build_path($namespace_path, $identifier);

    # check the cache for the specified object

    my $cloned_object = undef;

    my %object_data;

    _read_object_data($file_path, \%object_data);
    
    if (%object_data) {

	my $object = $object_data{object};

	my $expires_at = $object_data{expires_at};

	if (_s_should_expire($expires_at)) {
	    unlink($file_path) or
		croak("Couldn't remove $file_path");
	} else {
	    $cloned_object = (ref $object) ? dclone($object) : $object;
	}
    }
    
    return $cloned_object;
}


# check to see if a directory exists, and create it with option mask if it doesn't

sub _verify_directory 
{
    my ($directory, $mask) = @_;

    return $sSUCCESS if -d $directory;

    my $old_mask = umask if defined $mask;

    umask($mask) if defined $mask;
    
    mkdir ($directory, 0777) or
	croak("Couldn't create directory: $directory: $!");

    umask($old_mask) if defined $mask;

    return $sSUCCESS;
}


# read in the object frozen at the specified path

sub _read_object_data 
{
    my ($file_path, $data_ref) = @_;

    my $frozen_object_data = undef;

    if (-f $file_path) {
	_read_file($file_path, \$frozen_object_data);
    } else {
	return;
    }
    
    if (!$frozen_object_data) {
	return;
    }

    %$data_ref = %{ thaw($frozen_object_data) };

    return;
}



# clear all objects in this instance's namespace

sub clear 
{
    my ($self) = @_;

    my $namespace_path = $self->{_namespace_path} or
	croak("namespace path required");

    _verify_directory($namespace_path) or
	croak("Couldn't verify directory $namespace_path");

    rmtree($namespace_path) or
	croak("Couldn't clear namespace");

    return $sSUCCESS;
}



# iterate over all the objects in this instance's namespace and delete those that have expired

sub purge
{
    my ($self) = @_;

    my $namespace_path = $self->{_namespace_path} or
	croak("namespace path required");

    _verify_directory($namespace_path) or
	croak("Couldn't verify directory $namespace_path");

    find(\&_purge_file_wrapper, $namespace_path);

    return $sSUCCESS;
}


# used with the Find::Find::find routine, this calls _purge_file on each file found

sub _purge_file_wrapper 
{
    my $file_path = $File::Find::name;

    if (-f $file_path) {
	_purge_file($file_path);
    } else {
	return;
    }
}


# if the file specified has expired, remove it from the cache

sub _purge_file
{
    my ($file_path) = @_;

    my %object_data;

    _read_object_data($file_path, \%object_data);

    if (%object_data) {
	
	my $expires_at = $object_data{expires_at};

	if (_s_should_expire($expires_at)) {
	    unlink($file_path) or
		croak("Couldn't unlink $file_path");
	}
	
    }

    return $sSUCCESS;
}


# purge expired objects from all namespaces associated with this cache key

sub _purge_all 
{
    my ($self) = @_;

    my $cache_path = $self->{_cache_path} or
	croak("cache path required");

    _verify_directory($cache_path) or
	croak("Couldn't verify directory $cache_path");

    find(\&_purge_file_wrapper, $cache_path);

    return $sSUCCESS;    
}



# determine whether an object should expire

sub _s_should_expire
{
    my ($expires_at, $time) = @_;

    # time is optional

    $time = $time || time();

    if ($expires_at == $sEXPIRES_NOW) {
	return $sTRUE;
    } elsif ($expires_at == $sEXPIRES_NEVER) {
	return $sFALSE;
    } elsif ($time >= $expires_at) {
	return $sTRUE;
    } else {
	return $sFALSE;
    }
}



# use this cache instance's frozen data to get an estimate of the memory consumption

sub _size 
{
    my ($self) = @_;

    my $namespace_path = $self->{_namespace_path} or
	croak("namespace path required");

    _verify_directory($namespace_path) or
	croak("Couldn't verify directory $namespace_path");

    return _recursive_directory_size($namespace_path);
}



# represent a path in canonical form

sub _build_path 
{
    my (@elements) = @_;

    if (grep (/\.\./, @elements)) {
	croak("Illegal path characters ..");
    }
    
    my $path = join('/', @elements);

    $path =~ s|/+|/|g;

    return $path;
}


# read in a file

sub _read_file 
{
    my ($filename, $data_ref) = @_;

    $filename or
	croak("filename required");
    
    open(FILE, $filename) or
	croak("Couldn't open $filename for reading: $!");

    local $/ = undef;

    $$data_ref = <FILE>;

    close(FILE);

    return $sSUCCESS;
}


# write a file

sub _write_file 
{
    my ($filename, $data_ref) = @_;

    $filename or
	croak("filename required");

    open(FILE, ">$filename") or
	croak("Couldn't open $filename for writing: $!\n");

    print FILE $$data_ref;

    close(FILE);

    return $sSUCCESS;
}


# clear all objects in all namespaces

sub CLEAR 
{
    my ($cache_key) = @_;

    $cache_key = $cache_key || $sDEFAULT_CACHE_KEY;

    if (!-d $cache_key) {
	return $sSUCCESS;
    }

    rmtree($cache_key) or
	croak("Couldn't clear cache");

    return $sSUCCESS;
}



# purge all objects in all namespaces that have expired

sub PURGE 
{
    my ($cache_key) = @_;

    $cache_key = $cache_key || $sDEFAULT_CACHE_KEY;

    if (!-d $cache_key) {
	return $sSUCCESS;
    }

    find(\&_purge_file_wrapper, $cache_key);
    
    return $sSUCCESS;
}



# get an estimate of the total memory consumption of the cache

sub SIZE 
{
    my ($cache_key) = @_;

    return _recursive_directory_size($cache_key);
}


# walk down a directory structure and total the size of the files contained therein

sub _recursive_directory_size 
{
    my ($directory) = @_;

    my $size = 0;

    opendir(DIR, $directory) or
	croak("Couldn't open directory $directory: $!");
    
    my @dirents = readdir(DIR);
    
    foreach my $dirent (@dirents) {

	next if $dirent eq '.' or $dirent eq '..';

	my $path = _build_path($directory, $dirent);

	if (-d $path) {
	    $size += _recursive_directory_size($path);
	} else {
	    $size += -s $path;
	}

    }

    closedir(DIR);
    
    return $size;
}


sub _get_username 
{
    my $effective_uid = $>;

    my $username; 

    my $success = eval {
	$username = getpwuid($effective_uid);
    };
    
    $username = 'nobody' if !$success;

    return $username;
}


1;


__END__


=head1 NAME

File::Cache - Share data between processes via filesystem

=head1 DESCRIPTION

B<File::Cache> is a perl module that implements an object 
storage space where data is persisted across process  boundaries 
via the filesystem.  

=head1 SYNOPSIS

use File::Cache;

# create a cache in the specified namespace, where objects 
# will expire in one day

my $cache = new File::Cache( { namespace  => 'MyCache', 
                               expires_in => 86400 } );

# store a value in the cache (will expire in one day)

$cache->set("key1", "value1");

# retrieve a value from the cache

$cache->get("key1");

# store a value that expires in one hour

$cache->set("key2", "value2", 3600);

# clear this cache's contents

$cache->clear();

# delete all namespaces from the filesystem

File::Cache::CLEAR();

=head2 TYPICAL USAGE

A typical scenario for this would be a mod_perl or perl CGI application.  In a
multi-tier architecture, it is likely that a trip from the front-end to the
database is the most expensive operation, and that data may not change frequently.  
Using this module will help keep that data on the front-end.

Consider the following usage in a mod_perl application, where a mod_perl application
serves out images that are retrieved from a database.  Those images change infrequently,
but we want to check them once an hour, just in case.

my $imageCache = new Cache( { namespace => 'Images', 
                              expires_in => 3600 } );

my $image = $imageCache->get("the_requested_image");

if (!$image) {

    # $image = [expensive database call to get the image]

    $imageCache->set("the_requested_image", $image);

}

That bit of code, executed in any instance of the mod_perl/httpd process will
first try the filesystem cache, and only perform the expensive database call
if the image has not been fetched before, has timed out, or the cache has been cleared.

=head2 METHODS

=over 4

=item B<new(\%options)>

Creates a new instance of the cache object.  The constructor takes a reference to an options 
hash which can contain any or all of the following:

=over 4

=item $options{namespace}

Namespaces provide isolation between objects.  Each cache refers to one and only one
namespace.  Multiple caches can refer to the same namespace, however.  While specifying
a namespace is not required, it is recommended so as not to have data collide.

=item $options{expires_in}

If the "expires_in" option is set, all objects in this cache will be cleared in that number
of seconds.  It can be overridden on a per-object basis.  If expires_in is not set, the objects
will never expire unless explicitly set.

=item $options{cache_key}

The "cache_key" is used to determine the underlying filesystem namespace to use.  In typical
usage, leaving this unset and relying on namespaces alone will be more than adequate.

=back

=item B<set($identifier, $object, $expires_in)>

Adds an object to the cache.  set takes the following parameters:

=over 4

=item $identifier

The key the refers to this object.

=item $object

The object to be stored.

=item $expires_in I<(optional)>

The object will be cleared from the cache in this number of seconds.  Overrides 
the default expire_in for the cache.

=back

=item B<get($identifier)>

Retrieves an object from the cache.  get takes the following parameter:

=over 4

=item $identifier

The key referring to the object to be retrieved.

=back

=item B<clear()>

Removes all objects from this cache.

=item B<purge()>

Removes all objects that have expired

=item B<File::Cache::CLEAR($cache_key)>

Removes this cache and all the associated namespaces from the filesystem.  CLEAR
takes the following parameter:

=over 4

=item $cache_key I<(optional)>

Specifies the filesystem data to be cleared.  Needed only if a cache was created with
a non-standard cache key.

=back

=item B<File::Cache::PURGE($cache_key)>

Removes all objects in all namespaces that have expired.  PURGE takes the following  
parameter:

=over 4

=item $cache_key I<(optional)>

Specifies the filesystem data to be purged.  Needed only if a cache was created with
a non-standard cache key.

=back

=item B<File::Cache::SIZE($cache_key)>

Roughly estimates the amount of memory in use.  SIZE takes the following  
parameter:

=over 4

=item $cache_key I<(optional)>

Specifies the filesystem data to be examined.  Needed only if a cache was created with
a non-standard cache key.

=back

=back

=head1 BUGS

=over 4

=item *

The root of the cache namespace is created with global read/write permissions.

=item *

There is no mechanism for limiting the amount of memory in use

=back

=head1 SEE ALSO

IPC::Cache, Storable

=head1 AUTHOR

DeWitt Clinton <dclinton@eziba.com>

=cut

