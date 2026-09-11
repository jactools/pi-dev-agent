#!/usr/bin/env bash
set -euo pipefail

# Optional usage pattern:
#   source scripts/llama-server.profile.large-context.env && scripts/start_llama_server.sh
#   source scripts/llama-server.profile.q8-coding.env && scripts/start_llama_server.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LLAMA_PROFILE_FILE="${LLAMA_PROFILE_FILE:-}"

if [[ -z "$LLAMA_PROFILE_FILE" ]]; then
  LLAMA_PROFILE_FILE="$SCRIPT_DIR/llama-server.profile.large-context.env"
fi

if [[ ! -f "$LLAMA_PROFILE_FILE" ]]; then
  echo "Preset file not found: $LLAMA_PROFILE_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
echo "Using $LLAMA_PROFILE_FILE"
source "$LLAMA_PROFILE_FILE"

LLAMA_SERVER_BIN="${LLAMA_CPP_ROOT}/build/bin/llama-server"

if [[ -z "$LLAMA_CPP_ROOT" || ! -x "$LLAMA_SERVER_BIN" ]]; then
  echo "llama-server binary not found: $LLAMA_SERVER_BIN" >&2
  echo "Set LLAMA_CPP_ROOT or LLAMA_SERVER_BIN to a valid compiled llama.cpp location." >&2
  exit 1
fi
echo "llama-server binary found"

if [[ ! -f "$LLAMA_MODEL_PATH" ]]; then
  echo "Model file not found: $LLAMA_MODEL_PATH" >&2
  exit 1
fi
echo "model found"

if [[ ! -f "$LLAMA_CHAT_TEMPLATE" ]]; then
  echo "Chat template not found: $LLAMA_CHAT_TEMPLATE" >&2
  exit 1
fi
echo "chat template found"

export LD_LIBRARY_PATH="$LLAMA_CPP_ROOT/build/bin${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

args=(
  --load-mode "$LLAMA_LOAD_MODE"
  --port "$LLAMA_PORT"
  --jinja
  --flash-attn "$LLAMA_FLASH_ATTN"
  --cache-type-k "$LLAMA_CACHE_TYPE_K"
  --cache-type-v "$LLAMA_CACHE_TYPE_V"
  --parallel "$LLAMA_PARALLEL"
  -t "$LLAMA_THREADS"
  -c "$LLAMA_CONTEXT"
  -b "$LLAMA_BATCH"
  -ub "$LLAMA_UBATCH"
  --chat-template-file "$LLAMA_CHAT_TEMPLATE"
  -lv "$LLAMA_LOG_LEVEL"
  -ngl "$LLAMA_GPU_LAYERS"
  --temp "$LLAMA_TEMP"
  --top-p "$LLAMA_TOP_P"
  --top-k "$LLAMA_TOP_K"
  --min-p "$LLAMA_MIN_P"
  --presence-penalty "$LLAMA_PRESENCE_PENALTY"
  --repeat-penalty "$LLAMA_REPEAT_PENALTY"
  --spec-type "$LLAMA_SPEC_TYPE"
  -m "$LLAMA_MODEL_PATH"
)

if [[ "$LLAMA_REASONING_PRESERVE" != "0" ]]; then
  args+=(--reasoning-preserve)
fi

echo "Starting server..."
echo "exec $LLAMA_SERVER_BIN ${args[@]} $@"
exec "$LLAMA_SERVER_BIN" "${args[@]}" "$@"
