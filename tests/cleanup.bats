#!/usr/bin/env bats
# bercail cleanup <worktree> against a real git repo with a bare remote, a fake
# Herdr app and a fake hc: what it archives, removes, ends and closes, and what
# it refuses. The cases are the G3 entries in the mistakes ledger.

assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1' got '$2'"; }
assert_has() { grep -qF -- "$2" <<<"$1" || fail "$3: no '$2' in:"$'\n'"$1"; }

setup() {
  load test_helper
  isolate
  need git jq
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  export HERDR_APP_BIN="$FAKE_BIN/herdr-app" HC_BIN="$FAKE_BIN/hc"
  export BERCAIL_HERDR_LAYOUT="$ROOT/config/worktrunk/herdr-layout.sh"
  export STATE="$BATS_TEST_TMPDIR/state" CALLS="$BATS_TEST_TMPDIR/calls.log"
  export PATH="$FAKE_BIN:$PATH"
  unset HC_TERMINAL_ID HC_FAIL HC_BLANK
  mkdir -p "$STATE"
  : >"$CALLS"
  BERCAIL="$ROOT/bin/bercail"
  ARCHIVE="$HOME/Work/worktree-archives/widgets"

  # The Herdr app: open spaces and recent ones in $STATE/herdr.json. Closing a
  # space moves it to recent, as the sidebar does. $STATE/down: no window.
  # $STATE/on-status-<n>: a jq filter run on hc.json at the nth status call.
  cat >"$FAKE_BIN/herdr-app" <<'SH'
#!/usr/bin/env bash
printf 'herdr-app %s\n' "$*" >>"$CALLS"
[[ ! -f "$STATE/down" ]] || exit 1
st="$STATE/herdr.json"
case "$1 ${2:-}" in
  "status ")
    n=$(($(cat "$STATE/statuses" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$STATE/statuses"
    if [[ -f "$STATE/on-status-$n" ]]; then
      jq -f "$STATE/on-status-$n" "$STATE/hc.json" >"$STATE/hc.tmp" && mv "$STATE/hc.tmp" "$STATE/hc.json"
    fi
    echo '{"space":"sp-main"}' ;;
  "ls ") [[ -f "$STATE/blank-ls" ]] || cat "$st" ;;
  "do space.close")
    jq --arg id "$4" '(.spaces[] | select(.id == $id) | {name, folder}) as $s
      | .recent = [$s] + .recent | .spaces |= map(select(.id != $id))' "$st" >"$st.tmp" && mv "$st.tmp" "$st" ;;
  *) echo '{"ok":true}' ;;
esac
SH
  # hc: terminals in $STATE/hc.json, each {address, state, cwd, labels}, and
  # as the real one {parent, die_with_parent, notify, pid, created_ms, status}.
  # ls prints only the live ones, and no labels; get does, and exits 3 on one
  # it does not know. kill ends the terminal and, natively, every terminal that
  # dies with it; each one that ends with notify wakes its live parent, idle or
  # done, to working. With $STATE/lag those that die with it end only at the
  # next kill. $STATE/on-kill-<address>, on-rm-<address>: a jq filter run on
  # hc.json after that call; herdr-on-kill-<address>, on herdr.json. With
  # $STATE/bad-row, ls lists a row with no address first. A kill of a working terminal is logged. $HC_FAIL:
  # the call that fails; $HC_BLANK: the call that succeeds and prints nothing.
  # get answers not_found on stderr, as hc does, for a terminal marked gone,
  # which ls still lists.
  cat >"$FAKE_BIN/hc" <<'SH'
#!/usr/bin/env bash
printf 'hc %s\n' "$*" >>"$CALLS"
[[ "$*" != "${HC_FAIL:-}" ]] || exit 1
[[ "$*" != "${HC_BLANK:-}" ]] || exit 0
st="$STATE/hc.json"
save() { jq "$@" "$st" >"$st.tmp" && mv "$st.tmp" "$st"; }
# End the terminals in $1 (a JSON list), and wake the parents they notify.
end() {
  save --argjson e "$1" '(map(select(.address | IN($e[])) | select(.notify) | .parent)) as $w
    | map(if .address | IN($e[]) then .state = "finished" | .status = null
      elif (.address | IN($w[])) and .state == "live" and (.status.state | IN("idle", "done")) then .status.state = "working"
      else . end)'
}
case "$1" in
  ls)
    want=()
    while [[ $# -gt 0 ]]; do [[ "$1" != --label ]] || want+=("$2"); shift; done
    jq --args --argjson bad "$([[ -f "$STATE/bad-row" ]] && echo true || echo false)" '{terminals:
        ((if $bad then [{address: null, state: "live"}] else [] end) + [.[] | select(.state == "live") | select(. as $t | $ARGS.positional
        | all(split("=") as [$k, $v] | $t.labels[$k] == $v)) | {address, state, cwd}])}' "${want[@]}" <"$st" ;;
  get)
    jq -e --arg a "$2" '.[] | select(.address == $a and (.gone | not))' "$st" && exit
    printf '{"error":{"kind":"not_found","message":"no terminal \\"%s\\""}}\n' "$2" >&2
    exit 3 ;;
  kill)
    [[ ! -f "$STATE/pending" ]] || { end "$(cat "$STATE/pending")"; rm "$STATE/pending"; }
    jq -e --arg a "$2" 'any(.[]; .address == $a and .state == "live" and .status.state == "working")' "$st" >/dev/null \
      && printf 'killed working %s\n' "$2" >>"$CALLS"
    end "[\"$2\"]"
    dies="$(jq -c --arg a "$2" '. as $all | def grow: . as $s | [$all[] | select(.state == "live" and .die_with_parent
        and (.parent | IN($s[])) and (.address | IN($s[]) | not)) | .address] as $n
      | if $n == [] then $s else $s + $n | grow end; [$a] | grow | .[1:]' "$st")"
    if [[ -f "$STATE/lag" ]]; then printf '%s' "$dies" >"$STATE/pending"; else end "$dies"; fi
    [[ ! -f "$STATE/on-kill-$2" ]] || save -f "$STATE/on-kill-$2"
    if [[ -f "$STATE/herdr-on-kill-$2" ]]; then
      jq -f "$STATE/herdr-on-kill-$2" "$STATE/herdr.json" >"$STATE/h.tmp" && mv "$STATE/h.tmp" "$STATE/herdr.json"
    fi ;;
  rm)
    save --arg a "$2" 'map(select(.address != $a))'
    [[ ! -f "$STATE/on-rm-$2" ]] || save -f "$STATE/on-rm-$2" ;;
esac
SH
  chmod +x "$FAKE_BIN/herdr-app" "$FAKE_BIN/hc"

  # widgets: a main checkout on master, pushed to a bare origin.
  WORK="$HOME/Work"
  git init -q --bare -b master "$BATS_TEST_TMPDIR/origin.git"
  git_init "$WORK/widgets"
  git -C "$WORK/widgets" branch -M master
  git -C "$WORK/widgets" remote add origin "$BATS_TEST_TMPDIR/origin.git"
  git -C "$WORK/widgets" push -q -u origin master
  git -C "$WORK/widgets" remote set-head origin master
  printf '.bercail/\n' >>"$WORK/widgets/.git/info/exclude"
  WORK="$(cd "$WORK" && pwd -P)"
  jq -n '{spaces: [], recent: [{name: "Old_Widgets", folder: "/gone"}]}' >"$STATE/herdr.json"
  echo '[]' >"$STATE/hc.json"
}

