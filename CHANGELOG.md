# Changelog

All notable changes to the `pi-dev-agent` repository are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2026-10-22] — Multi-Agent Release

First consolidated release of the local `pi-dev-agent` stack, centered on the two-server multi-agent orchestrator/coder architecture.

### Added
- **Multi-agent orchestrator extension** (`extensions/multi-agent.ts`) exposing a virtual `local/multi-agent` model that routes between two llama.cpp servers.
- **Orchestrator skill** (`.agents/skills/orchestrator/SKILL.md`) — senior architect persona for planning, decomposition, routing, and validation.
- **Coder skill** (`.agents/skills/coder/SKILL.md`) — expert developer persona; model invocation disabled so it runs only via explicit command.
- **`scripts/setup_multi_agent.sh`** — installs/verifies the multi-agent model config into `~/.pi/agent/models.json`.
- **`scripts/pi_multi_agent.sh`** — launches Pi with the extension and skills, performs server health checks, and supports `--mode auto|orchestrator|coder|chat` and `--model <pattern>`.
- **Model provider configuration** (`pi/agent/models.json`) for two providers:
  - `mini-ai` (Orchestrator): `Qwen3.6-35B-A3B-UD-Q4_K_M.gguf`, port 1234, 200k context.
  - `debian` (Coder): four Qwen3.8-27B quantizations (`Q6_K_M`, `Q8_0`, `Q6_K_L`, `Q6_K_XL`), port 8082.
- **Chat template** (`scripts/chat_template.jinja`) and mini-ai server profile for thinking/reasoning control.
- Architecture design doc (`docs/architecture/MULTI_AGENT_ORCHESTRATOR.md`) and usage guide (`docs/multi-agent/USAGE.md`).

### Changed
- Provider naming finalized as `mini-ai` (Orchestrator) / `debian` (Coder).
- Added llama.cpp server profiles, systemd service units, and logrotate configuration.

### Fixed
- ROCm / llama.cpp HIP driver load error resolution (see `docs/infra/ROCM_LLAMA_CPP_INSTALL_SUMMARY.md`).

### Security
- Hardened host-side access via the forced-command `restricted_ssh.go` wrapper for limited `pidev` SSH access.
