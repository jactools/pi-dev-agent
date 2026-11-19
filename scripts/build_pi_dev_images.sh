#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_BASE_IMAGE="${BUILD_BASE_IMAGE:-}"
JAVA_SOURCE_IMAGE="${JAVA_SOURCE_IMAGE:-}"
BUILDKIT_SYNTAX="${BUILDKIT_SYNTAX:-}"
MOODY_NODE_VERSION="${MOODY_NODE_VERSION:-}"
MOODY_JAVA_VERSION="${MOODY_JAVA_VERSION:-}"
SSL_CERT_PATH="${SSL_CERT_PATH:-/etc/ssl/certs/ca-certificates.crt}"

ENV_MODE=""
ENV_NAME=""

usage() {
  cat <<'USAGE'
Usage: scripts/build_pi_dev_images.sh [--local|--corporate] --env dev|test|prod

REQUIRED (exactly one): --local or --corporate
REQUIRED:               --env dev, --env test, or --env prod

--local                  Local development with jacloud.site (public source defaults)
--corporate              Corporate deployment with proxy (explicit registry references)
--env NAME               Environment name; loads .env.<NAME>.<MODE> from the repository root
-h, --help               Show this help

Required Environment Variables (in .env.<NAME>):
  BUILD_BASE_IMAGE         Locally built/loaded moody-ai image (default in local
                           mode: moody-ai-base:latest); required before base build
  JAVA_SOURCE_IMAGE        Java source image (required in corporate mode;
                           local default: eclipse-temurin:25-jdk)
  BUILDKIT_SYNTAX          BuildKit Dockerfile frontend (required in corporate
                           mode; local default: docker/dockerfile:1.7)
  MOODY_NODE_VERSION       Node.js version from moody-ai (local default: 22)
  MOODY_JAVA_VERSION       Java version from moody-ai (local default: 25)
  NPM_CONFIG_FILE          Fallback npmrc path for agent build installs;
                           proxy/npmrc is preferred when present

Examples:
  ./scripts/build_pi_dev_images.sh --local --env dev
  ./scripts/build_pi_dev_images.sh --corporate --env prod
USAGE
}

MODE_FOUND=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) [ "$MODE_FOUND" = true ] && { echo "ERROR: Can only specify one mode" >&2; exit 1; }; ENV_MODE="local"; MODE_FOUND=true; shift ;;
    --corporate) [ "$MODE_FOUND" = true ] && { echo "ERROR: Can only specify one mode" >&2; exit 1; }; ENV_MODE="corporate"; MODE_FOUND=true; shift ;;
    --env)
      if [[ -z "${2:-}" || "${2#-}" != "$2" ]]; then
        echo "ERROR: --env requires a value (dev, test, or prod)" >&2
        exit 1
      fi
      case "$2" in
        dev|test|prod) ENV_NAME="$2" ;;
        *) echo "ERROR: --env must be one of: dev, test, prod (got '$2')" >&2; exit 1 ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ "$MODE_FOUND" = false ]; then
  echo "ERROR: Must specify --local or --corporate (no defaults allowed)" >&2
  exit 1
fi

if [[ -z "$ENV_NAME" ]]; then
  echo "ERROR: Must specify --env dev, --env test, or --env prod (no defaults allowed)" >&2
  exit 1
fi

ENV_FILE="${REPO_ROOT}/.env.${ENV_NAME}.${ENV_MODE}"

if [ ! -f "$ENV_FILE" ]; then echo "ERROR: Environment file not found: $ENV_FILE" >&2; exit 1; fi

echo "Loading environment from: $ENV_FILE"

# Environment files use shell assignment syntax, including comments.
source "$ENV_FILE"

if [[ -f "$REPO_ROOT/proxy/npmrc" ]]; then
  NPM_CONFIG_FILE="$REPO_ROOT/proxy/npmrc"
fi

if [ "$ENV_MODE" = local ]; then
  BUILD_BASE_IMAGE="${BUILD_BASE_IMAGE:-moody-ai-base:latest}"
  JAVA_SOURCE_IMAGE="${JAVA_SOURCE_IMAGE:-eclipse-temurin:25-jdk}"
  BUILDKIT_SYNTAX="${BUILDKIT_SYNTAX:-docker/dockerfile:1.7}"
  MOODY_NODE_VERSION="${MOODY_NODE_VERSION:-22}"
  MOODY_JAVA_VERSION="${MOODY_JAVA_VERSION:-25}"
fi

