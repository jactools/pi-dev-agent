#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_NAME=""
ENV_FILE=""
COMPOSE_FILE="$REPO_ROOT/docker-compose/pi-dev-agent.yml"
BUILD_SCRIPT="$REPO_ROOT/scripts/build_pi_dev_images.sh"
SERVICE_NAME="pi-dev-agent"
SHELL_USER="app_user"
COMPOSE_OVERRIDE_FILE=""
# Logical name of the private pi config volume (see docker-compose/pi-dev-agent.yml).
# The container's ~/.pi lives here, NOT on a bind mount of the host, so its
# models.json (host.docker.internal) never clobbers the host's ~/.pi/agent/models.json.
PI_CONFIG_VOLUME="pi-config"

usage() {
  cat <<'USAGE'
Usage: scripts/pi_dev_agent.sh <command> --env dev|test|prod [build-options]

Commands:
  build [--local|--corporate]   Build both pi-dev images (requires exactly one mode)
  start                         Start the pi-dev agent container (run 'build' first if
                                the images are missing or stale)
  restart                       Recreate the pi-dev agent container (run 'build' first if
                                the images are missing or stale)
  reset-config                  Wipe the private pi config volume and recreate it,
                                re-seeding models.json from the current image. Run after
                                changing pi/agent/models.json (build first) to pick up new
                                models.
  stop                          Stop and remove the pi-dev agent container
  shell                         Open a bash shell in the running container
  logs                          Show container logs
  config                        Render the compose configuration

Options:
  --env dev|test|prod    Required; selects .env.dev, .env.test, or .env.prod
  -h, --help             Show this help

Build options (forwarded verbatim to scripts/build_pi_dev_images.sh):
  --local | --corporate      Exactly one required for build
USAGE
}

require_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Env file not found: $ENV_FILE" >&2
    echo "Create it from .env.${ENV_NAME}.example before running this script." >&2
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

