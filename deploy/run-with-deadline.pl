#!/usr/bin/env perl
use strict;
use warnings;
use POSIX qw(:sys_wait_h setsid);
use Time::HiRes qw(time sleep);

my $deadline_seconds = shift @ARGV;
die "deadline must be a positive integer\n"
  unless defined $deadline_seconds && $deadline_seconds =~ /^[1-9][0-9]*$/;
die "command is required\n" unless @ARGV;

my $child_pid = fork();
die "fork failed: $!\n" unless defined $child_pid;

if ($child_pid == 0) {
  setsid() != -1 or die "setsid failed: $!\n";
  exec @ARGV;
  die "exec failed: $!\n";
}

sub terminate_process_group {
  my ($signal) = @_;
  kill $signal, -$child_pid;
}

sub process_group_exists {
  return kill 0, -$child_pid;
}

sub exit_with_status {
  my ($status) = @_;
  exit 128 + ($status & 127) if $status & 127;
  exit $status >> 8;
}

my $received_signal;
for my $signal (qw(HUP INT TERM)) {
  $SIG{$signal} = sub {
    $received_signal //= $signal;
  };
}

my $deadline_at = time() + $deadline_seconds;
my $termination_started_at;
my $termination_exit_status;
my $kill_sent;
my $leader_reaped = 0;
my $leader_status;
while (1) {
  if (!$leader_reaped) {
    my $waited = waitpid($child_pid, WNOHANG);
    if ($waited == $child_pid) {
      $leader_status = $?;
      $leader_reaped = 1;
    } elsif ($waited == -1) {
      die "waitpid failed: $!\n";
    }
  }

  my $now = time();
  if (!defined $termination_started_at && defined $received_signal) {
    warn "received ${received_signal}; terminating command process group\n";
    terminate_process_group('TERM');
    $termination_started_at = $now;
    $termination_exit_status = 128 + ($received_signal eq 'HUP' ? 1 : $received_signal eq 'INT' ? 2 : 15);
  } elsif (!defined $termination_started_at && $now >= $deadline_at) {
    warn "command exceeded ${deadline_seconds}s deadline; terminating its process group\n";
    terminate_process_group('TERM');
    $termination_started_at = $now;
    $termination_exit_status = 124;
  } elsif (defined $termination_started_at && !$kill_sent && $now >= $termination_started_at + 2) {
    warn "command ignored termination; killing its process group\n";
    terminate_process_group('KILL');
    $kill_sent = 1;
  }

  # The leader may exit while a TERM-ignoring descendant remains in its
  # session. Do not return until the process group is empty.
  if (!process_group_exists()) {
    exit $termination_exit_status if defined $termination_exit_status;
    exit_with_status($leader_status) if $leader_reaped;
  }
  sleep 0.05;
}
