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

Use the build helper directly with exactly one environment mode:

```bash
scripts/build_pi_dev_images.sh --local
# or:
scripts/build_pi_dev_images.sh --corporate
```

Both commands build both images. Set image names, `PI_DEV_IMAGE_TAG`, and
`PI_CODING_AGENT_VERSION` in the selected env file.
The wrapper's build commands do not currently forward the required mode, and
the helper's extra option parsing is not covered by this workflow.

### Environment templates

`.env.pi-dev.local.example` and `.env.pi-dev.corporate.example` have the same
build, runtime, and reserved-path keys, including commented optional assignments.
Copy the appropriate example only when creating a new env file; do not overwrite
an existing `.env.pi-dev.corporate` or its user values. Both files use shell
assignment syntax and are sourced by the helpers: use trusted files and quote
values where needed.

Local source defaults are `moody-ai-base:latest` and `eclipse-temurin:25-jdk`.
In both modes, `BUILD_BASE_IMAGE` is a local tag built separately from moody-ai
sources, not fetched from any registry. Use the moody-ai source project's own
build instructions, then load/tag the resulting image locally as
`moody-ai-base:latest` (or your selected local tag) before building pi-dev.
For corporate builds, only upstream Java/Temurin uses the corporate registry:
fill in `JAVA_SOURCE_IMAGE` with its fully qualified corporate reference
(intentionally blank in the example; no public fallback). The version labels
do not select different source images.

Before any base build, the helper runs `docker image inspect "$BUILD_BASE_IMAGE"`
and exits on failure without building or automatically pulling the missing base.
Inspection errors may also indicate an inaccessible Docker daemon.
The default Docker daemon-backed builder must be able to access the local image.
Separate buildx/docker-container/remote builders may not see daemon images; ensure
the selected builder has access to the locally built image. `--pull=false` alone
cannot prevent registry fallback when a builder cannot resolve a local image.
This preflight does not enforce offline builds or force a builder.
See [base build requirements](../../docker/pi-dev-base/README.md).

Before runtime startup, replace the required `GITREPOS_HOST_PATH` placeholder.
Commented optional settings use the wrapper/Compose defaults; they are not all
required corporate values. No personal repository allowlist or direct egress
exception is enabled by the templates.

`NPM_CONFIG_FILE` and `PIP_CONFIG_FILE` are reserved host paths only. Neither
build helper nor Compose mounts, passes, or consumes them; setting them does
**not** configure npm/pip or forward secrets. Existing corporate assignments may
remain, but plumbing for those files is outstanding. The separate optional
`PYPI_USERNAME`/`PYPI_PASSWORD` runtime inputs only configure the entrypoint's
existing `jacloud.site` index when both are set; they are not generic corporate
registry configuration or build inputs. Leave them unset unless that index is
intended; no host credential/config files need to be read for template setup.

## Run

By default, the host `gitrepos/` directory is bind-mounted into the container so the agent can read and write local repositories.

Start the agent container with Docker Compose:

```bash
cp .env.pi-dev.local.example .env.pi-dev.local
# edit .env.pi-dev.local
scripts/build_pi_dev_images.sh --local # once, or after changing the Dockerfiles
scripts/pi_dev_agent.sh start    # does NOT build; uses the existing images
```

For an existing, edited corporate env file, select it explicitly at runtime
(the build mode is not remembered by the startup wrapper):

```bash
scripts/build_pi_dev_images.sh --corporate
scripts/pi_dev_agent.sh start --env-file .env.pi-dev.corporate
scripts/pi_dev_agent.sh shell --env-file .env.pi-dev.corporate
```

Use the same `--env-file` for restart, stop, logs, config, and reset-config.

The compose file intentionally does not contain machine-specific absolute paths. Set them in `.env.pi-dev.local`:

```bash
GITREPOS_HOST_PATH=/absolute/path/to/gitrepos
PI_DEV_AGENT_PORT=3000
```

To limit container access to a specific set of repositories under `GITREPOS_HOST_PATH`, add an optional comma-separated allowlist:

