#!/bin/sh
# Runs BEFORE the image's own entrypoint (see compose `entrypoint:` override).
# Re-points wekan.dev.jac.dot at the CURRENT Docker host gateway, IPv4 only.
#
# Why:
# - The VM bridge IP can change across Docker Desktop updates/reinstalls; a static
#   extra_hosts entry would go stale and break WeKan with ERR_CONNECT_FAIL.
# - IPv4-only on purpose: the VM blackholes IPv6 to the host gateway, so a
#   dual-stack (host-gateway) entry makes squid try the dead AAAA address first.
set -eu

gw="$(getent ahostsv4 host.docker.internal | awk '{print $1; exit}' || true)"
if [ -n "$gw" ]; then
  # /etc/hosts is bind-mounted by Docker: sed -i (rename) fails with EBUSY,
  # so filter to a temp file and write back over the same inode.
  grep -v '^wekan\.dev\.jac\.dot[[:space:]]' /etc/hosts > /tmp/.hosts.new
  cat /tmp/.hosts.new > /etc/hosts
  rm -f /tmp/.hosts.new
  printf '%s\twekan.dev.jac.dot\n' "$gw" >> /etc/hosts
  echo "proxy-entrypoint: wekan.dev.jac.dot -> $gw (IPv4 only)"
else
  echo "proxy-entrypoint: WARNING: could not resolve host.docker.internal; WeKan egress will fail until fixed" >&2
fi

exec /usr/local/bin/entrypoint.sh "$@"
