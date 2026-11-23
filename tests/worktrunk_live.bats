#!/usr/bin/env bats
# bats file_tags=live
# What handoff-spawn and the shipped hooks ask of worktrunk, against the real wt
# on this machine. Run it when the deps tracker opens a worktrunk issue.

setup() {
  load test_helper
  local wt
  # A mise shim reads HOME, which isolate moves: find the binary first.
  wt="$(mise which wt 2>/dev/null || command -v wt || true)"
  [[ -n "$wt" ]] || skip "wt not found; live proof not run"
  isolate
  ln -s "$wt" "$BATS_TEST_TMPDIR/bin/wt"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  mkdir -p "$XDG_CONFIG_HOME/worktrunk"
  cp "$ROOT/config/worktrunk/config.toml" "$ROOT/config/worktrunk/herdr-layout.sh" "$XDG_CONFIG_HOME/worktrunk/"
  # shellcheck source=/dev/null
  source "$ROOT/skills/handoff/scripts/handoff-spawn"
  # shellcheck source=/dev/null
  source "$ROOT/config/worktrunk/herdr-layout.sh"
  REPO="$BATS_TEST_TMPDIR/app"
  git_init "$REPO"
  printf 'node_modules/\n.beads/embeddeddolt/\n.bercail/*\n!.bercail/policy.toml\n' >"$REPO/.gitignore"
  # As bd and bercail lay them out: tracked files beside the ignored state.
  mkdir -p "$REPO/.beads" "$REPO/.bercail"
  echo config >"$REPO/.beads/config.yaml"
  echo policy >"$REPO/.bercail/policy.toml"
  git -C "$REPO" add .gitignore .beads/config.yaml .bercail/policy.toml
  git -C "$REPO" commit -qm ignores
  mkdir -p "$REPO/node_modules/a" "$REPO/.beads/embeddeddolt" "$REPO/.bercail"
  echo dep >"$REPO/node_modules/a/f"
  echo store >"$REPO/.beads/embeddeddolt/db"
  echo report >"$REPO/.bercail/report.md"
}

@test "live: switch --create --no-hooks makes a worktree that git lists, and runs no hook" {
  local sib
  (cd "$REPO" && wt switch --create feat/x --no-cd --no-hooks </dev/null >/dev/null 2>&1) || fail "wt switch failed"
  sib="$(handoff_worktree_of "$REPO" feat/x)" || fail "git does not list feat/x: $(git -C "$REPO" worktree list)"
  [[ ! -e "$sib/node_modules" ]] || fail "the shipped pre-start copy ran under --no-hooks"
}

@test "live: --base <sha> makes only the named branch, and an existing branch switches without --create" {
  local sha
  sha="$(git -C "$REPO" rev-parse HEAD)"
  (cd "$REPO" && wt switch --create z --base "$sha" --no-cd --no-hooks </dev/null >/dev/null 2>&1) || fail "wt switch --base failed"
  [[ "$(git -C "$REPO" for-each-ref --format='%(refname:short)' refs/heads | sort | tr '\n' ' ')" == "master z " ]] \
    || fail "branches: $(git -C "$REPO" branch)"
  git -C "$REPO" branch pr
  (cd "$REPO" && wt switch pr --no-cd --no-hooks </dev/null >/dev/null 2>&1) || fail "wt switch to an existing branch failed"
  handoff_worktree_of "$REPO" pr >/dev/null || fail "no worktree for pr"
}

@test "live: the shipped config's copy leaves out the beads store and .bercail" {
  local sib
  (cd "$REPO" && wt switch --create feat --no-cd --no-hooks </dev/null >/dev/null 2>&1) || fail "wt switch failed"
  sib="$(handoff_worktree_of "$REPO" feat)"
  wt -C "$sib" step copy-ignored </dev/null >/dev/null 2>&1 || fail "copy-ignored failed"
  [[ -f "$sib/node_modules/a/f" ]] || fail "node_modules was not copied"
  [[ ! -e "$sib/.beads/embeddeddolt" && ! -e "$sib/.bercail/report.md" ]] || fail "state was copied: $(ls -A "$sib/.beads" "$sib/.bercail" 2>&1)"
}

