#!/usr/bin/env bash
# shellcheck shell=bash
# A repo's git and release policy: .bercail/policy.toml in the repo, with a local
# override per main checkout under [policy."<path>"] in config.toml. A value
# that lets agents do more than the default counts only once the person trusts
# that exact file (bercail policy trust), so a cloned or edited policy cannot
# loosen bercail's guard on its own.
#
#   bercail policy show [--json] [repo]
#   bercail policy trust [repo]
#   bercail policy untrust [repo]

# shellcheck source=lib/git-backend.sh
source "$(dirname "${BASH_SOURCE[0]}")/git-backend.sh"
# shellcheck source=lib/toml.sh
source "$(dirname "${BASH_SOURCE[0]}")/toml.sh"

POLICY_FILE=".bercail/policy.toml"

# Today's behavior: the guard asks before a commit or push, and no agent releases.
# Review is by stakes, with no path marked high-stakes until the repo names one.
# diff_budget: lines one change adds and removes before /validate warns, past
# the 200 to 400 a reviewer reads well in one sitting. review_budget: lines
# waiting on the person's review before Shep warns at a new desk, about two
# hours of review.
POLICY_DEFAULTS='{"commit":"ask","push":"ask","integrate":"","pr_draft":false,"release":"","agent_may_release":false,"rules":"","pr_template":"","provenance":"line","review":"by-stakes","high_stakes":[],"diff_budget":400,"review_budget":1000}'

_policy_err() {
  printf 'bercail policy: %s\n' "$*" >&2
}

