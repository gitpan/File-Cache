#!/usr/bin/perl -w

package File::Cache;

use strict;
use Carp;
use Storable qw(freeze thaw dclone);
use Digest::MD5  qw(md5_hex);
use File::Path;
use File::Find;
use File::Spec;
use Exporter;

use vars qw(@ISA @EXPORT_OK $VERSION $sSUCCESS $sFAILURE $sTRUE $sFALSE 
	    $sEXPIRES_NOW $sEXPIRES_NEVER $sNO_MAX_SIZE $sGET_STALE_ONLY 
	    $sGET_FRESH_ONLY);

$VERSION = '0.11';

@ISA = qw(Exporter);

@EXPORT_OK = qw($sSUCCESS $sFAILURE $sTRUE $sFALSE $sEXPIRES_NOW
		$sEXPIRES_NEVER $sNO_MAX_SIZE $sGET_STALE_ONLY 
		$sGET_FRESH_ONLY);

# Constants

$sSUCCESS = 1;
$sFAILURE = 0;

$sTRUE = 1;
$sFALSE = 0;

$sEXPIRES_NOW = 0;
$sEXPIRES_NEVER = -1;

$sNO_MAX_SIZE = -1;

$sGET_STALE_ONLY = 1;
$sGET_FRESH_ONLY = 0;

# The default cache key is used to address the temp filesystem

my $sDEFAULT_CACHE_KEY = '/tmp/File::Cache';


# if a namespace is not specified, use this as a default

my $sDEFAULT_NAMESPACE = "_default";


# by default, remove objects that have expired when then are requested

my $sDEFAULT_AUTO_REMOVE_STALE = $sTRUE;


# by default, the filemode is world read/writable

my $sDEFAULT_FILEMODE = 0777;


# by default, there is no max size to the cache

my $sDEFAULT_MAX_SIZE = $sNO_MAX_SIZE;


# if the OS does not support getpwuid, use this as a default username

my $sDEFAULT_USERNAME = 'nobody';


# by default, the objects in the cache never expire

my $sDEFAULT_GLOBAL_EXPIRES_IN = $sEXPIRES_NEVER;


# default cache depth

my $sDEFAULT_CACHE_DEPTH = 0;


# create a new Cache object that can be used to persist
# data across processes

sub new 
{
    my ($proto, $options) = @_;
    my $class = ref($proto) || $proto;
    my $self  = {};
    bless ($self, $class);


    # remove objects from the cache that have expired on retrieval
    # when this is set

    my $auto_remove_stale = defined $options->{auto_remove_stale} ?
	$options->{auto_remove_stale} : $sDEFAULT_AUTO_REMOVE_STALE;

    $self->set_auto_remove_stale($auto_remove_stale);


    # username is either specified or searched for in an OS
    # independent way

    my $username = defined $options->{username} ?
	$options->{username} : _find_username();

    $self->set_username($username);


    # the max cache size is either specified by the user or no max

    my $max_size = defined $options->{max_size} ? 
	$options->{max_size} : $sDEFAULT_MAX_SIZE;

    $self->set_max_size($max_size);


    # the user can specify the filemode

    my $filemode = defined $options->{filemode} ?
	$options->{filemode} : $sDEFAULT_FILEMODE;

    $self->set_filemode($filemode);


    # remember the expiration delta to be used for all objects if
    # specified

    my $global_expires_in = defined $options->{expires_in} ?
	$options->{expires_in} : $sDEFAULT_GLOBAL_EXPIRES_IN;

    $self->set_global_expires_in($global_expires_in);


    # verify that the cache space exists

    my $cache_key = defined $options->{cache_key} ?
	$options->{cache_key} : $sDEFAULT_CACHE_KEY;

    $self->set_cache_key($cache_key);


    # this instance will use the namespace specified or the default

    my $namespace = defined $options->{namespace} ?
	$options->{namespace} : $sDEFAULT_NAMESPACE;

    $self->set_namespace($namespace);


    # the cache will automatically create subdirectories to this depth

    my $cache_depth = defined $options->{cache_depth} ?
	$options->{cache_depth} : $sDEFAULT_CACHE_DEPTH;

    $self->set_cache_depth($cache_depth);


    # create a path for this particular user, and verify that it
    # exists

    my $user_path = _build_path($cache_key, $username);

    $self->set_user_path($user_path);


    # create a path for this namespace, and verify that it exists

    my $namespace_path = _build_path($user_path, $namespace);

    $self->set_namespace_path($namespace_path);
    

    return $self;
}



# store an object in the cache associated with the identifier

