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
  docstore start|stop|status|logs|build
                                Manage the Moody-AI Document Store container (separate
                                compose project; data in ~/data/docstore by default).
                                'start' generates the jacloud.site pip/npm configs from
                                this env file's credentials and creates the data folder.
                                'build' rebuilds the store image from the moody-ai repo
                                ($MOODY_AI_REPO_PATH, default ~/gitrepos/moody-ai).
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
  local local_direct_allow_hosts=""
  local local_no_proxy=""
  local local_llama_base_url=""
  local local_vision_server_url=""
  local local_llama_server_url=""
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
  if [[ "$ENV_MODE" == local ]]; then
    local_direct_allow_hosts="${PI_DEV_AGENT_DIRECT_ALLOW_HOSTS:-tunnel-local-llm:8082,tunnel-mini-ai:1234,tunnel-mini-ai:1235,host.docker.internal:${DOC_STORE_API_PORT:-3001}}"
    local_no_proxy="${PI_DEV_AGENT_NO_PROXY:-localhost,127.0.0.1,host.docker.internal,tunnel-local-llm,tunnel-mini-ai,.local,.svc,.svc.cluster.local}"
    local_llama_base_url="${PI_DEV_AGENT_LLAMA_BASE_URL:-http://tunnel-local-llm:8082}"
    local_vision_server_url="${PI_DEV_AGENT_VISION_SERVER_URL:-http://tunnel-mini-ai:1235}"
    local_llama_server_url="${PI_DEV_AGENT_LLAMA_SERVER_URL:-http://localhost:8082}"
    local_direct_allow_hosts="${local_direct_allow_hosts//\'/\'\'}"
    local_no_proxy="${local_no_proxy//\'/\'\'}"
    local_llama_base_url="${local_llama_base_url//\'/\'\'}"
    local_vision_server_url="${local_vision_server_url//\'/\'\'}"
    local_llama_server_url="${local_llama_server_url//\'/\'\'}"
  fi

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
    if [[ "$ENV_MODE" == corporate || "$ENV_MODE" == local || -n "$pip_config_path" ]]; then
      printf '    environment:\n'
    fi
    if [[ "$ENV_MODE" == corporate ]]; then
      printf '      NODE_TLS_REJECT_UNAUTHORIZED: "0"\n'
    fi
    if [[ -n "$pip_config_path" ]]; then
      printf '      PIP_CONFIG_FILE: /run/secrets/pip.conf\n'
    fi
    if [[ "$ENV_MODE" == local ]]; then
      printf "      PI_DEV_AGENT_DIRECT_ALLOW_HOSTS: '%s'\n" "$local_direct_allow_hosts"
      printf "      PI_DEV_AGENT_NO_PROXY: '%s'\n" "$local_no_proxy"
      printf "      LLAMA_BASE_URL: '%s'\n" "$local_llama_base_url"
      printf "      VISION_SERVER_URL: '%s'\n" "$local_vision_server_url"
      printf "      LLAMA_SERVER_URL: '%s'\n" "$local_llama_server_url"
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
    if [[ "$ENV_MODE" == local ]]; then
      printf '    extra_hosts:\n'
      printf '      - tunnel-local-llm:172.31.0.4\n'
      printf '      - tunnel-mini-ai:172.31.0.3\n'
    fi
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
  if [[ "$ENV_MODE" == local ]]; then
    compose_args+=(--profile local)
  fi

  docker compose "${compose_args[@]}" "$@"
}

DOCSTORE_COMPOSE_FILE="$REPO_ROOT/docker-compose/moody-doc-store.yml"
DOCSTORE_CONFIG_DIR="$REPO_ROOT/tmp/docstore"

docstore_compose() {
  docker compose --env-file "$ENV_FILE" -f "$DOCSTORE_COMPOSE_FILE" "$@"
}

