#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env.pi-dev.local"
COMPOSE_FILE="$REPO_ROOT/docker-compose/pi-dev-agent.yml"
BUILD_SCRIPT="$REPO_ROOT/scripts/build_pi_dev_images.sh"
SERVICE_NAME="pi-dev-agent"
SHELL_USER="app_user"
COMPOSE_OVERRIDE_FILE=""

usage() {
  cat <<'USAGE'
Usage: scripts/pi_dev_agent.sh <command> [options]

Commands:
  build              Build both pi-dev images
  build-base         Build only the base image
  build-agent        Build only the agent image
  start              Build both images, then start the pi-dev agent container
  restart            Build both images, then recreate the pi-dev agent container
  stop               Stop and remove the pi-dev agent container
  shell              Open a bash shell in the running container
  logs               Show container logs
  config             Render the compose configuration

Options:
  --env-file PATH    Override the default env file (.env.pi-dev.local)
  -h, --help         Show this help
USAGE
}

require_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Env file not found: $ENV_FILE" >&2
    echo "Create it from .env.pi-dev.local.example before running this script." >&2
    exit 1
  fi
}

load_env_file() {
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

cleanup() {
  if [[ -n "$COMPOSE_OVERRIDE_FILE" && -f "$COMPOSE_OVERRIDE_FILE" ]]; then
    rm -f "$COMPOSE_OVERRIDE_FILE"
  fi
}

trim_whitespace() {
  local value="$1"

  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"

  printf '%s' "$value"
}

validate_repo_path() {
  local repo_path="$1"

  if [[ -z "$repo_path" ]]; then
    echo "GITREPOS_ALLOWLIST contains an empty entry" >&2
    exit 1
  fi

  if [[ "$repo_path" = /* || "$repo_path" = *".."* ]]; then
    echo "GITREPOS_ALLOWLIST entries must stay within GITREPOS_HOST_PATH: '$repo_path'" >&2
    exit 1
  fi
}

create_compose_override() {
  local host_root="${GITREPOS_HOST_PATH:-}"
  local allowlist="${GITREPOS_ALLOWLIST:-}"
  local repo_path=""
  local source_path=""
  local target_path=""

  if [[ -z "$host_root" ]]; then
    echo "Set GITREPOS_HOST_PATH in $ENV_FILE" >&2
    exit 1
  fi

  COMPOSE_OVERRIDE_FILE="$(mktemp "${TMPDIR:-/tmp}/pi-dev-agent.compose.XXXXXX")"

  {
    printf 'services:\n'
    printf '  %s:\n' "$SERVICE_NAME"
    printf '    volumes:\n'

    if [[ -z "$allowlist" ]]; then
      printf '      - type: bind\n'
      printf '        source: %s\n' "$host_root"
      printf '        target: /workspace/gitrepos\n'
    else
      IFS=',' read -r -a repo_list <<< "$allowlist"
      for repo_path in "${repo_list[@]}"; do
        repo_path="$(trim_whitespace "$repo_path")"
        validate_repo_path "$repo_path"

        source_path="$host_root/$repo_path"
        target_path="/workspace/gitrepos/$repo_path"

        if [[ ! -d "$source_path" ]]; then
          echo "Configured repo path does not exist: $source_path" >&2
          exit 1
        fi

        printf '      - type: bind\n'
        printf '        source: %s\n' "$source_path"
        printf '        target: %s\n' "$target_path"
      done
    fi
  } > "$COMPOSE_OVERRIDE_FILE"
}

compose() {
  local compose_args=(--env-file "$ENV_FILE" -f "$COMPOSE_FILE")

  create_compose_override
  compose_args+=( -f "$COMPOSE_OVERRIDE_FILE" )

  docker compose "${compose_args[@]}" "$@"
}

COMMAND=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      if [[ -z "${2:-}" ]]; then
        echo "--env-file requires a path" >&2
        exit 1
      fi
      ENV_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$COMMAND" ]]; then
        COMMAND="$1"
        shift
      else
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$COMMAND" ]]; then
  usage >&2
  exit 1
fi

trap cleanup EXIT

case "$COMMAND" in
  build)
    "$BUILD_SCRIPT"
    ;;
  build-base)
    "$BUILD_SCRIPT" --image base
    ;;
  build-agent)
    "$BUILD_SCRIPT" --image agent
    ;;
  start)
    require_env_file
    load_env_file
    "$BUILD_SCRIPT"
    compose up -d --no-build "$SERVICE_NAME"
    ;;
  restart)
    require_env_file
    load_env_file
    "$BUILD_SCRIPT"
    compose up -d --force-recreate --no-build "$SERVICE_NAME"
    ;;
  stop)
    require_env_file
    load_env_file
    compose rm -f -s "$SERVICE_NAME"
    ;;
  shell)
    require_env_file
    load_env_file
    if ! compose exec "$SERVICE_NAME" getent passwd "$SHELL_USER" >/dev/null 2>&1; then
      echo "The running pi-dev-agent container does not contain user '$SHELL_USER'." >&2
      echo "Recreate it with: scripts/pi_dev_agent.sh restart" >&2
      exit 1
    fi
    compose exec --user "$SHELL_USER" "$SERVICE_NAME" bash
    ;;
  logs)
    require_env_file
    load_env_file
    compose logs -f "$SERVICE_NAME"
    ;;
  config)
    require_env_file
    load_env_file
    compose config
    ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    usage >&2
    exit 1
    ;;
esac