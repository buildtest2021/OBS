#
# Copyright (c) 2006, 2007 Michael Schroeder, Novell Inc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program (see the file COPYING); if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
#
################################################################
#
# implementation of state change watchers. Can watch for file
# changes, RPC results, and file download data. Handle with care.
#

package BSWatcher;

use BSServer;
use BSServerEvents;
use BSRPC;
use BSEvents;
use BSHTTP;
use POSIX;
use Socket;
use Symbol;
use XML::Structured;
use Data::Dumper;
use MIME::Base64;

use strict;

my %hostlookupcache;
my %cookiestore;        # our session store to keep iChain fast
my $tossl;

sub import {
  if (grep {$_ eq ':https'} @_) {
    require BSSSL;
    $tossl = \&BSSSL::tossl;
  }
}

sub reply {
  my $jev = $BSServerEvents::gev;
  return BSServer::reply(@_) unless $jev;
  deljob($jev) if @_ && defined($_[0]);
  return BSServerEvents::reply(@_);
}

sub reply_file {
  my $jev = $BSServerEvents::gev;
  return BSServer::reply_file(@_) unless $jev;
  deljob($jev);
  return BSServerEvents::reply_file(@_);
}

sub reply_cpio {
  my $jev = $BSServerEvents::gev;
  return BSServer::reply_cpio(@_) unless $jev;
  deljob($jev);
  return BSServerEvents::reply_cpio(@_);
}


###########################################################################
#
# job handling
#

#
# we add the following elements to the connection event:
# - redohandler
# - args
#

my %rpcs;
my %filewatchers;
my %filewatchers_s;
my $filewatchers_ev;
my $filewatchers_ev_active;

my %serializations;
my %serializations_waiting;

sub redo_request {
  my ($jev) = @_;
  local $BSServerEvents::gev = $jev;
  my $conf = $jev->{'conf'};
  eval {
    my @res = $jev->{'redohandler'}->(@{$jev->{'args'} || []});
    $conf->{'stdreply'}->(@res) if $conf->{'stdreply'};
    return;
  };
  print $@ if $@;
  BSServerEvents::reply_error($conf, $@) if $@;
}

sub deljob {
  my ($jev) = @_;
  print "deljob #$jev->{'id'}\n";
  for my $file (keys %filewatchers) {
    next unless grep {$_ == $jev} @{$filewatchers{$file}};
    @{$filewatchers{$file}} = grep {$_ != $jev} @{$filewatchers{$file}};
    if (!@{$filewatchers{$file}}) {
      delete $filewatchers{$file};
      delete $filewatchers_s{$file};
    }
  }
  if (!%filewatchers && $filewatchers_ev_active) {
    BSEvents::rem($filewatchers_ev);
    $filewatchers_ev_active = 0;
  }
  for my $uri (keys %rpcs) {
    my $ev = $rpcs{$uri};
    next unless $ev;
    next unless grep {$_ == $jev} @{$ev->{'joblist'}};
    @{$ev->{'joblist'}} = grep {$_ != $jev} @{$ev->{'joblist'}};
    if (!@{$ev->{'joblist'}}) {
      print "deljob: rpc $uri no longer needed\n";
      BSServerEvents::stream_close($ev, $ev->{'writeev'});
      delete $rpcs{$uri};
    }
  }
  for my $file (keys %serializations) {
    @{$serializations_waiting{$file}} = grep {$_ != $jev} @{$serializations_waiting{$file}};
    delete $serializations_waiting{$file} if $serializations_waiting{$file} && !@{$serializations_waiting{$file}};
    serialize_end({'file' => $file}) if $jev == $serializations{$file};
  }
}

sub rpc_error {
  my ($ev, $err) = @_;
  $ev->{'rpcstate'} = 'error';
  print "rpc_error: $err\n";
  my $uri = $ev->{'rpcuri'};
  delete $rpcs{$uri};
  close $ev->{'fd'} if $ev->{'fd'};
  delete $ev->{'fd'};
  for my $jev (@{$ev->{'joblist'} || []}) {
    $jev->{'rpcdone'} = $uri;
    $jev->{'rpcerror'} = $err;
    redo_request($jev);
    delete $jev->{'rpcdone'};
    delete $jev->{'rpcerror'};
  }
}

