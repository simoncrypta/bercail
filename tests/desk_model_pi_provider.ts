// Loaded by the installed Pi binary: two models that answer OK, no network calls.
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerProvider("fake", {
    api: "desk-model-pi",
    baseUrl: "http://invalid.invalid",
    apiKey: "offline-test-key",
    models: ["opus", "fable"].map((id) => ({
      id,
      name: id,
      reasoning: true,
      input: ["text"],
      contextWindow: 8000,
      maxTokens: 200,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    })),
    streamSimple(model) {
      const stream = createAssistantMessageEventStream();
      queueMicrotask(() => {
        const message = {
          role: "assistant",
          content: [{ type: "text", text: "OK" }],
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
