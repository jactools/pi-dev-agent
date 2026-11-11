# PI Dev Agent

Standalone repository for the local `pi-dev-agent` compose stack, images, helper scripts, and focused runtime documentation.

## Contents

- `docker-compose/pi-dev-agent.yml` — runtime stack for the agent and proxy sidecar
- `docker/pi-dev-base/` — shared base image
- `docker/pi-dev-agent/` — agent image and proxy config
- `scripts/build_pi_dev_images.sh` — local image build helper
- `scripts/bruno.sh` — pinned Bruno CLI wrapper (`@usebruno/cli@4.3.0`)
- `scripts/pi_dev_agent.sh` — start/restart/shell/log helper
- `scripts/setup_multi_agent.sh` — install/verify multi-agent model config into `~/.pi`
- `scripts/pi_multi_agent.sh` — launch Pi in multi-agent mode (auto/orchestrator/coder/chat)
- `scripts/restricted_ssh.go` — host-side forced-command wrapper for limited `pidev` SSH access
- `extensions/multi-agent.ts` — multi-agent orchestrator extension
- `.agents/skills/orchestrator/` — Orchestrator agent skill (senior architect)
- `.agents/skills/coder/` — Coder agent skill (expert developer)
- `.agents/skills/github-project-backlog/` — GitHub Projects v2 backlog manager (create/update/archive, whitelisted projects & repos)
- `.agents/skills/wekan-backlog/` — WeKan board card manager (create/update/move/archive, whitelisted boards & lists)
- `docs/architecture/MULTI_AGENT_ORCHESTRATOR.md` — multi-agent architecture design
- `docs/multi-agent/USAGE.md` — multi-agent usage guide
- `pi/agent/models.json` — model provider configuration
- `docs/infra/PI_DEV_AGENT_IMAGE.md` — usage and runtime notes
- `docs/infra/ROCM_LLAMA_CPP_INSTALL_SUMMARY.md` — host ROCm and llama.cpp HIP build troubleshooting summary
- `.env.pi-dev.local.example` — local env template
- `.env.pi-dev.corporate.example` — matching corporate build/runtime template (explicit Java source and Dockerfile frontend required)

For template differences, env-file startup selection, npmrc build secrets, and the
unsupported pip host config path, see [environment setup](docs/infra/PI_DEV_AGENT_IMAGE.md#environment-templates).

In both modes, build moody-ai separately from its local sources using that
project's own build instructions, then load/tag it locally as
`BUILD_BASE_IMAGE=moody-ai-base:latest` before building pi-dev images.
Do not fetch moody-ai from a registry. Upstream Java/Temurin and the Dockerfile
frontend use the corporate registry: set `JAVA_SOURCE_IMAGE` and `BUILDKIT_SYNTAX`
to their fully qualified corporate references for corporate builds.
Corporate agent builds also require a readable `NPM_CONFIG_FILE`; it is passed
only as a BuildKit secret for npm/npx installs, never as a runtime mount.
Direct Docker/Compose builds also need the corporate frontend override; see
[build usage](docs/infra/PI_DEV_AGENT_IMAGE.md#direct-docker-and-compose-builds) and
[builder visibility requirements](docker/pi-dev-base/README.md#local-moody-ai-prerequisite).

## Multi-Agent Setup

This repository includes a multi-agent orchestrator architecture with three llama.cpp servers:
- **Orchestrator** (mini-ai, port 1234, Qwen3-8B-Instruct-Q4_K_M.gguf): Plans, analyzes, and coordinates tasks within the low-memory M4-safe profile
- **Coder** (local-llm, port 8082, Qwen3.8-27B): Implements code changes with precision
- **Vision** (mini-ai, port 8083, Qwen3-VL-8B-Instruct-Q4_K_M.gguf): Image analysis — auto-routed when messages contain images

### Quick Start Multi-Agent

```bash
# 1. Ensure both llama.cpp servers are running
./scripts/pi_dev_agent.sh start

# 2. Install/verify the multi-agent model config into ~/.pi
./scripts/setup_multi_agent.sh

# 3. Start Pi in multi-agent mode (automatic routing by default)
./scripts/pi_multi_agent.sh
#    ...or pin a specific agent:
./scripts/pi_multi_agent.sh --mode orchestrator   # planning/analysis
./scripts/pi_multi_agent.sh --mode coder          # implementation

# 4. Check server status from inside Pi
/agent-status   # shows all three servers
/vision         # switch to Vision mode for image analysis
```

For detailed usage instructions, see [Multi-Agent Usage Guide](docs/multi-agent/USAGE.md).

## Quick start