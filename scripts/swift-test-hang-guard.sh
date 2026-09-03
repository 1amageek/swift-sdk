#!/bin/bash
set -euo pipefail

REPEATS=3
TEST_TIMEOUT=30
BUILD_TIMEOUT=120

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repeats)
      REPEATS="$2"
      shift 2
      ;;
    --timeout)
      TEST_TIMEOUT="$2"
      shift 2
      ;;
    --build-timeout)
      BUILD_TIMEOUT="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ ! "$REPEATS" =~ ^[1-9][0-9]*$ || ! "$TEST_TIMEOUT" =~ ^[1-9][0-9]*$ \
  || ! "$BUILD_TIMEOUT" =~ ^[1-9][0-9]*$ ]] \
  || (( TEST_TIMEOUT > 120 || BUILD_TIMEOUT > 120 )); then
  printf 'ERROR: repeats and timeouts must be positive integers; timeouts must not exceed 120 seconds\n' >&2
  exit 2
fi

readonly REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly TIMEOUT_SCRIPT="$REPOSITORY_ROOT/scripts/swift-test-timeout.sh"
readonly ARTIFACT_DIR="$REPOSITORY_ROOT/.test-artifacts/hang-guard/$(date -u +%Y%m%dT%H%M%SZ)-$$"
readonly LOCK_DIR="$REPOSITORY_ROOT/.build/swift-test-hang-guard.lock"

mkdir -p "$REPOSITORY_ROOT/.build" "$ARTIFACT_DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  printf 'ERROR: another hang-guard run is active\n' >&2
  exit 3
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

cd "$REPOSITORY_ROOT"
"$TIMEOUT_SCRIPT" "$BUILD_TIMEOUT" swift build --build-tests > "$ARTIFACT_DIR/build.log" 2>&1

for (( run = 1; run <= REPEATS; run++ )); do
  log="$ARTIFACT_DIR/run-$run.log"
  if ! "$TIMEOUT_SCRIPT" "$TEST_TIMEOUT" swift test --skip-build "$@" > "$log" 2>&1; then
    {
      ps -ef | rg 'swift|xctest' || true
      find .build -name .lock -print 2>/dev/null || true
    } > "$ARTIFACT_DIR/run-$run.diag.txt"
    printf 'ERROR: run %d failed; diagnostics: %s\n' "$run" "$ARTIFACT_DIR" >&2
    exit 1
  fi

  if ps -ef | rg "${REPOSITORY_ROOT}.*swiftpm-testing-helpe[r]" > /dev/null; then
    ps -ef | rg "${REPOSITORY_ROOT}.*swiftpm-testing-helpe[r]" > "$ARTIFACT_DIR/run-$run.diag.txt"
    printf 'ERROR: run %d left a stale helper; diagnostics: %s\n' "$run" "$ARTIFACT_DIR" >&2
    exit 1
  fi
done

printf 'OK: %d run(s) completed without timeout or stale helper\n' "$REPEATS"
