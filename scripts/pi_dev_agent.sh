#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_NAME=""
ENV_MODE=""
ENV_FILE=""
COMPOSE_FILE="$REPO_ROOT/docker-compose/pi-dev-agent.yml"
BUILD_SCRIPT="$REPO_ROOT/scripts/build_pi_dev_images.sh"
SERVICE_NAME="pi-dev-agent"
PROXY_SERVICE_NAME="pi-dev-agent-proxy"
SHELL_USER="app_user"
COMPOSE_OVERRIDE_FILE=""
CORPORATE_BLOCKED_DOMAINS_FILE=""
# Logical name of the private pi config volume (see docker-compose/pi-dev-agent.yml).
# The container's ~/.pi lives here, NOT on a bind mount of the host, so its
# models.json (host.docker.internal) never clobbers the host's ~/.pi/agent/models.json.
PI_CONFIG_VOLUME="pi-config"

usage() {
  cat <<'USAGE'
Usage: scripts/pi_dev_agent.sh <command> --local|--corporate --env dev|test|prod

Commands:
  build                         Build both pi-dev images
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
  --local | --corporate  Required; selects the mode-specific env file
  --env dev|test|prod    Required; selects the environment name
  -h, --help             Show this help

The selected env file is .env.<env>.<mode> (for example, .env.dev.local).
USAGE
}

