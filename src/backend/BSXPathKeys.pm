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
# Abstract data implementation for the BSXPath engine. Data is
# identified via keys.
#


package BSXPathKeys;

use BSXPath;
use Data::Dumper;

use strict;

#
# needs:
#   db->values($path)       -> array of values;
#   db->keys($path, $value) -> array of keys;
#   db->fetch($key)         -> data;
#


#
# node types:
#
# value defined
#     -> concrete node element
#        keys/other must also be set, define value set
#
# keys defined
#     -> abstract node element
#        limited to keys
#
# all other
#     -> abstract node element, unlimited
#




sub node {
  my ($db, $path) = @_;
  my $v = bless {};
  $v->{'db'} = $db;
  $v->{'path'} = $path;
  return $v;
}

sub selectpath {
  my ($v, $path) = @_;
  $v = [ $v ] unless ref($v) eq 'ARRAY';
  my @v = @$v;
  my $c;
  while(1) {
    last if !defined($path) || $path eq '';
    ($c, $path) = split('/', $path, 2);
    for my $vv (splice(@v)) {
      next unless ref($vv) eq 'HASH';
      $vv = $vv->{$c};
      next unless defined($vv);
      push @v, ref($vv) eq 'ARRAY' ? @$vv : $vv;
    }
  }
  return @v;
}

sub value {
  my ($self) = @_;
  my @v;
  if (exists($self->{'value'})) {
    return [ $self->{'value'} ];	# hmm, what about other?
  }
  my $db = $self->{'db'};
  my $path = $self->{'path'};
  if (!exists($self->{'keys'})) {
    if (defined($path)) {
      push @v, $db->values($path);
    } else {
      push @v, $db->keys();
    }
  } else {
    for my $k (@{$self->{'keys'}}) {
      my $v = $db->fetch($k);
      next unless defined $v;
      push @v, selectpath($v, $path);
    }
  }
  return \@v;
}

sub step {
  my ($self, $c) = @_;
  return [] if exists $self->{'value'};	# can't step concrete value
  my $v = bless {};
  $v->{'db'} = $self->{'db'};
  $v->{'keys'} = $self->{'keys'} if $self->{'keys'};
  if ($self->{'path'} eq '') {
    $v->{'path'} = "$c";
  } else {
    $v->{'path'} = "$self->{'path'}/$c";
  }
  return $v;
}

sub toconcrete {
  my ($self) = @_;
  my $vv = bless {};
  $vv->{'db'} = $self->{'db'};
  if ($self->{'keys'}) {
    $vv->{'keys'} = $self->{'keys'};
    $vv->{'value'} = 'true';
    $vv->{'other'} = '';
  } else {
    $vv->{'keys'} = [];
    $vv->{'value'} = '';
    $vv->{'other'} = 'true';
  }
  return $vv;
}

