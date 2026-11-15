#!/usr/bin/env bash
# Stress-test the LLM tunnel path used by pi-dev-agent, from the host.
#
# The test repeats CYCLES interleaved phases so connectivity checks and real
# LLM load alternate like in actual use:
#   soak segment:  fresh HTTP /health checks against both tunnel endpoints. The
#                  total SOAK_DURATION is split evenly across cycles; every check
#                  is a brand-new TCP connection through strict egress -> pinned
#                  IP -> ssh tunnel, i.e. exactly the path that used to fail with
#                  UND_ERR_CONNECT_TIMEOUT (see docker-compose comments).
#   prompt round:  real `pi --print` runs against each model — a simple prompt and
#                  a multi-turn tool-using prompt. Fresh process per run = fresh
#                  undici connection pool, so this exercises new-SYN handling end
#                  to end while the tunnels carry real inference load.
#
# Usage:
#   scripts/pi_dev_agent_stress.sh [--quick] [--duration <s>] [--cycles <n>] [--vision]
#
#   --quick          60s soak in 2 cycles instead of 300s in 3 (fast smoke test)
#   --duration <s>   total soak time in seconds, split across cycles (default 300)
#   --cycles <n>     how many times to repeat the soak+prompt phases (default 3)
#   --vision         also health-check the vision endpoint tunnel-mini-ai:1235
#                    (off by default; that server is often not running)
#
# Env overrides:
#   PI_DEV_AGENT_CONTAINER  container name (default pi-dev-agent-pi-dev-agent-1)
#   LOCAL_LLM_MODEL         model ref for the local-llm provider
#                           (default local-llm/Qwen3.8-27B-UD-Q6_K_M.gguf)
#   MINI_AI_MODEL           model ref for the mini-ai provider
#                           (default mini-ai/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf)
#   SIMPLE_PROMPT / COMPLEX_PROMPT  override the built-in prompts
#
# Exit code: 0 if every check and prompt succeeded, 1 otherwise.

set -euo pipefail

CONTAINER="${PI_DEV_AGENT_CONTAINER:-pi-dev-agent-pi-dev-agent-1}"
LOCAL_LLM_URL="http://tunnel-local-llm:8082"
MINI_AI_URL="http://tunnel-mini-ai:1234"
VISION_URL="http://tunnel-mini-ai:1235"
LOCAL_LLM_MODEL="${LOCAL_LLM_MODEL:-local-llm/Qwen3.8-27B-UD-Q6_K_M.gguf}"
MINI_AI_MODEL="${MINI_AI_MODEL:-mini-ai/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf}"
SIMPLE_PROMPT="${SIMPLE_PROMPT:-hi}"
COMPLEX_PROMPT="${COMPLEX_PROMPT:-To which repos do you have access and check if they have a README.md file in the repo root}"

SOAK_DURATION=300
CYCLES=3
WITH_VISION=false
PROMPT_TIMEOUT=240
HEALTH_TIMEOUT=6

while [[ $# -gt 0 ]]; do
	case "$1" in
		--quick) SOAK_DURATION=60; CYCLES=2 ;;
		--duration) SOAK_DURATION="${2:?--duration needs a value}"; shift ;;
		--cycles) CYCLES="${2:?--cycles needs a value}"; shift ;;
		--vision) WITH_VISION=true ;;
		-h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
	esac
	shift
done

ts() { date +%H:%M:%S; }

echo "== preflight: container + endpoint reachability ($(ts)) =="
if ! docker exec "$CONTAINER" true 2>/dev/null; then
	echo "ERROR: container '$CONTAINER' is not running (start it with scripts/pi_dev_agent.sh start --local --env dev)" >&2
	exit 1
fi

preflight_fail=0
for url in "$LOCAL_LLM_URL" "$MINI_AI_URL"; do
	if code="$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' --max-time "$HEALTH_TIMEOUT" "$url/health" 2>/dev/null)" && [[ "$code" == "200" ]]; then
		echo "   $url -> 200 OK"
	else
		echo "   $url -> UNREACHABLE (code=${code:-timeout}) — check 'docker compose logs tunnel-local-llm / tunnel-mini-ai'" >&2
		preflight_fail=1
	fi
done
if [[ "$WITH_VISION" == true ]]; then
	if code="$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' --max-time "$HEALTH_TIMEOUT" "$VISION_URL/health" 2>/dev/null)" && [[ "$code" == "200" ]]; then
		echo "   $VISION_URL -> 200 OK"
	else
		echo "   WARNING: $VISION_URL unreachable (vision server down?) — continuing, it will show as failures in the soak" >&2
	fi
fi
if [[ "$preflight_fail" -ne 0 ]]; then
	echo "ERROR: preflight failed; aborting before the soak." >&2
	exit 1
