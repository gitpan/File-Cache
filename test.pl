#!/usr/bin/perl -w

# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

######################### We start with some black magic to print on failure.

# Change 1..1 below to 1..last_test_to_print .
# (It may become useful if the test is moved to ./t subdirectory.)

BEGIN { $| = 1; print "1..20\n"; }
END {print "not ok 1\n" unless $loaded;}

use File::Cache;

$loaded = 1;
print "ok 1\n";


######################### End of black magic.

use strict;

my $sTEST_CACHE_KEY = "/tmp/TSTC";
my $sTEST_NAMESPACE = "TestCache";
my $sMAX_SIZE = 1000;
my $sTEST_USERNAME = "web";
my $sTEST_CACHE_DEPTH = 3;

# Test creation of a cache object

my $test = 2;

my $cache1 = new File::Cache( { cache_key => $sTEST_CACHE_KEY,
				namespace => $sTEST_NAMESPACE,
			        max_size => $sMAX_SIZE,
			        auto_remove_stale => 0,
			        username => $sTEST_USERNAME,
			        filemode => 0770,
				cache_depth => $sTEST_CACHE_DEPTH } );

if ($cache1) {
    print "ok $test\n";
} else {
    print "not ok $test\n";
}

# Test the setting of a scalar in the cache

$test = 3;

my $seed_value = "Hello World";

my $key = 'key1';

my $status = $cache1->set($key, $seed_value);

if ($status) {
    print "ok $test\n";
} else {
   print "not ok $test\n";
}

# Test the getting of a scalar from the cache

$test = 4;

my $val1_retrieved = $cache1->get($key);

if ($val1_retrieved eq $seed_value) {
    print "ok $test\n";
} else {
   print "not ok $test\n";
}

# Test the getting of the scalar from a subprocess

$test = 5;

if (system("perl", "-Iblib/lib", "./test/test_get.pl", 
	   $sTEST_CACHE_KEY, $sTEST_NAMESPACE, $sTEST_USERNAME, $sTEST_CACHE_DEPTH, $key, $seed_value) == 0) {
    print "ok $test\n";
} else {
    print "not okay $test\n";
}


# Test checking the memory consumption of the cache

$test = 6;

my $size = File::Cache::SIZE($sTEST_CACHE_KEY);

if ($size) {
   print "ok $test\n";
} else {
    print "not okay $test\n";
}


# Test clearing the cache's namespace

$test = 7;

$status = $cache1->clear();

if ($status) {
    print "ok $test\n";
} else {
   print "not ok $test\n";
}


# Test the max_size limit
# Intentionally add more data to the cache than fits in max_size

$test = 8;

my $string = 'abcdefghij';

my $start_size = $cache1->size();

$cache1->set('initial_value', $string);

my $end_size = $cache1->size();

my $string_size = $end_size - $start_size;

my $cache_item = 0;

# This should take the cache to nearly the edge

while (($cache1->size() + $string_size) < $sMAX_SIZE) {
    $cache1->set("item:$cache_item", $string);
    $cache_item++;
}

# This should put it over the top

$cache1->set("item:$cache_item", $string);

if ($cache1->size > $sMAX_SIZE) {
    print "not ok $test\n";
} else {
    print "ok $test\n";
}



# Test the getting of a scalar after the clearing of a cache

$test = 9;

my $val2_retrieved = $cache1->get($key);

if ($val2_retrieved) {
    print "not ok $test\n";
} else {
   print "ok $test\n";
}


# Test the setting of a scalar in the cache with a immediate timeout

$test = 10;

$status = $cache1->set($key, $seed_value, 0);

if ($status) {
    print "ok $test\n";
} else {
   print "not ok $test\n";
}


# Test the getting of a scalar from the cache that should have timed out immediately

$test = 11;

my $val3_retrieved = $cache1->get($key);

if ($val3_retrieved) {
    print "not ok $test\n";
} else {
   print "ok $test\n";
}


# Test the getting of the expired scalar using get_stale

$test = 12;

my $val3_stale_retrieved = $cache1->get_stale($key);

if ($val3_stale_retrieved) {
    print "ok $test\n";
} else {
    print "not ok $test\n";
}

    

# Test the setting of a scalar in the cache with a timeout in the near future

$test = 13;

$status = $cache1->set($key, $seed_value, 2);

if ($status) {
    print "ok $test\n";
} else {
   print "not ok $test\n";
}


# Test the getting of a scalar from the cache that should not have timed out yet (unless the system is *really* slow)

$test = 14;

my $val4_retrieved = $cache1->get($key);

if ($val4_retrieved eq $seed_value) {
    print "ok $test\n";
} else {
   print "not ok $test\n";
}


# Test the getting of a scalar from the cache that should have timed out

$test = 15;

sleep(3);

my $val5_retrieved = $cache1->get($key);

if ($val5_retrieved) {
    print "not ok $test\n";
} else {
   print "ok $test\n";
}


# Test purging the cache's namespace

$test = 16;

$status = $cache1->purge();

if ($status) {
    print "ok $test\n";
} else {
   print "not ok $test\n";
}

# Test getting the creation time of the cache entry

$test = 17;

my $timed_key = 'timed key';

my $creation_time = time();

my $expires_in = 1000;

$cache1->set($timed_key, $seed_value, $expires_in);

# Delay a bit

sleep(2);
    
# Let's expect no more than 1 second delay between the creation of the cache
# entry and our saving of the time.

my $cached_creation_time = $cache1->get_creation_time($timed_key);

my $creation_time_delta = $creation_time - $cached_creation_time;

if ($creation_time_delta <= 1) {
    $status = 1;
} else {
    $status = 0;
}

if ($status) {
    print "ok $test\n";
} else {                                                                        
   print "not ok $test\n";
}   


# Test getting the expiration time of the cache entry

$test = 18;

my $expected_expiration_time = $cache1->get_creation_time($timed_key) + $expires_in;

my $actual_expiration_time = $cache1->get_expiration_time($timed_key);

$status = $expected_expiration_time == $actual_expiration_time;

if ($status) {
    print "ok $test\n";
} else {
   print "not ok $test\n";
}



# Test PURGING of a cache object

$test = 19;

$status = File::Cache::PURGE($sTEST_CACHE_KEY);

if ($status) {
    print "ok $test\n";
} else {
   print "not ok $test\n";
}


# Test CLEARING of a cache object

$test = 20;

$status = File::Cache::CLEAR($sTEST_CACHE_KEY);

if ($status) {
    print "ok $test\n";
} else {
   print "not ok $test\n";
}

1;