@test "live: an unapproved project pre-start hook is listed, refused without a tty, and runs once approved" {
  local sib out
  mkdir -p "$REPO/.config"
  printf '[pre-start]\nmark = "touch PROJECT_RAN"\n' >"$REPO/.config/wt.toml"
  git -C "$REPO" add .config/wt.toml
  git -C "$REPO" commit -qm hooks
  out="$(wt -C "$REPO" config approvals list --format=json </dev/null 2>/dev/null)" || fail "no approvals JSON"
  jq -e '[.commands[] | select(.phase == "pre-start" and .approved == false)] | length == 1' <<<"$out" >/dev/null \
    || fail "approvals: $out"
  (cd "$REPO" && wt switch --create feat --no-cd --no-hooks </dev/null >/dev/null 2>&1) || fail "wt switch failed"
  sib="$(handoff_worktree_of "$REPO" feat)"
  if wt -C "$sib" hook pre-start --foreground project: </dev/null >/dev/null 2>&1; then
    fail "an unapproved hook must not run without a tty"
  fi
  [[ ! -e "$sib/PROJECT_RAN" ]] || fail "it ran"
  wt -C "$REPO" config approvals add --yes </dev/null >/dev/null 2>&1 || fail "approvals add failed"
  wt -C "$sib" hook pre-start --foreground project: </dev/null >/dev/null 2>&1 || fail "the approved hook failed"
  [[ -f "$sib/PROJECT_RAN" ]] || fail "the project's hook did not run"
  [[ ! -e "$sib/node_modules" ]] || fail "project: ran the user's copy hook too"
}

@test "live: the hooks' space name template is the name _wt_generate_session_name gives, in three layouts" {
  local b sib want got
  local nested="$BATS_TEST_TMPDIR/lesentiel/lesentiel" custom="$BATS_TEST_TMPDIR/custom"
  git_init "$nested"
  git_init "$custom"
  for b in feat/x v0.18-fix Mixed_Case; do
    (cd "$REPO" && wt switch --create "$b" --no-cd --no-hooks </dev/null >/dev/null 2>&1) || fail "wt switch $b failed"
    (cd "$nested" && wt --config-set 'worktree-path="{{ repo_path }}/../{{ branch | sanitize }}"' \
      switch --create "$b" --no-cd --no-hooks </dev/null >/dev/null 2>&1) || fail "nested wt switch $b failed"
    (cd "$custom" && wt --config-set 'worktree-path="{{ repo_path }}.custom-{{ branch | sanitize }}"' \
      switch --create "$b" --no-cd --no-hooks </dev/null >/dev/null 2>&1) || fail "custom wt switch $b failed"
    for sib in "$(handoff_worktree_of "$REPO" "$b")" "$(handoff_worktree_of "$nested" "$b")" "$(handoff_worktree_of "$custom" "$b")"; do
      want="$(wt -C "$sib" step eval '{{ branch | sanitize | capitalize }}_{{ repo | capitalize }}' 2>/dev/null)"
      got="$(_wt_generate_session_name "$sib")"
      [[ -n "$want" && "$got" == "$want" ]] || fail "$sib: worktrunk names it $want, bercail $got"
    done
  done
}

@test "live: list JSON reads through the shell helpers" {
  local sib got
  (cd "$REPO" && wt switch --create feat --no-cd --no-hooks </dev/null >/dev/null 2>&1) || fail "wt switch failed"
  sib="$(handoff_worktree_of "$REPO" feat)"
  # shellcheck source=/dev/null
  source "$ROOT/config/shell/bercail.inc.sh"
  got="$(cd "$REPO" && _wt_worktree_path_for_branch feat)" || fail "the helpers could not read wt list"
  [[ "$(cd "$got" && pwd -P)" == "$sib" ]] || fail "wt list says $got, git says $sib"
}

# The project hook of these setup cases: what it was given, on a line.
_project_hook() {
  mkdir -p "$REPO/.config"
  printf '[pre-start]\nvars = "echo base={{ base }} args=[{{ args }}] > HOOK_VARS"\n' >"$REPO/.config/wt.toml"
  git -C "$REPO" add .config/wt.toml
  git -C "$REPO" commit -qm hooks
}

@test "live: spawn setup refuses an unapproved project hook and keeps no worktree or branch" {
  local sib out
  _project_hook
  (cd "$REPO" && wt switch --create feat --no-cd --no-hooks </dev/null >/dev/null 2>&1) || fail "wt switch failed"
  sib="$(handoff_worktree_of "$REPO" feat)"
  out="$(handoff_setup_worktree "$REPO" "$sib" feat 1 master 2>&1)" && fail "an unapproved hook must stop the setup: $out"
  [[ "$out" == *"nothing was kept"* ]] || fail "$out"
  [[ ! -d "$sib" ]] && ! git -C "$REPO" show-ref --verify --quiet refs/heads/feat || fail "left: $(git -C "$REPO" worktree list; git -C "$REPO" branch)"
}

@test "live: spawn setup keeps the main checkout's state out under the new checkout's own ignore rules" {
  local sib
  git -C "$REPO" checkout -q -b bare-ignores
  printf 'node_modules/\n' >"$REPO/.gitignore"
  git -C "$REPO" commit -qam 'ignore less'
  git -C "$REPO" checkout -q master
  (cd "$REPO" && wt switch --create feat --base bare-ignores --no-cd --no-hooks </dev/null >/dev/null 2>&1) || fail "wt switch failed"
  sib="$(handoff_worktree_of "$REPO" feat)"
  rm -f "$XDG_CONFIG_HOME/worktrunk/config.toml"
  handoff_setup_worktree "$REPO" "$sib" feat 1 bare-ignores >/dev/null 2>&1 || fail "setup failed"
  [[ -f "$sib/node_modules/a/f" ]] || fail "node_modules was not copied"
  [[ ! -e "$sib/.bercail/report.md" && ! -e "$sib/.beads/embeddeddolt" ]] || fail "state was copied: $(git -C "$sib" status --short)"
  [[ -f "$sib/.beads/config.yaml" && -f "$sib/.bercail/policy.toml" ]] || fail "a tracked file went with it"
}

