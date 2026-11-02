#!/usr/bin/env bash
# shellcheck shell=bash
# bercail review-pr against fake gh, opencode, tuicr, herdr-app, hc, and fzf.
# No network: the PR heads come from a local bare repo.
set -euo pipefail

unset BASH_ENV BERCAIL_REVIEW_STACK HC_TERMINAL_ID
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1' got '$2'"; }
assert_has() { grep -qF -- "$2" <<<"$1" || fail "$3: no '$2' in:"$'\n'"$1"; }

for bin in git jq python3; do
  command -v "$bin" >/dev/null || { printf 'SKIP: %s not found\n' "$bin"; exit 0; }
done

# A mise shim reads $HOME, which the test replaces: take the real python3 now.
PY="$(type -ap python3 | grep -v '/mise/shims/' | head -1)"
[[ -n "$PY" ]] || { printf 'SKIP: python3 (not a mise shim) not found\n'; exit 0; }
export HOME="$TMP_DIR/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$TMP_DIR/state"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
FIX="$TMP_DIR/fix"
LOG="$TMP_DIR/log"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$HOME" "$FIX" "$LOG" "$FAKE_BIN" "$XDG_CONFIG_HOME/bercail"
export FIX LOG
# A family name, so the pass has to ask opencode. The checkout hides other
# providers; the stack dir does not. The pass must not inherit the checkout's list.
printf '[bstack]\nenabled = true\nlead = "grok"\n' >"$XDG_CONFIG_HOME/bercail/config.toml"
BERCAIL="$ROOT/bin/bercail"
REVIEWS="$XDG_STATE_HOME/bercail/reviews/github.com/acme/widgets"

# --- a repo with two PR heads: refs/pull/7/head and refs/pull/8/head -----------
REMOTE="$TMP_DIR/remotes/acme/widgets.git"
git init -q --bare -b main "$REMOTE"
git init -q -b main "$TMP_DIR/seed"
(
  cd "$TMP_DIR/seed"
  echo base >README && git add README && git commit -qm base
  git push -q "$REMOTE" main
  git switch -qc retry && mkdir lib && echo 'retry() { :; }' >lib/retry.sh
  ln -s /etc/hostname lib/host-link && git add lib && git commit -qm retry
  git push -q "$REMOTE" HEAD:refs/pull/7/head
  git switch -q main && git switch -qc docs && echo more >>README && git commit -qam docs
  git push -q "$REMOTE" HEAD:refs/pull/8/head
)
SHA7="$(git -C "$TMP_DIR/seed" rev-parse retry)"
SHA8="$(git -C "$TMP_DIR/seed" rev-parse docs)"
export REMOTE
git clone -q "$REMOTE" "$TMP_DIR/work/widgets"
WORK="$TMP_DIR/work/widgets"
export WORK
printf '%s\n' '{"disabled_providers":["xai","openai"]}' >"$WORK/opencode.json"

# --- fixtures -------------------------------------------------------------------
pr_json() { # n sha title body closing
  jq -n --argjson n "$1" --arg sha "$2" --arg title "$3" --arg body "$4" --argjson closing "$5" '{
    number: $n, title: $title, body: $body, url: "https://github.com/acme/widgets/pull/\($n)",
    author: {login: "dana"}, isDraft: false, baseRefName: "main", headRefName: "retry", headRefOid: $sha,
    closingIssuesReferences: $closing,
    files: [{path: "lib/retry.sh", additions: 1, deletions: 0, changeType: "ADDED"},
            {path: "package-lock.json", additions: 40, deletions: 2, changeType: "MODIFIED"}],
    statusCheckRollup: [{__typename: "CheckRun", name: "lint", workflowName: "CI", conclusion: "FAILURE", status: "COMPLETED", detailsUrl: "https://ci/lint"}]}'
}
pr_json 7 "$SHA7" "Retry flaky uploads" $'Adds a retry helper so uploads stop failing.\n\nCloses #12.' \
  '[{"number": 12, "url": "https://github.com/acme/widgets/issues/12"}]' >"$FIX/pr-7.json"
pr_json 8 "$SHA8" "Docs" '' '[]' >"$FIX/pr-8.json"
printf 'diff --git a/lib/retry.sh b/lib/retry.sh\n+retry() { :; }\n' >"$FIX/pr-7.diff"
printf 'diff --git a/README b/README\n+more\n' >"$FIX/pr-8.diff"
cat >"$FIX/checks.json" <<'EOF'
[{"name":"test","bucket":"pass","state":"SUCCESS","workflow":"CI","link":"https://ci/test"},
 {"name":"e2e","bucket":"pending","state":"IN_PROGRESS","workflow":"CI","link":"https://ci/e2e"},
 {"name":"lint","bucket":"fail","state":"FAILURE","workflow":"CI","link":"https://ci/lint"}]
EOF
jq -n '{number: 12, title: "Uploads fail on flaky networks", body: "Retry with backoff, and log each retry.", url: "https://github.com/acme/widgets/issues/12"}' >"$FIX/issue-12.json"
cat >"$FIX/reply.json" <<'EOF'
{"why": "Uploads fail on flaky networks; the issue asks for retries.", "why_source": "issue #12",
 "decisions": [
  {"kind": "approach", "statement": "Retries live in a new retry.sh helper",
   "evidence": [{"file": "lib/retry.sh", "line": 3, "end_line": 9, "side": "new"}],
   "stated": "PR body: adds a retry helper", "fits_intent": "yes", "alternative": null, "question": null},
  {"kind": "behavior", "statement": "Uploads retry 5 times with no backoff",
   "evidence": [{"file": "lib/upload.sh", "line": 12, "side": "new"}],
   "stated": null, "fits_intent": "partial", "alternative": "exponential backoff",
   "question": "Why 5 retries with no backoff? The issue asks for backoff."},
  {"kind": "scope", "statement": "Drops the old timeout",
   "evidence": [{"file": "outside.txt", "line": 40, "side": "old"}],
   "stated": null, "fits_intent": "unclear", "alternative": null, "question": "Was dropping the timeout intended?"}],
 "unmet_intent": [{"promise": "Log each retry", "source": "issue #12",
   "question": "The issue asks to log each retry; is that in another PR?"}],
 "questions": []}
EOF

# --- fakes ----------------------------------------------------------------------
cat >"$FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG/gh"
case "$1 $2" in
  "pr view") [[ " $* " == *" --web "* ]] && exit 0; cat "$FIX/pr-$3.json" ;;
  "pr diff") cat "$FIX/pr-$3.diff" ;;
  # Pending and failing checks: gh prints the JSON and exits 8.
  "pr checks") [[ -n "${FAKE_NO_CHECKS:-}" ]] && { echo "no checks reported" >&2; exit 1; }
    if [[ -n "${FAKE_GH_HOLD:-}" ]]; then
      touch "$LOG/gh.held"
      while [[ ! -f "$LOG/gh.release" ]]; do sleep 0.05; done
    fi
    cat "$FIX/checks.json"; exit 8 ;;
  "issue view") cat "$FIX/issue-12.json" ;;
  "repo clone")
    if [[ " $* " == *" --bare "* ]]; then git clone -q --bare "$REMOTE" "$4"
    else git clone -q "$REMOTE" "$4"; fi ;;
  "repo view") echo '{"defaultBranchRef":{"name":"main"}}' ;;
  "pr list")
    base="" head=""
    shift 2
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --base) base="$2"; shift 2 ;;
        --head) head="$2"; shift 2 ;;
        --json|--state|--limit|-R) shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ -n "$head" && -f "$FIX/list-head-$head.json" ]]; then cat "$FIX/list-head-$head.json"
    elif [[ -n "$base" && -f "$FIX/list-base-$base.json" ]]; then cat "$FIX/list-base-$base.json"
    else echo '[]'; fi ;;
  *) echo "fake gh: $*" >&2; exit 2 ;;
esac
SH
cat >"$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
# Model lookup must not use the checkout's config. A file named opencode.json
# stands in for a repo that hides providers.
case "$1" in
  auth)
    printf '%s\n' '[{"id":"xai","connections":[{"id":"1"}]}]'
    exit 0 ;;
  models)
    if [[ -f "$PWD/opencode.json" ]]; then
      printf '%s\n' claude-agent/opus
    else
      printf '%s\n' xai/grok-4.7
    fi
    exit 0 ;;
  api) exit 0 ;;
esac
printf '%s\n' "$PWD" >"$LOG/opencode.pwd"
printf '%s\n' "$@" >"$LOG/opencode.argv"
ev() { jq -cn --arg type "$1" --arg text "${2:-}" '{type: $type, sessionID: "ses_fake", part: {type: $type, text: $text}}'; }
ev step_start
if [[ -n "${FAKE_HOLD:-}" ]]; then
  trap 'exit 143' TERM
  echo "$$" >"$LOG/opencode.child"
  while [[ ! -f "$LOG/opencode.release" ]]; do sleep 0.05; done
fi
case "${FAKE_OPENCODE:-ok}" in
  ok) ev text "Read intent.md and diff.patch."
      ev text "$(printf 'Three decisions.\n\n```json\n%s\n```' "$(cat "$FIX/reply.json")")" ;;
  noblock) ev text "I looked at it and it seems fine." ;;
  long) for ((i = 0; i < 3000; i++)); do ev tool_use; done
        ev text "$(printf '```json\n%s\n```' "$(cat "$FIX/reply.json")")" ;;
  blocked) ev text "$(printf '```json\n{"blocked": "diff.patch is empty"}\n```')" ;;
  crash) echo "provider error" >&2; exit 3 ;;