# A worktree widgets.$1 on branch $1, with one pushed commit, its .bercail/
# evidence, and a Herdr space sp-$1 holding its desk d-$1 and a builder b-$1.
desk_space() {
  local name="$1" wt="$WORK/widgets.$1"
  git -C "$WORK/widgets" worktree add -q -b "$name" "$wt"
  printf '%s\n' "$name" >"$wt/$name.txt"
  git -C "$wt" add "$name.txt"
  git -C "$wt" commit -qm "$name"
  git -C "$wt" push -q origin "$name"
  mkdir -p "$wt/.bercail/verify/run-1"
  printf 'all green\n' >"$wt/.bercail/verify/run-1/unit.txt"
  printf '# %s\n' "$name" >"$wt/.bercail/description.md"
  ln -s verify/run-1/unit.txt "$wt/.bercail/latest"
  jq --arg id "sp-$name" --arg f "$wt" --arg n "${name^}_Widgets" \
    '.spaces += [{id: $id, name: $n, folder: $f, machine: null, tabs: [{terminals: [{terminal: "s-\($id)"}]}]}]' \
    "$STATE/herdr.json" >"$STATE/h.tmp" && mv "$STATE/h.tmp" "$STATE/herdr.json"
  jq --arg s "sp-$name" --arg n "$name" --arg f "$wt" 'length as $i | . + [
      {address: "s-\($s)", state: "live", cwd: $f, pid: ($i + 101), created_ms: ($i + 101), labels: {"herdr.space": $s}},
      {address: "d-\($n)", state: "live", cwd: $f, pid: ($i + 102), created_ms: ($i + 102),
        labels: {"bercail.role": "agent", "bercail.space": $s}},
      {address: "b-\($n)", state: "live", cwd: $f, pid: ($i + 103), created_ms: ($i + 103),
        labels: {"bercail.role": "bstack-builder", "bercail.space": $s}}]' \
    "$STATE/hc.json" >"$STATE/c.tmp" && mv "$STATE/c.tmp" "$STATE/hc.json"
}

# set_term ADDRESS OBJECT: merges the jq object into that terminal in hc.json,
# or adds it live at the end, with a pid of its own.
set_term() {
  jq --arg a "$1" "($2) as \$t | "'if any(.[]; .address == $a) then map(if .address == $a then . * $t else . end)
      else . + [{address: $a, state: "live", pid: (length + 101), created_ms: (length + 101), labels: {}} + $t] end' \
    "$STATE/hc.json" >"$STATE/c.tmp" && mv "$STATE/c.tmp" "$STATE/hc.json"
}

# The worktree, its space and its terminals are all still there; nothing archived.
assert_kept() {
  local name="$1" why="$2"
  [[ -d "$WORK/widgets.$name/.bercail" ]] || fail "$why: the worktree and its .bercail/ stay"
  git -C "$WORK/widgets" worktree list | grep -q "widgets.$name " || fail "$why: the worktree stays registered"
  jq -e --arg id "sp-$name" 'any(.spaces[]; .id == $id)' "$STATE/herdr.json" >/dev/null || fail "$why: its space stays open"
  [[ "$(jq -r '[.[] | select(.state == "live")] | length' "$STATE/hc.json")" == "$(jq length "$STATE/hc.json")" ]] \
    || fail "$why: no terminal is ended"
  [[ ! -e "$ARCHIVE" ]] || fail "$why: nothing is archived"
  [[ ! -e "$XDG_STATE_HOME/bercail/retired.jsonl" ]] || fail "$why: nothing is recorded as retired"
  if grep -q 'space.close\|^hc kill' "$CALLS"; then fail "$why: nothing is closed or ended"; fi
}

@test "cleanup among many open spaces retires only the one named, desk before its builder, and reports open and recent" {
  local name out
  for name in alpha bravo charlie delta; do desk_space "$name"; done
  out="$("$BERCAIL" cleanup "$WORK/widgets.bravo" 2>&1)" || fail "cleanup: $out"
  [[ ! -e "$WORK/widgets.bravo" ]] || fail "the worktree is removed"
  git -C "$WORK/widgets" show-ref --verify --quiet refs/heads/bravo || fail "the branch stays"
  assert_eq "sp-alpha sp-charlie sp-delta" "$(jq -r '[.spaces[].id] | join(" ")' "$STATE/herdr.json")" \
    "only bravo's space closes"
  assert_eq "hc kill d-bravo"$'\n'"hc kill b-bravo" "$(grep '^hc kill' "$CALLS")" "the desk ends first, then its builder"
  assert_eq 9 "$(jq '[.[] | select(.state == "live" and .labels["herdr.space"] != "sp-bravo")] | length' "$STATE/hc.json")" \
    "the other spaces' terminals keep running"
  [[ -d "$WORK/widgets.alpha" && -d "$WORK/widgets.charlie" && -d "$WORK/widgets.delta" ]] || fail "the other worktrees stay"
  assert_has "$out" "branch bravo stays" "the report says the branch is kept"
  assert_has "$out" "Herdr sidebar: 3 open, 2 recent" \
    "the report gives what the sidebar shows, not only the space it closed"
}

@test "cleanup copies .bercail/ to the archive as it was, links included, before it removes anything" {
  local out dest
  desk_space alpha
  out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)" || fail "cleanup: $out"
  dest="$(find "$ARCHIVE" -mindepth 1 -maxdepth 1 -name '*-alpha')"
  [[ "$(basename "$dest")" =~ ^[0-9]{8}T[0-9]{6}Z-alpha$ ]] || fail "one archive dir, <UTC stamp>-<checkout>: '$dest'"
  assert_eq "all green" "$(<"$dest/.bercail/verify/run-1/unit.txt")" "the evidence is copied"
  assert_eq "# alpha" "$(<"$dest/.bercail/description.md")" "the description is copied"
  assert_eq "verify/run-1/unit.txt" "$(readlink "$dest/.bercail/latest")" "a link is copied as a link"
  assert_eq 700 "$(stat -c %a "$ARCHIVE")" "the archive is private"
  assert_has "$out" "archived .bercail/ to $dest/.bercail" "the report names the copy"
}

