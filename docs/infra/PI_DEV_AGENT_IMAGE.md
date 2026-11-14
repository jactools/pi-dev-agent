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
- Purges the `git` CLI and removes the package manager (`apt`, `apt-get`,
  `dpkg`) so nothing can be installed at runtime (the agent could otherwise
  simply reinstall git)
- Declares volumes for `/workspace/gitrepos` and `/home/app_user/.pi`
- Starts in `/workspace/gitrepos`

## Build

Use the build helper directly with exactly one source mode and an explicit env name:

```bash
scripts/build_pi_dev_images.sh --local --env dev
# or:
scripts/build_pi_dev_images.sh --corporate --env prod
```

Both commands build both images. The helper loads `.env.<env>.<mode>` (for
example, `.env.dev.local` or `.env.prod.corporate`). Set image names,
`PI_DEV_IMAGE_TAG`, and `PI_CODING_AGENT_VERSION` in that file.
The wrapper forwards mode and env to the helper:
`scripts/pi_dev_agent.sh build --local --env dev`.

### Environment templates

`--env` selects the environment name (`dev`, `test`, or `prod`); builds also
select the mode-specific file `.env.<env>.local` or `.env.<env>.corporate`
(no defaults allowed). All wrapper commands use the selected mode-specific file.
At runtime, `--corporate` also allows `github.com` and its subdomains through
the proxy; `--local` keeps them blocked. Other GitHub-hosted domains remain
blocked in both modes.
The templates
`.env.dev.example`, `.env.test.example`, and `.env.prod.example` have the same
build, runtime, and host-config keys, including commented assignments.
Copy the appropriate example only when creating a new env file; do not overwrite
an existing user env file or its values. All files use shell assignment syntax
and are sourced by the helpers: use trusted files and quote values where needed.

`dev` is the local machine; `test` and `prod` use corporate registry references.
Local defaults are `moody-ai-base:latest`, `eclipse-temurin:25-jdk`,
`BUILDKIT_SYNTAX=docker/dockerfile:1.7`, Node.js 22, and Java 25.
In both modes, `BUILD_BASE_IMAGE` is a local tag built separately from moody-ai
sources, not fetched from any registry. Use the moody-ai source project's own
build instructions, then load/tag the resulting image locally as
`moody-ai-base:latest` (or your selected local tag) before building pi-dev.
For corporate builds, upstream Java/Temurin and the Dockerfile frontend use the
corporate registry: fill in `JAVA_SOURCE_IMAGE` and `BUILDKIT_SYNTAX` with fully
qualified corporate references (both intentionally blank in the example; no
public fallback in the helper). The helper logs the selected frontend and passes
the built-in `--build-arg BUILDKIT_SYNTAX=...` on both image builds. A user-only
`CORPORATE_REGISTRY` helper may compose these references in an actual env file;
it is not a required template key. The version labels do not select different
source images.

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

When present, the repository-local `proxy/npmrc` is the source of truth for npm.
Otherwise, `NPM_CONFIG_FILE` may name a readable regular host npmrc file.
Corporate agent builds require one of these files; the wrapper validates the
selected path before invoking Docker. The same file is used as a BuildKit secret
for the agent build and as a read-only Compose secret at runtime. BuildKit mounts
it only during the agent install `RUN`; runtime startup copies it to
`/home/app_user/.npmrc` with mode `0600` and sets `NPM_CONFIG_USERCONFIG` for
Pi's package installs. Its contents are not baked into an image, but are
readable by the running agent.

The wrapper optionally reads the host Pi auth file at
`$HOME/.pi/agent/auth.json` (override with `PI_AUTH_FILE`) as a read-only
Compose secret, then copies it into the container's private Pi config on
startup. The host file is never mounted writable or modified. If it is absent,
the wrapper warns and starts without host Copilot credentials. Corporate mode
permits `github.com` and its subdomains for Copilot authentication/token
requests; local mode blocks them.

In corporate mode, `CORPORATE_CA_CERT_FILE` may name a readable PEM-encoded
corporate root CA on the host. The wrapper mounts it read-only as a Compose
secret, and the entrypoint installs it into the container trust store before
starting Pi, so the existing system CA bundle includes it.

The Compose service sets `NPM_CONFIG_STRICT_SSL=false` for npm at runtime, as
requested. This disables npm's certificate verification and is insecure; it
does not disable TLS verification in Pi's Node.js Copilot client. It is not
passed to image-build npm commands.

Corporate mode also sets `NODE_TLS_REJECT_UNAUTHORIZED=0` for Node.js, as
requested. This disables TLS certificate verification for every Node.js process
in the corporate container, including Pi and any extensions. It can expose
Copilot credentials and traffic to interception; use only as a temporary
diagnostic workaround and restore verification when possible. Local mode keeps
Node.js TLS verification enabled.

