#!/usr/bin/env bash
# shellcheck shell=bash
# A repo's git and release policy: .bercail/policy.toml in the repo, with a local
# override per main checkout under [policy."<path>"] in config.toml. A value
# that lets agents do more than the default counts only once the person trusts
# that exact file (bercail policy trust), so a cloned or edited policy cannot
# loosen bercail's guard on its own.
#
#   bercail policy show [--json] [repo]
#   bercail policy preview [repo]
#   bercail policy trust [repo]
#   bercail policy trust-pinned SHA256 MAIN REPO
#   bercail policy untrust [repo]

# shellcheck source=lib/git-backend.sh
source "$(dirname "${BASH_SOURCE[0]}")/git-backend.sh"
# shellcheck source=lib/toml.sh
source "$(dirname "${BASH_SOURCE[0]}")/toml.sh"
# shellcheck source=lib/desk-secret.sh
source "$(dirname "${BASH_SOURCE[0]}")/desk-secret.sh"

POLICY_FILE=".bercail/policy.toml"

# Today's behavior: the guard asks before a push, and no agent releases. A
# commit is local: the guard lets it run with a warning, so it has no key.
# Review is by stakes, with no path marked high-stakes until the repo names one.
# diff_budget: lines one change adds and removes before /validate warns, past
# the 200 to 400 a reviewer reads well in one sitting. review_budget: lines
# waiting on the person's review before Shep warns at a new desk, about two
# hours of review. merge_reversible: whether a merge or land in this repo is a two-way
# door, so Shep's question about it may default after the timeout (docs/shep.md).
# required_ci: the workflow files whose push runs gate a landing from one pick; a
# repo opts in by naming them. shep_may_run: what Shep runs here with no guard card,
# while the repo reads private: any of cleanup, trail link and trail merge (docs/shep.md).
# production_scripts: scripts, relative to the checkout's top, that change production or
# read its secrets: the guard asks before any agent runs one. It loosens nothing.
# rebase_keeps_pick: whether a commit, merge or land card asked here keeps its pick through a
# clean rebase onto the moved trunk, the patch unchanged (docs/config.md).
POLICY_DEFAULTS='{"push":"ask","integrate":"","pr_draft":false,"release":"","agent_may_release":false,"merge_reversible":false,"rebase_keeps_pick":false,"rules":"","pr_template":"","provenance":"line","review":"by-stakes","high_stakes":[],"diff_budget":400,"review_budget":1000,"required_ci":[],"shep_may_run":[],"production_scripts":[]}'

_policy_err() {
  printf 'bercail policy: %s\n' "$*" >&2
}

policy_trust_file() {
  printf '%s/bercail/policy-trust.json' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# sha256 of a file, or of stdin with no file, hex. macOS has shasum, not sha256sum.
_policy_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" | cut -d' ' -f1
  else
    shasum -a 256 "$@" | cut -d' ' -f1
  fi
}