esac
ev step_finish
SH
cat >"$FAKE_BIN/tuicr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "review list")
    # The session shows up on the second look, as when tuicr is still starting.
    n="$(cat "$LOG/tuicr.lists" 2>/dev/null || echo 0)"; echo $((n + 1)) >"$LOG/tuicr.lists"
    if [[ "$n" -ge 1 ]]; then
      echo '[{"slug":"gh:acme/widgets/pr/8","kind":"pr","active":true},{"slug":"gh:acme/widgets/pr/7","kind":"pr","active":true}]'
    else
      echo '[{"slug":"gh:acme/widgets/pr/7","kind":"pr","active":false}]'
    fi ;;
  "review add")
    [[ "$*" == *"--session gh:acme/widgets/pr/7 --input -"* ]] || { echo "bad args: $*" >&2; exit 2; }
    payload="$(cat)"
    # A line outside the PR diff: tuicr can't anchor it.
    [[ "$(jq -r '.file // ""' <<<"$payload")" == outside.txt ]] && { echo "not in diff" >&2; exit 1; }
    printf '%s\n' "$payload" >>"$LOG/tuicr.add"
    if [[ -n "${FAKE_TUICR_HOLD:-}" ]]; then
      touch "$LOG/tuicr.held"
      while [[ ! -f "$LOG/tuicr.release" ]]; do sleep 0.05; done
    fi
    jq -c --arg id "c$(wc -l <"$LOG/tuicr.add" | tr -d ' ')" '{id: $id} + .' <<<"$payload" ;;
  *) echo "fake tuicr: $*" >&2; exit 2 ;;
esac
SH
# herdr-app: down unless FAKE_HERDR_UP; state in $HERDR_STATE.
cat >"$FAKE_BIN/herdr-app" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG/herdr"
[[ -n "${FAKE_HERDR_UP:-}" ]] || exit 1
st="$HERDR_STATE"
case "$1" in
  status) echo '{"space":"s0"}' ;;
  ls) cat "$st" ;;
  do)
    cmd="$2"; shift 2
    declare -A a=()
    if [[ $# -eq 1 && "$1" == "{"* ]]; then
      while IFS=$'\t' read -r k v; do a["$k"]="$v"; done \
        < <(jq -r 'to_entries[] | [.key, (.value | if type == "string" then . else tojson end)] | @tsv' <<<"$1")
    fi
    while [[ $# -gt 1 ]]; do a["${1#--}"]="$2"; shift 2; done
    case "$cmd" in
      space.new)
        jq --arg n "${a[name]}" --arg f "${a[folder]}" \
          '.spaces += [{id: "s1", name: $n, folder: $f, tabs: [{name: "Shell", terminals: [{terminal: "t-sh"}]}]}]' \
          "$st" >"$st.tmp" && mv "$st.tmp" "$st"
        echo '{"space":"s1"}' ;;
      tab.new)
        # A mod tab has no terminals.
        id="tb$(jq '[.spaces[].tabs[]?] | length' "$st")"
        jq --arg s "${a[space]}" --arg n "${a[name]}" --arg id "$id" --arg argv "${a[argv]:-}" \
          '(.spaces[] | select(.id == $s) | .tabs) += [{id: $id, name: $n,
             terminals: (if $argv == "" then [] else [{terminal: "t-\($id)"}] end)}]' \
          "$st" >"$st.tmp" && mv "$st.tmp" "$st"
        if [[ -n "${a[mod]:-}" ]]; then
          printf '%s %s\n' "${a[mod]}" "${a[props]}" >>"$LOG/stack.mod"
        else
          printf '%s\n' "${a[argv]}" >"$LOG/stack.argv"
        fi
        printf '{"space":"%s","tab":"%s"}\n' "${a[space]}" "$id" ;;
      tab.close)
        jq --arg id "${a[id]}" '.spaces[].tabs |= map(select(.id != $id))' "$st" >"$st.tmp" && mv "$st.tmp" "$st" ;;
    esac ;;
esac
SH
cat >"$FAKE_BIN/hc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG/hc"
case "$1" in
  ls) echo '{"terminals":[]}' ;;
esac
SH
cat >"$FAKE_BIN/fzf" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$LOG/fzf.argv"
cat >"$LOG/fzf.stdin"
SH
cat >"$FAKE_BIN/gt" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG/gt"
cwd="" branch="" prev=""
for a in "$@"; do
  [[ "$prev" == --cwd ]] && cwd="$a"
  [[ "$prev" == --branch ]] && branch="$a"
  prev="$a"
done
[[ "$1" == get ]] && branch="$2"
if [[ -n "$WORK" && ( "$cwd" == "$WORK" || "$cwd" == "$WORK/"* ) ]]; then
  echo "gt must not run against the source checkout" >&2
  exit 3
