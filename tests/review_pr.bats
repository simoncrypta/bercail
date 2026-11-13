#!/usr/bin/env bats
# bercail review-pr against fake gh, pi, tuicr, herdr-app, and hc.
# No network: the PR heads come from a local bare repo.

assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1' got '$2'"; }
assert_has() { grep -qF -- "$2" <<<"$1" || fail "$3: no '$2' in:"$'\n'"$1"; }

pr_json() { # n sha title body closing
  jq -n --argjson n "$1" --arg sha "$2" --arg title "$3" --arg body "$4" --argjson closing "$5" '{
    number: $n, title: $title, body: $body, url: "https://github.com/acme/widgets/pull/\($n)",
    author: {login: "dana"}, isDraft: false, baseRefName: "main", headRefName: "retry", headRefOid: $sha,
    closingIssuesReferences: $closing,
    files: [{path: "lib/retry.sh", additions: 1, deletions: 0, changeType: "ADDED"},
            {path: "package-lock.json", additions: 40, deletions: 2, changeType: "MODIFIED"}],
    statusCheckRollup: [{__typename: "CheckRun", name: "lint", workflowName: "CI", conclusion: "FAILURE", status: "COMPLETED", detailsUrl: "https://ci/lint"}]}'
}

# A PR's pass status as the Stack tab gets it.
status_of() { "$BERCAIL" review-pr state --stack "$1" | jq -r --argjson n "$2" '.prs[] | select(.number == $n) | .status'; }

# Every wait below ends by WAIT_S: generous under load, short of the CI limit.
WAIT_S=30

# True once PATH exists (a lock is a link to a pid, so -L too).
appears() {
  local i
  for ((i = 0; i < WAIT_S * 10; i++)); do [[ -e "$1" || -L "$1" ]] && return 0; sleep 0.1; done
  return 1
}

# True once PATH is gone.
vanishes() {
  local i
  for ((i = 0; i < WAIT_S * 10; i++)); do [[ -e "$1" || -L "$1" ]] || return 0; sleep 0.1; done
  return 1
}

wait_for() { appears "$1" || fail "timed out waiting for $1"; }

# A background job's exit status. One still running at WAIT_S fails the test.
wait_exit() {
  local i
  for ((i = 0; i < WAIT_S * 10; i++)); do
    kill -0 "$1" 2>/dev/null || { wait "$1"; return; }
    sleep 0.1
  done
  kill "$1" 2>/dev/null
  fail "$2 did not exit within ${WAIT_S}s"
}

wait_gone() {
  local i
  for ((i = 0; i < WAIT_S * 10; i++)); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done
  fail "$2 did not exit within ${WAIT_S}s"
}

# Wait for every pass and summary the CLI detached, and any they detached.
settle() {
  local i pid live
  for ((i = 0; i < WAIT_S * 10; i++)); do
    live=""
    while read -r pid; do
      kill -0 "$pid" 2>/dev/null && live+=" $pid"
    done < <(cat "$LOG/spawned" 2>/dev/null)
    if [[ -z "$live" ]]; then
      : >"$LOG/spawned"
      return 0
    fi
    sleep 0.1
  done
  fail "detached work still running after ${WAIT_S}s:$(for pid in $live; do printf '\n  %s' "$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)"; done)"
}

# --- arrange: each @test builds the state it needs -------------------------------

# PR #7 gathered with the Herdr app down; the pass it started has ended.
reviewed_7() {
  (cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/7/files) >/dev/null
  settle
}

# The Herdr app up, with one space on the source checkout.
herdr_up() {
  export FAKE_HERDR_UP=1
  jq -n --arg f "$WORK" '{spaces: [{id: "s0", name: "Main_Widgets", folder: $f, tabs: []}]}' >"$HERDR_STATE"
}

# PR #7 gathered into its Review-7_Widgets space and desk; no pass yet.
space_7() {
  herdr_up
  (cd / && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/7 --no-run) >/dev/null
}

# space_7, then #7's pass on the desk session and the stack summary it starts.
ready_7() {
  space_7
  "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >/dev/null
  settle
}


# A passing test leaves no detached work running. Then every desk and pass the
# CLI started is stopped, so none outlives the test or holds bats' pipe.
teardown() {
  [[ -n "${LOG:-}" ]] || return 0
  local pid rc=0
  [[ -z "${BATS_TEST_COMPLETED:-}" ]] || settle || rc=$?
  while read -r pid; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done < <(cat "$LOG/desk.pids" "$LOG/spawned" 2>/dev/null)
  return "$rc"
}

setup() {
  load test_helper
  isolate
  need git jq python3

  # A mise shim reads $HOME, which the test replaces: take the real python3 now.
  PY="$(type -ap python3 | grep -v '/mise/shims/' | head -1)"
  [[ -n "$PY" ]] || unavailable "python3 (not a mise shim) not found"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  FIX="$BATS_TEST_TMPDIR/fix"
  LOG="$BATS_TEST_TMPDIR/log"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FIX" "$LOG" "$FAKE_BIN"
  export FIX LOG
  # bstack's reviewer argv, as bercail update writes it.
  PI_PROFILE="$HOME/.local/share/bercail/pi"
  mkdir -p "$PI_PROFILE"
  jq -n --arg d "$PI_PROFILE" '["pi", "--model", "fake/model", "-e", "\($d)/extensions/review.ts", "--tools", "read,grep,find,ls"]' \
    >"$PI_PROFILE/review.json"
  export BERCAIL_DESK_AGENT="$ROOT/bin/bercail-desk-agent"
  BERCAIL="$ROOT/bin/bercail"
  REVIEWS="$XDG_STATE_HOME/bercail/reviews/github.com/acme/widgets"

  # --- a repo with two PR heads: refs/pull/7/head and refs/pull/8/head -----------
  REMOTE="$BATS_TEST_TMPDIR/remotes/acme/widgets.git"
  git init -q --bare -b main "$REMOTE"
  git init -q -b main "$BATS_TEST_TMPDIR/seed"
  (
    cd "$BATS_TEST_TMPDIR/seed" || exit
    echo base >README && git add README && git commit -qm base
    git push -q "$REMOTE" main
    git switch -qc retry && mkdir lib && echo 'retry() { :; }' >lib/retry.sh
    ln -s /etc/hostname lib/host-link && git add lib && git commit -qm retry -m 'Use a retry helper to isolate upload retries.'
    git push -q "$REMOTE" HEAD:refs/pull/7/head
    git switch -q main && git switch -qc docs && echo more >>README && git commit -qam docs
    git push -q "$REMOTE" HEAD:refs/pull/8/head
  )
  SHA7="$(git -C "$BATS_TEST_TMPDIR/seed" rev-parse retry)"
  SHA8="$(git -C "$BATS_TEST_TMPDIR/seed" rev-parse docs)"
  export REMOTE
  git clone -q "$REMOTE" "$BATS_TEST_TMPDIR/work/widgets"
  WORK="$BATS_TEST_TMPDIR/work/widgets"
  export WORK
  # Project config in the reviewed repo. The pass runs in the stack dir, so Pi never reads it.
  mkdir -p "$WORK/.pi" && printf '%s\n' '{"defaultProvider":"author"}' >"$WORK/.pi/settings.json"

  # --- fixtures -------------------------------------------------------------------
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
  cat >"$FIX/reply.json" <<EOF
{"why": "Best guess: make uploads resilient by retrying failures.", "why_source": "diff",
 "intent_analysis": {
   "confidence": "medium",
   "evidence": [{"file": "lib/retry.sh", "line": 1, "side": "new"}],
   "clues": [
     {"source": "issue #12", "alignment": "less", "detail": "The code retries, but omits requested backoff and logging."},
     {"source": "commit $SHA7", "alignment": "agrees", "detail": "The helper isolates upload retries."},
     {"source": "PR body", "alignment": "stale", "detail": "The description implies failures stop, but retry exhaustion can still fail."}],
   "assessment": "Resilience is worth building, but the retry policy needs a tradeoff discussion."},
 "decisions": [
  {"kind": "approach", "statement": "Retries live in a new retry.sh helper",
   "evidence": [{"file": "lib/retry.sh", "line": 3, "end_line": 9, "side": "new"}],
    "stated": "commit $SHA7: use a retry helper", "fits_intent": "yes", "alternative": null, "question": null},
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
      while [[ -d "$LOG" && ! -f "$LOG/gh.release" ]]; do sleep 0.05; done
    fi
    cat "$FIX/checks.json"; exit 8 ;;
  "issue view") cat "$FIX/issue-12.json" ;;
  "repo clone")
    if [[ " $* " == *" --bare "* ]]; then git clone -q --bare "$REMOTE" "$4"
    else git clone -q "$REMOTE" "$4"; fi ;;
  "repo view") echo '{"defaultBranchRef":{"name":"main"}}' ;;
  "api --hostname") echo '[]' ;;
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
  cat >"$FAKE_BIN/pi" <<'SH'
#!/usr/bin/env bash
# Headless (-p --mode json): one turn on stdout. Otherwise the review desk: it
# stands in for review.ts, taking desk/inbox/ requests one at a time and
# writing each turn to its out file. A desk turn reads FAKE_* from the
# waiting CLI's environment, as if the CLI had picked the reply.
sid="" prompt="" print=0 prev=""
for arg in "$@"; do
  [[ "$prev" == --session-id ]] && sid="$arg"
  [[ "$arg" == -p ]] && print=1
  prev="$arg"
done
prompt="${*: -1}"
ev() { jq -cn --arg text "$1" '{type: "message_end", message: {role: "assistant", content: [{type: "text", text: $text}], stopReason: "stop"}}'; }
turn() { # mode hold prompt
  local mode="$1" hold="$2" prompt="$3" i
  jq -cn --arg id "$sid" '{type: "session", id: $id}'
  if [[ -n "$hold" ]]; then
    trap 'exit 143' TERM
    echo "${BASHPID}" >"$LOG/pi.child"
    while [[ -d "$LOG" && ! -f "$LOG/pi.release" && ! -f "$OUT.cancel" ]]; do sleep 0.05; done
  fi
  case "$mode" in
    ok) if [[ "$prompt" == *"Stack summary mode"* ]]; then
          reply="$(jq -c '{overview:"The stack improves uploads.",order:[.prs[] | "#\(.number) \(.review.why)"],risks:["No backoff"],start_here:["Read retry.sh"]}' summary-input.json)"
          ev "$(printf '```json\n%s\n```' "$reply")"
          return 0
        fi
        ev "Read intent.md and diff.patch."
        ev "$(printf 'Three decisions.\n\n```json\n%s\n```' "$(cat "$FIX/reply.json")")" ;;
    noblock) ev "I looked at it and it seems fine." ;;
    long) for ((i = 0; i < 3000; i++)); do printf '%s\n' '{"type":"tool_execution_start","toolName":"read"}'; done
          ev "$(printf '```json\n%s\n```' "$(cat "$FIX/reply.json")")" ;;
    blocked) ev "$(printf '```json\n{"blocked": "diff.patch is empty"}\n```')" ;;
    provider) jq -cn '{type: "message_end", message: {role: "assistant", content: [], stopReason: "error", errorMessage: "429 rate limited"}}' ;;
    crash) echo "provider error" >&2; return 3 ;;
  esac
}
if [[ "$print" -eq 1 ]]; then
  printf '%s\n' "$PWD" >"$LOG/pi.pwd"
  printf '%s\n' "$@" >"$LOG/pi.argv"
  printf '%s\n' "$prompt" >>"$LOG/pi.runs"
  sid=ses_fake OUT=/dev/null
  turn "${FAKE_PI:-ok}" "${FAKE_HOLD:-}" "$prompt"
  exit
