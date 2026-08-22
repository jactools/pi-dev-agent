#!/usr/bin/env bash
set -euo pipefail

workspace_root="${WORKSPACE_ROOT:-/workspace}"
gitrepos_dir="${GITREPOS_DIR:-${workspace_root}/gitrepos}"
pi_config_dir="${PI_CONFIG_DIR:-/home/app_user/.pi}"
ssh_dir="${HOME:-/home/app_user}/.ssh"
host_ssh_dir="/mnt/host-ssh"

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

# Expose only public keys from the optional host SSH mount.
find "$ssh_dir" -maxdepth 1 -type l -name '*.pub' -delete 2>/dev/null || true
rm -f "$ssh_dir/config"
rm -f "$ssh_dir/vastai"

if [[ -d "$host_ssh_dir" ]]; then
	if [[ -f "$host_ssh_dir/config" ]]; then
		ln -sfn "$host_ssh_dir/config" "$ssh_dir/config"
	fi

	if [[ -f "$host_ssh_dir/vastai" ]]; then
		ln -sfn "$host_ssh_dir/vastai" "$ssh_dir/vastai"
	fi

	while IFS= read -r -d '' candidate; do
		if is_public_key_file "$candidate"; then
			ln -sfn "$candidate" "$ssh_dir/$(basename "$candidate")"
		fi
	done < <(find "$host_ssh_dir" -maxdepth 1 -type f -print0 2>/dev/null)

	# Expose id_ed25519 private key read-only
	if [[ -f "$host_ssh_dir/id_ed25519" ]]; then
		ln -sfn "$host_ssh_dir/id_ed25519" "$ssh_dir/id_ed25519"
		chmod 400 "$ssh_dir/id_ed25519" 2>/dev/null || true
	fi
fi

chmod 700 "$ssh_dir"
cd "$gitrepos_dir"

export WORKSPACE_ROOT="$workspace_root"
export GITREPOS_DIR="$gitrepos_dir"
export PI_CONFIG_DIR="$pi_config_dir"

exec "$@"