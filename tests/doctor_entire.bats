#!/usr/bin/env bats
# bercail doctor's Entire check, in a temp repo with a fake entire and gh on
# PATH: capture (CLI, git hooks, the Pi extension, Pi trust), the settings
# bercail recommends, and whether checkpoints go somewhere public.

setup() {
  load test_helper
  isolate
  need git jq
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/deps.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/doctor.sh"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global user.name test
  git config --global user.email test@example.com
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  # entire: a version, and a login unless ENTIRE_LOGGED_OUT is set.
  cat >"$BIN/entire" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "version "*) echo "Entire CLI ${ENTIRE_FAKE_VERSION:-0.13.4}" ;;
  "auth status") [ -z "$ENTIRE_LOGGED_OUT" ] ;;
  *) exit 2 ;;
esac
EOF
  # gh: the visibility GH_VISIBILITY names, for the repo it logs.
  cat >"$BIN/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/gh.log"
[ -n "\$GH_VISIBILITY" ] && printf '%s\n' "\$GH_VISIBILITY"
EOF
  chmod +x "$BIN/entire" "$BIN/gh"
  export PATH="$BIN:/usr/bin:/bin"
  REPO="$BATS_TEST_TMPDIR/work/repo"
  git_init "$REPO"
  cd "$REPO" || return 1
  mkdir -p "$HOME/.pi/agent"
  printf '{"%s": true}\n' "$BATS_TEST_TMPDIR/work" >"$HOME/.pi/agent/trust.json"
}

# An enabled repo as bercail recommends it: the five hooks, the extension
# committed, and settings with a private checkpoint repo.
enabled() {
  local hook
  for hook in prepare-commit-msg commit-msg post-commit post-rewrite pre-push; do
    printf '#!/bin/sh\n# Entire CLI hooks\n' >".git/hooks/$hook"
  done
  mkdir -p .entire .pi/extensions/entire
  : >.pi/extensions/entire/index.ts
  jq -n '{enabled: true, telemetry: false, commit_linking: "always", redaction: {pii: {enabled: true}},
    strategy_options: {checkpoint_remote: {provider: "github", repo: "acme/checkpoints"}}}' >.entire/settings.json
  git add .entire .pi && git commit -qm entire
}

@test "outside an Entire repo it says nothing" {
  out="$(doctor_entire)" || fail "rc"
  [[ -z "$out" ]] || fail "said: $out"
}

@test "an enabled repo set up as recommended is all ok, with a private checkpoint repo" {
  enabled
  out="$(GH_VISIBILITY=PRIVATE doctor_entire)" || fail "rc: $out"
  grep -qF 'ok  entire 0.13.4' <<<"$out" || fail "version: $out"
  grep -qF 'ok  git hooks in' <<<"$out" || fail "hooks: $out"
  grep -qF 'ok  Pi extension committed' <<<"$out" || fail "extension: $out"
  grep -qF "ok  Pi trusts $REPO" <<<"$out" || fail "trust from the parent's saved decision: $out"
  grep -qF 'ok  logged in to Entire' <<<"$out" || fail "login: $out"
  grep -qF 'ok  checkpoints go to github:acme/checkpoints, which is private' <<<"$out" || fail "destination: $out"
  grep -qE '  (hint|warning|missing|unknown)  ' <<<"$out" && fail "nothing to fix: $out"
  grep -qx 'repo view acme/checkpoints --json visibility --jq .visibility' "$BATS_TEST_TMPDIR/gh.log" || fail "gh: $(cat "$BATS_TEST_TMPDIR/gh.log")"
}