fi
printf '%s\n' "$PWD" >"$LOG/desk.pwd"
printf '%s\n' "$@" >"$LOG/desk.argv"
mkdir -p desk/inbox
jq -n --argjson pid "$$" --arg s "$sid" '{pid: $pid, session: $s}' >desk/pi.json
# Until the test's temp dir goes, so a desk the test missed still ends.
while [[ -d "$LOG" ]]; do
  for req in desk/inbox/*.json; do
    [[ -f "$req" ]] || continue
    mv "$req" "$req.taken" || continue
    caller="$(jq -r .pid "$req.taken")" OUT="$(jq -r .out "$req.taken")" prompt="$(jq -r .prompt "$req.taken")"
    rm -f "$req.taken"
    kill -0 "$caller" 2>/dev/null || continue
    printf '%s\n' "$caller" >"$LOG/pi.caller"
    env="$(tr '\0' '\n' <"/proc/$caller/environ")"
    mode="$(sed -n 's/^FAKE_PI=//p' <<<"$env")" hold="$(sed -n 's/^FAKE_HOLD=//p' <<<"$env")"
    printf '%s\n' "$prompt" >>"$LOG/pi.runs"
    turn "${mode:-ok}" "$hold" "$prompt" >>"$OUT" 2>/dev/null || true
    printf '%s\n' '{"type":"agent_settled","aborted":false}' >>"$OUT"
  done
  sleep 0.05
done
SH
  cat >"$FAKE_BIN/tuicr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "review list")
    # The session shows up on the second look, as when tuicr is still starting.
    n="$(cat "$LOG/tuicr.lists" 2>/dev/null || echo 0)"; echo $((n + 1)) >"$LOG/tuicr.lists"
    if [[ "$n" -ge 1 && -f "$LOG/tuicr.active" ]]; then
      jq -n --arg n "$(cat "$LOG/tuicr.active")" '[{slug:("gh:acme/widgets/pr/" + $n),kind:"pr",active:true}]'
    else
      echo '[{"slug":"gh:acme/widgets/pr/7","kind":"pr","active":false}]'
    fi ;;
  "review add")
    [[ "$*" == *"--session gh:acme/widgets/pr/$(cat "$LOG/tuicr.active") --input -"* ]] || { echo "bad args: $*" >&2; exit 2; }
    payload="$(cat)"
    # A line outside the PR diff: tuicr can't anchor it.
    [[ "$(jq -r '.file // ""' <<<"$payload")" == outside.txt ]] && { echo "not in diff" >&2; exit 1; }
    printf '%s\n' "$payload" >>"$LOG/tuicr.add"
    if [[ -n "${FAKE_TUICR_HOLD:-}" ]]; then
      touch "$LOG/tuicr.held"
      while [[ -d "$LOG" && ! -f "$LOG/tuicr.release" ]]; do sleep 0.05; done
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
          if [[ "$(jq -r '.[0:2] | join(" ")' <<<"${a[argv]}" 2>/dev/null)" == "tuicr pr" ]]; then
            jq -r '.[2]' <<<"${a[argv]}" >"$LOG/tuicr.active"
          fi
        fi
        printf '{"space":"%s","tab":"%s"}\n' "${a[space]}" "$id" ;;
      tab.close)
        if jq -e --arg id "${a[id]}" 'any(.spaces[].tabs[]; .id == $id and (.name | startswith("Review")))' "$st" >/dev/null; then
          rm -f "$LOG/tuicr.active"
        fi
        jq --arg id "${a[id]}" '.spaces[].tabs |= map(select(.id != $id))' "$st" >"$st.tmp" && mv "$st.tmp" "$st" ;;
      space.close)
        jq --arg id "${a[id]}" '.spaces |= map(select(.id != $id))' "$st" >"$st.tmp" && mv "$st.tmp" "$st" ;;
    esac ;;
esac
SH
  cat >"$FAKE_BIN/hc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG/hc"
case "$1" in
  ls) if [[ -f "$LOG/desk.json" ]]; then jq '{terminals:[{address:.address,state:"live"}]}' "$LOG/desk.json"; else echo '{"terminals":[]}'; fi ;;
  get) cat "$LOG/desk.json" ;;
  run)
    space="" session="" cwd=""
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --parent|--name) shift 2 ;;
        --cwd) cwd="$2"; shift 2 ;;
        --label)
          [[ "$2" == bercail.space=* ]] && space="${2#*=}"
          [[ "$2" == bercail.review.session=* ]] && session="${2#*=}"
          shift 2 ;;
        --*) shift ;;
        *) break ;;
      esac
    done
    jq -n --arg space "$space" --arg session "$session" '{address:"t-desk",state:"live",status:{state:"idle"},labels:{"bercail.role":"agent","bercail.space":$space,"bercail.review.session":$session}}' >"$LOG/desk.json"
    # A new desk replaces the last one. Close every fd but 0-2 so a survivor cannot hold bats' pipe.
    [[ ! -f "$LOG/desk.pid" ]] || kill "$(cat "$LOG/desk.pid")" 2>/dev/null || true
    ( cd "$cwd" || exit 1; eval exec {3..255}\>\&-; exec "$@" ) </dev/null >/dev/null 2>&1 &
    echo "$!" >"$LOG/desk.pid"
    echo "$!" >>"$LOG/desk.pids" ;;
  kill|rm)
    [[ ! -f "$LOG/desk.pid" ]] || kill "$(cat "$LOG/desk.pid")" 2>/dev/null || true
    rm -f "$LOG/desk.json" "$LOG/desk.pid" ;;
esac
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
  # setsid -f: the passes and summaries the CLI detaches. Logged, so the test
  # can wait for them (settle) and none races the next step.
  cat >"$FAKE_BIN/setsid" <<'SH'
#!/usr/bin/env bash
[[ "$1" == -f ]] && shift
"$@" &
printf '%s\n' "$!" >>"$LOG/spawned"
SH
  chmod +x "$FAKE_BIN"/*
  export PATH="$FAKE_BIN:$PATH"
  export HERDR_APP_BIN="$FAKE_BIN/herdr-app" HC_BIN="$FAKE_BIN/hc"
  export BERCAIL_HERDR_LAYOUT="$ROOT/config/worktrunk/herdr-layout.sh"
  export HERDR_STATE="$BATS_TEST_TMPDIR/herdr.json"
  export HERDR_APP_CONFIG_DIR="$HOME/.config/herdr-app"
  MOD="$HERDR_APP_CONFIG_DIR/mods/bercail-review"
  mkdir -p "$MOD" && : >"$MOD/main.js"
}

# --- thin rules -------------------------------------------------------------------
@test "thin rules: empty, restates title, no linked issue, part N of M only" {
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/review.sh"
  t() { # title body closing linear -> flags
    jq -n --arg t "$1" --arg b "$2" --argjson c "$3" '{title: $t, body: $b, closingIssuesReferences: $c}' >"$BATS_TEST_TMPDIR/t.json"
    _review_thin "$BATS_TEST_TMPDIR/t.json" "$4"
  }
  assert_eq '["empty_body","no_linked_issue"]' "$(t "Docs" "" '[]' '[]')" "empty body"
  assert_eq '["empty_body","no_linked_issue"]' "$(t "Docs" "<!-- template -->" '[]' '[]')" "a template comment is empty"
  assert_eq '["restates_title"]' "$(t "Retry flaky uploads" "Retry flaky uploads." '[{"number":1}]' '[]')" "restates title"
  assert_eq '["restates_title"]' "$(t "Retry flaky uploads" "retry" '[{"number":1}]' '[]')" "body inside the title"
  assert_eq '["no_linked_issue"]' "$(t "Retry" "Adds a helper so uploads retry." '[]' '[]')" "no linked issue"
  assert_eq '[]' "$(t "Retry" "Adds a helper so uploads retry." '[]' '["LEF-123"]')" "a Linear id is a linked issue"
  assert_eq '["part_n_of_m_only"]' "$(t "Retry" "Part 2 of 3" '[{"number":1}]' '[]')" "part N of M only"
  assert_eq '["part_n_of_m_only"]' "$(t "Retry: storage" "Part 2/3 — retry: storage" '[{"number":1}]' '[]')" "part N of M plus the title"
  assert_eq '[]' "$(t "Retry" "Part 2 of 3: adds the backoff schedule." '[{"number":1}]' '[]')" "part N of M with more"
}

@test "Linear ids come from the title, body and branch, not PR-12, CI-123 or a branch word" {
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/review.sh"
  jq -n '{title: "Retry", body: "See PR-12 and CI-123.", headRefName: "retry"}' >"$BATS_TEST_TMPDIR/l.json"
  assert_eq '[]' "$(_review_linear_ids "$BATS_TEST_TMPDIR/l.json")" "PR-12 and CI-123 are not Linear ids"
  jq -n '{title: "LEF-42 retry", body: "See UTF-8 and SHA-256, also ENG-7.", headRefName: "dana/lef-99-retry"}' >"$BATS_TEST_TMPDIR/l.json"
  assert_eq '["ENG-7","LEF-42","LEF-99"]' "$(_review_linear_ids "$BATS_TEST_TMPDIR/l.json")" "Linear ids"
  jq -n '{title: "x", body: "", headRefName: "review-pr-slice-1"}' >"$BATS_TEST_TMPDIR/l.json"
  assert_eq '[]' "$(_review_linear_ids "$BATS_TEST_TMPDIR/l.json")" "a branch word is not a Linear id"
}

@test "intent.md: code-first inference, missing issue clues and stale-description policy" {
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/review.sh"
  local issues="$BATS_TEST_TMPDIR/intent-issues.jsonl" commits="$BATS_TEST_TMPDIR/intent-commits.txt" md
  cp "$FIX/issue-12.json" "$issues"
  printf 'commit %s\nretry\n\nUse a retry helper to isolate upload retries.\n' "$SHA7" >"$commits"
  md="$(_review_intent_md "$FIX/pr-7.json" "$issues" '[]' '[]' "$commits")"
  assert_has "$md" 'Infer intent from diff.patch first, then compare it with these clues.' "gathered code-first policy"
  assert_has "$md" 'PR title/body are the weakest clues and may be stale.' "PR prose is not source of truth"
  assert_has "$md" "commit $SHA7" "commit provenance"
  printf '%s\n' "$md" >"$BATS_TEST_TMPDIR/intent-sources.md"
  "$PY" - "$BATS_TEST_TMPDIR/intent-sources.md" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
assert text.index('## Linked issues') < text.index('## Commit messages') < text.index('## PR body (weak hint)')
PY
  : >"$issues"
  jq '.closingIssuesReferences = [] | .body = "Retries uploads forever to prevent failures. This description may be stale."' "$FIX/pr-7.json" >"$BATS_TEST_TMPDIR/no-issue.json"
  md="$(_review_intent_md "$BATS_TEST_TMPDIR/no-issue.json" "$issues" '[]' '[]' "$commits")"
  assert_has "$md" 'No linked issue clues to compare; still infer intent from the code.' "missing issues do not prevent inference"
  assert_has "$md" 'Retries uploads forever' "body retained as a weak hint"
  md="$(_review_intent_md "$FIX/pr-7.json" "$issues" '[]' '[]' "$commits")"
  assert_has "$md" 'Linked issue content was not fetched; comparison is unavailable.' "a failed issue fetch is a missing clue"
  md="$(_review_intent_md "$BATS_TEST_TMPDIR/no-issue.json" "$issues" '["LEF-42"]' '[]' "$commits")"
  assert_has "$md" 'Detected, not fetched: LEF-42' "Linear ids remain unfetched clues"
  if grep -qF 'Intent unknown' <<<"$md"; then fail "missing clues produced unknown intent"; fi
}

@test "bstack-pr-review: code-first inference, confidence/evidence/clue schema and stale-description policy" {
  local agent
  agent="$(<"$ROOT/bstack/pi/agents/bstack-pr-review.md")"
  assert_has "$agent" 'The diff is the source of truth.' "agent source priority"
  assert_has "$agent" 'Always infer intent from what the code actually does' "code-based inference is required"
  assert_has "$agent" 'best educated guess' "inference is not claimed as author fact"
  assert_has "$agent" 'A PR body mention alone never makes a decision documented' "no body-only stated decisions"
  assert_has "$agent" 'Missing issues mean no issue clues to compare' "agent keeps inferring without issues"
  assert_has "$agent" 'likely stale description' "stale description policy"
  assert_has "$agent" 'not as an author question about the code' "stale descriptions do not seed code questions"
  "$PY" - "$ROOT/bstack/pi/agents/bstack-pr-review.md" <<'PY'
import json, re, sys
from pathlib import Path
schema = json.loads(re.findall(r'```json\n(.*?)\n```', Path(sys.argv[1]).read_text(), re.S)[-1])
assert schema['why_source'] == 'diff'
assert 'commit' in schema['decisions'][0]['stated'] and 'PR body' not in schema['decisions'][0]['stated']
assert 'best educated guess' in schema['why']
analysis = schema['intent_analysis']
assert set(analysis) == {'confidence', 'evidence', 'clues', 'assessment'}
assert all(level in analysis['confidence'] for level in ('high', 'medium', 'low'))
assert analysis['evidence'][0]['file'] and analysis['evidence'][0]['line']
assert all(status in analysis['clues'][0]['alignment'] for status in ('agrees', 'more', 'less', 'different', 'stale', 'unavailable'))
assert 'right thing to build' in analysis['assessment']
assert 'PR body' not in schema['unmet_intent'][0]['source']
PY
}

# --- review-pr <url>: a thin PR stops at the JSON --------------------------------
@test "a thin PR: run dir, detached worktree, CI kept from a failing gh pr checks, JSON stops with thin flags" {
  local out dir
  out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/8)"
  assert_eq '["empty_body","no_linked_issue"]' "$(jq -c '.prs[0].thin' <<<"$out")" "thin flags in the JSON"
  assert_eq 'true waiting' "$(jq -r '"\(.thin) \(.pass)"' <<<"$out")" "a thin PR waits"
  assert_eq "bercail review-pr run --stack $REVIEWS/stack-8" "$(jq -r '.next' <<<"$out")" "next command"
  [[ ! -e "$LOG/pi.argv" ]] || fail "a thin PR must not start the pass"
  dir="$REVIEWS/stack-8/pr-8/$SHA8"
  assert_eq "$dir" "$(jq -r '.prs[0].dir' <<<"$out")" "run dir in the JSON"
  for f in intent.md diff.patch ci.json pr.json; do [[ -s "$dir/$f" ]] || fail "missing $dir/$f"; done
  [[ -s "$REVIEWS/stack-8/stack.json" ]] || fail "missing stack.json"
  local sib="$BATS_TEST_TMPDIR/work/widgets.review-8"
  assert_eq "widgets.review-8 8 8" "$(jq -r '"\(.worktree | split("/")[-1]) \(.root) \(.current)"' "$REVIEWS/stack-8/stack.json")" "stack.json"
  assert_eq "$sib" "$(jq -r .worktree "$REVIEWS/stack-8/stack.json")" "sibling of the source checkout"
  assert_eq "$SHA8" "$(git -C "$sib" rev-parse HEAD)" "worktree at the PR head"
  git -C "$sib" symbolic-ref -q HEAD >/dev/null && fail "the review worktree must be detached"
  [[ "$(git -C "$WORK" worktree list --porcelain)" == *"$sib"* ]] || fail "worktree registered to the source git"
  # gh pr checks exited 8 (pending, failing): its JSON is kept.
  assert_eq 3 "$(jq length "$dir/ci.json")" "ci.json from gh pr checks"
  assert_eq '{"pass":1,"pending":1,"fail":1}' "$(jq -c '.prs[0].ci' <<<"$out")" "CI counts"
  assert_has "$(<"$dir/intent.md")" "- thin: empty_body, no_linked_issue" "intent.md thin"
  assert_eq 'Awaiting code-based intent inference.' "$(jq -r '.prs[0].intent' "$REVIEWS/stack-8/stack.json")" "pending card does not invent intent from prose"
  assert_has "$(<"$dir/intent.md")" "package-lock.json (+40 -2, modified) [lock or generated: name only]" "lock files by name"
  assert_has "$("$BERCAIL" review-pr card --stack "$REVIEWS/stack-8")" "Decisions pass: waiting: thin (empty_body, no_linked_issue)" "card before the pass"
}

# --- review-pr <url>: the pass starts, review.json and run.json land -------------
@test "a PR with intent: the pass runs bstack's Pi reviewer and writes review.json and run.json" {
  local out dir argv
  out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/7/files)"
  assert_eq 'false started' "$(jq -r '"\(.thin) \(.pass)"' <<<"$out")" "a PR with intent starts the pass"
  dir="$REVIEWS/stack-7/pr-7/$SHA7"
  assert_has "$(<"$dir/intent.md")" "### #12 Uploads fail on flaky networks" "linked issue in intent.md"
  assert_has "$(<"$dir/intent.md")" "commit $SHA7" "gathered commits are pinned to this PR head"
  assert_has "$(<"$dir/intent.md")" 'Use a retry helper to isolate upload retries.' "full commit message is available to the pass"
  assert_eq 'Awaiting code-based intent inference.' "$(jq -r '.prs[0].intent' "$REVIEWS/stack-7/stack.json")" "gather does not label issue clues as intent"
  jq -e --arg why "$(jq -r .why "$FIX/reply.json")" '.prs[0].summary | . == $why or . == "Awaiting code-based intent inference."' <<<"$out" >/dev/null \
    || fail "gather summary promoted a clue to inferred intent"
  wait_for "$dir/run.json"
  argv="$(<"$LOG/pi.argv")"
  assert_eq "$(jq -r '.[1:][]' "$PI_PROFILE/review.json")"$'\n-p\n--mode\njson\n--session-dir\n'"$REVIEWS/stack-7/sessions"$'\n--' \
    "$(head -n -1 <<<"$argv")" "the pass is bstack's reviewer argv, headless, with the stack's session dir"
  assert_has "$(tail -1 <<<"$argv")" "pr-7/$SHA7/source/" "the prompt names the snapshot"
  assert_eq "$REVIEWS/stack-7" "$(<"$LOG/pi.pwd")" "the pass runs in the stack dir, not the reviewed repo"
  [[ ! -e "$REVIEWS/stack-7/.pi" ]] || fail "the author's Pi config must not be copied to the launch cwd"
  assert_eq 'ready ses_fake' "$(jq -r '"\(.status) \(.session_id)"' "$dir/run.json")" "run.json"
  assert_eq '3 decisions, 2 undocumented, 1 unmet, 3 questions' "$(jq -r .summary "$dir/run.json")" "run.json summary"
  assert_eq "bercail.review/v1 7 $SHA7 ses_fake 3" \
    "$(jq -r '"\(.schema) \(.pr) \(.head_sha) \(.session_id) \(.decisions | length)"' "$dir/review.json")" "review.json"
  jq -e '.why_source == "diff" and .intent_analysis.confidence == "medium"
    and .intent_analysis.evidence[0].file == "lib/retry.sh"
    and [.intent_analysis.clues[].alignment] == ["less","agrees","stale"]' "$dir/review.json" >/dev/null \
    || fail "inference metadata was lost on save"
  assert_eq 'Best guess: make uploads resilient by retrying failures.' "$("$BERCAIL" review-pr state --stack "$REVIEWS/stack-7" | jq -r '.prs[0].intent')" "picker intent uses code inference, not issue or body"
  local sib7="$BATS_TEST_TMPDIR/work/widgets.review-7"
  [[ -L "$sib7/lib/host-link" ]] || fail "the review worktree keeps a normal symlink"
  [[ ! -L "$dir/source/lib/host-link" ]] || fail "the snapshot must not be a symlink"
  assert_eq /etc/hostname "$(cat "$dir/source/lib/host-link")" "symlink target, not its contents"
  [[ -s "$dir/source/lib/retry.sh" ]] || fail "changed text is snapshotted"
  [[ ! -e "$dir/source/package-lock.json" ]] || fail "lock files are not snapshotted"
  assert_eq '' "$(git -C "$sib7" status --porcelain)" "the review worktree stays clean"
  [[ "$(git -C "$WORK" config --get core.symlinks || true)" != false ]] || fail "source repo's symlink policy changed"
}

@test "card: why, decisions (kind, file:line, stated or undocumented, fits intent), unmet intent, questions, CI" {
  local card
  reviewed_7
  card="$(cd "$BATS_TEST_TMPDIR/work/widgets.review-7" && "$BERCAIL" review-pr card)"
  assert_has "$card" "PR #7  Retry flaky uploads" "card title"
  assert_has "$card" "by dana · main ← retry · ${SHA7:0:7}" "card author, base, head"
  assert_has "$card" "  Best guess: make uploads resilient by retrying failures.  [diff]" "inferred intent"
  assert_has "$card" 'Confidence: medium' "intent confidence"
  assert_has "$card" 'Evidence: lib/retry.sh:1' "intent evidence"
  assert_has "$card" 'less · issue #12: The code retries' "clue divergence"
  assert_has "$card" 'stale · PR body:' "stale description is shown"
  assert_has "$card" 'Right thing to build: Resilience is worth building' "intent assessment"
  assert_has "$card" "Decisions (3, 2 undocumented)" "decision counts"
  assert_has "$card" "  1. [approach] Retries live in a new retry.sh helper" "decision"
  assert_has "$card" "     lib/retry.sh:3-9  stated: commit $SHA7: use a retry helper · fits intent: yes" "commit-documented decision"
  assert_has "$card" "     lib/upload.sh:12  UNDOCUMENTED · fits intent: partial" "undocumented decision"
  assert_has "$card" "     over: exponential backoff" "alternative"
  assert_has "$card" $'Intent with no change\n  - Log each retry  [issue #12]' "unmet intent"
  assert_has "$card" "  2. outside.txt:40  Was dropping the timeout intended?" "anchored question"
  assert_has "$card" "  3. (whole PR)  The issue asks to log each retry; is that in another PR?" "whole-PR question"
  assert_has "$card" "CI  1 fail · 1 pending · 1 pass" "CI counts"
  assert_has "$card" "  fail     lint (CI)  https://ci/lint" "failing check with its link"
  assert_has "$(status_of "$REVIEWS/stack-7" 7)" "ready: 3 decisions" "pass status in state"
  assert_eq "$REVIEWS/stack-7/pr-7/$SHA7" "$(cd "$BATS_TEST_TMPDIR/work/widgets.review-7" && "$BERCAIL" review-pr dir)" "dir"
}

@test "a PR without linked issues gets code-inferred intent, confidence, evidence and a missing-clue comparison" {
  local stack="$REVIEWS/stack-8" card
  (cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/8) >/dev/null
  cp "$FIX/reply.json" "$FIX/linked-reply.json"
  jq -n --arg sha "$SHA8" '{
    why: "Best guess: clarify the README with another note.", why_source: "diff",
    intent_analysis: {confidence:"medium", evidence:[{file:"README",line:2,side:"new"}],
      clues:[{source:"linked issues",alignment:"unavailable",detail:"No linked issue clues to compare."},
        {source:("commit " + $sha),alignment:"agrees",detail:"The commit describes a docs update."}],
      assessment:"A small documentation update looks reasonable; its value depends on the note."},
    decisions:[], unmet_intent:[], questions:[]}' >"$FIX/reply.json"
  "$BERCAIL" review-pr run 8 --stack "$stack" >/dev/null
  assert_eq 'Best guess: clarify the README with another note.' "$("$BERCAIL" review-pr state --stack "$stack" | jq -r '.prs[0].intent')" "no linked issue still yields inferred intent"
  card="$("$BERCAIL" review-pr card 8 --stack "$stack")"
  assert_has "$card" 'Confidence: medium' "no-issue inference keeps confidence"
  assert_has "$card" 'Evidence: README:2' "no-issue inference keeps evidence"
  assert_has "$card" 'unavailable · linked issues: No linked issue clues to compare.' "missing clue is not missing intent"
  grep -qF 'Intent unknown' <<<"$card" && fail "missing issue hid inferred intent"
  mv "$FIX/linked-reply.json" "$FIX/reply.json"
}

@test "run: failed (no block, crash), blocked (drops the old review), a long pass, one pass at a time, a dead pass" {
  local dir="$REVIEWS/stack-7/pr-7/$SHA7"
  reviewed_7
  FAKE_PI=noblock "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >/dev/null && fail "no JSON block must fail"
  assert_eq 'failed the reply is not a valid decisions JSON block' "$(jq -r '"\(.status) \(.reason)"' "$dir/run.json")" "failed"
  FAKE_PI=crash "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >/dev/null && fail "a crash must fail"
  assert_eq 'failed pi exited 3: provider error' "$(jq -r '"\(.status) \(.reason)"' "$dir/run.json")" "crash"
  # Pi exits 0 when the provider fails; its last message says so.
  FAKE_PI=provider "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >/dev/null && fail "a provider error must fail"
  assert_eq 'failed pi failed: 429 rate limited' "$(jq -r '"\(.status) \(.reason)"' "$dir/run.json")" "provider error"
  cp "$FIX/reply.json" "$FIX/good-reply.json"
  local bad
  for bad in 'del(.intent_analysis)' '.why = ""' '.why_source = "issue #12"' \
    '.intent_analysis.confidence = "certain"' '.intent_analysis.evidence = "a"' '.intent_analysis.evidence = []' \
    '.intent_analysis.evidence[0].file = "../outside"' '.intent_analysis.clues[0].alignment = "okay"' \
    '.intent_analysis.clues = []' '.intent_analysis.assessment = 42' \
    '.decisions = ["not an object"]' '.decisions[0].evidence = {file:"a",line:1}' \
    '.unmet_intent = ["not an object"]' '.questions = [{text:42}]' '., .'; do
    jq "$bad" "$FIX/good-reply.json" >"$FIX/reply.json"
    "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >/dev/null && fail "malformed review must fail: $bad"
    assert_eq 'failed ses_fake' "$(jq -r '"\(.status) \(.session_id)"' "$dir/run.json")" "invalid shape keeps its session id"
    [[ ! -e "$dir/review.json" ]] || fail "an invalid review must never reach the card or seeding"
    assert_has "$("$BERCAIL" review-pr card --stack "$REVIEWS/stack-7")" "not a valid decisions JSON block" "card after invalid reply"
  done
  mv "$FIX/good-reply.json" "$FIX/reply.json"
  FAKE_PI=blocked "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >/dev/null || fail "blocked is not a failure"
  assert_eq 'blocked diff.patch is empty ses_fake' "$(jq -r '"\(.status) \(.reason) \(.session_id)"' "$dir/run.json")" "blocked"
  assert_has "$(status_of "$REVIEWS/stack-7" 7)" "blocked: diff.patch is empty" "a blocked row"
  [[ ! -e "$dir/review.json" ]] || fail "a rerun that blocks drops the last review"
  assert_has "$("$BERCAIL" review-pr card --stack "$REVIEWS/stack-7")" "Decisions pass: blocked: diff.patch is empty" "card after a blocked rerun"

  # A long pass (thousands of events) still gets its session id and review.
  FAKE_PI=long "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >/dev/null || fail "a long pass"
  assert_eq 'ready ses_fake' "$(jq -r '"\(.status) \(.session_id)"' "$dir/run.json")" "a long pass is ready"

  # One pass at a time. A lock whose process is gone reads as a pass that died.
  ln -s "$$" "$dir/pass.lock"
  assert_has "$("$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" 2>&1 || true)" "already running" "a second pass is refused"
  assert_has "$(status_of "$REVIEWS/stack-7" 7)" "running" "a live pass is running"
  rm -f "$dir/run.json"
  ln -sfn 999999 "$dir/pass.lock"
  assert_has "$(status_of "$REVIEWS/stack-7" 7)" "failed: the pass stopped before it finished" "a dead pass"
  "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >/dev/null || fail "a dead pass's lock is taken over"
  [[ ! -e "$dir/pass.lock" ]] || fail "the lock goes when the pass ends"

  "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >/dev/null
  assert_eq ready "$(jq -r .status "$dir/run.json")" "rerun is ready again"
}

@test "concurrent passes and gathers refused, termination kills pi, dead locks have one successor" {
  local dir="$REVIEWS/stack-7/pr-7/$SHA7" runner child
  reviewed_7
  rm -f "$LOG/pi.child" "$LOG/pi.release"
  FAKE_HOLD=1 "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >"$LOG/held-run" &
  runner=$!
  wait_for "$LOG/pi.child"
  child="$(cat "$LOG/pi.child")"
  assert_has "$("$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" 2>&1 || true)" "already running" "overlapping passes"
  assert_has "$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/7 2>&1 || true)" \
    "review stack is busy" "gather cannot change a running pass's inputs"
  kill -TERM "$runner"
  wait_exit "$runner" "the terminated pass" && fail "a terminated pass succeeds"
  kill -0 "$child" 2>/dev/null && fail "pi outlived its wrapper"
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
  rm -f "$LOG/pi.child"
  local i pid winners=0
  local -a pids=()
  for ((i = 0; i < 8; i++)); do
    FAKE_HOLD=1 "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >"$LOG/race-$i" 2>&1 &
    pids+=("$!")
  done
  wait_for "$LOG/pi.child"
  # Keep the winner running until all contenders have attempted the lock.
  for pid in "${pids[@]}"; do
    [[ "$(readlink "$dir/pass.lock")" == "$pid" ]] || wait_exit "$pid" "a stale-lock contender" || true
  done
  touch "$LOG/pi.release"
  for pid in "${pids[@]}"; do
    if wait_exit "$pid" "a stale-lock contender"; then winners=$((winners + 1)); fi
  done
  assert_eq 1 "$winners" "only one stale-lock contender ran"
}

@test "ui without the Herdr app fails and says why" {
  local out
  (cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/7 --no-run) >/dev/null
  out="$("$BERCAIL" review-pr ui --stack "$REVIEWS/stack-7" 2>&1)" && fail "ui without the Herdr app must fail"
  assert_has "$out" "the Herdr app is not running" "ui says why"
}

# --- a Herdr space: Review-<n>_<Repo>, its desk, a Stack tab -----------------------
@test "a Herdr space Review-<n>_<Repo> on the worktree, its desk, one Stack tab, the bercail-review mod" {
  local out
  # The checkout is found through a Herdr space on it, not the caller's cwd.
  herdr_up
  : >"$LOG/hc"
  out="$(cd / && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/7 --no-run)"
  assert_eq 's1 waiting' "$(jq -r '"\(.space) \(.pass)"' <<<"$out")" "space id, --no-run"
  assert_eq s1 "$(jq -r .space "$REVIEWS/stack-7/stack.json")" "space in stack.json"
  assert_eq "Review-7_Widgets $(cd "$BATS_TEST_TMPDIR/work/widgets.review-7" && pwd -P)" \
    "$(jq -r '.spaces[] | select(.id == "s1") | "\(.name) \(.folder)"' "$HERDR_STATE")" "space name and folder"
  [[ "$(git -C "$WORK" worktree list --porcelain)" == *"widgets.review-7"* ]] || fail "sibling worktree of the source"
  assert_eq "bercail-review $REVIEWS/stack-7 $ROOT/bin/bercail" \
    "$(awk '{ print $1 }' "$LOG/stack.mod") $(awk '{ print $2 }' "$LOG/stack.mod" | jq -r '"\(.stack) \(.bercail)"')" \
    "the Stack tab is the mod, on this stack"
  [[ ! -e "$LOG/stack.argv" ]] || fail "the Stack tab runs no terminal"
  assert_has "$(<"$LOG/hc")" "--label bercail.space=s1" "the desk starts without a bstack switch"
  local session
  session="$(jq -r .session_id "$REVIEWS/stack-7/desk.json")"
  assert_has "$(<"$LOG/hc")" "--label bercail.review.session=$session" "desk is attached to the review session"
  assert_has "$(<"$LOG/hc")" "--cwd $REVIEWS/stack-7 " "the visible desk uses the safe stack cwd"
  assert_has "$(<"$LOG/hc")" "$BERCAIL_DESK_AGENT $(jq -r 'join(" ")' "$PI_PROFILE/review.json") --session-dir $REVIEWS/stack-7/sessions --session-id $session" \
    "the desk runs bstack's reviewer on the review session"
  assert_eq "$REVIEWS/stack-7" "$(<"$LOG/desk.pwd")" "the desk's Pi runs in the stack dir"
  # Again: the same space and tab, no second desk.
  : >"$LOG/hc"
  (cd / && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/7 --no-run) >/dev/null
  assert_eq 1 "$(wc -l <"$LOG/stack.mod" | tr -d ' ')" "no second Stack tab"
  assert_eq 1 "$(jq '[.spaces[] | select(.name == "Review-7_Widgets")] | length' "$HERDR_STATE")" "one space"
  if grep -q '^run ' "$LOG/hc"; then fail "gather started a second desk"; fi
}

# --- ui: shows the Stack tab, or makes it ------------------------------------------
@test "ui/gather recreate a closed Stack tab, keep other tabs and reuse the mod; no mod says to update" {
  local saved="$BATS_TEST_TMPDIR/herdr.saved" out
  ready_7
  cp "$HERDR_STATE" "$saved"
  : >"$LOG/herdr"
  rm -f "$LOG/stack.mod"
  "$BERCAIL" review-pr ui --stack "$REVIEWS/stack-7"
  [[ ! -e "$LOG/stack.mod" ]] || fail "ui made a second Stack tab"
  assert_has "$(<"$LOG/herdr")" "do space.select --id s1" "ui shows the review space"
  assert_has "$(<"$LOG/herdr")" "do tab.select --id $(jq -r '.spaces[] | select(.id == "s1") | .tabs[] | select(.name == "Stack") | .id' "$HERDR_STATE")" "ui selects the Stack tab"
  # A closed native tab is recreated by the next ui request.
  jq '(.spaces[] | select(.id == "s1") | .tabs) |= map(select(.name != "Stack"))' \
    "$saved" >"$HERDR_STATE"
  "$BERCAIL" review-pr ui --stack "$REVIEWS/stack-7"
  assert_eq 1 "$(wc -l <"$LOG/stack.mod" | tr -d ' ')" "a replacement mod Stack tab"
  assert_eq 1 "$(jq '[.spaces[] | select(.id == "s1") | .tabs[] | select(.name == "Stack")] | length' "$HERDR_STATE")" \
    "only the mod Stack tab remains"
  # Gathering reuses the mod and leaves the user's shell tab alone.
  jq '(.spaces[] | select(.id == "s1") | .tabs) += [{id: "keep-shell", name: "Shell", terminals: [{terminal: "t-keep"}]}]' \
    "$HERDR_STATE" >"$HERDR_STATE.tmp"
  mv "$HERDR_STATE.tmp" "$HERDR_STATE"
  : >"$LOG/herdr"
  (cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/7 --no-run) >/dev/null
  assert_eq 1 "$(jq '[.spaces[] | select(.id == "s1") | .tabs[] | select(.id == "keep-shell")] | length' "$HERDR_STATE")" \
    "gather keeps the shell"
  assert_eq 1 "$(wc -l <"$LOG/stack.mod" | tr -d ' ')" "gather reuses the existing mod"
  # No mod: ui says to update, and a gather warns.
  mv "$MOD/main.js" "$MOD/main.js.off"
  out="$("$BERCAIL" review-pr ui --stack "$REVIEWS/stack-7" 2>&1)" && fail "ui without the mod must fail"
  assert_has "$out" "bercail update" "ui without the mod says to update"
  jq '.spaces |= map(select(.id != "s1"))' "$saved" >"$HERDR_STATE"
  assert_has "$(cd / && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/7 --no-run 2>&1 >/dev/null)" \
    "no bercail-review mod" "gather without the mod warns"
  mv "$MOD/main.js.off" "$MOD/main.js"
  cp "$saved" "$HERDR_STATE"
}

# --- checkout: the PR's branch in the review worktree; rereview: gather, then pass ----
@test "checkout puts the PR branch in the review worktree, never moves yours; rereview gathers then passes" {
  local wt="$BATS_TEST_TMPDIR/work/widgets.review-7" out main_sha
  ready_7
  main_sha="$(git -C "$WORK" rev-parse main)"
  git -C "$WORK" branch -D retry >/dev/null 2>&1 || true
  out="$("$BERCAIL" review-pr checkout 7 --stack "$REVIEWS/stack-7")"
  assert_eq "retry null $wt" "$(jq -r '"\(.branch) \(.note) \(.worktree)"' <<<"$out")" "a missing branch is made"
  assert_eq "retry $SHA7" "$(git -C "$wt" symbolic-ref --short HEAD) $(git -C "$wt" rev-parse HEAD)" "on the branch, at the head"
  # On a PR's branch the stack still moves it, a tag of the same name or not.
  git -C "$WORK" tag retry "$main_sha"
  "$BERCAIL" review-pr select 7 --stack "$REVIEWS/stack-7"
  git -C "$WORK" tag -d retry >/dev/null
  git -C "$wt" symbolic-ref -q HEAD >/dev/null && fail "select detaches again"
  # Your branch elsewhere: left alone, the worktree at the head, detached.
  git -C "$WORK" branch -f retry "$main_sha"
  out="$("$BERCAIL" review-pr checkout 7 --stack "$REVIEWS/stack-7")"
  assert_has "$(jq -r .note <<<"$out")" "left alone" "a branch not at the head"
  assert_eq "null $main_sha $SHA7" "$(jq -r .branch <<<"$out") $(git -C "$WORK" rev-parse retry) $(git -C "$wt" rev-parse HEAD)" \
    "the branch did not move; the worktree is at the head"
  git -C "$WORK" branch -f retry "$SHA7"
  git -C "$WORK" switch -q retry
  out="$("$BERCAIL" review-pr checkout 7 --stack "$REVIEWS/stack-7")"
  git -C "$WORK" switch -q main
  assert_has "$(jq -r .note <<<"$out")" "checked out in $WORK" "a branch checked out in another worktree"
  # A fork's PR: no local branch named after the fork's.
  git -C "$WORK" branch -D retry >/dev/null
  jq '.isCrossRepository = true' "$REVIEWS/stack-7/pr-7/$SHA7/pr.json" >"$LOG/fork.json"
  cp "$REVIEWS/stack-7/pr-7/$SHA7/pr.json" "$LOG/pr.json.saved" && cp "$LOG/fork.json" "$REVIEWS/stack-7/pr-7/$SHA7/pr.json"
  out="$("$BERCAIL" review-pr checkout 7 --stack "$REVIEWS/stack-7")"
  cp "$LOG/pr.json.saved" "$REVIEWS/stack-7/pr-7/$SHA7/pr.json"
  assert_has "$(jq -r .note <<<"$out")" "a fork's branch" "a fork's PR"
  git -C "$WORK" rev-parse -q --verify refs/heads/retry >/dev/null && fail "a fork's PR made a local branch"
  # Any other branch is the person's: the stack refuses to move it.
  git -C "$wt" switch -q -c mine
  assert_has "$("$BERCAIL" review-pr select 7 --stack "$REVIEWS/stack-7" 2>&1 || true)" "not detached or on a PR's branch" \
    "a branch that is not the stack's"
  git -C "$wt" switch -q --detach "$SHA7" && git -C "$wt" branch -q -D mine
  # rereview: the stack is gathered again, then #7's pass runs again though it was ready.
  : >"$LOG/gh"
  jq '.finished_at = "old"' "$REVIEWS/stack-7/pr-7/$SHA7/run.json" >"$LOG/run.old" && cp "$LOG/run.old" "$REVIEWS/stack-7/pr-7/$SHA7/run.json"
  FAKE_PI=ok "$BERCAIL" review-pr rereview 7 --stack "$REVIEWS/stack-7" >/dev/null 2>"$LOG/rereview.err" \
    || fail "rereview: $(cat "$LOG/rereview.err")"
  assert_has "$(<"$LOG/gh")" "pr view 7" "rereview gathers"
  assert_eq ready "$(jq -r 'select(.finished_at != "old") | .status' "$REVIEWS/stack-7/pr-7/$SHA7/run.json")" "rereview runs the pass again"
  assert_eq 7 "$(jq -r .current "$REVIEWS/stack-7/stack.json")" "rereview leaves the stack on its PR"
}

@test "one read-only visible desk session, cached ready-stack summary, invalidation, failure, and busy desk protection" {
  local stack="$REVIEWS/stack-7" dir="$REVIEWS/stack-7/pr-7/$SHA7" session before out
  ready_7
  session="$(jq -r .session_id "$stack/desk.json")"
  assert_eq "$session" "$(jq -r .session_id "$dir/review.json")" "the desk session produced the card"
  settle
  assert_eq "ready $session" "$(jq -r '"\(.status) \(.session_id)"' "$stack/stack-summary.json")" "same desk produced the stack summary"
  assert_has "$(jq -r '.order[]' "$stack/stack-summary.json")" 'Best guess: make uploads resilient' "stack summary reads the inferred purpose"
  before="$(grep -c 'Stack summary mode' "$LOG/pi.runs")"
  "$BERCAIL" review-pr summarize --stack "$stack"
  assert_eq "$before" "$(grep -c 'Stack summary mode' "$LOG/pi.runs")" "a matching summary is cached"
  assert_eq ready "$("$BERCAIL" review-pr state --stack "$stack" | jq -r .summary.status)" "summary reaches the mod"

  cp "$dir/run.json" "$LOG/ready-run.json"
  jq '.status = "blocked"' "$LOG/ready-run.json" >"$dir/run.json"
  "$BERCAIL" review-pr summarize --stack "$stack"
  assert_eq "$before" "$(grep -c 'Stack summary mode' "$LOG/pi.runs")" "summary waits for every card"
  assert_eq waiting "$("$BERCAIL" review-pr state --stack "$stack" | jq -r .summary.status)" "old summary hidden while a card is not ready"
  cp "$LOG/ready-run.json" "$dir/run.json"
  jq '.decisions[0].statement = "A new decision at the same SHA"' "$dir/review.json" >"$LOG/new-card.json"
  cp "$LOG/new-card.json" "$dir/review.json"
  assert_eq waiting "$("$BERCAIL" review-pr state --stack "$stack" | jq -r .summary.status)" "a changed card invalidates the old summary"
  FAKE_PI=noblock "$BERCAIL" review-pr summarize --stack "$stack" && fail "invalid stack summary accepted"
  assert_eq failed "$("$BERCAIL" review-pr state --stack "$stack" | jq -r .summary.status)" "summary failure is visible"
  "$BERCAIL" review-pr summarize --stack "$stack"
  assert_eq ready "$("$BERCAIL" review-pr state --stack "$stack" | jq -r .summary.status)" "summary retry succeeds"

  # Viewing a legacy card must not implicitly rerun it or discard a valid result.
  jq '.session_id = "ses_old_headless" | del(.intent_analysis)' "$dir/review.json" >"$LOG/foreign-card.json"
  cp "$LOG/foreign-card.json" "$dir/review.json"
  (
    # shellcheck source=/dev/null
    source "$ROOT/lib/common.sh"
    # shellcheck source=/dev/null
    source "$ROOT/lib/review.sh"
    export BERCAIL_SELF="$BERCAIL"
    _review_load --stack "$stack"
    _review_summary_input "$LOG/legacy-summary-input.json" || fail "saved cards without intent_analysis must remain valid summary inputs"
    # shellcheck disable=SC2329
    _review_spawn() { printf '%s\n' "$*" >>"$LOG/ui-spawns"; }
    review_ui --stack "$stack"
  )
  grep -q ' review-pr run ' "$LOG/ui-spawns" && fail "ui implicitly reran a ready card"
  cmp -s "$LOG/foreign-card.json" "$dir/review.json" || fail "ui changed a ready card"
  assert_eq 'Re-review for code-based intent.' "$("$BERCAIL" review-pr state --stack "$stack" | jq -r '.prs[0].intent')" "legacy context is not labeled inferred intent"

  cp "$LOG/desk.json" "$LOG/desk.saved.json"
  jq '.status.state = "working" | .labels["bercail.review.session"] = "other-session"' "$LOG/desk.saved.json" >"$LOG/desk.json"
  : >"$LOG/hc"
  out="$("$BERCAIL" review-pr ui --stack "$stack" 2>&1)" || fail "a busy desk prevented showing the Stack tab"
  assert_has "$out" "is working" "busy desk error"
  grep -qE '^(run|kill|rm) ' "$LOG/hc" && fail "interrupted a working desk"
  cp "$LOG/desk.saved.json" "$LOG/desk.json"
}

@test "desk preflight preserves cards, busy gathers wait, a quit desk comes back on its session, a desk that quits fails its pass" {
  local stack="$REVIEWS/stack-7" dir="$REVIEWS/stack-7/pr-7/$SHA7" out session runner
  ready_7
  cp "$dir/run.json" "$LOG/preflight-run.json"
  cp "$dir/review.json" "$LOG/preflight-review.json"
  cp "$LOG/desk.json" "$LOG/preflight-desk.json"
  jq '.status.state = "working" | .labels["bercail.review.session"] = "other-session"' "$LOG/preflight-desk.json" >"$LOG/desk.json"
  out="$("$BERCAIL" review-pr run 7 --stack "$stack" 2>&1)" && fail "used a busy unrelated desk"
  assert_has "$out" "is working" "run explains why it could not start"
  cmp -s "$LOG/preflight-run.json" "$dir/run.json" || fail "preflight failure replaced run.json"
  cmp -s "$LOG/preflight-review.json" "$dir/review.json" || fail "preflight failure deleted the ready card"

  # A gather can still show the space when its desk is busy, but must not claim a pass started.
  rm -f "$dir/run.json"
  out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/7 2>"$LOG/busy-gather.err")"
  assert_eq 's1 waiting' "$(jq -r '"\(.space) \(.pass)"' <<<"$out")" "busy desk keeps its space and waits"
  [[ ! -f "$dir/run.json" ]] || fail "gather launched a pass against an unavailable desk"
  cmp -s "$LOG/preflight-review.json" "$dir/review.json" || fail "busy gather changed the card"
  cp "$LOG/preflight-run.json" "$dir/run.json"
  cp "$LOG/preflight-desk.json" "$LOG/desk.json"

  cp "$HERDR_STATE" "$LOG/preflight-spaces.json"
  jq '.spaces |= map(select(.id != "s1"))' "$LOG/preflight-spaces.json" >"$HERDR_STATE"
  out="$("$BERCAIL" review-pr run 7 --stack "$stack" 2>&1)" && fail "run used a closed review space"
  assert_has "$out" "no Herdr space" "closed-space preflight error"
  cmp -s "$LOG/preflight-run.json" "$dir/run.json" || fail "closed-space preflight replaced run.json"
  cmp -s "$LOG/preflight-review.json" "$dir/review.json" || fail "closed-space preflight deleted the card"
  cp "$LOG/preflight-spaces.json" "$HERDR_STATE"

  # A desk whose Pi quit comes back on the same session.
  session="$(jq -r .session_id "$stack/desk.json")"
  kill "$(jq -r .pid "$stack/desk/pi.json")"
  : >"$LOG/hc"
  "$BERCAIL" review-pr ui --stack "$stack"
  assert_eq "$session" "$(jq -r .session_id "$stack/desk.json")" "a restarted desk keeps its session"
  assert_has "$(<"$LOG/hc")" "--session-id $session" "the new desk resumes the review session"
  kill -0 "$(jq -r .pid "$stack/desk/pi.json")" || fail "the new desk's Pi runs"
  # ui asked the desk for a stack summary; let it finish before the next turn.
  settle
  # A desk that quits mid-turn fails the pass instead of waiting forever.
  rm -f "$LOG/pi.child" "$LOG/pi.release"
  FAKE_HOLD=1 "$BERCAIL" review-pr run 7 --stack "$stack" >/dev/null 2>&1 &
  runner=$!
  wait_for "$LOG/pi.child"
  kill "$(jq -r .pid "$stack/desk/pi.json")"
  wait_exit "$runner" "the pass whose desk quit" && fail "a pass whose desk quit succeeded"
  assert_has "$(jq -r .reason "$dir/run.json")" "the review desk exited" "the pass says the desk quit"
  rm -f "$LOG/pi.child"
  cp "$LOG/preflight-run.json" "$dir/run.json"
  cp "$LOG/preflight-review.json" "$dir/review.json"
  "$BERCAIL" review-pr ui --stack "$stack"
  [[ ! -L "$dir/pass.lock" && ! -L "$stack/desk-pass.lock" ]] || fail "preflight failure leaked a lock"
}

# --- open: tuicr pr N directly, seeded with [AI Agent] questions ------------------
# A desk started in place of the one running the turn never saw the request:
# the pass fails instead of waiting on it forever.
@test "a pass whose desk was replaced mid-turn fails instead of waiting forever" {
  local stack="$REVIEWS/stack-7" dir="$REVIEWS/stack-7/pr-7/$SHA7" runner caller desk
  ready_7
  rm -f "$LOG/pi.child" "$LOG/pi.release" "$LOG/pi.caller"
  FAKE_HOLD=1 "$BERCAIL" review-pr run 7 --stack "$stack" >/dev/null 2>&1 &
  runner=$!
  wait_for "$LOG/pi.child"
  caller="$(cat "$LOG/pi.caller")" desk="$(jq -r .pid "$stack/desk/pi.json")"
  # Hold the waiting turn still, so the new desk is up before it looks again.
  kill -STOP "$caller"
  kill "$desk"
  wait_gone "$desk" "the killed desk"
  "$BERCAIL" review-pr ui --stack "$stack"
  [[ "$(jq -r .pid "$stack/desk/pi.json")" != "$desk" ]] || fail "ui did not start a new desk"
  kill -CONT "$caller"
  wait_exit "$runner" "the pass whose desk was replaced" && fail "a pass whose desk was replaced succeeded"
  assert_has "$(jq -r .reason "$dir/run.json")" "the review desk exited" "the pass says its desk is gone"
}

@test "open: a Review #N tab on tuicr pr N (no desk mod), waits for tuicr, seeds [AI Agent] notes once, made fresh, one tuicr per space" {
  local out dir="$REVIEWS/stack-7/pr-7/$SHA7"
  space_7
  FAKE_PI=ok "$BERCAIL" review-pr run --stack "$REVIEWS/stack-7" >/dev/null
  : >"$LOG/herdr"
  (cd "$BATS_TEST_TMPDIR/work/widgets.review-7" && FAKE_TUICR_HOLD=1 HC_TERMINAL_ID=t-elsewhere BERCAIL_REVIEW_OPEN_WAIT=5 "$BERCAIL" review-pr open) >"$LOG/open-result" &
  local opener=$!
  wait_for "$LOG/tuicr.held"
  assert_has "$("$BERCAIL" review-pr open --stack "$REVIEWS/stack-7" 2>&1 || true)" "already being opened" "a second open cannot duplicate drafts"
  touch "$LOG/tuicr.release"
  wait_exit "$opener" "the held open"
  out="$(cat "$LOG/open-result")"
  assert_eq '{"space":"s1","name":"Review #7","folder":"'"$BATS_TEST_TMPDIR/work/widgets.review-7"'","argv":["tuicr","pr","7","--no-update-check"]}' \
    "$(sed -n 's/^do tab.new //p' "$LOG/herdr" | grep '"Review #7"')" "a Review #7 tab on tuicr pr 7, in the review space"
  grep -q "bercail-desk" "$LOG/herdr" && fail "open needs no desk mod"
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
  # Again: the Review tab is made fresh (its tuicr may be gone), and nothing is seeded twice.
  : >"$LOG/herdr"
  (cd "$BATS_TEST_TMPDIR/work/widgets.review-7" && BERCAIL_REVIEW_OPEN_WAIT=5 "$BERCAIL" review-pr open) >/dev/null 2>&1
  assert_eq 1 "$(jq '[.spaces[] | select(.id == "s1") | .tabs[] | select(.name | startswith("Review"))] | length' "$HERDR_STATE")" \
    "one Review tab"
  assert_has "$(<"$LOG/herdr")" "do tab.close" "the old Review #7 tab goes"
  assert_eq 3 "$(wc -l <"$LOG/tuicr.add" | tr -d ' ')" "opening again does not seed twice"
  # Another PR's Review tab goes first: one tuicr per space.
  jq '(.spaces[] | select(.id == "s1") | .tabs[] | select(.name == "Review #7") | .name) = "Review #9"' "$HERDR_STATE" >"$HERDR_STATE.tmp" \
    && mv "$HERDR_STATE.tmp" "$HERDR_STATE"
  : >"$LOG/herdr"
  (cd "$BATS_TEST_TMPDIR/work/widgets.review-7" && BERCAIL_REVIEW_OPEN_WAIT=5 "$BERCAIL" review-pr open) >/dev/null 2>&1
  assert_has "$(<"$LOG/herdr")" "do tab.close" "another PR's Review tab is closed"
  assert_has "$(<"$LOG/herdr")" '"name":"Review #7"' "and #7's is made"
}

# --- the blobless clone when no checkout is around; no checks at all ---------------
@test "no checkout around: ~/Work/<repo> plus a sibling; no gh pr checks JSON: the rollup; a queued head does not review a newer one" {
  # Another repo name forces the no-local-checkout path.
  local out
  herdr_up
  REVIEWS="$XDG_STATE_HOME/bercail/reviews/github.com/acme/remote-only"
  mkdir -p "$REVIEWS"
  out="$(cd / && FAKE_NO_CHECKS=1 "$BERCAIL" review-pr https://github.com/acme/remote-only/pull/8)"
  [[ -d "$HOME/Work/remote-only" ]] || fail "no fallback checkout at ~/Work/remote-only"
  assert_eq "$SHA8" "$(git -C "$HOME/Work/remote-only.review-8" rev-parse HEAD)" "sibling of the fallback checkout"
  # No JSON from gh pr checks: the rollup from gh pr view stands in.
  assert_eq '[{"name":"lint","workflow":"CI","state":"FAILURE","link":"https://ci/lint","bucket":"fail"}]' \
    "$(jq -c . "$REVIEWS/stack-8/pr-8/$SHA8/ci.json")" "ci.json from statusCheckRollup"
  assert_eq '{"fail":1}' "$(jq -c '.prs[0].ci' <<<"$out")" "rollup CI counts"
  # A push to the PR, then review-pr from the local checkout: the new head is
  # fetched into the private clone the worktree came from.
  local sha
  sha="$(cd "$BATS_TEST_TMPDIR/seed" && git switch -q docs && echo again >>README && git commit -qam again && git rev-parse HEAD)"
  git -C "$BATS_TEST_TMPDIR/seed" push -q "$REMOTE" HEAD:refs/pull/8/head
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
}

@test "help and usage list review-pr; bad URLs are refused" {
  assert_has "$("$BERCAIL" help)" "review-pr" "bercail help lists review-pr"
  assert_has "$("$BERCAIL" nope 2>&1 || true)" "review-pr" "usage lists review-pr"
  assert_has "$("$BERCAIL" review-pr)" "open [N]" "review-pr usage"
  assert_has "$("$BERCAIL" review-pr)" "close [<PR url> | N] [--force]" "review-pr usage lists close"
  assert_has "$("$BERCAIL" help)" "review-pr close" "bercail help lists close"
  assert_has "$(<"$ROOT/docs/cli.md")" "review-pr close" "docs/cli.md lists close"
  assert_has "$("$BERCAIL" review-pr https://github.com/acme/widgets/issues/1 2>&1 || true)" "not a pull request URL" "bad URL"
  grep -qx 'pi/agents/bstack-pr-review.md' "$ROOT/bstack/MANIFEST" || fail "MANIFEST ships the reviewer's rules"
  grep -qx 'pi/extensions/review.ts' "$ROOT/bstack/MANIFEST" || fail "MANIFEST ships the reviewer's extension"
  grep -qx 'pi/prompts/pr-review.md' "$ROOT/bstack/MANIFEST" || fail "MANIFEST ships the /pr-review prompt"
}

# The reviewer is read-only by its argv; review.ts keeps reads in the stack dir
# (tests/review_pi_test.sh proves that on a real Pi).
@test "bstack-pr-review on Pi: read, grep, find and ls only, review.ts, the pr-review rules" {
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/bstack.sh"
  local argv
  _bstack_pi_review_argv claude-bridge/claude-opus-5-5#high
  argv="${BSTACK_PI_ARGV[*]}"
  assert_has "$argv" "--model claude-bridge/claude-opus-5-5:high" "the lead's model"
  assert_has "$argv" "--tools read,grep,find,ls" "read-only tools"
  assert_has "$argv" "-e $BSTACK_PI_DIR/extensions/review.ts" "review.ts confines reads"
  assert_has "$argv" "--no-skills --no-prompt-templates --no-context-files" "nothing but the pr-review rules"
  assert_has "$argv" "--append-system-prompt $BSTACK_PI_DIR/agents/bstack-pr-review.md" "the pr-review rules"
  if grep -q -- '-e .*guard.ts' <<<"$argv"; then fail "no bash, so no guard"; fi
}


# --- stacks ----------------------------------------------------------------------

pr_stack() { # n sha title body base head base_sha
  jq -n --argjson n "$1" --arg sha "$2" --arg title "$3" --arg body "$4" --arg base "$5" --arg head "$6" --arg bsha "$7" '{
    number: $n, title: $title, body: $body, url: "https://github.com/acme/widgets/pull/\($n)",
    author: {login: "dana"}, isDraft: false, baseRefName: $base, headRefName: $head,
    headRefOid: $sha, baseRefOid: $bsha, closingIssuesReferences: [],
    files: [{path: "lib/\($head).sh", additions: 1, deletions: 0, changeType: "ADDED"}],
    statusCheckRollup: []}' >"$FIX/pr-$1.json"
}

# The Herdr app up, another worktree of the source, and the source's state, for
# assert_source_untouched: nothing review-pr does to a stack may move them.
stack_source() {
  herdr_up
  seed="$BATS_TEST_TMPDIR/seed"
  wreviews="$XDG_STATE_HOME/bercail/reviews/github.com/acme/widgets"
  linked='[{"number":12,"url":"https://github.com/acme/widgets/issues/12"}]'
  main_sha="$(git -C "$seed" rev-parse main)"
  src_head="$(git -C "$WORK" rev-parse HEAD)"
  src_branch="$(git -C "$WORK" branch --show-current)"
  src_status="$(git -C "$WORK" status --porcelain)"
  src_cfg="$(git -C "$WORK" config --local --list | sort)"
  printf 'sentinel\n' >"$WORK/.git/FETCH_HEAD"
  other="$BATS_TEST_TMPDIR/work/widgets.other"
  git -C "$WORK" worktree add --detach -q "$other" HEAD
  other_sha="$(git -C "$other" rev-parse HEAD)"
}

assert_source_untouched() {
  assert_eq "$src_head" "$(git -C "$WORK" rev-parse HEAD)" "source HEAD unchanged"
  assert_eq "$src_branch" "$(git -C "$WORK" branch --show-current)" "source branch unchanged"
  assert_eq "$src_status" "$(git -C "$WORK" status --porcelain)" "source status unchanged"
  assert_eq "$src_cfg" "$(git -C "$WORK" config --local --list | sort)" "source config unchanged"
  assert_eq "$other_sha" "$(git -C "$other" rev-parse HEAD)" "another worktree is untouched"
  assert_eq sentinel "$(cat "$WORK/.git/FETCH_HEAD")" "FETCH_HEAD is not rewritten"
}

# Three dependent PRs pushed as pull heads, #21 <- #22 <- #23. #22 is thin.
three_prs() {
  local n
  git -C "$seed" switch -q main
  git -C "$seed" switch -qc s1
  mkdir -p "$seed/lib"
  printf 'S1ONLY\n' >"$seed/lib/s1.sh"
  git -C "$seed" add lib/s1.sh && git -C "$seed" commit -qm s1
  sha21="$(git -C "$seed" rev-parse HEAD)"
  git -C "$seed" push -q "$REMOTE" HEAD:refs/pull/21/head
  git -C "$seed" switch -qc s2
  printf 'S2ONLY\n' >"$seed/lib/s2.sh"
  ln -s /etc/hostname "$seed/lib/s2-link"
  git -C "$seed" add lib/s2.sh lib/s2-link && git -C "$seed" commit -qm s2
  sha22="$(git -C "$seed" rev-parse HEAD)"
  git -C "$seed" push -q "$REMOTE" HEAD:refs/pull/22/head
  git -C "$seed" switch -qc s3
  printf 'S3ONLY\n' >"$seed/lib/s3.sh"
  printf '{}\n' >"$seed/package-lock.json"
  git -C "$seed" add lib/s3.sh package-lock.json && git -C "$seed" commit -qm s3
  sha23="$(git -C "$seed" rev-parse HEAD)"
  git -C "$seed" push -q "$REMOTE" HEAD:refs/pull/23/head

  pr_stack 21 "$sha21" "Stack one" "Adds the first slice." main s1 "$main_sha"
  pr_stack 22 "$sha22" "Stack two" "" s1 s2 "$sha21"
  pr_stack 23 "$sha23" "Stack three" "Adds the third slice." s2 s3 "$sha22"
  for n in 21 23; do
    jq --argjson c "$linked" '.closingIssuesReferences = $c' "$FIX/pr-$n.json" >"$FIX/pr-$n.json.new"
    mv "$FIX/pr-$n.json.new" "$FIX/pr-$n.json"
  done
  jq -n --argjson n 21 --arg base main --arg head s1 '[{number:$n, baseRefName:$base, headRefName:$head, url:"https://github.com/acme/widgets/pull/21"}]' >"$FIX/list-head-s1.json"
  jq -n --argjson n 22 --arg base s1 --arg head s2 '[{number:$n, baseRefName:$base, headRefName:$head, url:"https://github.com/acme/widgets/pull/22"}]' >"$FIX/list-head-s2.json"
  jq -n --argjson n 22 --arg base s1 --arg head s2 '[{number:$n, baseRefName:$base, headRefName:$head, url:"https://github.com/acme/widgets/pull/22"}]' >"$FIX/list-base-s1.json"
  jq -n --argjson n 23 --arg base s2 --arg head s3 '[{number:$n, baseRefName:$base, headRefName:$head, url:"https://github.com/acme/widgets/pull/23"}]' >"$FIX/list-base-s2.json"
  stack="$wreviews/stack-21" sib="$BATS_TEST_TMPDIR/work/widgets.review-21"
}

# three_prs gathered from the middle PR, no passes.
three_prs_gathered() {
  three_prs
  (cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/22 --no-run) >/dev/null
}

# three_prs_gathered with every PR's pass ready on the desk session.
three_prs_ready() {
  three_prs_gathered
  "$BERCAIL" review-pr run --stack "$stack" >/dev/null
  "$BERCAIL" review-pr run 22 --stack "$stack" >/dev/null
}

# #71 and #73 on main, and #72, a cross-repo PR whose head is also named main.
cross_repo_prs() {
  jq -n --arg sha "$main_sha" '[{number:99, baseRefName:"main", headRefName:"other", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/99"},
    {number:71, baseRefName:"main", headRefName:"feat", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/71"}]' >"$FIX/list-base-main.json"
  jq -n --arg sha "$main_sha" '[{number:72, baseRefName:"main", headRefName:"main", isCrossRepository:true, url:"https://github.com/acme/widgets/pull/72"}]' >"$FIX/list-head-main.json"
  pr_stack 71 "$main_sha" "Internal feat" "An internal PR." main feat "$main_sha"
  pr_stack 72 "$main_sha" "Cross fork" "From a fork." main main "$main_sha"
  pr_stack 73 "$main_sha" "Develop" "Based on develop." main develop "$main_sha"
  jq '.isCrossRepository = false' "$FIX/pr-71.json" >"$FIX/pr-71.json.new" && mv "$FIX/pr-71.json.new" "$FIX/pr-71.json"
  jq '.isCrossRepository = true' "$FIX/pr-72.json" >"$FIX/pr-72.json.new" && mv "$FIX/pr-72.json.new" "$FIX/pr-72.json"
  jq '.isCrossRepository = false' "$FIX/pr-73.json" >"$FIX/pr-73.json.new" && mv "$FIX/pr-73.json.new" "$FIX/pr-73.json"
}

@test "a middle PR gathers its 3-PR stack root to tip, diffs each PR against its parent, and a dirty worktree refuses a regather" {
  local out mid
  stack_source
  three_prs
  out="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/22 --no-run)"
  assert_eq "$stack" "$(jq -r .stack <<<"$out")" "middle PR uses the root run dir"
  assert_eq "$sib" "$(jq -r .worktree <<<"$out")" "middle PR uses the root sibling"
  assert_eq '21 22 23' "$(jq -r '[.prs[].number] | join(" ")' "$stack/stack.json")" "root-to-tip order"
  assert_eq "$main_sha $sha21 $sha22" "$(jq -r '[.prs[].base_sha] | join(" ")' "$stack/stack.json")" "base shas: trunk, then parent heads"
  assert_eq "$sha21" "$(git -C "$sib" rev-parse HEAD)" "worktree starts at the root head"
  assert_has "$(<"$stack/stack.md")" "1. #21" "stack.md order"
  assert_eq '[] ["empty_body","no_linked_issue"] []' "$(jq -r '[.prs[].thin | tojson] | join(" ")' <<<"$out")" "thin is per PR"
  assert_eq 'waiting waiting waiting' "$(jq -r '[.prs[].pass] | join(" ")' <<<"$out")" "--no-run waits"
  mid="$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/23 --no-run)"
  assert_eq "$stack $sib" "$(jq -r '"\(.stack) \(.worktree)"' <<<"$mid")" "top PR is the same space"
  mid="$(cd "$WORK" && "$BERCAIL" review-pr s2 --no-run)"
  assert_eq "$stack" "$(jq -r .stack <<<"$mid")" "branch input is the same stack"
  assert_has "$(<"$stack/pr-22/$sha22/diff.patch")" "S2ONLY" "diff vs parent includes this PR"
  grep -q S1ONLY "$stack/pr-22/$sha22/diff.patch" && fail "diff vs parent must not be the trunk diff"
  assert_has "$(<"$stack/pr-22/$sha22/intent.md")" "commit $sha22" "middle PR includes its own commit"
  grep -qF "commit $sha21" "$stack/pr-22/$sha22/intent.md" && fail "middle PR includes its parent's commit"
  grep -qF "commit $sha23" "$stack/pr-22/$sha22/intent.md" && fail "middle PR includes the next PR's commit"
  [[ ! -e "$stack/pr-23/$sha23/source/package-lock.json" ]] || fail "lock file not snapshotted"
  [[ -s "$stack/pr-22/$sha22/source/lib/s2.sh" ]] || fail "parent diff snapshot"
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
  assert_source_untouched
}

@test "run on a stack starts its non-thin PRs in parallel, a thin PR only when named, all on the desk session" {
  local launcher desk_session n
  stack_source
  three_prs_gathered
  rm -f "$LOG/pi.child" "$LOG/pi.release"
  FAKE_HOLD=1 "$BERCAIL" review-pr run --stack "$stack" >"$LOG/multi-run" 2>"$LOG/multi-err" &
  launcher=$!
  appears "$stack/pr-21/$sha21/pass.lock" || {
    echo "MULTI out=$(cat "$LOG/multi-run" 2>/dev/null) err=$(cat "$LOG/multi-err" 2>/dev/null)" >&2
    find "$stack" -name 'pass.lock' -o -name 'pass.err' -o -name 'run.json' >&2
    fail "parallel run did not lock PR 21"
  }
  appears "$stack/pr-23/$sha23/pass.lock" || {
    echo "23 missing sha=$sha23" >&2
    find "$stack/pr-23" -maxdepth 2 -type d -o -name 'pass.*' -o -name 'run.json' >&2
    echo "err23=$(cat "$stack"/pr-23/*/pass.err 2>/dev/null)" >&2
    fail "parallel run did not lock PR 23"
  }
  [[ ! -L "$stack/pr-22/$sha22/pass.lock" ]] || fail "a thin PR is not started by run without N"
  # A pass drops the stack lock once it holds its own, and still runs.
  vanishes "$stack/context.lock" || fail "passes must not hold the stack lock"
  [[ -L "$stack/pr-21/$sha21/pass.lock" && -L "$stack/pr-23/$sha23/pass.lock" ]] || fail "the passes still run"
  touch "$LOG/pi.release"
  wait_exit "$launcher" "the parallel run"
  assert_eq ready "$(jq -r .status "$stack/pr-21/$sha21/run.json")" "parallel pass 21"
  assert_eq ready "$(jq -r .status "$stack/pr-23/$sha23/run.json")" "parallel pass 23"
  [[ ! -e "$stack/pr-22/$sha22/run.json" ]] || fail "thin PR still waiting"
  "$BERCAIL" review-pr run 22 --stack "$stack" >/dev/null
  assert_eq ready "$(jq -r .status "$stack/pr-22/$sha22/run.json")" "explicit run of a thin PR"
  desk_session="$(jq -r .session_id "$stack/desk.json")"
  for n in 21 22 23; do
    assert_eq "$desk_session" "$(jq -r .session_id "$stack/pr-$n/$(jq -r --argjson n "$n" '.prs[] | select(.number == $n) | .head_sha' "$stack/stack.json")/run.json")" \
      "all stack passes share the visible desk session"
  done

  "$BERCAIL" review-pr state --stack "$stack" | jq -e '.header | test("Stack one")' >/dev/null || fail "multi header from stack.md"
  assert_source_untouched
}

