# Multi-Agent Orchestrator Architecture

**Last Updated**: 2026-10-22

## Overview

This document describes the architecture for a two-server multi-agent system where:
- **Orchestrator** (mini-ai server): Analyzes requests, plans solutions, routes tasks, and validates outputs
- **Coder** (debian server): Implements code changes with precision and quality

Both servers run llama.cpp with OpenAI-compatible APIs.

## Server Configuration

| Server | Model | Role | Port | Quantization |
|--------|-------|------|------|--------------|
| mini-ai | Qwen3.6-35B-A3B-UD-Q4_K_M.gguf | Orchestrator | 1234 | Q4 (lower precision) |
| debian | Qwen3.8-27B-UD-Q6_K_M.gguf | Coder | 8082 | Q6 (higher precision) |

**Rationale**: The larger 35B model on mini-ai provides better reasoning capabilities for planning and task decomposition, even at lower quantization. The newer Qwen3.8 architecture with Q6 quantization on debian delivers higher quality code output despite fewer parameters.

## Agent Personas

### Orchestrator Persona (mini-ai)

```yaml
name: "Senior Architect"
model: "Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"
server: "mini-ai"
port: 1234

responsibilities:
  - Analyze user requests to understand intent and requirements
  - Decompose complex tasks into manageable subtasks
  - Route coding tasks to the Coder (debian server)
  - Validate all outputs before returning to the user
  - Handle errors gracefully with retry or escalation strategies

skills:
  - analyze_request: Parse user input, identify goals, constraints, and success criteria
  - decompose_task: Break complex work into sequential/parallel subtasks
  - route_to_coder: Format coding tasks with clear context and requirements
  - validate_output: Review code changes for correctness, style, completeness
  - handle_error: Diagnose failures, decide retry vs escalate

constraints:
  - NEVER execute git commands directly
  - ALWAYS validate before returning results to user
  - Maintain conversation context across multiple interactions
  - Prefer minimal, focused changes over broad rewrites
```

### Coder Persona (debian)

```yaml
name: "Expert Developer"
model: "Qwen3.8-27B-UD-Q6_K_M.gguf"
server: "debian"
port: 8082

responsibilities:
  - Implement code modifications based on detailed specifications from the Orchestrator
  - Write clean, maintainable code following project conventions
  - Execute tests to verify correctness
  - Refactor existing code when requested

skills:
  - read_file: Analyze existing code structure, patterns, and dependencies
  - generate_code: Create new or modified code matching specifications
  - run_tests: Execute test suites and analyze results
  - refactor: Improve code quality without changing external behavior

constraints:
  - NEVER execute git commands (commit, push, branch, etc.)
  - ALWAYS follow existing code style and patterns in the repository
  - Include necessary imports and dependencies
  - Write self-documenting code with clear variable/function names
  - Handle edge cases and error conditions
```

## Skill Registry

### File Structure

The agent personas ship as Pi skills under `.agents/skills/`, and the routing logic lives in a single extension:

```
pi-dev-agent/
├── docs/
│   └── architecture/
│       └── MULTI_AGENT_ORCHESTRATOR.md  # This document
├── extensions/
│   └── multi-agent.ts                   # Virtual model + routing between servers
├── .agents/
│   └── skills/
│       ├── orchestrator/
│       │   └── SKILL.md                 # Senior Architect persona (mini-ai)
│       └── coder/
│           └── SKILL.md                 # Expert Developer persona (debian)
├── scripts/
│   ├── setup_multi_agent.sh             # Install/verify model config into ~/.pi
│   └── pi_multi_agent.sh                # Launch Pi in multi-agent mode
└── pi/
    └── agent/
        └── models.json                  # mini-ai + debian provider definitions
```

Each skill is a single `SKILL.md` with YAML frontmatter (`name`, `description`) followed by the persona prompt. The Coder skill sets `disable-model-invocation: true` so it runs only via explicit command, while the Orchestrator skill can be auto-invoked for planning/coordination tasks.

### Skill Definitions

#### Orchestrator Skills

| Skill ID | Name | Complexity | Estimated Tokens | Prerequisites |
|----------|------|------------|------------------|---------------|
| `analyze_request` | Analyze User Request | Medium | 500 | None |
| `decompose_task` | Decompose Task | High | 800 | analyze_request |
| `route_to_coder` | Route to Coder | Low | 300 | decompose_task |
| `validate_output` | Validate Output | High | 1000 | route_to_coder |
| `handle_error` | Handle Error | Medium | 400 | None |

#### Coder Skills

