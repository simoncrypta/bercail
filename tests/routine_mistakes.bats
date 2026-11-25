#!/usr/bin/env bats
# The mistakes routine (lib/routine/mistakes.sh): which groups it finds from a
# stand-in mistakes ledger, run as bercail routine run runs it. Stand-ins for
# hc, bd and entire; real git and the real runner. Each @test is its own HOME.

assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1' got '$2'"; }

setup() {
  load test_helper
  isolate
  need git jq flock sha256sum node
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" TZ=UTC
  export HC_BIN="$BATS_TEST_TMPDIR/bin/hc" ENTIRE_DATA="$BATS_TEST_TMPDIR/entire"
  unset HC_TERMINAL_ID
  STATE="$XDG_STATE_HOME/bercail/shep" COUNTS="$XDG_STATE_HOME/bercail/routines/mistakes/counts.json"
  mkdir -p "$STATE/inbox" "$XDG_CONFIG_HOME/bercail" "$ENTIRE_DATA"
  printf '[routine.mistakes]\nrun = "mistakes"\nat = "Mon 08:00"\n' >"$XDG_CONFIG_HOME/bercail/config.toml"
  printf '#!/usr/bin/env bash\nprintf %s\n' "'{\"terminals\":[]}'" >"$HC_BIN"
  # bd lists every issue of the repo it runs in from .beads/fake/list.json; a
  # .beads/fake/list.hook runs first, and one that fails is bd's status.
  cat >"$BATS_TEST_TMPDIR/bin/bd" <<'SH'
#!/usr/bin/env bash
dir="$(git rev-parse --show-toplevel)/.beads/fake"
[[ "$1" == list ]] || exit 2
[[ ! -f "$dir/list.hook" ]] || bash "$dir/list.hook" || exit
cat "$dir/list.json"
SH
  # entire knows one repo, r-kvm, and the trails in $ENTIRE_DATA/<n>.json.
  cat >"$BATS_TEST_TMPDIR/bin/entire" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo '{"id":"r-kvm"}' ;;
  "trail show") cat "$ENTIRE_DATA/$3.json" 2>/dev/null || exit 1 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$HC_BIN" "$BATS_TEST_TMPDIR/bin/bd" "$BATS_TEST_TMPDIR/bin/entire"

  # app: a repo with beads, known to Shep. kvm: an Entire repo, with trails.
  git_init "$HOME/Work/app"
  git_init "$HOME/Work/kvm"
  git -C "$HOME/Work/kvm" remote add origin entire://aws-us-east-2.entire.io/et/lab/kvm
  APP="$(cd "$HOME/Work/app" && pwd -P)" KVM="$(cd "$HOME/Work/kvm" && pwd -P)"
  mkdir -p "$APP/.beads/fake"
  printf '.beads/\n' >>"$APP/.git/info/exclude"
  echo '[]' >"$APP/.beads/fake/list.json"
  printf '%s\n' "$APP" >"$STATE/repos"
}

# group ID: a group of the ledger, counted against a tool, with its one key k-ID.
group() {
  local file="$STATE/mistake-groups.json"
  [[ -f "$file" ]] || echo '{"groups":{},"keys":{}}' >"$file"
  jq --arg g "$1" '.groups[$g] = {name: "Group \($g)", against: "tool"} | .keys["k-\($g)"] = $g' "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
}

# seen ID AT [ISSUE] [REPO]: group ID's key happened at AT, naming ISSUE in REPO.
seen() {
  jq -nc --arg k "k-$1" --arg at "$2" --arg i "${3:-}" --arg r "${4:-}" \
    '{at: $at, key: $k, what: "seen \($at)"} + (if $r == "" then {} else {repo: $r} end) + (if $i == "" then {} else {issue: $i} end)' \
    >>"$STATE/mistakes.jsonl"
}

