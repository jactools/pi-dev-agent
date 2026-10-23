# Multi-Agent Setup Usage Guide

This guide explains how to use the multi-agent orchestrator setup with Pi.

## Quick Start

### 0. Set the Host Variable (host only)

Before running Pi on the **host machine**, export `PI_HOST=localhost` so that
the multi-agent model configuration resolves correctly:

```bash
export PI_HOST=localhost   # add to ~/.zshrc or ~/.bashrc for permanence
```

When running inside the container, this is set automatically by
docker-compose (`PI_HOST=host.docker.internal`). No action needed there.

### 1. Install Skills

Copy the skills to your Pi skills directory:

```bash
# For user-wide skills (available in all projects)
cp -r .agents/skills/orchestrator ~/.agents/skills/
cp -r .agents/skills/coder ~/.agents/skills/

# OR for project-specific skills (in this repo)
# Skills are already in .agents/skills/orchestrator and .agents/skills/coder
```

### 2. Configure Model Providers

Install or verify the multi-agent model configuration in `~/.pi`:

```bash
./scripts/setup_multi_agent.sh
```

This copies `pi/agent/models.json` to `~/.pi/agent/models.json` if it does not exist, and verifies that both the `mini-ai` (Orchestrator) and `debian` (Coder) providers are present.

### 3. Launch Pi

Use the launcher script (recommended):

```bash
# Automatic routing between agents (default)
./scripts/pi_multi_agent.sh

# Or start in a specific mode
./scripts/pi_multi_agent.sh --mode orchestrator   # planning/analysis
./scripts/pi_multi_agent.sh --mode coder          # implementation
./scripts/pi_multi_agent.sh --model "debian/Qwen3.8-27B-Q8_0.gguf"  # override model
```

Or start Pi manually with the extension and skills:

```bash
pi --extension ./extensions/multi-agent.ts \
   --skill ./.agents/skills/orchestrator \
   --skill ./.agents/skills/coder
```

### 4. Verify Setup

Check that both agent servers are running:

```bash
/agent-status
```

Expected output:
```
Agent Server Status:

🟢 Orchestrator (mini-ai): ONLINE
   Model: Qwen3.6-35B-A3B-UD-Q4_K_M.gguf
   URL: http://localhost:1234

🟢 Coder (debian): ONLINE
   Model: Qwen3.8-27B-UD-Q6_K_M.gguf
   URL: http://localhost:8082
```

## Usage Modes

### Mode 1: Automatic Routing (Recommended)

Start multi-agent mode with automatic task routing:

```bash
/multi-agent
```

Pi will automatically route:
- **Planning/analysis tasks** → Orchestrator (mini-ai, high thinking level)
- **Coding tasks** → Coder (debian, low thinking level)

Just describe what you want to do, and Pi will choose the right agent.

### Mode 2: Manual Control

Switch between agents manually:

```bash
/orchestrator  # Switch to Orchestrator for planning
/coder         # Switch to Coder for coding
```

### Mode 3: Explicit Tool Usage

Use tools to explicitly control the workflow:

```python
# Analyze a request
/analyze_request user_message="Add input validation to login endpoint"

# Delegate to coder
/delegate_to_coder \
  task_description="Add email and password validation" \
  files_to_modify='["src/auth/login.py"]' \
  requirements='["Validate email format", "Check password strength"]' \
  constraints='["Maintain backward compatibility"]'

# Validate output
/validate_code_output \
  code_changes="<coder's response>" \
  original_requirements="Add input validation" \
  files_affected='["src/auth/login.py"]'
```

## Available Commands

| Command | Description |
|---------|-------------|
| `/multi-agent` | Start automatic routing mode |
| `/orchestrator` | Switch to Orchestrator (mini-ai) |
| `/coder` | Switch to Coder (debian) |
| `/agent-status` | Check server status |
| `/multi-agent-config` | Show full multi-agent configuration (URLs, models, routing) |

## Available Tools

| Tool | Description | When to Use |
|------|-------------|-------------|
| `delegate_to_coder` | Send coding task to debian server | When you need code changes |
| `validate_code_output` | Review code from Coder | After receiving code changes |
| `analyze_request` | Analyze user request complexity | At start of complex tasks |

## Available Skills

### Orchestrator Skill
```bash
/skill:orchestrator
```

