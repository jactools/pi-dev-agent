#!/usr/bin/env bash
set -euo pipefail

BRUNO_VERSION="4.3.0"

npm_config_loglevel=error exec npx --yes "@usebruno/cli@${BRUNO_VERSION}" "$@"
