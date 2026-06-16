#!/usr/bin/perl

# Suite 13: Bodyless status responses (204 / 304)
#
# 204 No Content and 304 Not Modified carry no body (RFC 9110) and routinely
# omit Content-Length. The response-framing path must accept them on the
# status code alone and forward them unchanged, NOT turn them into a 503.
#
# Requests are POSTs with a non-empty body: GET response forwarding is
# independently broken (see BUG-GETRESP in 03_get.t), and a Content-Length: 0
# request does not currently round-trip either. The request body content is
# irrelevant — the backend routes on the request path (/204, /304) — it just
# has to be a request shape this module actually forwards a response for.
# Tests: STATUS-001 through STATUS-004

use warnings;
use strict;

use Test::More;
use File::Basename qw(dirname);
use lib dirname(__FILE__) . '/lib';
use Test::HTTPLite;
use Getopt::Long;

plan tests => 4;

my %opts;
GetOptions(\%opts, 'listen-port=i', 'upstream-port=i');

my $t = Test::HTTPLite->new();
my ($listen_port, $upstream_port) = $t->ports(2);
$listen_port   = $opts{'listen-port'}   // $listen_port;
$upstream_port = $opts{'upstream-port'} // $upstream_port;

# Backend that replies 204 for /204 and 304 for /304, both bodyless and
# without a Content-Length header.
$t->run_daemon(\&Test::HTTPLite::status_daemon, $upstream_port);
$t->waitforsocket("127.0.0.1:$upstream_port");

$t->write_config($listen_port, 10000, "127.0.0.1:${upstream_port}:5");
$t->run($listen_port);

die "nginx failed to start on port $listen_port"
    unless $t->waitforsocket("127.0.0.1:$listen_port", 5);

# Build a POST that routes to $path on the backend, carrying a small body so
# the request side forwards normally.
sub post_to {
    my ($path) = @_;
    return "POST $path HTTP/1.1\r\n"
         . "Host: 127.0.0.1\r\n"
         . "Content-Length: 4\r\n"
         . "Connection: keep-alive\r\n"
         . "\r\n"
         . "ping";
}

###############################################################################
# STATUS-001: 204 No Content is forwarded with its status line
###############################################################################

{
    my $resp = $t->http(post_to('/204'), timeout => 5, nresponses => 1);
    like($resp, qr{^HTTP/1\.[01] 204\b},
        'STATUS-001: 204 response forwarded (not a 503)');
}

###############################################################################
# STATUS-002: 304 Not Modified is forwarded with its status line
###############################################################################

{
    my $resp = $t->http(post_to('/304'), timeout => 5, nresponses => 1);
    like($resp, qr{^HTTP/1\.[01] 304\b},
        'STATUS-002: 304 response forwarded (not a 503)');
}

###############################################################################
# STATUS-003: bodyless response is not rewritten into a 503
###############################################################################

{
    my $resp = $t->http(post_to('/204'), timeout => 5, nresponses => 1);
    unlike($resp, qr{^HTTP/1\.[01] 503\b},
        'STATUS-003: bodyless response is not turned into a 503');
}

###############################################################################
# STATUS-004: two bodyless responses framed back-to-back on one connection
#
# Frames are demuxed by status code (no Content-Length), so a second request
# on the same keepalive connection must still get its own complete response.
###############################################################################

{
    my $resp = $t->http(post_to('/204') . post_to('/304'),
        timeout => 5, nresponses => 2);
    like($resp, qr{204 No Content.*304 Not Modified}s,
        'STATUS-004: both 204 and 304 framed in order on one connection');
}
