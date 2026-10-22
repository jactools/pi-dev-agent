# PI Dev Agent

Standalone repository for the local `pi-dev-agent` compose stack, images, helper scripts, and focused runtime documentation.

## Contents

- `docker-compose/pi-dev-agent.yml` — runtime stack for the agent and proxy sidecar
- `docker/pi-dev-base/` — shared base image
- `docker/pi-dev-agent/` — agent image and proxy config
- `scripts/build_pi_dev_images.sh` — local image build helper
- `scripts/pi_dev_agent.sh` — start/restart/shell/log helper
- `scripts/setup_multi_agent.sh` — install/verify multi-agent model config into `~/.pi`
- `scripts/pi_multi_agent.sh` — launch Pi in multi-agent mode (auto/orchestrator/coder/chat)
- `scripts/restricted_ssh.go` — host-side forced-command wrapper for limited `pidev` SSH access
- `extensions/multi-agent.ts` — multi-agent orchestrator extension
- `.agents/skills/orchestrator/` — Orchestrator agent skill (senior architect)
- `.agents/skills/coder/` — Coder agent skill (expert developer)
- `docs/architecture/MULTI_AGENT_ORCHESTRATOR.md` — multi-agent architecture design
- `docs/multi-agent/USAGE.md` — multi-agent usage guide
- `pi/agent/models.json` — model provider configuration
- `docs/infra/PI_DEV_AGENT_IMAGE.md` — usage and runtime notes
- `docs/infra/ROCM_LLAMA_CPP_INSTALL_SUMMARY.md` — host ROCm and llama.cpp HIP build troubleshooting summary
- `.env.pi-dev.local.example` — local env template

## Multi-Agent Setup

This repository includes a multi-agent orchestrator architecture with two llama.cpp servers:
- **Orchestrator** (mini-ai, Qwen3.6-35B): Plans, analyzes, and coordinates tasks
- **Coder** (debian, Qwen3.8-27B): Implements code changes with precision

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
/agent-status
```

For detailed usage instructions, see [Multi-Agent Usage Guide](docs/multi-agent/USAGE.md).

## Quick start