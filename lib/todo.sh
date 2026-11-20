#!/usr/bin/env bash
# shellcheck shell=bash
# bercail todo: what only the person can do (a login, a vault, a device), in
# the todo tool they already read. A target is one list there, by name; routes
# send a repo's todos to a target, and the default takes the rest. Targets and
# routes live in todo.json beside config.toml, written only by `bercail todo
# target` and `route`; an old [todo] backend in config.toml is the target
# "config". lib/todo/<backend>.sh defines todo_<backend>_owns, _target, _check,
# _add, _list, _show and _complete, and reads its target's fields from
# TODO_TARGET_JSON. Callers go through _todo_call, so a new backend touches no
# caller.
#
#   bercail todo add "TITLE" [--notes TEXT] [--due YYYY-MM-DD] [--issue ID] [--repo DIR] [--target NAME]
#   bercail todo list [--target NAME] [--json]
#   bercail todo show ID [--target NAME]
#   bercail todo done ID [--target NAME]
#   bercail todo target add NAME URL [--backend NAME] [--create "LIST"] [--json] | list [--json] | show NAME [--json] | rm NAME
#   bercail todo route REPO TARGET | --default TARGET | --rm REPO | --rm --default
#
# A backend prints a todo, or an array of them, as JSON:
#   {id, title, notes, due, done, url}   (id a string, due YYYY-MM-DD or null)
# its target op prints the target's fields ({label, url, ...its own}), and its
# check prints one "STATUS<TAB>TEXT" line for doctor (STATUS: ok, missing,
# incomplete, unreachable, or --), never a token.

# shellcheck source=lib/git-backend.sh
source "$(dirname "${BASH_SOURCE[0]}")/git-backend.sh"

TODO_USAGE='usage: bercail todo add "TITLE" [--notes TEXT] [--due YYYY-MM-DD] [--issue ID] [--repo DIR] [--target NAME] | list [--target NAME] [--json] | show ID [--target NAME] | done ID [--target NAME] | target add|list|show|rm | route REPO TARGET'
TODO_TARGET_USAGE='usage: bercail todo target add NAME URL [--backend NAME] [--create "LIST"] [--json] | list [--json] | show NAME [--json] | rm NAME'
TODO_ROUTE_USAGE='usage: bercail todo route REPO TARGET | route --default TARGET | route --rm REPO | route --rm --default'
# Seconds a backend call may take; the board gives each target less (Shep's
# compaction gives the whole board 60), and reads the targets side by side.
TODO_TIMEOUT=30
TODO_BOARD_TIMEOUT=10

_todo_err() {
  printf 'bercail todo: %s\n' "$*" >&2
}

