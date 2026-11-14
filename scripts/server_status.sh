#!/usr/bin/env bash
set -euo pipefail

PID_DIR="/var/log/pi-dev-agent"
LOG_DIR="$PID_DIR"

# Define servers as parallel arrays (bash 3 compatible)
NAMES=("main" "vision")
PORTS=(1234 8083)
PID_FILES=("$PID_DIR/main.pid" "$PID_DIR/vision.pid")
LOG_FILES=("$PID_DIR/llama-server-main.log" "$PID_DIR/llama-server-vision.log")

echo "=== llama.cpp server status ==="
echo ""

ALL_OK=true

for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"
  port="${PORTS[$i]}"
  pid_file="${PID_FILES[$i]}"
  log_file="${LOG_FILES[$i]}"

  echo "--- $name server (port $port) ---"

  if [[ ! -f "$pid_file" ]]; then
    echo "  Status: NOT RUNNING (no PID file)"
    ALL_OK=false
    echo ""
    continue
  fi

  pid=$(cat "$pid_file")

  # Check process exists
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "  Status: NOT RUNNING (stale PID $pid)"
    rm -f "$pid_file"
    ALL_OK=false
    echo ""
    continue
  fi

  # Check port ownership
  port_pid=$(lsof -i :"$port" -sTCP:LISTEN -t 2>/dev/null | head -1) || true
  if [[ "$port_pid" != "$pid" ]]; then
    echo "  Status: MISMATCH (PID $pid not on port $port, held by ${port_pid:-unknown})"
    ALL_OK=false
    cmdline=$(ps -p "$pid" -o command= 2>/dev/null) || true
    echo "  PID $pid cmdline: $cmdline"
    echo ""
    continue
  fi

  # Check it's llama-server
  cmdline=$(ps -p "$pid" -o command= 2>/dev/null) || true
  if [[ "$cmdline" != *"llama-server"* ]]; then
    echo "  Status: WRONG PROCESS (not a llama-server)"
    ALL_OK=false
    echo ""
    continue
  fi

  # Check health endpoint
  health=$(curl -s --max-time 2 "http://localhost:$port/health" 2>/dev/null) || true
  if [[ "$health" == *"ok"* ]]; then
    status="RUNNING ✓"
  else
    status="RUNNING (health check unclear)"
  fi

  echo "  Status: $status"
  echo "  PID: $pid"
  echo "  Log: $log_file"
  if [[ -f "$log_file" ]]; then
    lines=$(wc -l < "$log_file")
    size=$(du -h "$log_file" | cut -f1)
    echo "  Log size: ${size} (${lines} lines)"
  fi
  echo ""
done

if $ALL_OK; then
  echo "All servers are running."
else
  echo "One or more servers are not running."
fi
