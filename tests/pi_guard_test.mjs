// Decision table for bercail's Pi guard. No Pi process.
import assert from "node:assert/strict";

const { decideBash, decideTool } = await import(new URL("../bstack/pi/extensions/guard.ts", import.meta.url).href);

const headless = { role: "", hasUI: false, cwd: "/work" };
const tui = { role: "", hasUI: true, cwd: "/work" };
const auto = { role: "autopilot", hasUI: false, cwd: "/work", branch: "feature" };
const judge = { role: "judge", hasUI: true, cwd: "/work" };
const council = { role: "council", hasUI: false, cwd: "/work" };

function decision(command, input) {
  return decideBash(command, input);
}

function blocked(command, input, pattern) {
  const got = decision(command, input);
  assert.equal(got.action, "block", `${command} → ${JSON.stringify(got)}`);
  if (pattern) assert.match(got.reason, pattern, command);
}

function allowed(command, input) {
  assert.equal(decision(command, input).action, "allow", command);
}

function asked(command, input) {
  const got = decision(command, input);
  assert.equal(got.action, "ask", `${command} → ${JSON.stringify(got)}`);
}

blocked("git push --force", auto, /Force-push/);
blocked("git push -f origin feature", auto, /Force-push/);
blocked("git push --force-with-lease", auto, /Force-push/);
blocked("git push --force-if-includes origin feature", headless, /Force-push/);
blocked("git push --mirror", auto, /mirror/);
blocked("git push origin +feature", auto, /starting with \+/);
blocked("git push origin +HEAD:feature", auto, /starting with \+/);
blocked("git push --delete main", auto, /Deleting main or master/);
blocked("git push -d master", auto, /Deleting main or master/);
blocked("git push origin --delete refs/heads/main", auto, /Deleting main or master/);
blocked("git commit --no-verify -m x", auto, /--no-verify/);
blocked("git commit -n -m x", auto, /--no-verify/);
blocked("git push --no-verify origin feature", auto, /--no-verify/);
blocked("git merge --no-verify feature", headless, /--no-verify/);
blocked("git rebase --no-verify feature", tui, /--no-verify/);
blocked("gh pr merge", auto, /gh pr merge/);
blocked("gh pr merge 12 --squash", headless, /gh pr merge/);
blocked("sudo git push --force", auto, /Force-push/);
blocked("FOO=1 command env -u BAR git push --force", auto, /Force-push/);
blocked("git status && git push --force", auto, /Force-push/);
blocked("echo ok | git push --force origin feature", headless, /Force-push/);
blocked("bash -c 'git push --force'", auto, /Force-push/);
blocked('echo "$(git push --force)"', auto, /Force-push/);
blocked("git commit -m 'leave it'", headless, /headless run stages/);
blocked("git push origin feature", headless, /headless run stages/);
blocked("git push", { ...auto, branch: "main" }, /main or master/);
blocked("git push origin", { ...auto, branch: "master" }, /main or master/);
blocked("git push origin main", auto, /main or master/);
blocked("git push main", auto, /main or master/);
blocked("git push origin HEAD:main", auto, /main or master/);
blocked("git push origin feature:refs/heads/master", auto, /main or master/);
blocked("git push origin refs/heads/main", auto, /main or master/);
blocked("git push", { ...auto, branch: "" }, /Could not read the current branch/);
blocked("git add .", judge, /read-only/);
blocked("git commit -m x", council, /read-only/);
blocked("git reset --hard", judge, /read-only/);
blocked("git checkout -- .", council, /read-only/);
blocked("git restore --staged .", judge, /read-only/);

asked("git commit -m 'ship'", tui);
asked("git push origin feature", { role: "builder", hasUI: true, cwd: "/work" });

allowed("git status", headless);
allowed("git diff", judge);
allowed("git push origin feature", auto);
allowed("git push -u origin feature", auto);
allowed("git commit -m 'ship'", auto);
allowed("git push --delete feature", auto);
allowed('echo "git push --force"', headless);
allowed("git -C /tmp/repo push origin feature", auto);

const nested = decision("git -C ../other push", { role: "autopilot", hasUI: false, cwd: "/work" });
assert.equal(nested.action, "need-branch", JSON.stringify(nested));
assert.equal(nested.dir, "/other");

const abs = decision("git -C /repo/sub push", { ...auto, branch: undefined });
assert.equal(abs.action, "need-branch");
assert.equal(abs.dir, "/repo/sub");

// A heredoc body is data. Seen live: autopilot's summary quoted `git push --force origin feat`.
allowed("cat > /tmp/s.txt <<'EOF'\nNot attempted: `git push --force origin feat` and git push origin HEAD:main.\nEOF\npython3 -c 'print(1)'", auto);
allowed("cat <<-\"END\" >x\n\tgit commit --no-verify\n\tEND", headless);
blocked("cat <<EOF\n$(git push --force)\nEOF", auto, /Force-push/);
blocked("cat <<'EOF' >x\ntext\nEOF\ngit push --force", auto, /Force-push/);

assert.equal(decideTool("edit", undefined, judge).action, "block");
assert.equal(decideTool("write", undefined, council).action, "block");
assert.equal(decideTool("edit", undefined, headless).action, "allow");
assert.equal(decideTool("write", undefined, auto).action, "allow");
assert.equal(decideTool("read", undefined, judge).action, "allow");

console.log("PASS: pi guard decision table");
