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

The host `gitrepos/` directory is bind-mounted into the container so the agent can read and write local repositories.

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

To enable SSH from inside the container, add this optional setting:

```bash
SSH_DIR_HOST_PATH=/absolute/path/to/.ssh
```

The container runs as `app_user`, not as `root`. The image does not grant `app_user` passwordless sudo access.

When `SSH_DIR_HOST_PATH` is set, the main compose file mounts your host `.ssh` directory read-only at `/mnt/host-ssh`. The entrypoint then exposes only recognizable public key files, the host `config` file, and the specific `vastai` key file from that directory inside `/home/app_user/.ssh`. Other private keys are not mounted into the live `app_user` SSH directory.

When `SSH_DIR_HOST_PATH` is unset, compose mounts an empty managed volume at `/mnt/host-ssh`, and no public keys are linked into `/home/app_user/.ssh`.

With that env file, the bind mounts become:

- host `${GITREPOS_HOST_PATH}` → container `/workspace/gitrepos`
- host `${PI_CONFIG_HOST_PATH}` → container `/home/app_user/.pi`
- host `${SSH_DIR_HOST_PATH}` → container `/mnt/host-ssh` when public-key exposure is enabled

Inside the running container, every host `*.pub` file becomes available at:

- `/home/app_user/.ssh/<keyname>.pub`

Additionally, public key files that do not end in `.pub` but contain a recognizable SSH public key header are also exposed with their original filename.

If present on the host, the following file is also exposed inside the container:

- `/home/app_user/.ssh/config`
- `/home/app_user/.ssh/vastai`

Open an interactive shell in the running container:

```bash
scripts/pi_dev_agent.sh shell
```

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

## SSH Public Keys

The base image already includes `openssh-client`, and with `SSH_DIR_HOST_PATH` configured the container can read your host public keys. This setup intentionally does not expose private keys in `/home/app_user/.ssh`.

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

Use the SSH override only when you need remote access from inside the container. Leaving it unset keeps the default runtime narrower.

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
`NO_PROXY` is configurable through `.env.pi-dev.local`.

The Compose networking now narrows this to the `pi-dev-agent` container only:

- `pi-dev-agent` is attached only to an internal Docker network
- `pi-dev-agent-proxy` is attached to both the internal network and a normal egress network

That means `pi-dev-agent` can reach the proxy, but does not have its own direct internet egress path on Docker networking.

Note: `NO_PROXY` still allows direct connections to explicitly local or internal destinations such as `localhost`, `host.docker.internal`, `.svc`, and `.dev.jac.dot`.

## Notes

- The bind mount is a runtime concern, so it is configured in `docker-compose/pi-dev-agent.yml`, not in the image alone.
- The agent image also declares Docker volumes for the workspace and `.pi` config so the expected mount points are explicit.