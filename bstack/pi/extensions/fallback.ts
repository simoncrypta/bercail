import { appendFileSync, mkdirSync, readFileSync, writeFileSync, renameSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isContextOverflow, type AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { classifyProviderError, providerEventReason, type ProviderErrorReason } from "./provider-error.ts";

type Level = ReturnType<ExtensionAPI["getThinkingLevel"]>;

const profile = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const efforts = /[#:](?:off|minimal|low|medium|high|xhigh|max)$/;
// Claude plan windows every model on the plan shares. Any other claim
// (seven_day_opus) limits one model, so another model on the plan can still run.
const planWindows = new Set(["five_hour", "seven_day", "seven_day_overage_included", "overage"]);
// A limit that names no reset: try the desk's own model again after this long.
const unknownReset = 5 * 60_000;
// Dead providers, one JSON line each, for bercail doctor.
const deadLog = join(process.env.XDG_STATE_HOME || join(homedir(), ".local/state"), "bercail/fallback-dead.jsonl");

function read(name: string): string | undefined {
  try {
    return readFileSync(resolve(profile, name), "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
}

const clock = (ms: number) => new Date(ms).toTimeString().slice(0, 5);

export default function (pi: ExtensionAPI) {
  // The desk's own model and thinking level: what it started with, or what the person picked since.
  let desk: { name: string; level: Level } | undefined;
  let switching = false;
  // Models tried since the last user message, so one request never loops.
  const attempted = new Set<string>();
  // provider, or provider/model for a one-model window → when it lifts.
  const limited = new Map<string, number>();
  // provider → why, for the rest of the session: no credits or no subscription.
  const dead = new Map<string, string>();
  let response: { status: number; rejected: boolean } | undefined;
  let rejection: { claim?: string; reset?: number } | undefined;
  let assistant: AssistantMessage | undefined;
  let structuredReason: ProviderErrorReason | undefined;
  type Failure = {
    reason: ProviderErrorReason;
    completion: "incomplete";
    episode_id: string;
    attempt_id: string;
    session_id: string;
    provider: string;
    model: string;
    role: string;
    phase: string;
    candidate: string;
    issue?: string;
    issue_title?: string;
    evidence: { source: string; status?: number; message_entry_id: string; response_id?: string };
  };
  let safety: Failure | undefined;
  let latestFailure: Failure | undefined;
  let labels: Record<string, string> = {};
  const token = (value: string | undefined) => (value && /^[\w./:@#-]{1,200}$/.test(value) ? value : undefined);
  const noticed = new Set<string>();
  const attempts = new Set<string>();
  const binding = () => ({
    role: token(process.env.BERCAIL_ROLE) ?? "lead",
    phase: token(labels["bercail.phase"] ?? process.env.BERCAIL_PHASE ?? process.env.BERCAIL_STAGE) ?? "unknown",
    candidate: token(labels["bercail.candidate"] ?? process.env.BERCAIL_CANDIDATE) ?? "unknown",
    issue: token(labels["bercail.issue"] ?? process.env.BERCAIL_ISSUE),
    issue_title: (labels["bercail.issue_title"] ?? process.env.BERCAIL_ISSUE_TITLE)
      ?.replace(/[\r\n\t]/g, " ")
      .slice(0, 160),
  });
  const episode = (ctx: ExtensionContext) => {
    const user = [...ctx.sessionManager.getBranch()]
      .reverse()
      .find((entry) => entry.type === "message" && entry.message.role === "user");
    return `${ctx.sessionManager.getSessionId()}:${user?.id ?? "unknown"}`;
  };
  const restoreFailures = (ctx: ExtensionContext) => {
    safety = undefined;
    latestFailure = undefined;
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type !== "custom") continue;
      if (entry.customType === "bercail-provider-notice")
        noticed.add((entry.data as { episode_id: string }).episode_id);
      if (entry.customType !== "bercail-provider-error") continue;
      const failure = entry.data as Failure;
      attempts.add(failure.attempt_id);
      if (failure.episode_id !== episode(ctx)) continue;
      latestFailure = failure;
      if (failure.reason === "provider_safety_block") safety = failure;
    }
  };
  const recordFailure = (message: AssistantMessage, entryId: string, ctx: ExtensionContext) => {
    const reason = classifyProviderError(message, { ...response, reason: structuredReason });
    if (!reason) {
      latestFailure = undefined;
      return;
    }
    const failure: Failure = {
      ...binding(),
      reason,
      completion: "incomplete",
      episode_id: episode(ctx),
      attempt_id: entryId,
      session_id: ctx.sessionManager.getSessionId(),
      provider: message.provider,
      model: message.model,
      evidence: {
        source: structuredReason ? "provider_code" : "assistant_message",
        status: response?.status,
        message_entry_id: entryId,
        response_id: token(message.responseId),
      },
    };
    latestFailure = failure;
    if (reason === "provider_safety_block") safety = failure;
    if (attempts.has(entryId)) return;
    attempts.add(entryId);
    pi.appendEntry("bercail-provider-error", failure);
  };
  const stopFailure = async (failure: Failure, ctx: ExtensionContext) => {
    const { reason, role, phase, candidate, issue, issue_title, session_id, episode_id } = failure;
    const job = issue ? `${issue}: ${issue_title || "title unknown"}; ` : "job unknown; ";
    const recovery =
      reason === "provider_safety_block"
        ? "Human review of legitimate scope/authorization or the provider access/review process is needed. Do not replay, rewrite, switch models, or substitute parent approval."
        : "Human attention is needed; no automatic continuation for this stop.";
    const review = /judge|council/.test(role)
      ? " Unfinished review cannot approve shipping or be replaced by parent self-approval."
      : "";
    const text = `${job}${role} ${process.env.HC_TERMINAL_ID ?? "headless"} stopped: ${reason}; phase ${phase}; candidate ${candidate}; session ${session_id}; episode ${episode_id}. Work is incomplete; prior evidence retains its original candidate. ${recovery}${review}`;
    ctx.ui.setStatus("bercail-fallback", `${reason}: incomplete`);
    ctx.ui.notify(text, "error");
    // Print-mode JSON does not emit custom session entries. Preserve structured stops in its existing result.
    const result = process.env.BERCAIL_RESULT_PATH;
    if (result && process.env.BERCAIL_SESSION_ID === session_id) {
      try {
        let current = {};
        try {
          current = JSON.parse(readFileSync(result, "utf8"));
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        }
        mkdirSync(dirname(result), { recursive: true });
        writeFileSync(
          `${result}.tmp`,
          JSON.stringify({
            ...current,
            status: "blocked",
            summary: text,
            session_id,
            completion: "incomplete",
            provider_error: failure,
          }),
          { mode: 0o600 },
        );
        renameSync(`${result}.tmp`, result);
      } catch {
        ctx.ui.notify("Could not project provider stop to the handoff result; session evidence is retained.", "error");
      }
    }
    if (!noticed.has(episode_id) && process.env.BERCAIL_ROLE && process.env.HC_TERMINAL_ID) {
      // Claim before external delivery: restart cannot send this episode twice. A crash here may lose the notice.
      pi.appendEntry("bercail-provider-notice", { episode_id, reason, completion: "incomplete" });
      noticed.add(episode_id);
      try {
        const self = await pi.exec("hc", ["get", process.env.HC_TERMINAL_ID, "--json"], { timeout: 5000 });
        const parent = self.code === 0 ? JSON.parse(self.stdout).parent : undefined;
        if (parent) await pi.exec("hc", ["send", parent, text], { timeout: 5000 });
      } catch {
        // Durable failure evidence remains in the session even when parent delivery is unavailable.
      }
    }
  };

  const blocked = (name: string) => {
    const provider = name.split("/")[0];
    if (dead.has(provider)) return `dead (${dead.get(provider)})`;
    const until = Math.max(limited.get(provider) ?? 0, limited.get(name) ?? 0);
    return until > Date.now() ? `limited until ${clock(until)}` : undefined;
  };

  const find = (ctx: { modelRegistry: { find(provider: string, id: string): any } }, name: string) => {
    const slash = name.indexOf("/");
    return slash > 0 ? ctx.modelRegistry.find(name.slice(0, slash), name.slice(slash + 1)) : undefined;
  };

  // Pi's setModel resets thinking to its default level; put the desk's back.
  const switchTo = async (model: any) => {
    switching = true;
    try {
      if (!(await pi.setModel(model))) return false;
      if (desk) pi.setThinkingLevel(desk.level);
      return true;
    } finally {
      switching = false;
    }
  };

  // The desk's status line is its session name: say when it runs elsewhere and what is dead.
  const noteSession = (model: string) => {
    if (!process.env.HC_TERMINAL_ID) return;
    const base = (pi.getSessionName() ?? "").replace(/^(?:fallback|dead): .*$| · (?:fallback|dead) .*$/, "");
    const away = model !== desk?.name;
    const parts = [
      ...(away ? [base ? `fallback ${model.split("/")[0]}` : `fallback: ${model}`] : []),
      ...(dead.size ? [`dead${base || away ? "" : ":"} ${[...dead.keys()].join(",")}`] : []),
    ];
    pi.setSessionName([base, ...parts].filter(Boolean).join(" · "));
  };

  // A sibling role that runs out of models tells the agent that started it.
  const tellParent = async (text: string, ctx: ExtensionContext) => {
    const role = process.env.BERCAIL_ROLE;
    const me = process.env.HC_TERMINAL_ID;
    if (!role || !me) return;
    if (/judge|council/.test(role) && latestFailure) {
      await stopFailure(latestFailure, ctx);
      return;
    }
    try {
      const self = await pi.exec("hc", ["get", me, "--json"], { timeout: 5000 });
      const parent = self.code === 0 ? JSON.parse(self.stdout).parent : undefined;
      if (parent)
        await pi.exec("hc", ["send", parent, `${role} ${me} stopped: ${text} Do this part yourself.`], {
          timeout: 5000,
        });
    } catch {
      // The parent is gone or hc is missing; the desk's own status still says why.
    }
  };

  pi.on("session_start", async (_event, ctx) => {
    if (process.env.HC_TERMINAL_ID) {
      try {
        const self = await pi.exec("hc", ["get", process.env.HC_TERMINAL_ID, "--json"], { timeout: 5000 });
        if (self.code === 0) labels = JSON.parse(self.stdout).labels ?? {};
      } catch {
        // Unknown ownership stays explicit rather than inferred from provider text.
      }
    }
    if (ctx.model) desk = { name: `${ctx.model.provider}/${ctx.model.id}`, level: pi.getThinkingLevel() };
    restoreFailures(ctx);
  });
  pi.on("session_tree", (_event, ctx) => restoreFailures(ctx));
  // A switch the person makes moves the desk; the fallback's own do not.
  pi.on("model_select", (event) => {
    if (!switching && desk) desk.name = `${event.model.provider}/${event.model.id}`;
  });
  pi.on("thinking_level_select", (event) => {
    if (!switching && desk) desk.level = event.level;
  });
  // Back to the desk's model once its limit has lifted, before the next request.
  const restore = async (ctx: any) => {
    if (safety || !desk || !ctx.model) return;
    const from = `${ctx.model.provider}/${ctx.model.id}`;
    if (from === desk.name || attempted.has(desk.name) || blocked(desk.name)) return;
    const model = find(ctx, desk.name);
    if (!model || !(await switchTo(model))) return;
    const text = `Limit lifted: back to ${desk.name} (thinking ${desk.level}) from ${from}.`;
    ctx.ui.setStatus("bercail-fallback", undefined);
    ctx.ui.notify(text, "info");
    noteSession(desk.name);
    pi.appendEntry("bercail-fallback-restore", { from, to: desk.name, thinking: desk.level, text });
  };
  // A user message starts after its turn_start, so it restores too.
  pi.on("message_start", async (event, ctx) => {
    if (event.message.role !== "user") return;
    attempted.clear();
    safety = undefined;
    latestFailure = undefined;
    await restore(ctx);
  });
  pi.on("turn_start", async (_event, ctx) => {
    response = undefined;
    rejection = undefined;
    assistant = undefined;
    structuredReason = undefined;
    await restore(ctx);
  });
  pi.on("after_provider_response", (event) => {
    const rejected = event.headers["anthropic-ratelimit-unified-status"] === "rejected";
    response = { status: event.status, rejected };
    const reset =
      Number(event.headers["anthropic-ratelimit-unified-reset"]) * 1000 ||
      Date.now() + Number(event.headers["retry-after"]) * 1000;
    if (rejected || event.status === 429) {
      rejection = {
        claim: event.headers["anthropic-ratelimit-unified-representative-claim"],
        reset: Number.isFinite(reset) ? reset : undefined,
      };
    }
  });
  pi.on("provider_stream_event", (event) => {
    const reason = providerEventReason(event.data);
    if (reason && structuredReason !== "provider_safety_block") structuredReason = reason;
  });
  pi.on("turn_end", (event, ctx) => {
    assistant = event.message.role === "assistant" ? event.message : undefined;
    if (assistant) recordFailure(assistant, event.messageEntryId, ctx);
  });

  pi.on("agent_before_settle", async (event, ctx) => {
    if (ctx.signal?.aborted) return;
    // This is after Pi's native retries. A later native success must not erase an earlier safety stop.
    const failure = safety ?? latestFailure;
    if (failure && failure.reason !== "usage_limit") {
      await stopFailure(failure, ctx);
      return { continue: false };
    }
    if (event.outcome !== "error" || assistant?.stopReason !== "error" || failure?.reason !== "usage_limit") return;
    const error = assistant.errorMessage ?? "";
    if (isContextOverflow(assistant, ctx.model?.contextWindow)) return;
    // No credits or no subscription does not reset on its own: skip it for the session.
    const isDead =
      response?.status === 402 ||
      /\b402\b|payment.required|out of credits|insufficient.(?:credits|balance|funds)|need an? [\w-]+(?: [\w-]+)? subscription|no active subscription/i.test(
        error,
      );
    const current = `${assistant.provider}/${assistant.model}`;
    attempted.add(current);
    if (isDead) {
      const reason = "usage_limit: credits or subscription unavailable";
      const known = dead.has(assistant.provider);
      dead.set(assistant.provider, reason);
      if (!known) {
        ctx.ui.notify(`${assistant.provider} is dead for this session, skipping it: ${reason}`, "warning");
        try {
          mkdirSync(dirname(deadLog), { recursive: true });
          appendFileSync(
            deadLog,
            JSON.stringify({ at: new Date().toISOString(), provider: assistant.provider, model: current, reason }) +
              "\n",
          );
        } catch {
          // doctor only reads this; the fallback goes on without it.
        }
      }
    } else {
      // A plan window every model shares limits the provider; a one-model window, the model.
      const claim = rejection?.claim ?? error.match(/rate limit \((\w+)\)/)?.[1];
      const scope = claim && !planWindows.has(claim) ? current : assistant.provider;
      limited.set(
        scope,
        rejection?.reset && rejection.reset > Date.now() ? rejection.reset : Date.now() + unknownReset,
      );
    }

    const models = new Map(
      (read("models") ?? "").split(/\r?\n/).flatMap<[string, string]>((line) => {
        const index = line.indexOf("=");
        return index > 0 ? [[line.slice(0, index).trim(), line.slice(index + 1).trim()]] : [];
      }),
    );
    // Each line is a family (claude, gpt, grok) or a Pi model id.
    const order = (read("fallback") ?? "claude\ngpt\ngrok")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    const skipped = [`${current}: ${blocked(current)}`];
    for (const entry of order) {
      const configured = entry.includes("/") ? entry : models.get(entry);
      if (!configured) {
        skipped.push(`${entry}: no model`);
        continue;
      }
      const name = configured.replace(efforts, "");
      if (attempted.has(name)) continue;
      attempted.add(name);
      const why = blocked(name);
      if (why) {
        skipped.push(`${name}: ${why}`);
        continue;
      }
      const model = find(ctx, name);
      if (!model) {
        skipped.push(`${name}: unavailable`);
        continue;
      }
      if (model.provider === "claude-bridge") {
        // The bridge's dummy API key makes setModel succeed even without a Claude login.
        try {
          const auth = await pi.exec(
            "env",
            [
              "-u",
              "ANTHROPIC_API_KEY",
              "-u",
              "ANTHROPIC_BASE_URL",
              "-u",
              "ANTHROPIC_AUTH_TOKEN",
              "claude",
              "auth",
              "status",
              "--json",
            ],
            { signal: ctx.signal, timeout: 5000 },
          );
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
      if (!(await switchTo(model))) {
        skipped.push(`${name}: no login`);
        continue;
      }
      const text = `${isDead ? "Dead model" : "Rate limit"}: switched ${current} → ${name}. Continuing the same request.`;
      ctx.ui.setStatus(
        "bercail-fallback",
        `fallback: ${name}${dead.size ? ` · dead ${[...dead.keys()].join(",")}` : ""}`,
      );
      ctx.ui.notify(text, "warning");
      noteSession(name);
      const failed = [...event.context.contextEntries]
        .reverse()
        .find(
          (entry) =>
            entry.messages.some((message) => message.role === "assistant" && message.stopReason === "error") &&
            entry.sourceEntry.type === "message",
        );
      // Omit the empty error assistant. A later provider 400s on it and then looks like a non-limit failure.
      return {
        entries: [
          ...event.entries,
          ...(failed ? [{ type: "context_edit" as const, targetId: failed.sourceEntry.id, replacement: null }] : []),
          {
            type: "custom_message" as const,
            customType: "bercail-fallback",
            content: text,
            display: true,
            details: { from: current, to: name, skipped, dead: Object.fromEntries(dead) },
          },
        ],
        continue: true,
      };
    }
    const text = `Rate limit: fallback exhausted (${order.join(" → ") || "no candidates"}). No configured model can run now.${skipped.length ? ` ${skipped.join("; ")}.` : ""}`;
    ctx.ui.setStatus("bercail-fallback", "fallback exhausted");
    ctx.ui.notify(text, "error");
    noteSession(current);
    await tellParent(text, ctx);
    return {
      entries: [
        ...event.entries,
        {
          type: "custom" as const,
          customType: "bercail-fallback-error",
          data: { text, attempted: [...attempted], skipped, dead: Object.fromEntries(dead) },
        },
      ],
      continue: false,
    };
  });
}
