# shellcheck shell=bash
# The land card's fixture, loaded by tests/land_card.bats and
# tests/land_card_stops.bats after isolate: a main checkout whose origin is a
# bare repo behind a stand-in ssh as git@github.com:o/app.git, a desk worktree
# with a described staged change, stand-ins for gh, hc, bd and the Herdr app at
# the process boundary, and the helpers their tests share.

# The repos, the desk and its staged change; poll and timeout 0.
land_setup() {
  need git jq node flock
  set -o pipefail
  unset BERCAIL_CONFIG HC_TERMINAL_ID BERCAIL_SELF
  export BERCAIL_ROLE=shep BERCAIL_LAND_POLL=0 BERCAIL_LAND_TIMEOUT=0
  export FAKE="$BATS_TEST_TMPDIR/bin" STATE="$BATS_TEST_TMPDIR/fake" LOG="$BATS_TEST_TMPDIR/argv"
  export HERDR_APP_BIN="$FAKE/herdr-app" HC_BIN="$FAKE/hc" BERCAIL_HERDR_LAYOUT="$ROOT/config/worktrunk/herdr-layout.sh"
  export PATH="$FAKE:$PATH"
  mkdir -p "$STATE"
  : >"$LOG"
  # The worker drops GIT_CONFIG_*, so git's settings live in HOME, as the person's do.
  git config --global user.name Simon
  git config --global user.email simon@example.com
  git config --global init.defaultBranch master
  BERCAIL="$ROOT/bin/bercail"
  SHEP="$XDG_STATE_HOME/bercail/shep"
  INBOX="$SHEP/inbox"
  GH="$BATS_TEST_TMPDIR/github"
  ORIGIN="$GH/o/app.git"
  MAIN="$HOME/Work/app"
  WT="$HOME/Work/app.login"
  mkdir -p "$GH/o" "$INBOX" "$XDG_STATE_HOME/bercail/desk-sessions"
  stand_ins
  git init -q --bare -b master "$ORIGIN"
  git_init "$MAIN"
  git -C "$MAIN" branch -M master
  mkdir -p "$MAIN/.bercail"
  printf 'push = "main"\nintegrate = "direct"\nrequired_ci = [".github/workflows/ci.yml"]\n' >"$MAIN/.bercail/policy.toml"
  git -C "$MAIN" add -f .bercail/policy.toml
  git -C "$MAIN" commit -qm policy
  printf '.bercail/\n' >>"$MAIN/.git/info/exclude"
  git -C "$MAIN" remote add origin git@github.com:o/app.git
  git -C "$MAIN" config core.sshCommand "$FAKE/ssh"
  git -C "$MAIN" config ssh.variant simple
  git -C "$MAIN" push -q -u origin master
  git -C "$MAIN" remote set-head origin master
  MAIN="$(cd "$MAIN" && pwd -P)" WT="$(cd "$HOME/Work" && pwd -P)/app.login"
  "$BERCAIL" policy trust "$MAIN" >/dev/null
  desk "$WT" login app-1 t9 sp1
  printf 'new\n' >>"$WT/file.txt"
  git -C "$WT" add file.txt
  described "$WT" "file: add a line"
}

# Stand-ins at the process boundary, each logging its argv to $LOG.
stand_ins() {
  mkdir -p "$FAKE"
  # ssh: serves git@github.com:<path> from the bare repos under $GH.
  printf '#!/bin/sh\nfor last; do :; done\ncd %q && exec sh -c "$last"\n' "$GH" >"$FAKE/ssh"
  # The Herdr app: no window here, so cleanup finds the space through hc.
  printf '#!/bin/sh\nexit 1\n' >"$FAKE/herdr-app"
  # hc: terminals in $STATE/hc.json. run logs the start, as the Herdr server
  # would get it, and the test runs it; $STATE/run-fails makes it fail.
  # $STATE/hc-down: hc answers nothing.
  cat >"$FAKE/hc" <<'SH'
#!/usr/bin/env bash
printf 'hc %s\n' "$*" >>"$LOG"
[[ ! -f "$STATE/hc-down" ]] || exit 1
st="$STATE/hc.json"
case "$1" in
  run)
    [[ ! -f "$STATE/run-fails" ]] || { echo "hc: the server is gone" >&2; exit 1; }
    while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
    shift
    printf '%q ' "$@" >>"$STATE/starts"
    printf '\n' >>"$STATE/starts"
    printf '{"address":"t50"}\n' ;;
  ls)
    want=()
    while [[ $# -gt 0 ]]; do [[ "$1" != --label ]] || want+=("$2"); shift; done
    jq --args '{terminals: [.[] | select(. as $t | $ARGS.positional
        | all(split("=") as [$k, $v] | $t.labels[$k] == $v)) | {address, state, cwd, labels: null}]}' \
      "${want[@]}" <"$st" ;;
  get)
    jq -e --arg a "$2" '.[] | select(.address == $a)' "$st" \
      || { printf '{"error":{"kind":"not_found","message":"no terminal"}}\n'; exit 3; } ;;
  kill) jq --arg a "$2" 'map(if .address == $a then .state = "finished" else . end)' "$st" >"$st.tmp" && mv "$st.tmp" "$st" ;;
  rm) jq --arg a "$2" 'map(select(.address != $a))' "$st" >"$st.tmp" && mv "$st.tmp" "$st" ;;
esac
SH
  # gh: the required and optional workflows, and the push runs of the commit and
  # branch asked about, from $STATE/ci: one run a line, "<workflow id> <status>
  # <conclusion> [branch] [attempt]". Each call first runs $STATE/on-ci, if any.
  cat >"$FAKE/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$LOG"