fi
case "$1" in
  get) git -C "$cwd" branch -f "$branch" HEAD ;;
  log)
    cur="$(git -C "$cwd" branch --show-current 2>/dev/null || true)"
    if [[ -n "$cur" && -f "$FIX/gt-log-$cur" ]]; then cat "$FIX/gt-log-$cur"
    else cat "$FIX/gt-log"; fi ;;
  branch)
    [[ -f "$FIX/gt-info-$branch" ]] || { echo "no gt info for $branch" >&2; exit 2; }
    cat "$FIX/gt-info-$branch" ;;
  *) echo "fake gt: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$FAKE_BIN"/*
export PATH="$FAKE_BIN:$PATH"
export HERDR_APP_BIN="$FAKE_BIN/herdr-app" HC_BIN="$FAKE_BIN/hc"
export BERCAIL_HERDR_LAYOUT="$ROOT/config/worktrunk/herdr-layout.sh"
export HERDR_STATE="$TMP_DIR/herdr.json"

wait_for() {
  local i
  for ((i = 0; i < 100; i++)); do [[ -e "$1" ]] && return 0; sleep 0.1; done
  fail "timed out waiting for $1"
}

# --- thin rules -------------------------------------------------------------------
test_thin_rules() {
  (
   # shellcheck source=lib/common.sh
   source "$ROOT/lib/common.sh"
   # shellcheck source=lib/review.sh
   source "$ROOT/lib/review.sh"
   t() { # title body closing linear -> flags
     jq -n --arg t "$1" --arg b "$2" --argjson c "$3" '{title: $t, body: $b, closingIssuesReferences: $c}' >"$TMP_DIR/t.json"
     _review_thin "$TMP_DIR/t.json" "$4"
   }
   assert_eq '["empty_body","no_linked_issue"]' "$(t "Docs" "" '[]' '[]')" "empty body"
   assert_eq '["empty_body","no_linked_issue"]' "$(t "Docs" "<!-- template -->" '[]' '[]')" "a template comment is empty"
   assert_eq '["restates_title"]' "$(t "Retry flaky uploads" "Retry flaky uploads." '[{"number":1}]' '[]')" "restates title"
   assert_eq '["restates_title"]' "$(t "Retry flaky uploads" "retry" '[{"number":1}]' '[]')" "body inside the title"
   assert_eq '["no_linked_issue"]' "$(t "Retry" "Adds a helper so uploads retry." '[]' '[]')" "no linked issue"
   assert_eq '[]' "$(t "Retry" "Adds a helper so uploads retry." '[]' '["LEF-123"]')" "a Linear id is a linked issue"
   jq -n '{title: "Retry", body: "See PR-12 and CI-123.", headRefName: "retry"}' >"$TMP_DIR/l.json"
   assert_eq '[]' "$(_review_linear_ids "$TMP_DIR/l.json")" "PR-12 and CI-123 are not Linear ids"
   assert_eq '["part_n_of_m_only"]' "$(t "Retry" "Part 2 of 3" '[{"number":1}]' '[]')" "part N of M only"
   assert_eq '["part_n_of_m_only"]' "$(t "Retry: storage" "Part 2/3 — retry: storage" '[{"number":1}]' '[]')" "part N of M plus the title"
   assert_eq '[]' "$(t "Retry" "Part 2 of 3: adds the backoff schedule." '[{"number":1}]' '[]')" "part N of M with more"
   jq -n '{title: "LEF-42 retry", body: "See UTF-8 and SHA-256, also ENG-7.", headRefName: "dana/lef-99-retry"}' >"$TMP_DIR/l.json"
   assert_eq '["ENG-7","LEF-42","LEF-99"]' "$(_review_linear_ids "$TMP_DIR/l.json")" "Linear ids"
   jq -n '{title: "x", body: "", headRefName: "review-pr-slice-1"}' >"$TMP_DIR/l.json"
   assert_eq '[]' "$(_review_linear_ids "$TMP_DIR/l.json")" "a branch word is not a Linear id"
  ) || exit 1
  printf 'PASS: thin rules (empty, restates title, no linked issue, part N of M only) and Linear ids\n'
}

# --- review-pr <url>: a thin PR stops at the JSON --------------------------------
test_thin_pr_stops() {
  local out dir
  out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/8)"
  assert_eq '["empty_body","no_linked_issue"]' "$(jq -c '.prs[0].thin' <<<"$out")" "thin flags in the JSON"
  assert_eq 'true waiting' "$(jq -r '"\(.thin) \(.pass)"' <<<"$out")" "a thin PR waits"
  assert_eq "bercail review-pr run --stack $REVIEWS/stack-8" "$(jq -r '.next' <<<"$out")" "next command"
  [[ ! -e "$LOG/opencode.argv" ]] || fail "a thin PR must not start the pass"
  dir="$REVIEWS/stack-8/pr-8/$SHA8"
  assert_eq "$dir" "$(jq -r '.prs[0].dir' <<<"$out")" "run dir in the JSON"
  for f in intent.md diff.patch ci.json pr.json; do [[ -s "$dir/$f" ]] || fail "missing $dir/$f"; done
  [[ -s "$REVIEWS/stack-8/stack.json" ]] || fail "missing stack.json"
  local sib="$TMP_DIR/work/widgets.review-8"
  assert_eq "widgets.review-8 8 8" "$(jq -r '"\(.worktree | split("/")[-1]) \(.root) \(.current)"' "$REVIEWS/stack-8/stack.json")" "stack.json"
  assert_eq "$sib" "$(jq -r .worktree "$REVIEWS/stack-8/stack.json")" "sibling of the source checkout"
  assert_eq "$SHA8" "$(git -C "$sib" rev-parse HEAD)" "worktree at the PR head"
  git -C "$sib" symbolic-ref -q HEAD >/dev/null && fail "the review worktree must be detached"
  [[ "$(git -C "$WORK" worktree list --porcelain)" == *"$sib"* ]] || fail "worktree registered to the source git"
  [[ ! -d "$REVIEWS/stack-8/worktree" && ! -d "$REVIEWS/clone.git" ]] || fail "no state-dir review worktree"
  # gh pr checks exited 8 (pending, failing): its JSON is kept.
  assert_eq 3 "$(jq length "$dir/ci.json")" "ci.json from gh pr checks"
  assert_eq '{"pass":1,"pending":1,"fail":1}' "$(jq -c '.prs[0].ci' <<<"$out")" "CI counts"
  assert_has "$(<"$dir/intent.md")" "- thin: empty_body, no_linked_issue" "intent.md thin"
  assert_has "$(<"$dir/intent.md")" "package-lock.json (+40 -2, modified) [lock or generated: name only]" "lock files by name"
  assert_has "$("$BERCAIL" review-pr card --stack "$REVIEWS/stack-8")" "Decisions pass: waiting: thin (empty_body, no_linked_issue)" "card before the pass"
  printf 'PASS: a thin PR: run dir, detached worktree, CI kept from a failing gh pr checks, JSON stops with thin flags\n'
}

# --- review-pr <url>: the pass starts, review.json and run.json land -------------
test_pass() {
  local out dir argv
  out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/7/files)"
  assert_eq 'false started' "$(jq -r '"\(.thin) \(.pass)"' <<<"$out")" "a PR with intent starts the pass"
  dir="$REVIEWS/stack-7/pr-7/$SHA7"
  assert_has "$(<"$dir/intent.md")" "### #12 Uploads fail on flaky networks" "linked issue in intent.md"
  wait_for "$dir/run.json"
  argv="$(<"$LOG/opencode.argv")"
  assert_eq $'run\n--format\njson\n--agent\nbstack-pr-review' "$(head -5 <<<"$argv")" "opencode argv"
  grep -q -- '--model' <<<"$argv" && fail "must not pass --model"
  assert_has "$argv" "pr-7/$SHA7/source/" "the prompt names the snapshot"
  assert_eq "$REVIEWS/stack-7" "$(<"$LOG/opencode.pwd")" "the pass runs in the stack dir, not the reviewed repo"
  [[ ! -e "$REVIEWS/stack-7/opencode.json" ]] || fail "the author's opencode config must not be copied to the launch cwd"
  assert_eq 'ready ses_fake' "$(jq -r '"\(.status) \(.session_id)"' "$dir/run.json")" "run.json"
  assert_eq '3 decisions, 2 undocumented, 1 unmet, 3 questions' "$(jq -r .summary "$dir/run.json")" "run.json summary"
  assert_eq "bercail.review/v1 7 $SHA7 ses_fake 3" \
    "$(jq -r '"\(.schema) \(.pr) \(.head_sha) \(.session_id) \(.decisions | length)"' "$dir/review.json")" "review.json"
  local sib7="$TMP_DIR/work/widgets.review-7"
  [[ -L "$sib7/lib/host-link" ]] || fail "the review worktree keeps a normal symlink"
  [[ ! -L "$dir/source/lib/host-link" ]] || fail "the snapshot must not be a symlink"
  assert_eq /etc/hostname "$(cat "$dir/source/lib/host-link")" "symlink target, not its contents"
  [[ -s "$dir/source/lib/retry.sh" ]] || fail "changed text is snapshotted"
  [[ ! -e "$dir/source/package-lock.json" ]] || fail "lock files are not snapshotted"
  assert_eq '' "$(git -C "$sib7" status --porcelain)" "the review worktree stays clean"
  [[ "$(git -C "$WORK" config --get core.symlinks || true)" != false ]] || fail "source repo's symlink policy changed"
  printf 'PASS: a PR with intent: the pass runs bstack-pr-review with no --model and writes review.json and run.json\n'
}

test_card() {
  local card
  card="$(cd "$TMP_DIR/work/widgets.review-7" && "$BERCAIL" review-pr card)"
  assert_has "$card" "PR #7  Retry flaky uploads" "card title"
  assert_has "$card" "by dana · main ← retry · ${SHA7:0:7}" "card author, base, head"
  assert_has "$card" "  Uploads fail on flaky networks; the issue asks for retries.  [issue #12]" "why"
  assert_has "$card" "Decisions (3, 2 undocumented)" "decision counts"
  assert_has "$card" "  1. [approach] Retries live in a new retry.sh helper" "decision"
  assert_has "$card" "     lib/retry.sh:3-9  stated: PR body: adds a retry helper · fits intent: yes" "stated decision"
  assert_has "$card" "     lib/upload.sh:12  UNDOCUMENTED · fits intent: partial" "undocumented decision"
  assert_has "$card" "     over: exponential backoff" "alternative"
  assert_has "$card" $'Intent with no change\n  - Log each retry  [issue #12]' "unmet intent"
  assert_has "$card" "  2. outside.txt:40  Was dropping the timeout intended?" "anchored question"
  assert_has "$card" "  3. (whole PR)  The issue asks to log each retry; is that in another PR?" "whole-PR question"
  assert_has "$card" "CI  1 fail · 1 pending · 1 pass" "CI counts"
  assert_has "$card" "  fail     lint (CI)  https://ci/lint" "failing check with its link"
  assert_has "$("$BERCAIL" review-pr rows --stack "$REVIEWS/stack-7")" \
    $'7\t#7  Retry flaky uploads  ·  ready: 3 decisions' "rows"
  assert_eq "$REVIEWS/stack-7/pr-7/$SHA7" "$(cd "$TMP_DIR/work/widgets.review-7" && "$BERCAIL" review-pr dir)" "dir"
  printf 'PASS: card: why, decisions (kind, file:line, stated or undocumented, fits intent), unmet intent, questions, CI\n'
}

test_run_outcomes() {
  local dir="$REVIEWS/stack-7/pr-7/$SHA7"
  FAKE_OPENCODE=noblock "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >/dev/null && fail "no JSON block must fail"
  assert_eq 'failed the reply is not a valid decisions JSON block' "$(jq -r '"\(.status) \(.reason)"' "$dir/run.json")" "failed"
  FAKE_OPENCODE=crash "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >/dev/null && fail "a crash must fail"
  assert_eq 'failed opencode exited 3: provider error' "$(jq -r '"\(.status) \(.reason)"' "$dir/run.json")" "crash"
  cp "$FIX/reply.json" "$FIX/good-reply.json"
  local bad
  for bad in '.decisions = ["not an object"]' '.decisions[0].evidence = {file:"a",line:1}' \
    '.unmet_intent = ["not an object"]' '.questions = [{text:42}]' '., .'; do
    jq "$bad" "$FIX/good-reply.json" >"$FIX/reply.json"
    "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >/dev/null && fail "malformed review must fail: $bad"
    assert_eq 'failed ses_fake' "$(jq -r '"\(.status) \(.session_id)"' "$dir/run.json")" "invalid shape keeps its session id"
    [[ ! -e "$dir/review.json" ]] || fail "an invalid review must never reach the card or seeding"
    assert_has "$("$BERCAIL" review-pr card --stack "$REVIEWS/stack-7")" "not a valid decisions JSON block" "card after invalid reply"
  done
  mv "$FIX/good-reply.json" "$FIX/reply.json"
  FAKE_OPENCODE=blocked "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >/dev/null || fail "blocked is not a failure"
  assert_eq 'blocked diff.patch is empty ses_fake' "$(jq -r '"\(.status) \(.reason) \(.session_id)"' "$dir/run.json")" "blocked"
  assert_has "$("$BERCAIL" review-pr rows --stack "$REVIEWS/stack-7")" "blocked: diff.patch is empty" "a blocked row"
  [[ ! -e "$dir/review.json" ]] || fail "a rerun that blocks drops the last review"
  assert_has "$("$BERCAIL" review-pr card --stack "$REVIEWS/stack-7")" "Decisions pass: blocked: diff.patch is empty" "card after a blocked rerun"

  # A long pass (thousands of events) still gets its session id and review.
  FAKE_OPENCODE=long "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >/dev/null || fail "a long pass"
  assert_eq 'ready ses_fake' "$(jq -r '"\(.status) \(.session_id)"' "$dir/run.json")" "a long pass is ready"

  # One pass at a time. A lock whose process is gone reads as a pass that died.
  ln -s "$$" "$dir/pass.lock"
  assert_has "$("$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" 2>&1 || true)" "already running" "a second pass is refused"
  assert_has "$("$BERCAIL" review-pr rows --stack "$REVIEWS/stack-7")" "running" "a live pass is running"
  rm -f "$dir/run.json"
  ln -sfn 999999 "$dir/pass.lock"
  assert_has "$("$BERCAIL" review-pr rows --stack "$REVIEWS/stack-7")" "failed: the pass stopped before it finished" "a dead pass"
  "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >/dev/null || fail "a dead pass's lock is taken over"
  [[ ! -e "$dir/pass.lock" ]] || fail "the lock goes when the pass ends"

  # The Stack tab's fzf gets a reload when run.json lands.
  "$PY" -I - "$REVIEWS/stack-7/ui.sock" "$LOG/ui.req" <<'PY' &
import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)
c, _ = s.accept(); data = c.recv(65536)
open(sys.argv[2], "wb").write(data)
c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"); c.close()
PY
  local server=$!
  wait_for "$REVIEWS/stack-7/ui.sock"
  "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >/dev/null
  wait "$server"
  assert_has "$(<"$LOG/ui.req")" "reload($ROOT/bin/bercail review-pr rows --stack $REVIEWS/stack-7)" "reload sent to the Stack tab"
  rm -f "$REVIEWS/stack-7/ui.sock"
  assert_eq ready "$(jq -r .status "$dir/run.json")" "rerun is ready again"
  printf 'PASS: run: failed (no block, crash), blocked (drops the old review), a long pass, one pass at a time, a dead pass; the Stack tab reloads\n'
}

test_concurrency() {
  local dir="$REVIEWS/stack-7/pr-7/$SHA7" runner child
  rm -f "$LOG/opencode.child" "$LOG/opencode.release"
  FAKE_HOLD=1 "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >"$LOG/held-run" &
  runner=$!
  wait_for "$LOG/opencode.child"
  child="$(cat "$LOG/opencode.child")"
  assert_has "$("$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" 2>&1 || true)" "already running" "overlapping passes"
  assert_has "$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/7 2>&1 || true)" \
    "review stack is busy" "gather cannot change a running pass's inputs"
  kill -TERM "$runner"
  wait "$runner" && fail "a terminated pass succeeds"
  kill -0 "$child" 2>/dev/null && fail "opencode outlived its wrapper"
  assert_eq failed "$(jq -r .status "$dir/run.json")" "termination records failure"
  [[ ! -L "$dir/pass.lock" && ! -L "$REVIEWS/stack-7/context.lock" ]] || fail "termination kept locks"

  # A fresh acquisition must not bypass a recoverer between its stale-owner
  # check and link replacement, even when no lock link exists at that instant.
  mkdir "$dir/pass.lock.reap"
  assert_has "$("$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" 2>&1 || true)" "already running" "fresh acquisitions respect recovery"
  [[ ! -L "$dir/pass.lock" ]] || fail "fresh acquisition bypassed recovery"
  rmdir "$dir/pass.lock.reap"

  # Many callers reclaiming one dead lock must still start only one pass.
  ln -s 999999 "$dir/pass.lock"
  rm -f "$LOG/opencode.child"
  local i pid winners=0
  local -a pids=()
  for ((i = 0; i < 8; i++)); do
    FAKE_HOLD=1 "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >"$LOG/race-$i" 2>&1 &
    pids+=("$!")
  done
  wait_for "$LOG/opencode.child"
  # Keep the winner running until all contenders have attempted the lock.
  for pid in "${pids[@]}"; do
    [[ "$(readlink "$dir/pass.lock")" == "$pid" ]] || wait "$pid" || true
  done
  touch "$LOG/opencode.release"
  for pid in "${pids[@]}"; do
    if wait "$pid"; then winners=$((winners + 1)); fi
  done
  assert_eq 1 "$winners" "only one stale-lock contender ran"
  printf 'PASS: concurrent passes and gathers refused, termination kills opencode, dead locks have one successor\n'
}

test_ui() {
  local argv
  "$BERCAIL" review-pr ui --stack "$REVIEWS/stack-7"
  argv="$(<"$LOG/fzf.argv")"
  assert_has "$argv" "--listen=$REVIEWS/stack-7/ui.sock" "fzf listens"
  assert_has "$argv" "--preview=$ROOT/bin/bercail review-pr card --stack $REVIEWS/stack-7 {1}" "preview is the card"
  assert_has "$argv" "t:execute-silent($ROOT/bin/bercail review-pr open --stack $REVIEWS/stack-7 {1}" "t opens tuicr"
  assert_has "$argv" "o:execute-silent(gh pr view {1} -R github.com/acme/widgets --web" "o opens the browser"
  grep -q 'review-pr select' <<<"$argv" && fail "a stack of one has no enter bind"
  assert_has "$(<"$LOG/fzf.stdin")" $'7\t#7  Retry flaky uploads' "fzf rows"
  printf 'PASS: ui: fzf with --listen, the card as preview, t and o\n'
}

# --- a Herdr space: Review-<n>_<Repo>, its desk, a Stack tab -----------------------
test_space() {
  local out argv
  export FAKE_HERDR_UP=1
  # The checkout is found through a Herdr space on it, not the caller's cwd.
  jq -n --arg f "$WORK" '{spaces: [{id: "s0", name: "Main_Widgets", folder: $f, tabs: []}]}' >"$HERDR_STATE"
  git -C "$WORK" worktree remove -f "$TMP_DIR/work/widgets.review-7" 2>/dev/null || true
  rm -rf "$REVIEWS/stack-7"
  : >"$LOG/hc"
  out="$(cd / && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/7 --no-run)"
  assert_eq 's1 waiting' "$(jq -r '"\(.space) \(.pass)"' <<<"$out")" "space id, --no-run"
  assert_eq s1 "$(jq -r .space "$REVIEWS/stack-7/stack.json")" "space in stack.json"
  assert_eq "Review-7_Widgets $(cd "$TMP_DIR/work/widgets.review-7" && pwd -P)" \
    "$(jq -r '.spaces[] | select(.id == "s1") | "\(.name) \(.folder)"' "$HERDR_STATE")" "space name and folder"
  [[ "$(git -C "$WORK" worktree list --porcelain)" == *"widgets.review-7"* ]] || fail "sibling worktree of the source"
  argv="$(<"$LOG/stack.argv")"
  assert_eq bash "$(jq -r '.[0]' <<<"$argv")" "Stack tab runs bash -lc"
  assert_has "$(jq -r '.[2]' <<<"$argv")" "exec $ROOT/bin/bercail review-pr ui --stack $REVIEWS/stack-7" "Stack tab runs review-pr ui"
  assert_has "$(<"$LOG/hc")" "--label bercail.space=s1" "the desk starts (bstack on)"
  # Again: the same space and tab, no second desk.
  : >"$LOG/hc"
  rm -f "$LOG/stack.argv"
  (cd / && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/7 --no-run) >/dev/null
  [[ ! -e "$LOG/stack.argv" ]] || fail "a second Stack tab"
  assert_eq 1 "$(jq '[.spaces[] | select(.name == "Review-7_Widgets")] | length' "$HERDR_STATE")" "one space"
  printf 'PASS: a Herdr space Review-<n>_<Repo> on the worktree, its desk, one Stack tab running review-pr ui\n'
}

# --- with the bercail-review mod, the Stack tab is the mod, not fzf ----------------
test_ui_mod() {
  local mods="$HOME/.config/herdr-app/mods/bercail-review" saved="$TMP_DIR/herdr.saved" props
  export FAKE_HERDR_UP=1 HERDR_APP_CONFIG_DIR="$HOME/.config/herdr-app"
  cp "$HERDR_STATE" "$saved"
  mkdir -p "$mods" && : >"$mods/main.js"
  : >"$LOG/herdr"
  rm -f "$LOG/stack.mod" "$LOG/fzf.argv"
  # The space's Stack tab runs fzf (made before the mod): ui opens the mod beside it.
  "$BERCAIL" review-pr ui --stack "$REVIEWS/stack-7"
  [[ ! -e "$LOG/fzf.argv" ]] || fail "ui ran fzf with the mod there"
  props="$(awk '$1 == "bercail-review" { print $2 }' "$LOG/stack.mod")"
  assert_eq "$REVIEWS/stack-7 $ROOT/bin/bercail" "$(jq -r '"\(.stack) \(.bercail)"' <<<"$props")" "mod props"
  # The fzf tab stays: a Stack tab with a terminal may be the mod's with a split.
  assert_eq "fzf mod" "$(jq -r '[.spaces[] | select(.id == "s1") | .tabs[] | select(.name == "Stack")
    | if (.terminals | length) == 0 then "mod" else "fzf" end] | join(" ")' "$HERDR_STATE")" \
    "a mod Stack tab beside the fzf one"
  grep -q "tab.close" "$LOG/herdr" && fail "ui closed a tab"
  assert_has "$(<"$LOG/herdr")" "do space.select --id s1" "ui shows the review space"
  # Again: the same tab, shown.
  "$BERCAIL" review-pr ui --stack "$REVIEWS/stack-7"
  assert_eq 1 "$(wc -l <"$LOG/stack.mod" | tr -d ' ')" "no second mod tab"
  assert_has "$(<"$LOG/herdr")" "do tab.select --id $(jq -r '.spaces[] | select(.id == "s1") | .tabs[] | select(.name == "Stack" and (.terminals | length) == 0) | .id' "$HERDR_STATE")" "ui selects the mod tab"
  # A new review space gets the mod as its Stack tab.
  jq '.spaces |= map(select(.id != "s1"))' "$saved" >"$HERDR_STATE"
  rm -f "$LOG/stack.mod" "$LOG/stack.argv"
  (cd / && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/7 --no-run) >/dev/null
  [[ ! -e "$LOG/stack.argv" ]] || fail "gather made an fzf Stack tab with the mod there"
  assert_eq 1 "$(wc -l <"$LOG/stack.mod" | tr -d ' ')" "gather made the mod Stack tab"
  # No Herdr app: fzf, as before.
  FAKE_HERDR_UP="" "$BERCAIL" review-pr ui --stack "$REVIEWS/stack-7"
  [[ -e "$LOG/fzf.argv" ]] || fail "no Herdr app: ui runs fzf"
  rm -rf "$mods"
  cp "$saved" "$HERDR_STATE"
  unset HERDR_APP_CONFIG_DIR
  printf 'PASS: ui with the mod: one mod Stack tab, shown; gather makes it; fzf without the Herdr app\n'
}

# --- open: tuicr pr N via the desk mod, seeded with [AI Agent] questions ----------
test_open() {
  local out dir="$REVIEWS/stack-7/pr-7/$SHA7"
  FAKE_OPENCODE=ok "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >/dev/null
  : >"$LOG/herdr"
  (cd "$TMP_DIR/work/widgets.review-7" && FAKE_TUICR_HOLD=1 HC_TERMINAL_ID=t-elsewhere BERCAIL_REVIEW_OPEN_WAIT=5 "$BERCAIL" review-pr open) >"$LOG/open-result" &
  local opener=$!
  wait_for "$LOG/tuicr.held"
  assert_has "$("$BERCAIL" review-pr open --stack "$REVIEWS/stack-7" 2>&1 || true)" "already being opened" "a second open cannot duplicate drafts"
  touch "$LOG/tuicr.release"
  wait "$opener"
  out="$(cat "$LOG/open-result")"
  assert_has "$(<"$LOG/herdr")" "do bercail-desk.review-pr-7:t-sh" "the desk mod action, on the review space's terminal (not the caller's)"
  [[ "$(cat "$LOG/tuicr.lists")" -ge 2 ]] || fail "open waits for the active session"
  assert_eq gh:acme/widgets/pr/7 "$(jq -r .session <<<"$out")" "session slug"
  assert_eq 3 "$(jq '.comments | length' "$dir/seeded.json")" "three questions seeded"
  assert_eq 'c1 c2 c3' "$(jq -r '[.comments[].id] | join(" ")' "$dir/seeded.json")" "tuicr ids saved"
  assert_eq '{"content":"[AI Agent] Why 5 retries with no backoff? The issue asks for backoff.","type":"note","username":"bstack","file":"lib/upload.sh","side":"new","line":12}' \
    "$(sed -n 1p "$LOG/tuicr.add")" "an anchored question"
  assert_eq '{"content":"[AI Agent] (outside.txt:40) Was dropping the timeout intended?","type":"note","username":"bstack"}' \
    "$(sed -n 2p "$LOG/tuicr.add")" "a line tuicr can't anchor becomes a review comment"
  assert_eq '{"content":"[AI Agent] The issue asks to log each retry; is that in another PR?","type":"note","username":"bstack"}' \
    "$(sed -n 3p "$LOG/tuicr.add")" "a whole-PR question has no file"
  (cd "$TMP_DIR/work/widgets.review-7" && HC_TERMINAL_ID=t-stack BERCAIL_REVIEW_OPEN_WAIT=5 "$BERCAIL" review-pr open) >/dev/null 2>&1
  assert_eq 3 "$(wc -l <"$LOG/tuicr.add" | tr -d ' ')" "opening again does not seed twice"
  printf 'PASS: open: bercail-desk.review-pr-N, waits for tuicr, seeds [AI Agent] notes as bstack, ids in seeded.json\n'
  unset FAKE_HERDR_UP
}

# --- the blobless clone when no checkout is around; no checks at all ---------------
test_clone_and_no_checks() {
  # Another repo name forces the no-local-checkout path.
  local out
  REVIEWS="$XDG_STATE_HOME/bercail/reviews/github.com/acme/remote-only"
  mkdir -p "$REVIEWS"
  out="$(cd / && FAKE_NO_CHECKS=1 "$BERCAIL" review-pr https://github.com/acme/remote-only/pull/8)"
  [[ -d "$HOME/Work/remote-only" ]] || fail "no fallback checkout at ~/Work/remote-only"
  [[ ! -d "$REVIEWS/clone.git" && ! -d "$REVIEWS/stack-8/worktree" ]] || fail "fallback must not live in the state dir"
  assert_eq "$SHA8" "$(git -C "$HOME/Work/remote-only.review-8" rev-parse HEAD)" "sibling of the fallback checkout"
  # No JSON from gh pr checks: the rollup from gh pr view stands in.
  assert_eq '[{"name":"lint","workflow":"CI","state":"FAILURE","link":"https://ci/lint","bucket":"fail"}]' \
    "$(jq -c . "$REVIEWS/stack-8/pr-8/$SHA8/ci.json")" "ci.json from statusCheckRollup"
  assert_eq '{"fail":1}' "$(jq -c '.prs[0].ci' <<<"$out")" "rollup CI counts"
  # A push to the PR, then review-pr from the local checkout: the new head is
  # fetched into the private clone the worktree came from.
  local sha
  sha="$(cd "$TMP_DIR/seed" && git switch -q docs && echo again >>README && git commit -qam again && git rev-parse HEAD)"
  git -C "$TMP_DIR/seed" push -q "$REMOTE" HEAD:refs/pull/8/head
  jq --arg s "$sha" '.headRefOid = $s' "$FIX/pr-8.json" >"$FIX/pr-8.json.new" && mv "$FIX/pr-8.json.new" "$FIX/pr-8.json"
  # Not while a pass on the old head runs: the stack has one worktree.
  ln -s "$$" "$REVIEWS/stack-8/context.lock"
  assert_has "$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/remote-only/pull/8 2>&1 || true)" \
    "the review stack is busy" "the worktree does not move under a live pass"
  assert_eq "$SHA8" "$(git -C "$HOME/Work/remote-only.review-8" rev-parse HEAD)" "the worktree stays"
  rm -f "$REVIEWS/stack-8/context.lock"
  (cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/remote-only/pull/8) >/dev/null
  assert_eq "$sha" "$(git -C "$HOME/Work/remote-only.review-8" rev-parse HEAD)" "the worktree moves to the new head"
  [[ -s "$REVIEWS/stack-8/pr-8/$sha/intent.md" ]] || fail "a run dir for the new head"
  # A pass queued for the old head does not review the new one.
  "$BERCAIL" review-pr run 8 --head "$SHA8" --stack "$REVIEWS/stack-8" >/dev/null && fail "a pass for a head the worktree left"
  assert_has "$(jq -r .reason "$REVIEWS/stack-8/pr-8/$SHA8/run.json")" "not the gathered head" "the old head's pass fails"
  [[ ! -e "$REVIEWS/stack-8/pr-8/$sha/run.json" ]] || fail "the new head gets no run.json from it"
  printf 'PASS: no checkout around: ~/Work/<repo> plus a sibling; no gh pr checks JSON: the rollup; a queued head does not review a newer one\n'
}

test_help() {
  assert_has "$("$BERCAIL" help)" "review-pr" "bercail help lists review-pr"
  assert_has "$("$BERCAIL" nope 2>&1 || true)" "review-pr" "usage lists review-pr"
  assert_has "$("$BERCAIL" review-pr)" "open [N]" "review-pr usage"
  assert_has "$("$BERCAIL" review-pr https://github.com/acme/widgets/issues/1 2>&1 || true)" "not a pull request URL" "bad URL"
  grep -qx 'agents/bstack-pr-review.md' "$ROOT/bstack/MANIFEST" || fail "MANIFEST ships the agent"
  grep -qx 'commands/pr-review.md' "$ROOT/bstack/MANIFEST" || fail "MANIFEST ships the command"
  printf 'PASS: help and usage list review-pr; bad URLs are refused\n'
}

test_agent_permissions() {
  local f="$ROOT/bstack/agents/bstack-pr-review.md" perms
  perms="$(awk '/^permissions:/ { on = 1; next } on && /^---/ { exit } on' "$f" | paste -sd' ' | tr -s ' ')"
  assert_has "$perms" '- action: edit resource: "*" effect: deny' "edit denied"
  assert_has "$perms" '- action: subagent resource: "*" effect: deny' "subagents denied"
  assert_has "$perms" '- action: shell resource: "*" effect: deny' "shell denied"
  assert_has "$perms" '- action: external_directory resource: "*" effect: deny' "nothing read outside the stack dir"
  assert_has "$perms" '- action: "*" resource: "*" effect: deny' "unknown tools and MCP denied"
  assert_eq 3 "$(grep -c 'effect: allow' "$f")" "only read, glob and grep are allowed"
  printf 'PASS: bstack-pr-review: edit, subagents, shell, and reads outside the stack dir denied\n'
}

test_stacks() {
  local seed="$TMP_DIR/seed" main_sha src_head src_branch src_status src_cfg other
  main_sha="$(git -C "$seed" rev-parse main)"
  src_head="$(git -C "$WORK" rev-parse HEAD)"
  src_branch="$(git -C "$WORK" branch --show-current)"
  src_status="$(git -C "$WORK" status --porcelain)"
  src_cfg="$(git -C "$WORK" config --local --list | sort)"
  printf 'sentinel\n' >"$WORK/.git/FETCH_HEAD"
  other="$TMP_DIR/work/widgets.other"
  git -C "$WORK" worktree add --detach -q "$other" HEAD
  local other_sha
  other_sha="$(git -C "$other" rev-parse HEAD)"

  git -C "$seed" switch -q main
  git -C "$seed" switch -qc s1
  mkdir -p "$seed/lib"
  printf 'S1ONLY\n' >"$seed/lib/s1.sh"
  git -C "$seed" add lib/s1.sh && git -C "$seed" commit -qm s1
  local sha21
  sha21="$(git -C "$seed" rev-parse HEAD)"
  git -C "$seed" push -q "$REMOTE" HEAD:refs/pull/21/head
  git -C "$seed" switch -qc s2
  printf 'S2ONLY\n' >"$seed/lib/s2.sh"
  ln -s /etc/hostname "$seed/lib/s2-link"
  git -C "$seed" add lib/s2.sh lib/s2-link && git -C "$seed" commit -qm s2
  local sha22
  sha22="$(git -C "$seed" rev-parse HEAD)"
  git -C "$seed" push -q "$REMOTE" HEAD:refs/pull/22/head
  git -C "$seed" switch -qc s3
  printf 'S3ONLY\n' >"$seed/lib/s3.sh"
  printf '{}\n' >"$seed/package-lock.json"
  git -C "$seed" add lib/s3.sh package-lock.json && git -C "$seed" commit -qm s3
  local sha23
  sha23="$(git -C "$seed" rev-parse HEAD)"
  git -C "$seed" push -q "$REMOTE" HEAD:refs/pull/23/head

  pr_stack() { # n sha title body base head base_sha
    jq -n --argjson n "$1" --arg sha "$2" --arg title "$3" --arg body "$4" --arg base "$5" --arg head "$6" --arg bsha "$7" '{
      number: $n, title: $title, body: $body, url: "https://github.com/acme/widgets/pull/\($n)",
      author: {login: "dana"}, isDraft: false, baseRefName: $base, headRefName: $head,
      headRefOid: $sha, baseRefOid: $bsha, closingIssuesReferences: [],
      files: [{path: "lib/\($head).sh", additions: 1, deletions: 0, changeType: "ADDED"}],
      statusCheckRollup: []}' >"$FIX/pr-$1.json"
  }
  pr_stack 21 "$sha21" "Stack one" "Adds the first slice." main s1 "$main_sha"
  pr_stack 22 "$sha22" "Stack two" "" s1 s2 "$sha21"
  pr_stack 23 "$sha23" "Stack three" "Adds the third slice." s2 s3 "$sha22"
  local linked='[{"number":12,"url":"https://github.com/acme/widgets/issues/12"}]'
  for n in 21 23; do
    jq --argjson c "$linked" '.closingIssuesReferences = $c' "$FIX/pr-$n.json" >"$FIX/pr-$n.json.new"
    mv "$FIX/pr-$n.json.new" "$FIX/pr-$n.json"
  done
  jq -n --argjson n 21 --arg base main --arg head s1 '[{number:$n, baseRefName:$base, headRefName:$head, url:"https://github.com/acme/widgets/pull/21"}]' >"$FIX/list-head-s1.json"
  jq -n --argjson n 22 --arg base s1 --arg head s2 '[{number:$n, baseRefName:$base, headRefName:$head, url:"https://github.com/acme/widgets/pull/22"}]' >"$FIX/list-head-s2.json"
  jq -n --argjson n 22 --arg base s1 --arg head s2 '[{number:$n, baseRefName:$base, headRefName:$head, url:"https://github.com/acme/widgets/pull/22"}]' >"$FIX/list-base-s1.json"
  jq -n --argjson n 23 --arg base s2 --arg head s3 '[{number:$n, baseRefName:$base, headRefName:$head, url:"https://github.com/acme/widgets/pull/23"}]' >"$FIX/list-base-s2.json"

  local wreviews="$XDG_STATE_HOME/bercail/reviews/github.com/acme/widgets"
  local out stack="$wreviews/stack-21" sib="$TMP_DIR/work/widgets.review-21"
  out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/22 --no-run)"
  assert_eq "$stack" "$(jq -r .stack <<<"$out")" "middle PR uses the root run dir"
  assert_eq "$sib" "$(jq -r .worktree <<<"$out")" "middle PR uses the root sibling"
  assert_eq '21 22 23' "$(jq -r '[.prs[].number] | join(" ")' "$stack/stack.json")" "root-to-tip order"
  assert_eq "$main_sha $sha21 $sha22" "$(jq -r '[.prs[].base_sha] | join(" ")' "$stack/stack.json")" "base shas: trunk, then parent heads"
  assert_eq "$sha21" "$(git -C "$sib" rev-parse HEAD)" "worktree starts at the root head"
  assert_has "$(<"$stack/stack.md")" "1. #21" "stack.md order"
  assert_eq '[] ["empty_body","no_linked_issue"] []' "$(jq -r '[.prs[].thin | tojson] | join(" ")' <<<"$out")" "thin is per PR"
  assert_eq 'waiting waiting waiting' "$(jq -r '[.prs[].pass] | join(" ")' <<<"$out")" "--no-run waits"
  local mid
  mid="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/23 --no-run)"
  assert_eq "$stack $sib" "$(jq -r '"\(.stack) \(.worktree)"' <<<"$mid")" "top PR is the same space"
  mid="$(cd "$WORK" && "$BERCAIL" review-pr s2 --no-run)"
  assert_eq "$stack" "$(jq -r .stack <<<"$mid")" "branch input is the same stack"
  assert_has "$(<"$stack/pr-22/$sha22/diff.patch")" "S2ONLY" "diff vs parent includes this PR"
  grep -q S1ONLY "$stack/pr-22/$sha22/diff.patch" && fail "diff vs parent must not be the trunk diff"
  [[ ! -e "$stack/pr-23/$sha23/source/package-lock.json" ]] || fail "lock file not snapshotted"
  [[ -s "$stack/pr-22/$sha22/source/lib/s2.sh" ]] || fail "parent diff snapshot"
  env PAGER=cat "$BERCAIL" review-pr diff 22 --stack "$stack" >"$LOG/diff22"
  assert_has "$(<"$LOG/diff22")" "S2ONLY" "d is git diff parent...head"
  "$BERCAIL" review-pr select 23 --stack "$stack"
  assert_eq "$sha23" "$(git -C "$sib" rev-parse HEAD)" "enter detaches the sibling"
  assert_eq 23 "$(jq -r .current "$stack/stack.json")" "current follows select"
  assert_eq "$src_head" "$(git -C "$WORK" rev-parse HEAD)" "select does not move the source"
  assert_eq '23 21,22,23 waiting,thin,waiting true' "$("$BERCAIL" review-pr state --stack "$stack" | jq -r '
    "\(.current) \([.prs[].number] | join(",")) \([.prs[] | if (.thin | length) > 0 then "thin" else .pass end] | join(",")) \(.header | test("1. #21"))"')" \
    "state: the Stack tab's input for a real stack"
  # A failed regather must not publish a new stack.json that resets current to the root.
  "$BERCAIL" review-pr select 22 --stack "$stack"
  assert_eq "$sha22" "$(git -C "$sib" rev-parse HEAD)" "select middle"
  cp "$stack/stack.json" "$LOG/stack-before-dirty.json"
  printf 'note\n' >"$sib/review-pr-dirty-note"
  assert_has "$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/22 --no-run 2>&1 || true)" \
    "local changes" "dirty review worktree refuses regather"
  cmp -s "$LOG/stack-before-dirty.json" "$stack/stack.json" || fail "failed gather rewrote stack.json"
  assert_eq 22 "$(jq -r .current "$stack/stack.json")" "current stays on the selected middle"
  assert_eq "$sha22" "$(git -C "$sib" rev-parse HEAD)" "dirty refuse leaves the worktree"
  rm -f "$sib/review-pr-dirty-note"

  sha21="$(jq -r '.prs[0].head_sha' "$stack/stack.json")"
  sha22="$(jq -r '.prs[1].head_sha' "$stack/stack.json")"
  sha23="$(jq -r '.prs[2].head_sha' "$stack/stack.json")"
  rm -f "$LOG/opencode.child" "$LOG/opencode.release"
  FAKE_HOLD=1 "$BERCAIL" review-pr run --stack "$stack" >"$LOG/multi-run" 2>"$LOG/multi-err" &
  local launcher=$!
  sleep 1
  [[ -L "$stack/pr-21/$sha21/pass.lock" ]] || {
    echo "MULTI out=$(cat "$LOG/multi-run" 2>/dev/null) err=$(cat "$LOG/multi-err" 2>/dev/null)" >&2
    find "$stack" -name 'pass.lock' -o -name 'pass.err' -o -name 'run.json' >&2
    fail "parallel run did not lock PR 21"
  }
  sleep 0.5
  [[ -L "$stack/pr-23/$sha23/pass.lock" ]] || {
    echo "23 missing sha=$sha23" >&2
    find "$stack/pr-23" -maxdepth 2 -type d -o -name 'pass.*' -o -name 'run.json' >&2
    echo "err23=$(cat "$stack"/pr-23/*/pass.err 2>/dev/null)" >&2
    fail "parallel run did not lock PR 23"
  }
  [[ ! -L "$stack/pr-22/$sha22/pass.lock" ]] || fail "a thin PR is not started by run without N"
  [[ ! -L "$stack/context.lock" ]] || fail "passes must not hold the stack lock"
  touch "$LOG/opencode.release"
  wait "$launcher"
  assert_eq ready "$(jq -r .status "$stack/pr-21/$sha21/run.json")" "parallel pass 21"
  assert_eq ready "$(jq -r .status "$stack/pr-23/$sha23/run.json")" "parallel pass 23"
  [[ ! -e "$stack/pr-22/$sha22/run.json" ]] || fail "thin PR still waiting"
  "$BERCAIL" review-pr run 22 --stack "$stack" >/dev/null
  assert_eq ready "$(jq -r .status "$stack/pr-22/$sha22/run.json")" "explicit run of a thin PR"

  "$BERCAIL" review-pr ui --stack "$stack"
  assert_has "$(<"$LOG/fzf.argv")" "review-pr select" "multi fzf enter"
  assert_has "$(<"$LOG/fzf.argv")" "review-pr diff" "multi fzf d"
  assert_has "$(<"$LOG/fzf.argv")" "Stack one" "multi header from stack.md"

  pr_stack 41 "$main_sha" "Fork root" "Root of a fork." main fork-a "$main_sha"
  pr_stack 42 "$main_sha" "Fork mid" "Middle of a fork." fork-a up-b "$main_sha"
  pr_stack 44 "$main_sha" "Fork leaf" "Leaf of a fork." up-b up-b2 "$main_sha"
  jq -n '[{number:42, baseRefName:"fork-a", headRefName:"up-b", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/42"},
          {number:43, baseRefName:"fork-a", headRefName:"up-c", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/43"}]' >"$FIX/list-base-fork-a.json"
  jq -n '[{number:41, baseRefName:"main", headRefName:"fork-a", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/41"}]' >"$FIX/list-head-fork-a.json"
  jq -n '[{number:42, baseRefName:"fork-a", headRefName:"up-b", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/42"}]' >"$FIX/list-head-up-b.json"
  jq -n '[{number:44, baseRefName:"up-b", headRefName:"up-b2", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/44"}]' >"$FIX/list-base-up-b.json"
  # Middle and leaf first, so a partial stack-41 cannot already exist.
  local fork_out
  fork_out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/42 --no-run 2>"$LOG/fork42.err")"
  assert_has "$(<"$LOG/fork42.err")" "branched stack; reviewing PR #42 alone" "fork entered from the middle"
  assert_eq '42' "$(jq -r '[.prs[].number] | join(" ")' <<<"$fork_out")" "middle fork is only itself"
  assert_eq "$wreviews/stack-42" "$(jq -r .stack <<<"$fork_out")" "middle fork run dir is its own"
  [[ ! -f "$wreviews/stack-41/stack.json" ]] || fail "middle fork must not write the root stack"
  fork_out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/44 --no-run 2>"$LOG/fork44.err")"
  assert_has "$(<"$LOG/fork44.err")" "branched stack; reviewing PR #44 alone" "fork entered from a leaf"
  assert_eq '44' "$(jq -r '[.prs[].number] | join(" ")' <<<"$fork_out")" "leaf fork is only itself"
  assert_eq "$wreviews/stack-44" "$(jq -r .stack <<<"$fork_out")" "leaf fork run dir is its own"
  [[ ! -f "$wreviews/stack-41/stack.json" ]] || fail "leaf fork must not write the root stack"
  fork_out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/41 --no-run 2>"$LOG/fork41.err")"
  assert_has "$(<"$LOG/fork41.err")" "branched stack; reviewing PR #41 alone" "fork entered from the root"
  assert_eq '41' "$(jq -r '[.prs[].number] | join(" ")' <<<"$fork_out")" "root fork is only itself"
  assert_eq "$wreviews/stack-41" "$(jq -r .stack <<<"$fork_out")" "root fork run dir is its own"
  # Two open PRs with the same head: same standalone fallback, not a hard error.
  pr_stack 47 "$main_sha" "Twin" "Two parents." twin-head feat47 "$main_sha"
  jq -n '[{number:48, baseRefName:"main", headRefName:"twin-head", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/48"},
          {number:49, baseRefName:"main", headRefName:"twin-head", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/49"}]' >"$FIX/list-head-twin-head.json"
  fork_out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/47 --no-run 2>"$LOG/fork47.err")"
  assert_has "$(<"$LOG/fork47.err")" "branched stack; reviewing PR #47 alone" "duplicate heads fall back to the entry"
  assert_eq '47' "$(jq -r '[.prs[].number] | join(" ")' <<<"$fork_out")" "duplicate heads review only the entry"

  # Trunk is origin/HEAD. A cross-repo PR whose head is also named main is not a parent
  # and is not walked up from. Other PRs based on main are not children of develop.
  jq -n --arg sha "$main_sha" '[{number:99, baseRefName:"main", headRefName:"other", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/99"},
    {number:71, baseRefName:"main", headRefName:"feat", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/71"}]' >"$FIX/list-base-main.json"
  jq -n --arg sha "$main_sha" '[{number:72, baseRefName:"main", headRefName:"main", isCrossRepository:true, url:"https://github.com/acme/widgets/pull/72"}]' >"$FIX/list-head-main.json"
  pr_stack 71 "$main_sha" "Internal feat" "An internal PR." main feat "$main_sha"
  pr_stack 72 "$main_sha" "Cross fork" "From a fork." main main "$main_sha"
  pr_stack 73 "$main_sha" "Develop" "Based on develop." main develop "$main_sha"
  jq '.isCrossRepository = false' "$FIX/pr-71.json" >"$FIX/pr-71.json.new" && mv "$FIX/pr-71.json.new" "$FIX/pr-71.json"
  jq '.isCrossRepository = true' "$FIX/pr-72.json" >"$FIX/pr-72.json.new" && mv "$FIX/pr-72.json.new" "$FIX/pr-72.json"
  jq '.isCrossRepository = false' "$FIX/pr-73.json" >"$FIX/pr-73.json.new" && mv "$FIX/pr-73.json.new" "$FIX/pr-73.json"
  local gh_before cross_out
  gh_before="$(wc -l <"$LOG/gh")"
  cross_out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/71 --no-run)"
  assert_eq '71' "$(jq -r '[.prs[].number] | join(" ")' <<<"$cross_out")" "internal feat→main is its own stack"
  tail -n +$((gh_before + 1)) "$LOG/gh" | grep -q -- '--head main' && fail "down walk must not probe --head trunk"
  cross_out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/72 --no-run)"
  assert_eq '72' "$(jq -r '[.prs[].number] | join(" ")' <<<"$cross_out")" "a cross-repo PR is a stack of one"
  cross_out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/73 --no-run)"
  assert_eq '73' "$(jq -r '[.prs[].number] | join(" ")' <<<"$cross_out")" "develop→main does not collect other main PRs"
  # A unique cross-repo child of a same-repo branch stays in the stack.
  pr_stack 81 "$main_sha" "Feat parent" "Parent." main feat81 "$main_sha"
  pr_stack 82 "$main_sha" "Fork child" "Child." feat81 forkfeat "$main_sha"
  jq '.isCrossRepository = true' "$FIX/pr-82.json" >"$FIX/pr-82.json.new" && mv "$FIX/pr-82.json.new" "$FIX/pr-82.json"
  jq -n '[{number:81, baseRefName:"main", headRefName:"feat81", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/81"}]' >"$FIX/list-head-feat81.json"
  jq -n '[{number:82, baseRefName:"feat81", headRefName:"forkfeat", isCrossRepository:true, url:"https://github.com/acme/widgets/pull/82"}]' >"$FIX/list-base-feat81.json"
  cross_out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/82 --no-run)"
  assert_eq '81 82' "$(jq -r '[.prs[].number] | join(" ")' <<<"$cross_out")" "unique cross-repo child stays, entered from the child"
  cross_out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/81 --no-run)"
  assert_eq '81 82' "$(jq -r '[.prs[].number] | join(" ")' <<<"$cross_out")" "unique cross-repo child stays, entered from the parent"
  # Root base is develop, not the default main. No open PR has head develop.
  pr_stack 91 "$main_sha" "Release" "Release train." develop rel91 "$main_sha"
  pr_stack 92 "$main_sha" "On release" "Child of the release." rel91 rel92 "$main_sha"
  jq -n '[{number:91, baseRefName:"develop", headRefName:"rel91", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/91"}]' >"$FIX/list-head-rel91.json"
  jq -n '[{number:92, baseRefName:"rel91", headRefName:"rel92", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/92"}]' >"$FIX/list-base-rel91.json"
  cross_out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/91 --no-run)"
  assert_eq '91 92' "$(jq -r '[.prs[].number] | join(" ")' <<<"$cross_out")" "develop root entered from the root"
  assert_eq develop "$(jq -r .trunk "$wreviews/stack-91/stack.json")" "trunk is the root base, not default main"
  cross_out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/92 --no-run)"
  assert_eq '91 92' "$(jq -r '[.prs[].number] | join(" ")' <<<"$cross_out")" "develop root entered from the child"
  assert_eq develop "$(jq -r .trunk "$wreviews/stack-91/stack.json")" "child entry keeps trunk develop"

  jq -n --arg sha "$sha21" '{number:51, title:"cycle a", body:"a", url:"https://github.com/acme/widgets/pull/51",
    author:{login:"dana"}, isDraft:false, baseRefName:"cycle-b", headRefName:"cycle-a",
    headRefOid:$sha, baseRefOid:$sha, closingIssuesReferences:[], files:[], statusCheckRollup:[]}' >"$FIX/pr-51.json"
  jq -n --arg sha "$sha22" '{number:52, title:"cycle b", body:"b", url:"https://github.com/acme/widgets/pull/52",
    author:{login:"dana"}, isDraft:false, baseRefName:"cycle-a", headRefName:"cycle-b",
    headRefOid:$sha, baseRefOid:$sha, closingIssuesReferences:[], files:[], statusCheckRollup:[]}' >"$FIX/pr-52.json"
  jq -n '[{number:52, baseRefName:"cycle-a", headRefName:"cycle-b", url:"https://github.com/acme/widgets/pull/52"}]' >"$FIX/list-head-cycle-b.json"
  jq -n '[{number:51, baseRefName:"cycle-b", headRefName:"cycle-a", url:"https://github.com/acme/widgets/pull/51"}]' >"$FIX/list-head-cycle-a.json"
  assert_has "$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/51 2>&1 || true)" \
    "cycle" "a cycle is an error"

  rm -f "$LOG/gh.held" "$LOG/gh.release" "$LOG/opencode.release"
  FAKE_GH_HOLD=1 "$BERCAIL" review-pr https://github.com/acme/widgets/pull/21 --no-run >"$LOG/gather-hold" &
  local holder=$!
  wait_for "$LOG/gh.held"
  [[ -L "$stack/context.lock" ]] || fail "gather did not take the context lock"
  assert_has "$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/21 --no-run 2>&1 || true)" \
    "review stack is busy" "a second gather waits"
  touch "$LOG/gh.release"
  wait "$holder"
  unset FAKE_GH_HOLD

  # Graphite: five PRs, entered from the middle. gt runs only in a private clone.
  local i gsha prev="$main_sha"
  git -C "$seed" switch -q main
  for i in 1 2 3 4 5; do
    git -C "$seed" switch -qc "g$i"
    printf 'G%s\n' "$i" >"$seed/g$i.txt"
    git -C "$seed" add "g$i.txt" && git -C "$seed" commit -qm "g$i"
    gsha="$(git -C "$seed" rev-parse HEAD)"
    git -C "$seed" push -q "$REMOTE" "HEAD:refs/pull/$((30 + i))/head"
    local base_name=main
    [[ "$i" -gt 1 ]] && base_name="g$((i - 1))"
    pr_stack $((30 + i)) "$gsha" "Graphite $i" "Graphite slice $i." \
      "$base_name" "g$i" "$prev"
    prev="$gsha"
  done
  jq '.body = ""' "$FIX/pr-32.json" >"$FIX/pr-32.json.new" && mv "$FIX/pr-32.json.new" "$FIX/pr-32.json"
  for n in 31 33 34 35; do
    jq --argjson c "$linked" '.closingIssuesReferences = $c' "$FIX/pr-$n.json" >"$FIX/pr-$n.json.new"
    mv "$FIX/pr-$n.json.new" "$FIX/pr-$n.json"
  done
  cat >"$FIX/gt-log" <<'EOF'
