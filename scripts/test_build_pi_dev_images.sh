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
case "${1:-}" in
  image)
    [[ $# -eq 3 && "$2" == inspect && "$3" == "$DOCKER_TEST_LOCAL_IMAGE" ]] || exit 99
    exit "${DOCKER_TEST_INSPECT_STATUS:-0}"
    ;;
  build) ;;
  *) echo "Unexpected Docker command: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$FIXTURES/bin/docker"

new_fixture() {
  CASE_DIR="$FIXTURES/$1"
  mkdir -p "$CASE_DIR/scripts"
  cp "$SCRIPT_DIR/build_pi_dev_images.sh" "$CASE_DIR/scripts/"
}

run_build() (
  unset BUILD_BASE_IMAGE JAVA_SOURCE_IMAGE BUILDKIT_SYNTAX MOODY_NODE_VERSION MOODY_JAVA_VERSION
  unset PI_DEV_BASE_IMAGE_NAME PI_DEV_AGENT_IMAGE_NAME PI_DEV_IMAGE_TAG PI_CODING_AGENT_VERSION
  export PATH="$FIXTURES/bin:$PATH"
  export DOCKER_TEST_LOG="$CASE_DIR/docker.log"
  export DOCKER_TEST_LOCAL_IMAGE="${DOCKER_TEST_LOCAL_IMAGE:-moody-ai-base:latest}"
  export DOCKER_TEST_INSPECT_STATUS="${DOCKER_TEST_INSPECT_STATUS:-0}"
  bash "$CASE_DIR/scripts/build_pi_dev_images.sh" "$@" > "$CASE_DIR/output.log" 2>&1
)

assert_line() {
  if ! grep -Fxq -- "$1" "$2"; then
    echo "FAIL: missing '$1' in $2" >&2
    exit 1
  fi
}

assert_two_builds() {
  [ "$(grep -c '^DOCKER_CALL$' "$CASE_DIR/docker.log")" -eq 3 ]
  [ "$(grep -c '^build$' "$CASE_DIR/docker.log")" -eq 2 ]
}

assert_frontend_on_each_build() {
  awk -v expected="BUILDKIT_SYNTAX=$1" '
    function check() {
      if (command == "build") {
        if (syntax_args != 1 || !matched) exit 1
        if (file ~ /\/pi-dev-base\/Dockerfile.pi-dev-base$/) base++
        else if (file ~ /\/pi-dev-agent\/Dockerfile.pi-dev-agent$/) agent++
        else exit 1
      }
    }
    /^DOCKER_CALL$/ {
      check()
      command = ""; previous = ""; syntax_args = 0; matched = 0; file = ""
      next
    }
    command == "" { command = $0; next }
    {
      if (previous == "--file") file = $0
      if (previous == "--build-arg" && $0 ~ /^BUILDKIT_SYNTAX=/) {
        syntax_args++
        if ($0 == expected) matched = 1
      }
      previous = $0
    }
    END { check(); if (base != 1 || agent != 1) exit 1 }
  ' "$CASE_DIR/docker.log" || {
    echo "FAIL: exact BUILDKIT_SYNTAX build arg not forwarded once on each build" >&2
    exit 1
  }
  assert_line "BUILDKIT_SYNTAX: $1" "$CASE_DIR/output.log"
}

assert_inspected_first() {
  printf '%s\n' DOCKER_CALL image inspect "$1" > "$CASE_DIR/expected-inspect"
  head -n 4 "$CASE_DIR/docker.log" > "$CASE_DIR/actual-inspect"
  cmp -s "$CASE_DIR/expected-inspect" "$CASE_DIR/actual-inspect"
}

new_fixture corporate-explicit
cat > "$CASE_DIR/.env.pi-dev.corporate" <<'EOF'
BUILD_BASE_IMAGE=moody-ai-base:latest
JAVA_SOURCE_IMAGE=registry.example.invalid:5000/team/java@sha256:0123456789abcdef
BUILDKIT_SYNTAX=registry.example.invalid:5000/team/docker/dockerfile:1.7
MOODY_NODE_VERSION=22
MOODY_JAVA_VERSION=25
EOF
run_build --corporate
assert_two_builds
assert_frontend_on_each_build registry.example.invalid:5000/team/docker/dockerfile:1.7
assert_inspected_first moody-ai-base:latest
assert_line 'BUILD_BASE_IMAGE=moody-ai-base:latest' "$CASE_DIR/docker.log"
assert_line 'JAVA_SOURCE_IMAGE=registry.example.invalid:5000/team/java@sha256:0123456789abcdef' "$CASE_DIR/docker.log"
assert_line 'BASE_IMAGE=platform-pi-dev-base:latest' "$CASE_DIR/docker.log"
echo "PASS: local moody-ai inspected; corporate Java and exact frontend build args forwarded"

new_fixture corporate-local-override
cat > "$CASE_DIR/.env.pi-dev.corporate" <<'EOF'
BUILD_BASE_IMAGE=team/local-moody:custom
JAVA_SOURCE_IMAGE=registry.example.invalid/team/java:approved
BUILDKIT_SYNTAX=registry.example.invalid/team/frontend@sha256:0123456789abcdef
MOODY_NODE_VERSION=22
MOODY_JAVA_VERSION=25
EOF
DOCKER_TEST_LOCAL_IMAGE=team/local-moody:custom run_build --corporate
assert_two_builds
assert_frontend_on_each_build registry.example.invalid/team/frontend@sha256:0123456789abcdef
assert_inspected_first team/local-moody:custom
assert_line 'BUILD_BASE_IMAGE=team/local-moody:custom' "$CASE_DIR/docker.log"
echo "PASS: custom corporate-mode local tag preserved"