@test "re-reviewing a middle PR refreshes the whole stack and reruns only that PR" {
  local n
  stack_source
  three_prs_ready
  cp "$stack/pr-21/$sha21/run.json" "$LOG/sibling-before-rereview.json"
  jq '.finished_at = "old"' "$stack/pr-22/$sha22/run.json" >"$LOG/middle-old.json"
  cp "$LOG/middle-old.json" "$stack/pr-22/$sha22/run.json"
  : >"$LOG/gh"
  "$BERCAIL" review-pr rereview 22 --stack "$stack" >/dev/null 2>"$LOG/middle-rereview.err" \
    || fail "middle re-review: $(cat "$LOG/middle-rereview.err")"
  for n in 21 22 23; do assert_has "$(<"$LOG/gh")" "pr view $n" "re-review refreshes #$n"; done
  assert_eq ready "$(jq -r 'select(.finished_at != "old") | .status' "$stack/pr-22/$sha22/run.json")" "middle pass reran"
  cmp -s "$LOG/sibling-before-rereview.json" "$stack/pr-21/$sha21/run.json" || fail "re-review reran another PR's pass"
  assert_eq "22 $sha22" "$(jq -r .current "$stack/stack.json") $(git -C "$sib" rev-parse HEAD)" "re-review restores the middle PR"
  assert_source_untouched
}