fi

llm_ok=0; llm_fail=0
ai_ok=0; ai_fail=0
vis_ok=0; vis_fail=0
iter=0
prompt_ok=0; prompt_fail=0
out_file="$(mktemp)"
trap 'rm -f "$out_file"' EXIT

# Total soak time is split evenly across cycles; each cycle still runs at least
# one check iteration even if its share is shorter than a full check round.
segment=$(( SOAK_DURATION / CYCLES ))
[[ $segment -lt 1 ]] && segment=1

health_check() { # $1=url  -> echoes http code or "000" on failure/timeout
	local out
	out="$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' --max-time "$HEALTH_TIMEOUT" "$1/health" 2>/dev/null)" || true
	echo "${out:-000}"
}

run_prompt() { # $1=label  $2=model-ref  $3=prompt  -> returns pi's rc
	local label="$1" model="$2" prompt="$3"
	local start=$SECONDS rc=0
	docker exec -u app_user "$CONTAINER" timeout "$PROMPT_TIMEOUT" \
		pi --print --model "$model" --no-session "$prompt" >"$out_file" 2>&1 || rc=$?
	local elapsed=$(( SECONDS - start ))
	if [[ $rc -eq 0 ]]; then
		prompt_ok=$((prompt_ok + 1))
		echo "[$(ts)] PASS ${label} (${elapsed}s): $(tail -n 1 "$out_file" | cut -c1-100)"
	else
		prompt_fail=$((prompt_fail + 1))
		echo "[$(ts)] FAIL ${label} rc=$rc (${elapsed}s): $(tail -n 2 "$out_file" | tr '\n' ' ' | cut -c1-200)"
	fi
	return $rc
}

run_prompt_round() {
	run_prompt "local-llm simple  ($LOCAL_LLM_MODEL)" "$LOCAL_LLM_MODEL" "$SIMPLE_PROMPT" || true
	run_prompt "local-llm complex ($LOCAL_LLM_MODEL)" "$LOCAL_LLM_MODEL" "$COMPLEX_PROMPT" || true
	run_prompt "mini-ai   simple  ($MINI_AI_MODEL)" "$MINI_AI_MODEL" "$SIMPLE_PROMPT" || true
	run_prompt "mini-ai   complex ($MINI_AI_MODEL)" "$MINI_AI_MODEL" "$COMPLEX_PROMPT" || true
}

for cycle in $(seq 1 "$CYCLES"); do
	echo "== cycle $cycle/$CYCLES: soak ${segment}s + prompt round (timeout ${PROMPT_TIMEOUT}s each) =="
	end=$(( $(date +%s) + segment ))
	while :; do
		iter=$((iter + 1))

		code="$(health_check "$LOCAL_LLM_URL")"
		if [[ "$code" == "200" ]]; then llm_ok=$((llm_ok + 1)); else llm_fail=$((llm_fail + 1)); echo "[$(ts)] FAIL local-llm code=$code"; fi

		code="$(health_check "$MINI_AI_URL")"
		if [[ "$code" == "200" ]]; then ai_ok=$((ai_ok + 1)); else ai_fail=$((ai_fail + 1)); echo "[$(ts)] FAIL mini-ai   code=$code"; fi

		if [[ "$WITH_VISION" == true ]]; then
			code="$(health_check "$VISION_URL")"
			if [[ "$code" == "200" ]]; then vis_ok=$((vis_ok + 1)); else vis_fail=$((vis_fail + 1)); echo "[$(ts)] FAIL vision    code=$code"; fi
		fi

		echo "[$(ts)] iter $iter: local-llm=${llm_ok}ok/${llm_fail}fail mini-ai=${ai_ok}ok/${ai_fail}fail$([[ "$WITH_VISION" == true ]] && echo \" vision=${vis_ok}ok/${vis_fail}fail\")"
		now=$(date +%s)
		[[ "$now" -ge "$end" ]] && break
		sleep 5
	done

	run_prompt_round
done

echo
echo "== STRESS SUMMARY =="
echo "soak (${SOAK_DURATION}s in ${CYCLES} cycle(s), $iter iterations):"
echo "  local-llm : $llm_ok ok / $llm_fail fail"
echo "  mini-ai   : $ai_ok ok / $ai_fail fail"
if [[ "$WITH_VISION" == true ]]; then
	echo "  vision    : $vis_ok ok / $vis_fail fail"
fi
echo "prompts     : $prompt_ok ok / $prompt_fail fail"

if [[ $((llm_fail + ai_fail + vis_fail + prompt_fail)) -eq 0 ]]; then
	echo "RESULT: PASS"
	exit 0
else
	echo "RESULT: FAIL"
	exit 1
fi