@test "cleanup records the checkout it retired, once it is gone, for dispatch to start the job a new desk" {
  local out wt
  desk_space alpha
  wt="$WORK/widgets.alpha"
  out="$("$BERCAIL" cleanup "$wt" 2>&1)" || fail "cleanup: $out"
  jq -se --arg p "$wt" --arg r "$WORK/widgets" 'length == 1 and (.[0] | .path == $p and .repo == $r and .branch == "alpha"
    and (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))' "$XDG_STATE_HOME/bercail/retired.jsonl" >/dev/null \
    || fail "one line names the retired checkout: $(cat "$XDG_STATE_HOME/bercail/retired.jsonl")"
  # It is retired even when the line cannot be written; the warning says what a dispatch will ask.
  [[ "$(id -u)" != 0 ]] || return 0
  desk_space bravo
  chmod 400 "$XDG_STATE_HOME/bercail/retired.jsonl"
  out="$("$BERCAIL" cleanup "$WORK/widgets.bravo" 2>&1)" || fail "cleanup: $out"
  [[ ! -e "$WORK/widgets.bravo" ]] || fail "the worktree is removed"
  assert_has "$out" "could not record $WORK/widgets.bravo in retired.jsonl; a dispatch of its job will ask you to run bercail cleanup --gone $WORK/widgets.bravo" "the warning"
}

@test "cleanup --gone records a checkout removed some other way, only one a handoff names and git no longer lists" {
  local out wt handoffs="$XDG_STATE_HOME/bercail/handoffs.jsonl"
  desk_space alpha
  wt="$WORK/widgets.alpha"
  if out="$("$BERCAIL" cleanup --gone "$wt" 2>&1)"; then fail "a checkout still there is recorded gone: $out"; fi
  assert_has "$out" "$wt is still there; bercail cleanup $wt retires it" "still there"
  rm -rf "$wt"
  if out="$("$BERCAIL" cleanup --gone "$wt" 2>&1)"; then fail "a checkout no handoff names is recorded: $out"; fi
  assert_has "$out" "no handoff names $wt" "no handoff"
  mkdir -p "$(dirname "$handoffs")"
  jq -nc --arg p "$wt" --arg r "$WORK/widgets" '{at:"2026-11-20T10:00:00Z",path:$p,branch:"alpha",issue:"w-1",desk:"d-alpha",repo:$r}' >"$handoffs"
  if out="$("$BERCAIL" cleanup --gone "$wt" 2>&1)"; then fail "a checkout git still lists is recorded: $out"; fi
  assert_has "$out" "git still lists $wt as a worktree; run git -C $WORK/widgets worktree prune" "still listed"
  [[ ! -e "$XDG_STATE_HOME/bercail/retired.jsonl" ]] || fail "a refusal records nothing"
  git -C "$WORK/widgets" worktree prune
  out="$("$BERCAIL" cleanup --gone "$wt" 2>&1)" || fail "cleanup --gone: $out"
  assert_has "$out" "recorded $wt as retired" "the report"
  jq -se --arg p "$wt" --arg r "$WORK/widgets" 'length == 1 and (.[0] | .path == $p and .repo == $r and .branch == "alpha" and .gone)' \
    "$XDG_STATE_HOME/bercail/retired.jsonl" >/dev/null || fail "$(cat "$XDG_STATE_HOME/bercail/retired.jsonl")"
  if grep -q 'space.close\|^hc kill' "$CALLS"; then fail "--gone ends and closes nothing"; fi
}

@test "cleanup removes nothing when the archive cannot be written" {
  local out
  desk_space alpha
  printf 'not a dir\n' >"$HOME/Work/worktree-archives"
  if out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then fail "cleanup without an archive succeeds: $out"; fi
  assert_has "$out" "nothing was removed" "the refusal says nothing went"
  assert_kept alpha "no archive"
}

@test "cleanup leaves no partial archive when a file will not copy" {
  local out
  [[ "$(id -u)" != 0 ]] || skip "root reads an unreadable file"
  desk_space alpha
  chmod 000 "$WORK/widgets.alpha/.bercail/description.md"
  if out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then fail "cleanup with a partial copy succeeds: $out"; fi
  chmod 600 "$WORK/widgets.alpha/.bercail/description.md"
  assert_has "$out" "nothing was removed" "the refusal says nothing went"
  [[ -z "$(ls -A "$ARCHIVE")" ]] || fail "the partial copy is removed: $(ls -A "$ARCHIVE")"
  rmdir "$ARCHIVE"
  assert_kept alpha "partial copy"
}

@test "cleanup refuses a tree with work nobody reviewed: staged, changed or new files" {
  local out
  desk_space alpha
  printf 'more\n' >>"$WORK/widgets.alpha/alpha.txt"
  if out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then fail "a changed tree is removed: $out"; fi
  assert_has "$out" "work nobody reviewed" "the refusal names the cause"
  assert_kept alpha "changed"
  git -C "$WORK/widgets.alpha" add alpha.txt
  if out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then fail "a staged tree is removed: $out"; fi
  assert_kept alpha "staged"
  git -C "$WORK/widgets.alpha" reset -q --hard
  mkdir "$WORK/widgets.alpha/notes"
  printf 'new\n' >"$WORK/widgets.alpha/notes/todo.md"
  if out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then fail "a tree with a new file is removed: $out"; fi
  assert_kept alpha "untracked"
  [[ -f "$WORK/widgets.alpha/notes/todo.md" ]] || fail "the new file stays"
}

@test "cleanup refuses commits on neither trunk nor the remote, and takes them once on either" {
  local out wt
  desk_space alpha
  wt="$WORK/widgets.alpha"
  printf 'x\n' >"$wt/local.txt"
  git -C "$wt" add local.txt
  git -C "$wt" commit -qm "local only"
  if out="$("$BERCAIL" cleanup "$wt" 2>&1)"; then fail "an unpushed commit is removed: $out"; fi
  assert_has "$out" "1 commits are on neither master nor the remote" "the refusal names the count and trunk"
  assert_kept alpha "unpushed"
  # Merged into local master, not pushed: trunk holds it.
  git -C "$WORK/widgets" merge -q --no-edit alpha
  out="$("$BERCAIL" cleanup "$wt" 2>&1)" || fail "a commit on trunk is refused: $out"
  [[ ! -e "$wt" ]] || fail "the worktree is removed"
}

@test "cleanup takes a commit whose patch landed on trunk under another id, and still refuses one whose patch did not" {
  local out wt
  desk_space alpha
  wt="$WORK/widgets.alpha"
  printf 'x\n' >"$wt/local.txt"
  git -C "$wt" add local.txt
  git -C "$wt" commit -qm "local only"
  # The same patch replayed on a moved trunk and pushed there: another id (bercail-ao5i).
  printf 'moved\n' >"$WORK/widgets/moved.txt"
  git -C "$WORK/widgets" add moved.txt
  git -C "$WORK/widgets" commit -qm moved
  git -C "$WORK/widgets" cherry-pick "$(git -C "$wt" rev-parse HEAD)" >/dev/null
  git -C "$WORK/widgets" push -q origin master
  git -C "$WORK/widgets" reset -q --hard HEAD~2
  git -C "$wt" cherry origin/master HEAD | grep -qx -- "- $(git -C "$wt" rev-parse HEAD)" || fail "the setup is not a landed patch"
  printf 'y\n' >"$wt/other.txt"
  git -C "$wt" add other.txt
  git -C "$wt" commit -qm "not landed"
  if out="$("$BERCAIL" cleanup "$wt" 2>&1)"; then fail "a commit whose patch is nowhere is removed: $out"; fi
  assert_has "$out" "1 commits are on neither master nor the remote" "only the unlanded commit counts"
  assert_kept alpha "one patch not landed"
  git -C "$wt" reset -q --hard HEAD~1
  out="$("$BERCAIL" cleanup "$wt" 2>&1)" || fail "a landed patch is refused: $out"
  assert_has "$out" "1 commits are on master as the same patch under another id (git cherry); they count as landed" \
    "the report says why it counts"
  [[ ! -e "$wt" ]] || fail "the worktree is removed"
}