sub rpc_result {
  my ($ev, $res) = @_;
  $ev->{'rpcstate'} = 'done';
  my $uri = $ev->{'rpcuri'};
  print "got result for $uri\n";
  delete $rpcs{$uri};
  close $ev->{'fd'} if $ev->{'fd'};
  delete $ev->{'fd'};
  for my $jev (@{$ev->{'joblist'} || []}) {
    $jev->{'rpcdone'} = $uri;
    $jev->{'rpcresult'} = $res;
    redo_request($jev);
    delete $jev->{'rpcdone'};
    delete $jev->{'rpcresult'};
  }
}


###########################################################################
#
# file watching

sub filewatcher_handler {
  # print "filewatcher_handler\n";
  BSEvents::add($filewatchers_ev, 1);
  for my $file (sort keys %filewatchers) {
    next unless $filewatchers{$file};
    my @s = stat($file);
    my $s = @s ? "$s[9]/$s[7]/$s[1]" : "-/-/-";
    next if ($s eq $filewatchers_s{$file});
    print "file $file changed!\n";
    $filewatchers_s{$file} = $s;
    for my $jev (@{$filewatchers{$file}}) {
      redo_request($jev);
    }
  }
}

sub addfilewatcher {
  my ($file) = @_;

  my $jev = $BSServerEvents::gev;
  return unless $jev;
  $jev->{'closehandler'} = \&deljob;
  if ($filewatchers{$file}) {
    print "addfilewatcher to already watched $file\n";
    push @{$filewatchers{$file}}, $jev unless grep {$_ eq $jev} @{$filewatchers{$file}};
    return;
  }
  print "addfilewatcher $file\n";
  if (!$filewatchers_ev) {
    $filewatchers_ev = BSEvents::new('timeout', \&filewatcher_handler);
  }
  if (!$filewatchers_ev_active) {
    BSEvents::add($filewatchers_ev, 1);
    $filewatchers_ev_active = 1;
  }
  my @s = stat($file);
  my $s = @s ? "$s[9]/$s[7]/$s[1]" : "-/-/-";
  push @{$filewatchers{$file}}, $jev;
  $filewatchers_s{$file} = $s;
}

###########################################################################

sub serialize {
  my ($file) = @_;
  my $jev = $BSServerEvents::gev;
  die("unly supported in AJAX servers\n") unless $jev;
  if ($serializations{$file}) {
    if ($serializations{$file} != $jev) {
      print "adding to serialization queue of $file\n";
      push @{$serializations_waiting{$file}}, $jev unless grep {$_ eq $jev} @{$serializations_waiting{$file}};
      return undef;
    }
  } else {
    $serializations{$file} = $jev;
  }
  return {'file' => $file};
}

sub serialize_end {
  my ($ser) = @_;
  return unless $ser;
  my $file = $ser->{'file'};
  print "serialize_end for $file\n";
  delete $serializations{$file};
  my @waiting = @{$serializations_waiting{$file} || []};
  delete $serializations_waiting{$file};
  while (@waiting) {
    my $jev = shift @waiting;
    print "waking up $jev\n";
    redo_request($jev);
    if ($serializations{$file}) {
      push @{$serializations_waiting{$file}}, @waiting;
      last;
    }
  }
}

