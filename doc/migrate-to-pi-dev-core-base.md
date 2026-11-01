# Plan: Migrate pi-dev-agent to use pi-dev-core base image

## Current State

### pi-dev-core (source of truth for base)
- **Dockerfile.base**: `debian:trixie-slim` + Python 3.13 + Node.js 22 (verified) + build tools
- **Dockerfile.pi-dev**: On top of base — adds procps, mc, ssh-client, tree, xclip, net-tools; installs pi-coding-agent globally; creates `moody` user; bakes in extensions; config via symlinks into bind-mounted `/home/moody/pi-config`
- **User**: `moody` (uid 1000)
- **Config**: Bind mount from host (`./config:/home/moody/pi-config`) with symlinks inside `.pi/agent`

### pi-dev-agent (current, self-contained base)
- **docker/pi-dev-base/Dockerfile.pi-dev-base**: Separate base — adds Java 25 via multi-stage copy; installs kubectl; creates `app_user`; includes iptables, jq, zsh
- **Dockerfile.pi-dev-agent**: On top of its own base — installs pi-coding-agent + playwright; copies extensions & skills; sets up `.venv-test` venv
- **User**: `app_user` (no uid specified)
- **Config**: Private Docker volume (`pi-config`) — not a bind mount; entrypoint seeds models.json on first run
- **Unique features**: Strict egress via squid proxy + iptables, multi-agent mode, host SSH linking, requirements.txt auto-install

## Goal

Use `pi-dev-core`'s base image as the foundation for pi-dev-agent while preserving all current features.

---

## Differences to Reconcile

| Aspect | pi-dev-core | pi-dev-agent (keep) | Action |
|--------|-------------|---------------------|--------|
| Base OS | debian:trixie-slim | debian:trixie-slim | ✅ Same |
| Python | 3.13 via pyenv | 3.13 from python:3.13-trixie image copy | ⚠️ Different install method — core uses pyenv, agent copies from official image |
| Node.js | 22.23.2 verified tarball | `node:current-trixie` (unpinned) | ✅ Core's pinned version is better; adopt it |
| Java | ❌ Not included | ✅ Eclipse Temurin 25 | ⚠️ Must add Java to the merged base |
| kubectl | ❌ Not included | ✅ Installed in agent base | ⚠️ Must add kubectl |
| iptables | ❌ Not included | ✅ Included in agent base | ⚠️ Must add iptables (needed for egress) |
| jq, zsh | ❌ Not included | ✅ Included in agent base | ⚠️ Add these |
| User | `moody` (uid 1000) | `app_user` (no uid) | Choose one — see recommendation below |
| Config | Bind mount + symlinks | Private volume + seed on first run | Keep pi-dev-agent approach (private volume is intentional for container isolation) |

---

## Recommendations

### 1. User: keep `app_user` with explicit UID/GID
The pi-dev-agent uses a private config volume intentionally — the container's models.json resolves `${PI_HOST}` to `host.docker.internal`, which would conflict with the host's `~/.pi/agent/models.json` if bind-mounted. The `app_user` naming is fine; just add an explicit uid/gid (1000) for consistency.

