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
| `BUILD_BASE_IMAGE` | moody-ai source image; required in corporate mode | Local default: `moody-ai-base:latest` |
| `JAVA_SOURCE_IMAGE` | Java source image; required in corporate mode, with no public fallback | Local default: `eclipse-temurin:25-jdk` |
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

### Corporate source images

Replace `BUILD_BASE_IMAGE` in `.env.pi-dev.corporate` with your approved, fully
qualified corporate image reference, and fill in the blank `JAVA_SOURCE_IMAGE`.
For example, the following are **placeholders**, not working registry URLs:

```dotenv
BUILD_BASE_IMAGE=<corporate-registry-host>/<namespace>/moody-ai-base:<approved-tag>
JAVA_SOURCE_IMAGE=<corporate-registry-host>/<namespace>/eclipse-temurin:25-jdk
```

Replace every placeholder before sourcing the file. Authenticate to each source
registry as required, using its actual host (and port if applicable):

```bash
docker login <corporate-registry-host>
./scripts/build_pi_dev_images.sh --corporate
```

These script examples build both base and agent images by default. Corporate mode
fails before invoking Docker if either source image is empty; it never supplies
a public Java fallback. Nonempty references are passed through as supplied:
the script does not enforce a registry allowlist.

Registry selection is **not network enforcement**. It controls the two external
`FROM` images only; Dockerfile package installs and downloads may still access
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
