#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$REPO_ROOT/.test-pi-dev-npm-config.$$"
mkdir -p "$FIXTURES/bin" "$FIXTURES/scripts" "$FIXTURES/docker-compose"
trap 'rm -rf "$FIXTURES"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Execute the actual install RUN with credential-free command doubles and paths.
DOCKERFILE="$REPO_ROOT/docker/pi-dev-agent/Dockerfile.pi-dev-agent"
grep -Fxq 'RUN --mount=type=secret,id=npmrc \' "$DOCKERFILE" ||
  fail "npmrc mount must be optional and limited to the install RUN"
awk '
  /^RUN --mount=type=secret,id=npmrc / { active = 1; next }
  active && /^[[:space:]]*--mount=/ { next }
  active { print; if ($0 !~ /\\$/) exit }
' "$DOCKERFILE" |
  sed 's|/run/secrets/npmrc|"$NPM_TEST_SECRET"|g; s|cd /tmp|cd "$NPM_TEST_WORKDIR"|' \
  > "$FIXTURES/install.sh"
cat > "$FIXTURES/bin/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s|%s\n' "${0##*/}" "${NPM_CONFIG_USERCONFIG:-unset}" "$*" >> "$NPM_TEST_LOG"
[[ "${NPM_CONFIG_USERCONFIG:-unset}" == "$NPM_TEST_EXPECTED" ]]
EOF
cp "$FIXTURES/bin/npm" "$FIXTURES/bin/npx"
printf '#!/bin/sh\nexit 0\n' > "$FIXTURES/bin/chmod"
chmod +x "$FIXTURES/bin/"*
export PATH="$FIXTURES/bin:$PATH"
export NPM_TEST_SECRET="$FIXTURES/npm config"
export NPM_TEST_WORKDIR="$FIXTURES"
export NPM_TEST_LOG="$FIXTURES/npm.log"
export PI_CODING_AGENT_VERSION=test-agent PLAYWRIGHT_VERSION=test-playwright
unset NPM_CONFIG_USERCONFIG

for mounted in no yes; do
  if [[ "$mounted" == yes ]]; then
    printf 'registry=https://registry.example.invalid/\n' > "$NPM_TEST_SECRET"
    export NPM_TEST_EXPECTED="$NPM_TEST_SECRET"
  else
    export NPM_TEST_EXPECTED=unset
  fi
  : > "$NPM_TEST_LOG"
  sh "$FIXTURES/install.sh"
  [[ "$(wc -l < "$NPM_TEST_LOG")" -eq 3 ]] || fail "all three npm/npx calls must execute"
  grep -Fq 'npm install' "$FIXTURES/install.sh" || fail "install RUN extraction failed"
  grep -Fq '|playwright install --with-deps chromium' "$NPM_TEST_LOG" ||
    fail "npx must share the npmrc selection"
  echo "PASS: npm install, npx, and final npm install use expected config (mounted=$mounted)"
done
[[ -z "${NPM_CONFIG_USERCONFIG+x}" ]] || fail "userconfig must not escape the install shell"
if grep -Eq '^(ENV|ARG|COPY).*([Nn][Pp][Mm].*[Cc][Oo][Nn][Ff][Ii][Gg]|npmrc)' "$DOCKERFILE"; then
  fail "npmrc must not be copied or persisted as ARG/ENV"
fi

# The wrapper renders build secrets only when explicitly configured.
cp "$SCRIPT_DIR/pi_dev_agent.sh" "$FIXTURES/scripts/"
cp "$REPO_ROOT/docker-compose/pi-dev-agent.yml" "$FIXTURES/docker-compose/"
cat > "$FIXTURES/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == volume && "$2" == rm ]]; then
  printf '%s|' "$@" >> "$COMPOSE_TEST_CALLS"
  printf '\n' >> "$COMPOSE_TEST_CALLS"
  exit 0
fi
[[ "$1" == compose ]] || exit 99
printf '%s\n' "$@" >> "$COMPOSE_TEST_LOG"
printf '%s|' "$@" >> "$COMPOSE_TEST_CALLS"
printf '\n' >> "$COMPOSE_TEST_CALLS"
previous=""
for arg in "$@"; do
  if [[ "$previous" == -f && "$arg" == *".pi-dev-agent.compose."* ]]; then
    cp "$arg" "$COMPOSE_TEST_OVERRIDE"
    printf '%s\n' "$arg" > "$COMPOSE_TEST_OVERRIDE_PATH"
    printf '%s\n' "$arg" >> "$COMPOSE_TEST_PATHS"
  fi
  previous="$arg"
done
if [[ "$*" == *" getent passwd app_user" ]]; then
  if [[ "${COMPOSE_TEST_REMOVE_OVERRIDE:-no}" == yes ]]; then
    rm "$(cat "$COMPOSE_TEST_OVERRIDE_PATH")"
  fi
  exit "${COMPOSE_TEST_GETENT_STATUS:-0}"
fi
EOF
command -p chmod +x "$FIXTURES/bin/docker"
export COMPOSE_TEST_LOG="$FIXTURES/compose.log"
export COMPOSE_TEST_OVERRIDE="$FIXTURES/override.yml"
export COMPOSE_TEST_OVERRIDE_PATH="$FIXTURES/override-path"
export COMPOSE_TEST_CALLS="$FIXTURES/compose-calls"
export COMPOSE_TEST_PATHS="$FIXTURES/compose-paths"
unset NPM_CONFIG_FILE GITREPOS_ALLOWLIST
printf 'GITREPOS_HOST_PATH="%s"\n' "$FIXTURES" > "$FIXTURES/env"
bash "$FIXTURES/scripts/pi_dev_agent.sh" config --env-file "$FIXTURES/env"
if grep -Eq 'secrets:|npmrc|NPM_CONFIG_FILE' "$COMPOSE_TEST_OVERRIDE"; then
  fail "unconfigured local Compose must not require a secret source"
fi
[[ ! -e "$(cat "$COMPOSE_TEST_OVERRIDE_PATH")" ]] || fail "override must be cleaned up"
echo "PASS: local Compose without npmrc remains unchanged"

printf 'NPM_CONFIG_FILE="%s"\n' "$NPM_TEST_SECRET" >> "$FIXTURES/env"
bash "$FIXTURES/scripts/pi_dev_agent.sh" config --env-file "$FIXTURES/env"
grep -Fxq '    build:' "$COMPOSE_TEST_OVERRIDE" || fail "missing build settings"
grep -Fxq '      secrets:' "$COMPOSE_TEST_OVERRIDE" || fail "missing build secret"
grep -Fxq '        - npmrc' "$COMPOSE_TEST_OVERRIDE" || fail "wrong build secret id"
grep -Fxq "    file: '$NPM_TEST_SECRET'" "$COMPOSE_TEST_OVERRIDE" || fail "wrong secret source (path with spaces)"
[[ "$(grep -c npmrc "$COMPOSE_TEST_OVERRIDE")" -eq 2 ]] || fail "npmrc must not be mounted at runtime"
[[ ! -e "$(cat "$COMPOSE_TEST_OVERRIDE_PATH")" ]] || fail "override must be cleaned up"
echo "PASS: wrapper forwards exact npmrc source as an agent build secret only"

for configured in no yes; do
  printf 'GITREPOS_HOST_PATH="%s"\n' "$FIXTURES" > "$FIXTURES/env"
  if [[ "$configured" == yes ]]; then
    printf 'NPM_CONFIG_FILE="%s"\n' "$NPM_TEST_SECRET" >> "$FIXTURES/env"
  fi
  for command in shell reset-config; do
    : > "$COMPOSE_TEST_CALLS"
    : > "$COMPOSE_TEST_PATHS"
    bash "$FIXTURES/scripts/pi_dev_agent.sh" "$command" --env-file "$FIXTURES/env" > "$FIXTURES/output.log" 2>&1 ||
      fail "$command failed (npmrc=$configured)"
    [[ "$(wc -l < "$COMPOSE_TEST_PATHS")" -eq 2 ]] ||
      fail "$command must invoke Compose twice"
    [[ "$(sort -u "$COMPOSE_TEST_PATHS" | wc -l)" -eq 1 ]] ||
      fail "$command must reuse the exact same override path"
    [[ "$(cat "$COMPOSE_TEST_OVERRIDE_PATH")" == "$FIXTURES"/.pi-dev-agent.compose.*.yml ]] ||
      fail "override must remain in the repository root"
    [[ ! -e "$(cat "$COMPOSE_TEST_OVERRIDE_PATH")" ]] || fail "$command must clean up its override"
    if [[ "$command" == shell ]]; then
      [[ "$(wc -l < "$COMPOSE_TEST_CALLS")" -eq 2 ]] || fail "shell must invoke Docker twice"
      sed -n '1p' "$COMPOSE_TEST_CALLS" | grep -Fq '|exec|pi-dev-agent|getent|passwd|app_user|' ||
        fail "shell must check app_user first"
      sed -n '2p' "$COMPOSE_TEST_CALLS" | grep -Fq '|exec|--user|app_user|pi-dev-agent|bash|' ||
        fail "shell must then invoke bash as app_user"
    else
      sed -n '1p' "$COMPOSE_TEST_CALLS" | grep -Fq '|rm|-f|-s|pi-dev-agent|' ||
        fail "reset-config must remove the container first"
      sed -n '2p' "$COMPOSE_TEST_CALLS" | grep -Fxq 'volume|rm|pi-dev-agent_pi-config|' ||
        fail "reset-config must remove the private volume"
      sed -n '3p' "$COMPOSE_TEST_CALLS" | grep -Fq '|up|-d|--no-build|pi-dev-agent|' ||
        fail "reset-config must recreate without building"
    fi
    if [[ "$configured" == yes ]]; then
      grep -Fxq "    file: '$NPM_TEST_SECRET'" "$COMPOSE_TEST_OVERRIDE" ||
        fail "$command must preserve npmrc forwarding"
    elif grep -Eq 'secrets:|npmrc' "$COMPOSE_TEST_OVERRIDE"; then
      fail "$command must not add an unconfigured secret"
    fi
    echo "PASS: $command reuses and cleans up its override (npmrc=$configured)"
  done

  : > "$COMPOSE_TEST_CALLS"
  : > "$COMPOSE_TEST_PATHS"
  if COMPOSE_TEST_GETENT_STATUS=1 bash "$FIXTURES/scripts/pi_dev_agent.sh" shell --env-file "$FIXTURES/env" > "$FIXTURES/output.log" 2>&1; then
    fail "shell accepted a failed user check"
  fi
  [[ "$(wc -l < "$COMPOSE_TEST_CALLS")" -eq 1 ]] || fail "failed user check must not invoke bash"
  grep -Fq "does not contain user 'app_user'" "$FIXTURES/output.log" || fail "missing user-check error"
  [[ ! -e "$(cat "$COMPOSE_TEST_OVERRIDE_PATH")" ]] || fail "failed user check must clean up"
  echo "PASS: failed shell user check skips bash and cleans up (npmrc=$configured)"
done

: > "$COMPOSE_TEST_CALLS"
if COMPOSE_TEST_REMOVE_OVERRIDE=yes bash "$FIXTURES/scripts/pi_dev_agent.sh" shell --env-file "$FIXTURES/env" > "$FIXTURES/output.log" 2>&1; then
  fail "shell silently recreated a missing tracked override"
fi
[[ "$(wc -l < "$COMPOSE_TEST_CALLS")" -eq 1 ]] || fail "missing override must prevent bash"
grep -Fq 'Compose override file disappeared:' "$FIXTURES/output.log" || fail "missing explicit override error"
echo "PASS: disappeared override fails explicitly before bash"

: > "$COMPOSE_TEST_CALLS"
if bash -c '
  printf "unrelated file\n" > "$1/.pi-dev-agent.compose.$$.yml"
  printf "%s\n" "$1/.pi-dev-agent.compose.$$.yml" > "$1/collision-path"
  exec bash "$1/scripts/pi_dev_agent.sh" config --env-file "$1/env"
' _ "$FIXTURES" > "$FIXTURES/output.log" 2>&1; then
  fail "wrapper accepted a pre-existing override path"
fi
[[ ! -s "$COMPOSE_TEST_CALLS" ]] || fail "override collision must fail before Docker"
grep -Fxq 'unrelated file' "$(cat "$FIXTURES/collision-path")" ||
  fail "override collision must preserve the unrelated file"
rm "$(cat "$FIXTURES/collision-path")"
echo "PASS: PID collision preserves the pre-existing override"

rm "$NPM_TEST_SECRET" "$COMPOSE_TEST_LOG"
if bash "$FIXTURES/scripts/pi_dev_agent.sh" config --env-file "$FIXTURES/env" > "$FIXTURES/output.log" 2>&1; then
  fail "wrapper accepted missing configured npmrc"
fi
[[ ! -e "$COMPOSE_TEST_LOG" ]] || fail "wrapper invoked Docker with an invalid npmrc"
grep -Fq 'NPM_CONFIG_FILE must name a readable regular file' "$FIXTURES/output.log" ||
  fail "missing explicit npmrc error"
echo "PASS: invalid wrapper npmrc fails before Docker"
bash -n "$SCRIPT_DIR/test_pi_dev_npm_config.sh"
echo "All npm config checks passed (no Docker builds or host credentials)."
