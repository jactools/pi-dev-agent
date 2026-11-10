# Plans for pi-dev-agent Docker Infrastructure

---

## Plan 1: Base pi-dev-agent on moody-ai Images

### OVERALL CONSTRAINT
**All changes must be made in the `pi-dev-agent` repository only.**
- Do NOT modify files or code in the external `moody-ai` repository
- Use build arguments, image tags, and configuration overlays to customize behavior
- Only fork/branch moody-ai images if absolutely necessary (requires asking user)

### Overview
Replace the current Debian-based `platform-pi-dev-base` with moody-ai container images to leverage their optimized runtime environment.

### Research & Assessment Phase

**Tasks:**
1. Identify available moody-ai image tags and variants
   - Check for Python, Node.js, Java base images from moody-ai
   - Review documentation on supported runtimes and versions
2. Compare current stack requirements vs moody-ai capabilities
   - Current: Debian trixie-slim + Python 3.13 + Node.js 22 + Java 25
   - Verify compatibility with moody-ai base images
3. Evaluate migration impact
   - Tooling differences (apt-get vs package managers)
   - SSL certificate handling
   - Environment variable compatibility
4. Document any breaking changes or missing features

### Implementation Phase

**Phase 1: Create moody-ai-based Base Image**

NO DEFAULTS, NO FALLBACKS - All values must come from .env.local or .env.corporate via build args.

1. Update `Dockerfile.pi-dev-base`:
   - Replace `FROM debian:trixie-slim AS base` with moody-ai image tag (from env var BUILD_BASE_IMAGE)
   - Use build arguments for ALL paths, versions, and flags (no hard-coded defaults)
   - All build args must be provided via .env files or command line
   - Preserve Python 3.13 via pyenv setup if supported by moody-ai
   - Adapt Node.js 22 and Java 25 installation to match moody-ai runtime preferences (from env vars)
   - Maintain SSL certificate handling using COPY from .env-controlled paths
   **IMPORTANT**: If additional customizations require forking/branching moody-ai images, this requires asking the user first.

**Phase 2: Test Base Image Build** (NO DEFAULTS - All from .env files)
1. Create test container with base image only using `.env.local`
2. Verify all tools are installed correctly (python3, node, npm, java, kubectl)
3. Confirm Python 3.13, Node.js 22, Java 25 versions match requirements
4. Validate SSL certificate paths from .env-controlled locations
5. Test that build fails gracefully if required env vars are missing
5. Run integration tests on base image

**Phase 3: Update Agent Image**
1. Modify `Dockerfile.pi-dev-agent`:
   - Change base image reference to moody-ai tag (from env var BUILD_BASE_IMAGE)
   - ALL build args must come from .env files or command line (NO defaults allowed)
   - Test build with new base image
2. Verify all COPY, RUN, and ENTRYPOINT commands work correctly with moody-ai runtime
3. Confirm Playwright installation still functions in moody-ai environment
4. Validate entrypoint.sh compatibility with moody-ai paths
5. Add .env.local and .env.corporate templates with required build args for both environments

**Phase 4: Integration & Documentation**
1. Update Docker documentation for moody-ai base images
2. Create migration guide from Debian to moody-ai
3. Add build cache optimization notes (moody-ai may have different caching behavior)
4. Test in staging environment before production rollout

### Risk Mitigation
- **Risk**: Python package compatibility issues
  - **Mitigation**: Maintain requirements.txt validation during base image testing
  
- **Risk**: Node.js module installation failures
  - **Mitigation**: Add fallback npm registry configuration for corporate environments
  
- **Risk**: SSL certificate path differences
  - **Mitigation**: Test with both internal and external CA bundles

### Acceptance Criteria
- [ ] Base image builds successfully from .env.local (NO defaults, NO fallbacks)
- [ ] Base image builds successfully from .env.corporate (NO defaults, NO fallbacks)
- [ ] ALL build args must be provided via environment variables or command line
- [ ] All existing tests pass in container environment with moody-ai runtime
- [ ] Python packages resolve correctly (private index for local/proxy for corporate)
- [ ] Node.js modules install correctly via npm proxy support when configured
- [ ] Java runtime functions for all agent features without modification to moody-ai repo
- [ ] Entry point scripts execute without errors in both environments
- [ ] SSL certificates work from .env-controlled paths
- [ ] Documentation includes required .env variables for both local and corporate

---

### Required .env Files for moody-ai Migration (Plan 1)