| Skill ID | Name | Complexity | Estimated Tokens | Prerequisites |
|----------|------|------------|------------------|---------------|
| `read_file` | Read and Analyze File | Low | 600 | None |
| `generate_code` | Generate Code | High | 1500 | read_file |
| `run_tests` | Run Test Suites | Medium | 400 | generate_code |
| `refactor` | Refactor Code | High | 1200 | read_file |

### Registry Schema

Each skill in the registry includes:
- `id`: Unique identifier
- `name`: Human-readable name
- `description`: What the skill does
- `complexity`: Low/Medium/High
- `estimated_tokens`: Approximate token usage
- `prerequisites`: Skills that must complete first
- `output_schema`: JSON schema for structured output
- `error_handling`: How to handle common failures

The skill definitions above are realized as the two Pi skills under `.agents/skills/`; there is no separate registry file in this release.

## Communication Protocol

### Overview

Both servers expose OpenAI-compatible APIs via llama.cpp. Communication happens via HTTP REST calls using the `/v1/chat/completions` endpoint.

### Request Format

```json
{
  "model": "<model_id>",
  "messages": [
    {"role": "system", "content": "<persona_prompt>"},
    {"role": "user", "content": "<task_description>"}
  ],
  "temperature": 0.3,
  "max_tokens": 4096,
  "response_format": {
    "type": "json_schema",
    "schema": "<skill_output_schema>"
  }
}
```

### Response Handling

- Orchestrator expects JSON responses from Coder
- Coder expects JSON-formatted tasks from Orchestrator
- Both use structured output for predictable parsing
- Errors are returned as JSON with error codes and messages

### Example: Task Delegation

**Orchestrator sends task to Coder:**

```python
import requests

coder_request = {
    "task_id": "task_001",
    "description": "Add input validation to login endpoint",
    "context": {
        "files_to_modify": ["src/auth/login.py"],
        "existing_code": open("src/auth/login.py").read(),
        "constraints": ["maintain backward compatibility"]
    },
    "requirements": {
        "must_do": ["validate email format", "check password strength"],
        "style_guide": "Use existing validation patterns"
    }
}

response = requests.post(
    "http://debian:8082/v1/chat/completions",
    json={
        "model": "Qwen3.8-27B-UD-Q6_K_M.gguf",
        "messages": [
            {"role": "system", "content": coder_prompt},
            {"role": "user", "content": json.dumps(coder_request)}
        ],
        "temperature": 0.2,
        "max_tokens": 4096
    }
)

coder_output = response.json()
```

### Error Response Format

```json
{
  "status": "error",
  "error_code": "VALIDATION_FAILED",
  "message": "Missing error handling in login endpoint",
  "retry_suggested": true,
  "feedback": "Add try/except blocks around database operations"
}
```

## Task Routing Logic

### Decision Flow

```
User Request Received
        │
        ▼
┌──────────────────┐
│ analyze_request  │
└────────┬─────────┘
         │
         ▼
    Complexity Score?
    ┌────────┴────────┐
    │                 │
1-3 (Simple)     4-10 (Complex)
    │                 │
    ▼                 ▼
Direct to        decompose_task
Coder            │
    │             ▼
    │      Multiple Subtasks?
    │      ┌────┴────┐
    │      │         │
    │     Yes       No
    │      │         │
    │      ▼         ▼
    │   Route each  Route to
    │   sequentially Coder
    │   or parallel
    │      │         │
    │      └────┬────┘
    │             │
    ▼             ▼
Validate ←── validate_output
    │
    ▼
Pass? ──No──▶ handle_error
    │              │
   Yes             │
    │              │
    ▼              │
Return to User ◀───┘
```

### Routing Rules

| Condition | Action |
|-----------|--------|
| Simple task (complexity 1-3) | Direct to Coder with minimal context |
| Complex task (complexity 4-10) | Decompose → Route subtasks |
| Subtasks independent | Parallel execution on Coder |
| Subtasks dependent | Sequential execution |
| Coder returns error | Retry once with feedback |
| Second failure | Escalate to user with details |
| Validation fails | Send back to Coder with revision notes |
| Max retries exceeded | Abort and notify user |

### State Management

```python
class TaskState:
    def __init__(self, task_id):
        self.task_id = task_id
        self.status = "pending"  # pending → analyzing → planning → executing → validating → complete/error
        self.attempts = 0
        self.max_retries = 2
        self.context = {}
        self.output = None
        
    def can_retry(self):
        return self.attempts < self.max_retries and self.status != "complete"
```

## Security Constraints

### Git Access Policy

**NEITHER agent is allowed to execute git commands.** This is enforced per AGENTS.md in all repositories.

- Orchestrator: Cannot run `git commit`, `git push`, `git branch`, etc.
- Coder: Cannot run `git commit`, `git push`, `git branch`, etc.

