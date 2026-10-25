# Multi-Agent Coder Architecture

## Problem

The current `delegate_to_coder` tool calls a bare llama.cpp inference endpoint (Qwen3.8-27B) via HTTP `/v1/chat/completions`. The model generates text describing code changes, but **nothing acts on that output** — no file is ever written. The Coder has no tools, no session, no filesystem access. It's a stateless text generator wearing a system prompt.

```
┌──────────────┐         HTTP POST          ┌─────────────────┐
│  Orchestrator │ ──────────────────────────▶ │  llama.cpp      │
│  (pi agent)   │                             │  Qwen3.8-27B    │
│              │ ◀────────────────────────── │  (no tools,     │
│  receives    │       JSON text             │   no session)   │
│  text only   │                             └─────────────────┘
│  ✗ no writes │
└──────────────┘
```

## Solution: Coder as a Full Pi Agent Service

Run the Coder as its own pi coding agent process with access to the workspace filesystem and built-in tools (`read`, `edit`, `write`, `bash`). The Orchestrator communicates with it via subprocess or RPC.

```
┌───────────────────────┐                    ┌───────────────────────────┐
│   ORCHESTRATOR        │    spawn / HTTP    │   CODER (pi agent)        │
│                       │ ◀────────────────▶ │                           │
│  • pi session         │   prompt/response  │  • pi session             │
│  • model: Qwen3.6-35B│                    │  • model: Qwen3.8-27B     │
│  • tools: analyze,    │                    │  • tools: read, edit,     │
│    plan, delegate     │                    │    write, bash (full set) │
│  • NO file writes     │                    │  • HAS filesystem access  │
│                       │                    │  • Can verify its own     │
│                       │                    │    edits by re-reading    │
└───────────────────────┘                    └───────────────────────────┘
         ▲                                              │
         │                                              ▼
         │                                     ┌─────────────────┐
         └─────────────────────────────────────│  Workspace       │
                                               │  /workspace/     │
                                               │  gitrepos/       │
                                               └─────────────────┘
```

## Component Design

### 1. Coder Agent (Subprocess Mode — Phase 1)

The simplest approach: the orchestrator spawns `pi` in print mode as a child process, pointed at the local-llm model. The subprocess gets its own full pi session with all built-in tools.

```typescript
import { spawn } from "child_process";

async function delegateToCoder(taskPrompt: string, workspace: string, signal?: AbortSignal): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn("pi", [
      "--provider", "local-llm",
      "--model", "Qwen3.8-27B-UD-Q6_K_M.gguf",
      "--cwd", workspace,
      "-p", taskPrompt,       // print mode: single prompt → execute tools → output result → exit
    ], { 
      signal,
      timeout: 120_000,       // 2 min per task
    });

    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => stdout += d);
    child.stderr.on("data", (d) => stderr += d);
    
    child.on("close", (code) => {
      if (code === 0) resolve(stdout.trim());
      else reject(new Error(`Coder exited ${code}:\n${stderr || stdout}`));
    });
    child.on("error", reject);
  });
}
```

**Why this works:** In print mode (`-p`), pi:
1. Starts a session with the specified model and working directory
2. Processes the prompt through its normal agent loop
3. The model can call `read`, `edit`, `write`, `bash` tools freely
4. When the model stops calling tools, pi outputs the final text and exits

The Coder naturally: reads files → plans edits → applies them → verifies → reports done. No JSON parsing fragility.

### 2. Task Prompt Template

Since the Coder is now a full agent with tools, the prompt should be natural language instructions (not JSON):

```
Task: Remove flat field emission from ruleToWire() in the rule adapter.

Target file: /workspace/gitrepos/dq-made-easy-ui/src/api/adapters/rule-adapter.ts

Requirements:
1. In the ruleToWire() function, remove the three lines that emit 
   expression, check_type, and check_type_params as top-level wire fields.
2. Change deepSnakeCase(rule.dsl) to just rule.dsl (the DSL contract uses camelCase).
3. Do NOT modify any other functions in this file.

Constraints:
- Keep the attributes array emission unchanged
- The dsl field must still be present in the output object
```

The Coder agent will autonomously:
1. `read` the file to see current state
2. Identify the exact lines to change
3. `edit` with precise oldText/newText pairs (pi validates these)
4. Optionally `read` again to verify
5. Report completion summary

### 3. Orchestrator Extension (Revised Tool)

```typescript
pi.registerTool({
  name: "delegate_to_coder",
  description: "Delegate a coding task to the Coder agent. The Coder has full tool access and applies changes directly.",
  parameters: {
    type: "object" as const,
    properties: {
      task_description: { type: "string" as const, description: "What needs to be done" },
      files_to_modify: { type: "array" as const, items: { type: "string" as const } },
      requirements: { type: "array" as const, items: { type: "string" as const } },
      constraints: { type: "array" as const, items: { type: "string" as const } },
    },
    required: ["task_description", "files_to_modify"],
  },
  
  execute: async (_toolCallId, params, signal) => {
    const workspace = process.cwd();
    
    // Build natural language prompt (not JSON!)
    const prompt = [
      `Task: ${params.task_description}`,
      ``,
      `Target files:`,
      ...params.files_to_modify.map(f => `- ${f}`),
      ``,
      params.requirements?.length ? `Requirements:\n${params.requirements.map((r, i) => `${i+1}. ${r}`).join("\n")}` : "",
      ``,
      params.constraints?.length ? `Constraints:\n${params.constraints.map(c => `- ${c}`).join("\n")}` : "",
    ].filter(Boolean).join("\n");
    
    const result = await delegateToCoder(prompt, workspace, signal);
    
    return {
      content: [{ type: "text", text: `✅ Coder completed:\n\n${result}` }],
      details: { success: true },
    };
  },
});
```