# Derive the docker compose project name from the 'name:' field in the compose file.
# Named volumes are prefixed with it (e.g., pi-dev-agent_pi-config).
compose_project_name() {
  local name
  name="$(sed -nE 's/^name:[[:space:]]*//p' "$COMPOSE_FILE" | head -n1)"
  printf '%s' "${name:-pi-dev-agent}"
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
  if [[ -n "$COMPOSE_OVERRIDE_FILE" ]]; then
    if [[ ! -f "$COMPOSE_OVERRIDE_FILE" ]]; then
      echo "Compose override file disappeared: $COMPOSE_OVERRIDE_FILE" >&2
      exit 1
    fi
    return 0
  fi

  local host_root="${GITREPOS_HOST_PATH:-}"
  host_root="${host_root%/}"
  local allowlist="${GITREPOS_ALLOWLIST:-}"
  local repo_path=""
  local source_path=""
  local target_path=""
  local npm_config_path=""
  local override_file="$REPO_ROOT/.pi-dev-agent.compose.$$.yml"

  if [[ -z "$host_root" ]]; then
    echo "Set GITREPOS_HOST_PATH in $ENV_FILE" >&2
    exit 1
  fi

  # Mounting the whole gitrepos directory is not allowed: only explicitly
  # configured repos may be visible inside the container.
  if [[ -z "$allowlist" ]]; then
    echo "Set GITREPOS_ALLOWLIST in $ENV_FILE (comma-separated repo paths under GITREPOS_HOST_PATH)." >&2
    echo "Mounting every repo under GITREPOS_HOST_PATH is not permitted." >&2
    exit 1
  fi

  if [[ -n "${NPM_CONFIG_FILE:-}" ]]; then
    if [[ ! -f "$NPM_CONFIG_FILE" || ! -r "$NPM_CONFIG_FILE" ]]; then
      echo "NPM_CONFIG_FILE must name a readable regular file: $NPM_CONFIG_FILE" >&2
      exit 1
    fi
    npm_config_path="$(cd "$(dirname "$NPM_CONFIG_FILE")" && pwd)/$(basename "$NPM_CONFIG_FILE")"
    # Quote YAML strings and escape Compose interpolation in literal paths.
    npm_config_path="${npm_config_path//\'/\'\'}"
    npm_config_path="${npm_config_path//\$/\$\$}"
  fi

  (set -o noclobber; : > "$override_file") || exit 1
  COMPOSE_OVERRIDE_FILE="$override_file"

  {
    printf 'services:\n'
    printf '  %s:\n' "$SERVICE_NAME"
    if [[ -n "$npm_config_path" ]]; then
      printf '    build:\n'
      printf '      secrets:\n'
      printf '        - npmrc\n'
    fi
    printf '    volumes:\n'

    IFS=',' read -r -a repo_list <<< "$allowlist"
    for repo_path in "${repo_list[@]}"; do
      repo_path="$(trim_whitespace "$repo_path")"
      validate_repo_path "$repo_path"
      while [[ "$repo_path" == */ ]]; do repo_path="${repo_path%/}"; done

      source_path="$host_root/$repo_path"
      target_path="/workspace/gitrepos/$repo_path"

      # The pi-dev-agent repo itself must never be mounted into its own container:
      # the agent inside must not see (or modify) the scripts, compose file, or env
      # files that manage it.
      if [[ "$source_path" == "$REPO_ROOT" || \
            "$source_path" == "$REPO_ROOT"/* || \
            "$REPO_ROOT" == "$source_path"/* ]]; then
        echo "ERROR: GITREPOS_ALLOWLIST entry '$repo_path' resolves to the pi-dev-agent repo itself ($source_path). The pi-dev-agent repo must NOT be made available inside its own container." >&2
        exit 1
      fi

      if [[ ! -d "$source_path" ]]; then
        echo "Configured repo path does not exist: $source_path" >&2
        exit 1
      fi

      printf '      - type: bind\n'
      printf '        source: %s\n' "$source_path"
      printf '        target: %s\n' "$target_path"
    done
    if [[ -n "$npm_config_path" ]]; then
      printf 'secrets:\n'
      printf '  npmrc:\n'
      printf "    file: '%s'\n" "$npm_config_path"
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
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      if [[ -z "${2:-}" || "${2#-}" != "$2" ]]; then
        echo "--env requires a value (dev, test, or prod)" >&2
        exit 1
      fi
      case "$2" in
        dev|test|prod) ENV_NAME="$2" ;;
        *) echo "ERROR: --env must be one of: dev, test, prod (got '$2')" >&2; exit 1 ;;
      esac
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
        EXTRA_ARGS+=("$1")
        shift
      fi
      ;;
  esac
done

if [[ -z "$COMMAND" ]]; then
  usage >&2
  exit 1
fi

if [[ -z "$ENV_NAME" ]]; then
  echo "ERROR: Must specify --env dev, --env test, or --env prod (no defaults allowed)" >&2
  usage >&2
  exit 1
fi

ENV_FILE="$REPO_ROOT/.env.$ENV_NAME"

trap cleanup EXIT

# Only build forwards extra arguments (to scripts/build_pi_dev_images.sh).
case "$COMMAND" in
  build) ;;
  *)
    if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
      echo "Unknown argument: ${EXTRA_ARGS[0]}" >&2
      usage >&2
      exit 1
    fi
    ;;
esac

case "$COMMAND" in
  build)
    "$BUILD_SCRIPT" --env "$ENV_NAME" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
    ;;
  start)
    require_env_file
    load_env_file
    compose up -d --no-build "$SERVICE_NAME"
    ;;
  restart)
    require_env_file
    load_env_file
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
  reset-config)
    require_env_file
    load_env_file
    volume_name="$(compose_project_name)_${PI_CONFIG_VOLUME}"
    echo "Resetting pi config volume: $volume_name"
    # Stop/remove the container so the named volume is no longer in use.
    compose rm -f -s "$SERVICE_NAME" >/dev/null 2>&1 || true
    docker volume rm "$volume_name" 2>/dev/null || true
    # Recreate; a fresh volume is seeded with models.json from the current image.
    compose up -d --no-build "$SERVICE_NAME"
    echo "Done: $volume_name recreated and models.json re-seeded."
    ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    usage >&2
    exit 1
    ;;
esac