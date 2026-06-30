#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/remotepad-browser-proxy.XXXXXX")"
AGENT_LOG="$LOG_DIR/agent.log"
SERVER_LOG="$LOG_DIR/server.log"
PROXY_LOG="$LOG_DIR/proxy.log"
IDENTITY_LOG="$LOG_DIR/identity.log"
PAIR_LOG="$LOG_DIR/pair.log"
APPROVE_LOG="$LOG_DIR/approve.log"
STATUS_LOG="$LOG_DIR/status.log"
HTTP_LOG="$LOG_DIR/http.log"
CHUNKED_LOG="$LOG_DIR/chunked.log"
SSE_LOG="$LOG_DIR/sse.log"
WS_LOG="$LOG_DIR/websocket.log"
AGENT_PID=""
SERVER_PID=""
PROXY_PID=""
DEVICE_ID=""

log() {
  printf '[check-browser-proxy] %s\n' "$*"
}

fail() {
  printf '[check-browser-proxy] failed: %s\n' "$*" >&2
  printf '[check-browser-proxy] logs: %s\n' "$LOG_DIR" >&2
  exit 1
}

cleanup() {
  local exit_code=$?

  if [[ -n "$DEVICE_ID" ]]; then
    (cd "$ROOT_DIR" && swift run remotepad-agent --revoke-device "$DEVICE_ID" >/dev/null 2>&1 || true)
    (cd "$ROOT_DIR" && swift run remotepad-agent --reject-pairing "$DEVICE_ID" >/dev/null 2>&1 || true)
  fi

  for pid in "$PROXY_PID" "$SERVER_PID" "$AGENT_PID"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill -INT "$pid" >/dev/null 2>&1 || true
      sleep 0.2
      if kill -0 "$pid" >/dev/null 2>&1; then
        kill -TERM "$pid" >/dev/null 2>&1 || true
      fi
      sleep 0.2
      if kill -0 "$pid" >/dev/null 2>&1; then
        kill -KILL "$pid" >/dev/null 2>&1 || true
      fi
      wait "$pid" >/dev/null 2>&1 || true
    fi
  done

  if [[ "$exit_code" -eq 0 ]]; then
    rm -rf "$LOG_DIR"
  else
    printf '[check-browser-proxy] logs preserved: %s\n' "$LOG_DIR" >&2
  fi
}
trap cleanup EXIT

free_port() {
  python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
}

wait_for_port() {
  local port="$1"
  local label="$2"
  local deadline=$((SECONDS + 30))

  while [[ "$SECONDS" -lt "$deadline" ]]; do
    if python3 - "$port" <<'PY' >/dev/null 2>&1
import socket
import sys

port = int(sys.argv[1])
with socket.create_connection(("127.0.0.1", port), timeout=0.2):
    pass
PY
    then
      return 0
    fi
    sleep 0.2
  done

  fail "timed out waiting for $label on port $port"
}

require_contains() {
  local file="$1"
  local expected="$2"
  if ! /usr/bin/grep -Fq "$expected" "$file"; then
    printf '[check-browser-proxy] expected "%s" in %s\n' "$expected" "$file" >&2
    sed -n '1,220p' "$file" >&2
    fail "missing expected output"
  fi
}

extract_device_id() {
  awk -F': ' '/device_id:/ { print $2; exit }' "$1"
}

start_fixture_server() {
  python3 - "$TARGET_PORT" >"$SERVER_LOG" 2>&1 <<'PY' &
import socketserver
import signal
import sys
import time
from http.server import BaseHTTPRequestHandler

port = int(sys.argv[1])

def stop_server(signum, frame):
    raise SystemExit(0)

signal.signal(signal.SIGINT, stop_server)
signal.signal(signal.SIGTERM, stop_server)

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        return

    def do_GET(self):
        if self.path == "/":
            body = b"RemotePad browser proxy ok\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/chunked":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for chunk in (b"chunk-one\n", b"chunk-two\n"):
                self.wfile.write(f"{len(chunk):x}\r\n".encode("ascii"))
                self.wfile.write(chunk)
                self.wfile.write(b"\r\n")
                self.wfile.flush()
                time.sleep(0.1)
            self.wfile.write(b"0\r\n\r\n")
        elif self.path == "/sse":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            for value in ("hello", "done"):
                self.wfile.write(f"data: {value}\n\n".encode("utf-8"))
                self.wfile.flush()
                time.sleep(0.1)
        elif self.path == "/ws":
            self.send_response(101, "Switching Protocols")
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", "test")
            self.end_headers()
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

with socketserver.ThreadingTCPServer(("127.0.0.1", port), Handler) as server:
    server.allow_reuse_address = True
    server.serve_forever()
PY
  SERVER_PID=$!
}