sub set 
{
    my ($self, $identifier, $object, $expires_in) = @_;

    my $unique_key = _build_unique_key($identifier);

    my $cached_file_path = $self->_build_cached_file_path($unique_key);

    # expiration time is based on a delta from the current time if
    # expires_in is defined, the object will expire in that number of
    # seconds from now else if expires_in is undefined, it will expire
    # based on the global_expires_in

    my $global_expires_in = $self->get_global_expires_in();

    my $expires_at;

    my $created_at = time();

    if (defined $expires_in) {
	$expires_at = $created_at + $expires_in;
    } elsif ($global_expires_in ne $sEXPIRES_NEVER) {
	$expires_at = $created_at + $global_expires_in;
    } else {
	$expires_at = $sEXPIRES_NEVER;
    }
    

    # add the new object to the cache in this instance's namespace

    my %object_data = ( object => $object, expires_at => $expires_at,
			created_at => $created_at ); 

    my $frozen_object_data = freeze(\%object_data);

    # Figure out what the new size of the cache should be in order to
    # accomodate the new data and still be below the max_size. Then
    # reduce the size.
    
    my $max_size = $self->get_max_size();

    if ($max_size != $sNO_MAX_SIZE) {
      my $new_size = $max_size - length $frozen_object_data;
      $new_size = 0 if $new_size < 0;
      $self->reduce_size($new_size);
    }

    my $filemode = $self->get_filemode();

    _write_file($cached_file_path, \$frozen_object_data, $filemode);

    return $sSUCCESS;
}



# retrieve an object from the cache associated with the identifier,
# and remove it from the cache if its expiration has elapsed and
# auto_remove_stale is 1.

sub get 
{
    my ($self, $identifier) = @_;

    my $object = $self->_get($identifier, $sGET_FRESH_ONLY);
    
    return $object;
}


# retrieve an object from the cache associated with the identifier,
# but only if it's stale

sub get_stale 
{
    my ($self, $identifier) = @_;

    my $object = $self->_get($identifier, $sGET_STALE_ONLY);
    
    return $object;
}


# Gets the stale or non-stale data from the cache, depending on the
# second parameter ($sGET_STALE_ONLY or $sGET_FRESH_ONLY)

sub _get 
{
    my ($self, $identifier, $freshness) = @_;

    my $unique_key = _build_unique_key($identifier);

    my $cached_file_path = $self->_build_cached_file_path($unique_key);

    # check the cache for the specified object

    my $cloned_object = undef;

    my %object_data;

    _read_object_data($cached_file_path, \%object_data);
    
    if (%object_data) {

	my $object = $object_data{object};

	my $expires_at = $object_data{expires_at};
	
	# If we want non-stale data...

	if ($freshness eq $sGET_FRESH_ONLY) {

	    # Check if the cache item has expired

	    if (_s_should_expire($expires_at)) {

		# Remove the item from the cache if auto_remove_stale
		# is $sTRUE

		my $auto_remove_stale = $self->get_auto_remove_stale();
		
		if ($auto_remove_stale eq $sTRUE) {
		    _remove_cached_file($cached_file_path) or
			croak("Couldn't remove cached file $cached_file_path");
		}

	    # otherwise fetch the object and return a copy

	    } else {
		$cloned_object = (ref $object) ? dclone($object) : $object;
	    }

	# If we want stale data...

	} else {
	
	    # and the cache item is indeed stale...

	    if (_s_should_expire($expires_at)) {
		
		# fetch the object and return a copy
		$cloned_object = (ref $object) ? dclone($object) : $object;

	    }
	}
    }
    
    return $cloned_object;
}


# removes a key and value from the cache, it always succeeds, even if
# the key or value doesn't exist

sub remove 
{
    my ($self, $identifier) = @_;

    my $unique_key = _build_unique_key($identifier);

    my $cached_file_path = $self->_build_cached_file_path($unique_key);

    _remove_cached_file($cached_file_path) or
	croak("couldn't remove cached file $cached_file_path");

    return $sSUCCESS;
}


# take an human readable identifier, and create a unique key from it
 
sub _build_unique_key
{
    my ($identifier) = @_;

    $identifier or
	croak("identifier required");

    my $unique_key = md5_hex($identifier) or
	croak("couldn't build unique key for identifier $identifier");

    return $unique_key;
}


