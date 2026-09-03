#!/bin/bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
  printf 'Usage: %s <path>...\n' "$0" >&2
  exit 2
fi

FILES=()
while IFS= read -r file; do
  FILES+=("$file")
done < <(rg --files "$@" -g '*.swift')

if [[ ${#FILES[@]} -eq 0 ]]; then
  printf 'OK: no Swift sources found\n'
  exit 0
fi

if /usr/bin/perl -0777 -ne '
  while (/deinit\s*\{(?:(?!\n\s*\}).)*syncShutdownGracefully/sg) {
    my $line = 1 + (substr($_, 0, $-[0]) =~ tr/\n//);
    print "$ARGV:$line: synchronous shutdown in deinit\n";
    $found = 1;
  }
  END { exit($found ? 1 : 0) }
' "${FILES[@]}"; then
  printf 'OK: no synchronous shutdown in deinit\n'
else
  printf 'ERROR: synchronous shutdown in deinit can deadlock tests\n' >&2
  exit 1
fi
