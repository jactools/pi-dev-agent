# PI Dev Agent

Standalone repository for the local `pi-dev-agent` compose stack, images, helper scripts, and focused runtime documentation.

## Contents

- `docker-compose/pi-dev-agent.yml` — runtime stack for the agent and proxy sidecar
- `docker/pi-dev-base/` — shared base image
- `docker/pi-dev-agent/` — agent image and proxy config
- `scripts/build_pi_dev_images.sh` — local image build helper
- `scripts/bruno.sh` — pinned Bruno CLI wrapper (`@usebruno/cli@4.3.0`)
- `scripts/pi_dev_agent.sh` — build/start/restart/shell/log helper
- `scripts/restricted_ssh.go` — host-side forced-command wrapper for limited `pidev` SSH access
- `.agents/skills/orchestrator/` — Orchestrator agent skill (senior architect)
- `.agents/skills/coder/` — Coder agent skill (expert developer)
- `.agents/skills/github-project-backlog/` — GitHub Projects v2 backlog manager (create/update/archive, whitelisted projects & repos)
- `.agents/skills/wekan-backlog/` — WeKan board card manager (create/update/move/archive, whitelisted boards & lists)
- `pi/agent/models.json` — model provider configuration
- `docs/infra/PI_DEV_AGENT_IMAGE.md` — usage and runtime notes
- `docs/infra/BUILD_ENV_CLI_LESSONS_LEARNED.md` — retrospective on the build/env CLI simplification
- `docs/infra/ROCM_LLAMA_CPP_INSTALL_SUMMARY.md` — host ROCm and llama.cpp HIP build troubleshooting summary
- `.env.dev.example`, `.env.test.example`, `.env.prod.example` — env templates for the `--env dev|test|prod` selection (test/prod require explicit corporate Java source and Dockerfile frontend)

For template differences, env-file startup selection, npmrc build secrets, and the
unsupported pip host config path, see [environment setup](docs/infra/PI_DEV_AGENT_IMAGE.md#environment-templates).

In both modes, build moody-ai separately from its local sources using that
project's own build instructions, then load/tag it locally as
`BUILD_BASE_IMAGE=moody-ai-base:latest` before building pi-dev images.
Do not fetch moody-ai from a registry. Upstream Java/Temurin and the Dockerfile
frontend use the corporate registry: set `JAVA_SOURCE_IMAGE` and `BUILDKIT_SYNTAX`
to their fully qualified corporate references for corporate builds.
Corporate agent builds use `proxy/npmrc` when present, otherwise a readable
`NPM_CONFIG_FILE`; the selected config is a BuildKit secret and a read-only
runtime secret for Pi package installs. Runtime Python installs similarly prefer
`proxy/pip.conf` over `PIP_CONFIG_FILE`.
Direct Docker/Compose builds also need the corporate frontend override; see
[build usage](docs/infra/PI_DEV_AGENT_IMAGE.md#direct-docker-and-compose-builds) and
[builder visibility requirements](docker/pi-dev-base/README.md#local-moody-ai-prerequisite).

## Quick start