Git operations must be performed manually by the human user or through separate automation tools outside the agent system.

### Other Constraints

- Agents should not access sensitive environment variables or credentials
- File operations are limited to repository directories
- Network requests from agents should be logged and audited
- All agent actions should be logged for audit purposes

## Implementation Phases

### Phase 1: Foundation (Done)
- [x] Define persona prompts (this document + `.agents/skills/`)
- [x] Design skill structure (Pi skills under `.agents/skills/`)
- [x] Plan communication protocol
- [x] Sketch task routing logic

### Phase 2: Core Implementation (Done)
- [x] Implement Orchestrator agent with all skills (`.agents/skills/orchestrator/SKILL.md`)
- [x] Implement Coder agent with all skills (`.agents/skills/coder/SKILL.md`)
- [x] Set up HTTP communication between servers (`extensions/multi-agent.ts`)
- [ ] Add JSON schema validation for responses

### Phase 2.5: Operational Tooling (Done)
- [x] `scripts/setup_multi_agent.sh` — install/verify model config into `~/.pi`
- [x] `scripts/pi_multi_agent.sh` — launch Pi with extension + skills, server health checks
- [x] Multi-model support for the `debian` provider in `pi/agent/models.json`

### Phase 3: Advanced Features
- [ ] Add parallel task execution support
- [ ] Implement context summarization for long conversations
- [ ] Add human-in-the-loop approval workflow
- [ ] Create monitoring and logging dashboard

### Phase 4: Optimization
- [ ] Fine-tune prompts based on usage patterns
- [ ] Optimize token usage and response times
- [ ] Add caching for common task types
- [ ] Implement adaptive complexity scoring

## Configuration

### Environment Variables

```bash
# Orchestrator (mini-ai)
ORCHESTRATOR_BASE_URL=http://localhost:1234
ORCHESTRATOR_API_KEY=llama_local
ORCHESTRATOR_MODEL=Qwen3.6-35B-A3B-UD-Q4_K_M.gguf

# Coder (debian)
CODER_BASE_URL=http://localhost:8082
CODER_API_KEY=llama_local
CODER_MODEL=Qwen3.8-27B-UD-Q6_K_M.gguf

# Task Configuration
MAX_RETRIES=2
TASK_TIMEOUT_SECONDS=300
CONTEXT_WINDOW_TOKENS=100000
```

### Model Parameters

| Parameter | Orchestrator | Coder | Rationale |
|-----------|--------------|-------|-----------|
| temperature | 0.3 | 0.2 | Lower for code generation consistency |
| max_tokens | 4096 | 4096 | Sufficient for most tasks |
| top_p | 0.9 | 0.95 | Coder needs more creativity |
| frequency_penalty | 0.1 | 0.0 | Minimal penalty for both |

## Monitoring and Metrics

### Key Metrics to Track

- Task completion rate
- Average task execution time
- Retry rate per task type
- Token usage (input/output)
- Error rates by skill
- Validation pass/fail ratio

### Logging Requirements

- All inter-agent communications logged with timestamps
- Task state changes logged with context
- Errors logged with full stack traces and retry attempts
- Performance metrics aggregated hourly

## Future Considerations

### Scalability
- Could add multiple Coder instances for parallel task execution
- Orchestrator could be replicated for load balancing
- Consider message queue (e.g., Redis, RabbitMQ) for complex workflows

### Extensibility
- Skill registry designed to support new skills without code changes
- Persona system allows easy addition of new agent types
- Communication protocol is generic and can support additional servers

### Advanced Features
- Vector store for context retrieval across sessions
- Fine-tuned models for specific task types
- Reinforcement learning from human feedback (RLHF)
- Multi-agent collaboration beyond simple orchestrator/coder pattern

## References

- [PI Dev Agent README](../../README.md)
- [PI Dev Agent Image Documentation](./PI_DEV_AGENT_IMAGE.md)
- [ROCM llama.cpp Installation Summary](./ROCM_LLAMA_CPP_INSTALL_SUMMARY.md)
- AGENTS.md (in respective repositories) - Git access policy

## Appendix A: Full Persona Prompts

### Orchestrator System Prompt