@test "legacy desk dispatch times out; direct middle-PR tuicr launch works without a desk callback or checkout" {
  local wt current head out
  stack_source
  three_prs_ready
  wt="$sib"
  current="$(jq -r .current "$stack/stack.json")"
  "$BERCAIL" review-pr select 21 --stack "$stack"
  head="$(git -C "$wt" rev-parse HEAD)"
  cp "$HERDR_STATE" "$LOG/middle-open-spaces.json"
  jq -n --arg wt "$wt" '{spaces:[{id:"s-middle",folder:$wt,tabs:[
    {id:"middle-shell",name:"Shell",terminals:[{terminal:"t-middle"}]},
    {id:"old-review",name:"Review #7",terminals:[{terminal:"t-old-review"}]}]}]}' >"$HERDR_STATE"
  echo 7 >"$LOG/tuicr.active"

  # The old launcher succeeds as an RPC but an older desk ignores the command.
  # Another active PR must not make the requested middle PR look ready.
  (
    # shellcheck source=/dev/null
    source "$ROOT/lib/common.sh"
    # shellcheck source=/dev/null
    source "$ROOT/lib/review.sh"
    # shellcheck disable=SC2329
    _review_review_tab() { "$HERDR_APP" "do" "bercail-desk.review-pr-22:t-middle" >/dev/null; }
    BERCAIL_REVIEW_OPEN_WAIT=1 review_open 22 --stack "$stack"
  ) >"$LOG/legacy-middle-open" 2>&1 && fail "legacy desk dispatch unexpectedly opened tuicr"
  assert_has "$(<"$LOG/legacy-middle-open")" "did not open PR #22 within 1s" "legacy dispatch reproduces the timeout"
  assert_eq 7 "$(cat "$LOG/tuicr.active")" "the unrelated active PR was not accepted"

  : >"$LOG/herdr"
  out="$(BERCAIL_REVIEW_OPEN_WAIT=2 "$BERCAIL" review-pr open 22 --stack "$stack")"
  assert_eq gh:acme/widgets/pr/22 "$(jq -r .session <<<"$out")" "opens the middle PR, not the worktree's PR"
  assert_has "$(<"$LOG/herdr")" '"name":"Review #22"' "creates the requested Review tab"
  assert_eq '["tuicr","pr","22","--no-update-check"]' "$(jq -c . "$LOG/stack.argv")" "direct tuicr launch needs no desk callback"
  grep -q 'bercail-desk' "$LOG/herdr" && fail "direct open still dispatched to the desk mod"
  assert_eq "21 $head" "$(jq -r .current "$stack/stack.json") $(git -C "$wt" rev-parse HEAD)" "open does not switch the worktree"
  cp "$LOG/middle-open-spaces.json" "$HERDR_STATE"
  "$BERCAIL" review-pr select "$current" --stack "$stack"
  assert_source_untouched
}

