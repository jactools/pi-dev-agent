/**
 * Multi-Agent Orchestrator Extension for Pi
 * 
 * This extension enables a two-server architecture where:
 * - mini-ai (Qwen3.6-35B) acts as the Orchestrator
 * - debian (Qwen3.8-27B) acts as the Coder
 * 
 * Features:
 * - Virtual model for automatic routing between agents
 * - Tools for explicit delegation and validation
 * - Commands for manual control
 * - Event handlers for context management
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// ============================================================================
// Configuration
// ============================================================================

const CONFIG = {
  orchestrator: {
    provider: "mini-ai",
    model: "Qwen3.6-35B-A3B-UD-Q4_K_M.gguf",
    baseUrl: "http://localhost:1234",
    port: 1234,
  },
  coder: {
    provider: "debian",
    model: "Qwen3.8-27B-UD-Q6_K_M.gguf",
    baseUrl: "http://localhost:8082",
    port: 8082,
  },
  maxRetries: 2,
  taskTimeoutMs: 300000, // 5 minutes
};

// ============================================================================
// Persona Prompts
// ============================================================================

const ORCHESTRATOR_PROMPT = `You are PI-Orchestrator, a senior software architect responsible for analyzing requests, planning solutions, and coordinating with specialist coder agents.

## Your Role
- Analyze user requests to understand intent, goals, and success criteria
- Decompose complex tasks into manageable subtasks
- Route coding tasks to the Coder agent (debian server)
- Validate all outputs before returning to the user
- Handle errors gracefully with retry or escalation strategies

## Your Skills
1. analyze_request: Parse user input, identify goals, constraints, and success criteria
2. decompose_task: Break complex work into sequential/parallel subtasks
3. route_to_coder: Format coding tasks with clear context and requirements
4. validate_output: Review code changes for correctness, style, completeness
5. handle_error: Diagnose failures, decide retry vs escalate

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
  "data": {...}
}`;

const CODER_PROMPT = `You are PI-Coder, an expert software developer specializing in implementing code changes with precision and quality.

## Your Role
- Implement code modifications based on detailed specifications from the Orchestrator
- Write clean, maintainable code following project conventions
- Execute tests to verify correctness (when requested)
- Refactor existing code when requested

## Your Skills
1. read_file: Analyze existing code structure, patterns, and dependencies
2. generate_code: Create new or modified code matching specifications
3. run_tests: Execute test suites and analyze results
4. refactor: Improve code quality without changing external behavior

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
- [ ] Includes necessary documentation/comments`;

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * Send a request to a llama.cpp server
 */