# One JSON line per todo bercail added ({at, target, backend, id, url, title,
# issue, repo}), and one per todo Shep marked done ({at, target, backend, id,
# done: true}). Lines from before targets have no target: they are "config"'s.
todo_ledger_file() {
  printf '%s/bercail/todos.jsonl' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# {default, targets: {NAME: {backend, ...}}, routes: {MAIN_CHECKOUT: NAME}}.
todo_targets_file() {
  printf '%s/todo.json' "$(dirname "$BERCAIL_USER_CONFIG")"
}

# The backends this bercail has, space-separated.
_todo_backends() {
  local f names=()
  for f in "$(dirname "${BASH_SOURCE[0]}")"/todo/*.sh; do
    [[ -f "$f" ]] && names+=("$(basename "$f" .sh)")
  done
  printf '%s' "${names[*]}"
}

# Sources backend NAME; fails when bercail has none of that name.
_todo_source() {
  local file
  file="$(dirname "${BASH_SOURCE[0]}")/todo/$1.sh"
  [[ "$1" =~ ^[a-z0-9_]+$ && -f "$file" ]] || return 1
  # shellcheck source=/dev/null
  source "$file"
}

# todo.json as written, {} when there is none.
_todo_file_json() {
  local file
  file="$(todo_targets_file)"
  [[ -f "$file" ]] || { printf '{}'; return 0; }
  jq -ce 'select(type == "object")' "$file" 2>/dev/null \
    || { _todo_err "$file is not the JSON bercail todo writes; fix it, or move it away and add the targets again"; return 1; }
}

# Every target, route and the default, with [todo] in config.toml as the
# target "config" and the default when todo.json names none.
_todo_state() {
  local raw legacy fields='{}'
  raw="$(_todo_file_json)" || return 1
  legacy="$(toml_value "$BERCAIL_USER_CONFIG" todo backend)"
  if [[ -n "$legacy" ]]; then
    fields="$(toml_records "$BERCAIL_USER_CONFIG" | jq -sc --arg b "$legacy" '
      [.[] | select(.section == ["todo", $b] and has("value")) | {key, value: (.value | tostring)}] | from_entries')"
  fi
  jq -c --arg legacy "$legacy" --argjson fields "$fields" '
    {default: .default, targets: (.targets // {}), routes: (.routes // {})}
    | if $legacy == "" then . else .targets.config = ($fields + {backend: $legacy, from: "config.toml"}) | .default //= "config" end' <<<"$raw"
}

# Writes todo.json through jq FILTER [ARGS...], whole or not at all.
_todo_save() {
  local file raw tmp
  file="$(todo_targets_file)"
  raw="$(_todo_file_json)" || return 1
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "$file.XXXXXX")"
  if jq "$@" <<<"$raw" >"$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

_todo_names() {
  jq -r '.targets | keys | if length == 0 then "none" else join(", ") end' <<<"$1"
}

# Loads target NAME from STATE: TODO_TARGET, TODO_BACKEND, TODO_TARGET_JSON,
# TODO_TARGET_FROM, and its backend's functions.
_todo_use() {
  local state="$1" name="$2" target backend
  target="$(jq -c --arg n "$name" '.targets[$n] // empty' <<<"$state")"
  if [[ -z "$target" ]]; then
    _todo_err "no todo target \"$name\"; the targets are: $(_todo_names "$state") (bercail todo target list)"
    return 1
  fi
  backend="$(jq -r '.backend // ""' <<<"$target")"
  if [[ "$(jq -r '.from // ""' <<<"$target")" == config.toml ]]; then
    TODO_TARGET_FROM="[todo.$backend] in $BERCAIL_USER_CONFIG"
    _todo_source "$backend" || { _todo_err "unknown [todo] backend \"$backend\" in $BERCAIL_USER_CONFIG; bercail has: $(_todo_backends)"; return 1; }
  else
    TODO_TARGET_FROM="$(todo_targets_file)"
    _todo_source "$backend" || { _todo_err "todo target \"$name\" names backend \"$backend\", which bercail does not have (it has: $(_todo_backends))"; return 1; }
  fi
  # shellcheck disable=SC2034 # read by lib/todo/<backend>.sh
  TODO_TARGET="$name" TODO_BACKEND="$backend" TODO_TARGET_JSON="$target"
}

# The backend's OP, given at most SECONDS.
_todo_call() {
  local seconds="$1" op="$2" rc=0
  shift 2
  _git_backend_bounded "$seconds" "todo_${TODO_BACKEND}_$op" "$@" || rc=$?
  [[ "$rc" -ne 124 ]] || _todo_err "$TODO_BACKEND did not answer within ${seconds}s"
  return "$rc"
}

# The folder a route names: the main checkout of DIR, so a repo's worktrees
# route with it, else DIR itself.
_todo_repo_key() {
  git_backend_main "$1" 2>/dev/null || (cd "$1" 2>/dev/null && pwd -P)
}

# The target a todo goes to: EXPLICIT, else the route of REPO (a key from
# _todo_repo_key, or empty), else the default. With none, says what to run.
_todo_route() {
  local state="$1" explicit="$2" repo="$3" name
  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi
  name="$(jq -r --arg r "$repo" '(.routes[$r] // .default) // empty' <<<"$state")"
  [[ -z "$name" ]] || { printf '%s' "$name"; return 0; }
  if [[ "$(jq '.targets | length' <<<"$state")" -eq 0 ]]; then
    _todo_err "no todo target yet: bercail todo target add <name> <to-do list URL> (docs/config.md#todos)"
  else
    _todo_err "no todo target for ${repo:-a todo with no repo}: pass --target (the targets: $(_todo_names "$state")), route the repo (bercail todo route <repo> <target>), or set a default (bercail todo route --default <target>)"
  fi
  return 1
}

# The ledger's live entries for the loaded target: each todo bercail added
# that Shep has not marked done, as a JSON array.
_todo_ledger_open() {
  local file
  file="$(todo_ledger_file)"
  [[ -f "$file" ]] || { printf '[]'; return 0; }
  jq -ncR --arg t "$TODO_TARGET" '[inputs | fromjson? | select(type == "object" and (.target // "config") == $t and (.id | type) == "string")]
    | (map(select(.done)) | map(.id)) as $closed
    | map(select((.done | not) and (.id | IN($closed[]) | not))) | unique_by(.id)' "$file"
}

# The target bercail added todo ID (or its URL) to, from the ledger.
_todo_ledger_target() {
  local file id="${1%/}"
  id="${id##*/}"
  file="$(todo_ledger_file)"
  [[ -f "$file" ]] || return 0
  jq -nrR --arg id "$id" '[inputs | fromjson? | select(type == "object" and .id == $id and (.done | not))] | last | .target // empty' "$file"
}

