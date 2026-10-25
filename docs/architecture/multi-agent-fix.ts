/**
 * Multi-Agent Orchestrator Extension (FIXED)
 * 
 * This is a user-level override of /usr/local/pi-dev/extensions/multi-agent.ts
 * that actually applies file changes returned by the Coder LLM.
 *
 * The original extension only sent prompts to the Coder and returned its text
 * response without ever writing files. This version:
 *   1. Reads target files before sending them to the Coder
 *   2. Asks the Coder for exact oldText/newText edit pairs
 *   3. Applies edits via ctx.executeTool("edit", ...) / ctx.executeTool("write", ...)
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import * as fs from "fs";
import * as path from "path";

// ============================================================================
// Configuration
// ============================================================================

const PI_HOST = process.env.PI_HOST ?? "localhost";

const CONFIG = {
  orchestrator: {
    provider: "mini-ai",
    model: "Qwen3.6-35B-A3B-UD-Q4_K_M.gguf",
    baseUrl: `http://${PI_HOST}:1234`,
    port: 1234,
  },
  coder: {
    provider: "debian",
    model: "Qwen3.8-27B-UD-Q6_K_M.gguf",
    baseUrl: `http://${PI_HOST}:8082`,
    port: 8082,
  },
  maxRetries: 2,
  taskTimeoutMs: 300000,
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

## Constraints
- NEVER execute git commands directly
- ALWAYS validate before returning results to user
- Maintain conversation context across multiple interactions
- Prefer minimal, focused changes over broad rewrites`;

const CODER_PROMPT = `You are PI-Coder, an expert software developer specializing in implementing code changes with precision and quality.

## Your Role
- Implement code modifications based on detailed specifications from the Orchestrator
- Write clean, maintainable code following project conventions
- Refactor existing code when requested

## Constraints
- NEVER execute git commands (commit, push, branch, etc.)
- ALWAYS follow existing code style and patterns in the repository
- Include necessary imports and dependencies
- Handle edge cases and error conditions

## Input Format
You will receive tasks with current file contents already provided:
{
  "task_id": "...",
  "description": "...",
  "context": {
    "files_to_modify": ["path/to/file.ts"],
    "file_contents": {"/abs/path": "<full current content>"},
    "constraints": [...]
  },
  "requirements": {
    "must_do": [...]
  }
}

## Output Format (STRICT JSON — no markdown fences, no prose)
You MUST respond with ONLY a valid JSON object. Nothing else.
{
  "task_id": "...",
  "status": "success" | "failed",
  "message": "<one-line summary of what was done>",
  "edits": [
    {
      "file": "/absolute/path/to/file.ts",
      "oldText": "exact text to find in the current file (must be unique)",
      "newText": "replacement text"
    }
  ],
  "notes": []
}

## Rules for edits[]
- oldText MUST be an exact substring of the file content provided to you. Copy it character-for-character.
- oldText MUST be unique within that file (no ambiguity about which occurrence to replace).
- Keep oldText as small as possible while still being unique (a few lines, not the whole file).
- newText is what replaces oldText exactly.
- Multiple edits to the same file are allowed; they are all applied against the ORIGINAL content independently.
- Do NOT include overlapping or nested edits.
- If you need to create a brand new file that does not exist yet:
  {"file": "/path/to/new/file.ts", "action": "create", "content": "full file content here"}
- If no changes are needed, return: "edits": []

## Code Quality Checklist
Before returning, verify each edit:
- [ ] oldText is an exact match from the provided file content (check whitespace!)
- [ ] The resulting code after replacement is syntactically valid
- [ ] Follows existing project conventions and style`;

// ============================================================================
// Helper Functions
// ============================================================================

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

function extractContentText(content: string | Array<{ type: string; text?: string }>): string {
  if (typeof content === "string") return content;
  return content
    .filter((block): block is { type: "text"; text: string } => block.type === "text" && block.text !== undefined)
    .map((block) => block.text!)
    .join(" ");
}

function detectCodingTask(messages: Array<{ role: string; content: string | Array<{ type: string; text?: string }> }>): boolean {
  const lastUserMessage = [...messages].reverse().find((m) => m.role === "user");
  if (!lastUserMessage) return false;

  const codingKeywords = [
    "implement", "add", "remove", "change", "update", "fix",
    "modify", "create", "delete", "refactor", "code", "function",
    "class", "method", "file",
  ];

  const content = extractContentText(lastUserMessage.content).toLowerCase();
  return codingKeywords.some((keyword) => content.includes(keyword));
}

function generateTaskId(): string {
  return `task_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
}

/**
 * Read a file's contents, returning empty string if it doesn't exist.
 */
function readFileSafe(filePath: string): string {
  try {
    const resolved = path.resolve(filePath);
    return fs.readFileSync(resolved, "utf-8");
  } catch {
    return "";
  }
}

