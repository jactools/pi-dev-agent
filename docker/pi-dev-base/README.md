# pi-dev Base Image (moody-ai based)

This Dockerfile builds the `platform-pi-dev-base` image using moody-ai as the base runtime.

## Requirements

The build script requires exactly one mode: `--local` loads `.env.pi-dev.local`,
and `--corporate` loads `.env.pi-dev.corporate` from the repository root.
These files use shell assignment syntax and are sourced by the script.
Create a missing file from the matching `.example`; preserve existing user values.
The examples share build/runtime keys, with local source defaults and a deliberately
blank corporate Java source. See [environment setup](../../docs/infra/PI_DEV_AGENT_IMAGE.md#environment-templates)
for runtime `--env-file` selection. `NPM_CONFIG_FILE` and `PIP_CONFIG_FILE` are
reserved paths only: neither builds nor Compose currently consumes these files
or forwards their credentials.

### Required Build Arguments

| Variable | Description | Example |
|----------|-------------|---------|
| `BUILD_BASE_IMAGE` | Local tag built separately from moody-ai sources; required before base builds in both modes | `moody-ai-base:latest` |
| `JAVA_SOURCE_IMAGE` | Upstream Java/Temurin image; fully qualified corporate registry reference required in corporate mode, with no public fallback | Local default: `eclipse-temurin:25-jdk` |
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
# Minimal .env.pi-dev.local (source images may be omitted for local defaults)
cat > .env.pi-dev.local <<'EOF'
MOODY_NODE_VERSION=22
MOODY_JAVA_VERSION=25
EOF
./scripts/build_pi_dev_images.sh --local

# Or specify build args directly
docker build \
  --file docker/pi-dev-base/Dockerfile.pi-dev-base \
  --build-arg BUILD_BASE_IMAGE=moody-ai-base:latest \
  --build-arg JAVA_SOURCE_IMAGE=eclipse-temurin:25-jdk \
  --build-arg MOODY_NODE_VERSION=22 \
  --build-arg MOODY_JAVA_VERSION=25 \
  -t platform-pi-dev-base:latest \
  .
```

### Corporate Java source

Keep `BUILD_BASE_IMAGE` as the locally built moody-ai tag. Only upstream
Java/Temurin uses the corporate registry. Fill in the blank `JAVA_SOURCE_IMAGE`
with your approved, fully qualified corporate image reference:

```dotenv
BUILD_BASE_IMAGE=moody-ai-base:latest
JAVA_SOURCE_IMAGE=<corporate-registry-host>/<namespace>/eclipse-temurin:25-jdk
```

The Java registry host/namespace above are placeholders, not a working URL.
Replace them before sourcing the file. Authenticate to the Java source registry
as required, using its actual host (and port if applicable):

```bash
docker login <corporate-registry-host>
./scripts/build_pi_dev_images.sh --corporate
```

These script examples build both base and agent images by default. Corporate mode
fails before invoking Docker if either source image is empty; it never supplies
a public Java fallback. Nonempty references are passed through as supplied:
the script does not enforce a registry allowlist.

Registry selection is **not network enforcement**. It selects the upstream Java
`FROM` image, not the local moody-ai base; package installs and downloads may still access
other hosts. Enforce corporate-only network access separately using registry,
Docker daemon, firewall, and proxy policies. This does not change npm/pip
configuration or the Compose proxy image.

## Testing the Image

Run image-selection regression checks without Docker builds or network access:

```bash
bash scripts/test_build_pi_dev_images.sh
bash scripts/test_pi_dev_env_templates.sh
```

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
