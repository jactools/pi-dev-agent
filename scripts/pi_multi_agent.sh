#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PI Multi-Agent Startup Script
# 
# Starts Pi with the multi-agent orchestrator extension and skills loaded.
# Reads model configuration from ~/.pi/agent/models.json (not hardcoded).
#
# Usage:
#   ./scripts/pi_multi_agent.sh [options]
#
# Options:
#   --mode <mode>      Start mode: auto (default), orchestrator, coder, or chat
#   --model <pattern>  Override model selection
#   -h, --help         Show help
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXTENSION_FILE="$REPO_ROOT/extensions/multi-agent.ts"
SKILLS_DIR="$REPO_ROOT/.agents/skills"
MODELS_JSON="$HOME/.pi/agent/models.json"

# Default settings
START_MODE="auto"
EXTRA_ARGS=""

usage() {
  cat <<'USAGE'
Usage: scripts/pi_multi_agent.sh [options]

Start Pi with the multi-agent orchestrator setup.

Options:
  --mode <mode>      Start mode: auto (default), orchestrator, coder, or chat
                     auto    - Automatic routing between agents (recommended)
                     orchestrator - Start in Orchestrator mode
                     coder   - Start in Coder mode  
                     chat    - Just start Pi with extension loaded
  --model <pattern>  Override model selection pattern
  -h, --help         Show this help message

Examples:
  # Start with automatic routing (default)
  ./scripts/pi_multi_agent.sh

  # Start in Orchestrator mode for planning
  ./scripts/pi_multi_agent.sh --mode orchestrator

  # Start in Coder mode for implementation
  ./scripts/pi_multi_agent.sh --mode coder

  # Use a specific model
  ./scripts/pi_multi_agent.sh --model "local-llm/Qwen3.8-27B-Q8_0.gguf"

Requirements:
  - ~/.pi/agent/models.json must exist with 'mini-ai' and 'local-llm' providers
  - Both llama.cpp servers must be running (ports configured in models.json)
  - Start them with: ./scripts/pi_dev_agent.sh start
USAGE
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --mode requires a value (auto, orchestrator, coder, chat)" >&2
        exit 1
      fi
      START_MODE="$2"
      if [[ ! "$START_MODE" =~ ^(auto|orchestrator|coder|chat)$ ]]; then
        echo "Error: Invalid mode '$START_MODE'. Must be: auto, orchestrator, coder, chat" >&2
        exit 1
      fi
      shift 2
      ;;
    --model)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --model requires a value" >&2
        exit 1
      fi
      EXTRA_ARGS="$EXTRA_ARGS --model $2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# ============================================================================
# Configuration Loading (from ~/.pi/agent/models.json)
# ============================================================================

load_config() {
  if [[ ! -f "$MODELS_JSON" ]]; then
    echo "Error: models.json not found at $MODELS_JSON" >&2
    echo "" >&2
    echo "Please run setup first:" >&2
    echo "  ./scripts/setup_multi_agent.sh" >&2
    exit 1
  fi
  
  # Validate JSON
  if ! jq empty "$MODELS_JSON" 2>/dev/null; then
    echo "Error: models.json is not valid JSON" >&2
    exit 1
  fi
  
  # Require the orchestrator provider, but keep the coder provider optional
  if ! jq -e '.providers["mini-ai"]' "$MODELS_JSON" >/dev/null 2>&1; then
    echo "Error: models.json missing required provider (mini-ai)" >&2
    exit 1
  fi
  
  # Extract configuration dynamically and resolve ${PI_HOST} placeholders for local forwarded tunnels.
  local pi_host="${PI_HOST:-localhost}"
  MINI_AI_BASE_URL=$(jq -r '.providers["mini-ai"].baseUrl' "$MODELS_JSON")
  MINI_AI_BASE_URL="${MINI_AI_BASE_URL//\$\{PI_HOST\}/$pi_host}"
  LOCAL_LLM_BASE_URL=$(jq -r '.providers["local-llm"].baseUrl // empty' "$MODELS_JSON")
  LOCAL_LLM_BASE_URL="${LOCAL_LLM_BASE_URL//\$\{PI_HOST\}/$pi_host}"
  
  # Get first model from each provider (or use pattern matching)
  MINI_AI_MODEL=$(jq -r '.providers["mini-ai"].models[0].id' "$MODELS_JSON")
  LOCAL_LLM_MODEL=$(jq -r '.providers["local-llm"].models[0].id // empty' "$MODELS_JSON")

  # Extract ports from URLs (assuming standard format http://host:port/v1)
  MINI_AI_PORT=$(echo "$MINI_AI_BASE_URL" | awk -F: '{print $3}' | awk -F/ '{print $1}')
  LOCAL_LLM_PORT=$(echo "$LOCAL_LLM_BASE_URL" | awk -F: '{print $3}' | awk -F/ '{print $1}')

  # Extract vision model baseUrl (model-level override under mini-ai)
  VISION_BASE_URL=$(jq -r '.providers["mini-ai"].models[] | select(.id == "Qwen3-VL-8B-Instruct-Q4_K_M.gguf") | .baseUrl // empty' "$MODELS_JSON")
  VISION_BASE_URL="${VISION_BASE_URL//\$\{PI_HOST\}/$pi_host}"
  if [[ -z "$VISION_BASE_URL" ]]; then
    VISION_BASE_URL="http://localhost:8083/v1"
  fi
  VISION_PORT=$(echo "$VISION_BASE_URL" | awk -F: '{print $3}' | awk -F/ '{print $1}')
  VISION_MODEL=$(jq -r '.providers["mini-ai"].models[] | select(.id == "Qwen3-VL-8B-Instruct-Q4_K_M.gguf") | .id // empty' "$MODELS_JSON")
}

