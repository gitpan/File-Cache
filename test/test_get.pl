#!/usr/bin/perl -w

use strict;
use File::Cache;

my $sUSAGE = "Usage: test_get.pl cache_key namespace username cache_depth implementation key expected_value";

my $cache_key = $ARGV[0] or
    die("$sUSAGE\n");

my $namespace = $ARGV[1] or
    die("$sUSAGE\n");

my $username = $ARGV[2] or
    die("sUSAGE\n");

my $cache_depth = $ARGV[3] or
    die("sUSAGE\n");

my $implementation = $ARGV[4] or
    die("sUSAGE\n");

my $key = $ARGV[5] or
    die("sUSAGE\n");

my $expected_value = $ARGV[6] or
    die("sUSAGE\n");

# strip quotes, just in case the shell didn't

$expected_value =~ s|\"?([^\"]*)\"?|$1|;


my $cache = new File::Cache( { cache_key => $cache_key, 
			       namespace => $namespace, 
			       username => $username, 
			       implementation => $implementation, 
			       cache_depth => $cache_depth } ) or
    die("Couldn't create cache");

my $value = $cache->get($key) or
    die("Couldn't get object at $key");

$value eq $expected_value or
    die("value $value not equal to $expected_value");

exit(0);