###########################################################################
#
# rpc_recv_stream_handler
#
# do chunk decoding and forward to next handler
# (should probably do this in BSServerEvents::stream_read_handler)
#
sub rpc_recv_stream_handler {
  my ($ev) = @_;
  my $rev = $ev->{'readev'};

  #print "rpc_recv_stream_handler\n";
  $ev->{'paused'} = 1;	# always need more bytes!
nextchunk:
  $ev->{'replbuf'} =~ s/^\r?\n//s;
  if ($ev->{'replbuf'} !~ /\r?\n/s) {
    return unless $rev->{'eof'};
    print "rpc_recv_stream_handler: premature EOF\n";
    BSServerEvents::stream_close($rev, $ev);
    return;
  }
  if ($ev->{'replbuf'} !~ /^([0-9a-fA-F]+)/) {
    print "rpc_recv_stream_handler: bad chunked data\n";
    BSServerEvents::stream_close($rev, $ev);
    return;
  }
  my $cl = hex($1);
  # print "rpc_recv_stream_handler: chunk len $cl\n";
  if ($cl < 0 || $cl >= 16000) {
    print "rpc_recv_stream_handler: illegal chunk size: $cl\n";
    BSServerEvents::stream_close($rev, $ev);
    return;
  }
  if ($cl == 0) {
    # wait till trailer is complete
    if ($ev->{'replbuf'} !~ /\n\r?\n/s) {
      return unless $rev->{'eof'};
      print "rpc_recv_stream_handler: premature EOF\n";
      BSServerEvents::stream_close($rev, $ev);
      return;
    }
    print "rpc_recv_stream_handler: chunk EOF\n";
    my $trailer = $ev->{'replbuf'};
    $trailer =~ s/^(.*?\r?\n)/\r\n/s;	# delete chunk header
    $trailer =~ s/\n\r?\n.*//s;		# delete stuff after trailer
    $trailer =~ s/\r$//s;
    $trailer = substr($trailer, 2) if $trailer ne '';
    $trailer .= "\r\n" if $trailer ne '';
    $ev->{'chunktrailer'} = $trailer;
    BSServerEvents::stream_close($rev, $ev);
    return;
  }
  $ev->{'replbuf'} =~ /^(.*?\r?\n)/s;
  if (length($1) + $cl > length($ev->{'replbuf'})) {
    return unless $rev->{'eof'};
    print "rpc_recv_stream_handler: premature EOF\n";
    BSServerEvents::stream_close($rev, $ev);
    return;
  }

  my $data = substr($ev->{'replbuf'}, length($1), $cl);
  my $nextoff = length($1) + $cl;
  
  # handler returns false: cannot consume now, try later
  return unless $ev->{'datahandler'}->($ev, $rev, $data);

  $ev->{'replbuf'} = substr($ev->{'replbuf'}, $nextoff);

  goto nextchunk if length($ev->{'replbuf'});

  if ($rev->{'eof'}) {
    print "rpc_recv_stream_handler: EOF\n";
    BSServerEvents::stream_close($rev, $ev);
  }
}

sub rpc_recv_unchunked_stream_handler {
  my ($ev) = @_;
  my $rev = $ev->{'readev'};

  #print "rpc_recv_unchunked_stream_handler\n";
  my $cl = $rev->{'contentlength'};
  $ev->{'paused'} = 1;	# always need more bytes!
  my $data = $ev->{'replbuf'};
  if (length($data) && $cl) {
    $data = substr($data, 0, $cl) if $cl < length($data);
    $cl -= length($data);
    #print "feeding data handler...\n";
    return unless $ev->{'datahandler'}->($ev, $rev, $data);
    $rev->{'contentlength'} = $cl;
    $ev->{'replbuf'} = '';
  }
  if ($rev->{'eof'} || !$cl) {
    print "rpc_recv_unchunked_stream_handler: EOF\n";
    $ev->{'chunktrailer'} = '';
    BSServerEvents::stream_close($rev, $ev);
  }
}

###########################################################################
#
#  forward receiver methods
#

sub rpc_adddata {
  my ($jev, $data) = @_;

  $data = sprintf("%X\r\n", length($data)).$data."\r\n";
  $jev->{'replbuf'} .= $data;
  if ($jev->{'paused'}) {
    delete $jev->{'paused'};
    BSEvents::add($jev);
  }
}

sub rpc_recv_forward_close_handler {
  my ($ev) = @_;
  #print "rpc_recv_forward_close_handler\n";
  my $rev = $ev->{'readev'};
  my @jobs = @{$rev->{'joblist'} || []};
  my $trailer = $ev->{'chunktrailer'} || '';
  for my $jev (@jobs) {
    $jev->{'replbuf'} .= "0\r\n$trailer\r\n";
    if ($jev->{'paused'}) {
      delete $jev->{'paused'};
      BSEvents::add($jev);
    }
    $jev->{'readev'} = {'eof' => 1, 'rpcuri' => $rev->{'rpcuri'}};
  }
  # the stream rpc is finished!
  print "stream rpc $rev->{'rpcuri'} is finished!\n";
  delete $rpcs{$rev->{'rpcuri'}};
}