@test "a branched stack, entered from its root, middle or leaf, or two PRs on one head, reviews the entry PR alone" {
  local fork_out
  stack_source
  pr_stack 41 "$main_sha" "Fork root" "Root of a fork." main fork-a "$main_sha"
  pr_stack 42 "$main_sha" "Fork mid" "Middle of a fork." fork-a up-b "$main_sha"
  pr_stack 44 "$main_sha" "Fork leaf" "Leaf of a fork." up-b up-b2 "$main_sha"
  jq -n '[{number:42, baseRefName:"fork-a", headRefName:"up-b", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/42"},
          {number:43, baseRefName:"fork-a", headRefName:"up-c", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/43"}]' >"$FIX/list-base-fork-a.json"
  jq -n '[{number:41, baseRefName:"main", headRefName:"fork-a", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/41"}]' >"$FIX/list-head-fork-a.json"
  jq -n '[{number:42, baseRefName:"fork-a", headRefName:"up-b", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/42"}]' >"$FIX/list-head-up-b.json"
  jq -n '[{number:44, baseRefName:"up-b", headRefName:"up-b2", isCrossRepository:false, url:"https://github.com/acme/widgets/pull/44"}]' >"$FIX/list-base-up-b.json"
  # Middle and leaf first, so a partial stack-41 cannot already exist.
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
  assert_source_untouched
}

@test "trunk is origin/HEAD: a cross-repo head is not a parent, other trunk PRs are not children, a develop root keeps its trunk" {
  local gh_before cross_out
  stack_source
  # Trunk is origin/HEAD. A cross-repo PR whose head is also named main is not a parent
  # and is not walked up from. Other PRs based on main are not children of develop.
  cross_repo_prs
  touch "$LOG/gh"
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
  assert_source_untouched
}

@test "a stack cycle is an error" {
  stack_source
  three_prs
  jq -n --arg sha "$sha21" '{number:51, title:"cycle a", body:"a", url:"https://github.com/acme/widgets/pull/51",
    author:{login:"dana"}, isDraft:false, baseRefName:"cycle-b", headRefName:"cycle-a",
    headRefOid:$sha, baseRefOid:$sha, closingIssuesReferences:[], files:[], statusCheckRollup:[]}' >"$FIX/pr-51.json"
  jq -n --arg sha "$sha22" '{number:52, title:"cycle b", body:"b", url:"https://github.com/acme/widgets/pull/52",
    author:{login:"dana"}, isDraft:false, baseRefName:"cycle-a", headRefName:"cycle-b",
    headRefOid:$sha, baseRefOid:$sha, closingIssuesReferences:[], files:[], statusCheckRollup:[]}' >"$FIX/pr-52.json"
  jq -n '[{number:52, baseRefName:"cycle-a", headRefName:"cycle-b", url:"https://github.com/acme/widgets/pull/52"}]' >"$FIX/list-head-cycle-b.json"
  jq -n '[{number:51, baseRefName:"cycle-b", headRefName:"cycle-a", url:"https://github.com/acme/widgets/pull/51"}]' >"$FIX/list-head-cycle-a.json"
  local tmp_before
  tmp_before="$(ls -A "$TMPDIR")"
  assert_has "$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/51 2>&1 || true)" \
    "cycle" "a cycle is an error"
  # Other processes' temp files may come and go; none may be new.
  assert_eq '' "$(comm -13 <(sort <<<"$tmp_before") <(ls -A "$TMPDIR" | sort))" "the refused cycle leaves no temp file"
  assert_source_untouched
}