### 2. Base image: merge both, prefer pi-dev-core's approach
Create a new merged base that:
- Uses pi-dev-core's **pinned** Node.js installation (verified checksums)
- Adds Java 25 from the official Eclipse Temurin image (multi-stage copy)
- Adds kubectl, iptables, jq, zsh (from agent's current base)
- Keeps Python 3.13 — prefer pi-dev-core's pyenv approach for flexibility

### 3. Extensions & skills: keep as-is
Both projects use the same `pi-coding-agent` npm package. The extensions (`multi-agent.ts`, `test-tool.ts`) and skills (`.agents/skills/`) are pi-dev-agent specific and stay in the image.

---

## Implementation Steps

### Step 1: Create merged base Dockerfile
**File**: `docker/pi-dev-base/Dockerfile.pi-dev-base` (rewrite)

```
FROM debian:trixie-slim AS base

# System packages: merge both sets
# From core: bash, curl, ca-certificates, gnupg, git, nano, vim-tiny, wget, gpgv, xz-utils, ripgrep, fd-find
# From agent: iptables, jq, zsh, build-essential (already in core via apt)
# Add: libicu-dev (for Node.js Unicode), kubectl

# Python 3.13 — use pi-dev-core's pyenv approach
# Node.js 22.23.2 — use pi-dev-core's verified tarball approach  
# Java 25 — copy from eclipse-temurin:25-jdk (multi-stage)

# Create app_user with uid/gid 1000
# Set up /workspace, .pi, .ssh directories
```

### Step 2: Update Dockerfile.pi-dev-agent
**File**: `docker/pi-dev-agent/Dockerfile.pi-dev-agent`

- Change `ARG BASE_IMAGE` to reference the new merged base (same image name, just rebuilt)
- Keep all existing layers: playwright install, extensions copy, skills copy, .venv-test setup
- The entrypoint seeding of models.json stays unchanged

### Step 3: Update docker-compose/pi-dev-agent.yml
**File**: `docker-compose/pi-dev-agent.yml`

- No changes needed — the compose file references `${PI_DEV_BASE_IMAGE_NAME}` which defaults to `platform-pi-dev-base`. After rebuilding, it'll use the new merged base.

### Step 4: Update build script
**File**: `scripts/build_pi_dev_images.sh`

- No changes needed — already builds both images in sequence with proper args.

### Step 5: Clean up pi-dev-core references (optional)
If pi-dev-agent no longer needs its own separate base, consider whether the `docker/pi-dev-base/` directory can be simplified or if it should remain as a standalone buildable unit for CI purposes.

---

## Feature Preservation Checklist

| Feature | Status | Notes |
|---------|--------|-------|
| Strict egress (iptables + squid) | ✅ Preserved | iptables added to merged base; proxy setup in entrypoint unchanged |
| Multi-agent mode | ✅ Preserved | Extensions & skills baked into image; wrapper script unchanged |
| Host SSH linking | ✅ Preserved | Entrypoint SSH logic unchanged |
| Private config volume | ✅ Preserved | No bind mount — models.json seeded on first run |
| Playwright + Chromium | ✅ Preserved | Dockerfile layer unchanged |
| .venv-test with jacloud.nl pip | ✅ Preserved | Dockerfile layer unchanged |
| requirements.txt auto-install | ✅ Preserved | Entrypoint function unchanged |
| pi-wrapper.sh (auto-load extensions) | ✅ Preserved | Copied into image, unchanged |
| Container models.json seeding | ✅ Preserved | Entrypoint logic unchanged |

---

## Risks & Mitigations

1. **Image size increase**: Adding Java + kubectl + extra tools will make the base ~200-300MB larger. Acceptable for a dev environment.
2. **Python version mismatch**: If anything depends on the specific pyenv-installed Python, verify compatibility with the official image copy approach. Consider keeping pyenv if build-time flexibility is needed.
3. **Node.js unpinned in current agent base**: The current `node:current-trixie` is a moving target — migrating to pi-dev-core's pinned version is actually a fix.

---

## Order of Operations

1. ✅ Create the merged `Dockerfile.pi-dev-base`
2. ✅ Update `Dockerfile.pi-dev-agent` (stages settings.json template)
3. ✅ Update `entrypoint.sh` (seeds settings.json on first run)
4. ✅ Set `tuiMode: "regular"` in both projects
5. ⏳ Rebuild both images: `scripts/build_pi_dev_images.sh --image all`
6. ⏳ Test the container: `scripts/pi_dev_agent.sh start`
7. ⏳ Verify all features work (multi-agent, SSH, egress, playwright, etc.)
8. ⏳ Update `.env.pi-dev.local.example` if any new build args are needed