@test "live: spawn setup gives the project hook what wt switch --create gives it" {
  local native replay
  _project_hook
  git -C "$REPO" branch side
  wt -C "$REPO" config approvals add --yes </dev/null >/dev/null 2>&1 || fail "approvals add failed"
  (cd "$REPO" && wt switch --create native --base side --no-cd </dev/null >/dev/null 2>&1) || fail "native wt switch failed"
  native="$(cat "$(handoff_worktree_of "$REPO" native)/HOOK_VARS")"
  (cd "$REPO" && wt switch --create replay --base side --no-cd --no-hooks </dev/null >/dev/null 2>&1) || fail "wt switch failed"
  handoff_setup_worktree "$REPO" "$(handoff_worktree_of "$REPO" replay)" replay 1 side >/dev/null 2>&1 || fail "setup failed"
  replay="$(cat "$(handoff_worktree_of "$REPO" replay)/HOOK_VARS")"
  [[ -n "$native" && "$replay" == "$native" ]] || fail "wt switch gave [$native], the spawn [$replay]"
}

@test "live: spawn setup takes back only what the copy brought, odd file names too" {
  local sib odd=$'\xff.log'
  mkdir -p "$REPO/.bercail/logs" "$REPO/.bercail/cache/deep"
  echo main >"$REPO/.bercail/logs/same.log"
  echo main >"$REPO/.bercail/logs/$odd"
  echo main >"$REPO/.bercail/cache/deep/x"
  ln -s "$REPO/node_modules" "$REPO/.bercail/dirlink"
  (cd "$REPO" && wt switch --create feat --no-cd --no-hooks </dev/null >/dev/null 2>&1) || fail "wt switch failed"
  sib="$(handoff_worktree_of "$REPO" feat)"
  # A folder of the checkout's own, as a git post-checkout hook makes one.
  mkdir -p "$sib/.bercail/logs" "$sib/.bercail/local-queue"
  echo mine >"$sib/.bercail/logs/same.log"
  echo mine >"$sib/.bercail/logs/only.log"
  rm -f "$XDG_CONFIG_HOME/worktrunk/config.toml"
  handoff_setup_worktree "$REPO" "$sib" feat 1 master >/dev/null 2>&1 || fail "setup failed"
  [[ "$(cat "$sib/.bercail/logs/same.log")" == mine && -f "$sib/.bercail/logs/only.log" ]] \
    || fail "the checkout's own files must stay: $(ls -A "$sib/.bercail/logs")"
  [[ -d "$sib/.bercail/local-queue" ]] || fail "the checkout's own empty folder must stay"
  [[ ! -e "$sib/.bercail/logs/$odd" && ! -e "$sib/.bercail/report.md" && ! -e "$sib/.bercail/cache" && ! -e "$sib/.beads/embeddeddolt" \
    && ! -L "$sib/.bercail/dirlink" ]] \
    || fail "copied bytes stayed: $(ls -A "$sib/.bercail" "$sib/.bercail/logs" "$sib/.beads")"
}

@test "live: the kept-config migration appends only what wt can still read" {
  local cfg="$XDG_CONFIG_HOME/worktrunk/config.toml" before
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/config.sh"
  # shellcheck disable=SC2034 # read by migrate_worktrunk_names_and_copy
  WORKTRUNK_CONFIG_DIR="$XDG_CONFIG_HOME/worktrunk" DRY_RUN=0
  printf 'step = {}\n\n[pre-start]\ncopy-ignored = "wt step copy-ignored"\n\n[post-start]\nherdr = """\nsource "$HOME/.config/worktrunk/herdr-layout.sh"\n"""\n' >"$cfg"
  before="$(cat "$cfg")"
  migrate_worktrunk_names_and_copy >/dev/null 2>&1
  [[ "$(cat "$cfg")" == "$before" ]] || fail "a table wt cannot read was appended: $(cat "$cfg")"
  printf '[pre-start]\ncopy-ignored = "wt step copy-ignored"\n\n[post-start]\nherdr = """\nsource "$HOME/.config/worktrunk/herdr-layout.sh"\n"""\n' >"$cfg"
  migrate_worktrunk_names_and_copy >/dev/null 2>&1
  grep -Fxq 'exclude = [".beads/*", ".bercail/*"]' "$cfg" || fail "a stock kept config gets the exclude: $(cat "$cfg")"
  _worktrunk_config_parses "$cfg" || fail "wt cannot read the result"
}