◯                        g5
◯                        g4
◉                        g3
◯                        g2
◯                        g1
◯                        main
EOF
  # gt 1.8.6 leaves Children: empty even for a parent. The log drawing is the fork check.
  local name parent n
  for i in 1 2 3 4 5; do
    name="g$i"
    n=$((30 + i))
    if [[ "$i" -eq 1 ]]; then parent=main; else parent="g$((i - 1))"; fi
    printf '%s\n\nPR #%s graphite\n\nParent: %s\nChildren:\n\ncommit abc\n' "$name" "$n" "$parent" >"$FIX/gt-info-$name"
  done
  local gcfg
  gcfg="$(git -C "$WORK" rev-parse --path-format=absolute --git-common-dir)/.graphite_repo_config"
  printf '%s\n' '{"trunk":"main"}' >"$gcfg"
  : >"$LOG/gt"
  out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/33 --no-run)"
  rm -f "$gcfg"
  assert_eq "$wreviews/stack-31" "$(jq -r .stack <<<"$out")" "graphite middle PR uses the root"
  assert_eq '31 32 33 34 35' "$(jq -r '[.prs[].number] | join(" ")' "$wreviews/stack-31/stack.json")" "five-PR graphite stack"
  assert_eq '["empty_body","no_linked_issue"]' "$(jq -c '.prs[1].thin' <<<"$out")" "one thin PR in the stack"
  grep -q -- '--no-checkout' "$LOG/gt" || fail "gt get --no-checkout"
  grep -q -- '--remote-upstack' "$LOG/gt" || fail "gt get --remote-upstack"
  grep -q -- '--no-restack' "$LOG/gt" || fail "gt get --no-restack"
  grep -q 'get g1 ' "$LOG/gt" || fail "gt get of the stack root when the entry is not the root"
  grep -q 'gt-sync' "$LOG/gt" || fail "gt runs in the private clone"
  grep -q "$WORK" "$LOG/gt" && fail "gt must not run against the source"
  # A log from a leaf omits a sibling below it. The second log, from the root, shows the fork.
  printf '%s\n' '{"trunk":"main"}' >"$gcfg"
  local gt_before
  gt_before="$(wc -l <"$LOG/gt")"
  cross_out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/72 --no-run)"
  assert_eq '72' "$(jq -r '[.prs[].number] | join(" ")' <<<"$cross_out")" "fork entry in a Graphite repo uses the GitHub walk"
  assert_eq "$gt_before" "$(wc -l <"$LOG/gt")" "gt must not sync a foreign head branch"
  pr_stack 61 "$main_sha" "gt leaf" "Leaf of a graphite fork." groot gleaf "$main_sha"
  cat >"$FIX/gt-log-gleaf" <<'EOF'