sub boolop {
  my ($self, $v1, $v2, $op, $negpol) = @_;
  if (ref($v1) ne ref($self) && ref($v2) ne ref($self)) {
    return $op->($v1, $v2) ? 'true' : '';
  }
  #print "boolop ".Dumper($v1).Dumper($v2)."---\n";
  #print "negated!\n" if $negpol;
  if (ref($v1) eq ref($self) && ref($v2) eq ref($self)) {
    $v1 = toconcrete($v1) unless exists $v1->{'value'};
    $v2 = toconcrete($v2) unless exists $v2->{'value'};
    my $v = bless {};
    $v->{'db'} = $v1->{'db'};
    my @k;
    my %k1 = map {$_ => 1} @{$v1->{'keys'}};
    my %k2 = map {$_ => 1} @{$v2->{'keys'}};
    if ($op->($v1->{'other'}, $v2->{'other'})) {
      push @k, grep {$k2{$_}} @{$v1->{'keys'}} if !$op->($v1->{'value'}, $v2->{'value'});
      push @k, grep {!$k2{$_}} @{$v1->{'keys'}} if !$op->($v1->{'value'}, $v2->{'other'});
      push @k, grep {!$k1{$_}} @{$v2->{'keys'}} if !$op->($v1->{'other'}, $v2->{'value'});
      $v->{'value'} = '';
      $v->{'other'} = 'true';
    } else {
      push @k, grep {$k2{$_}} @{$v1->{'keys'}} if $op->($v1->{'value'}, $v2->{'value'});
      push @k, grep {!$k2{$_}} @{$v1->{'keys'}} if $op->($v1->{'value'}, $v2->{'other'});
      push @k, grep {!$k1{$_}} @{$v2->{'keys'}} if $op->($v1->{'other'}, $v2->{'value'});
      $v->{'value'} = 'true';
      $v->{'other'} = '';
    }
    $v->{'keys'} = \@k;
    return $v;
  }
  if (ref($v1) eq ref($self)) {
    my $v = bless {};
    $v->{'db'} = $v1->{'db'};
    my $db = $v1->{'db'};
    if (exists($v1->{'value'})) {
      $v->{'keys'} = $v1->{'keys'};
      $v->{'value'} = $op->($v1->{'value'}, $v2) ? 'true' : '';
      $v->{'other'} = $op->($v1->{'other'}, $v2) ? 'true' : '';
      return $v;
    }
    my @k;
    if ($op == \&BSXPath::boolop_eq) {
      @k = $db->keys($v1->{'path'}, $v2, $v1->{'keys'});
      $negpol = 0;
    } elsif (!$negpol) {
      for my $vv ($db->values($v1->{'path'}, $v1->{'keys'})) {
        push @k, $db->keys($v1->{'path'}, $vv, $v1->{'keys'}) if $op->($vv, $v2);
      }
    } else {
      for my $vv ($db->values($v1->{'path'}, $v1->{'keys'})) {
        push @k, $db->keys($v1->{'path'}, $vv, $v1->{'keys'}) unless $op->($vv, $v2);
      }
    }
    if ($v1->{'keys'}) {
      my %k = map {$_ => 1} @{$v1->{'keys'}};
      @k = grep {$k{$_}} @k;
    }
    $v->{'keys'} = \@k;
    $v->{'value'} = $negpol ? '' : 'true';
    $v->{'other'} = $negpol ? 'true' : '';
    #print "==> ".Dumper($v)."<===\n";
    return $v;
  }
  if (ref($v2) eq ref($self)) {
    my $v = bless {};
    $v->{'db'} = $v1->{'db'};
    my $db = $v1->{'db'};
    if (exists($v2->{'value'})) {
      $v->{'keys'} = $v2->{'keys'};
      $v->{'value'} = $op->($v1, $v2->{'value'}) ? 'true' : '';
      $v->{'other'} = $op->($v1, $v2->{'other'}) ? 'true' : '';
      return $v;
    }
    my @k;
    if ($op == \&BSXPath::boolop_eq) {
      @k = $db->keys($v2->{'path'}, $v1, $v2->{'keys'});
      $negpol = 0;
    } elsif (!$negpol) {
      for my $vv ($db->values($v2->{'path'}, $v2->{'keys'})) {
	push @k, $db->keys($v2->{'path'}, $vv, $v2->{'keys'}) if $op->($v1, $vv);
      }
    } else {
      for my $vv ($db->values($v2->{'path'}, $v2->{'keys'})) {
	push @k, $db->keys($v2->{'path'}, $vv, $v2->{'keys'}) unless $op->($v1, $vv);
      }
    }
    if ($v2->{'keys'}) {
      my %k = map {$_ => 1} @{$v2->{'keys'}};
      @k = grep {$k{$_}} @k;
    }
    $v->{'keys'} = \@k;
    $v->{'value'} = $negpol ? '' : 'true';
    $v->{'other'} = $negpol ? 'true' : '';
    return $v;
  }
}

sub op {
  my ($self, $v1, $v2, $op) = @_;
  if (ref($v1) ne ref($self) && ref($v2) ne ref($self)) {
    return $op->($v1, $v2);
  }
  die("op not implemented for abstract elements\n");
}

sub predicate {
  my ($self, $v) = @_;
  if (ref($v) ne ref($self)) {
    $v = @$v ? 'true' : '' if ref($v) eq 'ARRAY';
    if ($v =~ /^-?\d+$/) {
      die("enumeration not implemented for abstract elements\n");
    } else {
      return $v ? $self : [];
    }
  }
  $v = toconcrete($self, $v) unless exists $v->{'value'};
  my $vv = bless {};
  $vv->{'db'} = $self->{'db'};
  $vv->{'path'} = $self->{'path'};
  my @k;
  if ($v->{'value'}) {
    @k = @{$v->{'keys'}};
  } elsif ($v->{'other'}) {
    my %k = map {$_ => 1} @{$v->{'keys'}};
    @k = grep {!$k{$_}} $self->{'db'}->keys();
  }
  if (@k && $self->{'keys'}) {
    my %k = map {$_ => 1} @{$self->{'keys'}};
    @k = grep {$k{$_}} @k;
  }
  $vv->{'keys'} = \@k;
  return $vv;
}

sub limit {
  my ($self, $v) = @_;
  if (ref($v) ne ref($self)) {
    return $self;
  }
  return $self if $self->{'value'};
  if ($v->{'value'}) {
    my @k = @{$v->{'keys'}};
    my $vv = bless {};
    $vv->{'db'} = $self->{'db'};
    $vv->{'path'} = $self->{'path'};
    if (@k && $self->{'keys'}) {
      my %k = map {$_ => 1} @{$self->{'keys'}};
      @k = grep {$k{$_}} @k;
    }
    $vv->{'keys'} = \@k;
    return $vv;
  } else {
    return $self;
  }
}

1;
