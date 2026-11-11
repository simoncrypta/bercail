#!/usr/bin/env bash
# shellcheck shell=bash
# bercail policy: the repo's .bercail/policy.toml, the local override, trust by
# hash (a loosening value counts only once trusted, and an edit goes back to the
# default), scratch repos, and what the guard decides from that JSON. A temp HOME.
set -euo pipefail

unset BASH_ENV HC_TERMINAL_ID BERCAIL_CONFIG
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# node through mise needs the real HOME: find it first.
NODE="$(mise which node 2>/dev/null || command -v node 2>/dev/null || true)"
export HOME="$TMP_DIR/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export GIT_CONFIG_GLOBAL="$TMP_DIR/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$XDG_CONFIG_HOME/bercail"
git config --global user.name test
git config --global user.email test@example.com
git config --global init.defaultBranch main
CONFIG="$XDG_CONFIG_HOME/bercail/config.toml"
TRUST="$XDG_STATE_HOME/bercail/policy-trust.json"

policy() { "$ROOT/bin/bercail" policy "$@"; }
field() { policy show --json "$1" | jq -r "$2"; }

# A repo with a remote (so not scratch), one commit, and a linked worktree.
REPO="$TMP_DIR/repo"
git init -q "$REPO"
git -C "$REPO" remote add origin https://example.com/repo.git
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" worktree add -q -b feature "$TMP_DIR/repo.feature"
WT="$TMP_DIR/repo.feature"
REPO="$(cd "$REPO" && pwd -P)"
WT="$(cd "$WT" && pwd -P)"

# No policy: today's behavior, every value from the default.
[[ "$(field "$REPO" '.policy | [.commit, .push, .agent_may_release] | join(" ")')" == "ask ask false" ]] \
  || fail "no policy is not the default: $(policy show --json "$REPO")"
[[ "$(field "$REPO" '[.sources[]] | unique | join(",")')" == default ]] || fail "sources without a policy"
[[ "$(field "$REPO" '.file')" == "" && "$(field "$REPO" .scratch)" == false ]] || fail "a repo with a remote is scratch"
printf 'PASS: no policy file is the default\n'

write_policy() {
  mkdir -p "$1/.bercail"
  cat >"$1/.bercail/policy.toml" <<'EOF'
# team policy
commit = "allow"   # no prompt
push = 'main'
integrate = "direct"
pr_draft = true
release = "Bump \"VERSION\", then tag v*."
agent_may_release = false
rules = """
Use gh, never gt.
Simon merges."""
EOF
}
write_policy "$REPO"
git -C "$REPO" add .bercail/policy.toml
git -C "$REPO" commit -q -m policy
git -C "$WT" merge -q main

# Untrusted: the values that loosen the guard fall back; the rest apply.
out="$(policy show --json "$REPO")"
jq -e '.policy.commit == "ask" and .policy.push == "ask" and .policy.integrate == "direct" and .policy.pr_draft == true' <<<"$out" >/dev/null \
  || fail "untrusted loosening applied: $out"
jq -e '.untrusted == ["commit", "push"] and (.sources.commit | test("repo says allow, not trusted"))' <<<"$out" >/dev/null \
  || fail "untrusted values are not named: $out"
jq -e '.policy.release == "Bump \"VERSION\", then tag v*." and .policy.rules == "Use gh, never gt.\nSimon merges."' <<<"$out" >/dev/null \
  || fail "strings did not parse: $out"
jq -e '.prompt | test("Use gh, never gt.") and test("guard asks the person first") and test("is not trusted")' <<<"$out" >/dev/null \
  || fail "the prompt text: $(jq -r .prompt <<<"$out")"
policy show "$REPO" | grep -q "not trusted: bercail policy trust" || fail "show does not say how to trust"
printf 'PASS: an untrusted policy cannot loosen the guard\n'

# Trusted: everything applies, from the worktree too (keyed by the main checkout).
out="$(policy trust "$REPO")"
[[ "$out" == *"trusted $REPO/.bercail/policy.toml"* && "$out" == *"agents now: commit allow, push main"* ]] \
  || fail "trust did not say what it trusted: $out"
field "$REPO" .prompt | grep -q "is not trusted" && fail "a trusted policy is labeled untrusted"
jq -e --arg m "$REPO" '.[$m].sha256 | length == 64' "$TRUST" >/dev/null || fail "no hash in $(cat "$TRUST")"
[[ "$(field "$REPO" '[.trusted, .policy.commit, .policy.push] | join(" ")')" == "true allow main" ]] || fail "trust did not apply"
[[ "$(field "$WT" '[.repo, .trusted, .policy.commit] | join(" ")')" == "$REPO true allow" ]] \
  || fail "the worktree does not share the trust: $(policy show --json "$WT")"
printf 'PASS: a trusted policy applies in the main checkout and its worktrees\n'

# An edit (here, in the worktree) changes the hash: back to the default there.
printf 'push = "branch"\n' >>"$WT/.bercail/policy.toml"
[[ "$(field "$WT" '[.trusted, .policy.commit, .policy.push] | join(" ")')" == "false ask ask" ]] \
  || fail "an edited policy kept its trust: $(policy show --json "$WT")"
[[ "$(field "$REPO" '.trusted')" == true ]] || fail "the main checkout lost its trust"
git -C "$WT" checkout -q -- .bercail/policy.toml
policy untrust "$REPO" | grep -q "untrusted $REPO" || fail "untrust said nothing"
[[ "$(field "$REPO" '[.trusted, .policy.commit] | join(" ")')" == "false ask" ]] || fail "untrust did not go back to asking"
printf 'PASS: an edited file or untrust goes back to asking\n'

