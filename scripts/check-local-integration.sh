#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/remotepad-integration.XXXXXX")"
AGENT_LOG="$LOG_DIR/agent.log"
IDENTITY_LOG="$LOG_DIR/identity.log"
PAIR_LOG="$LOG_DIR/pair.log"
APPROVE_LOG="$LOG_DIR/approve.log"
STATUS_LOG="$LOG_DIR/status.log"
TERMINAL_CREATE_LOG="$LOG_DIR/terminal-create.log"
TERMINAL_ATTACH_LOG="$LOG_DIR/terminal-attach.log"
TEST_LOG="$LOG_DIR/test.log"
AGENT_PID=""
DEVICE_ID=""

export REMOTEPAD_AGENT_IDENTITY_FILE="$LOG_DIR/agent-identity.json"
export REMOTEPAD_DEV_CLIENT_IDENTITY_FILE="$LOG_DIR/dev-client-identity.json"
export REMOTEPAD_AUDIT_LOG_FILE="$LOG_DIR/audit.jsonl"

log() {
  printf '[check-local-integration] %s\n' "$*"
}

fail() {
  printf '[check-local-integration] failed: %s\n' "$*" >&2
  printf '[check-local-integration] logs: %s\n' "$LOG_DIR" >&2
  exit 1
}

cleanup() {
  local exit_code=$?

  if [[ -n "$DEVICE_ID" ]]; then
    (cd "$ROOT_DIR" && swift run remotepad-agent --revoke-device "$DEVICE_ID" >/dev/null 2>&1 || true)
    (cd "$ROOT_DIR" && swift run remotepad-agent --reject-pairing "$DEVICE_ID" >/dev/null 2>&1 || true)
  fi

  if [[ -n "$AGENT_PID" ]] && kill -0 "$AGENT_PID" >/dev/null 2>&1; then
    kill -INT "$AGENT_PID" >/dev/null 2>&1 || true
    wait "$AGENT_PID" >/dev/null 2>&1 || true
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    rm -rf "$LOG_DIR"
  else
    printf '[check-local-integration] logs preserved: %s\n' "$LOG_DIR" >&2
  fi
}
trap cleanup EXIT

require_contains() {
  local file="$1"
  local expected="$2"
  if ! /usr/bin/grep -Fq "$expected" "$file"; then
    printf '[check-local-integration] expected "%s" in %s\n' "$expected" "$file" >&2
    sed -n '1,220p' "$file" >&2
    fail "missing expected output"
  fi
}

extract_device_id() {
  awk -F': ' '/device_id:/ { print $2; exit }' "$1"
}

wait_for_agent_ready() {
  local deadline=$((SECONDS + 30))

  while [[ "$SECONDS" -lt "$deadline" ]]; do
    if python3 - "$AGENT_PORT" <<'PY' >/dev/null 2>&1
import socket
import sys

port = int(sys.argv[1])
with socket.create_connection(("127.0.0.1", port), timeout=0.2):
    pass
PY
    then
      return 0
    fi
    if [[ -n "$AGENT_PID" ]] && ! kill -0 "$AGENT_PID" >/dev/null 2>&1; then
      sed -n '1,220p' "$AGENT_LOG" >&2
      fail "agent exited before becoming ready"
    fi
    sleep 0.2
  done

  sed -n '1,220p' "$AGENT_LOG" >&2
  fail "timed out waiting for agent on port $AGENT_PORT"
}

cd "$ROOT_DIR"

AGENT_PORT="$(
  python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
)"

log "loading dev client identity"
swift run remotepad-dev-client --identity >"$IDENTITY_LOG" 2>&1
DEVICE_ID="$(extract_device_id "$IDENTITY_LOG")"
[[ -n "$DEVICE_ID" ]] || fail "could not read dev client device_id"

log "cleaning previous state for $DEVICE_ID"
swift run remotepad-agent --revoke-device "$DEVICE_ID" >/dev/null 2>&1 || true
swift run remotepad-agent --reject-pairing "$DEVICE_ID" >/dev/null 2>&1 || true

log "starting loopback agent"
REMOTEPAD_OPEN_PAIRING_APPROVER=0 REMOTEPAD_AGENT_PORT="$AGENT_PORT" swift run remotepad-agent >"$AGENT_LOG" 2>&1 &
AGENT_PID=$!
wait_for_agent_ready
log "agent ready on port $AGENT_PORT"

log "requesting pairing"
swift run remotepad-dev-client --pair "$AGENT_PORT" "RemotePad Integration Check" >"$PAIR_LOG" 2>&1
require_contains "$PAIR_LOG" "accepted: true"
require_contains "$PAIR_LOG" "status: pending_approval"
require_contains "$PAIR_LOG" "device_id: $DEVICE_ID"

log "approving pairing"
swift run remotepad-agent --approve-pairing "$DEVICE_ID" >"$APPROVE_LOG" 2>&1
require_contains "$APPROVE_LOG" "approved pairing: $DEVICE_ID"

log "checking pairing status"
swift run remotepad-dev-client --pair-status "$AGENT_PORT" >"$STATUS_LOG" 2>&1
require_contains "$STATUS_LOG" "accepted: true"
require_contains "$STATUS_LOG" "status: approved"
require_contains "$STATUS_LOG" "device_id: $DEVICE_ID"

log "creating a persistent authenticated terminal"
swift run remotepad-dev-client "$AGENT_PORT" >"$TERMINAL_CREATE_LOG" 2>&1
require_contains "$TERMINAL_CREATE_LOG" "received auth.result"
require_contains "$TERMINAL_CREATE_LOG" "accepted: true"
require_contains "$TERMINAL_CREATE_LOG" "received terminal.created"
require_contains "$TERMINAL_CREATE_LOG" "__REMOTEPAD_READY__"

log "reattaching to and explicitly closing the terminal"
swift run remotepad-dev-client "$AGENT_PORT" --attach-first --close-after-ready >"$TERMINAL_ATTACH_LOG" 2>&1
require_contains "$TERMINAL_ATTACH_LOG" "received terminal.list.result"
require_contains "$TERMINAL_ATTACH_LOG" "terminals: 1"
require_contains "$TERMINAL_ATTACH_LOG" "received terminal.attached"
require_contains "$TERMINAL_ATTACH_LOG" "__REMOTEPAD_ATTACHED__"
require_contains "$TERMINAL_ATTACH_LOG" "received terminal.closed"

log "running unit tests"
swift test >"$TEST_LOG" 2>&1
require_contains "$TEST_LOG" "Test run with"
require_contains "$TEST_LOG" "tests in 0 suites passed"

log "checking audit events"
require_contains "$REMOTEPAD_AUDIT_LOG_FILE" '"event":"pairing.approved"'
require_contains "$REMOTEPAD_AUDIT_LOG_FILE" '"event":"auth.accepted"'
require_contains "$REMOTEPAD_AUDIT_LOG_FILE" '"event":"terminal.created"'
require_contains "$REMOTEPAD_AUDIT_LOG_FILE" '"event":"terminal.attached"'
require_contains "$REMOTEPAD_AUDIT_LOG_FILE" '"event":"terminal.closed"'

log "passed"