@test "cleanup removes nothing when git cannot list the commits only the worktree holds" {
  local out wt real
  desk_space alpha
  wt="$WORK/widgets.alpha"
  printf 'x\n' >"$wt/local.txt"
  git -C "$wt" add local.txt
  git -C "$wt" commit -qm "local only"
  real="$(command -v git)"
  printf '#!/bin/sh\nfor a; do [ "$a" = rev-list ] && { echo "fatal: bad object" >&2; exit 128; }; done\nexec %q "$@"\n' "$real" \
    >"$FAKE_BIN/git"
  chmod +x "$FAKE_BIN/git"
  if out="$("$BERCAIL" cleanup "$wt" 2>&1)"; then fail "cleanup went on without the list: $out"; fi
  assert_has "$out" "git cannot list the commits only it holds; nothing was removed" "the refusal names the cause"
  assert_kept alpha "rev-list failed"
}

@test "cleanup refuses initialized submodules, which git worktree remove would refuse after the desk ended" {
  local out wt
  desk_space alpha
  wt="$WORK/widgets.alpha"
  git_init "$BATS_TEST_TMPDIR/lib"
  git -C "$wt" -c protocol.file.allow=always submodule add -q "$BATS_TEST_TMPDIR/lib" lib
  git -C "$wt" commit -qm lib
  git -C "$wt" push -q origin alpha
  if out="$("$BERCAIL" cleanup "$wt" 2>&1)"; then fail "a worktree with a submodule is removed: $out"; fi
  assert_has "$out" "initialized submodules" "the refusal names the cause"
  assert_kept alpha "submodule"
}

@test "cleanup closes this machine's space, not another machine's on the same path" {
  local out
  desk_space alpha
  jq --arg f "$WORK/widgets.alpha" '.spaces = [{id: "laptop/sp-9", name: "Alpha_Widgets", folder: $f, machine: "laptop", tabs: []}] + .spaces' \
    "$STATE/herdr.json" >"$STATE/h.tmp" && mv "$STATE/h.tmp" "$STATE/herdr.json"
  out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)" || fail "cleanup: $out"
  assert_eq "laptop/sp-9" "$(jq -r '[.spaces[].id] | join(" ")' "$STATE/herdr.json")" "only the local space closes"
}

@test "cleanup stops before removing when hc cannot list or end a terminal" {
  local out
  desk_space alpha
  if out="$(HC_BLANK="get b-alpha --json" "$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then
    fail "cleanup reads a blank answer as a terminal that ended: $out"
  fi
  assert_has "$out" "hc could not read terminal b-alpha; nothing was removed" "a blank read"
  assert_kept alpha "a blank read"
  # The window's Shell, as hc gets it, has no state.
  cp "$STATE/hc.json" "$STATE/hc.keep"
  jq 'map(if .address == "s-sp-alpha" then del(.state) else . end)' "$STATE/hc.keep" >"$STATE/hc.json"
  if out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then
    fail "cleanup reads a terminal with no state as one that ended: $out"
  fi
  assert_has "$out" "hc could not read terminal s-sp-alpha; nothing was removed" "no state"
  mv "$STATE/hc.keep" "$STATE/hc.json"
  assert_kept alpha "no state"
  touch "$STATE/down"
  if out="$(HC_FAIL="ls --json" "$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then fail "cleanup goes on with neither Herdr nor hc: $out"; fi
  assert_has "$out" "neither the Herdr app nor hc answered" "nothing answers"
  if out="$(HC_FAIL="get s-sp-alpha --json" "$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then
    fail "cleanup goes on without the space's Shell: $out"
  fi
  assert_has "$out" "nothing was removed" "a failed read"
  rm "$STATE/down"
  assert_kept alpha "a failed list"
  if out="$(HC_FAIL="kill d-alpha" "$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then fail "cleanup goes on past a live desk: $out"; fi
  assert_has "$out" "could not end terminal d-alpha" "a failed kill"
  [[ -d "$WORK/widgets.alpha" ]] || fail "the worktree stays while its desk is live"
  if grep -q '^hc kill b-alpha' "$CALLS"; then fail "the builder is not ended while its desk lives"; fi
  jq -e 'any(.spaces[]; .id == "sp-alpha")' "$STATE/herdr.json" >/dev/null || fail "the space stays open"
  touch "$STATE/down"
  rm -rf "$ARCHIVE"
  # A space whose only terminal is its kept Shell: hc lists it, then cannot read it.
  jq --arg f "$WORK/widgets.alpha" '[{address: "s-sp-alpha", state: "live", cwd: $f,
      labels: {"herdr.space": "sp-alpha", "bercail.space_name": "Alpha_Widgets"}}]' "$STATE/hc.json" >"$STATE/c.tmp" \
    && mv "$STATE/c.tmp" "$STATE/hc.json"
  if out="$(HC_FAIL="get s-sp-alpha --json" "$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then
    fail "cleanup takes an unread Shell for no space: $out"
  fi
  assert_has "$out" "could not tell which Herdr space is on $WORK/widgets.alpha: hc could not read terminal s-sp-alpha" "a failed hc get"
  [[ -d "$WORK/widgets.alpha" ]] || fail "the worktree stays when its Shell cannot be read"
  if out="$(HC_BLANK="get s-sp-alpha --json" "$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then
    fail "cleanup takes a blank read of its Shell for no space: $out"
  fi
  assert_has "$out" "could not tell which Herdr space" "a blank hc get"
  [[ -d "$WORK/widgets.alpha" ]] || fail "the worktree stays when its Shell reads blank"
}

@test "cleanup with no window refuses when two spaces sit on the worktree" {
  local out
  desk_space alpha
  touch "$STATE/down"
  jq --arg f "$WORK/widgets.alpha" '. + [{address: "s-other", state: "live", cwd: $f,
      labels: {"herdr.space": "sp-other", "bercail.space_name": "Other"}}]' "$STATE/hc.json" >"$STATE/c.tmp" \
    && mv "$STATE/c.tmp" "$STATE/hc.json"
  if out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then fail "cleanup picks one of two spaces: $out"; fi
  assert_has "$out" "two Herdr spaces sit on it" "the refusal names the cause"
  rm "$STATE/down"
  assert_kept alpha "two spaces"
}

