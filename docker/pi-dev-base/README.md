# pi-dev Base Image (moody-ai based)

This Dockerfile builds the `platform-pi-dev-base` image using moody-ai as the base runtime.

## Requirements

All build arguments MUST be provided via `.env.local` or `.env.corporate` files:

### Required Build Arguments

| Variable | Description | Example |
|----------|-------------|---------|
| `BUILD_BASE_IMAGE` | Base image from moody-ai | `moody-ai-base:latest` |
| `MOODY_NODE_VERSION` | Node.js version to use | `22` |
| `MOODY_JAVA_VERSION` | Java version to use (Temurin) | `25` |

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
# Using environment variables from .env.local
export $(cat .env.pi-dev.local | grep -v '^#' | xargs)
./scripts/build_pi_dev_images.sh --image base

# Or specify build args directly
docker build \
  --file docker/pi-dev-base/Dockerfile.pi-dev-base \
  --build-arg BUILD_BASE_IMAGE=moody-ai-base:latest \
  --build-arg MOODY_NODE_VERSION=22 \
  --build-arg MOODY_JAVA_VERSION=25 \
  -t platform-pi-dev-base:latest \
  .
```

## Testing the Image

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
Stage 1 (base): moody-ai-base:latest
   └─> Adds system packages + Python/pyenv
   
Stage 2 (java_runtime): base
   └─> Installs ca-certificates
   
Stage 3 (java_source): eclipse-temurin:25-jdk
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
