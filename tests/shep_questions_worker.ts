// Real separate writers and process death at the filesystem commit boundary.
import fs from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { QuestionStore, type QuestionSpec } from "../shep/pi/questions.ts";
import { tellLand } from "../shep/pi/land-chain.ts";

const [dir, mode, payload] = process.argv.slice(2);
const input = JSON.parse(payload);
if (mode === "crash-write") {
  const write = fs.writeFileSync;
  fs.writeFileSync = (file, data, options) => {
    if (typeof data !== "string") throw new Error("fault injection expects a JSON string write");
    write(file, data.slice(0, 32), options);
    fs.writeSync(1, "commit-boundary\n");
    process.kill(process.pid, "SIGSTOP");
  };
  syncBuiltinESMExports();
}
if (mode === "crash-before" || mode === "crash-after") {
  const rename = fs.renameSync;
  fs.renameSync = (...args: Parameters<typeof fs.renameSync>) => {
    // The commit boundary is the rename onto the ledger, not the backups' shift before it.
    if (!String(args[1]).endsWith("/questions.json")) return rename(...args);
    if (mode === "crash-after") rename(...args);
    fs.writeSync(1, "commit-boundary\n");
    process.kill(process.pid, "SIGSTOP");
    if (mode === "crash-before") rename(...args);
  };
  syncBuiltinESMExports();
}
if (mode === "land-tell") {
  // Each write of the land event into the inbox, said on stdout.
  const rename = fs.renameSync;
  fs.renameSync = (...args: Parameters<typeof fs.renameSync>) => {
    rename(...args);
    if (String(args[1]).includes("/inbox/land-")) fs.writeSync(1, "wrote\n");
  };
  syncBuiltinESMExports();
}
const store = new QuestionStore(dir);
const run = () => {
  if (mode === "reply") store.propose(input.requestId, input.token, input.answer, "worker");
  else if (mode === "claim") fs.writeSync(1, `${store.claimPush(input.token, input.check, input.claim).accepted}\n`);
  else if (mode === "land-reserve") fs.writeSync(1, `${store.reserveLand(input.token, input.attempt).accepted}\n`);
  else if (mode === "land-claim") fs.writeSync(1, `${store.claimLand(input.token).accepted}\n`);
  else if (mode === "land-tell") fs.writeSync(1, `${tellLand(dir, input.token).told}\n`);
  else store.create(input.requestId, input.spec as QuestionSpec, (spec) => spec);
};
if (["create", "reply", "claim", "land-reserve", "land-claim", "land-tell"].includes(mode)) {
  // The parent releases all writers together, without timing sleeps.
  fs.writeSync(1, "ready\n");
  process.stdin.once("data", () => {
    run();
    process.stdin.destroy();
  });
} else run();
