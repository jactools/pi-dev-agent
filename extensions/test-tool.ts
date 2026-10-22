import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  console.log("[Test] Loading test extension");
  
  pi.registerTool({
    name: "test_tool",
    description: "A simple test tool",
    parameters: {
      type: "object" as const,
      properties: {
        message: { 
          type: "string" as const, 
          description: "Test message" 
        },
      },
      required: ["message"] as const,
    } as const,
    execute: async (id, params, signal, onUpdate, ctx) => {
      return {
        content: [{ type: "text", text: `Received: ${params.message}` }],
      };
    },
  });
  
  console.log("[Test] Test extension loaded successfully");
}
