// Offline provider for review.ts's live proof. No network.
//   "READ <path>"  calls read on the path, then answers with what came back.
//   "HOLD"         answers only when aborted.
//   anything else  answers "REVIEW_OK <prompt>".
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

function textOf(message: any): string {
  const c = message?.content;
  if (typeof c === "string") return c;
  if (Array.isArray(c)) return c.map((p) => (typeof p?.text === "string" ? p.text : "")).join("\n");
  return "";
}

export default function (pi: ExtensionAPI) {
  pi.registerProvider("fake-review", {
    api: "review-pi-test",
    baseUrl: "http://invalid.invalid",
    apiKey: "offline-test-key",
    models: [
      {
        id: "model",
        name: "review",
        reasoning: false,
        input: ["text"],
        contextWindow: 200000,
        maxTokens: 1000,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      },
    ],
    streamSimple(model, context, options) {
      const stream = createAssistantMessageEventStream();
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
      const last = context.messages[context.messages.length - 1] as any;
      const say = (text: string) => {
        stream.push({
          type: "done",
          reason: "stop",
          message: { ...base, stopReason: "stop", content: [{ type: "text", text }] },
        });
        stream.end();
      };
      queueMicrotask(() => {
        if (last?.role === "toolResult") return say(`TOOL_RESULT ${textOf(last)}`);
        const prompt = textOf(last).trim();
        const read = prompt.match(/^READ (.+)$/);
        if (read) {
          stream.push({
            type: "done",
            reason: "toolUse",
            message: {
              ...base,
              stopReason: "toolUse",
              content: [{ type: "toolCall", id: "review-read", name: "read", arguments: { path: read[1] } }],
            },
          });
          stream.end();
          return;
        }
        if (prompt === "HOLD") {
          const stop = () => {
            stream.push({
              type: "error",
              reason: "aborted",
              error: { ...base, stopReason: "aborted", errorMessage: "aborted", content: [] },
            });
            stream.end();
          };
          if (options?.signal?.aborted) return stop();
          options?.signal?.addEventListener("abort", stop, { once: true });
          return;
        }
        say(`REVIEW_OK ${prompt}`);
      });
      return stream;
    },
  });
}