sub rpc_recv_forward_data_handler {
  my ($ev, $rev, $data) = @_;

  my @jobs = @{$rev->{'joblist'} || []};
  my @stay = ();
  my @leave = ();

  for my $jev (@jobs) {
    if (length($jev->{'replbuf'}) >= 16384) {
      push @stay, $jev;
    } else {
      push @leave, $jev;
    }
  }
  if ($rev->{'eof'}) {
    # must not hold back data at eof
    @leave = @jobs;
    @stay = ();
  }
  if (!@leave) {
    # too full! wait till there is more room
    #print "stay=".@stay.", leave=".@leave.", blocking\n";
    return 0;
  }

  # advance our uri
  my $newuri = $rev->{'rpcuri'};
  my $newpos = length($data);
  if ($newuri =~ /start=(\d+)/) {
    $newpos += $1;
    $newuri =~ s/start=\d+/start=$newpos/;
  } elsif ($newuri =~ /\?/) {
    $newuri .= '&' unless $newuri =~ /\?$/;
    $newuri .= "start=$newpos";
  } else {
    $newuri .= "?start=$newpos";
  }
  # mark it as in progress so that only other calls in progress can join
  $newuri .= "&inprogress" unless $newuri =~ /\&inprogress$/;

  #print "stay=".@stay.", leave=".@leave.", newpos=$newpos\n";

  if ($rpcs{$newuri}) {
    my $nev = $rpcs{$newuri};
    print "joining ".@leave." jobs with $newuri!\n";
    for my $jev (@leave) {
      push @{$nev->{'joblist'}}, $jev unless grep {$_ == $jev} @{$nev->{'joblist'}};
      $jev->{'readev'} = $nev;
    }
    $rev->{'joblist'} = [ @stay ];
    for my $jev (@leave) {
      rpc_adddata($jev, $data);
    }
    if (!@stay) {
      BSServerEvents::stream_close($rev, $ev);
    }
    # too full! wait till there is more room
    return 0;
  }

  my $olduri = $rev->{'rpcuri'};
  $rpcs{$newuri} = $rev;
  delete $rpcs{$olduri};
  $rev->{'rpcuri'} = $newuri;

  if (@stay) {
    # worst case: split of
    $rev->{'joblist'} = [ @leave ];
    print "splitting ".@stay." jobs from $newuri!\n";
    # put old output event on hold
    for my $jev (@stay) {
      delete $jev->{'readev'};
      if (!$jev->{'paused'}) {
        BSEvents::rem($jev);
      }
      delete $jev->{'paused'};
    }
    # this is scary
    $olduri =~ s/\&inprogress$//;
    eval {
      local $BSServerEvents::gev = $stay[0];
      my $param = {
	'uri' => $olduri,
	'verbatim_uri' => 1,
	'joinable' => 1,
      };
      rpc($param);
      die("could not restart rpc\n") unless $rpcs{$olduri};
    };
    if ($@ || !$rpcs{$olduri}) {
      # terminate all old rpcs
      my $err = $@ || "internal error\n";
      $err =~ s/\n$//s;
      warn("$err\n");
      for my $jev (@stay) {
	if ($jev->{'streaming'}) {
	  # can't do much here, sorry
	  BSServerEvents::reply_error($jev->{'conf'}, $err);
	  next;
	}
	$jev->{'rpcdone'} = $olduri;
	$jev->{'rpcerror'} = $err;
	redo_request($jev);
	delete $jev->{'rpcdone'};
	delete $jev->{'rpcerror'};
      }
    } else {
      my $nev = $rpcs{$olduri};
      for my $jev (@stay) {
        push @{$nev->{'joblist'}}, $jev unless grep {$_ == $jev} @{$nev->{'joblist'}};
      }
    }
  }

  for my $jev (@leave) {
    rpc_adddata($jev, $data);
  }

  return 1;
}

sub rpc_recv_forward_setup {
  my ($jev, $ev, @args) = @_;
  if (!$jev->{'streaming'}) {
     local $BSServerEvents::gev = $jev;
     BSServerEvents::reply(undef, @args);
     BSEvents::rem($jev);
     $jev->{'streaming'} = 1;
     delete $jev->{'timeouthandler'};
  }
  $jev->{'handler'} = \&BSServerEvents::stream_write_handler;
  $jev->{'readev'} = $ev;
  if (length($jev->{'replbuf'})) {
    delete $jev->{'paused'};
    BSEvents::add($jev, 0);
  } else {
    $jev->{'paused'} = 1;
  }
}

