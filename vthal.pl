# This file is part of the LibreRVAC project
#
# Copyright © 2015-2016
#     Aleks-Daniel Jakimenko-Aleksejev <alex.jakimenko@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

#!/usr/bin/env perl
use strict;
use warnings;
use v5.10;
use utf8;
use threads;
use threads::shared;
use Thread::Queue;
use Time::HiRes qw(time);

use JSON::XS;
use IO::Handle;
use IO::Socket::UNIX;

my $SEP = "\x1E";
my $device = '/dev/ttyS1';
my $SOCK_PATH = "brain.sock";
$| = 1;

mkdir 'logs' unless -d 'logs';
open my $log, '>', 'logs/' . timestamp();

my @connections :shared; # TODO most probably we have to use a hash here

# We can use different file handles, that's fine
open my $fhr, '<', $device;
open my $fhw, '>', $device;

#$fhr->autoflush;
$fhw->autoflush;
print $fhw 'U';

my %info;

# TODO move movement & navigation to a separate file
my $cleaning_mode :shared = '';
my $last_bump :shared = 0;
my $turn_stage = 0;

sub timestamp {
  my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
  my $timestamp = sprintf "%04d%02d%02d_%02d:%02d:%02d", $year+1900,$mon+1,$mday,$hour,$min,$sec;
  return $timestamp;
}

sub say_log {
  say          @_;
  say $log     @_;
  $_->enqueue(join '', @_) for @connections;
}

# TODO concurrency
# TODO rename to mcu_send&mcu_receive ?
sub receive_json {
  my ($line) = @_;
  my $data;
  eval { $data = decode_json $line };
  if ($@) {
    say_log 'Unparseable data from MCU:', $line;
    return;
  }
  if (exists $data->{'e'} and $data->{'e'} eq 'move-finished') {
    say 'cleaning mode: ', $cleaning_mode;
    return unless $cleaning_mode;
    say 'move finished: ', time;
    if ($turn_stage == 1) {
      send_json({c => 'move', length => -1});
      $turn_stage++;
    } elsif ($turn_stage == 2) {
      send_json({c => 'move', length => 0.001, radius => rand() - 0.5});
      $last_bump = 0;
      $turn_stage = 0;
    } else {
      send_json({c => 'move', length => 1});
    }
  } elsif (exists $data->{'e'} and $data->{'e'} eq 'bump') {
    $last_bump = time;
    $turn_stage = 1;
    say 'Bump! (', $data->{'angle'}, ') ', time;
  } elsif (exists $data->{'c'} and $data->{'c'} eq 'log') {
    say_log 'MCU log: ', $data->{'str'};
  } elsif (exists $data->{'c'} and $data->{'c'} eq 'info') {
    for (keys %$data) {
      next if $_ eq 'c';
      $info{$_} = $data->{$_};
      my $json = encode_json($data); # TODO do not retranslate blindly, just send %info
      $_->enqueue($json) for @connections;
    }
  } else {
    say_log 'Unknown packet from MCU: ', $line;
  }
}

sub send_json {
  my ($hash) = @_;
  my $str = encode_json($hash) . $SEP;
  say "To MCU: $str";
  print $fhw $str;
}

sub beep {
  my ($frequency, $duration, $volume) = @_;
  send_json({c => 'beep', pitch => $frequency, duration => $duration, volume => $volume});
}

sub motor {
  my ($motor, $throttle) = @_;
  send_json({c => 'motor', motor => $motor, throttle => $throttle});
}


threads->create(sub {
  #my $thr_id = threads->self->tid;
  unlink $SOCK_PATH if -e $SOCK_PATH;
  my $server = IO::Socket::UNIX->new(
    Type => SOCK_STREAM(),
    Local => $SOCK_PATH,
    Listen => 1,
      );
  while (my $conn = $server->accept()) {
    my $queue = Thread::Queue->new();
    {
      lock(@connections);
      push @connections, $queue;
    }

    threads->create(sub { # WRITE
      while (1) {
        $conn->send($queue->dequeue() . $SEP);
      }
      threads->detach(); # End thread
                    });

    threads->create(sub { # READ
      local $/ = $SEP;
      while (<$conn>) {
        chomp;
        my $data = decode_json $_;
        say "From socket: $_";
        if ($data->{'command'} eq 'bypass') {
          $cleaning_mode = '';
          send_json($data->{'data'});
        } elsif ($data->{'command'} eq 'clean') {
          $cleaning_mode = $data->{type};
          # initial move only, consequent commands will be sent as replies
          send_json({c => 'move', length => 1});
        }
      }
      {
        lock @connections;
        @connections = grep { $_ != $queue } @connections;
      }
      threads->detach(); # End thread
                    });
  }
                });

my $time = time;
while (1) {
    #my $line = <$fhr>;
    my $line = do { local $/ = "\x1E"; $_ = <$fhr>; chomp; $_ };
    receive_json($line);
    #print $line;
    #sleep 0.01;
    #say "$_ $info{$_}" for keys %info;
}
