# NPM Registry on jacloud.site (Verdaccio behind Caddy)

**Status**: Implemented
**Date**: 2026-11-14

## Purpose

`https://jacloud.site/` (site root) is the npm registry for the internal build
environments. It accepts private publishes and serves **only internally published
packages** — no npmjs proxying, mirroring the jacloud PyPI mirror policy: packages a
build needs must be published internally first. Containers with restricted egress — in
particular the pi-dev-agent stack (`docstore build`, agent-container npm installs) —
resolve everything through this one internal endpoint:

```
https://jacloud.site/              → npm registry (this document; root, npm-shaped paths only)
https://jacloud.site/pypi/simple/  → PyPI index   (already running)
https://jacloud.site/packages/     → pypiserver wheel files (root-absolute hrefs from the /pypi/ simple index — must NOT be routed to verdaccio)
https://jacloud.site/docker/       → Docker registry (already running)
```

**Why the site root and not a subpath:** verdaccio emits root-absolute tarball URLs
(`/<pkg>/-/<file>.tgz`) in package metadata — for locally published packages *and*
proxied ones. Under any subpath (`/npm/`, `/packages/`, …) npm clients fetch those
tarballs from the wrong path and get 404s. Mounting verdaccio at the root is the only
path-based layout that works with stock npm clients; a Caddy matcher then restricts it
to npm-shaped paths so junk never reaches the process (see Caddy section).
`/packages/*` stays reserved for pypiserver wheel downloads (explicit `handle` route).

Client credentials are the `NPM_USERNAME` / `NPM_PASSWORD` pair from the pi-dev-agent
env files; for npm they authenticate against verdaccio's htpasswd file.

## Architecture

```
npm client (host or container)
   │  HTTPS, Bearer token (_authToken in npmrc)
   ▼
Caddy (TLS termination, jacloud.site)
   │  @npm matcher (root, npm-shaped paths only) → verdaccio at its native root
   │  everything else → Caddy 404 (never reaches a backend)
   ▼
verdaccio on 127.0.0.1:4873   (systemd service, user 'verdaccio', loopback only,
                               private-only — no upstream proxy)
```

Design rules:

- **Verdaccio binds to loopback only.** Caddy terminates TLS and fronts it; port 4873
  must never be exposed directly (that would bypass auth/TLS).
- **Site root, not a subpath.** Verdaccio's root-absolute tarball URLs only resolve when
  it owns the host root (see Purpose). Explicit `handle` routes for `/v2/`, `/docker/`,
  `/pypi/`, and `/packages/` take precedence; everything else falls through to verdaccio.
- **Private-only by policy.** No `uplinks:` / `proxy: npmjs`. Packages needed by builds
  must be published internally first (same model as the PyPI mirror).
- The web UI is at `https://jacloud.site/` (package browsing is public; install and
  publish require `$authenticated`).
- Storage lives in `/var/lib/verdaccio/storage`; the htpasswd user file in
  `/var/lib/verdaccio/htpasswd`. Back up that folder to preserve packages + users.

## Prerequisites

- Debian (tested on trixie) with root/sudo access.
- Caddy already serving `jacloud.site` (the site block also hosts `/pypi/`).

## 1) Node.js 24 via NodeSource

Verdaccio 6 needs Node ≥ 18; install the current line from NodeSource so it stays
apt-managed at the standard system locations (`/usr/bin/node`, npm prefix `/usr`):

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates

# Replaces any existing nodesource repo (e.g. node_20.x) with 24.x; an installed
# older version is upgraded in place by the next command.
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo bash -
sudo apt-get install -y nodejs