### 4. Persistent Coder Service (Phase 2 — for concurrency)

When you need parallel delegation or lower latency, run the Coder as a long-lived service:

```yaml
# docker-compose.yml addition
services:
  coder-agent:
    image: node:22-slim
    working_dir: /workspace/gitrepos
    environment:
      - PI_PROVIDER=local-llm
      - PI_MODEL=Qwen3.8-27B-UD-Q6_K_M.gguf
      - PI_HOST=host.docker.internal
    volumes:
      - ./gitrepos:/workspace/gitrepos
    command: >
      node server.js
      # server.js exposes POST /task { prompt, cwd } → runs pi -p → returns result
    ports:
      - "8083:8083"
```

The orchestrator then POSTs to `http://coder-agent:8083/task` instead of spawning a subprocess. Same protocol, but the Coder process stays warm (no cold-start overhead per task).

## Comparison: Approaches

| Aspect | A: Parse LLM JSON + apply edits | B: Subprocess pi agent | C: Persistent service |
|--------|----------------------------------|------------------------|-----------------------|
| File access from Coder | ✗ (orchestrator applies) | ✓ (Coder has own tools) | ✓ |
| Self-verification | ✗ | ✓ (re-reads after edit) | ✓ |
| Iterative fixing | ✗ single shot | ✓ agent loop retries | ✓ |
| JSON parsing fragility | High (27B must produce valid JSON with exact oldText) | None (natural language in, tool calls out) | None |
| Multi-file coordination | Must get all edits right at once | Sequential, each verified | Sequential or parallel |
| Latency per task | ~10s (one LLM call) | ~30-60s (multiple tool round-trips) | ~25-50s (warm process) |
| Infra complexity | None | None (just child_process) | Docker service + HTTP server |
| Concurrency | N/A (orchestrator is single-threaded) | Limited by CPU (each subprocess uses RAM for model context) | Better (queue-based) |

## Implementation Plan

### Phase 1: Subprocess Coder ← **do this first**

**Changes to `multi-agent.ts`:**
- Replace the `callLlamaServer()` + JSON parsing logic in `delegate_to_coder` with a `spawn("pi", [...])` call
- Build natural language prompts instead of JSON payloads
- Parse exit code for success/failure
- Pass through stdout as the result

**Effort:** ~40 lines changed  
**Risk:** Low — pi print mode is stable  
**Prerequisite:** The `pi` binary must be in PATH inside the container (it is: `/home/app_user/.pi/agent/bin/pi`)

### Phase 2: Persistent Coder Service

- Write a small Node.js HTTP server that wraps `pi -p` calls
- Add to docker-compose
- Switch orchestrator from subprocess to HTTP POST
- Add task queue for concurrency control (max N parallel coders)

**Effort:** ~150 lines + compose entry  
**Risk:** Medium — session isolation, timeout handling

### Phase 3: Multi-Coder Fan-Out

- Orchestrator decomposes large tasks into independent subtasks
- Spawns multiple Coder subprocesses in parallel (each scoped to different files)
- Collects results, checks for file conflicts
- Reports consolidated summary

**Effort:** Significant — conflict detection, merge logic  
**Risk:** High — concurrent edits need coordination

## Security Considerations

- Coder subprocess inherits the orchestrator's filesystem permissions
- Constrain via `--cwd` to limit working directory scope
- System prompt should forbid: git operations, network calls, modifications outside target paths
- For production isolation: run Coder in a separate container with read-only bind mount except for the target repo
- The `PI_DEV_AGENT_DIRECT_ALLOW_HOSTS` env var already restricts which hosts the agent can reach

## Current Quick Fix (Applied)

Since we can't modify the root-owned extension at `/usr/local/pi-dev/extensions/multi-agent.ts`, a user-level override was placed at:

```
~/.pi/agent/extensions/multi-agent.ts
```

This uses **Approach A** (orchestrator applies edits on behalf of the Coder):
1. Reads target files via `fs.readFileSync`
2. Sends file contents + task to the bare LLM
3. Asks for JSON with exact `oldText`/`newText` pairs
4. Applies them via `ctx.executeTool("edit", ...)` / `ctx.executeTool("write", ...)`

This is less robust than Phase 1 (no self-verification, single-shot) but works without any infrastructure changes and will be auto-loaded by pi for new sessions.

## File Locations

```
~/.pi/agent/extensions/multi-agent.ts    # Quick fix (approach A, user-level override)
/usr/local/pi-dev/extensions/multi-agent.ts  # Original broken extension (root-owned)
/workspace/gitrepos/                     # Shared workspace volume
```

For the proper repo (when available):
```
pi-dev/
├── extensions/
│   └── multi-agent.ts           # Full implementation with subprocess Coder
├── prompts/
│   ├── orchestrator-system.md   
│   └── coder-task-template.md   
├── server/                      # [Phase 2]
│   └── coder-service.js         # HTTP wrapper around pi -p
└── docker-compose.yml           # [Phase 2]
```
