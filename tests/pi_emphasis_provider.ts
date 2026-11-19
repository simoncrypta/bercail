// Loaded by the installed Pi for the pi-emphasis live proof: a model with no network
// that writes what it was sent to $PI_EMPHASIS_PROBE and replies with one pill.
// Pi 1.5 carries the system prompt as system messages in the transcript.
import { writeFileSync } from "node:fs";
import { type AssistantMessage, createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerProvider("fake-emphasis", {
    api: "fake-emphasis",
    baseUrl: "http://invalid.invalid",
    apiKey: "offline-test-key",
    models: [
      {
        id: "model",
        name: "fake",
        reasoning: false,
        input: ["text"],
        contextWindow: 64000,
        maxTokens: 200,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      },
    ],
    streamSimple(model, context) {
      writeFileSync(process.env.PI_EMPHASIS_PROBE!, JSON.stringify(context));
      const stream = createAssistantMessageEventStream();
      queueMicrotask(() => {
        const message: AssistantMessage = {
          role: "assistant",
          content: [{ type: "text", text: "**Result:** the pill check is [[Done]]." }],
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
