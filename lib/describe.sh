#!/usr/bin/env bash
# shellcheck shell=bash
# A change's description: .bercail/description.md in the worktree, written at
# /validate and used as written for the commit message and the PR body. Its
# frontmatter names the staged tree it describes, so any later edit makes it
# stale, and title, body and commit refuse a stale or failing description.
#
#   bercail describe template [--json] [dir]
#   bercail describe stamp [dir]
#   bercail describe check [--json] [dir]
#   bercail describe title|body|commit [--reviewed-by NAME] [dir]
#
# body and commit end with the provenance the policy asks for (provenance =
# line, trailer or none): that an agent wrote it, on which model, and who
# reviewed it, from facts only.

# shellcheck source=lib/policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/policy.sh"

DESC_FILE=".bercail/description.md"
DESC_EVIDENCE=".bercail/validate.json"
# A PR body fits on one screen.
DESC_MAX_LINES=40

_desc_err() {
  printf 'bercail describe: %s\n' "$*" >&2
}

_desc_root() {
  git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null \
    || { _desc_err "${1:-.} is not a git checkout"; return 1; }
}

# The PR template among the repo paths on stdin, as {template, choices}:
# GitHub's pull_request_template.md in .github/, the root, then docs/, in any
# case. choices are the files of a PULL_REQUEST_TEMPLATE/ dir there, which
# GitHub never picks on its own. review-pr runs this on a ref's paths.
desc_template_pick() {
  jq -Rnc '
    def rank: if test("^\\.github/"; "i") then 0 elif test("^docs/"; "i") then 2 else 1 end;
    [inputs] as $p
    | { template: ([$p[] | select(test("^((\\.github|docs)/)?pull_request_template\\.md$"; "i"))] | sort_by(rank) | .[0]),
        choices: ([$p[] | select(test("^((\\.github|docs)/)?pull_request_template/[^/]+\\.md$"; "i"))] | sort_by(rank, .)) }'
}

# The checkout's template as {template, choices}. The policy's
# pr_template wins: a path in the repo, or "none". Organization defaults are
# not read.
desc_template() {
  local root="$1" pinned
  pinned="$(policy_json "$root" 2>/dev/null | jq -r '.policy.pr_template // ""')"
  if [[ "$pinned" == none ]]; then
    jq -nc '{template: null, choices: []}'
  elif [[ -n "$pinned" ]]; then
    [[ -f "$root/$pinned" ]] || { _desc_err "the policy's pr_template $pinned is not a file in $root"; return 1; }
    jq -nc --arg t "$pinned" '{template: $t, choices: []}'
  else
    git -C "$root" ls-files -co --exclude-standard | desc_template_pick
  fi
}

# commit when the policy integrates straight to main, else pr.
_desc_style() {
  if [[ "$(policy_json "$1" 2>/dev/null | jq -r '.policy.integrate')" == direct ]]; then
    printf commit
  else
    printf pr
  fi
}

# Frontmatter value KEY of FILE, or empty.
_desc_meta() {
  awk -v k="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    NR > 1 {
      i = index($0, ":")
      if (i && substr($0, 1, i - 1) == k) {
        v = substr($0, i + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); print v; exit
      }
    }' "$1"
}

# What follows the frontmatter, without the leading blank lines.
_desc_body() {
  awk '
    NR == 1 && $0 == "---" { fm = 1; next }
    fm && $0 == "---" { fm = 0; next }
    fm { next }
    !started && /^[ \t]*$/ { next }
    { started = 1; print }' "$1"
}

