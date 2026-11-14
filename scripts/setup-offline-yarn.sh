#!/bin/bash
# Setup offline yarn cache for Backstage development
set -e

CACHE_DIR="${1:-/Users/jacbeekers/gitrepos/yarn-cache}"

echo "Setting up offline yarn cache at: $CACHE_DIR"

# Create directory if it doesn't exist
mkdir -p "$CACHE_DIR"

# Pre-populate with yarn packages (run on host first, then the folder gets mounted)
if [ ! -d "$CACHE_DIR/.yarn/install-state.gz" ]; then
    echo "Note: Yarn cache will be populated when you run 'yarn install' in the container"
    echo "The volume mount ensures cached packages are reused offline."
fi

echo ""
echo "Setup complete! To use offline yarn:"
echo "1. Run on host (populates cache):"
echo "   cd /Users/jacbeekers/gitrepos/yarn-cache && yarn install --offline"
echo ""
echo "2. The container will mount this folder at /home/app_user/.yarn-cache"
echo "3. 'yarn install', 'yarn tsc', 'yarn build:backend' will work offline"
