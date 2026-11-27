import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

export type ProviderErrorReason =
  | "provider_safety_block"
  | "auth_expired_or_denied"
  | "usage_limit"
  | "transient_transport"
  | "model_refusal"
  | "unknown_provider_error";

type Message = { role?: string; stopReason?: string; rawStopReason?: string; errorMessage?: string };
export type ProviderEvidence = { status?: number; rejected?: boolean; reason?: ProviderErrorReason };

// Only provider metadata and failed messages are evidence; never infer blocks from successful prose.
export function classifyProviderError(
  message: Message,
  response: ProviderEvidence = {},
): ProviderErrorReason | undefined {
  const failed = message.role === "assistant" && message.stopReason === "error";
  const raw = message.rawStopReason;
  if (
    response.reason === "provider_safety_block" ||
    ["content_filter", "incomplete.content_filter", "sensitive"].includes(raw ?? "")
  )
    return "provider_safety_block";
  if (!failed) return response.reason === "model_refusal" || raw === "refusal" ? "model_refusal" : undefined;
  const error = message.errorMessage ?? "";
  if (
    /content was flagged for possible cybersecurity risk|Provider stopped with: sensitive|\b(?:content_filter|content_policy_violation|safety_block)\b/i.test(
      error,
    )
  )
    return "provider_safety_block";
  if (
    response.status === 401 ||
    response.status === 403 ||
    /\b(?:401|403)\b|unauthenticated|unauthorized|not.authorized|authenticat|invalid.api.key|permission.denied|access.denied|forbidden/i.test(
      error,
    )
  )
    return "auth_expired_or_denied";
  if (response.reason === "model_refusal" || raw === "refusal" || /\bmodel_refusal\b/i.test(error))
    return "model_refusal";
  // pi-claude-cli's billing stop: a call was or would be charged to usage credits, so waiting or switching may spend more.
  if (/\bClaude billing:/.test(error)) return "unknown_provider_error";
  // Invalid requests and context overflow must not become quota opportunities through a wrapper/header.
  if (
    response.status === 400 ||
    /\b400\b|invalid_request_error|bad.request|context.{0,30}(?:overflow|length|window|exceed|limit)|prompt.{0,20}(?:too.long|exceed)|too.many.tokens|request.{0,10}abort|invalid.*(?:rate[_ -]?limit|quota)/i.test(
      error,
    )
  )
    return "unknown_provider_error";
  if (
    response.status === 402 ||
    response.status === 429 ||
    response.rejected ||
    /\b(?:402|429)\b|payment.required|out of credits|insufficient.(?:credits|balance|funds|quota)|need an? [\w-]+(?: [\w-]+)? subscription|no active subscription|\brate[_ -]?limit(?:[_ -]?(?:error|exceeded|reached))?\b|\busage[_ -]?limit\b|usage cap|quota (?:exceeded|exhausted)|hit your (?:[\w-]+ )?limit|You've hit your (?:5-hour|weekly|Opus|Sonnet|Fable) limit|You've reached your Fable limit|You're out of (?:usage credits|extra usage)|Third-party apps now draw from your extra usage, not your plan limits|You've reached your ChatGPT workspace's usage limit|out of usage|subscription_sharing_usage_limit_exceeded/i.test(
      error,
    )
  )
    return "usage_limit";
  if (
    (response.status !== undefined && response.status >= 500) ||
    /\b(?:500|502|503|504)\b|network.?error|connection.?(?:error|refused|lost|reset)|fetch failed|socket hang up|timed? out|timeout|ECONNRESET|ENOTFOUND|service.?(?:temporarily.?)?unavailable/i.test(
      error,
    )
  )
    return "transient_transport";
  return "unknown_provider_error";
}

// Read only known error-code/refusal slots, not arbitrary event text or request payloads.
export function providerEventReason(data: unknown): ProviderErrorReason | undefined {
  const event = data as {
    type?: string;
    error?: { code?: string; type?: string };
    response?: { error?: { code?: string } };
    delta?: { stop_reason?: string };
  } | null;
  const code = event?.error?.code ?? event?.error?.type ?? event?.response?.error?.code ?? event?.delta?.stop_reason;
  if (["content_filter", "content_policy_violation", "safety_block", "sensitive"].includes(code ?? ""))
    return "provider_safety_block";
  if (code === "refusal" || /^response\.refusal\.(?:delta|done)$/.test(event?.type ?? "")) return "model_refusal";
  return undefined;
}

// Headless Pi JSON output, not process exit 0, decides whether the unfinished phase is blocked.
export function providerErrorFromLog(
  log: string,
):
  | { reason: ProviderErrorReason; completion: "incomplete"; evidence: { source: string; event_index: number } }
  | undefined {
  let last: ReturnType<typeof providerErrorFromLog>;
  let safety: ReturnType<typeof providerErrorFromLog>;
  for (const [index, line] of log.split("\n").entries()) {
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }
    if (event?.type !== "message_end" || event.message?.role !== "assistant") continue;
    const reason = classifyProviderError(event.message);
    last = reason
      ? { reason, completion: "incomplete", evidence: { source: "start.log", event_index: index + 1 } }
      : undefined;
    if (reason === "provider_safety_block") safety = last;
  }
  // Native retry success cannot erase a safety block from this invocation.
  return safety ?? last;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href && process.argv[2] !== "--check") {
  const failure = providerErrorFromLog(readFileSync(process.argv[2], "utf8"));
  process.stdout.write(JSON.stringify(failure ?? null));
}
