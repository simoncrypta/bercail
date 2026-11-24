#!/usr/bin/env bats
# The deps routine (lib/routine/deps.sh): the deps tracker's open GitHub issues
# as findings, from stand-ins for gh, bd and hc, and a bercail checkout Shep
# knows. Each @test is its own HOME.

assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1' got '$2'"; }

setup() {
  load test_helper
  isolate
  need git jq flock sha256sum
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" TZ=UTC HC_BIN="$BATS_TEST_TMPDIR/bin/hc"
  export GH_ISSUES="$BATS_TEST_TMPDIR/gh.json" GH_LOG="$BATS_TEST_TMPDIR/gh.argv" BEADS="$BATS_TEST_TMPDIR/beads.json"
  unset GH_FAIL STUB_BD_FAIL
  mkdir -p "$XDG_CONFIG_HOME/bercail" "$XDG_STATE_HOME/bercail/shep/inbox"
  printf '[routine.deps]\nrun = "deps"\nat = "08:00"\n' >"$XDG_CONFIG_HOME/bercail/config.toml"
  # No desks: Shep's repos come from its extras file alone.
  printf '#!/bin/sh\necho "{\\"terminals\\": []}"\n' >"$HC_BIN"
  # gh logs each call, and prints $GH_ISSUES for issue list; $GH_FAIL fails it.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
[[ -z "${GH_FAIL:-}" && "$1 $2" == "issue list" ]] || exit 1
cat "$GH_ISSUES"
SH
  # bd list prints $BEADS from the checkout it runs in; $STUB_BD_FAIL fails it.
  cat >"$BATS_TEST_TMPDIR/bin/bd" <<'SH'
#!/usr/bin/env bash
[[ -z "${STUB_BD_FAIL:-}" && "$1" == list && -d .beads ]] || exit 1
cat "$BEADS"
SH
  chmod +x "$HC_BIN" "$BATS_TEST_TMPDIR/bin/gh" "$BATS_TEST_TMPDIR/bin/bd"

  # The checkouts Shep knows: a fork and one on another host listed first, then bercail.
  git_init "$HOME/Work/afork"
  git -C "$HOME/Work/afork" remote add origin git@github.com:someone/bercail.git
  git_init "$HOME/Work/another"
  git -C "$HOME/Work/another" remote add origin https://notgithub.com/simoncrypta/bercail.git
  git_init "$HOME/Work/bercail"
  git -C "$HOME/Work/bercail" remote add origin https://github.com/simoncrypta/bercail.git
  mkdir -p "$HOME/Work/afork/.beads" "$HOME/Work/bercail/.beads"
  CHECKOUT="$(cd "$HOME/Work/bercail" && pwd -P)"
  printf '%s\n' "$HOME/Work/afork" "$HOME/Work/another" "$HOME/Work/bercail" >"$XDG_STATE_HOME/bercail/shep/repos"
  echo '[]' >"$BEADS"
}

# issues "NUMBER|LABEL|TITLE"...: the open deps issues gh lists.
issues() {
  local spec
  for spec in "$@"; do
    IFS="|" read -r n label title <<<"$spec"
    jq -nc --argjson n "$n" --arg l "$label" --arg t "$title" '{number: $n, title: $t,
      url: "https://github.com/simoncrypta/bercail/issues/\($n)", labels: [{name: "deps"}, {name: $l}]}'
  done | jq -s . >"$GH_ISSUES"
}

# What the query prints, run as the runner runs it: from HOME, nothing on stdin.
query() { (cd "$HOME" && bash "$ROOT/lib/routine/deps.sh" deps </dev/null); }

@test "the deps routine finds each open deps issue, with its URL, version and bercail checkout" {
  issues "71|deps:tuicr|deps: tuicr 0.30.0" "73|deps:tracker|deps: tracker failing" \
    "74|deps:pi-skills|vendor: pi-skills 0123456789abcdef0123456789abcdef01234567"
  local out
  out="$(query)" || fail "query: $out"
  assert_eq "deps:pi-skills deps:tracker deps:tuicr" "$(jq -r .key <<<"$out" | sort | xargs)" "one finding per deps:<name> label"
  assert_eq '{"key":"deps:tuicr","title":"deps: tuicr 0.30.0","detail":"https://github.com/simoncrypta/bercail/issues/71; version 0.30.0; no beads issue links it","repo":"'"$CHECKOUT"'"}' \
    "$(jq -c 'select(.key == "deps:tuicr")' <<<"$out")" "a tool's finding"
  assert_eq "https://github.com/simoncrypta/bercail/issues/74; version 0123456789abcdef0123456789abcdef01234567; no beads issue links it" \
    "$(jq -r 'select(.key == "deps:pi-skills") | .detail' <<<"$out")" "a vendored copy's version is its commit"
  assert_eq "https://github.com/simoncrypta/bercail/issues/73; no beads issue links it" \
    "$(jq -r 'select(.key == "deps:tracker") | .detail' <<<"$out")" "the tracker's failing issue has no version"
  read -ra argv <"$GH_LOG"
  assert_eq "issue list" "${argv[*]:0:2}" "gh is only asked to list"
  local want
  for want in "--repo simoncrypta/bercail" "--label deps" "--state open"; do
    [[ " ${argv[*]} " == *" $want "* ]] || fail "it lists bercail's open deps issues, $want: ${argv[*]}"
  done
}

