#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PI Multi-Agent Setup Script
# 
# Sets up the multi-agent configuration by:
# 1. Validating that ~/.pi/agent/models.json has the required providers
# 2. If it doesn't exist, copies from repo's pi/agent/models.json
# 3. Verifies both mini-ai and debian providers are configured
#
# Usage:
#   ./scripts/setup_multi_agent.sh
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_JSON_REPO="$REPO_ROOT/pi/agent/models.json"
MODELS_JSON_PI="$HOME/.pi/agent/models.json"

usage() {
  cat <<'USAGE'
Usage: scripts/setup_multi_agent.sh

Set up multi-agent configuration for Pi.

Description:
  Validates that ~/.pi/agent/models.json exists and contains the required
  'mini-ai' and 'debian' providers for the multi-agent setup.
  
  If ~/.pi/agent/models.json does NOT exist, it will be copied from
  this repository's pi/agent/models.json file.
  
  If ~/.pi/agent/models.json already exists, it is verified but NOT overwritten.

Examples:
  # Setup (copies if needed, verifies if exists)
  ./scripts/setup_multi_agent.sh
USAGE
}

# ============================================================================
# Validation Functions
# ============================================================================

check_models_json() {
  local file="$1"
  local name="$2"
  
  if [[ ! -f "$file" ]]; then
    echo "✗ $name not found: $file" >&2
    return 1
  fi
  
  # Validate JSON syntax
  if ! jq empty "$file" 2>/dev/null; then
    echo "✗ $name is not valid JSON: $file" >&2
    return 1
  fi
  
  # Check for required providers
  if ! jq -e '.providers' "$file" >/dev/null 2>&1; then
    echo "✗ $name missing 'providers' key" >&2
    return 1
  fi
  
  return 0
}

verify_providers() {
  local file="$1"
  local errors=0
  
  # Check for mini-ai provider
  if ! jq -e '.providers["mini-ai"]' "$file" >/dev/null 2>&1; then
    echo "✗ Missing 'mini-ai' provider in $file" >&2
    errors=$((errors + 1))
  else
    model_count=$(jq '.providers["mini-ai"].models | length' "$file")
    base_url=$(jq -r '.providers["mini-ai"].baseUrl' "$file")
    echo "✓ mini-ai provider configured"
    echo "  Base URL: $base_url"
    echo "  Models: $model_count"
  fi
  
  # Check for debian provider
  if ! jq -e '.providers["debian"]' "$file" >/dev/null 2>&1; then
    echo "✗ Missing 'debian' provider in $file" >&2
    errors=$((errors + 1))
  else
    model_count=$(jq '.providers["debian"].models | length' "$file")
    base_url=$(jq -r '.providers["debian"].baseUrl' "$file")
    echo "✓ debian provider configured"
    echo "  Base URL: $base_url"
    echo "  Models: $model_count"
  fi
  
  return $errors
}

# ============================================================================
# Main Setup Logic
# ============================================================================

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║         PI Multi-Agent Configuration Setup               ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Step 1: Validate source models.json in repo
echo "Step 1: Validating repository models.json..."
if ! check_models_json "$MODELS_JSON_REPO" "Repository models.json"; then
  echo ""
  echo "Error: Repository models.json is missing or invalid." >&2
  echo "Please ensure pi/agent/models.json exists and contains valid JSON." >&2
  exit 1
fi

if ! verify_providers "$MODELS_JSON_REPO"; then
  echo ""
  echo "Error: Repository models.json is missing required providers." >&2
  exit 1
fi

echo ""

# Step 2: Check if ~/.pi/agent/models.json already exists
if [[ -f "$MODELS_JSON_PI" ]]; then
  echo "✓ Existing models.json found at $MODELS_JSON_PI"
  echo ""
  echo "ℹ Using existing configuration (not overwriting)"
  echo ""
  
  # Verify the existing file has required providers
  if ! check_models_json "$MODELS_JSON_PI" "Installed models.json"; then
    echo "Error: Existing models.json is invalid." >&2
    exit 1
  fi
  
  if verify_providers "$MODELS_JSON_PI"; then
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║              Configuration Verified! ✓                    ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    echo "Next steps:"
    echo "  1. Start your llama.cpp servers (if not already running)"
    echo "     ./scripts/pi_dev_agent.sh start"
    echo ""
    echo "  2. Start Pi with multi-agent setup"
    echo "     ./scripts/pi_multi_agent.sh"
    echo ""
    echo "  3. Or just use Pi normally - it will auto-detect the providers"
    echo "     pi --extension ./extensions/multi-agent.ts"
    exit 0
  else
    echo ""
    echo "Warning: Existing models.json is missing required providers." >&2
    echo "Please update ~/.pi/agent/models.json to include 'mini-ai' and 'debian' providers." >&2
    exit 1
  fi
else
  echo "✓ No existing models.json found (first-time setup)"
  echo ""
  
  # Step 3: Copy models.json for first-time setup only
  echo "Step 3: Installing models.json..."
  cp "$MODELS_JSON_REPO" "$MODELS_JSON_PI"
  echo "✓ Copied to $MODELS_JSON_PI"
  
  # Step 4: Verify installation
  echo ""
  echo "Step 4: Verifying installation..."
  if check_models_json "$MODELS_JSON_PI" "Installed models.json"; then
    echo "✓ Installation successful"
    
    if verify_providers "$MODELS_JSON_PI"; then
      echo ""
      echo "╔═══════════════════════════════════════════════════════════╗"
      echo "║              Setup Complete! ✓                            ║"
      echo "╚═══════════════════════════════════════════════════════════╝"
      echo ""
      echo "Next steps:"
      echo "  1. Start your llama.cpp servers (if not already running)"
      echo "     ./scripts/pi_dev_agent.sh start"
      echo ""
      echo "  2. Start Pi with multi-agent setup"
      echo "     ./scripts/pi_multi_agent.sh"
      echo ""
      echo "  3. Or just use Pi normally - it will auto-detect the providers"
      echo "     pi --extension ./extensions/multi-agent.ts"
      echo ""
    else
      echo ""
      echo "Warning: Installation completed but verification failed." >&2
      exit 1
    fi
  else
    echo ""
    echo "Error: Installation verification failed." >&2
    exit 1
  fi
fi