@test "cleanup refuses evidence it cannot keep: a linked .bercail, an archive inside the worktree, unreadable submodules" {
  local out wt
  desk_space alpha
  wt="$WORK/widgets.alpha"
  mkdir -p "$WORK/widgets.alpha/.keep"
  printf '.keep/\n' >>"$WORK/widgets/.git/info/exclude"
  ln -s "$wt/.keep" "$HOME/Work/worktree-archives"
  if out="$("$BERCAIL" cleanup "$wt" 2>&1)"; then fail "an archive inside the worktree is removed with it: $out"; fi
  assert_has "$out" "is inside $wt" "archive inside"
  rm "$HOME/Work/worktree-archives"
  assert_kept alpha "archive inside"
  mv "$wt/.bercail" "$wt/.keep/evidence"
  ln -s .keep/evidence "$wt/.bercail"
  printf '/.bercail\n' >>"$WORK/widgets/.git/info/exclude"
  if out="$("$BERCAIL" cleanup "$wt" 2>&1)"; then fail "a linked .bercail is archived as a link: $out"; fi
  assert_has "$out" "is a link" "linked .bercail"
  rm "$wt/.bercail"
  mv "$wt/.keep/evidence" "$wt/.bercail"
  assert_kept alpha "linked .bercail"
  # A nested repo added as a gitlink, with no .gitmodules entry: git cannot read it.
  git_init "$wt/vendor"
  git -C "$wt" add vendor 2>/dev/null
  git -C "$wt" commit -qm vendor
  git -C "$wt" push -q origin alpha
  if out="$("$BERCAIL" cleanup "$wt" 2>&1)"; then fail "unreadable submodules are removed: $out"; fi
  assert_has "$out" "cannot read its submodules" "unreadable submodules"
  assert_kept alpha "unreadable submodules"
}

@test "cleanup refuses a detached commit nothing else holds" {
  local out wt
  desk_space alpha
  wt="$WORK/widgets.alpha"
  git -C "$wt" switch -q --detach
  git -C "$wt" commit -q --allow-empty -m "detached"
  if out="$("$BERCAIL" cleanup "$wt" 2>&1)"; then fail "a detached commit is removed: $out"; fi
  assert_has "$out" "1 commits are on neither" "the refusal names the commit"
  assert_kept alpha "detached"
}

@test "cleanup refuses the main checkout, a folder inside a worktree, a locked worktree, and its own space" {
  local out
  desk_space alpha
  if out="$("$BERCAIL" cleanup "$WORK/widgets" 2>&1)"; then fail "the main checkout is removed: $out"; fi
  assert_has "$out" "main checkout" "main"
  mkdir "$WORK/widgets.alpha/sub"
  if out="$("$BERCAIL" cleanup "$WORK/widgets.alpha/sub" 2>&1)"; then fail "a subfolder removes its worktree: $out"; fi
  assert_has "$out" "name the worktree itself" "subfolder"
  git -C "$WORK/widgets" worktree lock "$WORK/widgets.alpha"
  if out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then fail "a locked worktree is removed: $out"; fi
  assert_has "$out" "it is locked" "locked"
  git -C "$WORK/widgets" worktree unlock "$WORK/widgets.alpha"
  if out="$(HC_TERMINAL_ID=d-alpha "$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then fail "a desk removes its own space: $out"; fi
  assert_has "$out" "from its own space" "own space"
  if out="$(HC_TERMINAL_ID=s-sp-alpha "$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then fail "its Shell removes its space: $out"; fi
  assert_has "$out" "from its own space" "its window Shell"
  touch "$STATE/down"
  if out="$(HC_TERMINAL_ID=s-sp-alpha "$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then fail "its kept Shell removes its space: $out"; fi
  assert_has "$out" "from its own space" "its kept Shell"
  rm "$STATE/down"
  assert_kept alpha "refused"
}

@test "cleanup with no window closes the space's kept Shell through hc" {
  local out
  desk_space alpha
  desk_space bravo
  touch "$STATE/down"
  out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)" || fail "cleanup: $out"
  [[ ! -e "$WORK/widgets.alpha" ]] || fail "the worktree is removed"
  assert_eq "d-alpha b-alpha s-sp-alpha" "$(grep '^hc kill' "$CALLS" | cut -d' ' -f3 | tr '\n' ' ' | sed 's/ $//')" \
    "the desk, its builder, then the space's Shell end"
  assert_eq "s-sp-bravo d-bravo b-bravo" "$(jq -r '[.[].address] | join(" ")' "$STATE/hc.json")" "bravo's terminals stay"
  assert_has "$out" "closed Herdr space sp-alpha" "the report says the space closed"
}

# check_agrees WT WHY: cleanup --check refuses WT with cleanup's own reason, and
# neither changes anything.
check_agrees() {
  local wt="$1" why="$2" check out
  : >"$CALLS"
  if check="$("$BERCAIL" cleanup --check "$wt" 2>&1)"; then fail "$why: --check passes what cleanup refuses: $check"; fi
  if grep -q 'space.close\|^hc kill\|^hc rm' "$CALLS"; then fail "$why: --check ends or closes nothing"; fi
  [[ ! -e "$ARCHIVE" ]] || fail "$why: --check archives nothing"
  if out="$("$BERCAIL" cleanup "$wt" 2>&1)"; then fail "$why: cleanup takes it: $out"; fi
  assert_eq "$(grep '^error:' <<<"$out")" "$(grep '^error:' <<<"$check")" "$why: --check gives cleanup's reason"
}

@test "cleanup --check refuses each worktree cleanup refuses, with the same reason, and changes nothing" {
  local wt
  desk_space alpha
  wt="$WORK/widgets.alpha"
  check_agrees "$WORK/widgets" "the main checkout"
  printf 'more\n' >>"$wt/alpha.txt"
  check_agrees "$wt" "a changed file"
  git -C "$wt" add alpha.txt
  check_agrees "$wt" "a staged file"
  git -C "$wt" reset -q --hard
  printf 'x\n' >"$wt/local.txt"
  git -C "$wt" add local.txt
  git -C "$wt" commit -qm "local only"
  check_agrees "$wt" "an unpushed commit"
  git -C "$wt" push -q origin alpha
  git -C "$WORK/widgets" worktree lock "$wt"
  check_agrees "$wt" "a locked worktree"
  git -C "$WORK/widgets" worktree unlock "$wt"
  HC_TERMINAL_ID=d-alpha check_agrees "$wt" "its own space"
  printf 'not a dir\n' >"$HOME/Work/worktree-archives"
  check_agrees "$wt" "an archive it cannot write"
  rm "$HOME/Work/worktree-archives"
  mkdir -p "$wt/.keep"
  printf '.keep/\n' >>"$WORK/widgets/.git/info/exclude"
  ln -s "$wt/.keep" "$HOME/Work/worktree-archives"
  check_agrees "$wt" "an archive inside the worktree"
  rm "$HOME/Work/worktree-archives"
  HC_BLANK="get b-alpha --json" check_agrees "$wt" "a blank read of its builder"
  assert_kept alpha "every refusal"
}