Host certificate files and environment variables referenced by npmrc are not
automatically imported. Use `CORPORATE_CA_CERT_FILE` for a corporate CA, and
ensure any npmrc `cafile` path is valid inside the container. Playwright browser
downloads and OS dependencies are separate from npm registry downloads and may
need their own network/proxy/CA configuration. Build secrets do not enforce
corporate-only network access. BuildKit does not invalidate cached install
layers when a secret changes; rebuild without cache when you need npm installs
to run again.

When present, repository-local `proxy/pip.conf` is the source of truth for pip.
Otherwise, `PIP_CONFIG_FILE` may name a readable regular host pip configuration
file. The wrapper mounts the selected file read-only as a runtime secret and
points pip at it while populating `/workspace/.venv`; it is not passed to image
builds. Its contents and any credentials it contains are readable inside the
running container. The separate optional `PYPI_USERNAME`/`PYPI_PASSWORD` inputs configure the
entrypoint's `jacloud.site` index only when both are set; an explicit
`PIP_CONFIG_FILE` takes precedence. `CORPORATE_REGISTRY` is not interpreted as
a pip index URL; put the registry URL and any required auth in `pip.conf`.

The container provides a shared Python 3.13 virtual environment at
`/workspace/.venv`, with its `bin` directory first on `PATH`. At startup, the
entrypoint installs dependencies found in `requirements*.txt` files and
`pyproject.toml` packages under the mounted allowlisted repositories, plus the
shared test-package set, including `python-pptx`, into this venv. Use `python`,
`pip`, or activate it
with `source /workspace/.venv/bin/activate`; no per-repository venv is needed.

### Direct Docker and Compose builds

The agent Dockerfile retains `# syntax=docker/dockerfile:1.7` as its public local
default; the base Dockerfile has no syntax directive. BuildKit's built-in
`BUILDKIT_SYNTAX` build argument overrides frontend selection for either file.
It is not an ordinary Dockerfile `ARG` and cannot be interpolated into `# syntax`.

Direct builds bypass the helper's corporate checks. Supply the corporate
frontend explicitly even when not using the helper. For example, after editing
the trusted corporate env file and building/loading moody-ai locally:

```bash
source .env.prod
: "${BUILDKIT_SYNTAX:?Set the corporate Dockerfile frontend reference}"
: "${JAVA_SOURCE_IMAGE:?Set the corporate Java source reference}"
if [ -f proxy/npmrc ]; then NPM_CONFIG_FILE="$PWD/proxy/npmrc"; fi
: "${NPM_CONFIG_FILE:?Provide proxy/npmrc or set NPM_CONFIG_FILE}"
export NPM_CONFIG_FILE
test -f "$NPM_CONFIG_FILE" && test -r "$NPM_CONFIG_FILE" || {
  echo "NPM_CONFIG_FILE must name a readable regular file" >&2
  exit 1
}
docker build --file docker/pi-dev-base/Dockerfile.pi-dev-base \
  --build-arg BUILDKIT_SYNTAX="$BUILDKIT_SYNTAX" \
  --build-arg BUILD_BASE_IMAGE="$BUILD_BASE_IMAGE" \
  --build-arg JAVA_SOURCE_IMAGE="$JAVA_SOURCE_IMAGE" \
  --tag "${PI_DEV_BASE_IMAGE_NAME:-platform-pi-dev-base}:${PI_DEV_IMAGE_TAG:-latest}" .
docker build --file docker/pi-dev-agent/Dockerfile.pi-dev-agent \
  --secret "id=npmrc,src=$NPM_CONFIG_FILE" \
  --build-arg BUILDKIT_SYNTAX="$BUILDKIT_SYNTAX" \
  --build-arg BASE_IMAGE="${PI_DEV_BASE_IMAGE_NAME:-platform-pi-dev-base}:${PI_DEV_IMAGE_TAG:-latest}" \
  --build-arg PI_CODING_AGENT_VERSION="${PI_CODING_AGENT_VERSION:-latest}" \
  --tag "${PI_DEV_AGENT_IMAGE_NAME:-platform-pi-dev-agent}:${PI_DEV_IMAGE_TAG:-latest}" .

# Alternative agent build after the base is built; create the override below first:
docker compose --env-file .env.prod \
  -f docker-compose/pi-dev-agent.yml -f compose.npmrc.yml build \
  --build-arg BUILDKIT_SYNTAX="$BUILDKIT_SYNTAX" pi-dev-agent
```

For that direct Compose build, create `compose.npmrc.yml` in the repository root
with the following declaration (it contains only a path reference, not credentials):