# Who wrote it, from the desk's record for this worktree: "Pi, claude-opus-5-5"
# (the model the desk started on, without its provider and thinking level), or
# empty when no desk recorded this folder.
_desc_agent() {
  local root="$1" dir record
  dir="${XDG_STATE_HOME:-$HOME/.local/state}/bercail/desk-sessions"
  [[ -d "$dir" ]] || return 0
  # shellcheck disable=SC2012 # bercail names these files <address>.json
  record="$(ls -t "$dir"/*.json 2>/dev/null \
    | while IFS= read -r f; do jq -e --arg c "$root" '.cwd == $c' "$f" >/dev/null 2>&1 && { printf '%s' "$f"; break; }; done)"
  [[ -n "$record" ]] || return 0
  jq -r '
    (.harness // "" | if . == "pi" then "Pi" else . end) as $h
    | (.args // []) as $a | ($a | index("--model")) as $i
    | (if $i == null then "" else $a[$i + 1] | sub("^.*/"; "") | sub(":.*$"; "") end) as $m
    | [$h, $m] | map(select(. != "")) | join(", ")' "$record" 2>/dev/null
}

# The provenance lines for POLICY's form: line, trailer or none.
_desc_provenance() {
  local form="$1" agent="$2" reviewer="$3" by
  by="bercail${agent:+ ($agent)}"
  case "$form" in
    none) ;;
    trailer) printf 'Assisted-by: %s\n' "$by"; [[ -z "$reviewer" ]] || printf 'Reviewed-by: %s\n' "$reviewer" ;;
    *) printf 'Written with %s; %s\n' "$by" "$([[ -n "$reviewer" ]] && printf 'reviewed by %s' "$reviewer" || printf 'not yet reviewed')" ;;
  esac
}

_desc_provenance_form() {
  policy_json "$1" 2>/dev/null | jq -r '.policy.provenance // "line" | if . == "" then "line" else . end'
}

# The staged tree: after the commit it equals HEAD^{tree}, so one id names the
# change before and after it is committed.
_desc_tree() {
  git -C "$1" write-tree 2>/dev/null || { _desc_err "cannot write the index's tree in $1 (a merge in progress?)"; return 1; }
}

# The repo's beads ids as a JSON array; [] without beads. They mean nothing to a
# reader outside this machine, so the check fails on one.
_desc_beads_ids() {
  local root="$1"
  [[ -e "$root/.beads" ]] && command -v bd >/dev/null 2>&1 || { printf '[]'; return 0; }
  (cd "$root" && timeout 10 bd list --all --json --limit 0 2>/dev/null) | jq -c '[.[]?.id | strings]' 2>/dev/null || printf '[]'
}

_desc_conventional() {
  local root="$1" f
  for f in "$root"/commitlint.config.* "$root"/.commitlintrc*; do
    [[ -e "$f" ]] && return 0
  done
  [[ -f "$root/package.json" ]] && jq -e 'has("commitlint")' "$root/package.json" >/dev/null 2>&1
}

# 0 when validate.json records checks for TREE.
_desc_evidence_ok() {
  jq -e --arg tree "$2" '
    type == "object" and .tree == $tree and (.checks | type == "array" and length > 0)
    and all(.checks[]; type == "object" and (.kind | type == "string" and length > 0)
      and (.command | type == "string" and length > 0) and (.exit_code | type == "number")
      and (.evidence | type == "string"))' "$1" >/dev/null 2>&1
}

