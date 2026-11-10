# Improved Build Workflow

## Simplified Command-Line Usage

The build script now automatically detects which environment file to use based on the mode flag. No manual export statements required!

### Local Development

```bash
./scripts/build_pi_dev_images.sh --local
```

Automatically:
- Loads `.env.pi-dev.local` 
- Uses moody-ai-base for local development with jacloud.site packages
- Builds both base and agent images (unless `--image base|agent` specified)

### Corporate Deployment

```bash
./scripts/build_pi_dev_images.sh --corporate
```

Automatically:
- Loads `.env.pi-dev.corporate`
- Uses moody-ai-base for corporate deployment with proxy configuration  
- Enforces required proxy URLs (NPM_PROXY_URL, PYPI_INDEX_URL)

## No Defaults - All Values Required

All environment variables MUST be explicitly set in the .env files. No defaults allowed.

### Required Variables (Both Environments)
```bash
BUILD_BASE_IMAGE=moody-ai-base:latest   # Must be set explicitly
MOODY_NODE_VERSION=22                    # Must be set explicitly  
MOODY_JAVA_VERSION=25                    # Must be set explicitly
SSL_CERT_PATH=/etc/ssl/certs/ca-certificates.crt  # Optional, has default
```

### Local Environment (.env.pi-dev.local)
- Uses jacloud.site for package resolution (no proxy needed)
- All required moody-ai variables must be set

### Corporate Environment (.env.pi-dev.corporate)  
- Requires NPM_PROXY_URL and PYPI_INDEX_URL to be set explicitly
- No fallback to public registries allowed
- All required moody-ai variables must be set

## Build Options

```bash
# Build both images (default)
./scripts/build_pi_dev_images.sh --local

# Build only base image
./scripts/build_pi_dev_images.sh --local --image base

# Build only agent image  
./scripts/build_pi_dev_images.sh --local --image agent

# Custom tag
./scripts/build_pi_dev_images.sh --local --tag v1.0.0

# Agent version override
./scripts/build_pi_dev_images.sh --local --agent-version 2.3.0
```

## Error Handling

- **Missing mode flag**: `ERROR: Must specify --local or --corporate (no defaults allowed)`
- **Missing env file**: `ERROR: Environment file not found: /path/to/.env.xxx`
- **Missing required vars**: `ERROR: BUILD_BASE_IMAGE not set in .env.xxx`

## Example Workflow

```bash
# Navigate to repository
cd /Users/jacbeekers/gitrepos/pi-dev-agent

# Local development build
./scripts/build_pi_dev_images.sh --local

# Corporate deployment (with proxy)
export NPM_PROXY_URL=https://npm.corporate.com
export PYPI_INDEX_URL=https://pypi.corporate.com/simple/
./scripts/build_pi_dev_images.sh --corporate
```

## Key Benefits

1. ✅ **No manual export statements needed** - Automatic env file detection
2. ✅ **No defaults allowed** - Enforces explicit configuration at all levels  
3. ✅ **Clear error messages** - Tells user exactly what's missing
4. ✅ **Separate environments** - Local and corporate configs are isolated