```bash
GITREPOS_ALLOWLIST=repo-one,repo-two
```

Each allowlist entry must be a relative path rooted under `GITREPOS_HOST_PATH`. For example, `team/service-a` mounts host `${GITREPOS_HOST_PATH}/team/service-a` into container `/workspace/gitrepos/team/service-a`.

To enable SSH from inside the container, add this optional setting:

```bash
HOST_SSH_KEY_PATH=/absolute/path/to/dedicated-host-key
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

The main compose file bind-mounts a single dedicated private key — `${HOST_SSH_KEY_PATH:-$HOME/.ssh/pi-dev-agent_host}` — read-only at `/mnt/host-ssh/id_ed25519`, and the entrypoint links it into `/home/app_user/.ssh` as the default identity. The full host `~/.ssh` directory is deliberately NOT mounted: an LLM agent running with root inside the container must never be able to read general-purpose host keys (GitHub, deploy, cloud accounts). Create a dedicated keypair for this purpose and authorize only its public key on the host user (e.g. `pidev`).

When `HOST_SSH_ALIAS` and `HOST_SSH_USER` are both set, the entrypoint writes a container-local SSH config with a `Host` block pointing at `${HOST_SSH_HOSTNAME:-host.docker.internal}`. That lets commands such as `ssh pidev` reach the host machine from inside the container without changing your host `~/.ssh/config`. The first connection prompts to confirm the host key; it is then stored in the persistent `.ssh` volume (`known_hosts.local`).

If `HOST_SSH_KEY_PATH` points at a file that does not exist, Docker creates a directory at that path on first start — create the key before starting the stack.

With that env file, the bind mounts become:

- host `${GITREPOS_HOST_PATH}` → container `/workspace/gitrepos` when `GITREPOS_ALLOWLIST` is unset
- host `${GITREPOS_HOST_PATH}/<repo>` → container `/workspace/gitrepos/<repo>` for each `GITREPOS_ALLOWLIST` entry
- private Docker volume `pi-config` → container `/home/app_user/.pi` (never the host `~/.pi`)
- host `${HOST_BIN_DIR_HOST_PATH}` → container `/home/app_user/bin` when host helper script exposure is enabled
- host `${HOST_SSH_KEY_PATH:-$HOME/.ssh/pi-dev-agent_host}` → container `/mnt/host-ssh/id_ed25519` (dedicated key only)

Inside the running container, the dedicated key is available at:

- `/home/app_user/.ssh/id_ed25519` (symlink to the read-only bind mount)

The standard Compose stack does not expose host SSH config, known_hosts, or
other identities. The generated alias config and learned host keys live in the
container's persistent SSH volume.

Open an interactive shell in the running container:

```bash
scripts/pi_dev_agent.sh shell
```

With `HOST_BIN_DIR_HOST_PATH` set to your host `bin` directory, a host script such as `ssh-llm` becomes directly invocable inside the container because `/home/app_user/bin` is added to `PATH`.

Common wrapper commands:

```bash
scripts/pi_dev_agent.sh start
scripts/pi_dev_agent.sh restart
scripts/pi_dev_agent.sh stop
scripts/pi_dev_agent.sh logs
scripts/pi_dev_agent.sh config
```

`start` and `restart` never build; they run the container from the existing local
images. Rebuild explicitly with the mode-selecting build helper shown above.

## SSH Access

The base image includes `openssh-client`. Use the dedicated key and optional
container-local alias settings above; the host's general SSH directory is not
mounted. Strict egress also requires an explicit, port-scoped direct exception
for SSH to a non-loopback destination.

If you also set `HOST_SSH_ALIAS` and `HOST_SSH_USER`, the container can SSH back into the Docker host through `host.docker.internal` using a stable alias such as `pidev`.

Example:

```bash
scripts/pi_dev_agent.sh shell
ls -l /home/app_user/.ssh/id_ed25519
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
- TLD allowlist lives in `docker/pi-dev-agent/proxy/allowed_tlds.txt`
- Site exceptions to the TLD allowlist live in `docker/pi-dev-agent/proxy/allowed_sites.txt`