# Write jacloud.site registry configs (pip.conf + npmrc) into a target directory.
# Credentials come from the env file (never committed, never baked into images,
# and not exposed as container environment). Mirrors what entrypoint.sh writes to
# /etc/pip.conf inside the agent container. Used for:
#   - runtime bind mounts of the doc-store container (tmp/docstore/), and
#   - the fail-closed BuildKit secrets in moody-ai/proxy/ when building its images.
# Log in against the verdaccio npm registry and return an API token.
# Modern npm (>=10) does NOT send basic auth from username/password .npmrc entries —
# it only uses them for the login handshake. Requests carry `Authorization: Bearer
# <token>`, so generated npmrcs must use _authToken. The npm login protocol is:
# PUT /-/user/org.couchdb.user:<name> with BOTH a Basic auth header AND a JSON body.
fetch_npm_token() {
  local user="${NPM_USERNAME:-}" pass="${NPM_PASSWORD:-}"
  local resp token
  if [[ -z "$user" || -z "$pass" ]]; then
    echo "ERROR: NPM_USERNAME/NPM_PASSWORD missing from $ENV_FILE (needed for the npm registry token)." >&2
    return 1
  fi
  if ! resp="$(curl -kfsS --max-time 30 -u "${user}:${pass}" \
      -X PUT -H 'Content-Type: application/json' \
      -d "{\"name\":\"${user}\",\"password\":\"${pass}\"}" \
      "https://jacloud.site/-/user/org.couchdb.user:${user}")"; then
    echo "ERROR: npm registry login failed (is verdaccio up at https://jacloud.site/?)." >&2
    return 1
  fi
  token="$(printf '%s' "$resp" | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p' | head -1)"
  if [[ -z "$token" ]]; then
    echo "ERROR: npm registry login returned no token (check NPM_* credentials)." >&2
    return 1
  fi
  printf '%s' "$token"
}

write_registry_configs() {
  local dir="$1"
  local pip_conf="$dir/pip.conf"
  local npmrc="$dir/npmrc"
  local pypi_auth=""
  local npm_token

  # Fetch the token first so a failed login never leaves half-written configs behind.
  npm_token="$(fetch_npm_token)" || return 1

  mkdir -p "$dir"

  if [[ -n "${PYPI_USERNAME:-}" && -n "${PYPI_PASSWORD:-}" ]]; then
    pypi_auth="${PYPI_USERNAME}:${PYPI_PASSWORD}@"
  fi

  # NOTE: no extra-index-url fallback to public registries — the jacloud mirror is
  # authoritative (kept complete by platform-foundation's sync_standard_pypi_packages.sh);
  # a package available there must not be superseded by a newer public version.
  {
    printf '[global]\n'
    printf 'index-url = https://%sjacloud.site/pypi/simple/\n' "$pypi_auth"
    printf 'trusted-host = jacloud.site\n'
  } > "$pip_conf"

  # verdaccio is mounted at the SITE ROOT (default Caddy handler): it emits
  # root-absolute tarball URLs (<pkg>/-/<file>.tgz) that only resolve there.
  {
    printf 'registry=https://jacloud.site/\n'
    printf '//jacloud.site/:_authToken=%s\n' "$npm_token"
  } > "$npmrc"

  chmod 600 "$pip_conf" "$npmrc"
}