_todo_ledger_add() {
  local file
  file="$(todo_ledger_file)"
  mkdir -p "$(dirname "$file")"
  jq -c "$@" >>"$file"
}

# bercail job (lib/jobs.ts), for a todo linked to a trail, trail:N.
_todo_job() {
  node "$(dirname "${BASH_SOURCE[0]}")/jobs.ts" "$@"
}

todo_add() {
  local title="" notes="" due="" issue="" repo="" target="" main="" state item line
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --notes) notes="${2:-}"; shift 2 || shift $# ;;
      --notes=*) notes="${1#*=}"; shift ;;
      --due) due="${2:-}"; shift 2 || shift $# ;;
      --due=*) due="${1#*=}"; shift ;;
      --issue) issue="${2:-}"; shift 2 || shift $# ;;
      --issue=*) issue="${1#*=}"; shift ;;
      --repo) repo="${2:-}"; shift 2 || shift $# ;;
      --repo=*) repo="${1#*=}"; shift ;;
      --target) target="${2:-}"; shift 2 || shift $# ;;
      --target=*) target="${1#*=}"; shift ;;
      --) [[ $# -eq 2 && -z "$title" ]] || { _todo_err "$TODO_USAGE (-- goes last, before the title)"; return 1; }; title="$2"; shift 2 ;;
      -*) _todo_err "$TODO_USAGE"; return 1 ;;
      *) [[ -z "$title" ]] || { _todo_err "$TODO_USAGE (quote the title)"; return 1; }; title="$1"; shift ;;
    esac
  done
  title="$(printf '%s' "$title" | tr '\n\t\r' '   ' | sed 's/  */ /g; s/^ //; s/ $//')"
  [[ -n "$title" ]] || { _todo_err "$TODO_USAGE"; return 1; }
  [[ -z "$due" || "$due" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { _todo_err "--due takes a date as YYYY-MM-DD"; return 1; }
  # The issue's repo is the one it was asked from when --repo does not name it.
  [[ -z "$issue" ]] || repo="${repo:-$PWD}"
  if [[ -n "$repo" ]]; then
    main="$(_todo_repo_key "$repo")" || { _todo_err "no folder $repo; pass the job's checkout with --repo"; return 1; }
  fi
  if [[ "$issue" =~ ^trail:[1-9][0-9]{0,8}$ ]]; then
    # Before the backend: a todo must not point at a trail that is not there.
    _todo_job show "$issue" --repo "$main" --json </dev/null >/dev/null 2>&1 \
      || { _todo_err "Entire has no $issue for $main (bercail job show $issue --repo $main); pass its checkout with --repo"; return 1; }
  elif [[ -n "$issue" ]]; then
    [[ "$issue" =~ ^[A-Za-z0-9._-]+$ ]] || { _todo_err "issue id '$issue' is neither a beads id nor a trail (trail:N)"; return 1; }
    # Before the backend: a todo must not point at an issue that is not there.
    (cd "$main" && bd show "$issue" --json </dev/null >/dev/null 2>&1) \
      || { _todo_err "bd does not know $issue in $main; pass its checkout with --repo"; return 1; }
  fi
  # The job is local to the person's machine: the backend's reader gets the id only as a last line.
  [[ -z "$issue" ]] || notes="${notes:+$notes$'\n\n'}bercail: $issue in $(basename "$main")"
  state="$(_todo_state)" || return 1
  target="$(_todo_route "$state" "$target" "$main")" || return 1
  _todo_use "$state" "$target" || return 1
  item="$(_todo_call "$TODO_TIMEOUT" add "$title" "$notes" "$due")" || return 1
  jq -e '(.id | type) == "string" and .id != ""' <<<"$item" >/dev/null 2>&1 \
    || { _todo_err "$TODO_BACKEND did not return the todo it made: $item"; return 1; }
  _todo_ledger_add -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg t "$TODO_TARGET" --arg b "$TODO_BACKEND" --argjson item "$item" \
    --arg issue "$issue" --arg repo "$main" \
    '{at: $at, target: $t, backend: $b, id: $item.id, url: $item.url, title: $item.title}
     + (if $issue == "" then {} else {issue: $issue, repo: $repo} end)'
  printf 'added to %s: %s\n' "$TODO_TARGET" "$(_todo_line "$item")"
  [[ -n "$issue" ]] || return 0
  line="bercail todo: \"$(jq -r .title <<<"$item")\" waits on the person in $TODO_BACKEND ($TODO_TARGET): $(jq -r '.url // "(no link)"' <<<"$item")"
  if [[ "$issue" == trail:* ]]; then
    if printf '%s' "$line" | _todo_job comment "$issue" --repo "$main" >/dev/null 2>&1; then
      printf 'linked on %s\n' "$issue"
    else
      _todo_err "added, but bercail could not comment on $issue in $main; add the link by hand: bercail job comment $issue --repo $main"
      return 1
    fi
  elif (cd "$main" && bd comment "$issue" "$line" </dev/null >/dev/null 2>&1); then
    printf 'linked on %s\n' "$issue"
  else
    _todo_err "added, but bd could not comment on $issue in $main; add the link by hand: bd comment $issue \"$line\""
    return 1
  fi
}

# One todo as a line: title, due date, link.
_todo_line() {
  jq -r '[.title, (if .due then "due \(.due)" else empty end), (.url // empty)] | join(" · ")' <<<"$1"
}

# The loaded target's open todos, each with the issue bercail linked it to, if any.
_todo_open_json() {
  local seconds="$1" items
  items="$(_todo_call "$seconds" list)" || return 1
  jq -c --argjson ledger "$(_todo_ledger_open)" '
    ($ledger | map({key: .id, value: .}) | from_entries) as $l
    | [.[] | . + ($l[.id] | if . then {issue, repo} else {} end | with_entries(select(.value)))]' <<<"$items"
}

# --target NAME, the one option list, show and done take besides theirs.
_todo_target_opt() {
  case "$1" in
    --target) [[ -n "${2:-}" ]] && printf '%s' "$2" ;;
    --target=*) printf '%s' "${1#*=}" ;;
    *) return 1 ;;
  esac
}

