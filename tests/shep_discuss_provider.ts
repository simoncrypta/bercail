// Loaded by the installed Pi for the Discuss live proof: a model with no network.
// Its first turn asks for bash (`hc send`); every turn writes what Pi sent it (tools,
// system prompt, messages) to $SHEP_DISCUSS_SEEN, one JSON line per turn. Pi 1.5 folds
// the system prompt and tools into system messages (sections, toolsAdded).
import { type AssistantMessage, createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync } from "node:fs";

const textOf = (m: any): string =>
  typeof m?.content === "string"
    ? m.content
    : Array.isArray(m?.content)
      ? m.content.map((p: any) => p?.text ?? `[${p?.type}]`).join(" ")
      : "";

export default function (pi: ExtensionAPI) {
  let turn = 0;
  pi.registerProvider("fake-discuss", {
    api: "shep-discuss",
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
      turn++;
      const system = context.messages.filter((m: any) => m.role === "system") as any[];
      appendFileSync(
        process.env.SHEP_DISCUSS_SEEN!,
        JSON.stringify({
          tools: system
            .flatMap((m) => (m.toolsAdded ?? []).map((t: any) => String(t.name ?? t)))
            .sort((a, b) => a.localeCompare(b)),
          system: JSON.stringify(system),
          messages: context.messages.filter((m: any) => m.role !== "system").map((m) => [m.role, textOf(m)]),
        }) + "\n",
      );
      const stream = createAssistantMessageEventStream();
      queueMicrotask(() => {
        const ask = turn === 1;
        const message: AssistantMessage = {
          role: "assistant",
          content: ask
            ? [{ type: "toolCall", id: "call-1", name: "bash", arguments: { command: "hc send t1 merge-it" } }]
            : [{ type: "text", text: "A is smaller; B is safer." }],
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
          stopReason: ask ? "toolUse" : "stop",
          timestamp: Date.now(),
        };
        stream.push({ type: "done", reason: ask ? "toolUse" : "stop", message });
        stream.end();
      });
      return stream;
    },
  });
}
