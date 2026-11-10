#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_BASE_IMAGE="${BUILD_BASE_IMAGE:-}"
MOODY_NODE_VERSION="${MOODY_NODE_VERSION:-}"  
MOODY_JAVA_VERSION="${MOODY_JAVA_VERSION:-}"
SSL_CERT_PATH="${SSL_CERT_PATH:-/etc/ssl/certs/ca-certificates.crt}"

ENV_MODE=""

usage() {
  cat <<'USAGE'
Usage: scripts/build_pi_dev_images.sh [--local|--corporate] [OPTIONS]

REQUIRED (exactly one): --local or --corporate

--local                  Use .env.pi-dev.local for local development with jacloud.site
--corporate              Use .env.pi-dev.corporate for corporate deployment with proxy

Options:
  --image base|agent|all   Select which image to build (default: all)
  --tag TAG                Tag to apply to both images (default: latest)
  --agent-version VERSION  pi-coding-agent npm version to install (default: latest)
  -h, --help               Show this help

Required Environment Variables (in .env file):
  BUILD_BASE_IMAGE         moody-ai base image tag
  MOODY_NODE_VERSION       Node.js version from moody-ai
  MOODY_JAVA_VERSION       Java version from moody-ai

Examples:
  ./scripts/build_pi_dev_images.sh --local
  ./scripts/build_pi_dev_images.sh --corporate
USAGE
}

select_image() {
  case "$1" in
    base) BUILD_BASE=true; BUILD_AGENT=false ;;
    agent) BUILD_BASE=false; BUILD_AGENT=true ;;
    all) BUILD_BASE=true; BUILD_AGENT=true ;;
    *) echo "Unknown image selection: $1" >&2; usage >&2; exit 1 ;;
  esac
}

MODE_FOUND=false
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) [ "$MODE_FOUND" = true ] && { echo "ERROR: Can only specify one mode" >&2; exit 1; }; ENV_MODE="local"; MODE_FOUND=true; shift ;;
    --corporate) [ "$MODE_FOUND" = true ] && { echo "ERROR: Can only specify one mode" >&2; exit 1; }; ENV_MODE="corporate"; MODE_FOUND=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --image|--tag|--agent-version) POSITIONAL_ARGS+=("$1"); shift ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ "$MODE_FOUND" = false ]; then
  echo "ERROR: Must specify --local or --corporate (no defaults allowed)" >&2
  exit 1
fi

case "$ENV_MODE" in
  local) ENV_FILE="${REPO_ROOT}/.env.pi-dev.local" ;;
  corporate) ENV_FILE="${REPO_ROOT}/.env.pi-dev.corporate" ;;
esac

if [ ! -f "$ENV_FILE" ]; then echo "ERROR: Environment file not found: $ENV_FILE" >&2; exit 1; fi

echo "Loading environment from: $ENV_FILE"

# Filter comments and empty lines, then source
grep -v '^#' "$ENV_FILE" | grep -v '^[[:space:]]*$' > /tmp/envvars.$$
source /tmp/envvars.$$
rm -f /tmp/envvars.$$

if [ -z "$BUILD_BASE_IMAGE" ]; then echo "ERROR: BUILD_BASE_IMAGE not set in $ENV_FILE" >&2; exit 1; fi
if [ -z "$MOODY_NODE_VERSION" ]; then echo "ERROR: MOODY_NODE_VERSION not set in $ENV_FILE" >&2; exit 1; fi
if [ -z "$MOODY_JAVA_VERSION" ]; then echo "ERROR: MOODY_JAVA_VERSION not set in $ENV_FILE" >&2; exit 1; fi

PI_DEV_BASE_IMAGE_NAME="${PI_DEV_BASE_IMAGE_NAME:-platform-pi-dev-base}"
PI_DEV_AGENT_IMAGE_NAME="${PI_DEV_AGENT_IMAGE_NAME:-platform-pi-dev-agent}"
PI_DEV_IMAGE_TAG="${PI_DEV_IMAGE_TAG:-latest}"
PI_CODING_AGENT_VERSION="${PI_CODING_AGENT_VERSION:-latest}"

BUILD_BASE=false; BUILD_AGENT=false

if [ ${#POSITIONAL_ARGS[@]} -gt 0 ]; then
  while IFS= read -r arg; do
    case "$arg" in
      --image) [ -z "${2:-}" ] && { echo "--image requires base, agent, or all" >&2; exit 1; }; select_image "$2"; shift 2 ;;
      --tag|--agent-version|-h|--help) POSITIONAL_ARGS+=("$arg"); shift ;;
      *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
  done <<< "$(printf '%s\n' "${POSITIONAL_ARGS[@]}")"
else
  select_image all
fi

echo "=== Building moody-ai based pi-dev images ==="
echo "Mode: ${ENV_MODE:-local}"
echo "BUILD_BASE_IMAGE: $BUILD_BASE_IMAGE"
echo "MOODY_NODE_VERSION: $MOODY_NODE_VERSION"
echo ""

COMMON_ARGS=(--build-arg BUILD_BASE_IMAGE="$BUILD_BASE_IMAGE" --build-arg MOODY_NODE_VERSION="$MOODY_NODE_VERSION" --build-arg MOODY_JAVA_VERSION="$MOODY_JAVA_VERSION")

if [ "$BUILD_BASE" = true ]; then
  echo "Building ${PI_DEV_BASE_IMAGE_NAME}:${PI_DEV_IMAGE_TAG}"
  docker build --file "$REPO_ROOT/docker/pi-dev-base/Dockerfile.pi-dev-base" "${COMMON_ARGS[@]}" \
    --build-arg SSL_CERT_PATH="$SSL_CERT_PATH" --tag "${PI_DEV_BASE_IMAGE_NAME}:${PI_DEV_IMAGE_TAG}" "$REPO_ROOT"
fi

if [ "$BUILD_AGENT" = true ]; then
  echo "Building ${PI_DEV_AGENT_IMAGE_NAME}:${PI_DEV_IMAGE_TAG}"
  docker build --file "$REPO_ROOT/docker/pi-dev-agent/Dockerfile.pi-dev-agent" "${COMMON_ARGS[@]}" \
    --build-arg BASE_IMAGE="${PI_DEV_BASE_IMAGE_NAME}:${PI_DEV_IMAGE_TAG}" \
    --build-arg PI_CODING_AGENT_VERSION="${PI_CODING_AGENT_VERSION}" \
    --tag "${PI_DEV_AGENT_IMAGE_NAME}:${PI_DEV_IMAGE_TAG}" "$REPO_ROOT"
fi

echo "Done"
