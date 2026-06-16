#!/usr/bin/perl

# Suite 03: Basic GET Request Tests
# Tests: GET-001 through GET-006

use warnings;
use strict;

use Test::More;
use File::Basename qw(dirname);
use lib dirname(__FILE__) . '/lib';
use Test::HTTPLite;
use Getopt::Long;

plan tests => 6;

my %opts;
GetOptions(\%opts, 'listen-port=i', 'upstream-port=i');

my $t = Test::HTTPLite->new();
my ($listen_port, $upstream_port) = $t->ports(2);
$listen_port   = $opts{'listen-port'}   // $listen_port;
$upstream_port = $opts{'upstream-port'} // $upstream_port;

$t->run_daemon(\&Test::HTTPLite::echo_daemon, $upstream_port);
$t->waitforsocket("127.0.0.1:$upstream_port");

$t->write_config($listen_port, 10000, "127.0.0.1:${upstream_port}:5");
$t->run($listen_port);

die "nginx failed to start on port $listen_port"
    unless $t->waitforsocket("127.0.0.1:$listen_port", 5);

###############################################################################
# A bodyless request (GET, or POST with Content-Length: 0) ends exactly at the
# header separator "\r\n\r\n". The request splitter must still parse and
# forward it even though no request bytes remain after the separator.
# Previously the splitter's loop exited the instant the read slab was drained,
# so the staged headers were never parsed and the client hung with an empty
# response. These tests guard that fix.
###############################################################################

###############################################################################
# GET-001: Single GET request
###############################################################################

{
    my $resp = $t->http(
        "GET / HTTP/1.1\r\n"
        . "Host: 127.0.0.1:$listen_port\r\n"
        . "User-Agent: httplite-test/1.0\r\n"
        . "Accept: */*\r\n"
        . "Connection: keep-alive\r\n"
        . "\r\n",
        timeout => 2, nresponses => 1,
    );
    like($resp, qr/HTTP\/1\.[01] 200/, 'GET-001: single GET returns 200');
}

###############################################################################
# GET-002: GET with additional standard headers
###############################################################################

{
    my $resp = $t->http(
        "GET / HTTP/1.1\r\n"
        . "Host: 127.0.0.1:$listen_port\r\n"
        . "User-Agent: httplite-test/1.0\r\n"
        . "Accept: */*\r\n"
        . "Cache-Control: no-cache\r\n"
        . "Connection: keep-alive\r\n"
        . "\r\n",
        timeout => 2, nresponses => 1,
    );
    like($resp, qr/HTTP\/1\.[01] 200/,
        'GET-002: GET with standard headers returns 200');
}

###############################################################################
# GET-003: GET with a query string in the request target
###############################################################################

{
    my $resp = $t->http(
        "GET /search?q=httplite&page=2 HTTP/1.1\r\n"
        . "Host: 127.0.0.1:$listen_port\r\n"
        . "Accept: */*\r\n"
        . "Connection: keep-alive\r\n"
        . "\r\n",
        timeout => 2, nresponses => 1,
    );
    like($resp, qr/HTTP\/1\.[01] 200/,
        'GET-003: GET with query string returns 200');
}

###############################################################################
# GET-004: Two GETs pipelined on one connection
# Both requests arrive in a single read; the splitter must hand off the first
# and then parse the second from the same buffer.
###############################################################################

{
    my $resp = $t->http(
        "GET /a HTTP/1.1\r\n"
        . "Host: 127.0.0.1:$listen_port\r\n"
        . "Connection: keep-alive\r\n"
        . "\r\n"
        . "GET /b HTTP/1.1\r\n"
        . "Host: 127.0.0.1:$listen_port\r\n"
        . "Connection: keep-alive\r\n"
        . "\r\n",
        timeout => 3, nresponses => 2,
    );
    my $count = () = $resp =~ /HTTP\/1\.[01] 200/g;
    is($count, 2, 'GET-004: two pipelined GETs both return 200');
}

###############################################################################
# GET-005: Upstream echo body forwarded to client (POST round-trip)
# Confirms the response path itself carries a body back to the client.
###############################################################################

{
    my $resp = $t->http(
        "POST / HTTP/1.1\r\n"
        . "Host: 127.0.0.1:$listen_port\r\n"
        . "User-Agent: httplite-test/1.0\r\n"
        . "Accept: */*\r\n"
        . "Content-Length: 11\r\n"
        . "Content-Type: application/x-www-form-urlencoded\r\n"
        . "Connection: keep-alive\r\n"
        . "\r\n"
        . "testecho123",
        timeout => 2, nresponses => 1,
    );
    like($resp, qr/testecho123/,
        'GET-005: upstream echo body forwarded to client');
}

###############################################################################
# GET-006: 10 sequential GETs on separate connections
###############################################################################

{
    my $all_ok = 1;
    for my $i (1..10) {
        my $resp = $t->http(
            "GET / HTTP/1.1\r\n"
            . "Host: 127.0.0.1:$listen_port\r\n"
            . "User-Agent: httplite-test/1.0\r\n"
            . "Accept: */*\r\n"
            . "Connection: keep-alive\r\n"
            . "\r\n",
            timeout => 2, nresponses => 1,
        );
        if (!defined $resp || $resp !~ /HTTP\/1\.[01] 200/) {
            $all_ok = 0;
            diag("Failed at request #$i");
            last;
        }
    }
    ok($all_ok, 'GET-006: 10 sequential GETs all return 200');
}
