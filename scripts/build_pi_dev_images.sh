#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PI_DEV_BASE_IMAGE_NAME="${PI_DEV_BASE_IMAGE_NAME:-platform-pi-dev-base}"
PI_DEV_AGENT_IMAGE_NAME="${PI_DEV_AGENT_IMAGE_NAME:-platform-pi-dev-agent}"
PI_DEV_IMAGE_TAG="${PI_DEV_IMAGE_TAG:-latest}"
PI_CODING_AGENT_VERSION="${PI_CODING_AGENT_VERSION:-latest}"

BUILD_BASE=false
BUILD_AGENT=false

usage() {
  cat <<'USAGE'
Usage: scripts/build_pi_dev_images.sh [OPTIONS]

Build the shared pi-dev base image and the pi-dev agent image.

Options:
  --image base|agent|all   Select which image to build (default: all)
  --tag TAG                Tag to apply to both images (default: latest)
  --agent-version VERSION  pi-coding-agent npm version to install (default: latest)
  -h, --help               Show this help
USAGE
}

select_image() {
  case "$1" in
    base)
      BUILD_BASE=true
      BUILD_AGENT=false
      ;;
    agent)
      BUILD_BASE=false
      BUILD_AGENT=true
      ;;
    all)
      BUILD_BASE=true
      BUILD_AGENT=true
      ;;
    *)
      echo "Unknown image selection: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
}

if [[ $# -eq 0 ]]; then
  select_image all
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      if [[ -z "${2:-}" ]]; then
        echo "--image requires base, agent, or all" >&2
        exit 1
      fi
      select_image "$2"
      shift 2
      ;;
    --tag)
      if [[ -z "${2:-}" ]]; then
        echo "--tag requires a value" >&2
        exit 1
      fi
      PI_DEV_IMAGE_TAG="$2"
      shift 2
      ;;
    --agent-version)
      if [[ -z "${2:-}" ]]; then
        echo "--agent-version requires a value" >&2
        exit 1
      fi
      PI_CODING_AGENT_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$BUILD_BASE" == true ]]; then
  echo "Building ${PI_DEV_BASE_IMAGE_NAME}:${PI_DEV_IMAGE_TAG}"
  docker build \
    --file "$REPO_ROOT/docker/pi-dev-base/Dockerfile.pi-dev-base" \
    --tag "${PI_DEV_BASE_IMAGE_NAME}:${PI_DEV_IMAGE_TAG}" \
    "$REPO_ROOT"
fi

if [[ "$BUILD_AGENT" == true ]]; then
  echo "Building ${PI_DEV_AGENT_IMAGE_NAME}:${PI_DEV_IMAGE_TAG}"
  docker build \
    --file "$REPO_ROOT/docker/pi-dev-agent/Dockerfile.pi-dev-agent" \
    --build-arg "BASE_IMAGE=${PI_DEV_BASE_IMAGE_NAME}:${PI_DEV_IMAGE_TAG}" \
    --build-arg "PI_CODING_AGENT_VERSION=${PI_CODING_AGENT_VERSION}" \
    --tag "${PI_DEV_AGENT_IMAGE_NAME}:${PI_DEV_IMAGE_TAG}" \
    "$REPO_ROOT"
fi

echo "Done"