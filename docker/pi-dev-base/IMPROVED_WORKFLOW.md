# Improved Build Workflow

## Simplified Command-Line Usage

The build script takes exactly one source mode plus an explicit env name. No manual export statements required!

### Local Development (dev)

```bash
./scripts/build_pi_dev_images.sh --local --env dev
```

Automatically:
- Loads `.env.dev` from the repository root
- Uses moody-ai-base for local development with jacloud.site packages
- Builds both base and agent images

### Corporate Deployment (test/prod)

```bash
./scripts/build_pi_dev_images.sh --corporate --env prod
```

Automatically:
- Loads `.env.prod` from the repository root
- Uses moody-ai-base for corporate deployment with proxy configuration
- Requires fully qualified corporate `JAVA_SOURCE_IMAGE`, `BUILDKIT_SYNTAX`, and a readable `NPM_CONFIG_FILE` (no public fallback)

## No Defaults - All Values Required

All environment variables MUST be explicitly set in the .env files. No defaults allowed.

### Required Variables (Both Environments)
```bash
BUILD_BASE_IMAGE=moody-ai-base:latest   # Must be set explicitly
MOODY_NODE_VERSION=22                    # Must be set explicitly  
MOODY_JAVA_VERSION=25                    # Must be set explicitly  
SSL_CERT_PATH=/etc/ssl/certs/ca-certificates.crt  # Optional, has default
```

### Dev Environment (.env.dev)
- Uses jacloud.site for package resolution (no proxy needed)
- All required moody-ai variables must be set

### Test/Prod Environments (.env.test / .env.prod)  
- Require corporate `JAVA_SOURCE_IMAGE` and `BUILDKIT_SYNTAX` references explicitly
- No fallback to public registries allowed
- All required moody-ai variables must be set

## Build Options

```bash
# Build both images (the only build shape; image names, PI_DEV_IMAGE_TAG, and
# PI_CODING_AGENT_VERSION come from the selected env file)
./scripts/build_pi_dev_images.sh --local --env dev
./scripts/build_pi_dev_images.sh --corporate --env prod
```

## Error Handling

- **Missing mode flag**: `ERROR: Must specify --local or --corporate (no defaults allowed)`
- **Missing/invalid env name**: `ERROR: Must specify --env dev, --env test, or --env prod (no defaults allowed)` / `ERROR: --env must be one of: dev, test, prod (got '...')`
- **Missing env file**: `ERROR: Environment file not found: /path/to/.env.xxx`
- **Missing required vars**: `ERROR: BUILD_BASE_IMAGE not set in .env.xxx`

## Example Workflow

```bash
# Navigate to repository
cd /Users/jacbeekers/gitrepos/pi-dev-agent

# Local development build
./scripts/build_pi_dev_images.sh --local --env dev

# Corporate deployment (with proxy)
./scripts/build_pi_dev_images.sh --corporate --env prod
```

## Key Benefits

1. ✅ **No manual export statements needed** - Explicit env file selection via `--env`
2. ✅ **No defaults allowed** - Enforces explicit configuration at all levels  
3. ✅ **Clear error messages** - Tells user exactly what's missing
4. ✅ **Separate environments** - dev, test, and prod configs are isolated