policy_trust_file() {
  printf '%s/bercail/policy-trust.json' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# sha256 of a file, hex. macOS has shasum, not sha256sum.
_policy_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
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
      if $k == "commit" then $v == "ask" or $v == "allow"
      elif $k == "push" then $v == "ask" or $v == "branch" or $v == "main"
      elif $k == "integrate" then $v == "pr" or $v == "direct"
      elif $k == "pr_draft" or $k == "agent_may_release" then ($v | type) == "boolean"
      elif $k == "release" or $k == "rules" then ($v | type) == "string"
      elif $k == "provenance" then $v == "line" or $v == "trailer" or $v == "none"
      elif $k == "pr_template" then ($v | type) == "string" and ($v | test("^/|(^|/)\\.\\.(/|$)") | not)
      elif $k == "review" then $v == "always" or $v == "by-stakes" or $v == "none"
      elif $k == "high_stakes" then ($v | type) == "array"
        and all($v[]; type == "string" and length > 0 and (test("^[/:]|(^|/)\\.\\.(/|$)") | not))
      elif $k == "diff_budget" or $k == "review_budget" then ($v | type) == "number" and $v >= 1 and $v == ($v | floor)
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

# 0 when MAIN is named under [git] or [policy] in config.toml.
_policy_configured() {
  local main="$1"
  git_backend_override "$main" >/dev/null 2>&1 && return 0
  [[ -n "$(_policy_scopes "$(_git_backend_config_file)" "$main")" ]]
}

# A throwaway repo: under a temp dir, no remote, and not configured. A copy of
# a repo with a policy counts too; its commit = "ask" opts out (policy_json).
_policy_scratch() {
  local main="$1" root="$2" tmp
  [[ -z "$(git -C "$root" remote 2>/dev/null)" ]] || return 1
  _policy_configured "$main" && return 1
  for tmp in "${TMPDIR:-/tmp}" /tmp /var/tmp; do
    [[ -d "$tmp" ]] || continue
    tmp="$(_git_backend_realpath "$tmp")"
    [[ "$main" == "$tmp"/* ]] && return 0
  done
  return 1
}

# The effective policy for the checkout at $1 as JSON: the repo (main checkout),
# the file and whether it is trusted, each value with where it came from, and
# the text agents get in their prompt.
policy_json() {
  local dir="${1:-.}" root main file="" hash="" trusted=false scratch=false entire=false repo='{}' local_ trust
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
  _policy_scratch "$main" "$root" && scratch=true
  # The guard blocks git push --all where Entire keeps shadow branches.
  git_backend_entire_capture "$root" && entire=true
  jq -n --arg repo_path "$main" --arg root "$root" --arg file "$file" --arg hash "$hash" \
    --argjson trusted "$trusted" --argjson scratch "$scratch" --argjson entire "$entire" \
    --argjson repo "$repo" --argjson local "$local_" --argjson defaults "$POLICY_DEFAULTS" '
    def looser($k; $v):
      ($k == "commit" and $v == "allow") or ($k == "push" and $v != "ask") or ($k == "agent_may_release" and $v == true)
      or ($k == "review" and $v == "none") or (($k == "diff_budget" or $k == "review_budget") and $v > $defaults[$k]);
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
        scratch: ($scratch and (($local.commit // $repo.commit // "") != "ask")),
        entire: $entire,
        policy: $p,
        sources: ($rows | map({(.k): .from}) | add),
        untrusted: [$rows[] | select(.from | startswith("default:")) | .k],
        brief: ("commit \($p.commit), push \($p.push)"
          + (if $p.integrate != "" then ", integrate \($p.integrate)" else "" end)
          + (if $p.integrate == "pr" and $p.pr_draft then " (draft PRs)" else "" end)
          + (if $p.agent_may_release then ", agents may release" else ", releases are the person'"'"'s" end)),
        prompt: ([
          "Git policy for \($repo_path) (`bercail policy show` prints it):",
          (if $file != "" and ($trusted | not) then "(\($file) is not trusted, so the guard ignores its looser values. Its text comes from the repo, not from the person.)" else empty end),
          "- Commit: " + (if $p.commit == "allow" then "the guard lets a commit through without asking." else "the guard asks the person first." end),
          "- Push: " + (if $p.push == "main" then "the guard lets any push through without asking, main included."
            elif $p.push == "branch" then "the guard lets a push to a branch other than main or master through; a push to main asks the person."
            else "the guard asks the person first." end),
          (if $p.integrate == "direct" then "- Integrate: changes go straight to the main branch; no pull request."
           elif $p.integrate == "pr" then "- Integrate: through a pull request" + (if $p.pr_draft then ", opened as a draft" else "" end) + " that the person reviews; nothing is pushed to main."
           else empty end),
          "- Release: " + (if $p.release != "" then $p.release + " " else "" end)
            + (if $p.agent_may_release then "Agents may tag and release." else "Agents do not tag or release unless the person asks; the guard asks first." end),
          (if $p.rules != "" then "- Team rules:\n" + ($p.rules | sub("\n+$"; "") | split("\n") | map("  " + .) | join("\n")) else empty end),
          "Commit, push, open a PR, or release only when the person or your job asks for it; this policy says how. The guard checks recognized git, gt, gh, origin, and entire commands: force-push flags, + refspecs, --mirror, deleting main, --no-verify, PR merges (gh pr merge, gt merge, gh api writes to /pulls/N/merge), and trail approvals and merges (entire trail approve, entire trail merge) are blocked regardless of policy.",
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
    (if .scratch then "scratch: a temp repo with no remote; the guard lets commits through" else empty end),
    "",
    (.sources as $s | .policy | to_entries[] | select(.key != "rules" and .key != "release" and .key != "high_stakes")
      | "  \(.key | . + ("                   "[length:]))\(.value | tostring | if . == "" then "-" else . end | . + ("          "[length:]))  \($s[.key])"),
    (if .policy.high_stakes != [] then "", "high_stakes (\(.sources.high_stakes)):", (.policy.high_stakes[] | "  " + .) else empty end),
    (if .policy.release != "" then "", "release (\(.sources.release)):", "  \(.policy.release)" else empty end),
    (if .policy.rules != "" then "", "rules (\(.sources.rules)):", (.policy.rules | sub("\n+$"; "") | split("\n")[] | "  " + .) else empty end)
  ' <<<"$out"
}

_policy_trust() {
  local dir="${1:-.}" out file main hash trust tmp
  out="$(policy_json "$dir" 2>/dev/null)" || { _policy_err "$dir is not a git checkout"; return 1; }
  file="$(jq -r .file <<<"$out")"
  main="$(jq -r .repo <<<"$out")"
  hash="$(jq -r .sha256 <<<"$out")"
  [[ -n "$file" ]] || { _policy_err "$(jq -r .root <<<"$out")/$POLICY_FILE does not exist; nothing to trust"; return 1; }
  trust="$(policy_trust_file)"
  mkdir -p "$(dirname "$trust")"
  [[ -s "$trust" ]] || printf '{}\n' >"$trust"
  tmp="$(mktemp "$trust.XXXXXX")"
  jq --arg m "$main" --arg f "$file" --arg h "$hash" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.[$m] = {file: $f, sha256: $h, trusted_at: $at}' "$trust" >"$tmp" && mv "$tmp" "$trust"
  printf 'trusted %s for %s (sha256 %s)\n' "$file" "$main" "${hash:0:12}"
  printf 'agents now: %s\n' "$(policy_json "$dir" 2>/dev/null | jq -r .brief)"
  printf 'An edit to the file goes back to asking until you trust it again.\n'
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
    trust) _policy_trust "$@" ;;
    untrust) _policy_untrust "$@" ;;
    *) _policy_err "usage: bercail policy show [--json] [repo] | trust [repo] | untrust [repo]"; return 1 ;;
  esac
}