node --version          # v24.x
npm config get prefix   # /usr  ← global installs land in /usr/bin
```

**Pitfall — stale `node` resolution in interactive shells.** If `node --version` fails
with `-bash: /home/<user>/.local/share/pi-node/node-vXX.../bin/node: No such file or
directory`, the shell has a stale command hash (or PATH entry) pointing at pi's own
managed Node runtime, which no longer exists. The system install is fine; fix the shell:

```bash
hash -r                 # clear bash's command hash table
type -a node            # must show /usr/bin/node first (then /bin/node)
# If a pi-node path still appears earlier in PATH, find and remove the stale line:
echo "$PATH" | tr ':' '\n' | grep -n "pi-node"
grep -rn "pi-node" ~/.bashrc ~/.profile ~/.bash_profile 2>/dev/null
```

This only affects interactive shells — systemd services use a clean `secure_path` and
always get `/usr/bin/node`.

## 2) Install verdaccio (latest is fine — verified on v7.1.0)

```bash
sudo npm install -g verdaccio
which verdaccio         # /usr/bin/verdaccio
```

Both v6 and v7 work with the token-based client flow documented in *Client configuration*
(login → `_authToken` → `Authorization: Bearer`). Verified end-to-end on **v7.1.0**:
login, proxied public-package fetch, and a real npm client all pass.

Historical note (2026-11-14): an earlier attempt to pin v6 was based on misdiagnosed
failures — the actual causes were (a) Caddy using `handle` instead of `handle_path`
(prefix not stripped, so requests hit wrong verdaccio routes), and (b) a malformed login
request missing its JSON body. Do not "fix" version pins based on 401s without first
checking the Caddy route and using the correct login protocol.

## 3) System user + directories

```bash
sudo useradd --system --home /var/lib/verdaccio --shell /usr/sbin/nologin verdaccio
sudo mkdir -p /var/lib/verdaccio/storage /etc/verdaccio
sudo chown -R verdaccio:verdaccio /var/lib/verdaccio
```

## 4) Config — `/etc/verdaccio/config.yaml`

The config is kept in this repo and deployed as-is (no interactive pasting — that's how
indentation gets mangled):

- [`infra/jacloud-site/verdaccio/config.yaml`](../../infra/jacloud-site/verdaccio/config.yaml)
- [`infra/jacloud-site/verdaccio/verdaccio.service`](../../infra/jacloud-site/verdaccio/verdaccio.service)
- [`infra/jacloud-site/verdaccio/caddy-npm-route.snippet`](../../infra/jacloud-site/verdaccio/caddy-npm-route.snippet)

```bash
# copy to the server, then install (see infra/jacloud-site/verdaccio/README.md for the full flow)
sudo mkdir -p /etc/verdaccio
sudo install -o root -g verdaccio -m 750 config.yaml /etc/verdaccio/config.yaml
```

Key settings: `max_users` controls registration, `packages:` rules control access/publish,
and the log line sends output to the journal.

### Private-only (the policy)

The deployed config is **private-only**: no `uplinks:` block, no `proxy: npmjs`. Unknown
(non-published) packages fail by design instead of leaking to npmjs — mirroring the
jacloud PyPI mirror policy. Packages a build needs must be published internally first.
(If you ever want a caching proxy again, add an `uplinks:` block and `proxy: npmjs` on
the package rules; that requires outbound internet from the server.)

## 5) systemd service — `/etc/systemd/system/verdaccio.service`

Deploy the unit from the repo (same folder as the config), then start:

```bash
sudo install -m 644 verdaccio.service /etc/systemd/system/verdaccio.service
sudo systemctl daemon-reload
sudo systemctl enable --now verdaccio
sleep 2 && sudo journalctl -u verdaccio -n 15 --no-pager
curl -s http://127.0.0.1:4873/-/ping    # expect: {}
```

If it fails to start, run it in the foreground for instant feedback instead of reading
the journal:

```bash
sudo -u verdaccio /usr/bin/verdaccio --config /etc/verdaccio/config.yaml --listen 127.0.0.1:4873
#   expect "http server listening on 127.0.0.1:4873" — then Ctrl-C
```

## 6) Caddy — route the paths

Replace the route section of the existing `jacloud.site` site block with
[`infra/jacloud-site/verdaccio/caddy-npm-route.snippet`](../../infra/jacloud-site/verdaccio/caddy-npm-route.snippet):

```caddyfile
handle /v2/* {
    reverse_proxy 127.0.0.1:5000
}

handle_path /docker/* {
    reverse_proxy 127.0.0.1:5000 {
        header_up Host {http.reverse_proxy.upstream.host}
    }
}

# PyPI index (pypiserver) — handle_path strips /pypi so pypiserver sees its own routes
handle_path /pypi/* {
    reverse_proxy 127.0.0.1:8080
}

# pypiserver wheel files — the simple index under /pypi/ emits root-absolute hrefs like
# /packages/<wheel>; plain handle (NOT handle_path) keeps the prefix for pypiserver's route
handle /packages/* {
    reverse_proxy 127.0.0.1:8080
}

# npm registry — only npm-shaped paths reach verdaccio:
#   /-/...                  API (ping, user/login, audit)
#   /<pkg>                  package metadata + publish; scoped packages arrive as one
#                           segment, URL-encoded (@scope%2Fname) or decoded (@scope/name)
#   /<pkg>/-/<file>.tgz     tarball downloads
@npm {
    path_regexp ^(?:/-/.+|/(@[^/]+/[^/]+|[^/@]+)(/-/.+)?)$
}

handle @npm {
    reverse_proxy 127.0.0.1:4873
}

# everything else — instant 404 in Caddy, never reaches a backend process
respond "Unknown" 404
```

Notes:

- Verdaccio must own the site **root** (its root-absolute tarball URLs only resolve there,
  see Purpose) but is NOT the default handler: only npm-shaped paths (`@npm` matcher)
  reach it. Everything else — scanner probes, typos, junk — gets Caddy's instant
  `404 Unknown` and never touches a backend process.
- The explicit `handle` routes (`/v2/`, `/docker/`, `/pypi/`, `/packages/`) are evaluated
  before the `@npm` handler; keep them above it. (They don't overlap the npm pattern in
  practice, but ordering keeps precedence unambiguous.)
- Single-segment unknowns like `/admin` DO reach verdaccio (indistinguishable from a
  package named `admin`) and get verdaccio's own 404 — that is inherent to an npm registry
  at the root. Multi-segment junk never reaches it.
- The browser UI is disabled in the config (`web.enable: false`); the registry is API-only.

```bash
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
curl -s https://jacloud.site/-/ping    # expect: {}
```

## 7) Create the npm user + verify

```bash
npm adduser --registry https://jacloud.site/
#   → username / password / email. These are the NPM_USERNAME/NPM_PASSWORD
#     values for npm in client env files (never commit them).

curl -s -o /dev/null -w "%{http_code}\n" -u USER:PASS https://jacloud.site/   # 200 = web UI
npm view <published-pkg> version --registry https://jacloud.site/    # works for internal packages
```

Freeze the user list once everyone is registered: set `max_users: -1` in the config and
`sudo systemctl restart verdaccio`.

## Client configuration (consumers)

**Use `_authToken`, not username/password.** Modern npm (>=10) does NOT send basic auth
from `username`/`password` .npmrc entries — it only uses them for the login handshake,
and requests carry no Authorization header at all. npm sends `Authorization: Bearer
<token>` from `_authToken`, which is what verdaccio accepts.

Tokens are obtained by logging in (the same call `npm login` makes):

```bash
curl -s -u USER:PASS -X PUT -H 'Content-Type: application/json' \
  -d '{"name":"USER","password":"PASS"}' \
  https://jacloud.site/-/user/org.couchdb.user:USER | jq .token
# NOTE: the password must be in BOTH the Basic header and the JSON body.
```

Verdaccio v6 tokens are AES-encrypted blobs without expiry — they stay valid until the
server's secret changes. Re-login any time to mint a fresh one.

Standard npm client config for any machine/container that should use this registry —
this is exactly what `scripts/pi_dev_agent.sh docstore build|start` generates into
`tmp/docstore/npmrc` and `moody-ai/proxy/npmrc` (it logs in at generation time):

```ini
registry=https://jacloud.site/
//jacloud.site/:_authToken=<token>
```

Yarn berry equivalent:

```ini
//jacloud.site/:_authToken=<token>
npmRegistryServer=https://jacloud.site/
```

## Operations

| Task | Command |
|---|---|
| Logs | `sudo journalctl -u verdaccio -f` (level set in config; raise to `debug` temporarily) |
| Restart after config change | `sudo systemctl restart verdaccio` |
| Status / port check | `systemctl status verdaccio`; `ss -ltnp \| grep 4873` |
| Upgrade verdaccio | `sudo npm install -g verdaccio@latest && sudo systemctl restart verdaccio` |
| Upgrade Node | `sudo apt-get update && sudo apt-get upgrade nodejs && sudo systemctl restart verdaccio` |
| Backup (packages + users) | `tar czf verdaccio-backup.tgz -C /var/lib verdaccio` |
| Web UI | https://jacloud.site/ (package browsing public; install/publish need the npm user) |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `E401 Incorrect or missing password` from clients | Wrong credentials in the client npmrc, or the user was never created (`npm adduser`). Check `htpasswd` file exists after first login; verify with `curl -u USER:PASS https://jacloud.site/-/ping`. |
| 404 on tarball fetches like `https://jacloud.site/<pkg>/-/<file>.tgz` | Verdaccio is behind a subpath (e.g. `/npm/*`) instead of the site root — its root-absolute tarball URLs don't resolve. Mount it at the root via the `@npm` matcher (see Caddy section). |
| `404 Not Found ... is not in this registry` for a package that was never published | Expected under private-only policy: publish the package internally first (no npmjs proxying). |
| `E413 request entity too large` when publishing packages above ~7.5MB | Verdaccio's default `max_body_size` is 10MB, but npm publishes tarballs base64-encoded in a JSON document (~1.33x wire size). Set `max_body_size: 100mb` in `/etc/verdaccio/config.yaml` and restart verdaccio. |
| npm gets E401 although `curl -u USER:PASS` works fine | The npmrc uses username/password lines, which modern npm never sends on requests (verified: request goes out with no Authorization header). Switch to `_authToken` — see Client configuration. |
| Login PUT returns "The provided password does not pass the validation" | The JSON body is missing or lacks `password` — the login protocol requires the password in BOTH the Basic auth header and the JSON body (`{"name":...,"password":...}`). |
| 404 for npm requests that work when hitting `127.0.0.1:4873` directly | The `@npm` matcher/`handle @npm` route is missing, shadowed by an earlier handler, or the path doesn't match the npm pattern (e.g. a multi-segment path); or verdaccio not running (`systemctl status verdaccio`). |
| pip gets 401 on wheel downloads from the jacloud PyPI index (e.g. `https://jacloud.site/packages/<wheel>`) | The `/packages/*` Caddy route is missing, points at verdaccio, or uses `handle_path`. It must be plain `handle /packages/* { reverse_proxy 127.0.0.1:8080 }` so pypiserver receives its own `/packages/<wheel>` path. |
| `npm error code E401 ... npmjs.com/forgot` during a build that should use jacloud.site | The client never received the registry config (missing/empty npmrc) — npm fell back to the public registry. Check which file the build actually mounts (`--mount=type=secret` sources, `NPM_CONFIG_USERCONFIG`). |
| `-bash: ~/.local/share/pi-node/...: No such file or directory` when running `node` | Stale shell hash/PATH from pi's managed Node — see §1 pitfall. `hash -r`. |
| Verdaccio won't start, `EADDRINUSE 4873` | Another process holds the port: `ss -ltnp \| grep 4873`. |
| Publish works locally but clients can't fetch a private package | Client not authenticated (`access: $authenticated`), or proxying is on and the name collides with an upstream package that gets served from npmjs instead. Rename scope or tighten `packages:` rules. |