sub rpc_recv_forward {
  my ($ev, $chunked, $data, @args) = @_;

  push @args, 'Transfer-Encoding: chunked';
  unshift @args, 'Content-Type: application/octet-stream' unless grep {/^content-type:/i} @args;
  $ev->{'rpcstate'} = 'streaming';
  $ev->{'replyargs'} = \@args;
  #
  # setup output streams for all jobs
  #
  for my $jev (@{$ev->{'joblist'} || []}) {
    rpc_recv_forward_setup($jev, $ev, @args);
  }

  #
  # setup input stream from rpc client
  #
  $ev->{'streaming'} = 1;
  my $wev = BSEvents::new('always');
  # print "new rpc input stream $ev $wev\n";
  $wev->{'replbuf'} = $data;
  $wev->{'readev'} = $ev;
  $ev->{'writeev'} = $wev;
  if ($chunked) {
    $wev->{'handler'} = \&rpc_recv_stream_handler;
  } else {
    $wev->{'handler'} = \&rpc_recv_unchunked_stream_handler;
  }
  $wev->{'datahandler'} = \&rpc_recv_forward_data_handler;
  $wev->{'closehandler'} = \&rpc_recv_forward_close_handler;
  $ev->{'handler'} = \&BSServerEvents::stream_read_handler;
  BSEvents::add($ev);
  BSEvents::add($wev);	# do this last
}

###########################################################################
#
#  file receiver methods
#

sub rpc_recv_file_data_handler {
  my ($ev, $rev, $data) = @_;
  if ((syswrite($ev->{'fd'}, $data) || 0) != length($data)) {
    print "rpc_recv_file_data_handler: write error\n";
    BSServerEvents::stream_close($rev, $ev);
    return 0;
  }
  return 1;
}

sub rpc_recv_file_close_handler {
  my ($ev) = @_;
  print "rpc_recv_file_close_handler\n";
  my $rev = $ev->{'readev'};
  my $res = {};
  if ($ev->{'fd'}) {
    my @s = stat($ev->{'fd'});
    $res->{'size'} = $s[7] if @s;
    close $ev->{'fd'};
  }
  delete $ev->{'fd'};
  my $trailer = $ev->{'chunktrailer'} || '';
  rpc_result($rev, $res);
  print "file rpc $rev->{'rpcuri'} is finished!\n";
  delete $rpcs{$rev->{'rpcuri'}};
}

sub rpc_recv_file {
  my ($ev, $chunked, $data, $filename) = @_;
  print "rpc_recv_file $filename\n";
  my $fd = gensym;
  if (!open($fd, '>', $filename)) {
    rpc_error($ev, "$filename: $!");
    return;
  }
  my $wev = BSEvents::new('always');
  $wev->{'replbuf'} = $data;
  $wev->{'readev'} = $ev;
  $ev->{'writeev'} = $wev;
  $wev->{'fd'} = $fd;
  if ($chunked) {
    $wev->{'handler'} = \&rpc_recv_stream_handler;
  } else {
    $wev->{'handler'} = \&rpc_recv_unchunked_stream_handler;
  }
  $wev->{'datahandler'} = \&rpc_recv_file_data_handler;
  $wev->{'closehandler'} = \&rpc_recv_file_close_handler;
  $ev->{'handler'} = \&BSServerEvents::stream_read_handler;
  BSEvents::add($ev);
  BSEvents::add($wev);	# do this last
}


###########################################################################
#
#  rpc methods
#