```yaml
services:
  pi-dev-agent:
    build:
      secrets:
        - npmrc
secrets:
  npmrc:
    file: ${NPM_CONFIG_FILE:?Set npmrc path}
```

For direct Compose builds, set `NPM_CONFIG_FILE` to the chosen npmrc; the wrapper
prefers `proxy/npmrc` when present. Direct Compose does not select or forward the
secret automatically: the override is required to avoid silently using npm
defaults. Omit the override for local builds without a config. The wrapper
generates the equivalent declaration conditionally for its Compose calls.

Compose also forwards `BUILDKIT_SYNTAX` from its environment/env file as a build
argument, defaulting to `docker/dockerfile:1.7` when unset or empty for local
builds. It has no corporate mode validation: populate the corporate value before
direct Compose builds (the explicit argument above makes the override clear).
Registry selection is not network enforcement; downloads and other images may
still use other hosts. This does not change local moody-ai handling or pip
configuration.

## Run

By default, the host `gitrepos/` directory is bind-mounted into the container so the agent can read and write local repositories.

Start the agent container with Docker Compose:

```bash
cp .env.dev.example .env.dev.local
# edit .env.dev.local
scripts/build_pi_dev_images.sh --local --env dev   # once, or after changing the Dockerfiles
# (equivalently: scripts/pi_dev_agent.sh build --local --env dev)
scripts/pi_dev_agent.sh start --local --env dev    # does NOT build; uses the existing images
```

For an existing, edited corporate prod env file, select the same mode explicitly
at runtime:

```bash
scripts/build_pi_dev_images.sh --corporate --env prod
# (equivalently: scripts/pi_dev_agent.sh build --corporate --env prod)
scripts/pi_dev_agent.sh start --corporate --env prod
scripts/pi_dev_agent.sh shell --corporate --env prod
```

Use the same `--env` and mode for restart, stop, logs, config, and reset-config.

The compose file intentionally does not contain machine-specific absolute paths. Set them in `.env.dev.local`:

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

- host `${GITREPOS_HOST_PATH}/<repo>` → container `/workspace/gitrepos/<repo>` for each `GITREPOS_ALLOWLIST` entry (required; mounting the whole directory is not allowed)
- The pi-dev-agent repo itself must never appear in `GITREPOS_ALLOWLIST`: it must NOT be made available inside its own container, and `scripts/pi_dev_agent.sh` rejects such entries
- private Docker volume `pi-config` → container `/home/app_user/.pi` (never the host `~/.pi`)
- host `${HOST_BIN_DIR_HOST_PATH}` → container `/home/app_user/bin` when host helper script exposure is enabled
- host `${HOST_SSH_KEY_PATH:-$HOME/.ssh/pi-dev-agent_host}` → container `/mnt/host-ssh/id_ed25519` (dedicated key only)

On every container start, the image's `pi/agent/settings.json` template replaces
`/home/app_user/.pi/agent/settings.json`. The repository settings are
authoritative; container-side edits to that file do not persist across restarts.

Inside the running container, the dedicated key is available at:

- `/home/app_user/.ssh/id_ed25519` (symlink to the read-only bind mount)

The standard Compose stack does not expose host SSH config, known_hosts, or
other identities. The generated alias config and learned host keys live in the
container's persistent SSH volume.

Open an interactive shell in the running container:

```bash
scripts/pi_dev_agent.sh shell --local --env dev
```

With `HOST_BIN_DIR_HOST_PATH` set to your host `bin` directory, a host script such as `ssh-llm` becomes directly invocable inside the container because `/home/app_user/bin` is added to `PATH`.

Common wrapper commands:

```bash
scripts/pi_dev_agent.sh start --local --env dev
scripts/pi_dev_agent.sh restart --local --env dev
scripts/pi_dev_agent.sh stop --local --env dev
scripts/pi_dev_agent.sh logs --local --env dev
scripts/pi_dev_agent.sh config --local --env dev
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
scripts/pi_dev_agent.sh shell --local --env dev
ls -l /home/app_user/.ssh/id_ed25519
```

Example SOCKS proxy:

```bash
scripts/pi_dev_agent.sh shell --local --env dev
ssh -N -D 1080 your-user@your-vast-host
```

Example host login:

```bash
scripts/pi_dev_agent.sh shell --local --env dev
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
scripts/pi_dev_agent.sh shell --local --env dev
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

The agent container does not receive the Squid config files themselves. It still sees the standard `HTTP_PROXY` and `HTTPS_PROXY` variables, because conventional HTTP clients need those in order to use the proxy. The entrypoint preserves proxy and CA variables when it switches to `app_user`; a login shell would otherwise clear them. The broader internal proxy-control settings are not exposed as ordinary container env configuration.

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