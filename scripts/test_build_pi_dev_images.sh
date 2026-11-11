#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$REPO_ROOT/.test-build-pi-dev-images.$$"
mkdir "$FIXTURES"
trap 'rm -rf "$FIXTURES"' EXIT

mkdir "$FIXTURES/bin"
cat > "$FIXTURES/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' DOCKER_CALL "$@" >> "$DOCKER_TEST_LOG"
EOF
chmod +x "$FIXTURES/bin/docker"

new_fixture() {
  CASE_DIR="$FIXTURES/$1"
  mkdir -p "$CASE_DIR/scripts"
  cp "$SCRIPT_DIR/build_pi_dev_images.sh" "$CASE_DIR/scripts/"
}

run_build() (
  unset BUILD_BASE_IMAGE JAVA_SOURCE_IMAGE MOODY_NODE_VERSION MOODY_JAVA_VERSION
  unset PI_DEV_BASE_IMAGE_NAME PI_DEV_AGENT_IMAGE_NAME PI_DEV_IMAGE_TAG PI_CODING_AGENT_VERSION
  export PATH="$FIXTURES/bin:$PATH"
  export DOCKER_TEST_LOG="$CASE_DIR/docker.log"
  bash "$CASE_DIR/scripts/build_pi_dev_images.sh" "$@" > "$CASE_DIR/output.log" 2>&1
)

assert_line() {
  if ! grep -Fxq -- "$1" "$2"; then
    echo "FAIL: missing '$1' in $2" >&2
    exit 1
  fi
}

assert_two_builds() {
  [ "$(grep -c '^DOCKER_CALL$' "$CASE_DIR/docker.log")" -eq 2 ]
  [ "$(grep -c '^build$' "$CASE_DIR/docker.log")" -eq 2 ]
}

new_fixture corporate-explicit
cat > "$CASE_DIR/.env.pi-dev.corporate" <<'EOF'
BUILD_BASE_IMAGE=registry.example.invalid:5000/team/moody:approved
JAVA_SOURCE_IMAGE=registry.example.invalid:5000/team/java@sha256:0123456789abcdef
MOODY_NODE_VERSION=22
MOODY_JAVA_VERSION=25
EOF
run_build --corporate
assert_two_builds
assert_line 'BUILD_BASE_IMAGE=registry.example.invalid:5000/team/moody:approved' "$CASE_DIR/docker.log"
assert_line 'JAVA_SOURCE_IMAGE=registry.example.invalid:5000/team/java@sha256:0123456789abcdef' "$CASE_DIR/docker.log"
assert_line 'BASE_IMAGE=platform-pi-dev-base:latest' "$CASE_DIR/docker.log"
echo "PASS: corporate source references forwarded"

new_fixture local-defaults
printf '%s\n' 'MOODY_NODE_VERSION=22' 'MOODY_JAVA_VERSION=25' > "$CASE_DIR/.env.pi-dev.local"
run_build --local
assert_two_builds
assert_line 'BUILD_BASE_IMAGE=moody-ai-base:latest' "$CASE_DIR/docker.log"
assert_line 'JAVA_SOURCE_IMAGE=eclipse-temurin:25-jdk' "$CASE_DIR/docker.log"
echo "PASS: local source defaults preserved"

new_fixture local-explicit
cat > "$CASE_DIR/.env.pi-dev.local" <<'EOF'
BUILD_BASE_IMAGE=local-moody:custom
JAVA_SOURCE_IMAGE=local-java:custom
MOODY_NODE_VERSION=22
MOODY_JAVA_VERSION=25
EOF
run_build --local
assert_line 'BUILD_BASE_IMAGE=local-moody:custom' "$CASE_DIR/docker.log"
assert_line 'JAVA_SOURCE_IMAGE=local-java:custom' "$CASE_DIR/docker.log"
echo "PASS: explicit local source references preserved"

for state in missing empty; do
  new_fixture "corporate-java-$state"
  printf '%s\n' 'BUILD_BASE_IMAGE=registry.example.invalid/team/moody:approved' \
    'MOODY_NODE_VERSION=22' 'MOODY_JAVA_VERSION=25' > "$CASE_DIR/.env.pi-dev.corporate"
  if [ "$state" = empty ]; then
    printf '%s\n' 'JAVA_SOURCE_IMAGE=' >> "$CASE_DIR/.env.pi-dev.corporate"
  fi
  if run_build --corporate; then
    echo "FAIL: corporate mode accepted $state JAVA_SOURCE_IMAGE" >&2
    exit 1
  fi
  assert_line "ERROR: JAVA_SOURCE_IMAGE must be set to a fully qualified corporate image reference in $CASE_DIR/.env.pi-dev.corporate (no public fallback)" "$CASE_DIR/output.log"
  [ ! -e "$CASE_DIR/docker.log" ]
  echo "PASS: $state corporate JAVA_SOURCE_IMAGE rejected before Docker"
done

DOCKERFILE="$REPO_ROOT/docker/pi-dev-base/Dockerfile.pi-dev-base"
assert_line 'FROM ${BUILD_BASE_IMAGE} AS base' "$DOCKERFILE"
assert_line 'FROM ${JAVA_SOURCE_IMAGE} AS java_source' "$DOCKERFILE"
awk '
  /^ARG BUILD_BASE_IMAGE=moody-ai-base:latest$/ { base = 1 }
  /^ARG JAVA_SOURCE_IMAGE=eclipse-temurin:25-jdk$/ { java = 1 }
  /^FROM / { exit !(base && java) }
' "$DOCKERFILE"
echo "PASS: Dockerfile declares both source defaults before first FROM"
echo "All 6 regression checks passed (fake Docker only)."