# check to see if a directory exists, and create it with option mask
# if it doesn't

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
    my ($cached_file_path, $data_ref) = @_;

    my $frozen_object_data = undef;

    if (-f $cached_file_path) {
	_read_file($cached_file_path, \$frozen_object_data);
    } else {
	return;
    }
    
    if (!$frozen_object_data) {
	return;
    }

    %$data_ref = %{ thaw($frozen_object_data) };

    return;
}


# remove an object from the cache

sub _remove_cached_file
{
    my ($cached_file_path) = @_;

    # Is there any way to do this atomically?

    if (-f $cached_file_path) {

	# We don't catch the error, because this may fail if two
	# processes are in a race and try to remove the object

	unlink($cached_file_path);

    }

    return $sSUCCESS;
}


# clear all objects in this instance's namespace

sub clear 
{
    my ($self) = @_;

    my $namespace_path = $self->get_namespace_path();

    rmtree($namespace_path) or
	croak("Couldn't clear namespace");

    return $sSUCCESS;
}



# iterate over all the objects in this instance's namespace and delete
# those that have expired

sub purge
{
    my ($self) = @_;

    my $namespace_path = $self->get_namespace_path();

    find({wanted=>\&_purge_file_wrapper, untaint=>1, 
	  'untaint_pattern'=>qr{^([^<>|]*)$}}, $namespace_path);

    return $sSUCCESS;
}


# used with the Find::Find::find routine, this calls _purge_file on
# each file found

sub _purge_file_wrapper 
{
    my $file_path = $File::Find::name;

    my ($file) = $file_path =~ m|.*/(.*?)$|;

    if (-f $file) {
	_purge_file($file);
    } else {
	return;
    }
}


# if the file specified has expired, remove it from the cache

sub _purge_file
{
    my ($file) = @_;

    my %object_data;

    _read_object_data($file, \%object_data);

    if (%object_data) {
	
	my $expires_at = $object_data{expires_at};

	if (_s_should_expire($expires_at)) {
	    _remove_cached_file($file) or
		croak("Couldn't remove cached file $file");
	}
	
    }

    return $sSUCCESS;
}


# purge expired objects from all namespaces associated with this cache
# key

