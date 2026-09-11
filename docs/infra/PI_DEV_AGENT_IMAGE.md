# Pi Dev Agent Images

**Status**: Draft  
**Date**: 2026-08-09

## Purpose

These images provide a reusable development container for running the `pi` coding agent against local repositories mounted from the host.

Two images are defined:

- `platform-pi-dev-base` — shared runtime with current Node.js, Python 3.13, and Java 25
- `platform-pi-dev-agent` — `pi` agent image built on top of `platform-pi-dev-base`

## Image contract

### `platform-pi-dev-base`

- Node.js source: `node:current-trixie`
- Python source: `python:3.13-trixie`
- Java source: `eclipse-temurin:25-jdk`
- Base distribution: `debian:trixie-slim`
- Extra tooling: `curl`, `jq`, `ripgrep`, `zsh`, `build-essential`, and common shell utilities
- The `git` CLI is intentionally omitted from the image

### `platform-pi-dev-agent`

- Base image: `platform-pi-dev-base`
- Installs `@earendil-works/pi-coding-agent`
- Installs Playwright plus the Playwright-managed Chromium bundle
- Declares volumes for `/workspace/gitrepos` and `/home/app_user/.pi`
- Starts in `/workspace/gitrepos`

## Build

For day-to-day use, prefer the convenience wrapper:

```bash
scripts/pi_dev_agent.sh build
```

Build both images:

```bash
scripts/build_pi_dev_images.sh
```

Build only the base image:

```bash
scripts/build_pi_dev_images.sh --image base
```

Build only the agent image after the base image already exists:

```bash
scripts/build_pi_dev_images.sh --image agent
```

Override the tag or agent version:

```bash
scripts/build_pi_dev_images.sh --tag dev --agent-version latest
```

## Run

By default, the host `gitrepos/` directory is bind-mounted into the container so the agent can read and write local repositories.

Start the agent container with Docker Compose:

```bash
cp .env.pi-dev.local.example .env.pi-dev.local
# edit .env.pi-dev.local
scripts/pi_dev_agent.sh start
```

The compose file intentionally does not contain machine-specific absolute paths. Set them in `.env.pi-dev.local`:

```bash
GITREPOS_HOST_PATH=/absolute/path/to/gitrepos
PI_CONFIG_HOST_PATH=/absolute/path/to/.pi
PI_DEV_AGENT_PORT=3000
```

To limit container access to a specific set of repositories under `GITREPOS_HOST_PATH`, add an optional comma-separated allowlist:

```bash
GITREPOS_ALLOWLIST=repo-one,repo-two
```

Each allowlist entry must be a relative path rooted under `GITREPOS_HOST_PATH`. For example, `team/service-a` mounts host `${GITREPOS_HOST_PATH}/team/service-a` into container `/workspace/gitrepos/team/service-a`.

To enable SSH from inside the container, add this optional setting:

```bash
SSH_DIR_HOST_PATH=/absolute/path/to/.ssh
```

To expose host helper scripts such as `ssh-llm` inside the container, add this optional setting:

```bash
HOST_BIN_DIR_HOST_PATH=/absolute/path/to/bin
```

To let the container SSH back into the Docker host as a local user, add these optional settings:

```bash
HOST_SSH_ALIAS=pidev
HOST_SSH_USER=pidev
```

The container runs as `app_user`, not as `root`. The image does not grant `app_user` passwordless sudo access.

When `SSH_DIR_HOST_PATH` is set, the main compose file mounts your host `.ssh` directory read-only at `/mnt/host-ssh`. The entrypoint then exposes the host `known_hosts` files, recognizable public keys, and any private keys referenced by `IdentityFile` directives in `~/.ssh/config` inside `/home/app_user/.ssh`.

When `HOST_SSH_ALIAS` and `HOST_SSH_USER` are both set, the entrypoint writes a container-local SSH config that includes the mounted host config and adds a `Host` block pointing at `${HOST_SSH_HOSTNAME:-host.docker.internal}`. That lets commands such as `ssh pidev` reach the host machine from inside the container without changing your host `~/.ssh/config`.

