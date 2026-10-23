#!/bin/bash
PI_DEV_DIR="/usr/local/pi-dev"
EXTENSION_PATH="$PI_DEV_DIR/extensions/multi-agent.ts"
SKILLS_PATH="$PI_DEV_DIR/.agents/skills"

# Auto-load multi-agent extension and skills when pi is invoked
if [[ -f "$EXTENSION_PATH" ]]; then
    SKILL_ARGS=""
    if [[ -d "$SKILLS_PATH" ]]; then
        while IFS= read -r -d '' skill_dir; do
            SKILL_ARGS="$SKILL_ARGS --skill $skill_dir"
        done < <(find "$SKILLS_PATH" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    fi
    exec /usr/local/bin/pi --extension "$EXTENSION_PATH" $SKILL_ARGS "$@"
else
    exec /usr/local/bin/pi "$@"
fi