**`.env.local` template - Local development with jacloud.site:**
```
# BUILD BASE IMAGE CONFIGURATION (NO DEFAULTS, NO FALLBACKS)
BUILD_BASE_IMAGE=moody/python:latest  # Must be set explicitly
MOODY_NODE_VERSION=22
MOODY_JAVA_VERSION=25

# SSL CERTIFICATE PATH
SSL_CERT_PATH=/usr/local/share/ca-certificates/rabo.crt
```

**`.env.corporate` template - Corporate with proxy:**
```
# BUILD BASE IMAGE CONFIGURATION (NO DEFAULTS, NO FALLBACKS)
BUILD_BASE_IMAGE=moody/python:latest  # Must be set explicitly
MOODY_NODE_VERSION=22
MOODY_JAVA_VERSION=25

# PROXY CONFIGURATION
NPM_PROXY_URL=https://npm.corporate.com
PYPI_INDEX_URL=https://pypi.corporate.com/simple/
```

---

## Plan 2: Support Local Development + Corporate Proxy Environments

### Overview
Design Docker build system to automatically detect environment type (local vs corporate) and configure appropriate proxy settings for Docker, npm, and PyPI.

### Environment Constraints

**Local Development:**
- **Read-only**: Only `jacloud.site` is allowed as source
- **Exception**: Upload script can download from public registries to push packages to jacloud.site
- No corporate proxies required (uses default public registries)

**Corporate Deployment:**
- **Strict read-only**: Must ALWAYS use configured corporate proxy
- **NO public sources allowed**: Zero fallback to public PyPI/npm registries
- **No pushes allowed**: Corporate environment cannot push/upload packages

### Architecture Design

**Environment Detection Strategy:**
1. Use environment variables set at container runtime or build time
2. Create configuration files that can be mounted/overridden
3. Implement strict mode: explicit env vars → config file → defaults (no fallback to public for corporate)

### Implementation Plan

#### Phase 1: Configuration File Structure

Create templated configuration files in `docker/pi-dev-agent/config/`:
- `docker-proxy.conf` - Docker registry proxy settings (TOML format)
- `npm-proxy.conf` - NPM corporate registry settings (INI format)
- `pypi-proxy.conf` - PyPI index settings (INI format)
- `pypi-upload.conf` - Upload script exception config

All files should use placeholder values that get replaced at build time or mounted from environment-specific .env files.

### Environment Variable Reference

| Variable | Local Dev | Corporate |
|----------|-----------|------------|
| Mode flag | `--local` (required) | `--corporate` (required) |
| `NPM_PROXY_URL` | Empty string | Required |
| `PYPI_INDEX_URL` | Empty string | Required |
| `PYPI_EXTRA_INDEX_URL` | N/A | **MUST BE EMPTY** |
| `ALLOW_PUBLIC_DOWNLOADS` | `true` (upload script only) | `false` |
| `NEXUSCLOUD_*` | N/A | Required for authentication

**File: `docker/pi-dev-agent/config/npm-proxy.conf`** (template)
```
registry=https://npm.corporate.com/
//npm.corporate.com/:_authToken=REPLACE_WITH_REGISTRY_TOKEN
always-auth=true
save-exact=true
```

#### Phase 2: Build System Updates

**Update `Dockerfile.pi-dev-agent`:**

- Add build arguments for all proxy-related settings (NPM, PyPI indices)
- Implement STRICT MODE enforcement:
  - No auto-detection of environment type
  - No default values that could bypass corporate restrictions
  - Build args must be explicitly provided via command-line flags or scripts
- Add runtime validation to fail fast if corporate mode is enabled without proper proxy configuration

#### Phase 3: Local Development Docker Compose Support

Create `docker-compose.dev.yml` for local development that:
- Sets corporate mode to false
- Uses default public registries (jacloud.site only)
- Mounts local gitrepos volume
- Does not require any proxy configuration

#### Phase 5: Build Helper Scripts

Create three shell scripts:
- `build-local.sh` - Builds local development image with jacloud.site only
- `build-corporate.sh` - Builds corporate deployment image with strict proxy enforcement
- `build.sh` - Main entry point that requires exactly one mode flag (--local or --corporate), no auto-detection, no defaults
```bash
#!/bin/bash
set -e

# STRICT MODE: Exactly one flag required, no defaults, no fallbacks
MODE="${1:-}"

if [ "$MODE" != "local" ] && [ "$MODE" != "corporate" ]; then
  echo "ERROR: Must specify exactly one mode: --local or --corporate"
  echo "Usage: $0 [--local|--corporate]"
  exit 1
fi

case "$MODE" in
  local)
    ./scripts/build-local.sh
    ;;
  corporate)
    if [ -z "${NPM_PROXY_URL:-}" ] || [ -z "${PYPI_INDEX_URL:-}" ]; then
      echo "ERROR: Corporate mode requires NPM_PROXY_URL and PYPI_INDEX_URL environment variables"
      exit 1
    fi
    ./scripts/build-corporate.sh
    ;;
esac
```

