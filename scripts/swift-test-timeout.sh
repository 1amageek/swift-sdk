#!/bin/bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  printf 'Usage: %s <seconds> <command> [argument...]\n' "$0" >&2
  exit 2
fi

readonly TIMEOUT_SECONDS="$1"
shift

if [[ ! "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || (( TIMEOUT_SECONDS > 120 )); then
  printf 'ERROR: timeout must be an integer from 1 through 120 seconds\n' >&2
  exit 2
fi

exec /usr/bin/perl -MPOSIX -e '
  my $seconds = shift @ARGV;
  my $pid = fork();
  die "fork failed: $!\n" unless defined $pid;
  if ($pid == 0) {
    POSIX::setpgid(0, 0);
    exec @ARGV;
    exit 127;
  }
  $SIG{ALRM} = sub {
    kill "TERM", -$pid;
    select undef, undef, undef, 0.5;
    kill "KILL", -$pid;
    waitpid($pid, 0);
    exit 124;
  };
  alarm $seconds;
  waitpid($pid, 0);
  alarm 0;
  exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
' "$TIMEOUT_SECONDS" "$@"
