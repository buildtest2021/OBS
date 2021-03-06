#
# Copyright (c) 2008 Klaas Freitag, Novell Inc.
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
# Module to talk to Hermes
#

package BSHermes;

use BSRPC;
use BSConfig;

use strict;

sub notify($$) {
  my ($type, $paramRef ) = @_;

  return unless $BSConfig::hermesserver;

  my @args = ( "rm=notify" );

  $type = "UNKNOWN" unless $type;
  # prepend something BS specific
  my $prefix = $BSConfig::hermesnamespace || "OBS";
  $type =  "${prefix}_$type";

  push @args, "type=$type";

  if ($paramRef) {
    for my $key (sort keys %$paramRef) {
      next if ref $paramRef->{$key};
      push @args, "$key=$paramRef->{$key}";
    }
  }

  my $hermesuri = "$BSConfig::hermesserver/index.cgi";

  print STDERR "Notifying hermes at $hermesuri: <" . join( ', ', @args ) . ">\n";

  my $param = {
    'uri' => $hermesuri,
    'timeout' => 60,
  };
  eval {
    BSRPC::rpc( $param, undef, @args );
  };
  warn("Hermes: $@") if $@;
}

1;