@test "the deps routine names the beads issues that link a deps issue, an open one first" {
  issues "71|deps:tuicr|deps: tuicr 0.30.0" "72|deps:wrangler|deps: wrangler 4.167.0" \
    "73|deps:worktrunk|deps: worktrunk 0.83.0" "74|deps:herdr-app|deps: herdr-app 0.1.17"
  jq -n '[{id: "b-1", title: "Bring tuicr up", status: "closed", description: "https://github.com/simoncrypta/bercail/issues/71"},
    {id: "b-2", title: "tuicr https://github.com/simoncrypta/bercail/issues/71", status: "in_progress"},
    {id: "b-3", title: "wrangler 4.167.0 and #72", status: "open", description: "https://github.com/simoncrypta/bercail/issues/720"},
    {id: "b-4", title: "Take wrangler", status: "closed", external_ref: "gh-720"},
    {id: "b-5", title: "Take worktrunk", status: "closed", external_ref: "gh-73"},
    {id: "b-6", title: "Take herdr", status: "open", external_ref: "https://github.com/simoncrypta/bercail/issues/74"}]' >"$BEADS"
  local out
  out="$(query)" || fail "query: $out"
  assert_eq "b-2|https://github.com/simoncrypta/bercail/issues/71; version 0.30.0; linked by b-2 (open), b-1 (closed)" \
    "$(jq -r 'select(.key == "deps:tuicr") | "\(.issue)|\(.detail)"' <<<"$out")" "both name it, the open one first"
  assert_eq "null|https://github.com/simoncrypta/bercail/issues/72; version 4.167.0; no beads issue links it" \
    "$(jq -r 'select(.key == "deps:wrangler") | "\(.issue)|\(.detail)"' <<<"$out")" "#72 and another issue's URL or ref do not link it"
  assert_eq "b-5 b-6" "$(jq -r 'select(.key | IN("deps:worktrunk", "deps:herdr-app")) | .issue' <<<"$out" | sort | xargs)" \
    "an external ref of gh-<number> or the URL links it"
}

@test "the deps routine keeps the newest issue of a label that two issues have" {
  issues "60|deps:tuicr|deps: tuicr 0.29.0" "71|deps:tuicr|deps: tuicr 0.30.0"
  local out
  out="$(query)" || fail "query: $out"
  assert_eq "deps: tuicr 0.30.0" "$(jq -r .title <<<"$out")" "one finding, the newest issue's"
}

@test "the deps routine fails without a bercail checkout, or when gh or bd fails" {
  issues "71|deps:tuicr|deps: tuicr 0.30.0"
  STUB_BD_FAIL=1 run query
  assert_eq 1 "$status" "a bd that fails fails the run"
  [[ "$output" == "error: bd did not list the issues in $CHECKOUT" ]] || fail "it names bd: $output"
  GH_FAIL=1 run query
  assert_eq 1 "$status" "a gh that fails fails the run"
  [[ "$output" == "error: gh did not list the open deps issues of simoncrypta/bercail"* ]] || fail "it names gh: $output"
  rmdir "$CHECKOUT/.beads"
  run query
  [[ "$status" == 1 && "$output" == "error: $CHECKOUT has no beads"* ]] || fail "a checkout with no beads fails it: $output"
  printf '%s\n' "$HOME/Work/afork" "$HOME/Work/another" >"$XDG_STATE_HOME/bercail/shep/repos"
  run query
  [[ "$status" == 1 && "$output" == "error: no bercail checkout among Shep's repos"* ]] || fail "a fork or another host is not bercail: $output"
  git_init "$HOME/Work/bercail-2"
  git -C "$HOME/Work/bercail-2" remote add origin git@github.com:simoncrypta/bercail.git
  printf '%s\n' "$HOME/Work/bercail" "$HOME/Work/bercail-2" >"$XDG_STATE_HOME/bercail/shep/repos"
  run query
  [[ "$status" == 1 && "$output" == "error: Shep knows 2 bercail checkouts ($CHECKOUT $(cd "$HOME/Work/bercail-2" && pwd -P));"* ]] \
    || fail "two checkouts are one too many: $output"
}

@test "a deps run sends a deps issue once, again when its version moves on, and nothing after a failed run" {
  issues "71|deps:tuicr|deps: tuicr 0.30.0"
  local out
  out="$("$ROOT/bin/bercail" routine run deps)" || fail "run: $out"
  [[ "$out" == *"emitted, 1 found (1 new, 0 changed)"* ]] || fail "the first run sends it: $out"
  if out="$(GH_FAIL=1 "$ROOT/bin/bercail" routine run deps)"; then fail "a run whose gh failed is quiet: $out"; fi
  [[ "$out" == *"failed: exit 1: error: gh did not list"* ]] || fail "the run names gh: $out"
  out="$("$ROOT/bin/bercail" routine run deps)" || fail "run: $out"
  [[ "$out" == *"skipped (quiet), 1 found, nothing new or changed"* ]] || fail "the issue is not sent again: $out"
  issues "71|deps:tuicr|deps: tuicr 0.31.0"
  out="$("$ROOT/bin/bercail" routine run deps)" || fail "run: $out"
  [[ "$out" == *"emitted, 1 found (0 new, 1 changed)"* ]] || fail "a new version is sent: $out"
  assert_eq 2 "$(find "$XDG_STATE_HOME/bercail/shep/inbox" -name 'routine_deps_*.json' | wc -l)" "two events reach Shep's inbox"
  ! grep -v '^issue list ' "$GH_LOG" || fail "gh only lists"
}