/**
 * Parse the Coder's JSON response, handling common LLM output issues.
 */
function parseCoderResponse(raw: string): any | null {
  // Strip markdown code fences if present
  let cleaned = raw.trim();
  cleaned = cleaned.replace(/^```(?:json)?\s*\n?/, "").replace(/\n?\s*```\s*$/, "");
  
  // Try direct parse first
  try {
    return JSON.parse(cleaned);
  } catch {}

  // Try to find a JSON object in the response (in case of surrounding text)
  const jsonMatch = cleaned.match(/\{[\s\S]*\}/);
  if (jsonMatch) {
    try {
      return JSON.parse(jsonMatch[0]);
    } catch {}
  }

  return null;
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
      const sticky = request.failed ?? request.previous;
      if (request.reason !== "user" && sticky) {
        return { 
          model: sticky.model,
          thinkingLevel: sticky.thinkingLevel ?? "medium" 
        };
      }

      const isCodingTask = detectCodingTask(request.messages);
      
      if (isCodingTask) {
        return {
          model: ctx.modelRegistry.find(CONFIG.coder.provider, CONFIG.coder.model)!,
          thinkingLevel: "low",
        };
      } else {
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
   * Tool: delegate_to_coder (FIXED — actually applies file changes)
   */
  pi.registerTool({
    name: "delegate_to_coder",
    description: "Send a coding task to the debian coder server. The Coder's edits are automatically applied to files.",
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
    execute: async (_toolCallId, params, signal, _onUpdate, ctx) => {
      const taskId = generateTaskId();

      // ─── Step 1: Read current file contents ───────────────────────────────
      const fileContents: Record<string, string> = {};
      for (const filePath of params.files_to_modify) {
        fileContents[filePath] = readFileSafe(filePath);
      }

      // ─── Step 2: Build payload with actual content ────────────────────────
      const coderPayload = {
        task_id: taskId,
        description: params.task_description,
        context: {
          files_to_modify: params.files_to_modify,
          file_contents: fileContents,
          constraints: params.constraints || [],
        },
        requirements: {
          must_do: params.requirements || [],
        },
      };

      // ─── Step 3: Call the Coder LLM ───────────────────────────────────────
      let rawResponse: string;
      try {
        rawResponse = await callLlamaServer(
          CONFIG.coder.baseUrl,
          CONFIG.coder.model,
          [
            { role: "system", content: CODER_PROMPT },
            { role: "user", content: JSON.stringify(coderPayload, null, 2) },
          ],
          0.1, // Very low temperature for precise edits
          8192
        );
      } catch (error) {
        throw new Error(`Failed to reach Coder server: ${(error as Error).message}`);
      }

      // ─── Step 4: Parse response ───────────────────────────────────────────
      const parsed = parseCoderResponse(rawResponse);
      if (!parsed) {
        return {
          content: [{ type: "text", text: `⚠️ Coder returned unparseable response for task ${taskId}.\n\nRaw output:\n${rawResponse.slice(0, 2000)}` }],
          details: { success: false, task_id: taskId, error: "unparseable_response" },
        };
      }

      // ─── Step 5: Apply edits using ctx.executeTool ────────────────────────
      const applied: string[] = [];
      const errors: string[] = [];

      // Group edits by file for batch application
      const editsByFile = new Map<string, Array<{ oldText: string; newText: string }>>();
      const creates: Array<{ file: string; content: string }> = [];

      for (const edit of parsed.edits ?? []) {
        if (edit.action === "create" && edit.content) {
          creates.push({ file: edit.file, content: edit.content });
        } else if (edit.oldText !== undefined && edit.newText !== undefined) {
          const existing = editsByFile.get(edit.file) ?? [];
          existing.push({ oldText: edit.oldText, newText: edit.newText });
          editsByFile.set(edit.file, existing);
        }
      }

      // Apply creates
      for (const create of creates) {
        try {
          await ctx.executeTool("write", { path: create.file, content: create.content }, { signal });
          applied.push(`created ${create.file}`);
        } catch (err) {
          errors.push(`create ${create.file}: ${(err as Error).message}`);
        }
      }

      // Apply edits (batched per file)
      for (const [filePath, edits] of editsByFile) {
        try {
          await ctx.executeTool("edit", { path: filePath, edits }, { signal });
          applied.push(`edited ${filePath} (${edits.length} change${edits.length > 1 ? "s" : ""})`);
        } catch (err) {
          errors.push(`edit ${filePath}: ${(err as Error).message}`);
        }
      }

      // ─── Step 6: Build result summary ─────────────────────────────────────
      const allSuccess = parsed.status === "success" && errors.length === 0;
      const icon = allSuccess ? "✅" : errors.length > 0 ? "⚠️" : "❌";
      
      let summary = `${icon} Task ${taskId}: ${parsed.message ?? "completed"}\n`;
      
      if (applied.length > 0) {
        summary += `\nApplied:\n${applied.map(a => `  • ${a}`).join("\n")}`;
      }
      if (errors.length > 0) {
        summary += `\nErrors:\n${errors.map(e => `  ✗ ${e}`).join("\n")}`;
      }
      if (parsed.notes?.length) {
        summary += `\nNotes: ${parsed.notes.join("; ")}`;
      }
      if (applied.length === 0 && errors.length === 0) {
        summary += "\n(no file changes were requested)";
      }

      return {
        content: [{ type: "text", text: summary }],
        details: { success: allSuccess, task_id: taskId, applied, errors },
      };
    },
  });

  /**
   * Tool: validate_code_output
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
    execute: async (_toolCallId, params, _signal, _onUpdate, _ctx) => {
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
        throw new Error(`Validation failed: ${(error as Error).message}`);
      }
    },
  });

  /**
   * Tool: analyze_request
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
    execute: async (_toolCallId, params, _signal, _onUpdate, _ctx) => {
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
        throw new Error(`Analysis failed: ${(error as Error).message}`);
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
        const model = ctx.modelRegistry.find(CONFIG.orchestrator.provider, CONFIG.orchestrator.model);
        if (!model) {
          ctx.ui.notify(`Error: Model ${CONFIG.orchestrator.model} not found`, "error");
          return;
        }
        ctx.setModel(model.id);
        ctx.setThinkingLevel("high");
        ctx.ui.notify("✓ Switched to Orchestrator mode (mini-ai)", "info");
      } catch (error) {
        ctx.ui.notify(`Error switching to orchestrator: ${(error as Error).message}`, "error");
      }
    },
  });

  pi.registerCommand("coder", {
    description: "Switch to Coder mode (debian server). Use for code implementation.",
    handler: async (_, ctx) => {
      try {
        const model = ctx.modelRegistry.find(CONFIG.coder.provider, CONFIG.coder.model);
        if (!model) {
          ctx.ui.notify(`Error: Model ${CONFIG.coder.model} not found`, "error");
          return;
        }
        ctx.setModel(model.id);
        ctx.setThinkingLevel("low");
        ctx.ui.notify("✓ Switched to Coder mode (debian)", "info");
      } catch (error) {
        ctx.ui.notify(`Error switching to coder: ${(error as Error).message}`, "error");
      }
    },
  });

  pi.registerCommand("multi-agent", {
    description: "Start multi-agent orchestration session.",
    handler: async (_, ctx) => {
      try {
        const virtualModel = ctx.modelRegistry.find("local", "multi-agent");
        if (!virtualModel) {
          ctx.ui.notify("Error: Multi-agent virtual model not registered", "error");
          return;
        }
        ctx.setModel(virtualModel.id);
        ctx.setThinkingLevel("medium");
        await ctx.appendEntry({
          role: "system",
          content: "[Multi-Agent Mode Active] Tasks will be automatically routed between Orchestrator and Coder agents. Use /orchestrator or /coder to switch manually, or use delegate_to_coder for explicit control with automatic file application.",
        });
        ctx.ui.notify("✓ Multi-Agent mode started (with auto-apply)", "info");
      } catch (error) {
        ctx.ui.notify(`Error starting multi-agent: ${(error as Error).message}`, "error");
      }
    },
  });

  pi.registerCommand("agent-status", {
    description: "Show the status of both agent servers.",
    handler: async (_, ctx) => {
      try {
        const [miniAiRes, debianRes] = await Promise.all([
          fetch(`${CONFIG.orchestrator.baseUrl}/v1/models`, { headers: { Authorization: "Bearer llama_local" } }),
          fetch(`${CONFIG.coder.baseUrl}/v1/models`, { headers: { Authorization: "Bearer llama_local" } }),
        ]);

        const status = `Agent Server Status:\n\n` +
          `${miniAiRes.ok ? "🟢" : "🔴"} Orchestrator (mini-ai): ${miniAiRes.ok ? "ONLINE" : "OFFLINE"} — ${CONFIG.orchestrator.baseUrl}\n` +
          `${debianRes.ok ? "🟢" : "🔴"} Coder (debian): ${debianRes.ok ? "ONLINE" : "OFFLINE"} — ${CONFIG.coder.baseUrl}`;

        ctx.ui.notify(status, miniAiRes.ok && debianRes.ok ? "info" : "warn");
      } catch (error) {
        ctx.ui.notify(`Error checking status: ${(error as Error).message}`, "error");
      }
    },
  });

  // ===========================================================================
  // Logging
  // ===========================================================================

  console.log("[Multi-Agent-FIXED] Extension loaded — delegate_to_coder now applies edits automatically");
}