# Every target's open todos, grouped by target. One that does not answer is
# named on stderr, the others still listed, and the status is 1.
todo_list() {
  local json=0 only="" state name items rc=0 all='[]'
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      --target) only="${2:-}"; shift 2 || shift $# ;;
      --target=*) only="${1#*=}"; shift ;;
      *) _todo_err "usage: bercail todo list [--target NAME] [--json]"; return 1 ;;
    esac
  done
  state="$(_todo_state)" || return 1
  if [[ -z "$only" && "$(jq '.targets | length' <<<"$state")" -eq 0 ]]; then
    _todo_err "no todo target yet: bercail todo target add <name> <to-do list URL> (docs/config.md#todos)"
    return 1
  fi
  while IFS= read -r name; do
    _todo_use "$state" "$name" && items="$(_todo_open_json "$TODO_TIMEOUT")" || { rc=1; continue; }
    all="$(jq -c --arg t "$name" --argjson items "$items" '. + [$items[] | {target: $t} + .]' <<<"$all")"
    ((json)) || jq -r --arg t "$name" '"\($t):", if length == 0 then "- no open todos"
      else .[] | "- \(.id): " + ([.title, (if .due then "due \(.due)" else empty end), (.issue // empty), (.url // empty)] | join(" · ")) end' <<<"$items"
  done < <(if [[ -n "$only" ]]; then printf '%s\n' "$only"; else jq -r '.targets | keys[]' <<<"$state"; fi)
  ((json == 0)) || jq . <<<"$all"
  return "$rc"
}

# ID [--target NAME]: the todo's target is NAME, else the one bercail added it
# to, else the default.
_todo_for_id() {
  local id="" target="" state
  while [[ $# -gt 0 ]]; do
    if target="$(_todo_target_opt "$@")"; then
      if [[ "$1" == *=* ]]; then shift; else shift 2; fi
    elif [[ -z "$id" && "$1" != -* ]]; then
      id="$1"
      shift
    else
      return 2
    fi
  done
  [[ -n "$id" ]] || return 2
  state="$(_todo_state)" || return 1
  [[ -n "$target" ]] || target="$(_todo_ledger_target "$id")"
  target="$(_todo_route "$state" "$target" "")" || return 1
  _todo_use "$state" "$target" || return 1
  TODO_ID="$id"
}

todo_show() {
  local item rc=0
  _todo_for_id "$@" || rc=$?
  ((rc != 2)) || { _todo_err "usage: bercail todo show ID [--target NAME]"; return 1; }
  ((rc == 0)) || return 1
  item="$(_todo_call "$TODO_TIMEOUT" show "$TODO_ID")" || return 1
  jq -r --arg t "$TODO_TARGET" --argjson ledger "$(_todo_ledger_open)" '
    (.id as $id | $ledger | map(select(.id == $id)) | first) as $l
    | .title,
      (if .done then "done" else "open" end) + " in \($t)" + (if .due then " · due \(.due)" else "" end)
        + (if $l.issue then " · for \($l.issue)" else "" end),
      (.url // empty),
      (if (.notes // "") != "" then "", .notes else empty end)' <<<"$item"
}

# Completes the todo in the backend, and marks it done in the ledger so the
# board stops asking Shep to pick it up.
todo_done() {
  local item id rc=0
  _todo_for_id "$@" || rc=$?
  ((rc != 2)) || { _todo_err "usage: bercail todo done ID [--target NAME]"; return 1; }
  ((rc == 0)) || return 1
  item="$(_todo_call "$TODO_TIMEOUT" show "$TODO_ID")" || return 1
  id="$(jq -r .id <<<"$item")"
  if ! jq -e .done <<<"$item" >/dev/null; then
    _todo_call "$TODO_TIMEOUT" complete "$id" || return 1
  fi
  _todo_ledger_add -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg t "$TODO_TARGET" --arg b "$TODO_BACKEND" --arg id "$id" \
    '{at: $at, target: $t, backend: $b, id: $id, done: true}'
  printf 'done in %s: %s\n' "$TODO_TARGET" "$(_todo_line "$item")"
}

# --- targets and routes -----------------------------------------------------------

# Each target as {name, backend, label, url, default, routes, from, ...its
# fields}, sorted by name.
_todo_targets_view() {
  jq -c '. as $s | [.targets | to_entries[] | .key as $n
    | {name: $n} + .value + {default: ($s.default == $n),
        routes: [$s.routes | to_entries[] | select(.value == $n) | .key] | sort}]' <<<"$1"
}

# One target as text: name, backend and list, its link, and its routes.
TODO_TARGET_TEXT='def tilde: if startswith($home + "/") then "~" + .[($home | length):] else . end;
  def text: "- \(.name)\(if .default then " (default)" else "" end): \(.backend), "
    + (.label // (if .from == "config.toml" then "[todo.\(.backend)] in config.toml" else "?" end))
    + (if .url then " · \(.url)" else "" end)
    + (if (.routes | length) > 0 then " · routes \(.routes | map(tilde) | join(", "))" else "" end);'

todo_target_list() {
  local json=0 view
  case "${1:-}" in
    --json) json=1 ;;
    "") ;;
    *) _todo_err "usage: bercail todo target list [--json]"; return 1 ;;
  esac
  view="$(_todo_targets_view "$(_todo_state)")" || return 1
  if ((json)); then
    jq . <<<"$view"
    return 0
  fi
  jq -r --arg home "$HOME" "$TODO_TARGET_TEXT"'if length == 0
    then "no todo targets yet: bercail todo target add <name> <to-do list URL>"
    else (.[] | text), (if any(.default) then empty else "no default: a todo with no route needs --target (bercail todo route --default <target>)" end) end' <<<"$view"
}

todo_target_show() {
  local name="${1:-}" json=0 view
  case "$#:${2:-}" in
    1:) ;;
    2:--json) json=1 ;;
    *) name="" ;;
  esac
  [[ -n "$name" && "$name" != -* ]] || { _todo_err "usage: bercail todo target show NAME [--json]"; return 1; }
  view="$(_todo_targets_view "$(_todo_state)")" || return 1
  view="$(jq -c --arg n "$name" '.[] | select(.name == $n)' <<<"$view")"
  [[ -n "$view" ]] || { _todo_err "no todo target \"$name\" (bercail todo target list)"; return 1; }
  if ((json)); then
    jq . <<<"$view"
  else
    jq -r --arg home "$HOME" "$TODO_TARGET_TEXT"'text' <<<"$view"
  fi
}

# NAME URL: reads the list the URL names (or makes it, with --create) before
# anything is written, then keeps it as target NAME. Its routes stay.
todo_target_add() {
  local name="" url="" backend="" create="" json=0 b fields state
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend) backend="${2:-}"; shift 2 || shift $# ;;
      --backend=*) backend="${1#*=}"; shift ;;
      --create) create="${2:-}"; shift 2 || shift $# ;;
      --create=*) create="${1#*=}"; shift ;;
      --json) json=1; shift ;;
      -*) _todo_err "$TODO_TARGET_USAGE"; return 1 ;;
      *)
        if [[ -z "$name" ]]; then name="$1"; elif [[ -z "$url" ]]; then url="$1"; else _todo_err "$TODO_TARGET_USAGE"; return 1; fi
        shift ;;
    esac
  done
  [[ -n "$name" && -n "$url" ]] || { _todo_err "$TODO_TARGET_USAGE"; return 1; }
  [[ "$name" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] \
    || { _todo_err "a target name is 1-32 of a-z 0-9 - _, starting with a letter or digit: $name"; return 1; }
  [[ "$name" != config ]] \
    || { _todo_err "\"config\" is the list [todo] in config.toml names; pick another name"; return 1; }
  state="$(_todo_state)" || return 1
  if [[ -z "$backend" ]]; then
    for b in $(_todo_backends); do
      _todo_source "$b" && "todo_${b}_owns" "$url" && { backend="$b"; break; }
    done
    [[ -n "$backend" ]] || { _todo_err "no backend knows $url; name one with --backend (bercail has: $(_todo_backends))"; return 1; }
  fi
  _todo_source "$backend" || { _todo_err "unknown backend \"$backend\"; bercail has: $(_todo_backends)"; return 1; }
  # shellcheck disable=SC2034 # read by lib/todo/<backend>.sh
  TODO_TARGET="$name" TODO_BACKEND="$backend" TODO_TARGET_FROM="$(todo_targets_file)"
  fields="$(_todo_call "$TODO_TIMEOUT" target "$url" "$create")" || return 1
  jq -e 'type == "object"' <<<"$fields" >/dev/null 2>&1 \
    || { _todo_err "$backend did not describe the list: $fields"; return 1; }
  fields="$(jq -c --arg b "$backend" '{backend: $b} + del(.from, .backend)' <<<"$fields")"
  _todo_save --arg n "$name" --argjson t "$fields" '.targets[$n] = $t' || return 1
  if ((json)); then
    todo_target_show "$name" --json
  else
    printf '%s %s: %s\n' "$(jq -e --arg n "$name" '.targets[$n]' <<<"$state" >/dev/null && echo updated || echo added)" \
      "$name" "$(jq -r '"\(.backend), \(.label // "?")" + (if .url then " · \(.url)" else "" end)' <<<"$fields")"
  fi
}

todo_target_rm() {
  local name="${1:-}" state
  [[ $# -eq 1 && -n "$name" ]] || { _todo_err "usage: bercail todo target rm NAME"; return 1; }
  state="$(_todo_state)" || return 1
  [[ "$name" != config || "$(jq -r '.targets.config.from // ""' <<<"$state")" != config.toml ]] \
    || { _todo_err "\"config\" is [todo] in $BERCAIL_USER_CONFIG; delete [todo] and its table there to remove it"; return 1; }
  jq -e --arg n "$name" '.targets[$n]' <<<"$state" >/dev/null \
    || { _todo_err "no todo target \"$name\" (bercail todo target list)"; return 1; }
  _todo_save --arg n "$name" 'del(.targets[$n]) | .routes = ((.routes // {}) | with_entries(select(.value != $n)))
    | if .default == $n then del(.default) else . end' || return 1
  printf 'removed %s, and its routes\n' "$name"
}

todo_route() {
  local state key
  case "${1:-}" in
    --default)
      [[ $# -eq 2 ]] || { _todo_err "$TODO_ROUTE_USAGE"; return 1; }
      state="$(_todo_state)" || return 1
      _todo_use "$state" "$2" || return 1
      _todo_save --arg t "$2" '.default = $t' || return 1
      printf 'default: %s\n' "$2"
      ;;
    --rm)
      [[ $# -eq 2 ]] || { _todo_err "$TODO_ROUTE_USAGE"; return 1; }
      if [[ "$2" == --default ]]; then
        _todo_save 'del(.default)' || return 1
        printf 'no default\n'
        return 0
      fi
      key="$(_todo_repo_key "$2")" || key="$2"
      _todo_save --arg r "$key" 'if .routes then del(.routes[$r]) else . end' || return 1
      printf 'no route for %s\n' "$key"
      ;;
    -* | "") _todo_err "$TODO_ROUTE_USAGE"; return 1 ;;
    *)
      [[ $# -eq 2 ]] || { _todo_err "$TODO_ROUTE_USAGE"; return 1; }
      key="$(_todo_repo_key "$1")" || { _todo_err "no folder $1: route a repo's checkout"; return 1; }
      state="$(_todo_state)" || return 1
      _todo_use "$state" "$2" || return 1
      _todo_save --arg r "$key" --arg t "$2" '.routes[$r] = $t' || return 1
      printf '%s → %s\n' "$key" "$2"
      ;;
  esac
}

cmd_todo_target() {
  local op="${1:-}"
  shift || true
  case "$op" in
    add) todo_target_add "$@" ;;
    list) todo_target_list "$@" ;;
    show) todo_target_show "$@" ;;
    rm) todo_target_rm "$@" ;;
    *) _todo_err "$TODO_TARGET_USAGE"; return 1 ;;
  esac
}