# Problems with the body as {fails, warns}: the template's headings and order,
# empty sections, empty label lines, template comments, beads ids, length.
_desc_body_problems() {
  local body="$1" title="$2" tpl="$3" ids="$4"
  jq -nc --arg body "$body" --arg title "$title" --arg tpl "$tpl" --argjson ids "$ids" --argjson max "$DESC_MAX_LINES" '
    def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
    def heading: test("^#{1,6}\\s+\\S");
    def level: capture("^(?<h>#+)").h | length;
    def htext: sub("^#{1,6}\\s+"; "") | trim;
    def labelline: test("^[A-Za-z][^:#<]{0,40}:\\s*$");
    ($body | split("\n")) as $b
    | [$b | to_entries[] | select(.value | heading) | {i: .key, l: (.value | level), t: (.value | htext)}] as $h
    | [$h[] | .t | ascii_downcase] as $bh
    | [$tpl | split("\n")[] | select(heading) | htext] as $th
    | [$tpl | split("\n")[] | select(labelline) | trim] as $tl
    | [$th[] | ascii_downcase as $k | $bh | index($k)] as $pos
    | ([$title, $body] | map([scan("[A-Za-z0-9][A-Za-z0-9_.-]*[A-Za-z0-9]")]) | add | unique) as $tokens
    | {
        fails: [
          (if ($body | trim) == "" then "the body is empty" else empty end),
          ($th[] | select((ascii_downcase | IN($bh[])) | not) | "the template section \"\(.)\" is missing"),
          (if ($pos | map(select(. != null))) != ($pos | map(select(. != null)) | sort) then "the sections are not in the template order" else empty end),
          ($h | to_entries[] | .key as $k | .value as $cur
            | ([$h[$k + 1:][] | select(.l <= $cur.l) | .i] | .[0] // ($b | length)) as $end
            | select([$b[$cur.i + 1:$end][] | select(trim != "")] | length == 0)
            | "the section \"\($cur.t)\" is empty: fill it or write None: <why>"),
          ($tl[] as $l | select(any($b[]; trim == $l)) | "the line \"\($l)\" is empty: fill it or remove it"),
          (if $body | test("<!--") then "a template comment (<!-- -->) is left in" else empty end),
          ($tokens[] | select(IN($ids[])) | "\(.) is a beads id: state the ask in words; beads ids stay in reports"),
          (if any($b[]; test("^(Written with bercail|Assisted-by:|Reviewed-by:)")) then "a provenance line is written by hand: bercail adds it when it prints the description" else empty end)
        ],
        warns: [
          ($tl[] as $l | select(any($b[]; ascii_downcase | startswith($l | ascii_downcase)) | not) | "the template line \"\($l)\" was dropped"),
          (if ($b | length) > $max then "the body is \($b | length) lines, longer than a screen (\($max))" else empty end)
        ]
      }'
}

# Everything check knows, as JSON. Exit status is not the verdict; .fails is.
desc_state() {
  local root="$1" file evidence title style tree current tpl_json template meta_tpl tpl_text="" body ids line
  local -a fails=() warns=()
  file="$root/$DESC_FILE"
  evidence="$root/$DESC_EVIDENCE"
  current="$(_desc_tree "$root")" || return 1
  if [[ ! -f "$file" ]]; then
    jq -nc --arg file "$file" --arg cur "$current" \
      '{file: $file, tree: null, current_tree: $cur, stale: true, fails: ["no \($file): run /validate"], warns: []}'
    return 0
  fi
  title="$(_desc_meta "$file" title)"
  tree="$(_desc_meta "$file" tree)"
  meta_tpl="$(_desc_meta "$file" template)"
  style="$(_desc_style "$root")"
  tpl_json="$(desc_template "$root")" || return 1
  body="$(_desc_body "$file")"

  [[ -n "$title" ]] || fails+=("no title: put title: <intent, 72 characters or fewer> in the frontmatter")
  [[ "${#title}" -le 72 ]] || fails+=("the title is ${#title} characters; 72 at most (it is the commit subject)")
  if [[ -z "$tree" ]]; then
    fails+=("not stamped: run bercail describe stamp")
  elif [[ "$tree" != "$current" ]]; then
    fails+=("stale: it describes tree ${tree:0:12}, the staged tree is ${current:0:12}; rerun /validate")
  fi
  if [[ ! -f "$evidence" ]]; then
    fails+=("no $evidence: /validate records its checks there")
  elif ! _desc_evidence_ok "$evidence" "${tree:-$current}"; then
    fails+=("$evidence does not record checks for tree ${tree:0:12}: {tree, checks: [{kind, command, exit_code, evidence}]}")
  else
    while IFS= read -r line; do
      warns+=("$line")
    done < <(jq -r '.checks[] | select(.exit_code != 0) | "the check `\(.command)` exited \(.exit_code): say so in the validation"' "$evidence")
  fi
  if git -C "$root" ls-files -- .bercail | grep -qvx '.bercail/policy.toml'; then
    fails+=(".bercail/ runtime files are staged: git rm --cached them; only .bercail/policy.toml is versioned")
  fi
  if [[ -n "$(git -C "$root" status --porcelain --untracked-files=all -- . ':!.bercail' | grep -v '^[MADRC] ' || true)" ]]; then
    warns+=("changes outside the index are not in the described tree: git add them, or keep them out of the change")
  fi
  if [[ "$style" == commit ]]; then
    template=""
  else
    template="$(jq -r '.template // ""' <<<"$tpl_json")"
    if [[ -n "$meta_tpl" && "$meta_tpl" != "$template" ]]; then
      if jq -e --arg t "$meta_tpl" '.choices | index($t)' <<<"$tpl_json" >/dev/null; then
        template="$meta_tpl"
      else
        fails+=("the template $meta_tpl is not this repo's: $(jq -r '[.template // empty, .choices[]] | if length == 0 then "it has none" else join(", ") end' <<<"$tpl_json")")
      fi
    elif [[ -z "$template" ]] && jq -e '.choices | length > 0' <<<"$tpl_json" >/dev/null; then
      fails+=("pick a template: template: <one of $(jq -r '.choices | join(", ")' <<<"$tpl_json")> in the frontmatter")
    fi
    [[ -z "$template" || ! -f "$root/$template" ]] || tpl_text="$(<"$root/$template")"
  fi
  if _desc_conventional "$root" && [[ -n "$title" ]] && ! [[ "$title" =~ ^[a-z]+(\([^\)]+\))?!?:\ .+ ]]; then
    fails+=("this repo uses Conventional Commits (commitlint): the title must read type(scope): subject")
  fi
  ids="$(_desc_beads_ids "$root")"
  jq -nc --arg file "$file" --arg title "$title" --arg style "$style" --arg template "$template" \
    --arg tree "$tree" --arg cur "$current" \
    --argjson body "$(_desc_body_problems "$body" "$title" "$tpl_text" "$ids")" \
    --argjson fails "$(jq -nc '$ARGS.positional' --args -- "${fails[@]+"${fails[@]}"}")" \
    --argjson warns "$(jq -nc '$ARGS.positional' --args -- "${warns[@]+"${warns[@]}"}")" '
    {file: $file, title: $title, style: $style, template: (if $template == "" then null else $template end),
     tree: (if $tree == "" then null else $tree end), current_tree: $cur,
     stale: ($tree != $cur), fails: ($fails + $body.fails), warns: ($warns + $body.warns)}'
}