# issue ID STATUS [LABEL] [CLOSED_AT]: an issue of app.
issue() {
  local file="$APP/.beads/fake/list.json"
  jq --arg id "$1" --arg s "$2" --arg l "${3:-}" --arg c "${4:-}" \
    'map(select(.id != $id)) + [{id: $id, title: "Issue \($id)", status: $s,
       labels: (if $l == "" then [] else [$l] end), closed_at: (if $c == "" then null else $c end)}]' "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
}

# trail N STATUS PHASE: a trail of kvm.
trail() {
  jq -n --argjson n "$1" --arg s "$2" --arg p "$3" '{number: $n, title: "Trail \($n)", status: $s, phase: $p, repoIds: ["r-kvm"]}' \
    >"$ENTIRE_DATA/$1.json"
}

routine() { "$ROOT/bin/bercail" routine "$@"; }
# What the query prints, run as the runner runs it: from HOME, nothing on stdin.
query() { (cd "$HOME" && bash "$ROOT/lib/routine/mistakes.sh" mistakes </dev/null); }

@test "the mistakes routine finds a group grown with no issue and one whose fix closed, not one unchanged or with an open issue" {
  local out id
  # G1: twice, its entry's issue closed. G2: its fix closed, then seen again.
  # G3: its fix is open. G4: its entry names an open issue, without a repo.
  # G5: its entry names an open trail. G6: once. G7: its entry names a trail
  # without a repo, which may be open.
  for g in G1 G2 G3 G4 G5 G6 G7; do group "$g"; done
  issue a-1 closed
  issue a-2 closed mistake:G2 2026-11-10T12:00:00Z
  issue a-3 open mistake:G3
  issue a-4 open
  trail 7 open building
  seen G1 2026-11-01T00:00:00Z a-1 "$APP"
  seen G1 2026-11-02T00:00:00Z
  seen G2 2026-11-01T00:00:00Z
  seen G2 2026-11-02T00:00:00Z
  seen G2 2026-11-12T00:00:00Z
  seen G3 2026-11-01T00:00:00Z
  seen G3 2026-11-02T00:00:00Z
  seen G4 2026-11-01T00:00:00Z a-4
  seen G4 2026-11-02T00:00:00Z
  seen G5 2026-11-01T00:00:00Z trail:7 "$KVM"
  seen G5 2026-11-02T00:00:00Z
  seen G6 2026-11-01T00:00:00Z
  seen G7 2026-11-01T00:00:00Z trail:7
  seen G7 2026-11-02T00:00:00Z
  out="$(routine run mistakes)" || fail "run: $out"
  [[ "$out" == "mistakes: emitted, 2 found (2 new, 0 changed); run "* ]] || fail "the first run: $out"
  id="$(jq -r .id "$XDG_STATE_HOME/bercail/routines/mistakes/runs.jsonl")"
  assert_eq "$APP a-2 k-G2 3 times" "$(jq -r 'select(.key == "mistake:G2") | "\(.repo) \(.issue) \(.detail)"' \
    "$XDG_STATE_HOME/bercail/routines/mistakes/outputs/$id.jsonl")" "the fix's finding names it"
  out="$(routine show mistakes --run "$id")"
  [[ "$out" == *"new      mistake:G1  G1 Group G1 has happened 2 times, counts against a tool, and has no open issue"* ]] \
    || fail "G1, grown with no issue: $out"
  [[ "$out" == *"new      mistake:G2  G2 Group G2 has happened 3 times, counts against a tool: 1 time since its fix a-2 closed on 2026-11-10"* ]] \
    || fail "G2, whose fix did not hold: $out"
  # Unchanged: nothing new, though G4's and G5's issues have closed since.
  issue a-4 closed
  trail 7 closed closed
  out="$(routine run mistakes)" || fail "run: $out"
  [[ "$out" == "mistakes: skipped (quiet), 0 found, nothing new or changed; run "* ]] || fail "an unchanged ledger is quiet: $out"
  # G1 and G4 grow: both are found, G4 now that its issue is closed.
  seen G1 2026-11-20T00:00:00Z
  seen G4 2026-11-20T00:00:00Z
  out="$(query)" || fail "query: $out"
  assert_eq "mistake:G1 mistake:G4" "$(jq -r .key <<<"$out" | sort | xargs)" "the groups that grew"
}

