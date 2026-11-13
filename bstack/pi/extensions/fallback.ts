import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isContextOverflow, type AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

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
  const tellParent = async (text: string) => {
    const role = process.env.BERCAIL_ROLE;
    const me = process.env.HC_TERMINAL_ID;
    if (!role || !me) return;
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

  pi.on("session_start", (_event, ctx) => {
    if (ctx.model) desk = { name: `${ctx.model.provider}/${ctx.model.id}`, level: pi.getThinkingLevel() };
  });
  // A switch the person makes moves the desk; the fallback's own do not.
  pi.on("model_select", (event) => {
    if (!switching && desk) desk.name = `${event.model.provider}/${event.model.id}`;
  });
  pi.on("thinking_level_select", (event) => {
    if (!switching && desk) desk.level = event.level;
  });
  // Back to the desk's model once its limit has lifted, before the next request.
  const restore = async (ctx: any) => {
    if (!desk || !ctx.model) return;
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
    await restore(ctx);
  });
  pi.on("turn_start", async (_event, ctx) => {
    response = undefined;
    rejection = undefined;
    assistant = undefined;
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
  pi.on("turn_end", (event) => {
    assistant = event.message.role === "assistant" ? event.message : undefined;
  });

  pi.on("agent_before_settle", async (event, ctx) => {
    if (event.outcome !== "error" || assistant?.stopReason !== "error" || ctx.signal?.aborted) return;
    const error = assistant.errorMessage ?? "";
    if (response && [400, 401, 403].includes(response.status)) return;
    if (isContextOverflow(assistant, ctx.model?.contextWindow)) return;
    // Explicit request errors win over transport signals, including bridge headers.
    if (
      /\b(?:400|401|403)\b|unauthenticated|unauthorized|not.authorized|authenticat|invalid.api.key|permission.denied|access.denied|forbidden|invalid_request_error|bad.request|context.{0,30}(?:overflow|length|window|exceed|limit)|prompt.{0,20}(?:too.long|exceed)|too.many.tokens|request.{0,10}abort/i.test(
        error,
      )
    )
      return;
    // No credits or no subscription does not reset on its own: skip it for the session.
    const isDead =
      response?.status === 402 ||
      /\b402\b|payment.required|out of credits|insufficient.(?:credits|balance|funds)|need an? [\w-]+(?: [\w-]+)? subscription|no active subscription/i.test(
        error,
      );
    if (
      !isDead &&
      !(
        response?.status === 429 ||
        response?.rejected ||
        /\b429\b|rate[_ -]?limit|usage[_ -]?limit|usage cap|quota (?:exceeded|exhausted)|hit your limit|out of usage/i.test(
          error,
        )
      )
    )
      return;

    const current = `${assistant.provider}/${assistant.model}`;
    attempted.add(current);
    if (isDead) {
      const reason = error.replace(/\s+/g, " ").slice(0, 160);
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
    await tellParent(text);
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
