// Loaded by the installed Pi binary for Shep's live proof: a model with no
// network that answers each turn with "Shep report:" and the event ids it was given.
import { type AssistantMessage, createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

function textOf(message: any): string {
  const c = message?.content;
  if (typeof c === "string") return c;
  if (Array.isArray(c)) return c.map((p) => (typeof p?.text === "string" ? p.text : "")).join("\n");
  return "";
}

export default function (pi: ExtensionAPI) {
  pi.registerProvider("fake", {
    api: "shep-pi",
    baseUrl: "http://invalid.invalid",
    apiKey: "offline-test-key",
    models: [
      {
        id: "model",
        name: "fake",
        reasoning: false,
        input: ["text"],
        contextWindow: 16000,
        maxTokens: 200,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      },
    ],
    streamSimple(model, context) {
      const stream = createAssistantMessageEventStream();
      const last = context.messages[context.messages.length - 1];
      const ids = [...textOf(last).matchAll(/\[event ([^\]]+)\]/g)].map((m) => m[1]);
      queueMicrotask(() => {
        const message: AssistantMessage = {
          role: "assistant",
          content: [{ type: "text", text: `Shep report: ${ids.length ? ids.join(", ") : "no events"}` }],
          api: model.api,
          provider: model.provider,
          model: model.id,
          usage: {
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: 0,
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
          },
          stopReason: "stop",
          timestamp: Date.now(),
        };
        stream.push({ type: "done", reason: "stop", message });
        stream.end();
      });
      return stream;
    },
  });
}
