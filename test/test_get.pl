#!/usr/bin/perl -w

use strict;
use File::Cache;

my $sUSAGE = "Usage: test_get.pl cache_key namespace username cache_depth key expected_value";

my $cache_key = $ARGV[0] or
    die("$sUSAGE\n");

my $namespace = $ARGV[1] or
    die("$sUSAGE\n");

my $username = $ARGV[2] or
    die("sUSAGE\n");

my $cache_depth = $ARGV[3] or
    die("sUSAGE\n");

my $key = $ARGV[4] or
    die("sUSAGE\n");

my $expected_value = $ARGV[5] or
    die("sUSAGE\n");

my $cache = new File::Cache( { cache_key => $cache_key, 
			       namespace => $namespace, 
			       username => $username, 
			       cache_depth => $cache_depth } ) or
    die("Couldn't create cache");

my $value = $cache->get($key) or
    die("Couldn't get object at $key");

$value eq $expected_value or
    die("value $value not equal to $expected_value");

exit(0);