# ============================================================================
# Server Health Check Functions
# ============================================================================

check_server() {
  local url="$1"
  local name="$2"
  
  if curl -s -f --max-time 5 "$url/models" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

get_model_from_server() {
  local url="$1"
  
  if response=$(curl -s --max-time 5 "$url/models" 2>/dev/null); then
    echo "$response" | jq -r '.data[].id' 2>/dev/null | head -5
  fi
}

check_servers() {
  local errors=0
  
  echo "Checking llama.cpp server availability..."
  echo ""
  
  # Check mini-ai (Orchestrator)
  if check_server "$MINI_AI_BASE_URL" "mini-ai"; then
    echo "✓ Orchestrator ($MINI_AI_PORT) is running"
    
    models=$(get_model_from_server "$MINI_AI_BASE_URL")
    if [[ -n "$models" ]]; then
      model_count=$(echo "$models" | wc -l)
      echo "  Available models: $model_count"
      
      if echo "$models" | grep -qF "$MINI_AI_MODEL"; then
        echo "  ✓ Target model available"
      else
        echo "  ⚠ Warning: Expected model not found. Available:"
        echo "$models" | sed 's/^/    - /'
      fi
    fi
  else
    echo "✗ Orchestrator ($MINI_AI_PORT) is NOT running"
    errors=$((errors + 1))
  fi
  
  echo ""
  
  # Check local-llm (Coder) only when it is configured
  if [[ -n "$LOCAL_LLM_BASE_URL" ]]; then
    if check_server "$LOCAL_LLM_BASE_URL" "local-llm"; then
      echo "✓ Coder ($LOCAL_LLM_PORT) is running"
      
      models=$(get_model_from_server "$LOCAL_LLM_BASE_URL")
      if [[ -n "$models" ]]; then
        model_count=$(echo "$models" | wc -l)
        echo "  Available models: $model_count"
        
        if echo "$models" | grep -qF "$LOCAL_LLM_MODEL"; then
          echo "  ✓ Target model available"
        else
          echo "  ⚠ Warning: Expected model not found. Available:"
          echo "$models" | sed 's/^/    - /'
        fi
      fi
    else
      echo "⚠ Coder ($LOCAL_LLM_PORT) is not running (optional for this host)"
    fi
  else
    echo "ℹ️ Coder provider is not configured; skipping optional coder check"
  fi
  
  echo ""
  
  if [[ $errors -gt 0 ]]; then
    echo "Error: $errors server(s) not available." >&2
    echo "" >&2
    echo "To start the servers, run:" >&2
    echo "  ./scripts/pi_dev_agent.sh start" >&2
    exit 1
  fi

  # Check vision server (warn-only — auxiliary capability)
  if check_server "$VISION_BASE_URL" "vision"; then
    echo "✓ Vision ($VISION_PORT) is running"
  else
    echo "⚠ Vision ($VISION_PORT) not available (optional — image analysis disabled)"
  fi
  
  return 0
}

# ============================================================================
# Extension and Skill Validation
# ============================================================================

validate_setup() {
  local errors=0
  
  # Check extension file exists
  if [[ ! -f "$EXTENSION_FILE" ]]; then
    echo "✗ Extension file not found: $EXTENSION_FILE" >&2
    errors=$((errors + 1))
  else
    echo "✓ Extension file found: multi-agent.ts"
  fi
  
  # Check skills directory
  if [[ ! -d "$SKILLS_DIR" ]]; then
    echo "✗ Skills directory not found: $SKILLS_DIR" >&2
    errors=$((errors + 1))
  else
    skill_count=$(find "$SKILLS_DIR" -name "SKILL.md" | wc -l)
    if [[ $skill_count -gt 0 ]]; then
      echo "✓ Skills directory found with $skill_count skill(s)"
      
      # List available skills
      find "$SKILLS_DIR" -name "SKILL.md" | while read -r skill_file; do
        skill_name=$(dirname "$skill_file" | xargs basename)
        description=$(grep "^description:" "$skill_file" 2>/dev/null | head -1 | sed 's/^description: *//')
        echo "  - $skill_name: ${description:0:60}..."
      done
    else
      echo "✗ No skills found in $SKILLS_DIR" >&2
      errors=$((errors + 1))
    fi
  fi
  
  # Check models.json exists and is valid
  if [[ ! -f "$MODELS_JSON" ]]; then
    echo "⚠ Warning: models.json not found at $MODELS_JSON" >&2
    echo "  Multi-agent routing may not work correctly" >&2
    errors=$((errors + 1))
  else
    echo "✓ Model configuration found: $MODELS_JSON"
    
    # Verify the required orchestrator provider is configured; coder is optional
    if jq -e '.providers["mini-ai"]' "$MODELS_JSON" >/dev/null 2>&1; then
      echo "  ✓ Required provider (mini-ai) configured"
      if jq -e '.providers["local-llm"]' "$MODELS_JSON" >/dev/null 2>&1; then
        echo "  ✓ Optional coder provider (local-llm) configured"
      else
        echo "  ℹ️ Optional coder provider not configured; using host-only 1234/8083 setup"
      fi
    else
      echo "  ⚠ Warning: mini-ai provider not found in models.json" >&2
      errors=$((errors + 1))
    fi
  fi
  
  echo ""
  
  if [[ $errors -gt 0 ]]; then
    echo "Error: Setup validation failed with $errors error(s)." >&2
    exit 1
  fi
  
  return 0
}

# ============================================================================
# Pi Startup
# ============================================================================

start_pi() {
  local pi_command="pi"
  
  # Add extension flag
  pi_command="$pi_command --extension $EXTENSION_FILE"
  
  # Add skills flags
  if [[ -d "$SKILLS_DIR" ]]; then
    for skill_dir in "$SKILLS_DIR"/*/; do
      if [[ -f "$skill_dir/SKILL.md" ]]; then
        pi_command="$pi_command --skill $skill_dir"
      fi
    done
  fi
  
  # Add model override if specified
  if [[ -n "$EXTRA_ARGS" ]]; then
    pi_command="$pi_command $EXTRA_ARGS"
  else
    # Default to multi-agent virtual model for auto mode
    case "$START_MODE" in
      auto)
        pi_command="$pi_command --model local/multi-agent"
        ;;
      orchestrator)
        pi_command="$pi_command --model mini-ai/$MINI_AI_MODEL"
        ;;
      coder)
        pi_command="$pi_command --model local-llm/$LOCAL_LLM_MODEL"
        ;;
      chat)
        # No model specified, use default
        ;;
    esac
  fi
  
  # Add thinking level based on mode
  case "$START_MODE" in
    orchestrator)
      pi_command="$pi_command --thinking high"
      ;;
    coder)
      pi_command="$pi_command --thinking low"
      ;;
    auto|chat)
      pi_command="$pi_command --thinking medium"
      ;;
  esac
  
  echo "Starting Pi with multi-agent setup..."
  echo ""
  
  # Display startup configuration
  echo "Configuration:"
  echo "  Mode: $START_MODE"
  echo "  Extension: multi-agent.ts"
  
  if [[ -d "$SKILLS_DIR" ]]; then
    skill_count=$(find "$SKILLS_DIR" -name "SKILL.md" | wc -l)
    echo "  Skills: $skill_count loaded"
  fi
  
  case "$START_MODE" in
    auto)
      echo "  Routing: Automatic (coding → Coder, planning → Orchestrator)"
      ;;
    orchestrator)
      echo "  Model: mini-ai/$MINI_AI_MODEL (high thinking)"
      ;;
    coder)
      echo "  Model: local-llm/$LOCAL_LLM_MODEL (low thinking)"
      ;;
    chat)
      echo "  Model: Default"
      ;;
  esac
  
  echo ""
  echo "Commands available after startup:"
  echo "  /multi-agent     - Start automatic routing mode"
  echo "  /orchestrator    - Switch to Orchestrator"
  echo "  /coder           - Switch to Coder"
  echo "  /agent-status    - Check server status"
  echo ""
  
  # Execute Pi command
  eval $pi_command
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
  echo "╔═══════════════════════════════════════════════════════════╗"
  echo "║          PI Multi-Agent Orchestrator Setup               ║"
  echo "╚═══════════════════════════════════════════════════════════╝"
  echo ""
  
  # Load configuration from ~/.pi/agent/models.json
  load_config
  
  # Validate setup (files, configs)
  validate_setup
  
  # Check server availability
  check_servers
  
  # Start Pi
  start_pi
}

# Run main function
main
