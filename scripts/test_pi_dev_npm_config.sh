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
[[ "$1" == compose ]] || exit 99
printf '%s\n' "$@" >> "$COMPOSE_TEST_LOG"
previous=""
for arg in "$@"; do
  if [[ "$previous" == -f && "$arg" == *".pi-dev-agent.compose."* ]]; then
    cp "$arg" "$COMPOSE_TEST_OVERRIDE"
    printf '%s\n' "$arg" > "$COMPOSE_TEST_OVERRIDE_PATH"
  fi
  previous="$arg"
done
EOF
command -p chmod +x "$FIXTURES/bin/docker"
export COMPOSE_TEST_LOG="$FIXTURES/compose.log"
export COMPOSE_TEST_OVERRIDE="$FIXTURES/override.yml"
export COMPOSE_TEST_OVERRIDE_PATH="$FIXTURES/override-path"
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