# --- board and doctor ---------------------------------------------------------

# For Shep's board, as JSON: null without a target; else one entry per target,
# {target, error} when it cannot be read, or {target, backend, open, finished}:
# the open todos, and the ones bercail added that are no longer open there but
# Shep has not marked done. Read when the board is, so nothing polls.
todo_board_json() {
  local state names name dir i=0 n err
  state="$(_todo_state 2>&1)" || {
    jq -nc --arg e "$(sed 's/^bercail todo: //' <<<"$state" | head -c 300)" '[{error: $e}]'
    return 0
  }
  names="$(jq -r '.targets | keys[]' <<<"$state")"
  [[ -n "$names" ]] || { printf 'null'; return 0; }
  dir="$(mktemp -d)"
  while IFS= read -r name; do
    i=$((i + 1))
    (
      open=""
      _todo_use "$state" "$name" 2>"$dir/$i.err" && open="$(_todo_open_json "$TODO_BOARD_TIMEOUT" 2>"$dir/$i.err")" || true
      if [[ -z "$open" ]]; then
        err="$(sed 's/^bercail todo: //' "$dir/$i.err" | head -c 300 | tr '\n' ' ' | sed 's/ *$//')"
        jq -nc --arg t "$name" --arg e "${err:-the todo backend did not answer}" '{target: $t, error: $e}'
      else
        jq -nc --arg t "$name" --arg b "$TODO_BACKEND" --argjson open "$open" --argjson ledger "$(_todo_ledger_open)" '
          ([$open[].id]) as $ids
          | {target: $t, backend: $b, open: $open, finished: [$ledger[] | select(.id | IN($ids[]) | not)]}'
      fi
    ) >"$dir/$i.json" &
  done <<<"$names"
  wait
  for ((n = 1; n <= i; n++)); do cat "$dir/$n.json"; done | jq -sc .
  rm -rf "$dir"
}

