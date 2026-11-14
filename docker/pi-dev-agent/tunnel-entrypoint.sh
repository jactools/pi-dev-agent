#!/bin/sh
# SSH tunnel sidecar entrypoint for the pi-dev-agent stack.
#
# Runs one ssh -N port-forward in a retry loop so the container stays up and
# self-heals when the LAN link or remote host drops:
#   - ssh exits (link lost, keepalive budget exhausted) -> wait 5s -> reconnect
#   - no reliance on Docker's restart backoff; failures are visible in `docker logs`
#
# Required env vars:
#   TUNNEL_KEY      path to the mounted private key (copied to /tmp with mode 600,
#                   because ssh rejects keys with group/other permissions)
#   TUNNEL_TARGET   user@host of the remote machine
#   TUNNEL_FORWARDS space-separated -L specs, e.g. "-L 0.0.0.0:8082:localhost:1234"

set -eu

install -m 600 "${TUNNEL_KEY}" /tmp/tunnel_key

while :; do
	# TUNNEL_FORWARDS is intentionally word-split (multiple -L flags).
	# shellcheck disable=SC2086
	if ssh -N \
		-i /tmp/tunnel_key \
		-o BatchMode=yes \
		-o ConnectTimeout=10 \
		-o ServerAliveInterval=30 \
		-o ServerAliveCountMax=3 \
		-o ExitOnForwardFailure=yes \
		-o StrictHostKeyChecking=accept-new \
		${TUNNEL_FORWARDS} \
		"${TUNNEL_TARGET}"; then
		exit 0
	fi
	echo "[tunnel] connection to ${TUNNEL_TARGET} lost; retrying in 5s" >&2
	sleep 5
done
