#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKERFILE="$REPO_ROOT/docker/pi-dev-base/Dockerfile.pi-dev-base"

echo "=== Testing moody-ai based pi-dev Base Image ==="
echo ""

# ── Step 1: Check for required environment variables ───────────────────────────
echo "[Step 1] Validating required environment variables..."
BUILD_BASE_IMAGE="${BUILD_BASE_IMAGE:-}"
MOODY_NODE_VERSION="${MOODY_NODE_VERSION:-}"
MOODY_JAVA_VERSION="${MOODY_JAVA_VERSION:-}"

if [ -z "$BUILD_BASE_IMAGE" ]; then
  echo "ERROR: BUILD_BASE_IMAGE is not set. Must be provided via .env.local or command line." >&2
  exit 1
fi

echo "✓ BUILD_BASE_IMAGE=$BUILD_BASE_IMAGE"
echo "✓ MOODY_NODE_VERSION=$MOODY_NODE_VERSION"
echo "✓ MOODY_JAVA_VERSION=$MOODY_JAVA_VERSION"
echo ""

# ── Step 2: Build the base image ──────────────────────────────────────────────
IMAGE_NAME="${PI_DEV_BASE_IMAGE_NAME:-platform-pi-dev-base}"
IMAGE_TAG="${PI_DEV_IMAGE_TAG:-latest}"

echo "[Step 2] Building ${IMAGE_NAME}:${IMAGE_TAG}..."
docker build \
  --file "$DOCKERFILE" \
  --build-arg BUILD_BASE_IMAGE="$BUILD_BASE_IMAGE" \
  --build-arg MOODY_NODE_VERSION="$MOODY_NODE_VERSION" \
  --build-arg MOODY_JAVA_VERSION="$MOODY_JAVA_VERSION" \
  --tag "${IMAGE_NAME}:${IMAGE_TAG}" \
  "$REPO_ROOT"

echo "✓ Base image built successfully"
echo ""

# ── Step 3: Verify image exists and check size ───────────────────────────────
echo "[Step 3] Checking base image details..."
docker images | grep "${IMAGE_NAME}:${IMAGE_TAG}" || {
  echo "ERROR: Image not found in local Docker registry." >&2
  exit 1
}

# Get image ID for later use
IMAGE_ID=$(docker images --format "{{.ID}}" | grep "^${IMAGE_NAME}:${IMAGE_TAG}$" | head -1)
echo "✓ Image ID: ${IMAGE_ID}"
echo ""

# ── Step 4: Test container startup and tool verification ───────────────────────
echo "[Step 4] Testing container functionality..."

# Create a temporary test script inside the container
TEST_SCRIPT='#!/bin/bash
set -euo pipefail

echo "=== pi-dev Base Image Verification Tests ==="
echo ""

# Check available tools
TOOL_LIST=(node npm python3 java kubectl bash zsh jq)
for tool in "${TOOL_LIST[@]}"; do
  if command -v "$tool" &> /dev/null; then
    echo "✓ $tool is installed: $(command -v $tool)"
  else
    echo "✗ $tool NOT found!" >&2
    exit 1
  fi
done

echo ""
echo "--- Version Checks ---"

# Node.js version check (must be 22)
NODE_VERSION=$(node --version)
if [[ "$NODE_VERSION" == *"v22"* ]]; then
  echo "✓ Node.js: $NODE_VERSION"
else
  echo "✗ Expected Node.js v22, got: $NODE_VERSION" >&2
  exit 1
fi

# Python version check (must be 3.13)
PYTHON_VERSION=$(python3 --version | cut -d" " -f2)
if [[ "$PYTHON_VERSION" == *"3.13"* ]]; then
  echo "✓ Python: $PYTHON_VERSION"
else
  echo "✗ Expected Python 3.13, got: $PYTHON_VERSION" >&2
  exit 1
fi

# Java version check (must be 25)
JAVA_VERSION=$(java --version 2>&1 | head -n1 | grep -oE "[0-9]+\.[0-9]+")
if [[ "$JAVA_VERSION" == *"25"* ]]; then
  echo "✓ Java: $JAVA_VERSION"
else
  echo "✗ Expected Java 25, got: $JAVA_VERSION" >&2
  exit 1
fi

# Verify pyenv is available
if command -v pyenv &> /dev/null; then
  echo "✓ pyenv installed at $(command -v pyenv)"
else
  echo "✗ pyenv NOT found!" >&2
  exit 1
fi

# Check SSL certificate path
SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
if [ -f "$SSL_CERT_FILE" ]; then
  echo "✓ SSL cert file exists: $SSL_CERT_FILE"
else
  echo "✗ SSL cert file NOT found: $SSL_CERT_FILE" >&2
  exit 1
fi

# Check workspace directory
if [ -d /workspace ]; then
  echo "✓ Workspace directory exists at /workspace"
else
  echo "✗ Workspace directory NOT found!" >&2
  exit 1
fi

# Check app_user exists
if id -u app_user &>/dev/null; then
  echo "✓ app_user exists (UID: $(id -u app_user))"
else
  echo "✗ app_user NOT found!" >&2
  exit 1
fi

echo ""
echo "=== All tests passed! ==="
'

# Run the test script inside the container
docker run --rm \
  --entrypoint /bin/bash \
  "${IMAGE_NAME}:${IMAGE_TAG}" \
  -c "$TEST_SCRIPT"

echo ""
echo "=== Base Image Test Complete ==="