#### Phase 6: NPM and PyPI Credentials Handling

**For Corporate Environment:**
1. Create `~/.npmrc` with corporate registry settings
2. Use Docker secrets or mounted config files for authentication tokens
3. Implement credential rotation mechanism
4. **NO PUBLIC ACCESS ALLOWED**: Configure .dockerignore to prevent public fallbacks at build time

**Example `.npmrc` template:**
```ini
//registry.npmjs.org/:_authToken=$NPM_TOKEN
always-auth=false
save-exact=true
engine-strict=true
```

### Environment Template Files (Create as documentation)

**`.env.local` template - Local development environment:**
```bash
# STRICT MODE: --local flag required explicitly
CORPORATE_MODE=false
NPM_PROXY_URL=
PYPI_INDEX_URL=
PYPI_EXTRA_INDEX_URL=
ALLOW_PUBLIC_DOWNLOADS=true  # Upload script exception only
```

**`.env.corporate` template - Corporate deployment environment:**
```bash
# STRICT MODE: --corporate flag required explicitly
CORPORATE_MODE=true
NPM_PROXY_URL=https://npm.corporate.com  # REQUIRED
PYPI_INDEX_URL=https://pypi.corporate.com/simple/  # REQUIRED
PYPI_EXTRA_INDEX_URL=  # MUST BE EMPTY - NO PUBLIC FALLBACKS
ALLOW_PUBLIC_DOWNLOADS=false  # PROHIBITED IN CORPORATE MODE
NEXUSCLOUD_USERNAME=
NEXUSCLOUD_PASSWORD=
```

#### Phase 7: Testing & Validation

**Test Scenarios:**
1. Local development with `--local` flag (jacloud.site only)
2. Corporate build with `--corporate` flag and proxy URLs set
3. Corporate validation that public fallbacks are blocked
4. Corporate validation that pushes/uploads fail without explicit permission
5. Verify no auto-detection occurs - must specify --local or --corporate explicitly

#### Phase 8: Documentation Updates

**Create:**
1. `README.md` sections for Local vs Corporate builds (strict mode requirements)
2. Environment variable reference guide with STRICT MODE warnings
3. Troubleshooting proxy configuration issues
4. CI/CD pipeline examples (--local and --corporate flags in GitHub Actions/GitLab CI)
5. Docker Compose example configurations
6. `.env.local` template - Local development environment variables (jacloud.site only)
7. `.env.corporate` template - Corporate deployment environment variables (mandatory proxy URLs)

### Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Build fails when corporate proxies are unreachable | Add timeout and retry logic; fail fast with clear error messages |
| Credentials exposed in images | Use Docker secrets, runtime env vars only (no .dockerignore for credentials) |
| Proxy authentication failures | Implement credential rotation mechanism; add health checks for proxy endpoints |
| Accidental public access in corporate mode | STRICT MODE enforcement - build fails if required proxy args not provided

### Acceptance Criteria

- [ ] Local development build succeeds with `--local` flag (jacloud.site only)
- [ ] Corporate build with `--corporate` flag works correctly with proxy URLs
- [ ] NPM packages resolve ONLY from corporate proxy when in corporate mode
- [ ] PyPI packages resolve ONLY from corporate proxy (NO public fallback allowed)
- [ ] Upload script exception: can download from public only in local mode
- [ ] No auto-detection - must specify --local or --corporate explicitly
- [ ] Build fails if corporate mode enabled without proper proxy configuration
- [ ] CI/CD pipeline examples provided for both environments
- [ ] Documentation covers all configuration options and troubleshooting

### Rollout Strategy

1. **Week 1**: Implement config file templates, build arguments, and STRICT MODE enforcement
2. **Week 2**: Create helper scripts (build.sh, build-local.sh, build-corporate.sh) with mode switch validation
3. **Week 3**: Test in local development environment (--local flag)
4. **Week 4**: Deploy to staging corporate environment (--corporate flag with proxy URLs)
5. **Week 5-6**: Production rollout with monitoring, rollback plan, and CI/CD integration