if [ -z "$BUILD_BASE_IMAGE" ]; then echo "ERROR: BUILD_BASE_IMAGE not set in $ENV_FILE" >&2; exit 1; fi
if [ -z "$JAVA_SOURCE_IMAGE" ]; then
  echo "ERROR: JAVA_SOURCE_IMAGE must be set to a fully qualified corporate image reference in $ENV_FILE (no public fallback)" >&2
  exit 1
fi
if [ -z "$BUILDKIT_SYNTAX" ]; then
  echo "ERROR: BUILDKIT_SYNTAX must be set to a fully qualified corporate Dockerfile frontend reference in $ENV_FILE (no public fallback)" >&2
  exit 1
fi
if [ -z "$MOODY_NODE_VERSION" ]; then echo "ERROR: MOODY_NODE_VERSION not set in $ENV_FILE" >&2; exit 1; fi
if [ -z "$MOODY_JAVA_VERSION" ]; then echo "ERROR: MOODY_JAVA_VERSION not set in $ENV_FILE" >&2; exit 1; fi

PI_DEV_BASE_IMAGE_NAME="${PI_DEV_BASE_IMAGE_NAME:-platform-pi-dev-base}"
PI_DEV_AGENT_IMAGE_NAME="${PI_DEV_AGENT_IMAGE_NAME:-platform-pi-dev-agent}"
PI_DEV_IMAGE_TAG="${PI_DEV_IMAGE_TAG:-latest}"
PI_CODING_AGENT_VERSION="${PI_CODING_AGENT_VERSION:-latest}"
INSTALL_PLAYWRIGHT=true
if [ "$ENV_MODE" = corporate ]; then
  INSTALL_PLAYWRIGHT=false
fi

AGENT_SECRET_ARGS=()
if [ "$ENV_MODE" = corporate ] && [ -z "${NPM_CONFIG_FILE:-}" ]; then
  echo "ERROR: proxy/npmrc or NPM_CONFIG_FILE must be configured for corporate agent builds (no public fallback)" >&2
  exit 1
fi
if [ -n "${NPM_CONFIG_FILE:-}" ]; then
  if [ ! -f "$NPM_CONFIG_FILE" ] || [ ! -r "$NPM_CONFIG_FILE" ]; then
    echo "ERROR: NPM_CONFIG_FILE must name a readable regular file: $NPM_CONFIG_FILE" >&2
    exit 1
  fi
  AGENT_SECRET_ARGS=(--secret "id=npmrc,src=$NPM_CONFIG_FILE")
fi

echo "=== Building moody-ai based pi-dev images ==="
echo "Mode: ${ENV_MODE:-local}"
echo "Env: $ENV_NAME"
echo "BUILD_BASE_IMAGE: $BUILD_BASE_IMAGE"
echo "JAVA_SOURCE_IMAGE: $JAVA_SOURCE_IMAGE"
echo "BUILDKIT_SYNTAX: $BUILDKIT_SYNTAX"
echo "MOODY_NODE_VERSION: $MOODY_NODE_VERSION"
echo ""

COMMON_ARGS=(--build-arg BUILDKIT_SYNTAX="$BUILDKIT_SYNTAX" --build-arg BUILD_BASE_IMAGE="$BUILD_BASE_IMAGE" --build-arg MOODY_NODE_VERSION="$MOODY_NODE_VERSION" --build-arg MOODY_JAVA_VERSION="$MOODY_JAVA_VERSION")

if ! docker image inspect "$BUILD_BASE_IMAGE" > /dev/null; then
  echo "ERROR: Cannot inspect local BUILD_BASE_IMAGE '$BUILD_BASE_IMAGE'. Build moody-ai from its sources using that project's own build instructions, then load/tag the image locally first. Check Docker daemon access if the image is already loaded. No pull will be attempted by this script." >&2
  exit 1
fi

echo "Building ${PI_DEV_BASE_IMAGE_NAME}:${PI_DEV_IMAGE_TAG}"
docker build --file "$REPO_ROOT/docker/pi-dev-base/Dockerfile.pi-dev-base" "${COMMON_ARGS[@]}" \
  --build-arg JAVA_SOURCE_IMAGE="$JAVA_SOURCE_IMAGE" \
  --build-arg SSL_CERT_PATH="$SSL_CERT_PATH" --tag "${PI_DEV_BASE_IMAGE_NAME}:${PI_DEV_IMAGE_TAG}" "$REPO_ROOT"

