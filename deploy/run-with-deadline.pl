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

for my $signal (qw(HUP INT TERM)) {
  $SIG{$signal} = sub {
    terminate_process_group('TERM');
    sleep 0.2;
    terminate_process_group('KILL');
    exit 128 + ($signal eq 'HUP' ? 1 : $signal eq 'INT' ? 2 : 15);
  };
}

my $deadline_at = time() + $deadline_seconds;
my $termination_started_at;
while (1) {
  my $waited = waitpid($child_pid, WNOHANG);
  if ($waited == $child_pid) {
    my $status = $?;
    exit 128 + ($status & 127) if $status & 127;
    exit $status >> 8;
  }
  die "waitpid failed: $!\n" if $waited == -1;

  my $now = time();
  if (!defined $termination_started_at && $now >= $deadline_at) {
    warn "command exceeded ${deadline_seconds}s deadline; terminating its process group\n";
    terminate_process_group('TERM');
    $termination_started_at = $now;
  } elsif (defined $termination_started_at && $now >= $termination_started_at + 2) {
    warn "command ignored termination; killing its process group\n";
    terminate_process_group('KILL');
  }
  sleep 0.05;
}
