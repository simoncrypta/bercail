// Offline provider loaded by the real Pi binary. No network.
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// PI_GUARD_COMMANDS: a JSON list of bash commands, one tool call each. The last
// message says whether the repo's git policy reached the system prompt.
const commands: string[] = JSON.parse(process.env.PI_GUARD_COMMANDS || '["git push --force"]');

export default function (pi: ExtensionAPI) {
  let calls = 0;
  pi.registerProvider("fake-guard", {
    api: "pi-guard-test",
    baseUrl: "http://invalid.invalid",
    apiKey: "offline-test-key",
    models: [
      {
        id: "model",
        name: "guard",
        reasoning: false,
        input: ["text"],
        contextWindow: 200000,
        maxTokens: 1000,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      },
    ],
    streamSimple(model, context) {
      const stream = createAssistantMessageEventStream();
      queueMicrotask(() => {
        calls++;
        const usage = {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
        };
        const base = {
          role: "assistant" as const,
          api: model.api,
          provider: model.provider,
          model: model.id,
          usage,
          timestamp: Date.now(),
        };
        if (calls <= commands.length) {
          stream.push({
            type: "done",
            reason: "toolUse",
            message: {
              ...base,
              stopReason: "toolUse",
              content: [
                {
                  type: "toolCall",
                  id: `guard-call-${calls}`,
                  name: "bash",
                  arguments: { command: commands[calls - 1] },
                },
              ],
            },
          });
        } else {
          const policy = JSON.stringify(context.messages).includes("Git policy for") ? "yes" : "no";
          stream.push({
            type: "done",
            reason: "stop",
            message: {
              ...base,
              stopReason: "stop",
              content: [{ type: "text", text: `PI_GUARD_DONE policy-in-prompt=${policy}` }],
            },
          });
        }
        stream.end();
      });
      return stream;
    },
  });
}