Filtering is layered (first match wins, see `squid.conf`):

1. **Explicit deny** — `blocked_domains.txt` blocks specific domains regardless of TLD
   (e.g. `.github.com`, `.gitee.com`, web archives). A leading dot matches the domain
   and all subdomains; never list both forms of one domain in the file.
2. **Site exceptions** — `allowed_sites.txt` allows individual hosts on non-allowlisted
   TLDs (e.g. the private package index `jacloud.site`).
3. **TLD allowlist** — anything not matching an allowed top-level domain
   (`allowed_tlds.txt`, currently `.com .dev .io .org`) is denied by default.
   New gTLDs/ccTLDs are blocked automatically until added deliberately.

Port policy: only port **443** may be reached through the proxy, for both plain
HTTP requests and CONNECT tunnels. Local services never reach the proxy at all —
they bypass it via `NO_PROXY` plus port-scoped direct-allow iptables rules in the
agent container (see `PI_DEV_AGENT_DIRECT_ALLOW_HOSTS`).

`HTTP_PROXY` and `HTTPS_PROXY` are injected into the agent container automatically.
`PI_DEV_AGENT_NO_PROXY` in the selected env file sets both `NO_PROXY` and
`no_proxy`. Its commented template value matches Compose's default. Bypassing
the proxy does not open the strict egress firewall: non-loopback services also
need explicit `PI_DEV_AGENT_DIRECT_ALLOW_HOSTS` rules. On Docker Desktop,
hostname and resolved gateway-IP matching may both matter for HTTP clients.

Strict egress is enabled by default inside `pi-dev-agent`. Direct outbound connections are limited to the Squid sidecar and any explicit `PI_DEV_AGENT_DIRECT_ALLOW_HOSTS` entries. This means unsetting `HTTP_PROXY` or `HTTPS_PROXY` no longer restores direct web access.

The proxy sidecar is given a stable IP on the internal Docker network, and the agent's proxy environment variables point at that IP. That avoids depending on Docker DNS for the proxy itself after strict egress rules are active.

The container sets `PI_HOST=host.docker.internal` and `LLAMA_BASE_URL=http://host.docker.internal:8082`. The entrypoint resolves `${PI_HOST}` placeholders in `models.json` at startup (Pi does not interpolate env vars in `baseUrl`).

The agent container does not receive the Squid config files themselves. It still sees the standard `HTTP_PROXY` and `HTTPS_PROXY` variables, because conventional HTTP clients need those in order to use the proxy. The broader internal proxy-control settings are not exposed as ordinary container env configuration.

Allowed package hosts on non-allowlisted TLDs (such as `jacloud.site`) go in `allowed_sites.txt` rather than `NO_PROXY`. That keeps the traffic allowed while still forcing it through the proxy path.

The Compose networking uses separate internal and egress networks:

- `pi-dev-agent` is attached to both the internal Docker network and a normal egress network
- `pi-dev-agent-proxy` is attached to both the internal network and a normal egress network

`pi-dev-agent` still receives `HTTP_PROXY` and `HTTPS_PROXY` automatically for web traffic, but strict egress rules prevent direct outbound web traffic from bypassing the proxy even if those env vars are unset. If you need a specific direct destination such as `host.docker.internal:22`, add it to `PI_DEV_AGENT_DIRECT_ALLOW_HOSTS` explicitly.

Note: reserve `NO_PROXY` for explicitly local/internal destinations. Do not add
the broad `.dev.jac.dot` suffix: WeKan must stay proxied through its exact
host:port ACL, and other dev FQDNs should remain denied by default. Internet
destinations that are meant to stay allowed should remain proxied.

## Notes

- The bind mount is a runtime concern, so it is configured in `docker-compose/pi-dev-agent.yml`, not in the image alone.
- The agent image also declares Docker volumes for the workspace and `.pi` config so the expected mount points are explicit.