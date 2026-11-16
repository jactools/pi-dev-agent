#!/usr/bin/env bash
set -euo pipefail

# A/B benchmark for MTP speculative decoding on the main coding model.
# Starts llama-server twice (on a bench port, never touching your live server):
#   1) baseline: --spec-type none
#   2) mtp:      --spec-type draft-mtp + -md <LLAMA_DRAFT_MODEL>
# and compares generated tokens/sec from the /completion "timings" response.
#
# Usage: ./scripts/bench_mtp_ab.sh [profile] [n_predict]
# Env overrides (set before calling):
#   BENCH_PORT      bench server port        (default 18642)
#   BENCH_RUNS      measured requests/config (default 2, plus one warmup each)
#   BENCH_TIMEOUT   seconds to wait for /health per start-up (default 300)
#   BENCH_CONTEXT   override LLAMA_CONTEXT from the profile (e.g. 4096 to also
#                   measure short-context speed; default: use the profile value,
#                   which reflects real usage at long context)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${1:-$SCRIPT_DIR/llama-server.profile.qwen3-8-27b}"
N_PREDICT="${2:-150}"
PORT="${BENCH_PORT:-18642}"
RUNS="${BENCH_RUNS:-2}"
TIMEOUT_S="${BENCH_TIMEOUT:-300}"

if [[ ! -f "$PROFILE" ]]; then echo "Profile not found: $PROFILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$PROFILE"

LLAMA_CPP_ROOT="${LLAMA_CPP_ROOT:-$HOME/gitrepos/llama.cpp}"
BIN="$LLAMA_CPP_ROOT/build/bin/llama-server"
if [[ ! -x "$BIN" ]]; then echo "llama-server binary not found: $BIN" >&2; exit 1; fi

# Env override for context size (applied after sourcing the profile)
if [[ -n "${BENCH_CONTEXT:-}" ]]; then LLAMA_CONTEXT="$BENCH_CONTEXT"; fi

WORKDIR="${TMPDIR:-/tmp}/pi-bench.$$"
mkdir -p "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT

# Representative prompt (~200 tokens). Override with BENCH_PROMPT_FILE if desired.
if [[ -n "${BENCH_PROMPT_FILE:-}" ]]; then
  PROMPT="$(cat "$BENCH_PROMPT_FILE")"
else
  PROMPT="You are a senior software architect reviewing a pull request that refactors the build pipeline of a large monorepo into independent services with their own CI caches, artifact registries and deployment targets. Explain step by step how you would assess the risk of this migration, which invariants must be preserved during cutover, what rollback strategy to design for each service boundary, and how you would verify that end-to-end integration tests still cover every cross-service contract after the split."
fi

echo "=== A/B bench: MTP speculative decoding ==="
echo "model : $LLAMA_MODEL_PATH"
if [[ -z "${LLAMA_DRAFT_MODEL:-}" ]]; then
  echo "ERROR: LLAMA_DRAFT_MODEL not set in profile — cannot run the MTP leg." >&2
  exit 1
fi
echo "draft : $LLAMA_DRAFT_MODEL"
echo "ctx   : $LLAMA_CONTEXT | n_predict=$N_PREDICT runs/config=$RUNS port=$PORT"
[[ -f "$LLAMA_DRAFT_MODEL" ]] || { echo "ERROR: draft model file not found: $LLAMA_DRAFT_MODEL" >&2; exit 1; }

free_port() {
  local pids i=0
  pids="$(lsof -ti tcp:"$PORT" 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then kill $pids 2>/dev/null; fi
  while lsof -ti tcp:"$PORT" >/dev/null 2>&1; do
    i=$((i + 1))
    if (( i > 30 )); then echo "ERROR: port $PORT still busy." >&2; exit 1; fi
    sleep 1
  done
}

wait_health() { # $1 = pid, $2 = logfile; waits up to TIMEOUT_S for /health ok
  local i=0 out=""
  while (( i < TIMEOUT_S )); do
    kill -0 "$1" 2>/dev/null || { echo "ERROR: server died during start-up." >&2; tail -5 "$2"; exit 1; }
    out="$(curl -s --max-time 3 http://localhost:"$PORT"/health || true)"
    if [[ "$out" == *'"ok"'* ]]; then return 0; fi
    i=$((i + 1)); sleep 1
  done
  echo "ERROR: server not healthy after ${TIMEOUT_S}s." >&2; exit 1
}