sub rpc_recv_handler {
  my ($ev) = @_;
  my $cs = 1024;
  # needs to be bigger than the ssl package size...
  $cs = 16384 if $ev->{'param'} && $ev->{'param'}->{'proto'} && $ev->{'param'}->{'proto'} eq 'https';
  my $r = sysread($ev->{'fd'}, $ev->{'recvbuf'}, $cs, length($ev->{'recvbuf'}));
  if (!defined($r)) {
    if ($! == POSIX::EINTR || $! == POSIX::EWOULDBLOCK) {
      BSEvents::add($ev);
      return;
    }
    rpc_error($ev, "read error from $ev->{'rpcdest'}: $!");
    return;
  }
  my $ans;
  $ev->{'rpceof'} = 1 if !$r;
  $ans = $ev->{'recvbuf'};

  if ($ev->{'_need'}) {
    #shortcut for need more bytes...
    if (!$ev->{'rpceof'} && length($ans) < $ev->{'_need'}) {
      printf "... %d/%d\n", length($ans), $ev->{'_need'};
      BSEvents::add($ev);
      return;
    }
    delete $ev->{'_need'};
  }

  if ($ans !~ /\n\r?\n/s) {
    if ($ev->{'rpceof'}) {
      rpc_error($ev, "EOF from $ev->{'rpcdest'}");
      return;
    }
    BSEvents::add($ev);
    return;
  }
  if ($ans !~ s/^HTTP\/\d+?\.\d+?\s+?(\d+[^\r\n]*)/Status: $1/s) {
    rpc_error($ev, "bad answer from $ev->{'rpcdest'}");
    return;
  }
  my $status = $1;
  $ans =~ /^(.*?)\n\r?\n(.*)$/s;
  my $headers = $1;
  $ans = $2;
  if ($status !~ /^200[^\d]/) {
    rpc_error($ev, "remote error: $status");
    return;
  }
  my %headers;
  BSHTTP::gethead(\%headers, $headers);
  my $param = $ev->{'param'};
  if ($headers{'set-cookie'} && $param->{'uri'}) {
    my @cookie = split(',', $headers{'set-cookie'});
    s/;.*// for @cookie;
    if ($param->{'uri'} =~ /((:?https?):\/\/(?:([^\/]*)\@)?(?:[^\/:]+)(?::\d+)?)(?:\/.*)$/) {
      my %cookie = map {$_ => 1} @cookie;
      push @cookie, grep {!$cookie{$_}} @{$cookiestore{$1} || []};
      splice(@cookie, 10) if @cookie > 10;
      $cookiestore{$1} = \@cookie;
    }
  }

  my $cl = $headers{'content-length'};
  my $chunked = $headers{'transfer-encoding'} && lc($headers{'transfer-encoding'}) eq 'chunked' ? 1 : 0;

  # we assume that all chunked data is streaming
  if ($param->{'receiver'} || $chunked) {
    $ev->{'contentlength'} = $cl if !$chunked && defined($cl);
    if ($param->{'receiver'} && $param->{'receiver'} == \&BSHTTP::file_receiver) {
      rpc_recv_file($ev, $chunked, $ans, $param->{'filename'});
    } else {
      my $ct = $headers{'content-type'} || 'application/octet-stream';
      rpc_recv_forward($ev, $chunked, $ans, "Content-Type: $ct");
    }
    return;
  }

  if ($ev->{'rpceof'} && $cl && length($ans) < $cl) {
    rpc_error($ev, "EOF from $ev->{'rpcdest'}");
    return;
  }
  if (!$ev->{'rpceof'} && (!defined($cl) || length($ans) < $cl)) {
    $ev->{'_need'} = length($headers) + $cl if defined $cl;
    BSEvents::add($ev);
    return;
  }
  $ans = substr($ans, 0, $cl) if defined $cl;
  rpc_result($ev, $ans);
}

sub rpc_send_handler {
  my ($ev) = @_;
  my $l = length($ev->{'sendbuf'});
  return unless $l;
  $l = 4096 if $l > 4096;
  my $r = syswrite($ev->{'fd'}, $ev->{'sendbuf'}, $l);
  if (!defined($r)) {
    if ($! == POSIX::EINTR || $! == POSIX::EWOULDBLOCK) {
      BSEvents::add($ev);
      return;
    }
    rpc_error($ev, "write error to $ev->{'rpcdest'}: $!");
    return;
  }
  if ($r != length($ev->{'sendbuf'})) {
    $ev->{'sendbuf'} = substr($ev->{'sendbuf'}, $r) if $r;
    BSEvents::add($ev);
    return;
  }
  # print "done sending to $ev->{'rpcdest'}, now receiving\n";
  delete $ev->{'sendbuf'};
  $ev->{'recvbuf'} = '';
  $ev->{'type'} = 'read';
  $ev->{'rpcstate'} = 'receiving';
  $ev->{'handler'} = \&rpc_recv_handler;
  BSEvents::add($ev);
}

sub rpc_connect_timeout {
  my ($ev) = @_;
  rpc_error($ev, "connect to $ev->{'rpcdest'}: timeout");
}