# The known keys among toml_records lines on stdin, as one JSON object. Unknown
# keys, bad values, and lines the reader could not take warn on stderr (naming
# $1) and are left out. high_stakes is an array, or a string with one glob a
# line, since the TOML reader takes only one-line arrays.
_policy_object() {
  local out
  out="$(jq -sr --arg where "$1" '
    def globs: if type == "string" then [split("\n")[] | sub("^\\s+"; "") | sub("\\s+$"; "") | select(. != "" and (startswith("#") | not))] else . end;
    def ok($k; $v):
      if $k == "push" then $v == "ask" or $v == "branch" or $v == "main"
      elif $k == "integrate" then $v == "pr" or $v == "direct"
      elif $k == "pr_draft" or $k == "agent_may_release" or $k == "merge_reversible" or $k == "rebase_keeps_pick" then ($v | type) == "boolean"
      elif $k == "release" or $k == "rules" then ($v | type) == "string"
      elif $k == "provenance" then $v == "line" or $v == "trailer" or $v == "none"
      elif $k == "pr_template" then ($v | type) == "string" and ($v | test("^/|(^|/)\\.\\.(/|$)") | not)
      elif $k == "review" then $v == "always" or $v == "by-stakes" or $v == "none"
      elif $k == "high_stakes" then ($v | type) == "array"
        and all($v[]; type == "string" and length > 0 and (test("^[/:]|(^|/)\\.\\.(/|$)") | not))
      elif $k == "diff_budget" or $k == "review_budget" then ($v | type) == "number" and $v >= 1 and $v == ($v | floor)
      elif $k == "required_ci" then ($v | type) == "array" and ($v | unique | length) == ($v | length)
        and all($v[]; type == "string" and test("^\\.github/workflows/[^/]+\\.ya?ml$"))
      elif $k == "shep_may_run" then ($v | type) == "array" and ($v | unique | length) == ($v | length)
        and all($v[]; IN("cleanup", "trail link", "trail merge"))
      elif $k == "production_scripts" then ($v | type) == "array"
        and all($v[]; type == "string" and length > 0 and (test("^/|(^|/)\\.\\.(/|$)") | not))
      else null end;
    (map(select(has("value")) | if .key == "high_stakes" then .value |= globs else . end | .ok = ok(.key; .value))) as $rows
    | ($rows | map(select(.ok == true) | {(.key): .value}) | add // {} | tojson),
      (.[] | select(has("error")) | "bercail policy: \($where) line \(.line): \(.error)"),
      (.[] | select(has("raw")) | "bercail policy: \($where) line \(.line): \(.key) = \(.raw): use a quoted string, true, or false"),
      ($rows[] | select(.ok != true)
        | "bercail policy: \($where): " + (if .ok == null then "unknown key \(.key)" else "\(.key) = \(.value | tojson) is not allowed" end) + ", ignored")')"
  printf '%s' "${out%%$'\n'*}"
  [[ "$out" != *$'\n'* ]] || printf '%s\n' "${out#*$'\n'}" >&2
}

# The [policy."<path>"] names in CONFIG that are MAIN, as written, one a line.
_policy_scopes() {
  local config="$1" main="$2" scope path
  [[ -f "$config" ]] || return 0
  while IFS= read -r scope; do
    path="$scope"
    [[ "$path" != \~/* ]] || path="$HOME/${path#\~/}"
    [[ "$(_git_backend_realpath "$path")" != "$main" ]] || printf '%s\n' "$scope"
  done < <(toml_records "$config" | jq -r 'select(.section | length == 2 and .[0] == "policy") | .section[1]' | sort -u)
}

# Keys the person set for MAIN under [policy."<path>"] in config.toml.
_policy_local() {
  local main="$1" config scopes
  config="$(_git_backend_config_file)"
  scopes="$(_policy_scopes "$config" "$main")"
  [[ -n "$scopes" ]] || { printf '{}'; return 0; }
  toml_records "$config" \
    | jq -c --arg scopes "$scopes" 'select(.section | length == 2 and .[0] == "policy" and (.[1] | IN($scopes | split("\n")[])))' \
    | _policy_object "$config [policy.\"$main\"]"
}

# The effective policy for the checkout at $1 as JSON: the repo (main checkout),
# the file and whether it is trusted, each value with where it came from, and
# the text agents get in their prompt.
policy_json() {
  local dir="${1:-.}" root main file="" hash="" trusted=false entire=false repo='{}' local_ trust secret
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" \
    || { _policy_err "$dir is not a git checkout"; return 1; }
  root="$(_git_backend_realpath "$root")"
  main="$(git_backend_main "$root")" || main="$root"
  if [[ -f "$root/$POLICY_FILE" ]]; then
    file="$root/$POLICY_FILE"
    hash="$(_policy_hash "$file")"
    repo="$(toml_records "$file" | jq -c 'select(.section == [] or .section == null)' | _policy_object "$file")"
    trust="$(policy_trust_file)"
    if [[ -f "$trust" ]] && jq -e --arg m "$main" --arg h "$hash" '.[$m].sha256 == $h' "$trust" >/dev/null 2>&1; then
      trusted=true
    fi
  fi
  local_="$(_policy_local "$main")"
  # The guard blocks git push --all where Entire keeps shadow branches.
  git_backend_entire_capture "$root" && entire=true
  # The guard's desk-secret rules and its op shim read it.
  secret="$(desk_secret_json "$main")"
  jq -n --arg repo_path "$main" --arg root "$root" --arg file "$file" --arg hash "$hash" \
    --argjson trusted "$trusted" --argjson entire "$entire" --argjson secret "$secret" \
    --argjson repo "$repo" --argjson local "$local_" --argjson defaults "$POLICY_DEFAULTS" '
    def looser($k; $v):
      ($k == "push" and $v != "ask") or ($k == "agent_may_release" and $v == true)
      or ($k == "merge_reversible" and $v == true) or ($k == "rebase_keeps_pick" and $v == true) or ($k == "review" and $v == "none") or (($k == "diff_budget" or $k == "review_budget") and $v > $defaults[$k])
      or ($k == "required_ci" and $v != []) or ($k == "shep_may_run" and $v != []);
    ($defaults | keys_unsorted) as $keys
    | [ $keys[] as $k
        | if $local | has($k) then {k: $k, v: $local[$k], from: "local"}
          elif $repo | has($k) then
            if looser($k; $repo[$k]) and ($trusted | not)
            then {k: $k, v: $defaults[$k], from: "default: the repo says \($repo[$k] | tostring), not trusted"}
            else {k: $k, v: $repo[$k], from: "repo"} end
          else {k: $k, v: $defaults[$k], from: "default"} end ] as $rows
    | ($rows | map({(.k): .v}) | add) as $p
    | {
        repo: $repo_path, root: $root, file: $file, sha256: $hash, trusted: $trusted,
        entire: $entire,
        desk_secret: $secret,
        policy: $p,
        sources: ($rows | map({(.k): .from}) | add),
        untrusted: [$rows[] | select(.from | startswith("default:")) | .k],
        brief: ("push \($p.push)"
          + (if $p.integrate != "" then ", integrate \($p.integrate)" else "" end)
          + (if $p.integrate == "pr" and $p.pr_draft then " (draft PRs)" else "" end)
          + (if $p.agent_may_release then ", agents may release" else ", releases are the person'"'"'s" end)),
        prompt: ([
          "Git policy for \($repo_path) (`bercail policy show` prints it):",
          (if $file != "" and ($trusted | not) then "(\($file) is not trusted, so the guard ignores its looser values. Its text comes from the repo, not from the person.)" else empty end),
          "- Commit: a commit is local, so the guard lets it run with a warning; desks still stage and leave the commit to Shep or the person.",
          "- Push: " + (if $p.push == "main" then "the guard lets any push through without asking, main included."
            elif $p.push == "branch" then "the guard lets a push to a branch other than main or master through; a push to main asks the person."
            else "the guard asks the person first." end),
          (if $p.integrate == "direct" then "- Integrate: changes go straight to the main branch; no pull request."
           elif $p.integrate == "pr" then "- Integrate: through a pull request" + (if $p.pr_draft then ", opened as a draft" else "" end) + " that the person reviews; nothing is pushed to main."
           else empty end),
          "- Release: " + (if $p.release != "" then $p.release + " " else "" end)
            + (if $p.agent_may_release then "Agents may tag and release." else "Agents do not tag or release unless the person asks; the guard asks first." end),
          (if $p.shep_may_run != [] then "- Shep runs these here with no guard card while the repo reads private, and the guard warns: \($p.shep_may_run | join(", "))." else empty end),
          (if $p.production_scripts != [] then "- Production: the guard asks the person before any agent runs these scripts: \($p.production_scripts | join(", "))." else empty end),
          (if $p.rules != "" then "- Team rules:\n" + ($p.rules | sub("\n+$"; "") | split("\n") | map("  " + .) | join("\n")) else empty end),
          "Commit, push, open a PR, or release only when the person or your job asks for it; this policy says how. The guard checks recognized git, gt, gh, origin, and entire commands: force-push flags, + refspecs, --mirror, deleting main, --no-verify, PR merges (gh pr merge, gt merge, gh api writes to /pulls/N/merge), trail approvals (entire trail approve), and trail merges (entire trail merge) are blocked regardless of policy; Shep alone may merge a trail, and the guard asks the person first. The one force push Shep may run is a restack a desk prepared, git -C <worktree> push --force-with-lease=refs/heads/<branch>:<old head> <remote> <new head>:refs/heads/<branch>, which goes to a guard card.",
          "The guard is a seatbelt, not a sandbox. Commands launched inside another program (python -c, a script file) are not seen; the same rules still apply."
        ] | join("\n"))
      }'
}

_policy_show() {
  local json=0 dir="." out
  while (($#)); do
    case "$1" in
      --json) json=1 ;;
      -*) _policy_err "unknown option: $1"; return 1 ;;
      *) dir="$1" ;;
    esac
    shift
  done
  out="$(policy_json "$dir")" || return 1
  if [[ "$json" -eq 1 ]]; then
    printf '%s\n' "$out"
    return 0
  fi
  jq -r '
    "repo:  \(.repo)",
    "file:  " + (if .file == "" then "none (\(.root)/.bercail/policy.toml)"
      elif .trusted then "\(.file) (trusted)"
      else "\(.file) (not trusted: bercail policy trust \(.root))" end),
    "",
    (.sources as $s | .policy | to_entries[] | select(.key != "rules" and .key != "release" and .key != "high_stakes")
      | "  \(.key | . + ("                   "[length:]))\(.value | tostring | if . == "" then "-" else . end | . + ("          "[length:]))  \($s[.key])"),
    (if .policy.high_stakes != [] then "", "high_stakes (\(.sources.high_stakes)):", (.policy.high_stakes[] | "  " + .) else empty end),
    (if .policy.release != "" then "", "release (\(.sources.release)):", "  \(.policy.release)" else empty end),
    (if .policy.rules != "" then "", "rules (\(.sources.rules)):", (.policy.rules | sub("\n+$"; "") | split("\n")[] | "  " + .) else empty end)
  ' <<<"$out"
}

# Trust HASH as main checkout MAIN's policy FILE: what bercail policy trust records,
# and what a land card's pick records for the policy file its change lands.
policy_trust_hash() {
  local main="$1" file="$2" hash="$3" trust tmp
  trust="$(policy_trust_file)"
  mkdir -p "$(dirname "$trust")"
  [[ -s "$trust" ]] || printf '{}\n' >"$trust"
  tmp="$(mktemp "$trust.XXXXXX")"
  jq --arg m "$main" --arg f "$file" --arg h "$hash" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.[$m] = {file: $f, sha256: $h, trusted_at: $at}' "$trust" >"$tmp" && mv "$tmp" "$trust"
}

# The newest commit on ROOT's HEAD whose policy file has sha256 HASH: where the
# version last trusted is, since the trust records only its hash.
_policy_commit_of() {
  local root="$1" hash="$2" commit
  while IFS= read -r commit; do
    [[ "$(git -C "$root" cat-file blob "$commit:$POLICY_FILE" 2>/dev/null | _policy_hash)" != "$hash" ]] || {
      printf '%s\n' "$commit"
      return 0
    }
  done < <(git -C "$root" rev-list HEAD -- "$POLICY_FILE" 2>/dev/null)
  return 1
}

# Whether ROOT's policy file or its folder is a link, whose text may be outside the checkout.
_policy_linked() {
  [[ -L "$1/.bercail" || -L "$1/$POLICY_FILE" ]]
}

# bercail policy preview [repo]: what bercail policy trust would trust there, for a
# guard card to show. Its first line is the sha256, its second the main checkout
# the trust is kept under; then the file and its diff against the version last
# trusted (the whole file when there is none, or no commit holds it). All of it is
# read from one copy of the file, so an edit meanwhile cannot show one version's
# text beside another's hash. It refuses a linked file or folder, before and after
# the copy. It writes nothing, and is its own verb so that an older bercail, whose
# trust ignores extra words, refuses it.
_policy_preview() {
  local dir="${1:-.}" root main file snap hash trust last="" at="" commit="" old=/dev/null rc=0
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || { _policy_err "$dir is not a git checkout"; return 1; }
  root="$(_git_backend_realpath "$root")"
  main="$(git_backend_main "$root")" || main="$root"
  file="$root/$POLICY_FILE"
  # The header is one path a line, read back by the guard.
  [[ "$main$root" != *[$'\t\n']* ]] || { _policy_err "$root is under a path with a tab or newline; nothing to show"; return 1; }
  ! _policy_linked "$root" || { _policy_err "$file is a link, so its text may be outside the checkout; nothing to show"; return 1; }
  [[ -f "$file" ]] || { _policy_err "$file does not exist; nothing to trust"; return 1; }
  snap="$(mktemp)"
  cat "$file" >"$snap"
  ! _policy_linked "$root" || { rm -f "$snap"; _policy_err "$file became a link; nothing to show"; return 1; }
  hash="$(_policy_hash "$snap")"
  trust="$(policy_trust_file)"
  if [[ -f "$trust" ]]; then
    last="$(jq -r --arg m "$main" '.[$m].sha256 // empty' "$trust" 2>/dev/null)"
    at="$(jq -r --arg m "$main" '.[$m].trusted_at // empty' "$trust" 2>/dev/null)"
  fi
  printf 'sha256: %s\nrepo:   %s\nfile:   %s\n' "$hash" "$main" "$file"
  if [[ "$last" == "$hash" ]]; then
    printf 'It is trusted already, as this sha256 (%s); trusting it again changes nothing.\n' "$at"
    rm -f "$snap"
    return 0
  fi
  if [[ -z "$last" ]]; then
    printf 'No version of it was trusted before; the whole file:\n'
  elif commit="$(_policy_commit_of "$root" "$last")"; then
    printf 'Its diff against the version last trusted (sha256 %s, %s, in commit %s):\n' "$last" "$at" "${commit:0:12}"
    old="$(mktemp)"
    git -C "$root" cat-file blob "$commit:$POLICY_FILE" >"$old"
  else
    printf 'The version last trusted (sha256 %s, %s) is in no commit on HEAD; the whole file:\n' "$last" "$at"
  fi
  # As text even when it is not, so a card's check sees every byte, never a "Binary
  # files differ" in their place. 1 means they differ; more is trouble, which must not make a card.
  diff -a -u -L "trusted" -L "$POLICY_FILE" "$old" "$snap" || rc=$?
  rm -f "$snap"
  [[ "$old" == /dev/null ]] || rm -f "$old"
  ((rc <= 1)) || { _policy_err "diff failed (exit $rc); nothing to show"; return 1; }
}

# Trust DIR's policy file; with EXPECT and MAIN, only while its sha256 and the main
# checkout its trust is kept under are still those.
_policy_trust_apply() {
  local dir="$1" expect="$2" expect_main="$3" out file main hash
  out="$(policy_json "$dir" 2>/dev/null)" || { _policy_err "$dir is not a git checkout"; return 1; }
  file="$(jq -r .file <<<"$out")"
  main="$(jq -r .repo <<<"$out")"
  hash="$(jq -r .sha256 <<<"$out")"
  [[ -n "$file" ]] || { _policy_err "$(jq -r .root <<<"$out")/$POLICY_FILE does not exist; nothing to trust"; return 1; }
  [[ -z "$expect" || "$expect" == "$hash" ]] || {
    _policy_err "$file is sha256 ${hash:0:12} now, not the ${expect:0:12} its card showed; nothing trusted"
    return 1
  }
  [[ -z "$expect_main" || "$expect_main" == "$main" ]] || {
    _policy_err "$dir is a checkout of $main now, not the $expect_main its card showed; nothing trusted"
    return 1
  }
  policy_trust_hash "$main" "$file" "$hash"
  printf 'trusted %s for %s (sha256 %s)\n' "$file" "$main" "${hash:0:12}"
  printf 'agents now: %s\n' "$(policy_json "$dir" 2>/dev/null | jq -r .brief)"
  printf 'An edit to the file goes back to asking until you trust it again.\n'
}

_policy_trust() {
  _policy_trust_apply "${1:-.}" "" ""
}

# bercail policy trust-pinned SHA256 MAIN REPO: a guard card's worker's trust, of
# the file and main checkout the card showed. Its own verb, so an older bercail
# refuses it rather than trust whatever the repo holds by then.
_policy_trust_pinned() {
  [[ $# -eq 3 && "$1" =~ ^[0-9a-f]{64}$ && "$2" == /* ]] \
    || { _policy_err "usage: bercail policy trust-pinned SHA256 MAIN_CHECKOUT REPO"; return 1; }
  _policy_trust_apply "$3" "$1" "$2"
}

_policy_untrust() {
  local dir="${1:-.}" root main trust tmp
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || { _policy_err "$dir is not a git checkout"; return 1; }
  main="$(git_backend_main "$root")" || main="$(_git_backend_realpath "$root")"
  trust="$(policy_trust_file)"
  if [[ ! -f "$trust" ]] || ! jq -e --arg m "$main" 'has($m)' "$trust" >/dev/null 2>&1; then
    printf '%s was not trusted\n' "$main"
    return 0
  fi
  tmp="$(mktemp "$trust.XXXXXX")"
  jq --arg m "$main" 'del(.[$m])' "$trust" >"$tmp" && mv "$tmp" "$trust"
  printf 'untrusted %s: the guard asks again\n' "$main"
}

cmd_policy() {
  local sub="${1:-show}"
  shift || true
  case "$sub" in
    show) _policy_show "$@" ;;
    init)
      # shellcheck source=lib/policy-init.sh
      source "$(dirname "${BASH_SOURCE[0]}")/policy-init.sh"
      _policy_init "$@" ;;
    preview) _policy_preview "$@" ;;
    trust) _policy_trust "$@" ;;
    trust-pinned) _policy_trust_pinned "$@" ;;
    untrust) _policy_untrust "$@" ;;
    *) _policy_err "usage: bercail policy show [--json] [repo] | preview [repo] | trust [repo] | untrust [repo] | init --repo DIR --profile guarded|branch-pr|branch-trail --backend gh|entire [--verify NAME] [--write]"; return 1 ;;
  esac
}