# The agent image bakes the Moody-AI bundle from the moody-ai git submodule;
# fail fast with a clear hint when it is not checked out (plain 'git clone'
# leaves vendor/moody-ai empty and the COPY steps would fail obscurely).
if [[ ! -f "$REPO_ROOT/vendor/moody-ai/.pi/skills/plan/SKILL.md" ]]; then
  echo "ERROR: moody-ai submodule is not checked out (vendor/moody-ai)." >&2
  echo "Run 'git submodule update --init vendor/moody-ai' and retry." >&2
  exit 1
fi

# Use the local moody-ai checkout as the source of truth for extensions when it
# is available. The Docker build context is this repository, so sync extensions
# into the vendored checkout before building the agent image.
MOODY_AI_REPO_PATH="${MOODY_AI_REPO_PATH:-$HOME/gitrepos/moody-ai}"
MOODY_AI_EXTENSIONS="$MOODY_AI_REPO_PATH/extensions"
VENDORED_EXTENSIONS="$REPO_ROOT/vendor/moody-ai/extensions"
if [[ -d "$MOODY_AI_EXTENSIONS" ]]; then
  rm -rf "$VENDORED_EXTENSIONS"
  mkdir -p "$VENDORED_EXTENSIONS"
  cp -R "$MOODY_AI_EXTENSIONS/." "$VENDORED_EXTENSIONS/"
  echo "Synced moody-ai extensions from $MOODY_AI_EXTENSIONS to vendor/moody-ai/extensions"
else
  echo "moody-ai extensions not found at $MOODY_AI_EXTENSIONS; using vendored extensions as-is."
fi

# ── Repo dependency manifests ───────────────────────────────────────────────
# The agent image bakes a TARGET-PLATFORM node_modules for bind-mounted repos whose
# native optional deps are platform-specific (see "Repo dependency bundles" in
# Dockerfile.pi-dev-agent). Only the manifests come from the host checkout; `npm ci`
# runs inside the build so every binary matches the image's architecture. Staged
# files land under docker/pi-dev-agent/repo-deps/ and are gitignored — never commit.
stage_repo_dep_manifests() {
  local repo_name="$1"
  local source_dir="${GITREPOS_HOST_PATH%/}/${repo_name}"
  local staged_dir="$REPO_ROOT/docker/pi-dev-agent/repo-deps/${repo_name}"

  if [[ -z "${GITREPOS_HOST_PATH:-}" ]]; then
    echo "ERROR: GITREPOS_HOST_PATH is not set in $ENV_FILE; cannot stage dependency manifests for '$repo_name'." >&2
    exit 1
  fi
  if [[ ! -d "$source_dir" ]]; then
    echo "ERROR: Cannot stage dependency manifests for '$repo_name': $source_dir does not exist." >&2
    echo "Set GITREPOS_HOST_PATH in $ENV_FILE to the directory containing that checkout, or place package.json + package-lock.json manually under docker/pi-dev-agent/repo-deps/${repo_name}/ and re-run." >&2
    exit 1
  fi

  local f
  for f in package.json package-lock.json; do
    if [[ ! -f "$source_dir/$f" ]]; then
      echo "ERROR: $source_dir/$f not found (required to bake the '$repo_name' dependency bundle)." >&2
      exit 1
    fi
  done

  mkdir -p "$staged_dir"
  cp "$source_dir/package.json" "$source_dir/package-lock.json" "$staged_dir/"
  echo "Staged $repo_name manifests -> docker/pi-dev-agent/repo-deps/${repo_name}/ (from $source_dir)"
}

stage_repo_dep_manifests dq-made-easy-ui

echo "Building ${PI_DEV_AGENT_IMAGE_NAME}:${PI_DEV_IMAGE_TAG}"
docker build --file "$REPO_ROOT/docker/pi-dev-agent/Dockerfile.pi-dev-agent" "${COMMON_ARGS[@]}" \
  ${AGENT_SECRET_ARGS[@]+"${AGENT_SECRET_ARGS[@]}"} \
  --build-arg INSTALL_PLAYWRIGHT="$INSTALL_PLAYWRIGHT" \
  --build-arg BASE_IMAGE="${PI_DEV_BASE_IMAGE_NAME}:${PI_DEV_IMAGE_TAG}" \
  --build-arg PI_CODING_AGENT_VERSION="${PI_CODING_AGENT_VERSION}" \
  --tag "${PI_DEV_AGENT_IMAGE_NAME}:${PI_DEV_IMAGE_TAG}" "$REPO_ROOT"

echo "Done"
