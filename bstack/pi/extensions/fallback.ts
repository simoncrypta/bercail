import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isContextOverflow, type AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const profile = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const efforts = /[#:]((?:off|minimal|low|medium|high|xhigh|max))$/;

function read(name: string): string | undefined {
  try {
    return readFileSync(resolve(profile, name), "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
}

export default function (pi: ExtensionAPI) {
  const attempted = new Set<string>();
  let response: { status: number; rejected: boolean } | undefined;
  let assistant: AssistantMessage | undefined;

  const noteSession = (model: string) => {
    if (!process.env.HC_TERMINAL_ID) return;
    const current = pi.getSessionName();
    const note = current ? `${current.replace(/ · fallback .*$/, "")} · fallback ${model.split("/")[0]}` : `fallback: ${model}`;
    pi.setSessionName(note);
  };

  pi.on("message_start", (event, ctx) => {
    if (event.message.role !== "user") return;
    attempted.clear();
    ctx.ui.setStatus("bercail-fallback", undefined);
  });
  pi.on("turn_start", () => {
    response = undefined;
    assistant = undefined;
  });
  pi.on("after_provider_response", (event) => {
    response = {
      status: event.status,
      rejected: event.headers["anthropic-ratelimit-unified-status"] === "rejected",
    };
  });
  pi.on("turn_end", (event) => {
    assistant = event.message.role === "assistant" ? event.message : undefined;
  });

  pi.on("agent_before_settle", async (event, ctx) => {
    if (event.outcome !== "error" || assistant?.stopReason !== "error" || ctx.signal?.aborted) return;
    const error = assistant.errorMessage ?? "";
    if (response && [400, 401, 403].includes(response.status)) return;
    if (isContextOverflow(assistant, ctx.model?.contextWindow)) return;
    // Explicit request errors win over transport signals, including bridge headers.
    if (/\b(?:400|401|403)\b|unauthenticated|unauthorized|not.authorized|authenticat|invalid.api.key|permission.denied|access.denied|forbidden|invalid_request_error|bad.request|context.{0,30}(?:overflow|length|window|exceed|limit)|prompt.{0,20}(?:too.long|exceed)|too.many.tokens|request.{0,10}abort/i.test(error)) return;
    if (!(response?.status === 429 || response?.rejected || /\b429\b|rate[_ -]?limit|usage[_ -]?limit|usage cap|quota (?:exceeded|exhausted)|hit your limit|out of (?:usage|credits)/i.test(error))) return;

    const current = `${assistant.provider}/${assistant.model}`;
    attempted.add(current);
    const models = new Map((read("models") ?? "").split(/\r?\n/).flatMap<[string, string]>((line) => {
      const index = line.indexOf("=");
      return index > 0 ? [[line.slice(0, index).trim(), line.slice(index + 1).trim()]] : [];
    }));
    const order = (read("fallback") ?? "claude\ngpt\ngrok").split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
    const skipped: string[] = [];
    for (const family of order) {
      const configured = models.get(family);
      if (!configured) { skipped.push(`${family}: no model`); continue; }
      const effort = configured.match(efforts)?.[1];
      const name = configured.replace(efforts, "");
      if (attempted.has(name)) continue;
      attempted.add(name);
      const slash = name.indexOf("/");
      const model = slash > 0 ? ctx.modelRegistry.find(name.slice(0, slash), name.slice(slash + 1)) : undefined;
      if (!model) { skipped.push(`${name}: unavailable`); continue; }
      if (model.provider === "claude-bridge") {
        // The bridge's dummy API key makes setModel succeed even without a Claude login.
        try {
          const auth = await pi.exec("env", ["-u", "ANTHROPIC_API_KEY", "-u", "ANTHROPIC_BASE_URL", "-u", "ANTHROPIC_AUTH_TOKEN", "claude", "auth", "status", "--json"], { signal: ctx.signal, timeout: 5000 });
          const login = auth.code === 0 ? JSON.parse(auth.stdout) : undefined;
          if (login?.loggedIn !== true || !["claude.ai", "oauth_token"].includes(login.authMethod)) {
            skipped.push(`${name}: no Claude subscription login`);
            continue;
          }
        } catch {
          if (ctx.signal?.aborted) return;
          skipped.push(`${name}: Claude login unavailable`);
          continue;
        }
      }
      if (ctx.signal?.aborted) return;
      if (!(await pi.setModel(model))) { skipped.push(`${name}: no login`); continue; }
      if (effort) pi.setThinkingLevel(effort as Parameters<typeof pi.setThinkingLevel>[0]);
      const text = `Rate limit: switched ${current} → ${name}. Continuing the same request.`;
      ctx.ui.setStatus("bercail-fallback", `fallback: ${name}`);
      ctx.ui.notify(text, "warning");
      noteSession(name);
      const failed = [...event.context.contextEntries].reverse().find((entry) => entry.messages.some((message) => message.role === "assistant" && message.stopReason === "error") && entry.sourceEntry.type === "message");
      // Omit the empty error assistant. A later provider 400s on it and then looks like a non-limit failure.
      return {
        entries: [...event.entries,
          ...(failed ? [{ type: "context_edit" as const, targetId: failed.sourceEntry.id, replacement: null }] : []),
          { type: "custom_message" as const, customType: "bercail-fallback", content: text, display: true, details: { from: current, to: name, skipped } },
        ],
        continue: true,
      };
    }
    const text = `Rate limit: fallback exhausted (${order.join(" → ") || "no candidates"}). All configured models are limited or unavailable.${skipped.length ? ` ${skipped.join("; ")}.` : ""}`;
    ctx.ui.setStatus("bercail-fallback", "fallback exhausted");
    ctx.ui.notify(text, "error");
    return { entries: [...event.entries, { type: "custom" as const, customType: "bercail-fallback-error", data: { text, attempted: [...attempted], skipped } }], continue: false };
  });
}