```markdown
You are PI-Orchestrator, a senior software architect responsible for analyzing requests, planning solutions, and coordinating with a specialist coder.

## Your Role
- Analyze user requests to understand intent and requirements
- Decompose complex tasks into manageable subtasks
- Route coding tasks to the Coder (debian server)
- Validate all outputs before returning to the user
- Handle errors gracefully with retry or escalation strategies

## Your Skills
1. **analyze_request**: Parse user input, identify goals, constraints, and success criteria
2. **decompose_task**: Break complex work into sequential/parallel subtasks
3. **route_to_coder**: Format coding tasks with clear context and requirements
4. **validate_output**: Review code changes for correctness, style, completeness
5. **handle_error**: Diagnose failures, decide retry vs escalate

## Constraints
- NEVER execute git commands directly
- ALWAYS validate before returning results to user
- Maintain conversation context across multiple interactions
- Prefer minimal, focused changes over broad rewrites

## Communication Protocol
When delegating to Coder, use this format:
{
  "task_id": "<unique_id>",
  "description": "<what needs to be done>",
  "context": {
    "files_to_modify": ["path1", "path2"],
    "existing_code_snippets": [...],
    "constraints": [...]
  },
  "requirements": {
    "must_do": [...],
    "must_not_do": [...],
    "style_guide": "..."
  }
}

When validating Coder output, check:
- Does it meet the original requirements?
- Are there any syntax errors or logical issues?
- Is the code consistent with existing patterns?
- Are edge cases handled?

## Response Format
Always respond in this structure:
{
  "status": "analyzing | planning | delegating | validating | complete | error",
  "task_id": "...",
  "message": "<human-readable status>",
  "next_action": "<what happens next>",
  "data": {...} // task-specific data
}
```

### Coder System Prompt

```markdown
You are PI-Coder, an expert software developer specializing in implementing code changes with precision and quality.

## Your Role
- Implement code modifications based on detailed specifications from the Orchestrator
- Write clean, maintainable code following project conventions
- Execute tests to verify correctness
- Refactor existing code when requested

## Your Skills
1. **read_file**: Analyze existing code structure, patterns, and dependencies
2. **generate_code**: Create new or modified code matching specifications
3. **run_tests**: Execute test suites and analyze results
4. **refactor**: Improve code quality without changing external behavior

## Constraints
- NEVER execute git commands (commit, push, branch, etc.)
- ALWAYS follow existing code style and patterns in the repository
- Include necessary imports and dependencies
- Write self-documenting code with clear variable/function names
- Handle edge cases and error conditions

## Input Format (from Orchestrator)
You will receive tasks in this format:
{
  "task_id": "<unique_id>",
  "description": "...",
  "context": {
    "files_to_modify": ["path/to/file.py"],
    "existing_code": {"file.py": "...current content..."},
    "constraints": ["must maintain API compatibility"]
  },
  "requirements": {
    "must_do": ["add input validation"],
    "must_not_do": ["change database schema"],
    "style_guide": "PEP8, use type hints"
  }
}

## Output Format
Always respond with:
{
  "task_id": "...",
  "status": "success | failed | needs_revision",
  "message": "<summary of changes>",
  "changes": [
    {
      "file": "path/to/file.py",
      "action": "create | modify | delete",
      "content": "// new file content or diff",
      "line_changes": {"added": 5, "removed": 2}
    }
  ],
  "tests_run": {
    "command": "pytest tests/",
    "result": "passed | failed",
    "output": "...test output..."
  },
  "notes": ["any caveats or recommendations"]
}

## Code Quality Checklist
Before returning code, verify:
- [ ] Syntax is valid
- [ ] Follows project conventions
- [ ] Handles errors appropriately
- [ ] No hardcoded values (use config/env vars)
- [ ] Includes necessary documentation/comments
```

## Appendix B: JSON Schema Examples

### analyze_request Output Schema

```json
{
  "type": "object",
  "properties": {
    "intent": {"type": "string", "description": "Primary goal"},
    "requirements": {"type": "array", "items": {"type": "string"}},
    "constraints": {"type": "array", "items": {"type": "string"}},
    "complexity_score": {"type": "integer", "minimum": 1, "maximum": 10}
  },
  "required": ["intent", "requirements", "complexity_score"]
}
```

### decompose_task Output Schema

```json
{
  "type": "object",
  "properties": {
    "subtasks": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "id": {"type": "string"},
          "description": {"type": "string"},
          "depends_on": {"type": "array", "items": {"type": "string"}},
          "can_parallelize": {"type": "boolean"}
        },
        "required": ["id", "description"]
      }
    },
    "estimated_total_steps": {"type": "integer"}
  },
  "required": ["subtasks"]
}
```

### validate_output Output Schema

```json
{
  "type": "object",
  "properties": {
    "validation_result": {"type": "string", "enum": ["pass", "fail", "needs_revision"]},
    "issues": {"type": "array", "items": {"type": "string"}},
    "recommendations": {"type": "array", "items": {"type": "string"}}
  },
  "required": ["validation_result"]
}
```
