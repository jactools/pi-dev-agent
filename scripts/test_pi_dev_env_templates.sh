#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$REPO_ROOT/.test-pi-dev-env-templates.$$"
mkdir "$FIXTURES"
trap 'rm -rf "$FIXTURES"' EXIT

LOCAL="$REPO_ROOT/.env.pi-dev.local.example"
CORPORATE="$REPO_ROOT/.env.pi-dev.corporate.example"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Extract names only, never values from the user's corporate env file.
keys() {
  sed -nE 's/^[[:space:]]*(#[[:space:]]*)?([A-Z][A-Z0-9_]*)=.*/\2/p' "$1" |
    LC_ALL=C sort
}

cat > "$FIXTURES/expected" <<'EOF'
BUILDKIT_SYNTAX
BUILD_BASE_IMAGE
GITREPOS_ALLOWLIST
GITREPOS_HOST_PATH
HOST_BIN_DIR_HOST_PATH
HOST_SSH_ALIAS
HOST_SSH_HOSTNAME
HOST_SSH_KEY_PATH
HOST_SSH_PORT
HOST_SSH_USER
JAVA_SOURCE_IMAGE
MOODY_JAVA_VERSION
MOODY_NODE_VERSION
NPM_CONFIG_FILE
PIP_CONFIG_FILE
PI_CODING_AGENT_VERSION
PI_DEV_AGENT_DIRECT_ALLOW_HOSTS
PI_DEV_AGENT_IMAGE_NAME
PI_DEV_AGENT_LLAMA_SERVER_URL
PI_DEV_AGENT_NO_PROXY
PI_DEV_AGENT_PORT
PI_DEV_BASE_IMAGE_NAME
PI_DEV_IMAGE_TAG
PYPI_PASSWORD
PYPI_USERNAME
SSL_CERT_PATH
EOF

for template in "$LOCAL" "$CORPORATE"; do
  keys "$template" > "$FIXTURES/keys"
  cmp -s "$FIXTURES/expected" "$FIXTURES/keys" ||
    fail "template shared keys differ (including commented options)"
  bash -n "$template"
  if grep -Eq '^[[:space:]]*(#[[:space:]]*)?(PI_CONFIG_HOST_PATH|SSH_DIR_HOST_PATH)=' "$template"; then
    fail "obsolete settings remain in an example"
  fi
  if grep -Eq '^(GITREPOS_ALLOWLIST|PI_DEV_AGENT_DIRECT_ALLOW_HOSTS|PYPI_USERNAME|PYPI_PASSWORD|NPM_CONFIG_FILE|PIP_CONFIG_FILE)=' "$template"; then
    fail "example activates an optional allowlist, egress exception, credential, or reserved path"
  fi
done
echo "PASS: template key parity, optional settings, and shell syntax"

if [[ -f "$REPO_ROOT/.env.pi-dev.corporate" ]]; then
  # CORPORATE_REGISTRY may remain a user-only helper; never copy its URL to examples.
  keys "$REPO_ROOT/.env.pi-dev.corporate" | LC_ALL=C sort -u > "$FIXTURES/corporate-keys"
  comm -23 "$FIXTURES/expected" "$FIXTURES/corporate-keys" > "$FIXTURES/missing"
  [[ ! -s "$FIXTURES/missing" ]] || fail "user corporate file is missing shared fields"
  bash -n "$REPO_ROOT/.env.pi-dev.corporate"
  echo "PASS: existing corporate file has shared fields and valid syntax (no values inspected)"
else
  echo "SKIP: optional user corporate file is absent"
fi