@test "a gather holds the stack's context lock, so a second gather waits" {
  local holder
  stack_source
  three_prs_gathered
  rm -f "$LOG/gh.held" "$LOG/gh.release" "$LOG/pi.release"
  FAKE_GH_HOLD=1 "$BERCAIL" review-pr https://github.com/acme/widgets/pull/21 --no-run >"$LOG/gather-hold" &
  holder=$!
  wait_for "$LOG/gh.held"
  [[ -L "$stack/context.lock" ]] || fail "gather did not take the context lock"
  assert_has "$(cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/21 --no-run 2>&1 || true)" \
    "review stack is busy" "a second gather waits"
  touch "$LOG/gh.release"
  wait_exit "$holder" "the held gather"
  assert_source_untouched
}

@test "graphite: a 5-PR stack entered from the middle syncs with gt only in a private clone; a fork entry reviews alone" {
  local i gsha prev base_name name parent n gcfg out gt_before cross_out fork_out sync
  stack_source
  cross_repo_prs
  # Graphite: five PRs, entered from the middle. gt runs only in a private clone.
  prev="$main_sha"
  git -C "$seed" switch -q main
  for i in 1 2 3 4 5; do
    git -C "$seed" switch -qc "g$i"
    printf 'G%s\n' "$i" >"$seed/g$i.txt"
    git -C "$seed" add "g$i.txt" && git -C "$seed" commit -qm "g$i"
    gsha="$(git -C "$seed" rev-parse HEAD)"
    git -C "$seed" push -q "$REMOTE" "HEAD:refs/pull/$((30 + i))/head"
    base_name=main
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
  for i in 1 2 3 4 5; do
    name="g$i"
    n=$((30 + i))
    if [[ "$i" -eq 1 ]]; then parent=main; else parent="g$((i - 1))"; fi
    printf '%s\n\nPR #%s graphite\n\nParent: %s\nChildren:\n\ncommit abc\n' "$name" "$n" "$parent" >"$FIX/gt-info-$name"
  done
  gcfg="$(git -C "$WORK" rev-parse --path-format=absolute --git-common-dir)/.graphite_repo_config"
  git -C "$WORK" update-ref refs/branch-metadata/g1 HEAD
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
  git -C "$WORK" update-ref -d refs/branch-metadata/g1
  sync="$XDG_STATE_HOME/bercail/reviews/github.com/acme/widgets/gt-sync"
  [[ "$(git -C "$sync" rev-parse --path-format=absolute --git-common-dir)" != "$(git -C "$WORK" rev-parse --path-format=absolute --git-common-dir)" ]] \
    || fail "private clone must not share the source git dir"
  assert_source_untouched
}

