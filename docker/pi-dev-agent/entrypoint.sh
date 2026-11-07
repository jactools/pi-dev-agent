#!/usr/bin/env bash
set -euo pipefail

workspace_root="${WORKSPACE_ROOT:-/workspace}"
gitrepos_dir="${GITREPOS_DIR:-${workspace_root}/gitrepos}"
pi_config_dir="${PI_CONFIG_DIR:-/home/app_user/.pi}"
container_user="${CONTAINER_RUN_USER:-app_user}"
container_home="${CONTAINER_HOME:-/home/${container_user}}"
ssh_dir="${container_home}/.ssh"
host_ssh_dir="/mnt/host-ssh"
host_ssh_alias="${HOST_SSH_ALIAS:-}"
host_ssh_user="${HOST_SSH_USER:-}"
host_ssh_hostname="${HOST_SSH_HOSTNAME:-host.docker.internal}"
host_ssh_port="${HOST_SSH_PORT:-22}"
proxy_host="172.31.0.2"
proxy_port="3128"
strict_egress="true"
direct_allow_hosts="${PI_DEV_AGENT_DIRECT_ALLOW_HOSTS:-}"
proxy_wait_seconds="30"

multi_agent_enabled="${PI_DEV_AGENT_MULTI_AGENT_ENABLED:-false}"

is_truthy() {
	case "${1,,}" in
		1|true|yes|on)
			return 0
			;;
		esac

	return 1
}

resolve_ipv4() {
	local host="$1"

	getent ahostsv4 "$host" | awk 'NR == 1 { print $1; exit }'
}

allow_dns_resolvers() {
	local resolver_ip=""

	while read -r _ resolver_ip _; do
		[[ -n "$resolver_ip" ]] || continue
		iptables -A OUTPUT -d "$resolver_ip/32" -p udp --dport 53 -j ACCEPT
		iptables -A OUTPUT -d "$resolver_ip/32" -p tcp --dport 53 -j ACCEPT
	done < <(awk '/^nameserver[[:space:]]+/ { print $1, $2 }' /etc/resolv.conf)
}

allow_direct_destination() {
	local destination="$1"
	local host_part="$destination"
	local port_part=""
	local resolved_ip=""

	if [[ "$destination" == *:* ]]; then
		host_part="${destination%%:*}"
		port_part="${destination##*:}"
	fi

	resolved_ip="$(resolve_ipv4 "$host_part")"
	if [[ -z "$resolved_ip" ]]; then
		echo "Unable to resolve direct egress allowlist host: $host_part" >&2
		exit 1
	fi

	if [[ -n "$port_part" ]]; then
		iptables -A OUTPUT -d "$resolved_ip/32" -p tcp --dport "$port_part" -j ACCEPT
	else
		iptables -A OUTPUT -d "$resolved_ip/32" -j ACCEPT
	fi
}

configure_strict_egress() {
	local proxy_ip=""
	local destination=""
	local attempt=0

	until [[ $attempt -ge $proxy_wait_seconds ]]; do
		proxy_ip="$(resolve_ipv4 "$proxy_host")"
		if [[ -n "$proxy_ip" ]]; then
			break
		fi

		attempt=$((attempt + 1))
		sleep 1
	done

	if [[ -z "$proxy_ip" ]]; then
		echo "Unable to resolve proxy host for strict egress after ${proxy_wait_seconds}s: $proxy_host" >&2
		exit 1
	fi

	iptables -F OUTPUT
	iptables -P OUTPUT DROP
	iptables -A OUTPUT -o lo -j ACCEPT
	iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
	allow_dns_resolvers
	iptables -A OUTPUT -d "$proxy_ip/32" -p tcp --dport "$proxy_port" -j ACCEPT

	if [[ -n "$direct_allow_hosts" ]]; then
		IFS=',' read -r -a direct_destinations <<< "$direct_allow_hosts"
		for destination in "${direct_destinations[@]}"; do
			destination="${destination#${destination%%[![:space:]]*}}"
			destination="${destination%${destination##*[![:space:]]}}"
			[[ -n "$destination" ]] || continue
			allow_direct_destination "$destination"
		done
	fi

	iptables -A OUTPUT -p tcp -m multiport --dports 80,443 -j REJECT --reject-with tcp-reset
}


