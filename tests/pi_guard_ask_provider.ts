// Offline provider for the guard-ask live proof (tests/pi_guard_ask_live.ts). No network.
// A user message "RUN <command>" makes one bash call; anything else, a tool result or
// an inbox event included, comes back as "ECHO <text>", so the proof reads what reached
// the model and when.
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const textOf = (message: any): string =>
  typeof message?.content === "string"
    ? message.content
    : (message?.content ?? []).map((part: any) => part.text ?? "").join("\n");

export default function (pi: ExtensionAPI) {
  let calls = 0;
  pi.registerProvider("fake-shep", {
    api: "guard-ask-proof",
    apiKey: "offline-test-key",
    baseUrl: "http://invalid.invalid",
    models: [
      {
        id: "model",
        name: "offline guard-ask proof",
        reasoning: false,
        input: ["text"],
        contextWindow: 200000,
        maxTokens: 1000,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      },
    ],
    streamSimple(model, context) {
      const stream = createAssistantMessageEventStream();
      const last = context.messages.at(-1) as any;
      const text = textOf(last);
      queueMicrotask(() => {
        const base = {
          role: "assistant" as const,
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
          timestamp: Date.now(),
        };
        const run = last?.role === "user" && text.startsWith("RUN ");
        stream.push(
          run
            ? {
                type: "done",
                reason: "toolUse",
                message: {
                  ...base,
                  stopReason: "toolUse",
                  content: [
                    { type: "toolCall", id: `call-${++calls}`, name: "bash", arguments: { command: text.slice(4) } },
                  ],
                },
              }
            : {
                type: "done",
                reason: "stop",
                message: { ...base, stopReason: "stop", content: [{ type: "text", text: `ECHO ${text}` }] },
              },
        );
        stream.end();
      });
      return stream;
    },
  });
}
