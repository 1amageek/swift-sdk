#!/bin/bash
set -euo pipefail

readonly CONFORMANCE_PACKAGE="@modelcontextprotocol/conformance@0.2.0-alpha.10"
readonly SPEC_VERSION="2026-07-28"
readonly CLIENT_EXECUTABLE="mcp-everything-client"
readonly SERVER_EXECUTABLE="mcp-everything-server"
readonly CLIENT_SCENARIO_TIMEOUT_MS="${CLIENT_SCENARIO_TIMEOUT_MS:-30000}"
readonly PROCESS_TIMEOUT_SECONDS="${PROCESS_TIMEOUT_SECONDS:-120}"
readonly STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-20}"
readonly SERVER_URL="${SERVER_URL:-http://127.0.0.1:3001/mcp}"
readonly SERVER_SCENARIOS=(
  server-stateless
  completion-complete
  tools-list
  tools-call-simple-text
  tools-call-image
  tools-call-audio
  tools-call-embedded-resource
  tools-call-mixed-content
  tools-call-error
  tools-call-with-progress
  server-sse-multiple-streams
  resources-list
  resources-read-text
  resources-read-binary
  resources-templates-read
  sep-2164-resource-not-found
  prompts-list
  prompts-get-simple
  prompts-get-with-args
  prompts-get-embedded-resource
  prompts-get-with-image
  dns-rebinding-protection
  caching
  input-required-result-basic-elicitation
  input-required-result-basic-sampling
  input-required-result-basic-list-roots
  input-required-result-request-state
  input-required-result-multiple-input-requests
  input-required-result-multi-round
  input-required-result-missing-input-response
  input-required-result-non-tool-request
  input-required-result-result-type
  input-required-result-unsupported-methods
  input-required-result-tampered-state
  input-required-result-capability-check
  input-required-result-ignore-extra-params
  input-required-result-validate-input
)

MODE="both"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

case "$MODE" in
  client|server|both) ;;
  *)
    printf 'Invalid mode: %s\n' "$MODE" >&2
    exit 1
    ;;
esac

readonly REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly EVIDENCE_ROOT="${CONFORMANCE_OUTPUT_DIR:-$REPOSITORY_ROOT/.build/conformance-results}"
readonly EVIDENCE_DIR="$EVIDENCE_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$EVIDENCE_DIR"

run_with_timeout() {
  local seconds="$1"
  shift
  /usr/bin/perl -MPOSIX -e '
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
  ' "$seconds" "$@"
}

build_product() {
  run_with_timeout "$PROCESS_TIMEOUT_SECONDS" \
    swift build --product "$1"
}

write_not_scored_report() {
  cat > "$EVIDENCE_DIR/not-scored.json" <<'JSON'
{
  "referee": "@modelcontextprotocol/conformance@0.2.0-alpha.10",
  "specVersion": "2026-07-28",
  "clientReportOnly": [
    "auth/client-credentials-jwt",
    "auth/client-credentials-basic",
    "auth/enterprise-managed-authorization",
    "auth/dpop",
    "auth/dpop-nonce",
    "auth/wif-jwt-bearer",
    "json-schema-2020-12-preservation"
  ],
  "serverPending": [
    "json-schema-2020-12",
    "http-header-validation",
    "http-custom-header-server-validation"
  ],
  "tasksNotScored": [
    "tasks-lifecycle",
    "tasks-capability-negotiation",
    "tasks-request-headers",
    "tasks-mrtr-input",
    "tasks-dispatch-and-envelope",
    "tasks-wire-fields",
    "tasks-request-state-removal",
    "tasks-status-notifications",
    "tasks-required-task-error",
    "tasks-mrtr-composition"
  ]
}
JSON
}

cd "$REPOSITORY_ROOT"
write_not_scored_report

if [[ "$MODE" == "client" || "$MODE" == "both" ]]; then
  build_product "$CLIENT_EXECUTABLE"
fi
if [[ "$MODE" == "server" || "$MODE" == "both" ]]; then
  build_product "$SERVER_EXECUTABLE"
fi

readonly BIN_PATH="$(swift build --show-bin-path)"
readonly CLIENT_PATH="$BIN_PATH/$CLIENT_EXECUTABLE"
readonly SERVER_PATH="$BIN_PATH/$SERVER_EXECUTABLE"

if [[ "$MODE" == "client" || "$MODE" == "both" ]]; then
  run_with_timeout "$PROCESS_TIMEOUT_SECONDS" \
    npx --yes "$CONFORMANCE_PACKAGE" client \
      --command "$CLIENT_PATH" \
      --suite all \
      --timeout "$CLIENT_SCENARIO_TIMEOUT_MS" \
      --spec-version "$SPEC_VERSION" \
      --output-dir "$EVIDENCE_DIR/client"
fi

SERVER_PID=""
cleanup_server() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$SERVER_PID" 2>/dev/null; then
      kill -KILL "$SERVER_PID" 2>/dev/null || true
    fi
  fi
  if [[ -n "$SERVER_PID" ]]; then
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
}
trap cleanup_server EXIT

wait_for_server() {
  local deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      printf 'Server exited before readiness; see %s/server.log\n' "$EVIDENCE_DIR" >&2
      return 1
    fi
    local status
    status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 1 --max-time 1 "$SERVER_URL" || true)"
    if [[ "$status" != "000" ]]; then
      return 0
    fi
    sleep 0.1
  done
  printf 'Server readiness timed out after %s seconds\n' "$STARTUP_TIMEOUT_SECONDS" >&2
  return 1
}

if [[ "$MODE" == "server" || "$MODE" == "both" ]]; then
  if [[ "${#SERVER_SCENARIOS[@]}" -ne 37 ]]; then
    printf 'Expected 37 frozen server scenarios, found %s\n' \
      "${#SERVER_SCENARIOS[@]}" >&2
    exit 1
  fi
  "$SERVER_PATH" > "$EVIDENCE_DIR/server.log" 2>&1 &
  SERVER_PID=$!
  wait_for_server
  for scenario in "${SERVER_SCENARIOS[@]}"; do
    run_with_timeout "$PROCESS_TIMEOUT_SECONDS" \
      npx --yes "$CONFORMANCE_PACKAGE" server \
        --url "$SERVER_URL" \
        --scenario "$scenario" \
        --spec-version "$SPEC_VERSION" \
        --output-dir "$EVIDENCE_DIR/server"
  done
  cleanup_server
fi

printf 'Conformance evidence: %s\n' "$EVIDENCE_DIR"