# run_config <spec-type> ; prints "<avg_tps>" on stdout, logs to $WORKDIR/<spec>.log
run_config() { # $1 = spec-type; prints average generated tok/s on stdout, details to stderr
  local spec="$1"
  log="$WORKDIR/$spec.log"
  local draft_args="" pid i tps avg resp
  if [[ "$spec" == "draft-mtp" ]]; then
    # Offload draft model to CPU only — M4 unified memory runs out when both target+draft are on GPU
    draft_args="--spec-draft-model ${LLAMA_DRAFT_MODEL} --spec-draft-ngl 0"
  fi

  free_port
  nohup "$BIN" \
    --load-mode "${LLAMA_LOAD_MODE:-mmap}" \
    --port "$PORT" \
    --jinja \
    --flash-attn "${LLAMA_FLASH_ATTN:-on}" \
    --cache-type-k "${LLAMA_CACHE_TYPE_K:-q8_0}" \
    --cache-type-v "${LLAMA_CACHE_TYPE_V:-q8_0}" \
    -t "${LLAMA_THREADS:-10}" \
    -c "$LLAMA_CONTEXT" \
    -b 2048 -ub 1024 \
    -lv "${LLAMA_LOG_LEVEL:-4}" \
    -ngl "${LLAMA_GPU_LAYERS:-99}" \
    --spec-type "$spec" \
    $draft_args \
    -m "$LLAMA_MODEL_PATH" >"$log" 2>&1 &
  pid=$!

  wait_health "$pid" "$log" || { kill "$pid" 2>/dev/null; exit 1; }

  # warmup (first request compiles graphs / warms caches) — result discarded
  if ! curl -sf http://localhost:"$PORT"/completion \
    --data-binary @<(python3 -c 'import json,sys;print(json.dumps({"prompt": sys.argv[1], "n_predict": 8}))' "$PROMPT") >/dev/null; then
    echo "[$spec] ERROR: warmup request failed — server log tail:" >&2
    tail -25 "$log" | sed 's/^ */    /' >&2
    kill "$pid" 2>/dev/null || true
    echo ERR
    return 0
  fi

  tps=""
  for (( i = 0; i < RUNS; i++ )); do
    local resp
    if ! resp=$(curl -s --max-time $((N_PREDICT * 10 + 60)) http://localhost:"$PORT"/completion \
        --data-binary @<(python3 -c 'import json,sys;print(json.dumps({"prompt": sys.argv[1], "n_predict": int(sys.argv[2])}))' "$PROMPT" "$N_PREDICT")); then
      echo "[$spec] ERROR: curl failed — server log tail:" >&2
      tail -15 "$log" | sed 's/^ */    /' >&2
      kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
      echo ERR
      return 0
    fi
    if ! printf '%s' "$resp" | grep -q '"timings"'; then
      echo "[$spec] ERROR: response has no timings — first bytes of body:" >&2
      printf '        %.400s\n' "$resp" >&2
      tail -15 "$log" | sed 's/^ */    /' >&2
      kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
      echo ERR
      return 0
    fi
    tps="$tps $(printf '%s' "$resp" | python3 -c 'import json,sys
t=json.load(sys.stdin)["timings"]
print("%.2f" % (t["predicted_n"]*1000.0/t["predicted_ms"]))')"
  done

  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  if [[ -z "${tps// /}" ]]; then echo ERR; return 0; fi
  avg="$(echo $tps | python3 -c 'import sys;v=list(map(float,sys.stdin.read().split()));print(f"{sum(v)/len(v):.2f}")')"
  echo "[$spec] per-run tps:$tps → avg: ${avg} (log: $log)" >&2
  [[ "$spec" == "draft-mtp" ]] && grep -h "draft acceptance\|acc rate/pos" "$log" | sed 's/^ */    /' >&2 || true
  echo "$avg"
}

echo "--- baseline (--spec-type none) ---"
BASE="$(run_config none)"
echo "--- mtp      (--spec-type draft-mtp + -md) ---"
MTP="$(run_config draft-mtp)"

if [[ -z "$BASE" || $BASE == ERR* ]] || { [[ -z "$MTP" ]] || [[ "$MTP" == ERR* ]]; }; then
  echo 'ERROR: a leg failed — see diagnostics above and the log paths printed for each config.' >&2
  exit 1
fi

printf '\n=== results (generated tokens/sec, higher is better) ===\n'
printf '%-12s %8s\n' "baseline:" "$BASE"
printf '%-12s %8s\n' "mtp:      " "$MTP"
awk -v b="$BASE" -v m="$MTP" 'BEGIN { printf "%-12s %.2fx\n", "speedup:", (b > 0 ? m / b : 0) }'