When `SSH_DIR_HOST_PATH` is unset, compose mounts an empty managed volume at `/mnt/host-ssh`, and no host SSH files are linked into `/home/app_user/.ssh`.

With that env file, the bind mounts become:

- host `${GITREPOS_HOST_PATH}` → container `/workspace/gitrepos` when `GITREPOS_ALLOWLIST` is unset
- host `${GITREPOS_HOST_PATH}/<repo>` → container `/workspace/gitrepos/<repo>` for each `GITREPOS_ALLOWLIST` entry
- host `${PI_CONFIG_HOST_PATH}` → container `/home/app_user/.pi`
- host `${HOST_BIN_DIR_HOST_PATH}` → container `/home/app_user/bin` when host helper script exposure is enabled
- host `${SSH_DIR_HOST_PATH}` → container `/mnt/host-ssh` when SSH file exposure is enabled

Inside the running container, every host `*.pub` file becomes available at:

- `/home/app_user/.ssh/<keyname>.pub`

Additionally, public key files that do not end in `.pub` but contain a recognizable SSH public key header are also exposed with their original filename.

If present on the host, the following files are also exposed or included inside the container:

- `/home/app_user/.ssh/config`
- `/home/app_user/.ssh/known_hosts`
- `/home/app_user/.ssh/known_hosts2`

Each `IdentityFile` referenced in `~/.ssh/config` is also linked into `/home/app_user/.ssh/<filename>` when the corresponding file exists in the mounted host `.ssh` directory.

The generated `/home/app_user/.ssh/config` always includes the mounted host config first when that file exists.

Open an interactive shell in the running container:

```bash
scripts/pi_dev_agent.sh shell
```

With `HOST_BIN_DIR_HOST_PATH` set to your host `bin` directory, a host script such as `ssh-llm` becomes directly invocable inside the container because `/home/app_user/bin` is added to `PATH`.

Common wrapper commands:

```bash
scripts/pi_dev_agent.sh build
scripts/pi_dev_agent.sh start
scripts/pi_dev_agent.sh restart
scripts/pi_dev_agent.sh stop
scripts/pi_dev_agent.sh logs
scripts/pi_dev_agent.sh config
```

`start` and `restart` both build the local base and agent images first, then recreate the container from those local images.

## SSH Access

The base image already includes `openssh-client`, and with `SSH_DIR_HOST_PATH` configured the container can use host entries defined in `~/.ssh/config`, including IP-based hosts that rely on `IdentityFile` and `known_hosts` data from the mounted host `.ssh` directory.

If you also set `HOST_SSH_ALIAS` and `HOST_SSH_USER`, the container can SSH back into the Docker host through `host.docker.internal` using a stable alias such as `pidev`.

Example:

```bash
scripts/pi_dev_agent.sh shell
ls -1 /home/app_user/.ssh/*.pub
```

Example SOCKS proxy:

```bash
scripts/pi_dev_agent.sh shell
ssh -N -D 1080 your-user@your-vast-host
```

Example host login:

```bash
scripts/pi_dev_agent.sh shell
ssh pidev
```

If the host-side `pidev` account should expose only `kubectl` and selected `dq-made-easy` validation scripts, use a compiled forced-command wrapper instead of a shell script. A compiled wrapper can be installed `root:root` with mode `711`, which keeps it executable by `pidev` without making the file itself readable to that account.

Build and install it on the Linux host that accepts the `pidev` SSH key:

```bash
cd /path/to/pi-dev-agent
go build -o /tmp/restricted-ssh ./scripts/restricted_ssh.go
install -o root -g root -m 711 /tmp/restricted-ssh /opt/bin/restricted-ssh
```

The wrapper allows:

- any invocation of `/usr/local/bin/kubectl` or `kubectl` that resolves to `/usr/local/bin/kubectl`
- `bash <dq-root>/scripts/validate*.sh ...`
- `bash <dq-root>/scripts/validation/**/*.sh ...`

Point the SSH key at the wrapper and pass the checked-out `dq-made-easy` repo root explicitly:

```text
command="/opt/bin/restricted-ssh --dq-root /Users/pidev/gitrepos/dq-made-easy" ssh-ed25519 <key material>
```