sub rpc_connect_handler {
  my ($ev) = @_;
  my $err;
  #print "rpc_connect_handler\n";
  $err = getsockopt($ev->{'fd'}, SOL_SOCKET, SO_ERROR);
  if (!defined($err)) {
    $err = "getsockopt: $!";
  } else {
    $err = unpack("I", $err);
    if ($err == 0 || $err == POSIX::EISCONN) {
      $err = undef;
    } else {
      $! = $err;
      $err = "connect to $ev->{'rpcdest'}: $!";
    }
  }
  if ($err) {
    rpc_error($ev, $err);
    return;
  }
  #print "rpc_connect_handler: connected!\n";
  if ($ev->{'param'} && $ev->{'param'}->{'proto'} && $ev->{'param'}->{'proto'} eq 'https') {
    print "switching to https\n";
    fcntl($ev->{'fd'}, F_SETFL, 0); 	# in danger honor...
    eval {
      $ev->{'param'}->{'https'}->($ev->{'fd'});
    };
    #fcntl($ev->{'fd'}, F_SETFL, O_NONBLOCK);
    if ($@) {
      $err = $@;
      $err =~ s/\n$//s;
      rpc_error($ev, $err);
      return;
    }
  }
  $ev->{'rpcstate'} = 'sending';
  delete $ev->{'timeouthandler'};
  $ev->{'handler'} = \&rpc_send_handler;
  BSEvents::add($ev, 0);
}

my $tcpproto = getprotobyname('tcp');

