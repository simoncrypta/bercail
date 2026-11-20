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
  cat >"$FAKE_BIN/herdr-app" <<'SH'
#!/usr/bin/env bash
printf 'herdr-app %s\n' "$*" >>"$CALLS"
[[ ! -f "$STATE/down" ]] || exit 1
st="$STATE/herdr.json"
case "$1 ${2:-}" in
  "status ") echo '{"space":"sp-main"}' ;;
  "ls ") cat "$st" ;;
  "do space.close")
    jq --arg id "$4" '(.spaces[] | select(.id == $id) | {name, folder}) as $s
      | .recent = [$s] + .recent | .spaces |= map(select(.id != $id))' "$st" >"$st.tmp" && mv "$st.tmp" "$st" ;;
  *) echo '{"ok":true}' ;;
esac
SH
  # hc: terminals in $STATE/hc.json, each {address, state, cwd, labels}. ls,
  # like the real one, prints no labels; get does. $HC_FAIL: the call that fails;
  # $HC_BLANK: the call that succeeds and prints nothing.
  cat >"$FAKE_BIN/hc" <<'SH'
#!/usr/bin/env bash
printf 'hc %s\n' "$*" >>"$CALLS"
[[ "$*" != "${HC_FAIL:-}" ]] || exit 1
[[ "$*" != "${HC_BLANK:-}" ]] || exit 0
st="$STATE/hc.json"
case "$1" in
  ls)
    want=()
    while [[ $# -gt 0 ]]; do [[ "$1" != --label ]] || want+=("$2"); shift; done
    jq --args '{terminals: [.[] | select(. as $t | $ARGS.positional
        | all(split("=") as [$k, $v] | $t.labels[$k] == $v)) | {address, state, cwd, labels: null}]}' \
      "${want[@]}" <"$st" ;;
  get) jq -e --arg a "$2" '.[] | select(.address == $a)' "$st" ;;
  kill) jq --arg a "$2" 'map(if .address == $a then .state = "done" else . end)' "$st" >"$st.tmp" && mv "$st.tmp" "$st" ;;
  rm) jq --arg a "$2" 'map(select(.address != $a))' "$st" >"$st.tmp" && mv "$st.tmp" "$st" ;;
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
  jq --arg s "sp-$name" --arg n "$name" --arg f "$wt" '. + [
      {address: "s-\($s)", state: "live", cwd: $f, labels: {"herdr.space": $s}},
      {address: "d-\($n)", state: "live", cwd: $f, labels: {"bercail.role": "agent", "bercail.space": $s}},
      {address: "b-\($n)", state: "live", cwd: $f, labels: {"bercail.role": "bstack-builder", "bercail.space": $s}}]' \
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
  if out="$(HC_BLANK="ls --json --label bercail.space=sp-alpha" "$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then
    fail "cleanup reads a blank answer as no siblings: $out"
  fi
  assert_has "$out" "nothing was removed" "a blank list"
  assert_kept alpha "a blank list"
  touch "$STATE/down"
  if out="$(HC_FAIL="ls --json" "$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then fail "cleanup goes on with neither Herdr nor hc: $out"; fi
  assert_has "$out" "neither the Herdr app nor hc answered" "nothing answers"
  if out="$(HC_FAIL="ls --json --label herdr.space=sp-alpha" "$BERCAIL" cleanup "$WORK/widgets.alpha" 2>&1)"; then
    fail "cleanup goes on without the space's Shell: $out"
  fi
  assert_has "$out" "nothing was removed" "a failed list"
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
  assert_has "$out" "could not tell which Herdr space" "a failed hc get"
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
  assert_has "$out" "two spaces match" "the refusal names the cause"
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
