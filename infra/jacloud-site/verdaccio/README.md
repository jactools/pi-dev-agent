# Verdaccio on jacloud.site — deployable files

Files in this folder are deployed **as-is** to the server (no editing needed):

| File | Destination | Owner / mode |
|---|---|---|
| `config.yaml` | `/etc/verdaccio/config.yaml` | `root:verdaccio`, `750` |
| `verdaccio.service` | `/etc/systemd/system/verdaccio.service` | `root:root`, `644` |
| `caddy-npm-route.snippet` | copy into the `jacloud.site` block of `/etc/caddy/Caddyfile` | — |

Full runbook (Node 24 install, user creation, verification, operations, troubleshooting):
[`docs/infra/NPM_REGISTRY_VERDACCIO.md`](../../../docs/infra/NPM_REGISTRY_VERDACCIO.md)

## Deploy (from this repo, as your normal user on the server or via scp)

```bash
# 1) Copy the files over (adjust host/user)
scp config.yaml verdaccio.service caddy-npm-route.snippet USER@jacloud.site:/tmp/verdaccio-deploy/ \
  || { ssh USER@jacloud.site 'mkdir -p /tmp/verdaccio-deploy' && scp config.yaml verdaccio.service caddy-npm-route.snippet USER@jacloud.site:/tmp/verdaccio-deploy/; }

# 2) Install them (on the server)
sudo mkdir -p /etc/verdaccio
sudo install -o root -g verdaccio -m 750 /tmp/verdaccio-deploy/config.yaml /etc/verdaccio/config.yaml
sudo install -m 644 /tmp/verdaccio-deploy/verdaccio.service /etc/systemd/system/verdaccio.service

# 3) Add the Caddy route (insert the snippet into the jacloud.site site block), then:
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy

# 4) Reload + start
sudo systemctl daemon-reload
sudo systemctl enable --now verdaccio
sleep 2 && sudo journalctl -u verdaccio -n 10 --no-pager

# 5) Verify
curl -s http://127.0.0.1:4873/-/ping                 # expect: {}
curl -s https://jacloud.site/-/ping                 # expect: {} (after Caddy reload)
```

## Prerequisites on the server (one-time, see runbook for details)

- Node 24 via NodeSource (`/usr/bin/node`)
- verdaccio installed globally: `sudo npm install -g verdaccio` (latest; verified on v7.1.0)
  — clients must use `_authToken` (see runbook, Client configuration)
- System user + dirs: `useradd --system -d /var/lib/verdaccio -s /usr/sbin/nologin verdaccio`,
  `mkdir -p /var/lib/verdaccio/storage && chown -R verdaccio:verdaccio /var/lib/verdaccio`

## After first start

```bash
npm adduser --registry https://jacloud.site/     # create the npm user (NPM_* for npm)
# freeze the user list afterwards: max_users: -1 in config.yaml + systemctl restart verdaccio
```
