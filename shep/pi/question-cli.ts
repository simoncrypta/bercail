import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { QuestionStore, projection, tokenOf, type QuestionSpec } from "./questions.ts";
import { captureTarget, checkQuestion } from "./question-target.ts";

async function main() {
  const state = process.env.BERCAIL_SHEP_STATE;
  if (!state?.trim()) throw new Error("set BERCAIL_SHEP_STATE to the question state directory");
  const [op, ...args] = process.argv.slice(2);
  const store = new QuestionStore(state);
  let result: unknown;
  if (op === "list") {
    console.log(projection(store.snapshot()));
    return;
  }
  if (op === "json") result = store.snapshot();
  else if (op === "thread") {
    if (args.length !== 1) throw new Error("thread requires a topic (or - to clear)");
    store.select(args[0] === "-" ? null : args[0]!);
    result = store.snapshot();
  } else if (op === "check") {
    if (args.length !== 1 || !/^Q[1-9]\d*@[1-9]\d*$/.test(args[0]!))
      throw new Error("check requires an explicit Qn@revision token");
    const question = store.snapshot().questions.find((q) => tokenOf(q) === args[0]);
    if (!question) throw new Error("unknown question revision");
    result = await checkQuestion(question);
  } else if (["create", "revise", "reply"].includes(op ?? "")) {
    if (args.length) throw new Error(`${op} reads JSON from stdin, not argv`);
    const input = JSON.parse(readFileSync(0, "utf8"));
    if (!input || typeof input !== "object" || Array.isArray(input)) throw new Error("expected a JSON object");
    if (op === "reply") {
      if (Object.keys(input).sort().join() !== "answer,requestId,source,token")
        throw new Error("reply fields must be requestId, token, answer and source only; no verification flags");
      result = store.propose(input.requestId, input.token, input.answer, input.source);
    } else {
      if (
        !input.origin ||
        !["event", "session"].every((key) => typeof input.origin[key] === "string" && input.origin[key].trim()) ||
        (input.origin.entry !== null && (typeof input.origin.entry !== "string" || !input.origin.entry.trim()))
      )
        throw new Error("origin requires nonempty event/session and entry or null");
      const { requestId, token, ...intent } = input;
      const resolveSpec = (): QuestionSpec => ({
        kind: input.kind,
        prompt: input.prompt,
        options: input.options,
        origin: input.origin,
        target: captureTarget(input),
      });
      result =
        op === "create"
          ? store.create(requestId, intent, resolveSpec)
          : store.revise(requestId, token, intent, resolveSpec);
    }
  } else
    throw new Error("usage: question-cli.ts list | json | create | revise | reply | thread TOPIC | check Qn@revision");
  console.log(JSON.stringify(result));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(`Shep questions: ${error.message}`);
    process.exitCode = 1;
  });
}
