#!/bin/sh
# SSH tunnel sidecar entrypoint for the pi-dev-agent stack.
#
# Runs one ssh -N port-forward in a retry loop so the container stays up and
# self-heals when the LAN link or remote host drops:
#   - ssh exits (link lost, keepalive budget exhausted) -> wait 3s -> reconnect
#   - no reliance on Docker's restart backoff; failures are visible in `docker logs`
#
# Dead-link detection budget: ServerAliveInterval=10 x ServerAliveCountMax=2
# means a dead link is declared after ~20s of missed probes, plus the 3s retry
# sleep and <1s wired-LAN reconnect -> port-forwards are restored within ~25s.
# Do not raise these values: clients (undici) give up after ~40s of connect
# timeouts, so detection must stay well under that.
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
		-o ServerAliveInterval=10 \
		-o ServerAliveCountMax=2 \
		-o ExitOnForwardFailure=yes \
		-o StrictHostKeyChecking=accept-new \
		${TUNNEL_FORWARDS} \
		"${TUNNEL_TARGET}"; then
		exit 0
	fi
	echo "[tunnel] connection to ${TUNNEL_TARGET} lost; retrying in 3s" >&2
	sleep 3
done
