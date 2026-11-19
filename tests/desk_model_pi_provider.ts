// Loaded by the installed Pi binary: two models that answer OK, no network calls.
import { type AssistantMessage, createAssistantMessageEventStream } from "@earendil-works/pi-ai";
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
    streamSimple(model, context) {
      const last = context.messages.at(-1);
      const work = last?.role === "user" && JSON.stringify(last.content).includes("Amend/publish follow-up");
      // A long run: one slow bash call, so a follow-up can arrive while it works.
      const busy = last?.role === "user" && JSON.stringify(last.content).includes("busy run");
      const call = busy ? "sleep 4" : work ? "git rev-parse HEAD" : "";
      const stream = createAssistantMessageEventStream();
      queueMicrotask(() => {
        const message: AssistantMessage = {
          role: "assistant",
          content: call
            ? [
                {
                  type: "toolCall",
                  id: `read-${Date.now()}`,
                  name: "bash",
                  arguments: { command: call },
                },
              ]
            : [{ type: "text", text: "OK" }],
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
          stopReason: call ? "toolUse" : "stop",
          timestamp: Date.now(),
        };
        stream.push({ type: "done", reason: call ? "toolUse" : "stop", message });
        stream.end();
      });
      return stream;
    },
  });
}