# Source only examples, in an isolated shell; never source user configuration.
for mode in local corporate; do
  env -i HOME="$FIXTURES/home" PATH="$PATH" bash --noprofile --norc -c '
    set -euo pipefail
    source "$1"
    [[ "$GITREPOS_HOST_PATH" == /absolute/path/to/gitrepos ]]
    [[ "$BUILD_BASE_IMAGE" == moody-ai-base:latest ]]
    [[ "$MOODY_NODE_VERSION" == 22 && "$MOODY_JAVA_VERSION" == 25 ]]
    [[ "$SSL_CERT_PATH" == /etc/ssl/certs/ca-certificates.crt ]]
    [[ "$PI_DEV_BASE_IMAGE_NAME" == platform-pi-dev-base ]]
    [[ "$PI_DEV_AGENT_IMAGE_NAME" == platform-pi-dev-agent ]]
    [[ "$PI_DEV_IMAGE_TAG" == latest && "$PI_CODING_AGENT_VERSION" == latest ]]
    if [[ "$2" == local ]]; then
      [[ "$JAVA_SOURCE_IMAGE" == eclipse-temurin:25-jdk ]]
      [[ "$BUILDKIT_SYNTAX" == docker/dockerfile:1.7 ]]
    else
      [[ "${JAVA_SOURCE_IMAGE+x}" == x && -z "$JAVA_SOURCE_IMAGE" ]]
      [[ "${BUILDKIT_SYNTAX+x}" == x && -z "$BUILDKIT_SYNTAX" ]]
    fi
    [[ -z "${GITREPOS_ALLOWLIST+x}" && -z "${PI_DEV_AGENT_DIRECT_ALLOW_HOSTS+x}" ]]
    [[ -z "${NPM_CONFIG_FILE+x}" && -z "${PIP_CONFIG_FILE+x}" ]]
  ' _ "$REPO_ROOT/.env.pi-dev.$mode.example" "$mode" ||
    fail "example source/default validation failed"
done
echo "PASS: isolated example sourcing and deliberate local/corporate defaults"

COMPOSE="$REPO_ROOT/docker-compose/pi-dev-agent.yml"
awk '
  /^      args:$/ { args = 1; next }
  args && /^    [^ ]/ { args = 0 }
  args && /^        BUILDKIT_SYNTAX: \$\{BUILDKIT_SYNTAX:-docker\/dockerfile:1.7\}$/ { found++ }
  END { exit !(found == 1) }
' "$COMPOSE" || fail "Compose must pass the built-in frontend build arg with the local default"
DEFAULT_NO_PROXY="$(sed -nE 's/^[[:space:]]*NO_PROXY: \$\{PI_DEV_AGENT_NO_PROXY:-([^}]+)\}.*/\1/p' "$COMPOSE")"
[[ -n "$DEFAULT_NO_PROXY" && "$DEFAULT_NO_PROXY" != *".dev.jac.dot"* ]] ||
  fail "Compose no-proxy default missing or overly broad"
for template in "$LOCAL" "$CORPORATE"; do
  grep -Fxq "# PI_DEV_AGENT_NO_PROXY=$DEFAULT_NO_PROXY" "$template" ||
    fail "example no-proxy default differs from Compose"
  grep -Fxq '# HOST_SSH_KEY_PATH=/absolute/path/to/dedicated-host-key' "$template" ||
    fail "dedicated SSH key placeholder missing"
done

# Every env-file interpolation currently exposed by Compose must be documented.
grep -oE '\$\{[A-Z][A-Z0-9_]*' "$COMPOSE" | sed 's/^${//' |
  LC_ALL=C sort -u > "$FIXTURES/compose-keys"
comm -23 "$FIXTURES/compose-keys" "$FIXTURES/expected" > "$FIXTURES/missing"
[[ ! -s "$FIXTURES/missing" ]] || fail "Compose exposes an undocumented env setting"
bash -n "$SCRIPT_DIR/build_pi_dev_images.sh" "$SCRIPT_DIR/pi_dev_agent.sh" \
  "$REPO_ROOT/docker/pi-dev-agent/entrypoint.sh" "$SCRIPT_DIR/test_pi_dev_env_templates.sh" \
  "$SCRIPT_DIR/test_build_pi_dev_images.sh"
echo "PASS: Compose coverage, no-proxy/SSH defaults, and consumer shell syntax"
echo "All env template regression checks passed (no Docker or host credentials)."