@test "no-source fallback is ~/Work/<repo>, or ~/Work/<owner>-<repo> if that path is taken" {
  local out
  herdr_up
  mkdir -p "$HOME/Work"
  printf 'occupied\n' >"$HOME/Work/occupied"
  out="$(cd / && "$BERCAIL" review-pr https://github.com/acme/occupied/pull/8 --no-run)"
  [[ -f "$HOME/Work/occupied" && "$(cat "$HOME/Work/occupied")" == occupied ]] || fail "fallback must not overwrite"
  [[ -d "$HOME/Work/acme-occupied" ]] || fail "fallback uses ~/Work/<owner>-<repo> when ~/Work/<repo> is taken"
  assert_eq "$(jq -r .headRefOid "$FIX/pr-8.json")" "$(git -C "$HOME/Work/acme-occupied.review-8" rev-parse HEAD)" "sibling of the alternate checkout"
}

# The requested PR first in a stack longer than a pipe buffer: a reader that
# stops at the first match would leave the rest unwritten, a SIGPIPE under pipefail.
@test "stack membership holds for the first PR of a long stack, and a missing PR is refused" {
  local out entry="$LOG/pr-1.json"
  # A child bash under bin/bercail's options: bats traces each command it runs
  # itself, which turns the 50000-PR walk into a minute.
  discover() {
    STACK_FIRST="$1" bash -c 'set -euo pipefail
      source "$ROOT/lib/common.sh"
      source "$ROOT/lib/stack.sh"
      _stack_github() { seq "$STACK_FIRST" 50000; }
      stack_discover github.com/acme/widgets "$1" "" "" gh' _ "$entry"
  }
  jq '.number = 1' "$FIX/pr-8.json" >"$entry"
  out="$(discover 1 2>"$LOG/membership.err")" \
    || fail "PR first in a long stack: $(<"$LOG/membership.err")"
  assert_eq '1 50000' "$(jq -r '"\(.numbers[0]) \(.numbers | length)"' <<<"$out")" "the whole stack, root first"
  # Rooted at #2, which the trunk lookup views.
  jq '.number = 2' "$FIX/pr-8.json" >"$FIX/pr-2.json"
  if discover 2 >/dev/null 2>"$LOG/membership.err"; then
    fail "a stack without the requested PR"
  fi
  assert_has "$(<"$LOG/membership.err")" "native stack omitted requested PR #1" "the missing PR is named"
}

