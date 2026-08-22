# PI Dev Agent

Standalone repository for the local `pi-dev-agent` compose stack, images, helper scripts, and focused runtime documentation.

## Contents

- `docker-compose/pi-dev-agent.yml` — runtime stack for the agent and proxy sidecar
- `docker/pi-dev-base/` — shared base image
- `docker/pi-dev-agent/` — agent image and proxy config
- `scripts/build_pi_dev_images.sh` — local image build helper
- `scripts/pi_dev_agent.sh` — start/restart/shell/log helper
- `docs/infra/PI_DEV_AGENT_IMAGE.md` — usage and runtime notes
- `.env.pi-dev.local.example` — local env template

## Quick start

```bash
cp .env.pi-dev.local.example .env.pi-dev.local
# edit .env.pi-dev.local
./scripts/pi_dev_agent.sh start
```