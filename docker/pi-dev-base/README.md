# pi-dev Base Image (moody-ai based)

This Dockerfile builds the `platform-pi-dev-base` image using moody-ai as the base runtime.

## Requirements

The build script requires exactly one source mode (`--local` or `--corporate`)
plus an explicit env name: `--env dev|test|prod` and the mode select
`.env.<env>.<mode>` (for example, `.env.dev.local`) from the repository root.
These files use shell assignment syntax and are sourced by the script.
Create a missing file from the matching `.example`; preserve existing user values.
The examples share build/runtime keys, with local source defaults and a deliberately
blank corporate Java source and Dockerfile frontend. See [environment setup](../../docs/infra/PI_DEV_AGENT_IMAGE.md#environment-templates)
for runtime `--env` selection. `NPM_CONFIG_FILE` is required for corporate
agent builds and optional locally. The helper forwards it as an agent-only
BuildKit secret; the wrapper also mounts it as a read-only runtime secret when
configured and copies it into the container for Pi package installs. The agent
can read its credentials, but the host file is not modified or baked into an
image. Direct Compose builds need an equivalent build-secret override.
Referenced host cert files and env vars are not imported automatically.
`PIP_CONFIG_FILE` remains unsupported and is not forwarded.

### Required Build Arguments

| Variable | Description | Example |
|----------|-------------|---------|
| `BUILD_BASE_IMAGE` | Local tag built separately from moody-ai sources; required before base builds in both modes | `moody-ai-base:latest` |
| `JAVA_SOURCE_IMAGE` | Upstream Java/Temurin image; fully qualified corporate registry reference required in corporate mode, with no public fallback | Local default: `eclipse-temurin:25-jdk` |
| `BUILDKIT_SYNTAX` | BuildKit built-in argument selecting the Dockerfile frontend for both builds; required corporate reference with no public fallback in corporate mode | Local default: `docker/dockerfile:1.7` |
| `MOODY_NODE_VERSION` | Existing Node.js version setting; does not select a source image | `22` |
| `MOODY_JAVA_VERSION` | Existing Java version setting; does not select a source image | `25` |

Both source images are selected by global Dockerfile arguments before the first
`FROM`. Direct Docker builds use the local defaults unless overridden.
The Java source must provide `/opt/java/openjdk` and support the existing
`apt-get` commands (as the Temurin image does). Select a source containing the
desired JDK; `MOODY_JAVA_VERSION` does not change `JAVA_SOURCE_IMAGE`.

### Optional Build Arguments

| Variable | Description | Default |
|----------|-------------|---------|
| `SSL_CERT_PATH` | SSL certificate path inside container | `/etc/ssl/certs/ca-certificates.crt` |
| `MOODY_PYTHON_VERSION` | Python version via pyenv | `3.13` |

### PyPI/Nexus Configuration (Optional)

These can be set for custom registry support:

- `PIP_INDEX_URL` - Primary PyPI index URL
- `PIP_EXTRA_INDEX_URL` - Additional PyPI indices  
- `PIP_TRUSTED_HOST` - Trusted host for PyPI
- `NEXUSCLOUD_URL` - Nexus Cloud registry URL (requires username/password)
- `NEXUSCLOUD_USERNAME` - Nexus Cloud username
- `NEXUSCLOUD_PASSWORD` - Nexus Cloud password

## Building the Image

### Local moody-ai prerequisite

First build moody-ai separately from its local sources using the moody-ai source
project's own build instructions. Load/tag the resulting image locally as
`moody-ai-base:latest`, or the local tag selected by `BUILD_BASE_IMAGE`. This
applies to both local and corporate modes: moody-ai must not be fetched through
any registry.

Before building the base, the helper runs `docker image inspect "$BUILD_BASE_IMAGE"`.
Any inspection failure stops the script before any build, with instructions to
build/load locally first and check Docker daemon access. It never automatically
pulls a missing moody-ai image.

The default Docker daemon-backed builder must be able to access this local image.
Separate buildx/docker-container/remote builders may not see daemon images; ensure
your selected builder can access the locally built image. `--pull=false` alone
cannot prevent registry fallback when the builder cannot resolve a local image.
The helper does not force a builder or enforce offline builds. Direct Docker
builds below bypass the helper's preflight and require the same local prerequisite.

```bash
# Minimal .env.dev (source images may be omitted for local defaults)
cat > .env.dev <<'EOF'
MOODY_NODE_VERSION=22
MOODY_JAVA_VERSION=25
EOF
./scripts/build_pi_dev_images.sh --local --env dev

# Or specify build args directly
docker build \
  --file docker/pi-dev-base/Dockerfile.pi-dev-base \
  --build-arg BUILD_BASE_IMAGE=moody-ai-base:latest \
  --build-arg JAVA_SOURCE_IMAGE=eclipse-temurin:25-jdk \
  --build-arg BUILDKIT_SYNTAX=docker/dockerfile:1.7 \
  --build-arg MOODY_NODE_VERSION=22 \
  --build-arg MOODY_JAVA_VERSION=25 \
  -t platform-pi-dev-base:latest \
  .
```

### Corporate Java source and Dockerfile frontend

Keep `BUILD_BASE_IMAGE` as the locally built moody-ai tag. Upstream Java/Temurin
and the Dockerfile frontend use the corporate registry. Fill in the blank
`JAVA_SOURCE_IMAGE` and `BUILDKIT_SYNTAX` with approved, fully qualified references:

```dotenv
BUILD_BASE_IMAGE=moody-ai-base:latest
JAVA_SOURCE_IMAGE=<corporate-registry-host>/<namespace>/eclipse-temurin:25-jdk
BUILDKIT_SYNTAX=<corporate-registry-host>/<namespace>/docker/dockerfile:1.7
NPM_CONFIG_FILE="$HOME/.npmrc"
```

The registry host/namespace above are placeholders, not a working URL.
Replace them before sourcing the file. Authenticate to the source/frontend registry
as required, using its actual host (and port if applicable):

```bash
docker login <corporate-registry-host>
./scripts/build_pi_dev_images.sh --corporate --env prod
```

These script examples build both base and agent images by default. Corporate mode
fails before invoking Docker if either source image or `BUILDKIT_SYNTAX` is empty;
agent builds also require a nonempty, readable regular `NPM_CONFIG_FILE`.
It never supplies a public Java or frontend fallback. The selected frontend is
logged and passed as `--build-arg BUILDKIT_SYNTAX=...` on both builds, including
the base Dockerfile which has no syntax directive.
Nonempty references are passed through as supplied:
the script does not enforce a registry allowlist.

Direct Docker/Compose builds bypass that validation and must supply the corporate
`BUILDKIT_SYNTAX` too; the agent's `# syntax=docker/dockerfile:1.7` remains the
public default. See [direct build commands](../../docs/infra/PI_DEV_AGENT_IMAGE.md#direct-docker-and-compose-builds).

Registry selection is **not network enforcement**. It selects the upstream Java
`FROM` image and Dockerfile frontend, not the local moody-ai base; package installs and downloads may still access
other hosts. The npmrc configures build-time and Pi runtime npm installs, not
Playwright browser downloads or OS package downloads. Enforce corporate-only network access separately
using registry, Docker daemon, firewall, and proxy policies. This does not change
pip configuration or the Compose proxy image.

### Debian/APT build caches

Every APT-using build step in the base and agent (including Playwright's
`--with-deps` install) uses BuildKit persistent cache mounts for downloaded
archives (`/var/cache/apt`) and indices (`/var/lib/apt/lists`), with
`sharing=locked` to serialize concurrent users. Installed package state
(`/var/lib/dpkg`) stays in image layers, not a cache. Docker's `docker-clean`
hooks are removed and downloaded packages are kept. Moody-derived base/agent
steps share architecture-specific cache IDs; the independent Temurin source
uses separate IDs. The agent inherits the base's APT configuration.

Reuse is **per BuildKit builder**, not a portable image feature. Completed
downloads can survive a failed RUN and be reused on retry; a first fetch is
still required, and APT still refreshes indices whenever an install RUN executes.
Normal image-layer caching may skip an unchanged RUN altogether. Cache contents
are disposable: builder garbage collection or pruning can remove them, forcing
downloads again. Changing builders also starts without the previous cache.

APT uses three retries, 60-second HTTP/HTTPS timeouts, and strict update error
handling (including APT invoked by Playwright). Caching reduces repeated
downloads; it does **not** cure an unreachable Debian repository or network
timeouts. If Debian is unreachable, configure an approved corporate APT mirror
or apt-cacher-ng separately using your organization's supplied endpoint.
No mirror/proxy is provisioned here and TLS verification is not weakened.
The optional npmrc remains a secret mount during image builds; no npm config or
secret cache is persisted in the image. The wrapper's runtime secret handling is
separate. Registry/frontend selection and existing environment variables are
unchanged.

## Testing the Image

To verify an actually built image:

```bash
docker run --rm platform-pi-dev-base:latest bash -c "node --version && npm --version && python3 --version && java --version"
```

Expected output:
- Node.js v22.x.x
- npm x.y.z
- Python 3.13.x
- Java (OpenJDK) 25.x.x

## Image Contents

The base image includes:
- **Node.js**: Installed from moody-ai-base (v22+)
- **Python 3.13**: Via pyenv
- **Java 25**: Eclipse Temurin JDK
- **kubectl**: Latest version
- **pyenv**: Python version management
- **Shell tools**: bash, zsh, vim, nano, etc.

## Multi-stage Build Architecture

```
Stage 1 (base): ${BUILD_BASE_IMAGE}
   └─> Adds system packages + Python/pyenv
   
Stage 2 (java_runtime): base
   └─> Installs ca-certificates
   
Stage 3 (java_source): ${JAVA_SOURCE_IMAGE}
   └─> Provides Java installation
   
Stage 4 (final): java_runtime
   └─> Copies Java from java_source, adds user/workspace
```

## Environment Variables Set in Image

| Variable | Value |
|----------|-------|
| `JAVA_HOME` | `/opt/java/openjdk` |
| `PATH` | Includes `${JAVA_HOME}/bin` |
| `SSL_CERT_FILE` | `/etc/ssl/certs/ca-certificates.crt` |
| `REQUESTS_CA_BUNDLE` | `/etc/ssl/certs/ca-certificates.crt` |
| `PIP_CERT` | `/etc/ssl/certs/ca-certificates.crt` |
| `NODE_EXTRA_CA_CERTS` | `/etc/ssl/certs/ca-certificates.crt` |

## User & Directory Setup

- **User**: `app_user` (created during build)
- **Home directory**: `/home/app_user`
- **Workspace**: `/workspace`
- **PI config**: `/home/app_user/.pi`
- **SSH keys**: `/home/app_user/.ssh`
