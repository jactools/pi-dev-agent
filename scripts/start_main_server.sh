#!/usr/bin/env bash
set -euo pipefail

# Start the main coding model server (port 1234)
# Usage: ./scripts/start_main_server.sh [profile]
#   Default profile: llama-server.profile.large-context.env

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/log/pi-dev-agent"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="${LLAMA_MAIN_LOG:-$LOG_DIR/llama-server-main.log}"

PROFILE="${1:-$SCRIPT_DIR/llama-server.profile.large-context.env}"

if [[ ! -f "$PROFILE" ]]; then
  echo "Profile not found: $PROFILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$PROFILE"

export LLAMA_CPP_ROOT="${LLAMA_CPP_ROOT:-$HOME/gitrepos/llama.cpp}"
LLAMA_SERVER_BIN="$LLAMA_CPP_ROOT/build/bin/llama-server"

if [[ ! -x "$LLAMA_SERVER_BIN" ]]; then
  echo "llama-server binary not found: $LLAMA_SERVER_BIN" >&2
  exit 1
fi

echo "Starting main server (port $LLAMA_PORT) → log: $LOG_FILE"
nohup "$LLAMA_SERVER_BIN" \
  --load-mode "$LLAMA_LOAD_MODE" \
  --port "$LLAMA_PORT" \
  --jinja \
  --flash-attn "$LLAMA_FLASH_ATTN" \
  --cache-type-k "$LLAMA_CACHE_TYPE_K" \
  --cache-type-v "$LLAMA_CACHE_TYPE_V" \
  --parallel "$LLAMA_PARALLEL" \
  -t "$LLAMA_THREADS" \
  -c "$LLAMA_CONTEXT" \
  -b "$LLAMA_BATCH" \
  -ub "$LLAMA_UBATCH" \
  --chat-template-file "$LLAMA_CHAT_TEMPLATE" \
  -lv "$LLAMA_LOG_LEVEL" \
  -ngl "$LLAMA_GPU_LAYERS" \
  --temp "$LLAMA_TEMP" \
  --top-p "$LLAMA_TOP_P" \
  --top-k "$LLAMA_TOP_K" \
  --min-p "$LLAMA_MIN_P" \
  --presence-penalty "$LLAMA_PRESENCE_PENALTY" \
  --repeat-penalty "$LLAMA_REPEAT_PENALTY" \
  --spec-type "$LLAMA_SPEC_TYPE" \
  -m "$LLAMA_MODEL_PATH" \
  > "$LOG_FILE" 2>&1 &

echo "PID: $!"
echo "Health check: curl http://localhost:$LLAMA_PORT/health"