cleanup_host_ssh_links() {
	local link_path=""
	local target_path=""

	while IFS= read -r -d '' link_path; do
		target_path="$(readlink "$link_path" 2>/dev/null || true)"
		case "$target_path" in
			"$host_ssh_dir"/*)
				rm -f "$link_path"
				;;
		esac
	done < <(find "$ssh_dir" -maxdepth 1 -type l -print0 2>/dev/null)
}

link_host_ssh_file() {
	local source_path="$1"
	local target_name="${2:-$(basename "$source_path")}"

	[[ -f "$source_path" ]] || return 0

	ln -sfn "$source_path" "$ssh_dir/$target_name"
}

write_ssh_config() {
	local config_path="$ssh_dir/config"
	local temp_path="$ssh_dir/.config.tmp"
	local local_known_hosts_path="$ssh_dir/known_hosts.local"

	if [[ -n "$host_ssh_alias" && -z "$host_ssh_user" ]]; then
		echo "HOST_SSH_USER must be set when HOST_SSH_ALIAS is configured" >&2
		exit 1
	fi

	touch "$local_known_hosts_path"
	chmod 600 "$local_known_hosts_path"
	chown "$container_user:$container_user" "$local_known_hosts_path"

	: > "$temp_path"

	if [[ -f "$host_ssh_dir/config" ]]; then
		printf 'Include %s\n' "$host_ssh_dir/config" >> "$temp_path"
	fi

	if [[ -n "$host_ssh_alias" ]]; then
		printf '\nHost %s\n' "$host_ssh_alias" >> "$temp_path"
		printf '  HostName %s\n' "$host_ssh_hostname" >> "$temp_path"
		printf '  User %s\n' "$host_ssh_user" >> "$temp_path"
		printf '  Port %s\n' "$host_ssh_port" >> "$temp_path"
		printf '  UserKnownHostsFile %s\n' "$local_known_hosts_path" >> "$temp_path"
	fi

	if [[ -s "$temp_path" ]]; then
		mv "$temp_path" "$config_path"
		chmod 600 "$config_path"
		chown "$container_user:$container_user" "$config_path"
	else
		rm -f "$temp_path" "$config_path"
	fi
}

expand_identity_file() {
	local identity_path="$1"

	identity_path="${identity_path%\"}"
	identity_path="${identity_path#\"}"
	identity_path="${identity_path%\'}"
	identity_path="${identity_path#\'}"

	if [[ "$identity_path" == '~/.ssh/'* ]]; then
		printf '%s\n' "$host_ssh_dir/${identity_path#\~/.ssh/}"
		return
	fi

	if [[ "$identity_path" == /* ]]; then
		printf '%s\n' "$identity_path"
		return
	fi

	printf '%s\n' "$host_ssh_dir/$identity_path"
}

link_configured_identity_files() {
	local config_path="$host_ssh_dir/config"
	local configured_path=""
	local expanded_path=""

	[[ -f "$config_path" ]] || return 0

	while IFS= read -r configured_path; do
		expanded_path="$(expand_identity_file "$configured_path")"
		link_host_ssh_file "$expanded_path"
		done < <(
			awk 'tolower($1) == "identityfile" {
				$1 = ""
				sub(/^[[:space:]]+/, "")
				print
			}' "$config_path" | sort -u
		)
}

is_public_key_file() {
	local candidate="$1"
	local first_line=""

	[[ -f "$candidate" ]] || return 1

	case "$(basename "$candidate")" in
		*.pub)
			return 0
			;;
	esac

	first_line="$(head -n 1 "$candidate" 2>/dev/null || true)"

	[[ "$first_line" =~ ^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com|-----BEGIN[[:space:]]SSH2[[:space:]]PUBLIC[[:space:]]KEY-----) ]]
}

mkdir -p "$workspace_root" "$gitrepos_dir" "$pi_config_dir" "$ssh_dir"
chown "$container_user:$container_user" "$ssh_dir"

# Remove previously linked files from the host SSH mount before re-syncing them.
cleanup_host_ssh_links

if [[ -d "$host_ssh_dir" ]]; then
	# Dedicated host-SSH key (single-file bind mount): expose it as the default identity so
	# `ssh <HOST_SSH_ALIAS>` authenticates with this key and nothing else.
	link_host_ssh_file "$host_ssh_dir/id_ed25519"

	link_host_ssh_file "$host_ssh_dir/known_hosts"
	link_host_ssh_file "$host_ssh_dir/known_hosts2"
	link_host_ssh_file "$host_ssh_dir/vastai"

	link_configured_identity_files

	while IFS= read -r -d '' candidate; do
		if is_public_key_file "$candidate"; then
			ln -sfn "$candidate" "$ssh_dir/$(basename "$candidate")"
		fi
	done < <(find "$host_ssh_dir" -maxdepth 1 -type f -print0 2>/dev/null)
fi

write_ssh_config

chmod 700 "$ssh_dir"
cd "$gitrepos_dir"

export WORKSPACE_ROOT="$workspace_root"
export GITREPOS_DIR="$gitrepos_dir"
export PI_CONFIG_DIR="$pi_config_dir"

# Prepend pi-dev bin dir to PATH so our wrapper (auto-loading extensions) takes precedence
export PATH="/usr/local/pi-dev/bin:$PATH"

# ============================================================================
# Seed the container-specific models.json into the agent dir.
#
# The image bakes a copy of the repo template with ${PI_HOST} resolved to
# host.docker.internal (see Dockerfile). Pi does not interpolate env vars in
# baseUrl, so this literal file is what the container uses. We seed it only if
# it is missing: one-time and idempotent, never rewrites an existing file, and
# never touches the host's ~/.pi/agent/models.json (the config dir is a private
# volume, not a bind mount of the host).
# ============================================================================

seed_models_json() {
	local staged="/usr/local/pi-dev/agent/models.json"
	local models_dir="${PI_CONFIG_DIR}/agent"
	local models_file="${models_dir}/models.json"

	mkdir -p "$models_dir"
	if [[ ! -f "$models_file" && -f "$staged" ]]; then
		echo "Seeding container models.json: $staged -> $models_file"
		cp "$staged" "$models_file"
		chown app_user:app_user "$models_file" 2>/dev/null || true
	fi
}

# ============================================================================
# Seed the container-specific settings.json into the agent dir.
#
# The image bakes a default settings template (see Dockerfile). We seed it only
# if missing: one-time and idempotent, never rewrites an existing file.
# ============================================================================

seed_settings_json() {
	local staged="/usr/local/pi-dev/settings.template.json"
	local settings_dir="${PI_CONFIG_DIR}/agent"
	local settings_file="${settings_dir}/settings.json"

	mkdir -p "$settings_dir"
	if [[ ! -f "$settings_file" && -f "$staged" ]]; then
		echo "Seeding container settings.json: $staged -> $settings_file"
		cp "$staged" "$settings_file"
		chown app_user:app_user "$settings_file" 2>/dev/null || true
	fi
}

# ============================================================================
# Multi-Agent Mode
# ============================================================================

# Multi-agent files are baked into the image at /usr/local/pi-dev/
PI_DEV_DIR="/usr/local/pi-dev"

configure_multi_agent() {
	local extension_path="$PI_DEV_DIR/extensions/multi-agent.ts"
	local skills_path="$PI_DEV_DIR/.agents/skills"

	if [[ ! -f "$extension_path" ]]; then
		echo "Warning: multi-agent extension not found at $extension_path, starting plain pi" >&2
		return 1
	fi

	local args=("$@")
	args+=("--extension" "$extension_path")

	if [[ -d "$skills_path" ]]; then
		while IFS= read -r -d '' skill_dir; do
			if [[ -f "$skill_dir/SKILL.md" ]]; then
				args+=("--skill" "$skill_dir")
			fi
		done < <(find "$skills_path" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
	fi

	echo "Starting Pi in multi-agent mode..."
	printf '  Extension: %s\n' "$extension_path"
	if [[ ${#args[@]} -gt 3 ]]; then
		skill_count=$(( (${#args[@]} - 3) / 2 ))
		echo "  Skills: $skill_count loaded"
	fi
	echo ""

	exec "${args[@]}"
}

# ============================================================================
# Populate .venv-test from everything under gitrepos, using jacloud.site as
# the only package index (/etc/pip.conf is written just below).
#
# 1. Every requirements*.txt file (any depth; build/vendor/venv noise skipped).
#    Relative path lines (./x, ../y) are resolved by running pip from an
#    ancestor directory where all referenced paths exist. If a whole file
#    fails to resolve, each requirement is retried individually so one bad
#    pin does not block the rest (-r includes are expanded recursively).
# 2. Every pyproject.toml package (repo-local code wins over index versions;
#    skipped when name+version already installed). If a local build fails
#    (e.g. its build backend is missing from the index), fall back to the
#    published wheel of the same version.
# 3. A pinned set of core test packages, installed last so they always end up
#    present even if an individual file above failed.
# ============================================================================

VENV_TEST_PIP="/workspace/.venv-test/bin/pip"
VENV_TEST_PYTHON="/workspace/.venv-test/bin/python"
VENV_TEST_FAILURES=0
declare -A REQ_IN_PROGRESS=()

# Directories that never contain installable requirements (build output,
# vendored copies, virtualenvs, release staging).
find_repo_files() {  # $1 = find -name pattern; NUL-separated on stdout
    find "$gitrepos_dir" -type f -name "$1" \
        ! -path "*/.git/*" \
        ! -path "*/node_modules/*" \
        ! -path "*/venv/*" \
        ! -path "*/.venv/*" \
        ! -path "*/vendor/*" \
        ! -path "*/tmp/*" \
        ! -path "*/build/*" \
        ! -path "*/dist/*" \
        ! -path "*/__pycache__/*" \
        ! -path "*/.cache/*" \
        -print0 2>/dev/null | sort -z
}

# Choose a working directory for pip so relative path lines in a requirements
# file (./x, ../y) resolve: walk up from the file's own dir until every
# referenced path exists below one ancestor.
resolve_requirements_cwd() {
    local req_file="$1" line refs=() dir depth ok
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"   # ltrim
        [[ -z "$line" || "$line" == \#* ]] && continue
        case "$line" in ./*|../*) refs+=("${line%% *}") ;; esac
    done < "$req_file"

    if [[ ${#refs[@]} -eq 0 ]]; then
        dirname "$req_file"; return 0
    fi
    dir="$(dirname "$req_file")"; depth=0
    while [[ -n "$dir" && "$dir" != "/" && $depth -lt 8 ]]; do
        ok=1
        for line in "${refs[@]}"; do
            if [[ ! -e "$dir/$line" ]]; then ok=0; break; fi
        done
        if [[ $ok -eq 1 ]]; then printf '%s' "$dir"; return 0; fi
        dir="$(dirname "$dir")"; depth=$((depth + 1))
    done
    dirname "$req_file"
}

# Install one requirements file, falling back to per-requirement installs so a
# single unresolvable pin does not block the rest of the file.
install_requirements_file() {
    local req_file="$1" cwd line sub
    [[ -f "$req_file" ]] || return 0
    [[ -n "${REQ_IN_PROGRESS[$req_file]:-}" ]] && return 0   # include-cycle guard
    REQ_IN_PROGRESS["$req_file"]=1

    cwd="$(resolve_requirements_cwd "$req_file")"
    echo "Installing requirements: $req_file (cwd=$cwd)"
    if (cd "$cwd" && "$VENV_TEST_PIP" install --no-cache-dir -r "$req_file"); then
        return 0
    fi

    echo "Warning: full-file install failed for $req_file; retrying requirement by requirement" >&2
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"   # ltrim
        line="${line%"${line##*[![:space:]]}"}"   # rtrim
        [[ -z "$line" || "$line" == \#* ]] && continue
        case "$line" in
            -r\ *|--requirement\ *)
                sub="$line"
                if [[ "$sub" == --requirement* ]]; then sub="${sub#--requirement}"; else sub="${sub#-r}"; fi
                sub="${sub#"${sub%%[![:space:]]*}"}"   # ltrim
                install_requirements_file "$(dirname "$req_file")/$sub"
                ;;
            -* )
                echo "Warning: skipping unsupported option line '$line' (from $req_file)" >&2
                VENV_TEST_FAILURES=$((VENV_TEST_FAILURES + 1))
                ;;
            * )
                if ! (cd "$cwd" && "$VENV_TEST_PIP" install --no-cache-dir "$line"); then
                    echo "Warning: failed to install '$line' (from $req_file)" >&2
                    VENV_TEST_FAILURES=$((VENV_TEST_FAILURES + 1))
                fi
                ;;
        esac
    done < "$req_file"
}

# Read "name version" from a pyproject.toml using the venv's python (tomllib).
read_project_meta() {
    "$VENV_TEST_PYTHON" -c '
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))["project"]
print(d.get("name", ""), d.get("version", ""))
' "$1/pyproject.toml" 2>/dev/null
}

install_project_dir() {
    local proj_dir="$1" meta name version installed
    [[ -f "$proj_dir/pyproject.toml" ]] || return 0
    meta="$(read_project_meta "$proj_dir")" || { echo "Warning: cannot read $proj_dir/pyproject.toml" >&2; VENV_TEST_FAILURES=$((VENV_TEST_FAILURES + 1)); return 0; }
    name="${meta% *}"
    version="${meta##* }"
    [[ -n "$name" ]] || { echo "Warning: no project name in $proj_dir/pyproject.toml" >&2; VENV_TEST_FAILURES=$((VENV_TEST_FAILURES + 1)); return 0; }

    installed="$("$VENV_TEST_PIP" show "$name" 2>/dev/null | awk '/^Version:/ {print $2}')" || true
    if [[ -n "$version" && "$installed" == "$version" ]]; then
        echo "Skipping $name ($version already in .venv-test)"
        return 0
    fi

    echo "Installing package dir: $proj_dir ($name ${version:-?})"
    if (cd "$gitrepos_dir" && "$VENV_TEST_PIP" install --no-cache-dir "$proj_dir"); then
        return 0
    fi

    # Local build failed (e.g. build backend not available on the index):
    # fall back to the published wheel of the same version, if any.
    if [[ -n "$version" ]]; then
        echo "Warning: local build failed for $name; trying published ${name}==${version} from index" >&2
        (cd "$gitrepos_dir" && "$VENV_TEST_PIP" install --no-cache-dir "${name}==${version}") \
            || { echo "Warning: could not install $name ($proj_dir)" >&2; VENV_TEST_FAILURES=$((VENV_TEST_FAILURES + 1)); }
    else
        echo "Warning: could not install package dir $proj_dir" >&2
        VENV_TEST_FAILURES=$((VENV_TEST_FAILURES + 1))
    fi
}

install_gitrepos_requirements() {
    local req_file proj_file found=0

    if [[ ! -x "$VENV_TEST_PIP" ]]; then
        echo "Warning: $VENV_TEST_PIP not found; skipping .venv-test population" >&2
        return 0
    fi

    # 1) requirements files (any depth, noise dirs excluded)
    while IFS= read -r -d '' req_file; do
        install_requirements_file "$req_file"
        found=$((found + 1))
    done < <(find_repo_files 'requirements*.txt')

    # 2) pyproject packages (repo-local code wins over index versions)
    while IFS= read -r -d '' proj_file; do
        install_project_dir "$(dirname "$proj_file")"
    done < <(find_repo_files 'pyproject.toml')

    # 3) Pinned core test packages, last so they always end up installed.
    #    Versions are the latest available on jacloud.site (pinned, never "latest").
    local must_haves=(
        "psycopg==3.2.13"
        "pydantic-settings==2.15.0"
        "coverage==7.10.6"
        "pytest-asyncio==1.4.0"
        "pytest-cov==7.1.0"
        "jsonschema==4.26.0"
        "dq-made-easy-cli==0.6.5"
        "dq-made-easy-utils==0.1.3"
        "dq-made-easy-domain-validation==0.1.3"
    )
    echo "Ensuring core test packages in .venv-test: ${must_haves[*]}"
    if ! "$VENV_TEST_PIP" install --no-cache-dir "${must_haves[@]}"; then
        echo "Warning: failed to ensure one or more core test packages (see above)" >&2
        VENV_TEST_FAILURES=$((VENV_TEST_FAILURES + 1))
    fi

    if [[ $found -eq 0 && ${#must_haves[@]} -gt 0 ]]; then
        echo "No requirements*.txt found in $gitrepos_dir (core packages only)"
    else
        echo ".venv-test population complete ($found requirements file(s), $VENV_TEST_FAILURES failure(s))"
    fi
}

# Write pip.conf with credentials from env vars (not baked into image).
# Written to /etc/pip.conf so it is visible regardless of which user runs pip.
if [[ -n "${PYPI_USERNAME:-}" && -n "${PYPI_PASSWORD:-}" ]]; then
    cat > /etc/pip.conf <<EOF
[global]
index-url = https://${PYPI_USERNAME}:${PYPI_PASSWORD}@jacloud.site/pypi/simple/
trusted-host = jacloud.site
download-cache = /tmp/pip-cache
EOF
fi

install_gitrepos_requirements

# Seed the container-specific models.json and settings.json into the agent dir (no-op if present).
seed_models_json
seed_settings_json

# Ensure app_user owns its writable config dirs (bind mounts like /home/app_user/bin
# are read-only and must be skipped). The volumes pi-config (.pi) and pi-dev-agent-ssh
# (.ssh) are the only writable paths under home.
chown -R "${container_user}:${container_user}" "$pi_config_dir" 2>/dev/null || true
chown -R "${container_user}:${container_user}" "$ssh_dir"    2>/dev/null || true

# Enforce strict egress at the network level (must run as root): default-DROP OUTPUT,
# allowing only loopback, established connections, DNS resolvers, the Squid proxy, and
# PI_DEV_AGENT_DIRECT_ALLOW_HOSTS. Without this, clients can bypass the proxy blocklist
# entirely (e.g., curl --noproxy '*').
if is_truthy "$strict_egress"; then
    configure_strict_egress
fi

# If a command was passed (e.g. CMD ["pi"] from docker-compose), run it as
# app_user via su; otherwise keep the container alive so users can exec in.
if [[ $# -gt 0 ]]; then
    echo "Starting Pi as ${container_user}..."
    exec su - "$container_user" -c "\"$*\""
else
    # Keep container alive so user can exec into it and run pi manually
tail -f /dev/null &
    wait
fi