# Keep the runtime dir out of git status, tuicr and git add -A, in a repo that
# does not ignore it already. info/exclude is local; the repo is not edited.
_desc_ignore() {
  local root="$1" exclude
  git -C "$root" check-ignore -q "$DESC_FILE" && return 0
  exclude="$(git -C "$root" rev-parse --path-format=absolute --git-path info/exclude)"
  mkdir -p "$(dirname "$exclude")"
  printf '.bercail/*\n!.bercail/policy.toml\n' >>"$exclude"
}

# Record the staged tree, the template and the agent in the frontmatter. It
# needs validate.json for that same tree, so a new stamp needs new evidence.
_desc_stamp() {
  local root="$1" file tree title style template tpl_json meta_tpl tmp agent
  file="$root/$DESC_FILE"
  [[ -f "$file" ]] || { _desc_err "no $file: write the description first (the describe skill)"; return 1; }
  title="$(_desc_meta "$file" title)"
  [[ -n "$title" ]] || { _desc_err "$file has no title: in its frontmatter"; return 1; }
  _desc_ignore "$root"
  tree="$(_desc_tree "$root")" || return 1
  _desc_evidence_ok "$root/$DESC_EVIDENCE" "$tree" \
    || { _desc_err "$root/$DESC_EVIDENCE must record the checks for the staged tree $tree: {tree, checks: [{kind, command, exit_code, evidence}]}"; return 1; }
  style="$(_desc_style "$root")"
  meta_tpl="$(_desc_meta "$file" template)"
  tpl_json="$(desc_template "$root")" || return 1
  template="$(jq -r '.template // ""' <<<"$tpl_json")"
  [[ -z "$meta_tpl" ]] || template="$meta_tpl"
  [[ "$style" == pr ]] || template=""
  agent="$(_desc_agent "$root")"
  tmp="$(mktemp "$file.XXXXXX")"
  {
    printf -- '---\ntitle: %s\ntree: %s\n' "$title" "$tree"
    [[ -z "$template" ]] || printf 'template: %s\n' "$template"
    [[ -z "$agent" ]] || printf 'agent: %s\n' "$agent"
    printf -- '---\n'
    _desc_body "$file"
  } >"$tmp" && mv "$tmp" "$file"
  printf 'stamped %s: %s style, tree %s%s\n' "$DESC_FILE" "$style" "${tree:0:12}" "${template:+, template $template}"
}