cd "$ROOT_DIR"

AGENT_PORT="$(free_port)"
TARGET_PORT="$(free_port)"
LISTEN_PORT="$(free_port)"

log "loading dev client identity"
swift run remotepad-dev-client --identity >"$IDENTITY_LOG" 2>&1
DEVICE_ID="$(extract_device_id "$IDENTITY_LOG")"
[[ -n "$DEVICE_ID" ]] || fail "could not read dev client device_id"

log "cleaning previous state for $DEVICE_ID"
swift run remotepad-agent --revoke-device "$DEVICE_ID" >/dev/null 2>&1 || true
swift run remotepad-agent --reject-pairing "$DEVICE_ID" >/dev/null 2>&1 || true

log "starting fixture server on $TARGET_PORT"
start_fixture_server
wait_for_port "$TARGET_PORT" "fixture server"

log "starting loopback agent on $AGENT_PORT"
REMOTEPAD_OPEN_PAIRING_APPROVER=0 REMOTEPAD_AGENT_PORT="$AGENT_PORT" swift run remotepad-agent >"$AGENT_LOG" 2>&1 &
AGENT_PID=$!
wait_for_port "$AGENT_PORT" "agent"

log "pairing and approving dev client"
swift run remotepad-dev-client --pair "$AGENT_PORT" "RemotePad Browser Proxy Check" >"$PAIR_LOG" 2>&1
require_contains "$PAIR_LOG" "status: pending_approval"
swift run remotepad-agent --approve-pairing "$DEVICE_ID" >"$APPROVE_LOG" 2>&1
require_contains "$APPROVE_LOG" "approved pairing: $DEVICE_ID"
swift run remotepad-dev-client --pair-status "$AGENT_PORT" >"$STATUS_LOG" 2>&1
require_contains "$STATUS_LOG" "status: approved"

log "starting local proxy on $LISTEN_PORT -> $TARGET_PORT"
swift run remotepad-dev-client --local-proxy "$AGENT_PORT" "$LISTEN_PORT" "$TARGET_PORT" >"$PROXY_LOG" 2>&1 &
PROXY_PID=$!
wait_for_port "$LISTEN_PORT" "local proxy"

log "checking HTTP"
curl -fsS "http://127.0.0.1:$LISTEN_PORT/" >"$HTTP_LOG"
require_contains "$HTTP_LOG" "RemotePad browser proxy ok"

log "checking chunked response"
curl -fsS --http1.1 "http://127.0.0.1:$LISTEN_PORT/chunked" >"$CHUNKED_LOG"
require_contains "$CHUNKED_LOG" "chunk-one"
require_contains "$CHUNKED_LOG" "chunk-two"

log "checking SSE"
curl -fsS --http1.1 -N "http://127.0.0.1:$LISTEN_PORT/sse" >"$SSE_LOG"
require_contains "$SSE_LOG" "data: hello"
require_contains "$SSE_LOG" "data: done"

log "checking WebSocket upgrade"
curl -sS --http1.1 -i --max-time 2 \
  -H 'Connection: Upgrade' \
  -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  -H 'Sec-WebSocket-Version: 13' \
  "http://127.0.0.1:$LISTEN_PORT/ws" >"$WS_LOG" 2>>"$WS_LOG" || true
require_contains "$WS_LOG" "101 Switching Protocols"
require_contains "$WS_LOG" "Upgrade: websocket"

log "passed"