@test "cleanup --check passes a worktree cleanup takes, says what it would do, and changes nothing" {
  local out index before
  desk_space alpha
  : >"$CALLS"
  out="$("$BERCAIL" cleanup --check "$WORK/widgets.alpha" 2>&1)" || fail "--check refuses a landed worktree: $out"
  assert_has "$out" "cleanup would retire $WORK/widgets.alpha" "it names the worktree"
  assert_has "$out" "end d-alpha b-alpha" "it names the terminals it would end"
  assert_has "$out" "close Herdr space sp-alpha" "it names the space it would close"
  assert_kept alpha "--check"
  if grep -q 'space.close\|^hc kill\|^hc rm' "$CALLS"; then fail "--check ends or closes nothing"; fi
  # A file touched since the index was written: git status would refresh the index.
  touch -d '+1 hour' "$WORK/widgets.alpha/alpha.txt"
  index="$(git -C "$WORK/widgets.alpha" rev-parse --path-format=absolute --git-path index)"
  before="$(stat -c '%Y %s' "$index") $(sha256sum <"$index")"
  "$BERCAIL" cleanup --check "$WORK/widgets.alpha" >/dev/null 2>&1 || fail "--check refuses a touched file"
  assert_eq "$before" "$(stat -c '%Y %s' "$index") $(sha256sum <"$index")" "--check leaves the index as it was"
  out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)" || fail "cleanup refuses what --check passed: $out"
  [[ ! -e "$WORK/widgets.alpha" ]] || fail "cleanup takes it"
}

@test "cleanup refuses to end a terminal that is working or blocked, and --check says so" {
  local out state
  desk_space alpha
  for state in working blocked; do
    jq --arg s "$state" 'map(if .address == "b-alpha" then .status = {app: "pi", state: $s} else . end)' "$STATE/hc.json" \
      >"$STATE/c.tmp" && mv "$STATE/c.tmp" "$STATE/hc.json"
    check_agrees "$WORK/widgets.alpha" "a $state builder"
    assert_has "$(grep '^error:' <<<"$("$BERCAIL" cleanup --check "$WORK/widgets.alpha" 2>&1)")" "terminal b-alpha is $state" \
      "the refusal names the terminal"
  done
  # The window's own terminal in the space closes with it.
  jq 'map(if .address == "b-alpha" then .status = {app: "pi", state: "idle"}
      elif .address == "s-sp-alpha" then .status = {app: "pi", state: "working"} else . end)' "$STATE/hc.json" \
    >"$STATE/c.tmp" && mv "$STATE/c.tmp" "$STATE/hc.json"
  check_agrees "$WORK/widgets.alpha" "a working terminal in the window's tab"
  assert_kept alpha "a builder at work"
  jq 'map(if .address == "s-sp-alpha" then .status = null else . end)' "$STATE/hc.json" >"$STATE/c.tmp" \
    && mv "$STATE/c.tmp" "$STATE/hc.json"
  out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)" || fail "an idle builder holds it back: $out"
}

@test "cleanup ends each parent before what it started, so no child's end wakes a terminal it still has to end" {
  local name out
  for name in alpha bravo; do
    : >"$CALLS"
    desk_space "$name"
    # The builder outlives the desk; its judge dies with it, and hc lists the
    # judge first. bravo's judge ends a moment after its builder.
    set_term "b-$name" '{parent: "d-'"$name"'", notify: true, status: {app: "pi", state: "idle"}}'
    set_term "j-$name" '{parent: "b-'"$name"'", die_with_parent: true, notify: true, status: {app: "pi", state: "idle"},
      labels: {"bercail.role": "bstack-judge", "bercail.space": "sp-'"$name"'"}}'
    jq --arg b "b-$name" 'sort_by(.address == $b)' "$STATE/hc.json" >"$STATE/c.tmp" && mv "$STATE/c.tmp" "$STATE/hc.json"
    [[ "$name" == alpha ]] || touch "$STATE/lag"
    out="$("$BERCAIL" cleanup --check "$WORK/widgets.$name" 2>&1)" || fail "--check: $out"
    assert_has "$out" "end d-$name b-$name j-$name" "$name: parents come before what they started"
    out="$("$BERCAIL" cleanup "$WORK/widgets.$name" 2>&1)" || fail "$name: cleanup: $out"
    if grep -q '^killed working' "$CALLS"; then fail "$name: a child's end woke its parent, and cleanup ended it at work"; fi
    [[ ! -e "$WORK/widgets.$name" ]] || fail "$name: the worktree is removed"
  done
  assert_eq "hc kill d-bravo"$'\n'"hc kill b-bravo"$'\n'"hc kill j-bravo" "$(grep '^hc kill' "$CALLS")" \
    "a judge still live once its builder ended is ended in turn"
}

@test "cleanup ends nothing the judge's builder took with it, and says it ended already" {
  local name out
  # bravo's judge is still listed once its builder ends, but hc no longer knows it.
  for name in alpha bravo; do
    : >"$CALLS"
    desk_space "$name"
    set_term "b-$name" '{parent: "d-'"$name"'", notify: true}'
    set_term "j-$name" '{parent: "b-'"$name"'", die_with_parent: true, notify: true, labels: {"bercail.space": "sp-'"$name"'"}}'
    [[ "$name" == alpha ]] || printf 'map(if .address == "j-bravo" then .state = "live" | .gone = true else . end)\n' >"$STATE/on-kill-b-bravo"
    out="$("$BERCAIL" cleanup "$WORK/widgets.$name" 2>&1)" || fail "$name: cleanup: $out"
    assert_eq "hc kill d-$name"$'\n'"hc kill b-$name" "$(grep '^hc kill' "$CALLS")" "$name: the judge ended with its builder"
    assert_has "$out" "terminal j-$name had ended already" "$name: the report says so"
  done
}

@test "cleanup reads a terminal hc forgot once it ended as gone, and prints nothing of hc's not_found" {
  # Cleanup ends and removes each terminal, then looks again: hc no longer knows it.
  local out
  desk_space alpha
  out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)" || fail "cleanup: $out"
  [[ ! -e "$WORK/widgets.alpha" ]] || fail "the worktree is removed"
  if grep -qF not_found <<<"$out"; then fail "hc's raw error is not in the output:"$'\n'"$out"; fi
}

@test "cleanup checks and ends what a sibling started, labelled or not, and refuses one at work" {
  local out
  desk_space alpha
  set_term u-alpha '{parent: "b-alpha", die_with_parent: true, status: {app: "pi", state: "working"}}'
  check_agrees "$WORK/widgets.alpha" "a working terminal the builder started"
  assert_has "$("$BERCAIL" cleanup --check "$WORK/widgets.alpha" 2>&1)" "terminal u-alpha is working" "the refusal names it"
  assert_kept alpha "a working terminal the builder started"
  set_term u-alpha '{status: {app: "pi", state: "idle"}}'
  assert_has "$("$BERCAIL" cleanup --check "$WORK/widgets.alpha" 2>&1)" "end d-alpha b-alpha u-alpha" "--check names it"
  out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)" || fail "cleanup: $out"
  [[ ! -e "$WORK/widgets.alpha" ]] || fail "the worktree is removed"
  jq -e 'any(.[]; .address == "u-alpha" and .state == "live") | not' "$STATE/hc.json" >/dev/null \
    || fail "the terminal the builder started is ended"
}

