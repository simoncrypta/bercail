// Loaded by the installed Pi binary: no provider SDK mocks and no network calls.
import { appendFileSync } from "node:fs";
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const scenario = process.env.PI_FALLBACK_CASE!;
const log = (data: unknown) => appendFileSync(process.env.PI_FALLBACK_LOG!, JSON.stringify(data) + "\n");
export default function (pi: ExtensionAPI) {
  let calls = 0;
  let toolSent = false;
  let userTurns = 0;
  pi.on("before_agent_start", () => { userTurns++; });
  pi.registerTool({
    name: "fallback_test_tool", label: "Fallback test", description: "Offline test tool",
    parameters: { type: "object", properties: {} } as any,
    async execute() {
      log({ type: "tool" });
      if (scenario === "user-reset" || scenario === "followup-reset") {
        pi.sendUserMessage("Second real user turn", { deliverAs: scenario === "user-reset" ? "steer" : "followUp" });
      }
      return { content: [{ type: "text", text: "offline tool result" }], details: {} };
    },
  });
  for (const provider of ["fake-a", "fake-b", "fake-c", "fake-unlogged", "claude-bridge"]) {
    pi.registerProvider(provider, {
      api: "pi-fallback-test", baseUrl: "http://invalid.invalid",
      apiKey: provider === "fake-unlogged" ? "$PI_FALLBACK_MISSING_KEY" : "offline-test-key",
      models: [{ id: "model", name: provider, reasoning: true, input: ["text"], contextWindow: 200000, maxTokens: 1000, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
      streamSimple(model, context, options) {
        const stream = createAssistantMessageEventStream();
        queueMicrotask(async () => {
          calls++;
          const first = model.provider === "fake-a";
          let error = first ? "429 rate_limit_error" : undefined;
          let status = first ? 429 : 200;
          let headers: Record<string, string> = {};
          if (scenario === "exhaustion") error = "429 rate_limit_error";
          if (first && scenario === "401") { error = "401 authentication failed; rate_limit_error"; status = 401; }
          if (first && scenario.startsWith("status-only-")) { error = "invalid rate_limit configuration"; status = Number(scenario.slice(12)); headers = { "anthropic-ratelimit-unified-status": "rejected" }; }
          if (first && scenario === "500") { error = "500 unrelated server failure"; status = 500; }
          if (first && scenario === "403") { error = "403 forbidden"; status = 403; }
          if (first && scenario === "400") { error = "400 invalid request"; status = 400; }
          if (first && scenario === "context") { error = "context overflow: usage limit"; status = 200; }
          if (first && scenario === "usage") { error = "You have hit your usage limit"; status = 200; }
          if (first && scenario === "bridge") { error = "Claude Code turn failed"; status = 200; headers = { "anthropic-ratelimit-unified-status": "rejected" }; }
          if (first && scenario === "bridge-auth") { error = "401 authentication failed"; status = 200; headers = { "anthropic-ratelimit-unified-status": "rejected" }; }
          if (first && scenario === "bridge-success") { error = undefined; status = 200; headers = { "anthropic-ratelimit-unified-status": "rejected" }; }
          if (first && scenario === "bridge-warning") { error = "unrelated failure"; status = 200; headers = { "anthropic-ratelimit-unified-status": "allowed_warning", "anthropic-ratelimit-unified-5h-utilization": "1" }; }
          if (first && scenario === "retry-success" && calls > 1) { error = undefined; status = 200; }
          if (first && scenario === "stale") { error = calls === 1 ? "429 rate_limit_error" : "unrelated failure"; status = calls === 1 ? 429 : 200; }
          const toolScenario = ["tool-no-loop", "user-reset", "followup-reset"].includes(scenario);
          const emitTool = toolScenario && model.provider === "fake-b" && !toolSent;
          if (toolScenario && model.provider === "fake-b") { error = emitTool ? undefined : "429 rate_limit_error"; }
          if (["user-reset", "followup-reset"].includes(scenario) && first && toolSent) error = undefined;
          if (scenario === "new-user-reset") {
            if (userTurns === 1 && !first) error = undefined;
            if (userTurns === 2) error = first ? undefined : "429 rate_limit_error";
          }
          log({ type: "request", provider: model.provider, calls, reasoning: options?.reasoning, at: Date.now(), messages: context.messages });
          // The stale case deliberately omits the next response hook entirely.
          if (!(scenario === "stale" && calls > 1)) await options?.onResponse?.({ status, headers }, model);
          const output: any = { role: "assistant", content: error ? [] : [{ type: "text", text: "PI_FALLBACK_OK" }], api: model.api, provider: model.provider, model: model.id, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: error ? "error" : "stop", timestamp: Date.now(), ...(error ? { errorMessage: error } : {}) };
          if (emitTool) {
            toolSent = true;
            output.stopReason = "toolUse";
            output.content = [{ type: "toolCall", id: "offline-call", name: "fallback_test_tool", arguments: {} }];
          }
          if (scenario === "abort" && first) output.stopReason = "aborted";
          stream.push(error ? { type: "error", reason: output.stopReason, error: output } : { type: "done", reason: output.stopReason, message: output });
          stream.end();
        });
        return stream;
      },
    });
  }
  for (const name of ["message_start", "before_agent_start", "agent_start", "turn_start", "turn_end", "agent_before_settle", "agent_settled", "model_select"] as const) {
    pi.on(name as any, (event: any, ctx: any) => {
      log({ type: "event", event: name, outcome: event.outcome, role: event.message?.role, continue: event.continue, model: ctx.model?.provider, aborted: event.aborted });
      if (name === "agent_settled" && process.env.PI_FALLBACK_TUI_SHUTDOWN) ctx.shutdown();
    });
  }
}