create_docstore_registry_configs() {
  write_registry_configs "$DOCSTORE_CONFIG_DIR"
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

# Only build forwards extra arguments (to scripts/build_pi_dev_images.sh);
# docstore takes exactly one action argument.
case "$COMMAND" in
  build) ;;
  docstore)
    if [[ ${#EXTRA_ARGS[@]} -ne 1 ]]; then
      echo "docstore requires an action: start, stop, status, or logs" >&2
      usage >&2
      exit 1
    fi
    ;;
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
    if [[ "$ENV_MODE" == local ]]; then
      compose up -d --no-build tunnel-local-llm tunnel-mini-ai "$SERVICE_NAME"
    else
      compose --profile local rm -f -s tunnel-local-llm tunnel-mini-ai
      compose up -d --no-build "$SERVICE_NAME"
    fi
    ;;
  restart)
    require_env_file
    load_env_file
    if [[ "$ENV_MODE" == local ]]; then
      compose up -d --force-recreate --no-build tunnel-local-llm tunnel-mini-ai "$SERVICE_NAME"
    else
      compose --profile local rm -f -s tunnel-local-llm tunnel-mini-ai
      compose up -d --force-recreate --no-build "$SERVICE_NAME"
    fi
    ;;
  stop)
    require_env_file
    load_env_file
    if [[ "$ENV_MODE" == local ]]; then
      compose rm -f -s "$SERVICE_NAME" tunnel-local-llm tunnel-mini-ai
    else
      compose rm -f -s "$SERVICE_NAME"
      compose --profile local rm -f -s tunnel-local-llm tunnel-mini-ai
    fi
    ;;
  docstore)
    require_env_file
    load_env_file
    # Compose interpolates these paths even for status/stop/logs, though those
    # actions do not use the registry. Generate authenticated configs only for
    # start, when the container needs them mounted.
    export DOC_STORE_PIP_CONF="$DOCSTORE_CONFIG_DIR/pip.conf"
    export DOC_STORE_NPMRC="$DOCSTORE_CONFIG_DIR/npmrc"
    case "${EXTRA_ARGS[0]}" in
      start)
        if [[ "$ENV_MODE" == corporate ]]; then
          DOC_STORE_PIP_CONF="${PIP_CONFIG_FILE:-}"
          DOC_STORE_NPMRC="${NPM_CONFIG_FILE:-}"
          for config in DOC_STORE_PIP_CONF DOC_STORE_NPMRC; do
            config_path="${!config}"
            [[ "$config_path" = /* ]] || config_path="$REPO_ROOT/$config_path"
            if [[ -z "$config_path" || ! -f "$config_path" || ! -r "$config_path" ]]; then
              echo "ERROR: $config must name a readable corporate registry config in $ENV_FILE." >&2
              exit 1
            fi
            printf -v "$config" '%s' "$config_path"
          done
          export DOC_STORE_PIP_CONF DOC_STORE_NPMRC
        else
          create_docstore_registry_configs
        fi
        image="${MOODY_DOC_STORE_IMAGE:-moody-ai-document-store:latest}"
        if ! docker image inspect "$image" >/dev/null 2>&1; then
          echo "ERROR: doc store image '$image' not found." >&2
          echo "Build it from the moody-ai repo first (docker compose -f docker-compose.doc-store.yml build), or set MOODY_DOC_STORE_IMAGE in $ENV_FILE." >&2
          exit 1
        fi
        data_dir="${DOC_STORE_DATA_HOST_PATH:-$HOME/data/docstore}"
        mkdir -p "$data_dir"
        # Store layout bootstrap (same semantics as moody-ai's own startup script):
        # an existing config is NEVER touched — pre-existing stores keep their
        # declared collections; only a fresh folder gets the empty '[]' config.
        if [[ ! -f "$data_dir/document-store-config.json" ]]; then
          printf '[]\n' > "$data_dir/document-store-config.json"
          echo "Created empty Document Store config: $data_dir/document-store-config.json"
        fi
        docstore_compose up -d --no-build
        echo "Doc store started: data in $data_dir, API on port ${DOC_STORE_API_PORT:-3001}, WebUI on port ${DOC_STORE_WEBUI_PORT:-3050}."
        ;;
      stop)
        docstore_compose down
        ;;
      status)
        docstore_compose ps
        if curl -ksf "http://localhost:${DOC_STORE_API_PORT:-3001}/health" >/dev/null 2>&1; then
          echo "API healthy: http://localhost:${DOC_STORE_API_PORT:-3001}/health"
        else
          echo "API not responding on port ${DOC_STORE_API_PORT:-3001} (store down or still starting)." >&2
        fi
        ;;
      build)
        # Rebuild the store image from the moody-ai repo (external-build dependency,
        # same model as BUILD_BASE_IMAGE). Needed after bumping moody-ai, e.g. when a
        # newer Document Store API is required by the seeded skills.
        moody_repo="${MOODY_AI_REPO_PATH:-$HOME/gitrepos/moody-ai}"
        if [[ ! -f "$moody_repo/Dockerfile.doc-store" ]]; then
          echo "ERROR: moody-ai repo not found at $moody_repo (set MOODY_AI_REPO_PATH in $ENV_FILE)." >&2
          exit 1
        fi
        if [[ ! -f "$moody_repo/document-store-api/pyproject.toml" ]]; then
          echo "ERROR: document-store-api submodule is not checked out under $moody_repo." >&2
          echo "Run 'cd $moody_repo && git submodule update --init' and retry." >&2
          exit 1
        fi
        # Fail-closed build secrets: create the host-only proxy configs when missing
        # (never overwrite — a user-customized file wins).
        if [[ ! -f "$moody_repo/proxy/pip.conf" || ! -f "$moody_repo/proxy/npmrc" ]]; then
          echo "Writing jacloud.site registry configs to $moody_repo/proxy/ (missing files only)"
          write_registry_configs "$moody_repo/proxy"
        fi
        if ! docker image inspect moody-ai-base:latest >/dev/null 2>&1; then
          echo "Building moody-ai-base first (required by Dockerfile.doc-store)"
          (cd "$moody_repo" && docker compose -f docker-compose.base.yml build)
        fi
        (cd "$moody_repo" && docker compose -f docker-compose.doc-store.yml build)
        echo "Doc store image rebuilt. Apply with: scripts/pi_dev_agent.sh docstore stop --$ENV_MODE --env $ENV_NAME && scripts/pi_dev_agent.sh docstore start --$ENV_MODE --env $ENV_NAME"
        ;;
      logs)
        docstore_compose logs -f
        ;;
      *)
        echo "Unknown docstore action: ${EXTRA_ARGS[0]} (start, stop, status, or logs)" >&2
        exit 1
        ;;
    esac
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
    compose logs --no-color -f "$SERVICE_NAME" |
      perl -pe 's/\e\][^\a]*(?:\a|\e\\)//g; s/\e\[[0-?]*[ -\/]*[@-~]//g; s/\r//g'
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