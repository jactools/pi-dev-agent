#!/usr/bin/env bash
set -euo pipefail

username="${1:-}"
# Resolve the invoking user's home even when run via sudo (where $HOME is /root).
if [[ -n "${SUDO_USER:-}" ]]; then
  credentials_file="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.credentials"
else
  credentials_file="${HOME}/.credentials"
fi

docker_htpasswd="/etc/docker/registry/auth.htpasswd"
pypi_htpasswd="/etc/pypi-server/htpasswd"
# verdaccio (jacloud.site, private-only) — bcrypt (-B) is required: its htpasswd
# library verifies bcrypt, not the SHA512 (-5) mode used for pypi.
npm_htpasswd="/var/lib/verdaccio/htpasswd"

if [[ -z "$username" ]]; then
  echo "usage: $0 <username>" >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required" >&2
  exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 2
fi

userpassword="$(openssl rand -hex 24)"

make_htpasswd_entry() {
  local mode="$1"
  local user="$2"
  local password="$3"
  docker run --rm --entrypoint htpasswd httpd:2 "-nb${mode}" "$user" "$password"
}

update_htpasswd_file() {
  local file="$1"
  local user="$2"
  local password="$3"
  local owner_group="$4"
  local hash_mode="$5"
  local owner="${owner_group%%:*}"
  local group="${owner_group##*:}"
  local existing_user=false

  local tmp_file
  tmp_file="$(mktemp)"

  if sudo test -f "$file"; then
    if sudo grep -q "^${user}:" "$file"; then
      existing_user=true
    fi
    sudo grep -v "^${user}:" "$file" > "$tmp_file" || true
  fi

  make_htpasswd_entry "$hash_mode" "$user" "$password" >> "$tmp_file"

  sudo install -o "$owner" -g "$group" -m 640 "$tmp_file" "$file"
  rm -f "$tmp_file"

  if [[ "$existing_user" == true ]]; then
    echo "password reset for existing user '$user' in $file"
  else
    echo "created new user '$user' in $file"
  fi
}

update_credentials_file() {
  local user="$1"
  local password="$2"
  local tmp_file
  tmp_file="$(mktemp)"

  if [[ -f "$credentials_file" ]]; then
    grep -v "^docker_registry_${user}_username=" "$credentials_file" > "$tmp_file" || true
    grep -v "^docker_registry_${user}_password=" "$tmp_file" > "${tmp_file}.next" || true
    mv "${tmp_file}.next" "$tmp_file"

    grep -v "^npm_${user}_username=" "$credentials_file" > "$tmp_file" || true
    grep -v "^npm_${user}_password=" "$tmp_file" > "${tmp_file}.next" || true
    mv "${tmp_file}.next" "$tmp_file"

    grep -v "^pypi_${user}_username=" "$tmp_file" > "${tmp_file}.next" || true
    mv "${tmp_file}.next" "$tmp_file"

    grep -v "^pypi_${user}_password=" "$tmp_file" > "${tmp_file}.next" || true
    mv "${tmp_file}.next" "$tmp_file"
  else
    : > "$tmp_file"
  fi

  {
    echo "docker_registry_${user}_username=${user}"
    echo "docker_registry_${user}_password=${password}"
    echo "pypi_${user}_username=${user}"
    echo "pypi_${user}_password=${password}"
    echo "npm_${user}_username=${user}"
    echo "npm_${user}_password=${password}"
  } >> "$tmp_file"

  install -m 600 "$tmp_file" "$credentials_file"
  rm -f "$tmp_file"
}

echo "updating user for docker-registry..."
update_htpasswd_file "$docker_htpasswd" "$username" "$userpassword" "registry:registry" "B"

echo "updating user for pypi-server..."
update_htpasswd_file "$pypi_htpasswd" "$username" "$userpassword" "pypi:pypi" "5"

echo "updating user for verdaccio (npm registry)..."
update_htpasswd_file "$npm_htpasswd" "$username" "$userpassword" "verdaccio:verdaccio" "B"

echo "writing credentials to ${credentials_file}..."
update_credentials_file "$username" "$userpassword"

echo "restarting pypi-server..."
sudo systemctl restart pypi-server
sudo systemctl is-active --quiet pypi-server

echo "restarting docker-registry..."
sudo systemctl restart docker-registry
sudo systemctl is-active --quiet docker-registry

# verdaccio reads the htpasswd file per auth check, so this restart is not
# strictly required — kept for consistency with the other registries.
echo "restarting verdaccio (npm registry)..."
sudo systemctl restart verdaccio
sudo systemctl is-active --quiet verdaccio

echo "Done. Check ${credentials_file}"