@test "checkpoints to a public origin warn; to a public checkpoint repo too; unknown visibility says check it" {
  enabled
  jq 'del(.strategy_options)' .entire/settings.json >s && mv s .entire/settings.json
  git remote add origin https://github.com/acme/widgets.git
  out="$(GH_VISIBILITY=PUBLIC doctor_entire)" || fail "a warning does not fail doctor: $out"
  grep -qF 'warning  checkpoints (full agent transcripts) go to origin (https://github.com/acme/widgets.git), which is public' <<<"$out" \
    || fail "public origin: $out"
  grep -qx 'repo view acme/widgets --json visibility --jq .visibility' "$BATS_TEST_TMPDIR/gh.log" || fail "gh: $(cat "$BATS_TEST_TMPDIR/gh.log")"
  jq '.strategy_options.checkpoint_remote = {provider: "github", repo: "acme/open"}' .entire/settings.json >s && mv s .entire/settings.json
  out="$(GH_VISIBILITY=PUBLIC doctor_entire)"
  grep -qF 'warning  checkpoints (full agent transcripts) go to github:acme/open, which is public' <<<"$out" || fail "public checkpoint repo: $out"
  out="$(doctor_entire)"
  grep -qF 'unknown  checkpoints go to github:acme/open; check that it is private' <<<"$out" || fail "gh says nothing: $out"
  printf '{"strategy_options": {"push_sessions": false}}\n' >.entire/settings.local.json
  out="$(GH_VISIBILITY=PUBLIC doctor_entire)"
  grep -qF 'ok  checkpoints stay in this clone (push_sessions: false)' <<<"$out" || fail "local only: $out"
}

@test "no entire, a missing hook, an old entire, an untracked extension and no trust are said, and never fail doctor" {
  enabled
  rm .git/hooks/pre-push
  out="$(GH_VISIBILITY=PRIVATE doctor_entire)" || fail "a missing hook fails doctor: $out"
  grep -qF "missing  Entire's pre-push hook" <<<"$out" || fail "hook: $out"
  printf '#!/bin/sh\n# Entire CLI hooks\n' >.git/hooks/pre-push
  git rm -q --cached .pi/extensions/entire/index.ts
  printf '{"%s": false}\n' "$REPO" >"$HOME/.pi/agent/trust.json"
  out="$(ENTIRE_FAKE_VERSION=0.12.9 ENTIRE_LOGGED_OUT=1 GH_VISIBILITY=PRIVATE doctor_entire)" || fail "warnings only: $out"
  grep -qF 'old  entire 0.12.9' <<<"$out" || fail "version: $out"
  grep -qF 'warning  .pi/extensions/entire/index.ts is not committed' <<<"$out" || fail "untracked: $out"
  grep -qF "warning  Pi does not trust $REPO (false)" <<<"$out" || fail "trust: $out"
  grep -qF 'hint  not logged in to Entire' <<<"$out" || fail "login: $out"
  rm "$HOME/.pi/agent/trust.json"
  out="$(GH_VISIBILITY=PRIVATE doctor_entire)"
  grep -qF "warning  Pi does not trust $REPO (ask)" <<<"$out" || fail "no saved decision: Pi's default: $out"
  rm "$BIN/entire"
  out="$(doctor_entire)" || fail "no entire fails doctor: $out"
  grep -qF 'missing  entire' <<<"$out" || fail "no entire: $out"
}

@test "the settings bercail recommends are hints; enabled: false is off" {
  enabled
  printf '{"enabled": true, "telemetry": true}\n' >.entire/settings.json
  out="$(GH_VISIBILITY=PRIVATE doctor_entire)" || fail "hints do not fail doctor: $out"
  grep -qF 'hint  commit_linking is prompt' <<<"$out" || fail "commit_linking: $out"
  grep -qF 'hint  telemetry is on' <<<"$out" || fail "telemetry: $out"
  grep -qF 'hint  PII redaction is off' <<<"$out" || fail "pii: $out"
  printf '{"commit_linking": "always", "telemetry": false, "redaction": {"pii": {"enabled": true}}}\n' >.entire/settings.local.json
  out="$(GH_VISIBILITY=PRIVATE doctor_entire)"
  grep -qF '  hint  ' <<<"$out" && fail "local settings count: $out"
  printf '{"enabled": false}\n' >.entire/settings.local.json
  out="$(doctor_entire)" || fail "rc"
  grep -qF 'ok  off here (enabled: false)' <<<"$out" || fail "off: $out"
}