@test "cleanup stops, keeps the worktree and its space, and gives the reasons, when a terminal changed since it checked" {
  local name out
  local -A said=()
  # alpha: ending its builder wakes the agent in the window's tab, which closing the space would end.
  desk_space alpha
  set_term s-sp-alpha '{status: {app: "pi", state: "idle"}}'
  set_term b-alpha '{parent: "s-sp-alpha", notify: true}'
  # bravo: once the desk ends, hc has brought its builder back in place, and it is at work.
  desk_space bravo
  set_term b-bravo '{pid: 2, created_ms: 100}'
  printf 'map(if .address == "b-bravo" then .created_ms = 200 | .status.state = "working" else . end)\n' >"$STATE/on-kill-d-bravo"
  # charlie: once the desk ends, its builder is at work and a new terminal joins the space.
  desk_space charlie
  printf '%s\n' '. + [{address: "n-charlie", state: "live", pid: 60, labels: {"bercail.space": "sp-charlie"}, status: {state: "idle"}}]' \
    '| map(if .address == "b-charlie" then .status = {state: "working"} else . end)' >"$STATE/on-kill-d-charlie"
  # delta: the desk started an unlabelled terminal that outlives it, just before it ended.
  desk_space delta
  printf '%s\n' '. + [{address: "late", state: "live", pid: 70, parent: "d-delta", labels: {}, status: {state: "working"}}]' \
    >"$STATE/on-kill-d-delta"
  # echo: once the desk ends, its builder belongs to another space.
  desk_space echo
  printf 'map(if .address == "b-echo" then .labels["bercail.space"] = "sp-elsewhere" else . end)\n' >"$STATE/on-kill-d-echo"
  # foxtrot: once the desk ends, the space is on another folder, and its Shell left the window's tab.
  desk_space foxtrot
  printf '.spaces |= map(if .id == "sp-foxtrot" then .folder = "/elsewhere" | .tabs = [] else . end)\n' >"$STATE/herdr-on-kill-d-foxtrot"
  # golf: once the desk ends, its builder no longer reports a status.
  desk_space golf
  set_term b-golf '{status: {app: "pi", state: "idle"}}'
  printf 'map(if .address == "b-golf" then .status = null else . end)\n' >"$STATE/on-kill-d-golf"
  for name in alpha bravo charlie delta echo foxtrot golf; do
    : >"$CALLS"
    if out="$("$BERCAIL" cleanup "$WORK/widgets.$name" 2>&1)"; then fail "$name: cleanup goes on: $out"; fi
    [[ -d "$WORK/widgets.$name/.bercail" ]] || fail "$name: the worktree stays"
    jq -e --arg id "sp-$name" 'any(.spaces[]; .id == $id)' "$STATE/herdr.json" >/dev/null || fail "$name: its space stays open"
    if grep -q 'space.close\|^killed working' "$CALLS"; then fail "$name: nothing at work is ended or closed"; fi
    [[ ! -e "$XDG_STATE_HOME/bercail/retired.jsonl" ]] || fail "$name: nothing is recorded as retired"
    assert_has "$out" "the worktree and its space stay, and .bercail/ is archived in $ARCHIVE/" "$name: what stays"
    if [[ "$name" != alpha ]] && grep -q "^hc kill [bn]-$name" "$CALLS"; then fail "$name: what changed is not ended"; fi
    said[$name]="$out"
  done
  assert_has "${said[alpha]}" "cleanup stopped: terminal s-sp-alpha is working now; it ended d-alpha b-alpha;" "a woken parent"
  assert_has "${said[bravo]}" "terminal b-bravo is not the process cleanup checked (pid 2 from 100, now pid 2 from 200); terminal b-bravo is working now; it ended d-bravo;" \
    "a replaced builder, and every reason it fails"
  assert_has "${said[charlie]}" "terminal b-charlie is working now; terminal n-charlie joined the space after cleanup checked it; it ended d-charlie;" \
    "every reason, not the first"
  assert_has "${said[delta]}" "terminal late joined the space after cleanup checked it, and is working; it ended d-delta;" \
    "a child of a desk that ended"
  assert_has "${said[echo]}" "terminal b-echo has another parent or space now (parent none, space sp-elsewhere); it ended d-echo;" \
    "a builder bound elsewhere"
  assert_has "${said[foxtrot]}" "cleanup stopped: the Herdr space on the worktree is none now, not sp-foxtrot; terminal s-sp-foxtrot is no longer where cleanup found it in space sp-foxtrot; it ended d-foxtrot;" \
    "a space moved off the worktree"
  assert_has "${said[golf]}" "terminal b-golf no longer reports its status; it ended d-golf;" "an agent gone silent"
}

@test "cleanup refuses a terminal labelled for two spaces, a hidden grandchild at work, two desks, and a status it cannot read" {
  local out rc
  desk_space alpha
  desk_space bravo
  # With no window, bravo's builder carries alpha's Shell label too.
  touch "$STATE/down"
  set_term b-bravo '{labels: {"herdr.space": "sp-alpha"}}'
  check_agrees "$WORK/widgets.alpha" "a terminal labelled for two spaces"
  assert_has "$("$BERCAIL" cleanup --check "$WORK/widgets.alpha" 2>&1)" \
    "terminal b-bravo is labelled for another space (bercail.space sp-bravo, herdr.space sp-alpha)" "the refusal names both labels"
  set_term b-bravo '{labels: {"herdr.space": null}}'
  rm "$STATE/down"
  # The window lists bravo's desk in alpha's tab.
  jq '.spaces |= map(if .id == "sp-alpha" then .tabs[0].terminals += [{terminal: "d-bravo"}] else . end)' "$STATE/herdr.json" \
    >"$STATE/h.tmp" && mv "$STATE/h.tmp" "$STATE/herdr.json"
  check_agrees "$WORK/widgets.alpha" "another space's desk in the window's tab"
  jq '.spaces |= map(if .id == "sp-alpha" then .tabs[0].terminals |= map(select(.terminal != "d-bravo")) else . end)' "$STATE/herdr.json" \
    >"$STATE/h.tmp" && mv "$STATE/h.tmp" "$STATE/herdr.json"
  # The builder's helper finished; the terminal it started is at work.
  set_term i-alpha '{parent: "b-alpha", state: "finished"}'
  set_term u-alpha '{parent: "i-alpha", status: {app: "pi", state: "working"}}'
  check_agrees "$WORK/widgets.alpha" "a grandchild under a finished helper"
  assert_has "$("$BERCAIL" cleanup --check "$WORK/widgets.alpha" 2>&1)" "terminal u-alpha is working" "the refusal names it"
  set_term u-alpha '{state: "finished"}'
  # The desk finished; the unlabelled terminal it started is at work.
  set_term d-alpha '{state: "finished"}'
  set_term v-alpha '{parent: "d-alpha", status: {app: "pi", state: "working"}}'
  check_agrees "$WORK/widgets.alpha" "a child of a finished desk"
  assert_has "$("$BERCAIL" cleanup --check "$WORK/widgets.alpha" 2>&1)" "terminal v-alpha is working" "the refusal names it"
  set_term v-alpha '{state: "finished"}'
  set_term d-alpha '{state: "live"}'
  set_term d2-alpha '{labels: {"bercail.role": "agent", "bercail.space": "sp-alpha"}}'
  check_agrees "$WORK/widgets.alpha" "two desks"
  assert_has "$("$BERCAIL" cleanup --check "$WORK/widgets.alpha" 2>&1)" "two desks claim space sp-alpha: d-alpha, d2-alpha" "both named"
  set_term d2-alpha '{state: "finished"}'
  set_term b-alpha '{status: {app: "pi"}}'
  check_agrees "$WORK/widgets.alpha" "a builder with no state"
  assert_has "$("$BERCAIL" cleanup --check "$WORK/widgets.alpha" 2>&1)" "terminal b-alpha is unknown" "the refusal names it"
  set_term b-alpha '{status: null}'
  touch "$STATE/bad-row"
  rc=0
  out="$("$BERCAIL" cleanup --check "$WORK/widgets.alpha" 2>&1)" || rc=$?
  assert_eq 2 "$rc" "a list with a row it cannot read is not a refusal"
  assert_has "$out" "hc listed a terminal without its address or state" "it says so"
  touch "$STATE/down"
  rc=0
  "$BERCAIL" cleanup --check "$WORK/widgets.alpha" >/dev/null 2>&1 || rc=$?
  assert_eq 2 "$rc" "with no window, a row it cannot read does not mean no space"
  rm "$STATE/bad-row" "$STATE/down"
  "$BERCAIL" cleanup --check "$WORK/widgets.alpha" >/dev/null 2>&1 || fail "alpha passes once each is settled"
}

