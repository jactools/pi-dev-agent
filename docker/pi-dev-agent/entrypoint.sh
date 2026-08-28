#!/usr/bin/env bash
set -euo pipefail

workspace_root="${WORKSPACE_ROOT:-/workspace}"
gitrepos_dir="${GITREPOS_DIR:-${workspace_root}/gitrepos}"
pi_config_dir="${PI_CONFIG_DIR:-/home/app_user/.pi}"
ssh_dir="${HOME:-/home/app_user}/.ssh"
host_ssh_dir="/mnt/host-ssh"
host_ssh_alias="${HOST_SSH_ALIAS:-}"
host_ssh_user="${HOST_SSH_USER:-}"
host_ssh_hostname="${HOST_SSH_HOSTNAME:-host.docker.internal}"
host_ssh_port="${HOST_SSH_PORT:-22}"

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

	if [[ -n "$host_ssh_alias" && -z "$host_ssh_user" ]]; then
		echo "HOST_SSH_USER must be set when HOST_SSH_ALIAS is configured" >&2
		exit 1
	fi

	: > "$temp_path"

	if [[ -f "$host_ssh_dir/config" ]]; then
		printf 'Include %s\n' "$host_ssh_dir/config" >> "$temp_path"
	fi

	if [[ -n "$host_ssh_alias" ]]; then
		printf '\nHost %s\n' "$host_ssh_alias" >> "$temp_path"
		printf '  HostName %s\n' "$host_ssh_hostname" >> "$temp_path"
		printf '  User %s\n' "$host_ssh_user" >> "$temp_path"
		printf '  Port %s\n' "$host_ssh_port" >> "$temp_path"
	fi

	if [[ -s "$temp_path" ]]; then
		mv "$temp_path" "$config_path"
		chmod 600 "$config_path"
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

# Remove previously linked files from the host SSH mount before re-syncing them.
cleanup_host_ssh_links

if [[ -d "$host_ssh_dir" ]]; then
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

exec "$@"