async function callLlamaServer(
  baseUrl: string,
  model: string,
  messages: Array<{ role: string; content: string }>,
  temperature = 0.3,
  maxTokens = 4096
): Promise<string> {
  const response = await fetch(`${baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: "Bearer llama_local",
    },
    body: JSON.stringify({
      model,
      messages,
      temperature,
      max_tokens: maxTokens,
      response_format: { type: "json_object" },
    }),
  });

  if (!response.ok) {
    throw new Error(`LLM request failed: ${response.status} ${response.statusText}`);
  }

  const data = await response.json();
  return data.choices[0].message.content;
}

/**
 * Extract text from a message's content, handling both string and array formats.
 */
function extractContentText(content: string | Array<{ type: string; text?: string }>): string {
  if (typeof content === "string") {
    return content;
  }
  // Handle array of content blocks (e.g., [{ type: "text", text: "..." }])
  return content
    .filter((block): block is { type: string; text: string } => block.type === "text" && block.text !== undefined)
    .map((block) => block.text!)
    .join(" ");
}

/**
 * Detect if a message is a coding task
 */
function detectCodingTask(messages: Array<{ role: string; content: string | Array<{ type: string; text?: string }> }>): boolean {
  const lastUserMessage = [...messages].reverse().find((m) => m.role === "user");
  if (!lastUserMessage) return false;

  const codingKeywords = [
    "implement",
    "add",
    "remove",
    "change",
    "update",
    "fix",
    "modify",
    "create",
    "delete",
    "refactor",
    "code",
    "function",
    "class",
    "method",
    "file",
  ];

  const content = extractContentText(lastUserMessage.content).toLowerCase();
  return codingKeywords.some((keyword) => content.includes(keyword));
}

/**
 * Generate a unique task ID
 */
function generateTaskId(): string {
  return `task_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
}

// ============================================================================
// Extension Factory
// ============================================================================

export default function (pi: ExtensionAPI) {
  
  // ===========================================================================
  // 1. Register Virtual Model for Automatic Routing
  // ===========================================================================
  
  pi.registerVirtualModel({
    provider: "local",
    id: "multi-agent",
    name: "Multi-Agent (Auto-Route)",
    description: "Automatically routes tasks between Orchestrator and Coder based on task type",
    thinkingLevels: ["low", "medium", "high"],
    
    route(request, ctx) {
      // For tool follow-ups and retries, stay on the same model
      const sticky = request.failed ?? request.previous;
      if (request.reason !== "user" && sticky) {
        return { 
          model: sticky.model,
          thinkingLevel: sticky.thinkingLevel ?? "medium" 
        };
      }

      // Detect task type and route accordingly
      const isCodingTask = detectCodingTask(request.messages);
      
      if (isCodingTask) {
        // Route to Coder for coding tasks
        return {
          model: ctx.modelRegistry.find(CONFIG.coder.provider, CONFIG.coder.model)!,
          thinkingLevel: "low", // Coder needs precision, not heavy reasoning
        };
      } else {
        // Route to Orchestrator for planning/analysis
        return {
          model: ctx.modelRegistry.find(CONFIG.orchestrator.provider, CONFIG.orchestrator.model)!,
          thinkingLevel: request.thinkingLevel === "high" ? "high" : "medium",
        };
      }
    },
  });

  // ===========================================================================
  // 2. Register Tools for Explicit Agent Control
  // ===========================================================================

  /**
   * Tool: delegate_to_coder
   * Allows the Orchestrator to explicitly send coding tasks to the Coder
   */
  pi.registerTool({
    name: "delegate_to_coder",
    description: "Send a coding task to the debian coder server. Use when you need code changes implemented.",
    parameters: {
      type: "object" as const,
      properties: {
        task_description: { type: "string" as const, description: "Clear description of what needs to be done" },
        files_to_modify: { type: "array" as const, items: { type: "string" as const }, description: "List of file paths that need to be modified" },
        requirements: { type: "array" as const, items: { type: "string" as const }, description: "List of specific requirements the implementation must meet" },
        constraints: { type: "array" as const, items: { type: "string" as const }, description: "List of constraints (what NOT to do, limitations, etc.)" },
      },
      required: ["task_description", "files_to_modify"] as const,
    },
    execute: async (_toolCallId, params, _signal, _onUpdate, ctx) => {
      const taskId = generateTaskId();
      
      // Build the task payload for the Coder
      const coderPayload = {
        task_id: taskId,
        description: params.task_description,
        context: {
          files_to_modify: params.files_to_modify,
          constraints: params.constraints || [],
        },
        requirements: {
          must_do: params.requirements || [],
        },
      };

      // Call the Coder server
      try {
        const result = await callLlamaServer(
          CONFIG.coder.baseUrl,
          CONFIG.coder.model,
          [
            { role: "system", content: CODER_PROMPT },
            { role: "user", content: JSON.stringify(coderPayload, null, 2) },
          ],
          0.2, // Lower temperature for code generation
          8192 // More tokens for code output
        );

        return {
          content: [{ type: "text", text: `Coding task ${taskId} delegated successfully:\n\n${result}` }],
          details: { success: true, task_id: taskId },
        };
      } catch (error) {
        throw new Error(`Failed to delegate coding task: ${error.message}`);
      }
    },
  });

  /**
   * Tool: validate_code_output
   * Allows the Orchestrator to validate code changes from the Coder
   */
  pi.registerTool({
    name: "validate_code_output",
    description: "Review and validate code changes for correctness, style, and completeness. Use after receiving code from the Coder.",
    parameters: {
      type: "object" as const,
      properties: {
        code_changes: { type: "string" as const, description: "The code changes returned by the Coder" },
        original_requirements: { type: "string" as const, description: "The original requirements that need to be met" },
        files_affected: { type: "array" as const, items: { type: "string" as const }, description: "List of files that were modified" },
      },
      required: ["code_changes", "original_requirements"] as const,
    },
    execute: async (_toolCallId, params, _signal, _onUpdate, ctx) => {
      // Call the Orchestrator to validate
      try {
        const result = await callLlamaServer(
          CONFIG.orchestrator.baseUrl,
          CONFIG.orchestrator.model,
          [
            { role: "system", content: ORCHESTRATOR_PROMPT },
            { 
              role: "user", 
              content: JSON.stringify({
                action: "validate_output",
                code_changes: params.code_changes,
                original_requirements: params.original_requirements,
                files_affected: params.files_affected || [],
              }, null, 2) 
            },
          ],
          0.3,
          4096
        );

        return {
          content: [{ type: "text", text: `Validation result:\n\n${result}` }],
          details: { success: true },
        };
      } catch (error) {
        throw new Error(`Validation failed: ${error.message}`);
      }
    },
  });

  /**
   * Tool: analyze_request
   * Orchestrator skill to analyze user requests
   */
  pi.registerTool({
    name: "analyze_request",
    description: "Analyze a user request to understand intent, requirements, and complexity. Returns a structured analysis.",
    parameters: {
      type: "object" as const,
      properties: {
        user_message: { type: "string" as const, description: "The user's request or message to analyze" },
      },
      required: ["user_message"] as const,
    },
    execute: async (_toolCallId, params, _signal, _onUpdate, ctx) => {
      try {
        const result = await callLlamaServer(
          CONFIG.orchestrator.baseUrl,
          CONFIG.orchestrator.model,
          [
            { role: "system", content: ORCHESTRATOR_PROMPT },
            { 
              role: "user", 
              content: JSON.stringify({
                action: "analyze_request",
                user_message: params.user_message,
              }, null, 2) 
            },
          ],
          0.3,
          4096
        );

        return {
          content: [{ type: "text", text: `Analysis result:\n\n${result}` }],
          details: { success: true },
        };
      } catch (error) {
        throw new Error(`Analysis failed: ${error.message}`);
      }
    },
  });

  // ===========================================================================
  // 3. Register Commands for Manual Control
  // ===========================================================================

  pi.registerCommand("orchestrator", {
    description: "Switch to Orchestrator mode (mini-ai server). Use for planning and analysis.",
    handler: async (_, ctx) => {
      try {
        const model = ctx.modelRegistry.find(
          CONFIG.orchestrator.provider, 
          CONFIG.orchestrator.model
        );
        
        if (!model) {
          ctx.ui.notify(`Error: Model ${CONFIG.orchestrator.model} not found`, "error");
          return;
        }

        ctx.setModel(model.id);
        ctx.setThinkingLevel("high");
        ctx.ui.notify("✓ Switched to Orchestrator mode (mini-ai)", "info");
      } catch (error) {
        ctx.ui.notify(`Error switching to Orchestrator: ${error.message}`, "error");
      }
    },
  });

  pi.registerCommand("coder", {
    description: "Switch to Coder mode (debian server). Use for code implementation.",
    handler: async (_, ctx) => {
      try {
        const model = ctx.modelRegistry.find(
          CONFIG.coder.provider, 
          CONFIG.coder.model
        );
        
        if (!model) {
          ctx.ui.notify(`Error: Model ${CONFIG.coder.model} not found`, "error");
          return;
        }

        ctx.setModel(model.id);
        ctx.setThinkingLevel("low");
        ctx.ui.notify("✓ Switched to Coder mode (debian)", "info");
      } catch (error) {
        ctx.ui.notify(`Error switching to Coder: ${error.message}`, "error");
      }
    },
  });

  pi.registerCommand("multi-agent", {
    description: "Start multi-agent orchestration session. Uses automatic routing between Orchestrator and Coder.",
    handler: async (_, ctx) => {
      try {
        // Switch to the virtual model for auto-routing
        const virtualModel = ctx.modelRegistry.find("local", "multi-agent");
        
        if (!virtualModel) {
          ctx.ui.notify("Error: Multi-agent virtual model not registered", "error");
          return;
        }

        ctx.setModel(virtualModel.id);
        ctx.setThinkingLevel("medium");
        
        // Add a system message to indicate multi-agent mode is active
        await ctx.appendEntry({
          role: "system",
          content: "[Multi-Agent Mode Active] Tasks will be automatically routed between Orchestrator and Coder agents. Use /orchestrator or /coder to switch manually, or use tools like delegate_to_coder for explicit control.",
        });

        ctx.ui.notify("✓ Multi-Agent mode started with automatic routing", "info");
      } catch (error) {
        ctx.ui.notify(`Error starting multi-agent mode: ${error.message}`, "error");
      }
    },
  });

  pi.registerCommand("agent-status", {
    description: "Show the status of both agent servers (mini-ai and debian).",
    handler: async (_, ctx) => {
      try {
        // Check mini-ai
        const miniAiResponse = await fetch(`${CONFIG.orchestrator.baseUrl}/v1/models`, {
          headers: { Authorization: "Bearer llama_local" },
        });
        
        // Check debian
        const debianResponse = await fetch(`${CONFIG.coder.baseUrl}/v1/models`, {
          headers: { Authorization: "Bearer llama_local" },
        });

        const miniAiOk = miniAiResponse.ok;
        const debianOk = debianResponse.ok;

        let statusMessage = `Agent Server Status:\n\n`;
        statusMessage += `🟢 Orchestrator (mini-ai): ${miniAiOk ? "ONLINE" : "OFFLINE"}\n`;
        statusMessage += `   Model: ${CONFIG.orchestrator.model}\n`;
        statusMessage += `   URL: ${CONFIG.orchestrator.baseUrl}\n\n`;
        statusMessage += `🟢 Coder (debian): ${debianOk ? "ONLINE" : "OFFLINE"}\n`;
        statusMessage += `   Model: ${CONFIG.coder.model}\n`;
        statusMessage += `   URL: ${CONFIG.coder.baseUrl}\n`;

        ctx.ui.notify(statusMessage, miniAiOk && debianOk ? "info" : "warn");
      } catch (error) {
        ctx.ui.notify(`Error checking agent status: ${error.message}`, "error");
      }
    },
  });

  // ===========================================================================
  // 4. Register Event Handlers for Context Management
  // ===========================================================================

  /**
   * Before each agent run, add context about multi-agent mode if active
   */
  pi.on("before_agent_start", async (event, ctx) => {
    const currentModel = ctx.model;
    
    // If using the virtual model or coder model, ensure we have proper context
    if (currentModel && typeof currentModel === "string" && 
        (currentModel.includes("multi-agent") || currentModel.includes(CONFIG.coder.provider))) {
      // This is handled by the system message added in /multi-agent command
      return event;
    }
    
    return event;
  });

  /**
   * After each turn, log what happened for debugging
   */
  pi.on("turn_end", async (event, ctx) => {
    const modelUsed = event.model || "unknown";
    const toolCalls = event.toolCalls?.length || 0;
    
    // Silent logging - could be enhanced with proper logging framework
    console.log(`[Multi-Agent] Turn completed: model=${modelUsed}, tools=${toolCalls}`);
  });

  /**
   * Session start notification
   */
  pi.on("session_start", async (event, ctx) => {
    console.log("[Multi-Agent] Session started");
    
    // Could initialize session state here if needed
  });

  /**
   * Session shutdown cleanup
   */
  pi.on("session_shutdown", async (event, ctx) => {
    console.log("[Multi-Agent] Session shutting down");
    
    // Clean up any session-scoped resources
  });

  // ===========================================================================
  // 5. Register Extension UI Elements (Optional)
  // ===========================================================================

  // Could add persistent status indicator here if needed
  // For now, we rely on notifications and /agent-status command

  console.log("[Multi-Agent] Extension loaded successfully");
  console.log(`[Multi-Agent] Orchestrator: ${CONFIG.orchestrator.provider}/${CONFIG.orchestrator.model}`);
  console.log(`[Multi-Agent] Coder: ${CONFIG.coder.provider}/${CONFIG.coder.model}`);
}