@test "cleanup with no window stops before removing when a terminal at work joins the space as it ends the desk" {
  local out
  desk_space alpha
  touch "$STATE/down"
  printf '. + [{address: "w-alpha", state: "live", pid: 80, labels: {"bercail.space": "sp-alpha"}, status: {state: "working"}}]\n' \
    >"$STATE/on-rm-d-alpha"
  if out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then fail "cleanup removes it with a worker in its space: $out"; fi
  assert_has "$out" "terminal w-alpha joined the space after cleanup checked it, and is working; it ended d-alpha;" "the reason"
  [[ -d "$WORK/widgets.alpha/.bercail" ]] || fail "the worktree stays"
}

@test "cleanup removes no record between a look and the kill it guards" {
  local out
  desk_space alpha
  set_term b-alpha '{status: {app: "pi", state: "idle"}}'
  set_term j-alpha '{parent: "d-alpha", die_with_parent: true}'
  printf 'map(if .address == "b-alpha" then .status.state = "working" else . end)\n' >"$STATE/on-rm-j-alpha"
  out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)" || fail "cleanup: $out"
  if grep -q '^killed working' "$CALLS"; then fail "a record removed after the look let a working builder be ended"; fi
  assert_has "$out" "terminal j-alpha had ended already" "the desk's helper ended with it"
}

@test "cleanup leaves a terminal another space owns, and refuses when it would end with one of its own" {
  local out
  desk_space alpha
  desk_space bravo
  desk_space charlie
  # alpha's builder started bravo's desk, which outlives it; bravo's builder
  # started charlie's desk, which dies with it.
  set_term d-bravo '{parent: "b-alpha"}'
  set_term d-charlie '{parent: "b-bravo", die_with_parent: true}'
  assert_has "$("$BERCAIL" cleanup --check "$WORK/widgets.alpha" 2>&1)" "end d-alpha b-alpha, remove" "--check leaves bravo's desk"
  out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)" || fail "cleanup: $out"
  assert_eq "hc kill d-alpha"$'\n'"hc kill b-alpha" "$(grep '^hc kill' "$CALLS")" "bravo's desk is not ended"
  : >"$CALLS"
  if out="$("$BERCAIL" cleanup "$WORK/widgets.bravo" 2>&1)"; then fail "cleanup ends charlie's desk with bravo's builder: $out"; fi
  assert_has "$out" "refusing to clean up $WORK/widgets.bravo: terminal d-charlie of space sp-charlie would end with b-bravo; nothing was removed" \
    "the refusal names it"
  [[ -d "$WORK/widgets.bravo/.bercail" ]] || fail "bravo's worktree stays"
  if grep -q '^hc kill' "$CALLS"; then fail "nothing is ended"; fi
}

@test "cleanup keeps the space open, and says the worktree is gone, when the window's terminal is at work by the close" {
  local out
  desk_space alpha
  set_term s-sp-alpha '{status: {app: "pi", state: "idle"}}'
  # The second status call is the focus read once the worktree is gone.
  printf 'map(if .address == "s-sp-alpha" then .status.state = "working" else . end)\n' >"$STATE/on-status-2"
  if out="$("$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then fail "cleanup closes a space at work: $out"; fi
  assert_has "$out" "removed worktree $WORK/widgets.alpha, but left Herdr space sp-alpha open: terminal s-sp-alpha is working now" \
    "the report says what is gone and what stays"
  [[ ! -e "$WORK/widgets.alpha" ]] || fail "the worktree is gone"
  jq -e 'any(.spaces[]; .id == "sp-alpha")' "$STATE/herdr.json" >/dev/null || fail "the space stays open"
  if grep -q 'space.close' "$CALLS"; then fail "the space is not closed"; fi
}

@test "cleanup --check exits 1 on a refusal, and 2 when hc does not answer" {
  local rc=0
  desk_space alpha
  printf 'more\n' >>"$WORK/widgets.alpha/alpha.txt"
  "$BERCAIL" cleanup --check "$WORK/widgets.alpha" 2>/dev/null || rc=$?
  assert_eq 1 "$rc" "a changed file is a refusal"
  git -C "$WORK/widgets.alpha" checkout -q alpha.txt
  rc=0
  HC_BLANK="get b-alpha --json" "$BERCAIL" cleanup --check "$WORK/widgets.alpha" 2>/dev/null || rc=$?
  assert_eq 2 "$rc" "a blank read of its builder is not a refusal"
  rc=0
  : >"$STATE/blank-ls"
  "$BERCAIL" cleanup --check "$WORK/widgets.alpha" 2>/dev/null || rc=$?
  assert_eq 2 "$rc" "a window that lists nothing is not one with no spaces"
  rm "$STATE/blank-ls"
  jq --arg f "$WORK/widgets.alpha" '.spaces += [{id: "sp-two", name: "Two", folder: $f, machine: null, tabs: []}]' \
    "$STATE/herdr.json" >"$STATE/h.tmp" && mv "$STATE/h.tmp" "$STATE/herdr.json"
  rc=0
  "$BERCAIL" cleanup --check "$WORK/widgets.alpha" 2>/dev/null || rc=$?
  assert_eq 1 "$rc" "two spaces on the worktree is a refusal"
}

@test "cleanup --check takes one worktree, like cleanup" {
  local out
  if out="$("$BERCAIL" cleanup --check 2>&1)"; then fail "--check with no worktree passes: $out"; fi
  assert_has "$out" "usage: bercail cleanup [--check] <worktree>" "the usage names --check"
}
