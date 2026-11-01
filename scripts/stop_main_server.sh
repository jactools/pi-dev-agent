#!/usr/bin/env bash
set -euo pipefail

PID_FILE="/var/log/pi-dev-agent/main.pid"
LOG_DIR="/var/log/pi-dev-agent"
PORT=1234

if [[ ! -f "$PID_FILE" ]]; then
  echo "No PID file found: $PID_FILE" >&2
  echo "Main server does not appear to be running." >&2
  exit 1
fi

PID=$(cat "$PID_FILE")

# Check if process exists
if ! kill -0 "$PID" 2>/dev/null; then
  echo "Process $PID is not running (stale PID file)." >&2
  rm -f "$PID_FILE"
  exit 1
fi

# Verify it's our server by checking the port
PROCESS_PORT=$(lsof -i :"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1) || true
if [[ "$PROCESS_PORT" != "$PID" ]]; then
  echo "WARNING: PID $PID is not listening on port $PORT (currently held by PID ${PROCESS_PORT:-unknown})." >&2
  echo "Process $PID cmdline:" >&2
  ps -p "$PID" -o command= 2>/dev/null || true
  exit 1
fi

# Confirm it's a llama-server process
CMDLINE=$(ps -p "$PID" -o command= 2>/dev/null) || true
if [[ "$CMDLINE" != *"llama-server"* ]]; then
  echo "WARNING: PID $PID is not a llama-server process." >&2
  exit 1
fi

echo "Stopping main server (PID $PID, port $PORT)..."
kill "$PID" 2>/dev/null || true
rm -f "$PID_FILE"

# Wait for it to actually die (up to 5 seconds)
for i in $(seq 1 10); do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "Main server stopped."
    exit 0
  fi
  sleep 0.5
done

echo "Server did not stop gracefully, sending SIGKILL..."
kill -9 "$PID" 2>/dev/null || true
rm -f "$PID_FILE"
sleep 1
echo "Main server killed."