# --- close: the worktree, the run dir, and the space ---------------------------------

# Everything review-pr made for #7 is still there.
assert_7_kept() {
  [[ -d "$WORK.review-7" && -f "$REVIEWS/stack-7/stack.json" ]] || fail "$1: the worktree and run dir stay"
  [[ "$(git -C "$WORK" worktree list --porcelain)" == *"widgets.review-7"* ]] || fail "$1: the worktree stays registered"
}

@test "close from the review worktree removes it, the desk, the run dir and the space, and nothing of yours; again is a no-op" {
  local out refs
  stack_source
  (cd / && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/7 --no-run) >/dev/null
  refs="$(git -C "$WORK" for-each-ref)"
  : >"$LOG/herdr"
  : >"$LOG/hc"
  out="$(cd "$WORK.review-7" && "$BERCAIL" review-pr close 2>&1)" || fail "close: $out"
  [[ ! -e "$WORK.review-7" ]] || fail "the review worktree is removed"
  if git -C "$WORK" worktree list --porcelain | grep -q 'widgets.review-7'; then fail "the worktree is unregistered"; fi
  [[ ! -e "$REVIEWS/stack-7" ]] || fail "the run dir is removed"
  assert_eq s0 "$(jq -r '[.spaces[].id] | join(" ")' "$HERDR_STATE")" "the review space is closed, yours stays"
  assert_has "$(<"$LOG/hc")" "kill t-desk" "the desk ends"
  assert_eq 'do space.close --id s1 --confirmed true' "$(grep '^do ' "$LOG/herdr")" \
    "the only command sent to the Herdr app closes that space; the shown space is not switched"
  assert_eq "$refs" "$(git -C "$WORK" for-each-ref)" "the source's branches and refs are unchanged"
  assert_source_untouched
  out="$(cd "$WORK" && "$BERCAIL" review-pr close 7 2>&1)" || fail "a second close fails: $out"
  assert_has "$out" "nothing to close for PR #7" "a second close says so"
  out="$(cd / && "$BERCAIL" review-pr close --stack "$REVIEWS/stack-7" 2>&1)" || fail "close --stack on a closed stack fails: $out"
  assert_has "$out" "nothing to close" "close --stack on a closed stack"
}

@test "close refuses a worktree with local changes, and --force drops them; without the Herdr app the rest still goes" {
  local out before
  reviewed_7
  before="$(git -C "$WORK" status --porcelain)"
  printf 'note\n' >"$WORK.review-7/note"
  if out="$(cd "$WORK" && "$BERCAIL" review-pr close 7 2>&1)"; then fail "a dirty worktree is closed: $out"; fi
  assert_has "$out" "local changes" "the refusal names the cause"
  assert_has "$out" "--force" "and the way out"
  assert_7_kept "dirty"
  [[ -f "$WORK.review-7/note" ]] || fail "the local change stays"
  out="$(cd "$WORK" && "$BERCAIL" review-pr close https://github.com/acme/widgets/pull/7 --force 2>&1)" || fail "close --force: $out"
  [[ ! -e "$WORK.review-7" && ! -e "$REVIEWS/stack-7" ]] || fail "--force removes the worktree and the run dir"
  if grep -q 'by hand' <<<"$out"; then fail "no space was made, so none to close by hand: $out"; fi
  assert_eq "$before" "$(git -C "$WORK" status --porcelain)" "the source checkout's status is unchanged"
}

@test "close with the Herdr app down removes the worktree and run dir and says the space is left to close by hand" {
  local out
  space_7
  unset FAKE_HERDR_UP
  out="$(cd "$WORK" && "$BERCAIL" review-pr close 7 2>&1)" || fail "close: $out"
  [[ ! -e "$WORK.review-7" && ! -e "$REVIEWS/stack-7" ]] || fail "the worktree and the run dir are removed"
  assert_has "$out" "close the review space there by hand" "the space that is left is named"
}

@test "close refuses while a gather, a pass, an open or the desk's summary or start runs, and removes nothing" {
  local out lock
  reviewed_7
  for lock in context "pr-7/$SHA7/pass" "pr-7/$SHA7/open" summary desk-init; do
    ln -s "$$" "$REVIEWS/stack-7/$lock.lock"
    if out="$(cd "$WORK" && "$BERCAIL" review-pr close 7 2>&1)"; then fail "closed under a live $lock lock: $out"; fi
    grep -qE 'try again when it ends|let it end, then close' <<<"$out" || fail "$lock: no word on waiting in: $out"
    assert_7_kept "$lock"
    rm -f "$REVIEWS/stack-7/$lock.lock"
  done
}

@test "close removes only a worktree review-pr made for this stack, and only a run dir under the reviews root" {
  local out gd stray="$BATS_TEST_TMPDIR/stray/stack-7"
  reviewed_7
  gd="$(git -C "$WORK.review-7" rev-parse --absolute-git-dir)"
  # The worktree's marker names another stack.
  printf '%s\n' "$REVIEWS/stack-8" >"$gd/bercail-review-stack"
  if out="$(cd "$WORK" && "$BERCAIL" review-pr close 7 2>&1)"; then fail "an unmarked worktree is removed: $out"; fi
  assert_has "$out" "not this stack's review worktree" "unmarked worktree"
  assert_7_kept "unmarked"
  printf '%s\n' "$REVIEWS/stack-7" >"$gd/bercail-review-stack"
  # stack.json names the main checkout.
  cp "$REVIEWS/stack-7/stack.json" "$LOG/stack.saved"
  jq --arg wt "$WORK" '.worktree = $wt' "$LOG/stack.saved" >"$REVIEWS/stack-7/stack.json"
  if out="$(cd / && "$BERCAIL" review-pr close --stack "$REVIEWS/stack-7" --force 2>&1)"; then fail "the main checkout is removed: $out"; fi
  assert_has "$out" "main checkout" "main checkout"
  [[ -f "$WORK/README" ]] || fail "the main checkout stays"
  cp "$LOG/stack.saved" "$REVIEWS/stack-7/stack.json"
  assert_7_kept "main checkout"
  # A commit on the detached worktree: clean, but on no branch.
  git -C "$WORK.review-7" commit -q --allow-empty -m mine
  if out="$(cd "$WORK" && "$BERCAIL" review-pr close 7 2>&1)"; then fail "a commit on no branch is dropped: $out"; fi
  assert_has "$out" "on no branch" "a detached commit"
  assert_7_kept "detached commit"
  git -C "$WORK.review-7" switch -q --detach "$SHA7"
  # A dir inside the run dir is not the run dir.
  if out="$(cd / && "$BERCAIL" review-pr close --stack "$REVIEWS/stack-7/pr-7" 2>&1)"; then fail "part of a run dir is removed: $out"; fi
  assert_has "$out" "not a review run dir" "inside the run dir"
  # The same owner/repo reviewed from another host is another repo.
  mkdir -p "$XDG_STATE_HOME/bercail/reviews/ghe.example.com/acme"
  mv "$REVIEWS" "$XDG_STATE_HOME/bercail/reviews/ghe.example.com/acme/widgets"
  git -C "$WORK" remote set-url origin https://github.com/acme/widgets.git
  if out="$(cd "$WORK" && "$BERCAIL" review-pr close 7 2>&1)"; then fail "another host's review is closed: $out"; fi
  assert_has "$out" "no review of this checkout's repo" "another host"
  [[ -d "$WORK.review-7" ]] || fail "another host's worktree stays"
  mv "$XDG_STATE_HOME/bercail/reviews/ghe.example.com/acme/widgets" "$REVIEWS"
  # Not in a checkout of the repo: N alone finds nothing, and says so as an error.
  if out="$(cd / && "$BERCAIL" review-pr close 7 2>&1)"; then fail "close 7 outside the repo succeeds: $out"; fi
  assert_has "$out" "pass the PR url" "outside the repo"
  assert_7_kept "outside the repo"
  # A stack.json somewhere else is not a run dir to delete.
  mkdir -p "$stray" && cp "$LOG/stack.saved" "$stray/stack.json"
  if out="$(cd / && "$BERCAIL" review-pr close --stack "$stray" --force 2>&1)"; then fail "a dir outside the reviews root is removed: $out"; fi
  assert_has "$out" "not a review run dir" "outside the reviews root"
  [[ -f "$stray/stack.json" ]] || fail "the stray dir stays"
  assert_7_kept "stray"
}

@test "close by a middle PR closes its whole stack; a worktree on a PR's branch goes and the branch stays; a worktree already gone is unregistered" {
  local out
  stack_source
  three_prs_gathered
  "$BERCAIL" review-pr checkout 23 --stack "$stack" >/dev/null
  assert_eq s3 "$(git -C "$sib" symbolic-ref --short HEAD)" "the worktree is on #23's branch"
  out="$(cd "$WORK" && "$BERCAIL" review-pr close 22 2>&1)" || fail "close 22: $out"
  [[ ! -e "$sib" && ! -e "$stack" ]] || fail "the stack rooted at #21 is closed from #22"
  assert_eq "$sha23" "$(git -C "$WORK" rev-parse s3)" "the branch checkout made stays"
  assert_has "$out" "branch s3 stays" "and close says so"
  assert_source_untouched
  # Deleted by hand: git still lists it until close.
  (cd "$WORK" && "$BERCAIL" review-pr https://github.com/acme/widgets/pull/7 --no-run) >/dev/null
  rm -rf "$WORK.review-7"
  out="$(cd "$WORK" && "$BERCAIL" review-pr close 7 2>&1)" || fail "close after rm -rf: $out"
  if git -C "$WORK" worktree list --porcelain | grep -q 'widgets.review-7'; then fail "the stale registration is removed"; fi
  [[ ! -e "$REVIEWS/stack-7" ]] || fail "the run dir is removed"
  [[ -d "$other" ]] || fail "another worktree of the source stays"
}