Provides instructions for the senior architect role. Automatically loaded when Pi detects planning/coordination tasks.

### Coder Skill
```bash
/skill:coder
```

Provides instructions for the expert developer role. Only loads via explicit command (disabled auto-invocation).

## Workflow Examples

### Example 1: Simple Code Change

**User**: "Add input validation to the login endpoint"

**What happens:**
1. Pi detects this is a coding task
2. Routes to Coder (debian) automatically
3. Coder implements the changes
4. Returns code to user

### Example 2: Complex Refactoring

**User**: "Refactor the authentication module to use JWT tokens instead of sessions"

**What happens:**
1. Pi routes to Orchestrator (mini-ai) for analysis
2. Orchestrator decomposes into subtasks:
   - Analyze current auth implementation
   - Design JWT integration
   - Update login endpoint
   - Update middleware
   - Update tests
3. Each subtask routed to Coder sequentially
4. Orchestrator validates each phase
5. Returns complete solution

### Example 3: Manual Control

**User**: "/orchestrator"

Then describe the task for planning, then:

```python
/delegate_to_coder \
  task_description="Implement JWT token generation" \
  files_to_modify='["src/auth/jwt.py"]' \
  requirements=['"Generate signed JWT tokens"', '"Include expiration"']
```

## Troubleshooting

### Server Not Responding

If you see connection errors:

1. Check if llama.cpp servers are running:
   ```bash
   # For mini-ai (port 1234)
   curl http://localhost:1234/v1/chat/completions
   
   # For debian (port 8082)
   curl http://localhost:8082/v1/chat/completions
   ```

2. Restart the servers if needed:
   ```bash
   ./scripts/pi_dev_agent.sh restart
   ```

### Model Not Found

If Pi reports a model isn't found:

1. Verify models.json has the correct configuration:
   ```bash
   cat pi/agent/models.json | jq '.providers'
   ```

2. Reload Pi configuration:
   ```bash
   /reload
   ```

### Extension Not Loading

If the extension fails to load:

1. Check for TypeScript errors:
   ```bash
   # Test the extension file
   npx tsc --noEmit extensions/multi-agent.ts
   ```

2. Check Pi logs:
   ```bash
   # Look for extension loading errors
   pi 2>&1 | grep -i "multi-agent\|extension"
   ```

## Advanced Configuration

### Adjusting Model Parameters

Edit `extensions/multi-agent.ts` and modify the `CONFIG` object:

```typescript
const CONFIG = {
  orchestrator: {
    // ... existing config
  },
  coder: {
    // ... existing config
  },
  maxRetries: 3,           // Increase retry attempts
  taskTimeoutMs: 600000,   // 10 minute timeout
};
```

### Selecting a Coder Model

The `debian` provider ships with several Qwen3.8-27B quantizations in `pi/agent/models.json`:

| Model | Context Window | Notes |
|-------|---------------|-------|
| `Qwen3.8-27B-UD-Q6_K_M.gguf` | 100k | Default Coder model (balanced) |
| `Qwen3.8-27B-Q8_0.gguf` | 120k | Higher precision, larger file |
| `Qwen3.8-27B-UD-Q6_K_L.gguf` | 160k | Larger context variant |
| `Qwen3.8-27B-UD-Q6_K_XL.gguf` | 160k | Largest context variant |

Select one at launch time without editing files:

```bash
./scripts/pi_multi_agent.sh --model "debian/Qwen3.8-27B-Q8_0.gguf"
```

To add a new model, append it to the `debian` provider's `models` array in `pi/agent/models.json`, then re-run `./scripts/setup_multi_agent.sh`.

### Custom Routing Logic

Modify the `route()` function in the virtual model registration to implement custom routing logic based on your needs.

## Next Steps

1. **Test with simple tasks** - Start with straightforward coding requests
2. **Try complex refactoring** - Test the full orchestration workflow
3. **Customize prompts** - Adjust persona prompts in `extensions/multi-agent.ts`
4. **Add more skills** - Create additional skills for specialized tasks
5. **Monitor performance** - Track token usage and response times

## Support

For issues or questions:
1. Check the [Architecture Design Doc](../architecture/MULTI_AGENT_ORCHESTRATOR.md)
2. Review Pi documentation at `~/.pi/agent/install/releases/1.4.0/node_modules/@earendil-works/pi-coding-agent/docs/`
3. Check extension logs in Pi's output
