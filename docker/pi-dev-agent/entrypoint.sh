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
llama_bridge_enabled="${PI_DEV_AGENT_LLAMA_BRIDGE_ENABLED:-true}"
llama_bridge_listen_host="${PI_DEV_AGENT_LLAMA_BRIDGE_LISTEN_HOST:-127.0.0.1}"
llama_bridge_listen_port="${PI_DEV_AGENT_LLAMA_BRIDGE_LISTEN_PORT:-8082}"
llama_bridge_target_host="${PI_DEV_AGENT_LLAMA_BRIDGE_TARGET_HOST:-host.docker.internal}"
llama_bridge_target_port="${PI_DEV_AGENT_LLAMA_BRIDGE_TARGET_PORT:-8082}"

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

start_llama_bridge() {
	node - "$llama_bridge_listen_host" "$llama_bridge_listen_port" "$llama_bridge_target_host" "$llama_bridge_target_port" <<'EOF' >/tmp/pi-llama-bridge.log 2>&1 &
const net = require('node:net');

const [listenHost, listenPortRaw, targetHost, targetPortRaw] = process.argv.slice(2);
const listenPort = Number.parseInt(listenPortRaw, 10);
const targetPort = Number.parseInt(targetPortRaw, 10);

if (!Number.isInteger(listenPort) || !Number.isInteger(targetPort)) {
	console.error('Invalid llama bridge port configuration');
	process.exit(1);
}

const server = net.createServer((clientSocket) => {
	const upstreamSocket = net.createConnection({ host: targetHost, port: targetPort });

	clientSocket.pipe(upstreamSocket);
	upstreamSocket.pipe(clientSocket);

	const destroyPair = () => {
		clientSocket.destroy();
		upstreamSocket.destroy();
	};

	clientSocket.on('error', destroyPair);
	upstreamSocket.on('error', destroyPair);
});

server.on('error', (error) => {
	console.error(`Llama bridge error: ${error.message}`);
	process.exit(1);
});

server.listen(listenPort, listenHost);
EOF
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

if [[ "$(id -u)" -eq 0 ]]; then
	if is_truthy "$strict_egress"; then
		configure_strict_egress
	fi

	if is_truthy "$llama_bridge_enabled"; then
		start_llama_bridge
	fi

	exec runuser -u "$container_user" -- "$@"
fi

exec "$@"