# The local override is the person's: it applies without trust and wins.
cat >"$CONFIG" <<EOF
[git]
"~/elsewhere" = "gh"

[policy."${REPO/#$HOME/\~}"]
commit = "allow"
integrate = "pr"

[policy."/somewhere/else"]
push = "main"
EOF
out="$(policy show --json "$WT")"
jq -e '.policy.commit == "allow" and .sources.commit == "local" and .policy.integrate == "pr" and .policy.push == "ask"' <<<"$out" >/dev/null \
  || fail "the local override: $out"
printf 'PASS: config.toml [policy."<main checkout>"] overrides without trust\n'

# Bad values and unknown keys warn and are left out.
printf 'commit = "always"\nmerge = "yes"\npush = maybe\n' >"$WT/.bercail/policy.toml"
err="$(policy show --json "$WT" 2>&1 >/dev/null)"
[[ "$err" == *'commit = "always" is not allowed'* && "$err" == *"unknown key merge"* && "$err" == *"push = maybe"* ]] \
  || fail "warnings: $err"
git -C "$WT" checkout -q -- .bercail/policy.toml
printf 'PASS: bad values warn and fall back\n'

# Scratch: a temp-dir repo with no remote and no config entry, even a copy of a
# repo with a policy, unless that policy says commit = "ask".
SCRATCH="$TMP_DIR/scratch"
git init -q "$SCRATCH"
[[ "$(field "$SCRATCH" .scratch)" == true ]] || fail "a temp repo with no remote is not scratch"
policy show "$SCRATCH" | grep -q "^scratch:" || fail "show does not say scratch"
mkdir -p "$SCRATCH/.bercail" && printf 'push = "main"\n' >"$SCRATCH/.bercail/policy.toml"
[[ "$(field "$SCRATCH" .scratch)" == true ]] || fail "a temp copy of a repo with a policy is not scratch"
printf 'commit = "ask"\n' >"$SCRATCH/.bercail/policy.toml"
[[ "$(field "$SCRATCH" .scratch)" == false ]] || fail "commit = \"ask\" did not opt out of scratch"
rm -rf "$SCRATCH/.bercail"
printf '\n[git]\n"%s" = "gh"\n' "$SCRATCH" >>"$CONFIG"
[[ "$(field "$SCRATCH" .scratch)" == false ]] || fail "a configured repo is scratch"
printf 'PASS: scratch is a temp repo with no remote or config\n'

# Errors name the fix.
err="$(policy show "$TMP_DIR" 2>&1)" && fail "a non-checkout succeeded"
[[ "$err" == *"is not a git checkout"* ]] || fail "non-checkout error: $err"
err="$(policy trust "$SCRATCH" 2>&1)" && fail "trusting a repo with no policy succeeded"
[[ "$err" == *"does not exist; nothing to trust"* ]] || fail "trust error: $err"
printf 'PASS: errors say what is wrong\n'

# The guard's answers from that JSON: untrusted asks, trusted allows, an edit asks.
[[ -n "$NODE" ]] || { printf 'SKIP: node not found; guard decisions from policy JSON\n'; exit 0; }
printf '[git]\n"%s" = "gh"\n' "$SCRATCH" >"$CONFIG"
decide() {
  policy show --json "$1" | "$NODE" --no-warnings --input-type=module -e '
    import { readFileSync } from "node:fs";
    const { decideBash, policyFromJson } = await import(process.argv[1]);
    const json = JSON.parse(readFileSync(0, "utf8"));
    const headless = process.argv[3] === "headless";
    const input = { role: headless ? "" : process.argv[3], hasUI: !headless, cwd: json.root,
      policies: { [json.root]: policyFromJson(json) }, branches: { [json.root]: "feature" } };
    console.log(decideBash(process.argv[2], input).action);
  ' "$ROOT/bstack/pi/extensions/guard.ts" "$2" "${3:-}"
}
[[ "$(decide "$WT" "git commit -m x")" == ask ]] || fail "untrusted commit did not ask"
[[ "$(decide "$WT" "git commit -m x" headless)" == block ]] || fail "untrusted headless commit was not blocked"
policy trust "$WT" >/dev/null
[[ "$(decide "$WT" "git commit -m x")" == allow ]] || fail "trusted commit did not go through"
[[ "$(decide "$WT" "git push origin main")" == allow ]] || fail "trusted push to main did not go through"
[[ "$(decide "$WT" "git commit -m x" headless)" == allow ]] || fail "trusted headless commit did not go through"
[[ "$(decide "$WT" "git push --force origin feature")" == block ]] || fail "force-push under a trusted policy"
[[ "$(decide "$WT" "git tag v1.0.0")" == ask ]] || fail "a tag without agent_may_release"
printf 'rules = "changed"\n' >>"$WT/.bercail/policy.toml"
[[ "$(decide "$WT" "git commit -m x")" == ask ]] || fail "an edited policy still allowed the commit"
git -C "$WT" checkout -q -- .bercail/policy.toml
[[ "$(decide "$SCRATCH" "git commit -m x")" == ask ]] || fail "a configured repo is still scratch"
: >"$CONFIG"
[[ "$(decide "$SCRATCH" "git commit -m x" headless)" == allow ]] || fail "a scratch commit did not go through"
[[ "$(decide "$SCRATCH" "git push /tmp/x.git HEAD:main")" == ask ]] || fail "a scratch push did not ask"
printf 'PASS: the guard decides from bercail policy show --json\n'