The wrapper parses `SSH_ORIGINAL_COMMAND` into argv and re-executes the approved binary directly, so command chaining such as `;`, `&&`, or shell substitution is not evaluated as another command.

The allowlist is still only as strong as the downstream permissions. If `kubectl` is broadly authorized, or if the approved `dq-made-easy` validation scripts are writable by `pidev`, the SSH restriction will still allow broad behavior through those permitted paths.

Use the SSH override only when you need remote access from inside the container. Leaving it unset keeps the default runtime narrower.

## Browser Automation

The agent image includes the `playwright` package and only the Playwright-managed Chromium bundle. It does not install a broader desktop browser set such as Chrome, Firefox, or WebKit.

Example check:

```bash
scripts/pi_dev_agent.sh shell
playwright --version
node -e 'const { chromium } = require("playwright"); console.log(chromium.executablePath())'
```

## HTTP Proxy Filtering

The `pi-dev-agent` compose stack can route HTTP and HTTPS traffic through a local Squid sidecar.

- Proxy wiring lives in `docker-compose/pi-dev-agent.yml`
- Squid config lives in `docker/pi-dev-agent/proxy/squid.conf`
- Hostname/domain deny rules live in `docker/pi-dev-agent/proxy/blocked_domains.txt`

The proxy can deny by DNS name or domain suffix, for example:

```text
.example.com
github.com
raw.githubusercontent.com
```

`HTTP_PROXY` and `HTTPS_PROXY` are injected into the agent container automatically.
`NO_PROXY` is configurable through `.env.pi-dev.local` for local and internal addresses that should never hit the sidecar proxy. On Docker Desktop, include both `host.docker.internal` and the resolved host-gateway IP when local host services such as a forwarded llama.cpp port must bypass the proxy reliably.

Strict egress is enabled by default inside `pi-dev-agent`. Direct outbound connections are limited to the Squid sidecar and any explicit `PI_DEV_AGENT_DIRECT_ALLOW_HOSTS` entries. This means unsetting `HTTP_PROXY` or `HTTPS_PROXY` no longer restores direct web access.

The proxy sidecar is given a stable IP on the internal Docker network, and the agent's proxy environment variables point at that IP. That avoids depending on Docker DNS for the proxy itself after strict egress rules are active.

For local llama.cpp usage on Docker Desktop, the agent entrypoint also starts a loopback bridge inside the container from `127.0.0.1:8082` to the host-forwarded llama server port. That lets the host browser and the in-container Pi runtime share the same base URL `http://localhost:8082/v1`.

The agent container does not receive the Squid config files themselves. It still sees the standard `HTTP_PROXY` and `HTTPS_PROXY` variables, because conventional HTTP clients need those in order to use the proxy. The broader internal proxy-control settings are not exposed as ordinary container env configuration.

Allowed package hosts such as `jacloud.nl` should remain off the Squid blocklist rather than being added to `NO_PROXY`. That keeps the traffic allowed while still forcing it through the proxy path.

The Compose networking uses separate internal and egress networks:

- `pi-dev-agent` is attached to both the internal Docker network and a normal egress network
- `pi-dev-agent-proxy` is attached to both the internal network and a normal egress network

`pi-dev-agent` still receives `HTTP_PROXY` and `HTTPS_PROXY` automatically for web traffic, but strict egress rules prevent direct outbound web traffic from bypassing the proxy even if those env vars are unset. If you need a specific direct destination such as `host.docker.internal:22`, add it to `PI_DEV_AGENT_DIRECT_ALLOW_HOSTS` explicitly.

Note: `NO_PROXY` should be reserved for explicitly local or internal destinations such as `localhost`, `host.docker.internal`, `.svc`, and `.dev.jac.dot`. Internet destinations that are meant to stay allowed should usually remain proxied and simply stay off the Squid deny list.

## Notes

- The bind mount is a runtime concern, so it is configured in `docker-compose/pi-dev-agent.yml`, not in the image alone.
- The agent image also declares Docker volumes for the workspace and `.pi` config so the expected mount points are explicit.