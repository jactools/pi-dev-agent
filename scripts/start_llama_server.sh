#!/usr/bin/env bash
set -euo pipefail

# Optional usage pattern:
#   source scripts/llama-server.profile.large-context.env && scripts/start_llama_server.sh
#   source scripts/llama-server.profile.q8-coding.env && scripts/start_llama_server.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_LLAMA_CPP_ROOT="$(cd "$REPO_ROOT/../llama.cpp" 2>/dev/null && pwd || true)"
LLAMA_PROFILE_FILE="${LLAMA_PROFILE_FILE:-}"

if [[ -n "$LLAMA_PROFILE_FILE" ]]; then
  if [[ ! -f "$LLAMA_PROFILE_FILE" ]]; then
    echo "Preset file not found: $LLAMA_PROFILE_FILE" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$LLAMA_PROFILE_FILE"
fi

LLAMA_CPP_ROOT="${LLAMA_CPP_ROOT:-$DEFAULT_LLAMA_CPP_ROOT}"
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-$LLAMA_CPP_ROOT/build/bin/llama-server}"
LLAMA_MODEL_PATH="${LLAMA_MODEL_PATH:-$HOME/Qwen3.8-27B-UD-Q6_K_XL.gguf}"
LLAMA_CHAT_TEMPLATE="${LLAMA_CHAT_TEMPLATE:-$HOME/chat-template.jinja}"
LLAMA_PORT="${LLAMA_PORT:-1234}"
LLAMA_THREADS="${LLAMA_THREADS:-8}"
LLAMA_CONTEXT="${LLAMA_CONTEXT:-65536}"
LLAMA_BATCH="${LLAMA_BATCH:-512}"
LLAMA_UBATCH="${LLAMA_UBATCH:-128}"
LLAMA_GPU_LAYERS="${LLAMA_GPU_LAYERS:-99}"
LLAMA_CACHE_TYPE_K="${LLAMA_CACHE_TYPE_K:-q4_0}"
LLAMA_CACHE_TYPE_V="${LLAMA_CACHE_TYPE_V:-q4_0}"
LLAMA_PARALLEL="${LLAMA_PARALLEL:-1}"
LLAMA_LOG_LEVEL="${LLAMA_LOG_LEVEL:-1}"
LLAMA_TEMP="${LLAMA_TEMP:-0.2}"
LLAMA_TOP_P="${LLAMA_TOP_P:-0.95}"
LLAMA_TOP_K="${LLAMA_TOP_K:-40}"
LLAMA_MIN_P="${LLAMA_MIN_P:-0.0}"
LLAMA_PRESENCE_PENALTY="${LLAMA_PRESENCE_PENALTY:-0.0}"
LLAMA_REPEAT_PENALTY="${LLAMA_REPEAT_PENALTY:-1.05}"
LLAMA_SPEC_TYPE="${LLAMA_SPEC_TYPE:-none}"
LLAMA_REASONING_PRESERVE="${LLAMA_REASONING_PRESERVE:-1}"
LLAMA_LOAD_MODE="${LLAMA_LOAD_MODE:-mmap}"
LLAMA_FLASH_ATTN="${LLAMA_FLASH_ATTN:-on}"

if [[ -z "$LLAMA_CPP_ROOT" || ! -x "$LLAMA_SERVER_BIN" ]]; then
  echo "llama-server binary not found: $LLAMA_SERVER_BIN" >&2
  echo "Set LLAMA_CPP_ROOT or LLAMA_SERVER_BIN to a valid compiled llama.cpp location." >&2
  exit 1
fi

if [[ ! -f "$LLAMA_MODEL_PATH" ]]; then
  echo "Model file not found: $LLAMA_MODEL_PATH" >&2
  exit 1
fi

if [[ ! -f "$LLAMA_CHAT_TEMPLATE" ]]; then
  echo "Chat template not found: $LLAMA_CHAT_TEMPLATE" >&2
  exit 1
fi

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

exec "$LLAMA_SERVER_BIN" "${args[@]}" "$@"