# Print the problems; 0 when none fail.
_desc_report() {
  jq -r '(.fails[] | "fail: \(.)"), (.warns[] | "warn: \(.)")' <<<"$1" >&2
  jq -e '.fails | length == 0' <<<"$1" >/dev/null
}

_desc_check() {
  local json="$1" root="$2" state
  state="$(desc_state "$root")" || return 1
  if [[ "$json" -eq 1 ]]; then
    printf '%s\n' "$state"
    jq -e '.fails | length == 0' <<<"$state" >/dev/null
    return
  fi
  if _desc_report "$state"; then
    printf 'ok %s: %s style, tree %s\n' "$DESC_FILE" "$(jq -r .style <<<"$state")" "$(jq -r '.tree[0:12]' <<<"$state")"
  else
    return 1
  fi
}

# title, body or commit: the text, only when the check passes. body and commit
# end with the provenance; REVIEWER only when a person reviewed this change.
_desc_print() {
  local what="$1" root="$2" reviewer="$3" state file body provenance
  state="$(desc_state "$root")" || return 1
  _desc_report "$state" || { _desc_err "not printing a description that fails the check"; return 1; }
  file="$root/$DESC_FILE"
  body="$(_desc_body "$file")"
  provenance="$(_desc_provenance "$(_desc_provenance_form "$root")" "$(_desc_meta "$file" agent)" "$reviewer")"
  [[ -z "$provenance" ]] || body+=$'\n\n'"$provenance"
  case "$what" in
    title) jq -r .title <<<"$state" ;;
    body) printf '%s\n' "$body" ;;
    commit) printf '%s\n\n%s\n' "$(jq -r .title <<<"$state")" "$body" ;;
  esac
}

cmd_describe() {
  local sub="${1:-check}" json=0 dir="." root reviewer=""
  shift || true
  while (($#)); do
    case "$1" in
      --json) json=1 ;;
      --reviewed-by)
        reviewer="${2:-}"
        [[ -n "$reviewer" && "$reviewer" != *$'\n'* ]] || { _desc_err "--reviewed-by takes the reviewer's name"; return 1; }
        shift ;;
      -*) _desc_err "unknown option: $1"; return 1 ;;
      *) dir="$1" ;;
    esac
    shift
  done
  root="$(_desc_root "$dir")" || return 1
  case "$sub" in
    template)
      if [[ "$json" -eq 1 ]]; then
        desc_template "$root"
      else
        desc_template "$root" | jq -r 'if .template != null then .template
          elif (.choices | length) > 0 then "pick one: " + (.choices | join(", "))
          else "none" end'
      fi
      ;;
    stamp) _desc_stamp "$root" ;;
    check) _desc_check "$json" "$root" ;;
    title|body|commit) _desc_print "$sub" "$root" "$reviewer" ;;
    *) _desc_err "usage: bercail describe template|stamp|check [--json] [dir] | title|body|commit [--reviewed-by NAME] [dir]"; return 1 ;;
  esac
}