@test "the mistakes routine finds a group again when the runner could not keep the run that found it, and a dry run keeps nothing" {
  local out
  group G1
  seen G1 2026-11-01T00:00:00Z
  seen G1 2026-11-02T00:00:00Z
  out="$(routine run mistakes --dry-run)" || fail "dry run: $out"
  [[ "$out" == "mistakes: emitted, 1 found (1 new, 0 changed); dry run, nothing written"* ]] || fail "a dry run: $out"
  [[ ! -e "$COUNTS" ]] || fail "a dry run writes no counts.json: $(cat "$COUNTS")"
  out="$(routine run mistakes)" || fail "run: $out"
  [[ "$out" == "mistakes: emitted, 1 found (1 new, 0 changed); run "* ]] || fail "the first run: $out"
  # G1 grows, and the query finds it under the same key, but the runner keeps
  # nothing of that run, as when its state write fails.
  seen G1 2026-11-03T00:00:00Z
  out="$(query)" || fail "query: $out"
  assert_eq "mistake:G1" "$(jq -r .key <<<"$out")" "the query found it"
  out="$(routine run mistakes)" || fail "run: $out"
  [[ "$out" == "mistakes: emitted, 1 found (0 new, 1 changed); run "* ]] || fail "the next run finds it again: $out"
  out="$(routine run mistakes)" || fail "run: $out"
  [[ "$out" == "mistakes: skipped (quiet), 0 found, nothing new or changed; run "* ]] || fail "once kept, it is not found again: $out"
}

@test "the mistakes routine fails when bd or a trail lookup fails, so the next good run sends nothing again" {
  local out
  group G1
  seen G1 2026-11-01T00:00:00Z trail:7 "$KVM"
  seen G1 2026-11-02T00:00:00Z
  trail 7 closed closed
  out="$(routine run mistakes)" || fail "run: $out"
  [[ "$out" == *"emitted, 1 found (1 new, 0 changed)"* ]] || fail "the first run: $out"
  seen G1 2026-11-03T00:00:00Z
  printf 'exit 1\n' >"$APP/.beads/fake/list.hook"
  if out="$(routine run mistakes)"; then fail "a run whose bd failed is quiet: $out"; fi
  [[ "$out" == *"failed: exit 1: error: bd could not list the issues of $APP (status 1)"* ]] || fail "the run names bd: $out"
  rm "$APP/.beads/fake/list.hook"
  # Entire could not show the trail, here for want of a login: it may be open.
  trail 7 open building
  printf '#!/bin/sh\necho "not logged in" >&2\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/entire"
  if out="$(routine run mistakes)"; then fail "a run whose trail lookup failed is quiet: $out"; fi
  [[ "$out" == *"error: could not read trail:7 in $KVM (status 1)"* ]] || fail "the run names the lookup: $out"
  # The runner keeps 300 characters of it; the query says why in full.
  if out="$(query 2>&1)"; then fail "the query passed: $out"; fi
  [[ "$out" == *"not logged in"* ]] || fail "the query says why: $out"
  trail 7 closed closed
  printf '#!/usr/bin/env bash\n[[ "$1 $2" == "repo view" ]] && echo %s || cat "$ENTIRE_DATA/$3.json"\n' "'{\"id\":\"r-kvm\"}'" \
    >"$BATS_TEST_TMPDIR/bin/entire"
  out="$(routine run mistakes)" || fail "run: $out"
  [[ "$out" == *"emitted, 1 found (0 new, 1 changed)"* ]] || fail "the growth the failed runs saw is sent once: $out"
  out="$(routine run mistakes)" || fail "run: $out"
  [[ "$out" == *"skipped (quiet), 0 found, nothing new or changed"* ]] || fail "and not again: $out"
}