new_fixture local-defaults
printf '%s\n' 'MOODY_NODE_VERSION=22' 'MOODY_JAVA_VERSION=25' > "$CASE_DIR/.env.pi-dev.local"
run_build --local
assert_two_builds
assert_frontend_on_each_build docker/dockerfile:1.7
assert_inspected_first moody-ai-base:latest
assert_line 'BUILD_BASE_IMAGE=moody-ai-base:latest' "$CASE_DIR/docker.log"
assert_line 'JAVA_SOURCE_IMAGE=eclipse-temurin:25-jdk' "$CASE_DIR/docker.log"
echo "PASS: local source defaults preserved"

new_fixture local-explicit
cat > "$CASE_DIR/.env.pi-dev.local" <<'EOF'
BUILD_BASE_IMAGE=local-moody:custom
JAVA_SOURCE_IMAGE=local-java:custom
BUILDKIT_SYNTAX=local-frontend:custom
MOODY_NODE_VERSION=22
MOODY_JAVA_VERSION=25
EOF
DOCKER_TEST_LOCAL_IMAGE=local-moody:custom run_build --local
assert_two_builds
assert_frontend_on_each_build local-frontend:custom
assert_inspected_first local-moody:custom
assert_line 'BUILD_BASE_IMAGE=local-moody:custom' "$CASE_DIR/docker.log"
assert_line 'JAVA_SOURCE_IMAGE=local-java:custom' "$CASE_DIR/docker.log"
echo "PASS: explicit local source references preserved"

new_fixture local-empty-frontend
printf '%s\n' 'MOODY_NODE_VERSION=22' 'MOODY_JAVA_VERSION=25' \
  'BUILDKIT_SYNTAX=' > "$CASE_DIR/.env.pi-dev.local"
run_build --local
assert_two_builds
assert_frontend_on_each_build docker/dockerfile:1.7
echo "PASS: empty local frontend uses public local default on both builds"

for mode in local corporate; do
  for status in 1 2; do
    new_fixture "$mode-inspect-failure-$status"
    cat > "$CASE_DIR/.env.pi-dev.$mode" <<'EOF'
BUILD_BASE_IMAGE=moody-ai-base:latest
JAVA_SOURCE_IMAGE=registry.example.invalid/team/java:approved
BUILDKIT_SYNTAX=registry.example.invalid/team/docker/dockerfile:1.7
MOODY_NODE_VERSION=22
MOODY_JAVA_VERSION=25
EOF
    if DOCKER_TEST_INSPECT_STATUS="$status" run_build "--$mode"; then
      echo "FAIL: $mode accepted local image inspection failure $status" >&2
      exit 1
    fi
    assert_inspected_first moody-ai-base:latest
    [ "$(grep -c '^DOCKER_CALL$' "$CASE_DIR/docker.log")" -eq 1 ]
    [ "$(wc -l < "$CASE_DIR/docker.log")" -eq 4 ]
    grep -Fq "Build moody-ai from its sources using that project's own build instructions, then load/tag the image locally first." "$CASE_DIR/output.log"
    grep -Fq "Check Docker daemon access" "$CASE_DIR/output.log"
    echo "PASS: $mode inspection failure $status stops before any build or pull"
  done
done

for state in missing empty; do
  new_fixture "corporate-java-$state"
  printf '%s\n' 'BUILD_BASE_IMAGE=moody-ai-base:latest' \
    'BUILDKIT_SYNTAX=registry.example.invalid/team/docker/dockerfile:1.7' \
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

for state in missing empty; do
  new_fixture "corporate-frontend-$state"
  printf '%s\n' 'BUILD_BASE_IMAGE=moody-ai-base:latest' \
    'JAVA_SOURCE_IMAGE=registry.example.invalid/team/java:approved' \
    'MOODY_NODE_VERSION=22' 'MOODY_JAVA_VERSION=25' > "$CASE_DIR/.env.pi-dev.corporate"
  if [ "$state" = empty ]; then
    printf '%s\n' 'BUILDKIT_SYNTAX=' >> "$CASE_DIR/.env.pi-dev.corporate"
  fi
  if run_build --corporate; then
    echo "FAIL: corporate mode accepted $state BUILDKIT_SYNTAX" >&2
    exit 1
  fi
  assert_line "ERROR: BUILDKIT_SYNTAX must be set to a fully qualified corporate Dockerfile frontend reference in $CASE_DIR/.env.pi-dev.corporate (no public fallback)" "$CASE_DIR/output.log"
  [ ! -e "$CASE_DIR/docker.log" ]
  echo "PASS: $state corporate BUILDKIT_SYNTAX rejected before any Docker invocation"
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
assert_line '# syntax=docker/dockerfile:1.7' "$REPO_ROOT/docker/pi-dev-agent/Dockerfile.pi-dev-agent"
bash -n "$SCRIPT_DIR/build_pi_dev_images.sh" "$SCRIPT_DIR/test_build_pi_dev_images.sh"
echo "PASS: public agent syntax default retained and build/test shell syntax valid"
echo "All build regression checks passed (fake Docker only)."