case "$1 $2" in
  "workflow list") printf '[{"id":7,"path":".github/workflows/ci.yml"},{"id":9,"path":".github/workflows/site.yml"}]\n' ;;
  "run list")
    [[ ! -x "$STATE/on-ci" ]] || "$STATE/on-ci"
    while [[ $# -gt 0 ]]; do
      case "$1" in --commit) sha="$2" ;; --branch) branch="$2" ;; --limit) limit="$2" ;; esac
      shift
    done
    n=0
    while read -r id status conclusion other attempt; do
      [[ -n "$id" ]] || continue
      n=$((n + 1))
      [[ -n "$other" && "$other" != - ]] || other="$branch"
      jq -nc --argjson id "$id" --arg s "$status" --arg c "$conclusion" --arg sha "$sha" --arg b "$other" \
        --argjson n "$n" --argjson a "${attempt:-1}" \
        '{databaseId: $n, workflowDatabaseId: $id, headBranch: $b, headSha: $sha, attempt: $a, status: $s, conclusion: $c}'
    done < <(cat "$STATE/ci" 2>/dev/null) | jq -s --argjson limit "$limit" '.[:$limit]' ;;
  *) exit 2 ;;
esac
SH
  # bd: app-1 and app-2, open until closed. $STATE/on-close runs on a close.
  cat >"$FAKE/bd" <<'SH'
#!/usr/bin/env bash
printf 'bd %s\n' "$*" >>"$LOG"
case "$1" in
  show)
    [[ -f "$STATE/issue-$2.json" ]] || exit 1
    jq -c --arg s "$(cat "$STATE/status-$2" 2>/dev/null || echo open)" '[. + {status: $s}]' "$STATE/issue-$2.json" ;;
  close)
    [[ ! -x "$STATE/on-close" ]] || "$STATE/on-close"
    echo closed >"$STATE/status-$2" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$FAKE"/*
}

# A desk: worktree DIR on BRANCH for ISSUE, its live desk terminal T and space
# SP, its handoff record and desk session record.
desk() {
  local dir="$1" branch="$2" issue="$3" t="$4" sp="$5"
  git -C "$MAIN" worktree add -q -b "$branch" "$dir"
  jq -nc --arg i "$issue" --arg b "$branch" --arg t "$t" \
    '{id: $i, title: "Login", metadata: {bercail_task: {branch: $b, owner: {desk: $t}}}}' >"$STATE/issue-$issue.json"
  jq -nc --arg p "$dir" --arg i "$issue" --arg b "$branch" '{path: $p, issue: $i, branch: $b, stage: "bstack"}' \
    >>"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  jq -nc --arg t "$t" --arg p "$dir" --arg i "$issue" --arg sp "$sp" \
    '{address: $t, session: "desk-session-\($t)", cwd: $p, harness: "pi", issue: $i, space: $sp}' \
    >"$XDG_STATE_HOME/bercail/desk-sessions/$t.json"
  [[ -f "$STATE/hc.json" ]] || echo '[]' >"$STATE/hc.json"
  jq --arg t "$t" --arg p "$dir" --arg i "$issue" --arg sp "$sp" '. + [{address: $t, state: "live", reason: null,
      cwd: $p, labels: {"bercail.role": "agent", "bercail.issue": $i, "bercail.space": $sp},
      records: {"desk-session-\($t)": {app: "pi", state: "idle"}}}]' "$STATE/hc.json" >"$STATE/hc.tmp"
  mv "$STATE/hc.tmp" "$STATE/hc.json"
}

# Evidence and a stamped description titled TITLE for DIR's staged change.
described() {
  local dir="$1" title="$2"
  mkdir -p "$dir/.bercail"
  jq -n --arg t "$(git -C "$dir" write-tree)" \
    '{tree: $t, checks: [{kind: "test", command: "bash tests/run.sh", exit_code: 0, evidence: "all passed"}]}' >"$dir/.bercail/validate.json"
  printf -- '---\ntitle: %s\n---\nAdds a line for readers of file.txt.\n\nValidation: bash tests/run.sh passed.\n' \
    "$title" >"$dir/.bercail/description.md"
  (cd "$dir" && "$BERCAIL" describe stamp >/dev/null) || fail "stamp $dir"
}

question() { "$BERCAIL" shep question "$@"; }
# The card's token from land ask's line.
ask() { "$BERCAIL" land ask "${1:-$WT}" | grep -o '^Q[0-9]*@[0-9]*'; }
# The person's pick on the panel.
pick() {
  jq -nc --arg t "$1" --arg c "${2:-Ship it}" '{requestId: "pick-\($t)-\($c)", token: $t, choice: $c, source: "panel picker"}' \
    | question answer
}
# What the worker's terminal runs, as hc run got it.
run_worker() { eval "$(tail -n 1 "$STATE/starts")"; }
card() { question get "$1"; }
trunk() { git --git-dir="$ORIGIN" rev-parse master; }
ref() { git --git-dir="$ORIGIN" rev-parse --verify --quiet "$1" || true; }
# The land events in Shep's inbox.
events() { cat "$INBOX"/land-*.json 2>/dev/null; }

# A staged change to the repo's policy file in the desk's worktree, described; prints its sha256.
policy_change() {
  printf 'rules = "%s"\n' "$1" >>"$WT/.bercail/policy.toml"
  git -C "$WT" add -f .bercail/policy.toml
  described "$WT" "policy: $1"
  git -C "$WT" cat-file blob :.bercail/policy.toml | sha256sum | cut -d' ' -f1
}
trusted_hash() { jq -r --arg m "$MAIN" '.[$m].sha256' "$XDG_STATE_HOME/bercail/policy-trust.json"; }
