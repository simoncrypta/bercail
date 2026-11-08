// Offline provider loaded by the real Pi binary. No network.
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  let calls = 0;
  pi.registerProvider("fake-guard", {
    api: "pi-guard-test",
    baseUrl: "http://invalid.invalid",
    apiKey: "offline-test-key",
    models: [{
      id: "model",
      name: "guard",
      reasoning: false,
      input: ["text"],
      contextWindow: 200000,
      maxTokens: 1000,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    }],
    streamSimple(model) {
      const stream = createAssistantMessageEventStream();
      queueMicrotask(() => {
        calls++;
        const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
        const base = { role: "assistant" as const, api: model.api, provider: model.provider, model: model.id, usage, timestamp: Date.now() };
        if (calls === 1) {
          stream.push({
            type: "done",
            reason: "toolUse",
            message: {
              ...base,
              stopReason: "toolUse",
              content: [{ type: "toolCall", id: "guard-call", name: "bash", arguments: { command: "git push --force" } }],
            },
          });
        } else {
          stream.push({
            type: "done",
            reason: "stop",
            message: { ...base, stopReason: "stop", content: [{ type: "text", text: "PI_GUARD_DONE" }] },
          });
        }
        stream.end();
      });
      return stream;
    },
  });
}