sub rpc {
  my ($uri, $xmlargs, @args) = @_;

  my $jev = $BSServerEvents::gev;
  return BSRPC::rpc($uri, $xmlargs, @args) unless $jev;
  my @xhdrs;
  my $param = {'uri' => $uri};
  if (ref($uri) eq 'HASH') {
    $param = $uri;
    $uri = $param->{'uri'};
    @xhdrs = @{$param->{'headers'} || []};
  }
  $uri = BSRPC::urlencode($uri) unless $param->{'verbatim_uri'};
  if (@args) {
    for (@args) {
      s/([\000-\040<>\"#&\+=%[\177-\377])/sprintf("%%%02X",ord($1))/sge;
      s/%3D/=/;
    }
    if ($uri =~ /\?/) {
      $uri .= '&'.join('&', @args); 
    } else {
      $uri .= '?'.join('&', @args); 
    }
  }

  my $rpcuri = $uri;
  $rpcuri .= ";$jev->{'id'}" unless $param->{'joinable'};

  if ($jev->{'rpcdone'} && $rpcuri eq $jev->{'rpcdone'}) {
    die("$jev->{'rpcerror'}\n") if exists $jev->{'rpcerror'};
    my $ans = $jev->{'rpcresult'};
    if ($xmlargs) {
      die("answer is not xml\n") if $ans !~ /<.*?>/s;
      return XMLin($xmlargs, $ans);
    }
    return $ans;
  }

  $jev->{'closehandler'} = \&deljob;
  if ($rpcs{$rpcuri}) {
    my $ev = $rpcs{$rpcuri};
    print "rpc $rpcuri already in progress, ".@{$ev->{'joblist'} || []}." entries\n";
    return undef if grep {$_ == $jev} @{$ev->{'joblist'}};
    if ($ev->{'rpcstate'} eq 'streaming') {
      # this seams wrong, cannot join a living stream!
      # (we're lucky to change the url when streaming...)
      print "joining stream\n";
      rpc_recv_forward_setup($jev, $ev, @{$ev->{'replyargs'} || []});
    }
    push @{$ev->{'joblist'}}, $jev;
    return undef;
  }

  # new rpc, create rpc event
  die("bad uri: $uri\n") unless $uri =~ /^(https?):\/\/(?:([^\/\@]*)\@)?([^\/:]+)(:\d+)?(\/.*)$/;
  my ($proto, $auth, $host, $port, $path) = ($1, $2, $3, $4, $5);
  my $hostport = $port ? "$host$port" : $host;
  $port = substr($port || ($proto eq 'http' ? ":80" : ":443"), 1);
  if (!$hostlookupcache{$host}) {
    # should do this async, but that's hard to do in perl
    my $hostaddr = inet_aton($host);
    die("unknown host '$host'\n") unless $hostaddr;
    $hostlookupcache{$host} = $hostaddr;
  }
  unshift @xhdrs, "User-Agent: $BSRPC::useragent" unless !defined($BSRPC::useragent) || grep {/^user-agent:/si} @xhdrs;
  unshift @xhdrs, "Host: $hostport" unless grep {/^host:/si} @xhdrs;;

  if (defined $auth) {
    $auth =~ s/%([a-fA-F0-9]{2})/chr(hex($1))/ge unless $param->{'verbatim_uri'};
    $auth =~ s/%([a-fA-F0-9]{2})/chr(hex($1))/ge;
    unshift @xhdrs, "Authorization: Basic ".encode_base64($auth, '');
  }
  if ($proto eq 'https') {
    $param->{'proto'} = 'https';
    $param->{'https'} ||= $tossl;
    die("https not supported\n") unless $param->{'https'};
  }
  if (%cookiestore) {
    if ($uri =~ /((:?https?):\/\/(?:([^\/]*)\@)?(?:[^\/:]+)(?::\d+)?)(?:\/.*)$/) {
      push @xhdrs, map {"Cookie: $_"} @{$cookiestore{$1} || []};
    }
  }
  
  my $req = "GET $path HTTP/1.1\r\n".join("\r\n", @xhdrs)."\r\n\r\n";
  my $fd = gensym;
  socket($fd, PF_INET, SOCK_STREAM, $tcpproto) || die("socket: $!\n");
  fcntl($fd, F_SETFL,O_NONBLOCK);
  my $ev = BSEvents::new('write', \&rpc_send_handler);
  $ev->{'fd'} = $fd;
  $ev->{'sendbuf'} = $req;
  $ev->{'rpcdest'} = "$host:$port";
  $ev->{'rpcuri'} = $rpcuri;
  $ev->{'rpcstate'} = 'connecting';
  $ev->{'param'} = $param;
  push @{$ev->{'joblist'}}, $jev;
  $rpcs{$rpcuri} = $ev;
  print "new rpc $uri\n";
  if (!connect($fd, sockaddr_in($port, $hostlookupcache{$host}))) {
    if ($! == POSIX::EINPROGRESS) {
      $ev->{'handler'} = \&rpc_connect_handler;
      $ev->{'timeouthandler'} = \&rpc_connect_timeout;
      BSEvents::add($ev, 60);	# 60s connect timeout
      return undef;
    }
    close $ev->{'fd'};
    delete $ev->{'fd'};
    delete $rpcs{$rpcuri};
    die("connect to $host:$port: $!\n");
  }
  $ev->{'rpcstate'} = 'sending';
  BSEvents::add($ev);
  return undef;
}

sub getstatus {
  my $ret = {};
  for my $filename (sort keys %filewatchers) {
    my $fw = {'filename' => $filename, 'state' => $filewatchers_s{$filename}};
    for my $jev (@{$filewatchers{$filename}}) {
      my $j = {'ev' => $jev->{'id'}};
      $j->{'fd'} = fileno(*{$jev->{'fd'}}) if $jev->{'fd'};
      push @{$fw->{'job'}}, $j;
    }
    push @{$ret->{'watcher'}}, $fw;
  }
  for my $uri (sort keys %rpcs) {
    my $ev = $rpcs{$uri};
    my $r = {'uri' => $uri, 'ev' => $ev->{'id'}};
    $r->{'fd'} = fileno(*{$ev->{'fd'}}) if $ev->{'fd'};
    $r->{'state'} = $ev->{'rpcstate'} if $ev->{'rpcstate'};
    for my $jev (@{$ev->{'joblist'} || []}) {
      my $j = {'ev' => $jev->{'id'}};
      $j->{'fd'} = fileno(*{$jev->{'fd'}}) if $jev->{'fd'};
      push @{$r->{'job'}}, $j;
    }
    push @{$ret->{'rpc'}}, $r;
  }
  return $ret;
}

sub addhandler {
  my ($f, @args) = @_;
  my $jev = $BSServerEvents::gev;
  $jev->{'redohandler'} = $f;
  $jev->{'args'} = [ @args ];
  return $f->(@args);
}

sub compile_dispatches {
  my ($dispatches, $verifyers) = @_;
  return BSServer::compile_dispatches($dispatches, $verifyers, \&addhandler);
}

1;