# doctor's lines: one per target, whether its list answers; then a hint when
# config.toml still holds the old [todo] list. Never a failure: todos are
# optional.
doctor_todo() {
  local state name line errs legacy
  if ! state="$(_todo_state 2>&1)"; then
    log "  broken  todos: ${state#bercail todo: }"
    return 0
  fi
  if [[ "$(jq '.targets | length' <<<"$state")" -eq 0 ]]; then
    log "  --  todos: no target (bercail todo target add <name> <to-do list URL>; docs/config.md#todos)"
    return 0
  fi
  errs="$(mktemp)"
  while IFS= read -r name; do
    if ! _todo_use "$state" "$name" 2>"$errs"; then
      log "  unknown  todos $name: $(sed 's/^bercail todo: //' "$errs")"
      continue
    fi
    line="$(_todo_call 15 check 2>/dev/null)" || line=$'--\tdid not answer within 15s'
    log "  ${line%%$'\t'*}  todos $name: $TODO_BACKEND, ${line#*$'\t'}"
  done < <(jq -r '.targets | keys[]' <<<"$state")
  rm -f "$errs"
  legacy="$(jq -r '.targets.config | select(.from == "config.toml") | .backend' <<<"$state")"
  [[ -z "$legacy" ]] \
    || log "  hint  todos: \"config\" is [todo] in config.toml; move it: bercail todo target add <name> <its URL>, bercail todo route --default <name>, then delete [todo] and [todo.$legacy] from config.toml"
}

cmd_todo() {
  local op="${1:-}"
  shift || true
  case "$op" in
    add) todo_add "$@" ;;
    list) todo_list "$@" ;;
    show) todo_show "$@" ;;
    done) todo_done "$@" ;;
    target) cmd_todo_target "$@" ;;
    route) todo_route "$@" ;;
    *) _todo_err "$TODO_USAGE"; return 1 ;;
  esac
}