sub _purge_all 
{
    my ($self) = @_;

    my $user_path = $self->get_user_path();

    find(\&_purge_file_wrapper, $user_path);

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


# reduce this namespace to a given size

sub reduce_size
{
    my ($self, $new_size) = @_;

    $new_size >= 0 or 
	croak("size >= 0 required");

    my $namespace_path = $self->get_namespace_path();

    while ($self->size() > $new_size) {

	my $victim_file = $self->_choose_victim_file($namespace_path);

	if (!$victim_file) {
	    print STDERR "Couldn't reduce size to $new_size\n";
	    return $sFAILURE;
	}

	_remove_cached_file($victim_file) or
	    croak("Couldn't remove cached file $victim_file");
    }

    return $sSUCCESS;
}



# reduce the entire cache size to a given size

sub REDUCE_SIZE
{
    my ($self, $new_size, $cache_key) = @_;

    $new_size >= 0 or 
	croak("size >= 0 required");

    $cache_key = $cache_key || $sDEFAULT_CACHE_KEY;

    while ($self->SIZE() > $new_size) {
	
	my $victim_file = $self->_choose_victim_file($cache_key);
	
	_remove_cached_file($victim_file) or
	    croak("Couldn't remove cached file $victim_file");
    }

    return $sSUCCESS;
}


# Choose a "victim" cache entry to remove. First get the one with the
# closest expiration, or (if that's not available), the least recently
# accessed one.

sub _choose_victim_file
{
    my ($self, $root) = @_;

    # Look for the file to delete with the nearest expiration

    my ($nearest_expiration_path, $nearest_expiration_time) =
	_recursive_find_nearest_expiration($root);

    return $nearest_expiration_path if defined $nearest_expiration_path;

    # If there are no files with expirations, get the least recently
    # accessed one

    my ($latest_accessed_path, $latest_accessed_time) =
	_recursive_find_latest_accessed($root);

    return $latest_accessed_path;
}


# Recursively searches a cache namespace for the cache entry with the
# nearest expiration. Returns undef if no cache entry with an
# expiration time could be found.

sub _recursive_find_nearest_expiration
{
    my ($directory) = @_;

    my $best_nearest_expiration_path = undef;
    
    my $best_nearest_expiration_time = undef;

    opendir(DIR, $directory) or
	croak("Couldn't open directory $directory: $!");
    
    my @dirents = readdir(DIR);
    
    foreach my $dirent (@dirents) {

	next if $dirent eq '.' or $dirent eq '..';

	my $nearest_expiration_path_candidate = undef;

	my $nearest_expiration_time_candidate = undef;

	my $path = _build_path($directory, $dirent);

	if (-d $path) {

	    ($nearest_expiration_path_candidate, 
	     $nearest_expiration_time_candidate) =
		 _recursive_find_nearest_expiration($path);

	} else {

	    my %object_data;

	    _read_object_data_without_modification($path, \%object_data);
		
	    my $expires_at = $object_data{expires_at};

	    $nearest_expiration_path_candidate = $path;

	    $nearest_expiration_time_candidate = $expires_at;

	}

	
	next unless defined $nearest_expiration_path_candidate;

	next unless defined $nearest_expiration_time_candidate;

	# Skip this file if it doesn't have an expiration time.

	next if $nearest_expiration_time_candidate == $sEXPIRES_NEVER;

	# if this is the first candidate, they're automatically the
	# best, otherwise they have to beat the best

	if ((!defined $best_nearest_expiration_time) or
	    ($best_nearest_expiration_time > 
	     $nearest_expiration_time_candidate)) {

	    $best_nearest_expiration_path =
		$nearest_expiration_path_candidate;

	    $best_nearest_expiration_time =
		$nearest_expiration_time_candidate; 
	}

    }

    closedir(DIR);

    return ($best_nearest_expiration_path, $best_nearest_expiration_time);
}


# read in object data without modifying the access time

sub _read_object_data_without_modification 
{
    my ($path, $object_data_ref) = @_;

    my ($file_access_time, $file_modified_time) = (stat($path))[8,9];

    _read_object_data($path, $object_data_ref);
	
    utime($file_access_time, $file_modified_time, $path);    
}


# Recursively searches a cache namespace for the cache entry with the
# latest access time. Precondition: there is at least one cache entry
# in the cache.  (This should be true as long as this function is
# called only when the cache size is greater than 0.)

sub _recursive_find_latest_accessed
{
    my ($directory) = @_;

    my $best_latest_accessed_path = undef;

    my $best_latest_accessed_time = undef;

    opendir(DIR, $directory) or
	croak("Couldn't open directory $directory: $!");
    
    my @dirents = readdir(DIR);
    
    foreach my $dirent (@dirents) {

	next if $dirent eq '.' or $dirent eq '..';

	my $latest_accessed_path_candidate = undef;

	my $latest_accessed_time_candidate = undef;

	my $path = _build_path($directory, $dirent);

	if (-d $path) {

	    ($latest_accessed_path_candidate,
	     $latest_accessed_time_candidate) =
		 _recursive_find_latest_accessed($path);


	} else {

	    my $last_accessed_time = (stat($path))[8];

	    $latest_accessed_path_candidate = $path;

	    $latest_accessed_time_candidate = $last_accessed_time;

	}

	next unless defined $latest_accessed_path_candidate;

	next unless defined $latest_accessed_time_candidate;

	# if this is the first candidate, they're automatically the
	# best, otherwise they have to beat the best

	if ((!defined $best_latest_accessed_time) or
	    ($best_latest_accessed_time >
	     $latest_accessed_time_candidate)) {

	    $best_latest_accessed_path = 
		$latest_accessed_path_candidate;

	    $best_latest_accessed_time = 
		$latest_accessed_time_candidate;

	}
    }

    closedir(DIR);
    
    return ($best_latest_accessed_path, $best_latest_accessed_time);
}



# recursively descend to get an estimate of the memory consumption for
# this namespace

sub size 
{
    my ($self) = @_;

    my $namespace_path = $self->get_namespace_path();

    return _recursive_directory_size($namespace_path);
}


# find the path to the cached file, taking into account the
# identifier, namespace, and cache depth

sub _build_cached_file_path 
{
    my ($self, $unique_key) = @_;

    my $namespace_path = $self->get_namespace_path();

    my $cache_depth = $self->get_cache_depth();

    my (@path_prefix) = _extract_path_prefix($unique_key, $cache_depth);

    my $cached_file_path = _build_path($namespace_path);

    foreach my $path_element (@path_prefix) {

	$cached_file_path = _build_path($cached_file_path, $path_element);

	_verify_directory($cached_file_path);	

    }

    $cached_file_path = _build_path($cached_file_path, $unique_key);

    return $cached_file_path;
}


# return a list of the first $cache_depth letters in the $identifier

sub _extract_path_prefix  
{
    my ($unique_key, $cache_depth) = @_;

    my @path_prefix;

    for (my $i = 0; $i < $cache_depth; $i++) {
	push (@path_prefix, substr($unique_key, $i, 1));
    }

    return @path_prefix;
}



# represent a path in canonical form

sub _build_path 
{
    my (@elements) = @_;

    if (grep (/\.\./, @elements)) {
	croak("Illegal path characters ..");
    }
    
    my $path = File::Spec->catfile(@elements);

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
    my ($filename, $data_ref, $mode) = @_;

    $filename or
	croak("filename required");

    $mode = 0600 unless defined $mode;

    # Prepare the name for taint checking 

    ($filename) = $filename =~ /([^|<>]*)/;
    
    open(FILE, ">$filename") or
	croak("Couldn't open $filename for writing: $!\n");

    chmod $mode, $filename;

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


# walk down a directory structure and total the size of the files
# contained therein

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



# Find the username of the person running the process in an OS
# independent way

sub _find_username 
{
    my ($self) = @_;
    
    my $username;

    my $success = eval {
	my $effective_uid = $>;
	$username = getpwuid($effective_uid);	
    };
      
    if ($success and $username) {
	return $username;
    } else {
	return $sDEFAULT_USERNAME;
    }
}




# Get whether or not we automatically remove stale data from the cache
# on retrieval

sub get_auto_remove_stale 
{
    my ($self) = @_;

    return $self->{_auto_remove_stale};
}


# Set whether or not we automatically remove stale data from the cache
# on retrieval

sub set_auto_remove_stale 
{
    my ($self, $auto_remove_stale) = @_;

    $self->{_auto_remove_stale} = $auto_remove_stale;
}



# Get the root of this cache on the filesystem

sub get_cache_key 
{
    my ($self) = @_;

    my $cache_key = $self->{_cache_key};

    _verify_directory($cache_key, 0000) or
	croak("Couldn't verify directory $cache_key");

    return $cache_key;
}


# Set the root of this cache on the filesystem 

# TODO: This should probably trigger a rebuilding of the user_path and
# the namespace_path

sub set_cache_key 
{
    my ($self, $cache_key) = @_;

    _verify_directory($cache_key, 0000) or
	croak("Couldn't verify directory $cache_key");

    $self->{_cache_key} = $cache_key;
}



# Get the root of this user's path

sub get_user_path 
{
    my ($self) = @_;

    my $user_path = $self->{_user_path};

    _verify_directory($user_path) or
	croak("Couldn't verify directory $user_path");
    
    return $user_path;
}



# Set the root of this user's path

# TODO: This should probably trigger a rebuild of the namespace path

sub set_user_path 
{
    my ($self, $user_path) = @_;

    _verify_directory($user_path) or
	croak("Couldn't verify directory $user_path");

    $self->{_user_path} = $user_path;
}




# Get the root of this namespace's path

sub get_namespace_path 
{
    my ($self) = @_;

    my $namespace_path = $self->{_namespace_path};

    _verify_directory($namespace_path) or
	croak("Couldn't verify directory $namespace_path");
    
    return $namespace_path;
}



# Set the root of this namespaces's path

sub set_namespace_path 
{
    my ($self, $namespace_path) = @_;

    _verify_directory($namespace_path) or
	croak("Couldn't verify directory $namespace_path");

    $self->{_namespace_path} = $namespace_path;
}





# Get the namespace for this cache instance (within the entire cache)

sub get_namespace 
{
    my ($self) = @_;

    return $self->{_namespace};
}


# Set the namespace for this cache instance (within the entire cache)

# TODO: This should probably trigger a rebuild of the namespace path

sub set_namespace 
{
    my ($self, $namespace) = @_;

    $self->{_namespace} = $namespace;
}



# Get the global expiration value for the cache

sub get_global_expires_in 
{
    my ($self) = @_;

    return $self->{_global_expires_in};
}


# Set the global expiration value for the cache

sub set_global_expires_in 
{
    my ($self, $global_expires_in) = @_;

    ($global_expires_in > 0) || 
	($global_expires_in == $sEXPIRES_NEVER) || 
	    ($global_expires_in == $sEXPIRES_NOW) or
		croak("\$global_expires_in must be > 0," .
		      "\$sEXPIRES_NOW, or $sEXPIRES_NEVER");

    $self->{_global_expires_in} = $global_expires_in;
}



# Get the creation time for a cache entry. Returns undef if the value
# is not in the cache

sub get_creation_time
{
    my ($self, $identifier) = @_;

    my $unique_key = _build_unique_key($identifier);
    
    my $cached_file_path = $self->_build_cached_file_path($unique_key);
    
    my %object_data;
    
    _read_object_data($cached_file_path, \%object_data);

    if (%object_data) {

	return $object_data{created_at};
	
    } else {
	
        return undef;
	
    }
}


# Get the expiration time for a cache entry. Returns undef if the
# value is not in the cache

sub get_expiration_time
{
    my ($self, $identifier) = @_;

    my $unique_key = _build_unique_key($identifier);
    
    my $cached_file_path = $self->_build_cached_file_path($unique_key);
    
    my %object_data;
    
    _read_object_data($cached_file_path, \%object_data);
    
    if (%object_data) {
	
	return $object_data{expires_at};
	
    } else {
	
        return undef;
	
    }
}






# Get the username associated with this cache

sub get_username 
{
    my ($self) = @_;
    
    return $self->{_username};
}


# Set the username associated with this cache 

# TODO: This should probably trigger a rebuild of the namespace_path

sub set_username 
{
    my ($self, $username) = @_;

    $self->{_username} = $username;
}




# Gets the filemode for files created within the cache

sub get_filemode
{
    my ($self) = @_;

    return $self->{_filemode};
}


# Sets the filemode for files created within the cache

sub set_filemode 
{
    my ($self, $filemode) = @_;

    $self->{_filemode} = $filemode;
}




# Gets the max cache size.

sub get_max_size
{
    my ($self) = @_;

    return $self->{_max_size};
}



# Sets the max cache size.

# TODO: This could cause the reduction routines to run

sub set_max_size
{
    my ($self, $max_size) = @_;
    
    ($max_size > 0) || ($max_size == $sNO_MAX_SIZE) or
	croak("Invalid cache size.  " . 
	      "Must be either \$sNO_MAX_SIZE or greater than zero");

    $self->{_max_size} = $max_size;
}



# Gets the cache depth

sub get_cache_depth 
{
    my ($self) = @_;

    return $self->{_cache_depth};
}


# Sets the cache depth

sub set_cache_depth 
{
    my ($self, $cache_depth) = @_;

    $self->{_cache_depth} = $cache_depth;
}


1;


__END__


=head1 NAME

File::Cache - Share data between processes via filesystem

=head1 DESCRIPTION

B<File::Cache> is a perl module that implements an object storage
space where data is persisted across process boundaries via the
filesystem.

=head1 SYNOPSIS

 use File::Cache;

 # create a cache in the default namespace, where objects
 # do not expire

 my $cache = new File::Cache();

 # create a user-private cache in the specified 
 # namespace, where objects will expire in one day, and
 # will automatically be removed from the cache.

 my $cache = new File::Cache( { namespace  => 'MyCache', 
                                expires_in => 86400,
                                filemode => 0600 } );

 # create a public cache in the specified namespace,
 # where objects will expire in one day, but will not be
 # removed from the cache automatically.

 my $cache = new File::Cache( { namespace  => 'MyCache', 
                                expires_in => 86400,
                                username => 'shared_user',
                                auto_remove_stale => 0,
                                filemode => 0666 } );

 # create a cache readable by the user and the user's
 # group in the specified namespace, where objects will
 # expire in one day, but may be removed from the cache
 # earlier if the size becomes more than a megabyte. Also,
 # request that the cache use subdirectories to increase
 # performance of large number of objects

 my $cache = new File::Cache( { namespace  => 'MyCache', 
                                expires_in => 86400,
                                max_size => 1048576,
                                username => 'shared_user',
                                filemode => 0660,
			        cache_depth => 3 } );

 # store a value in the cache (will expire in one day)

 $cache->set("key1", "value1");

 # retrieve a value from the cache

 $cache->get("key1");

 # retrieve a stale value from the cache.
 # (Undefined behavior if auto_remove_stale is 1)

 $cache->get_stale("key1");

 # store a value that expires in one hour

 $cache->set("key2", "value2", 3600);

 # reduce the cache size to 3600 bytes

 $cache->reduce_size(3600);

 # clear this cache's contents

 $cache->clear();

 # delete all namespaces from the filesystem

 File::Cache::CLEAR();

=head2 TYPICAL USAGE

A typical scenario for this would be a mod_perl or perl CGI
application.  In a multi-tier architecture, it is likely that a trip
from the front-end to the database is the most expensive operation,
and that data may not change frequently.  Using this module will help
keep that data on the front-end.

Consider the following usage in a mod_perl application, where a
mod_perl application serves out images that are retrieved from a
database.  Those images change infrequently, but we want to check them
once an hour, just in case.

my $imageCache = new Cache( { namespace => 'Images', 
                              expires_in => 3600 } );

my $image = $imageCache->get("the_requested_image");

if (!$image) {

    # $image = [expensive database call to get the image]

    $imageCache->set("the_requested_image", $image);

}

That bit of code, executed in any instance of the mod_perl/httpd
process will first try the filesystem cache, and only perform the
expensive database call if the image has not been fetched before, has
timed out, or the cache has been cleared.

The current implementation of this module automatically removes
expired items from the cache when the get() method is called and the
auto_remove_stale setting is true.  Automatic removal does not occur
when the set() method is called, which means that the cache can become
polluted with expired items if many items are stored in the cache for
short periods of time, and are rarely accessed. This is a design
decision that favors efficiency in the common case, where items are
accessed frequently. If you want to limit cache growth, see the
max_size option, which will automatically shrink the cache when the
set() method is called. (max_size is unaffected by the value of
auto_remove_stale.)

Be careful that you call the purge method periodically if
auto_remove_stale is 0 and max_size has its default value of unlimited
size. In this configuration, the cache size will be a function of the
number of items inserted into the cache since the last purge. (i.e. It
can grow extremely large if you put lots of different items in the
cache.)

=head2 METHODS

=over 4

=item B<new(\%options)>

Creates a new instance of the cache object.  The constructor takes a
reference to an options hash which can contain any or all of the
following:

=over 4

=item $options{namespace}

Namespaces provide isolation between objects.  Each cache refers to
one and only one namespace.  Multiple caches can refer to the same
namespace, however.  While specifying a namespace is not required, it
is recommended so as not to have data collide.

=item $options{expires_in}

If the "expires_in" option is set, all objects in this cache will be
cleared in that number of seconds.  It can be overridden on a
per-object basis.  If expires_in is not set, the objects will never
expire unless explicitly set.

=item $options{cache_key}

The "cache_key" is used to determine the underlying filesystem
namespace to use.  In typical usage, leaving this unset and relying on
namespaces alone will be more than adequate.

=item $options{username}

The "username" is used to explicitely set the username. This is useful
for cases where one wishes to share a cache among multiple users. If
left unset, the value will be the current user's username. (Also see
$options{filemode}.)  Note that the username is not used to set
ownership of the cache files -- the i.e. the username does not have to
be a user of the system.

=item $options{filemode}

"filemode" specifies the permissions for cache files. This is useful
for cases where one wishes to share a cache among multiple users. If
left unset, the value will be "u", indicating that only the current
user can read an write the cache files. See the filemode() method
documentation for the specification syntax.

=item $options{max_size}

"max_size" specifies the maximum size of the cache, in bytes.  Cache
entries are removed during the set() operation in order to reduce the
cache size before the new cache value is added. See the reduce_size()
documentation for the cache entry removal policy. The max_size will be
maintained regardless of the value of auto_remove_stale.

=item $options(auto_remove_stale}

"auto_remove_stale" specifies that the cache should remove expired
objects from the cache when they are requested.

=item $options(cache_depth}

"cache_depth" specifies the depth of the subdirectories that should be
created.  This is helpful when especially large numbers of objects are
being cached (>1000) at once.  The optimal number of files per
directory is dependent on the type of filesystem, so some hand-tuning
may be required.

=back

=item B<set($identifier, $object, $expires_in)>

Adds an object to the cache.  set takes the following parameters:

=over 4

=item $identifier

The key the refers to this object.

=item $object

The object to be stored.

=item $expires_in I<(optional)>

The object will be cleared from the cache in this number of seconds.
Overrides the default expires_in value for the cache.

=back

=item B<get($identifier)>

Retrieves an object from the cache, if it is not stale.  If it is
stale and auto_remove_stale is 1, it will be removed from the cache.
B<get> returns undef if the object is stale or does not exist.  get
takes the following parameter:

=over 4

=item $identifier

The key referring to the object to be retrieved.

=back

=item B<get_stale($identifier)>

Retrieves a stale object from the cache. Call this method only if
auto_remove_stale is 0. B<get_stale> returns undef if the object is
not stale or does not exist.  (It happens to have a precise semantics
for auto_remove_stale == 1, but it may change.) get_stale takes the
following parameter:

=over 4

=item $identifier

The key referring to the object to be retrieved.

=back

=item B<remove($identifier)>

Removes an object from the cache.

=over 4

=item $identifier

The key referring to the object to be removed.

=back

=item B<clear()>

Removes all objects from this cache.

=item B<purge()>

Removes all objects that have expired

=item B<size()>

Return an estimate of the disk usage of the current namespace.


=item B<reduce_size($size)>

Reduces the size of the cache so that it is below $size. Note that the
cache size is approximate, and may slightly exceed the value of $size.

Cache entries are removed in order of nearest expiration time, or
latest access time if there are no cache entries with expiration
times. (If there are a mix of cache entries with expiration times and
without, the ones with expiration times are removed first.)
reduce_size takes the following parameter:

=over 4

=item $size

The new target cache size.

=back

=item B<get_creation_time($identifier)>

Gets the time at which the data associated with $identifier was stored
in the cache. Returns undef if $identifier is not cached.

=over 4

=item $identifier

The key referring to the object to be retrieved.

=back 


=item B<get_expiration_time($identifier)>

Gets the time at which the data associated with $identifier will
expire from the cache. Returns undef if $identifier is not cached.

=over 4

=item $identifier

The key referring to the object to be retrieved.

=back 


=item B<get_global_expires_in()>

Returns the default number of seconds before an object in the cache expires.

=item B<set_global_expires_in($global_expires_in)>

Sets the default number of seconds before an object in the cache
expires.  set_global_expires_in takes the following parameter:

=over 4

=item $global_expires_in

The default number of seconds before an object in the cache expires.
It should be a number greater than zero, $File::Cache::sEXPIRES_NEVER,
or $File::Cache::sEXPIRES_NOW.

=back 

=item B<get_auto_remove_stale()>

Returns whether or not the cache will automatically remove objects
after they expire.

=item B<set_auto_remove_stale($auto_remove_stale)>

Sets whether or not the cache will automatically remove objects after
they expire.  set_auto_remove_stale takes the following parameter:

=over 4

=item $auto_remove_stale

The new auto_remove_stale value.  If $auto_remove_stale is 1 or
$File::Cache::sTRUE, then the cache will automatically remove items
when they are being retrieved if they have expired.  If
$auto_remove_stale is 0 or $File::Cache::sFALSE, the cache will only
remove expired items when the purge() method is called, or if max_size
is set.  Note that the behavior of get_stale is undefined if
$auto_remove_stale is true.

=back


=item B<get_username()>

Returns the username that is currently being used to define the
location of this cache.

=item B<set_username($username)>

Sets the username that is currently being used to define the location
of this cache.  set_username takes the following parameter:

=over 4

=item $username

The username that is currently being used to define the location of
this cache. It is not directly used to determine the ownership of the
cache files, but can be used to isolate sections of a cache for
different permissions.

=back

=item B<get_filemode()>

Returns the filemode specification for newly created cache objects. 

=item B<set_filemode($mode)>

Sets the filemode specification for newly created cache objects.
set_filemode takes the following parameter:

=over 4

=item $mode

The file mode -- a numerical mode identical to that used by
chmod(). See the chmod() documentation for more information.

=back


=item B<File::Cache::CLEAR($cache_key)>

Removes this cache and all the associated namespaces from the
filesystem.  CLEAR takes the following parameter:

=over 4

=item $cache_key I<(optional)>

Specifies the filesystem data to be cleared.  Needed only if a cache
was created with a non-standard cache key.

=back

=item B<File::Cache::PURGE($cache_key)>

Removes all objects in all namespaces that have expired.  PURGE takes
the following parameter:

=over 4

=item $cache_key I<(optional)>

Specifies the filesystem data to be purged.  Needed only if a cache
was created with a non-standard cache key.

=back

=item B<File::Cache::SIZE($cache_key)>

Roughly estimates the amount of memory in use.  SIZE takes the
following parameter:

=over 4

=item $cache_key I<(optional)>

Specifies the filesystem data to be examined.  Needed only if a cache
was created with a non-standard cache key.

=back

=item B<File::Cache::REDUCE_SIZE($size, $cache_key)>

Reduces the size of the cache so that it is below $size. Note that the
cache size is approximate, and may slightly exceed the value of $size.

Cache entries are removed in order of nearest expiration time, or
latest access time if there are no cache entries with expiration
times. (If there are a mix of cache entries with expiration times and
without, the ones with expiration times are removed first.)
REDUCE_SIZE takes the following parameters:

=over 4

=item $size

The new target cache size.

=item $cache_key I<(optional)>

Specifies the filesystem data to be examined.  Needed only if a cache
was created with a non-standard cache key.

=back

=back

=head1 BUGS

=over 4

=item *

The root of the cache namespace is created with global read/write
permissions.

=back

=head1 SEE ALSO

IPC::Cache, Storable

=head1 AUTHOR

DeWitt Clinton <dewitt@avacet.com>, and please see the CREDITS file

=cut