require_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Env file not found: $ENV_FILE" >&2
    echo "Create it from .env.${ENV_NAME}.example and configure it for the selected mode." >&2
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
  if [[ -n "$CORPORATE_BLOCKED_DOMAINS_FILE" && -f "$CORPORATE_BLOCKED_DOMAINS_FILE" ]]; then
    rm -f "$CORPORATE_BLOCKED_DOMAINS_FILE"
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
  local npm_config_source="${NPM_CONFIG_FILE:-}"
  local npm_config_path=""
  local pip_config_source="${PIP_CONFIG_FILE:-}"
  local pip_config_path=""
  local pi_auth_path=""
  local corporate_ca_path=""
  local pi_auth_file="${PI_AUTH_FILE:-${HOME:-}/.pi/agent/auth.json}"
  local blocked_domains_file="$REPO_ROOT/docker/pi-dev-agent/proxy/blocked_domains.txt"
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

  if [[ -f "$REPO_ROOT/proxy/npmrc" ]]; then
    npm_config_source="$REPO_ROOT/proxy/npmrc"
  fi
  if [[ -n "$npm_config_source" ]]; then
    if [[ ! -f "$npm_config_source" || ! -r "$npm_config_source" ]]; then
      echo "npm config must name a readable regular file: $npm_config_source" >&2
      exit 1
    fi
    npm_config_path="$(cd "$(dirname "$npm_config_source")" && pwd)/$(basename "$npm_config_source")"
    # Quote YAML strings and escape Compose interpolation in literal paths.
    npm_config_path="${npm_config_path//\'/\'\'}"
    npm_config_path="${npm_config_path//\$/\$\$}"
  fi

  if [[ -f "$REPO_ROOT/proxy/pip.conf" ]]; then
    pip_config_source="$REPO_ROOT/proxy/pip.conf"
  fi
  if [[ -n "$pip_config_source" ]]; then
    if [[ ! -f "$pip_config_source" || ! -r "$pip_config_source" ]]; then
      echo "pip config must name a readable regular file: $pip_config_source" >&2
      exit 1
    fi
    pip_config_path="$(cd "$(dirname "$pip_config_source")" && pwd)/$(basename "$pip_config_source")"
    pip_config_path="${pip_config_path//\'/\'\'}"
    pip_config_path="${pip_config_path//\$/\$\$}"
  fi

  if [[ "$ENV_MODE" == corporate && -n "${CORPORATE_CA_CERT_FILE:-}" ]]; then
    if [[ ! -f "$CORPORATE_CA_CERT_FILE" || ! -r "$CORPORATE_CA_CERT_FILE" ]]; then
      echo "CORPORATE_CA_CERT_FILE must name a readable regular file: $CORPORATE_CA_CERT_FILE" >&2
      exit 1
    fi
    corporate_ca_path="$(cd "$(dirname "$CORPORATE_CA_CERT_FILE")" && pwd)/$(basename "$CORPORATE_CA_CERT_FILE")"
    corporate_ca_path="${corporate_ca_path//\'/\'\'}"
    corporate_ca_path="${corporate_ca_path//\$/\$\$}"
  fi

  if [[ -f "$pi_auth_file" ]]; then
    if [[ ! -r "$pi_auth_file" ]]; then
      echo "PI_AUTH_FILE must name a readable regular file: $pi_auth_file" >&2
      exit 1
    fi
    pi_auth_path="$(cd "$(dirname "$pi_auth_file")" && pwd)/$(basename "$pi_auth_file")"
    pi_auth_path="${pi_auth_path//\'/\'\'}"
    pi_auth_path="${pi_auth_path//\$/\$\$}"
  elif [[ -n "${PI_AUTH_FILE:-}" ]]; then
    echo "PI_AUTH_FILE must name a readable regular file: $pi_auth_file" >&2
    exit 1
  else
    echo "Host Pi auth file not found; container Copilot auth will be unavailable." >&2
  fi

  if [[ "$ENV_MODE" == corporate ]]; then
    if ! grep -Fxq '.github.com' "$blocked_domains_file"; then
      echo "ERROR: Expected .github.com entry is missing from $blocked_domains_file" >&2
      exit 1
    fi
    CORPORATE_BLOCKED_DOMAINS_FILE="$REPO_ROOT/.pi-dev-agent.blocked-domains.$$.txt"
    (set -o noclobber; : > "$CORPORATE_BLOCKED_DOMAINS_FILE") || exit 1
    awk '$0 != ".github.com"' "$blocked_domains_file" > "$CORPORATE_BLOCKED_DOMAINS_FILE"
  fi

  (set -o noclobber; : > "$override_file") || exit 1
  COMPOSE_OVERRIDE_FILE="$override_file"

  {
    printf 'services:\n'
    if [[ -n "$CORPORATE_BLOCKED_DOMAINS_FILE" ]]; then
      printf '  %s:\n' "$PROXY_SERVICE_NAME"
      printf '    volumes:\n'
      printf '      - type: bind\n'
      printf '        source: %s\n' "$CORPORATE_BLOCKED_DOMAINS_FILE"
      printf '        target: /etc/squid/blocked_domains.txt\n'
      printf '        read_only: true\n'
    fi
    printf '  %s:\n' "$SERVICE_NAME"
    if [[ "$ENV_MODE" == corporate || -n "$pip_config_path" ]]; then
      printf '    environment:\n'
    fi
    if [[ "$ENV_MODE" == corporate ]]; then
      printf '      NODE_TLS_REJECT_UNAUTHORIZED: "0"\n'
    fi
    if [[ -n "$pip_config_path" ]]; then
      printf '      PIP_CONFIG_FILE: /run/secrets/pip.conf\n'
    fi
    if [[ -n "$npm_config_path" ]]; then
      printf '    build:\n'
      printf '      secrets:\n'
      printf '        - npmrc\n'
    fi
    if [[ -n "$npm_config_path" || -n "$pip_config_path" || -n "$pi_auth_path" || -n "$corporate_ca_path" ]]; then
      printf '    secrets:\n'
    fi
    if [[ -n "$npm_config_path" ]]; then
      printf '      - source: npmrc\n'
      printf '        target: npmrc\n'
    fi
    if [[ -n "$pip_config_path" ]]; then
      printf '      - source: pip-config\n'
      printf '        target: pip.conf\n'
    fi
    if [[ -n "$pi_auth_path" ]]; then
      printf '      - source: pi-auth\n'
      printf '        target: pi-auth.json\n'
    fi
    if [[ -n "$corporate_ca_path" ]]; then
      printf '      - source: corporate-ca\n'
      printf '        target: corporate-ca.crt\n'
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
    if [[ -n "$npm_config_path" || -n "$pip_config_path" || -n "$pi_auth_path" || -n "$corporate_ca_path" ]]; then
      printf 'secrets:\n'
    fi
    if [[ -n "$npm_config_path" ]]; then
      printf '  npmrc:\n'
      printf "    file: '%s'\n" "$npm_config_path"
    fi
    if [[ -n "$pip_config_path" ]]; then
      printf '  pip-config:\n'
      printf "    file: '%s'\n" "$pip_config_path"
    fi
    if [[ -n "$pi_auth_path" ]]; then
      printf '  pi-auth:\n'
      printf "    file: '%s'\n" "$pi_auth_path"
    fi
    if [[ -n "$corporate_ca_path" ]]; then
      printf '  corporate-ca:\n'
      printf "    file: '%s'\n" "$corporate_ca_path"
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
    --local|--corporate)
      if [[ -n "$ENV_MODE" ]]; then
        echo "ERROR: Specify only one of --local or --corporate" >&2
        exit 1
      fi
      ENV_MODE="${1#--}"
      shift
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

if [[ -z "$ENV_MODE" ]]; then
  echo "ERROR: Must specify exactly one of --local or --corporate" >&2
  usage >&2
  exit 1
fi

ENV_FILE="$REPO_ROOT/.env.$ENV_NAME.$ENV_MODE"

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
    "$BUILD_SCRIPT" "--$ENV_MODE" --env "$ENV_NAME" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
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
      echo "Recreate it with: scripts/pi_dev_agent.sh restart --$ENV_MODE --env $ENV_NAME" >&2
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