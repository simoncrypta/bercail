// Loaded by the installed Pi binary for Shep's compaction live proof: a model
// with no network. It reports usage as the context's characters / 4, so Pi's
// threshold sees the context grow. "medium" gets an answer long enough to
// compact, "big" one that crosses the threshold; a compaction request gets
// fixed decisions; anything else is echoed.
import { type AssistantMessage, createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

function textOf(message: any): string {
  const c = message?.content;
  if (typeof c === "string") return c;
  if (Array.isArray(c))
    return c
      .map((p) => (typeof p?.text === "string" ? p.text : typeof p?.thinking === "string" ? p.thinking : ""))
      .join("\n");
  return "";
}

export default function (pi: ExtensionAPI) {
  pi.registerProvider("fake", {
    api: "shep-context",
    baseUrl: "http://invalid.invalid",
    apiKey: "offline-test-key",
    models: [
      {
        id: "model",
        name: "fake",
        reasoning: false,
        input: ["text"],
        contextWindow: 64000,
        maxTokens: 32000,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      },
    ],
    streamSimple(model, context) {
      const stream = createAssistantMessageEventStream();
      const last = textOf(context.messages[context.messages.length - 1]).trim();
      let text: string;
      if (last.includes("You are compacting the conversation of Shep")) {
        text = "### Decisions\n- LIVE-DECISION: ship live-1 once reviewed\n### Open questions\n- none";
      } else if (last === "medium") {
        text = "Shep medium: " + "lorem ipsum dolor sit amet ".repeat(600);
      } else if (last === "big") {
        text = "Shep big: " + "lorem ipsum dolor sit amet ".repeat(4000);
      } else {
        text = `Shep ok: ${last.slice(0, 40).replace(/\s+/g, " ")}`;
      }
      // Pi 1.5 hands a transcript with no systemPrompt: kept as the proof's thresholds were set.
      const chars =
        ((context as { systemPrompt?: string }).systemPrompt ?? "").length +
        context.messages.reduce((n, m) => n + textOf(m).length, 0);
      const input = Math.ceil(chars / 4),
        output = Math.ceil(text.length / 4);
      queueMicrotask(() => {
        const message: AssistantMessage = {
          role: "assistant",
          content: [{ type: "text", text }],
          api: model.api,
          provider: model.provider,
          model: model.id,
          usage: {
            input,
            output,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: input + output,
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