◯                        gleaf
◯                        groot
◯                        main
EOF
  cat >"$FIX/gt-log-groot" <<'EOF'
◯                        gleaf
│ ◯                      gsib
◯─┘                      groot
◯                        main
EOF
  fork_out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/61 --no-run 2>"$LOG/gtfork.err")"
  assert_has "$(<"$LOG/gtfork.err")" "branched stack; reviewing PR #61 alone" "graphite fork entered from a leaf"
  assert_eq '61' "$(jq -r '[.prs[].number] | join(" ")' <<<"$fork_out")" "graphite fork is only the entry"
  assert_eq "$wreviews/stack-61" "$(jq -r .stack <<<"$fork_out")" "graphite fork run dir is the entry"
  grep -q 'get groot ' "$LOG/gt" || fail "gt get of the graphite root after a leaf entry"
  rm -f "$gcfg"
  local sync="$XDG_STATE_HOME/bercail/reviews/github.com/acme/widgets/gt-sync"
  [[ "$(git -C "$sync" rev-parse --path-format=absolute --git-common-dir)" != "$(git -C "$WORK" rev-parse --path-format=absolute --git-common-dir)" ]] \
    || fail "private clone must not share the source git dir"

  assert_eq "$src_head" "$(git -C "$WORK" rev-parse HEAD)" "source HEAD unchanged"
  assert_eq "$src_branch" "$(git -C "$WORK" branch --show-current)" "source branch unchanged"
  assert_eq "$src_status" "$(git -C "$WORK" status --porcelain)" "source status unchanged"
  assert_eq "$src_cfg" "$(git -C "$WORK" config --local --list | sort)" "source config unchanged"
  assert_eq "$other_sha" "$(git -C "$other" rev-parse HEAD)" "another worktree is untouched"
  assert_eq sentinel "$(cat "$WORK/.git/FETCH_HEAD")" "FETCH_HEAD is not rewritten"
  printf 'PASS: generic 3-PR stack, graphite 5-PR stack, middle PR, thin, parallel passes, ambiguous and cycle refused\n'

  printf 'occupied\n' >"$HOME/Work/occupied"
  out="$(cd / && "$BERCAIL" review-pr https://github.com/acme/occupied/pull/8 --no-run)"
  [[ -f "$HOME/Work/occupied" && "$(cat "$HOME/Work/occupied")" == occupied ]] || fail "fallback must not overwrite"
  [[ -d "$HOME/Work/acme-occupied" ]] || fail "fallback uses ~/Work/<owner>-<repo> when ~/Work/<repo> is taken"
  assert_eq "$(jq -r .headRefOid "$FIX/pr-8.json")" "$(git -C "$HOME/Work/acme-occupied.review-8" rev-parse HEAD)" "sibling of the alternate checkout"
  printf 'PASS: no-source fallback is ~/Work/<repo>, or ~/Work/<owner>-<repo> if that path is taken\n'
}

test_thin_rules
test_thin_pr_stops
test_pass
test_card
test_run_outcomes
test_concurrency
test_ui
test_space
test_open
test_ui_mod
test_clone_and_no_checks
test_stacks
test_help
test_agent_permissions
