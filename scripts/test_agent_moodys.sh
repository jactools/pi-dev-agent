#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${PI_DEV_AGENT_IMAGE_NAME:-platform-pi-dev-agent}"
IMAGE_TAG="${PI_DEV_IMAGE_TAG:-latest}"

echo "=== Testing moody-ai Compatibility for pi-dev Agent ==="
echo ""

# Check Node.js and npm work correctly with moody-ai runtime
echo "[1/4] Checking Node.js compatibility..."
docker run --rm \
  -e PYPI_USERNAME="" \
  -e PYPI_PASSWORD="" \
  "${IMAGE_NAME}:${IMAGE_TAG}" \
  bash -c "node --version && npm --version" 2>&1 | grep -E "^v|^npm"

# Check Python/pyenv still works correctly  
echo "[2/4] Checking Python via pyenv..."
docker run --rm \
  -e PYPI_USERNAME="" \
  -e PYPI_PASSWORD="" \
  "${IMAGE_NAME}:${IMAGE_TAG}" \
  bash -c "python3 --version && which pyenv" 2>&1 | grep -E "^Python|^/usr/bin/pyenv"

# Check Java is accessible for any agent features that need it
echo "[3/4] Checking Java runtime..."
docker run --rm \
  -e PYPI_USERNAME="" \
  -e PYPI_PASSWORD="" \
  "${IMAGE_NAME}:${IMAGE_TAG}" \
  bash -c "java --version 2>&1 | head -n1"

# Check Playwright was installed during build (key moody-ai compatibility)
echo "[4/4] Checking Playwright installation..."
docker run --rm \
  -e PYPI_USERNAME="" \
  -e PYPI_PASSWORD="" \
  "${IMAGE_NAME}:${IMAGE_TAG}" \
  bash -c "ls /ms-playwright/ | head -3"

echo ""
echo "=== moody-ai Compatibility Test Complete ==="
