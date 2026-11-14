// Loaded before inbox.ts by the offline real-Pi fault proof. Gates are file
// handshakes, not delays: the parent kills Pi only after observing the phase.
import { type AssistantMessage, createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { appendFileSync, existsSync, readFileSync, renameSync, watch, writeFileSync } from "node:fs";
import { join } from "node:path";
import { claim, TYPE } from "../shep/pi/inbox.ts";

export default function (pi: ExtensionAPI) {
  const control = process.env.INBOX_PROOF_CONTROL!;
  const mode = process.env.INBOX_PROOF_MODE!;
  const inbox = process.env.BERCAIL_SHEP_INBOX!;
  const delivered = join(inbox, "..", "delivered");
  const phase = (name: string, value: unknown = {}) => {
    const file = join(control, `${name}.json`);
    writeFileSync(`${file}.tmp`, JSON.stringify(value));
    renameSync(`${file}.tmp`, file);
  };
  const disk = (ctx: ExtensionContext): any[] => {
    const file = ctx.sessionManager.getSessionFile();
    return file && existsSync(file)
      ? readFileSync(file, "utf8")
          .split("\n")
          .filter(Boolean)
          .map((line) => JSON.parse(line))
      : [];
  };
  const park = (name: string, value: unknown) => {
    const release = join(control, `release-${name}`);
    return new Promise<void>((resolve, reject) => {
      const watcher = watch(control, () => {
        if (existsSync(release)) finish();
      });
      const timer = setTimeout(() => finish(new Error(`phase ${name} was not released or killed`)), 30000);
      const finish = (error?: Error) => {
        watcher.close();
        clearTimeout(timer);
        if (error) reject(error);
        else resolve();
      };
      phase(name, value);
      // Freeze the process, not just this handler: the inbox's scheduled disk
      // verifier must not acknowledge while the parent observes this cut.
      if (name !== "busy") process.kill(process.pid, "SIGSTOP");
      if (existsSync(release)) finish();
    });
  };
  const textOf = (message: any): string =>
    typeof message?.content === "string"
      ? message.content
      : (message?.content ?? []).map((part: any) => part.text ?? "").join("\n");

  pi.registerProvider("inbox-proof", {
    api: "inbox-proof",
    apiKey: "offline-fixture",
    baseUrl: "http://invalid.invalid",
    models: [
      {
        id: "model",
        name: "offline inbox proof",
        reasoning: false,
        input: ["text"],
        contextWindow: 32000,
        maxTokens: 200,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      },
    ],
    streamSimple(model, context) {
      const stream = createAssistantMessageEventStream();
      const text = textOf(context.messages.at(-1));
      const ids = [...text.matchAll(/\[event ([^\]]+)\]/g)].map((match) => match[1]);
      appendFileSync(join(control, "requests.jsonl"), `${JSON.stringify({ ids })}\n`);
      void (async () => {
        if (mode === "busy" && text === "HOLD") await park("busy", {});
        const message: AssistantMessage = {
          role: "assistant",
          api: model.api,
          provider: model.provider,
          model: model.id,
          content: [],
          stopReason: "pending",
          timestamp: Date.now(),
          usage: {
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: 0,
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
          },
        };
        stream.push({ type: "start", partial: message });
        stream.push({ type: "text_start", contentIndex: 0, partial: message });
        message.content.push({ type: "text", text: `Shep report: ${ids.join(", ")}` });
        stream.push({ type: "text_delta", contentIndex: 0, delta: `Shep report: ${ids.join(", ")}`, partial: message });
        stream.push({ type: "text_end", contentIndex: 0, content: `Shep report: ${ids.join(", ")}`, partial: message });
        message.stopReason = "stop";
        stream.push({ type: "done", reason: "stop", message });
        stream.end();
      })().catch((error) => {
        phase("error", { error: String(error) });
        process.exit(1);
      });
      return stream;
    },
  });

  pi.on("session_start", async (_event, ctx) => {
    if (mode === "claim") {
      const taken = claim(inbox, delivered);
      await park("claimed", { ids: taken.map((item) => item.ev.event_id) });
    }
    phase("started", { file: ctx.sessionManager.getSessionFile() });
  });
  pi.on("resources_discover", () => phase("ready"));
  pi.on("context", async (_event, ctx) => {
    if (mode !== "virgin") return;
    const entries = ctx.sessionManager.getEntries();
    if (!entries.some((entry) => entry.type === "custom_message" && entry.customType === TYPE)) return;
    await park("virgin", { file: ctx.sessionManager.getSessionFile(), disk: disk(ctx) });
  });
  pi.on("message_end", (event, ctx) => {
    if (event.message.role !== "custom" || event.message.customType !== TYPE) return;
    phase("message-end", { disk: disk(ctx) });
  });
  pi.on("turn_end", async (_event, ctx) => {
    if (mode !== "persisted") return;
    const entries = disk(ctx);
    if (!entries.some((entry) => entry.type === "custom_message" && entry.customType === TYPE)) return;
    await park("persisted", { file: ctx.sessionManager.getSessionFile(), entries });
  });
  pi.on("agent_settled", (_event, ctx) => {
    phase("settled", { file: ctx.sessionManager.getSessionFile(), entries: disk(ctx) });
  });
}
