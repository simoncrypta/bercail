#!/usr/bin/env bash
# shellcheck shell=bash
# bercail todo: what only the person can do (a login, a vault, a device), in
# the todo tool they already read. [todo] backend in config.toml picks one;
# lib/todo/<backend>.sh defines todo_<backend>_check, _add, _list, _show and
# _complete. Callers go through _todo_call, so a new backend touches no caller.
#
#   bercail todo add "TITLE" [--notes TEXT] [--due YYYY-MM-DD] [--issue ID] [--repo DIR]
#   bercail todo list [--json]
#   bercail todo show ID
#   bercail todo done ID
#
# A backend prints a todo, or an array of them, as JSON:
#   {id, title, notes, due, done, url}   (id a string, due YYYY-MM-DD or null)
# and its check prints one "STATUS<TAB>TEXT" line for doctor (STATUS: ok,
# missing, incomplete, or --), never a token.

# shellcheck source=lib/git-backend.sh
source "$(dirname "${BASH_SOURCE[0]}")/git-backend.sh"

TODO_USAGE='usage: bercail todo add "TITLE" [--notes TEXT] [--due YYYY-MM-DD] [--issue ID] [--repo DIR] | list [--json] | show ID | done ID'
# Seconds a backend call may take; the board gives it less (Shep's compaction
# gives the whole board 60).
TODO_TIMEOUT=30
TODO_BOARD_TIMEOUT=10

_todo_err() {
  printf 'bercail todo: %s\n' "$*" >&2
}

# One JSON line per todo bercail added ({at, backend, id, url, title, issue,
# repo}), and one per todo Shep marked done ({at, backend, id, done: true}).
todo_ledger_file() {
  printf '%s/bercail/todos.jsonl' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# The backends this bercail has, space-separated.
_todo_backends() {
  local f names=()
  for f in "$(dirname "${BASH_SOURCE[0]}")"/todo/*.sh; do
    [[ -f "$f" ]] && names+=("$(basename "$f" .sh)")
  done
  printf '%s' "${names[*]}"
}

# [todo] backend, loaded into TODO_BACKEND. Fails, saying why, when it is not
# set or names no backend this bercail has.
_todo_load() {
  local name file
  name="$(toml_value "$BERCAIL_USER_CONFIG" todo backend)"
  if [[ -z "$name" ]]; then
    _todo_err "no todo backend: set [todo] backend = \"basecamp\" in $BERCAIL_USER_CONFIG (docs/config.md#todos)"
    return 1
  fi
  file="$(dirname "${BASH_SOURCE[0]}")/todo/$name.sh"
  if [[ ! "$name" =~ ^[a-z0-9_]+$ || ! -f "$file" ]]; then
    _todo_err "unknown [todo] backend \"$name\" in $BERCAIL_USER_CONFIG; bercail has: $(_todo_backends)"
    return 1
  fi
  # shellcheck source=/dev/null
  source "$file"
  TODO_BACKEND="$name"
}

# The backend's OP, given at most SECONDS.
_todo_call() {
  local seconds="$1" op="$2" rc=0
  shift 2
  _git_backend_bounded "$seconds" "todo_${TODO_BACKEND}_$op" "$@" || rc=$?
  [[ "$rc" -ne 124 ]] || _todo_err "$TODO_BACKEND did not answer within ${seconds}s"
  return "$rc"
}

# The ledger's live entries for this backend: each todo bercail added that Shep
# has not marked done, as a JSON array.
_todo_ledger_open() {
  local file
  file="$(todo_ledger_file)"
  [[ -f "$file" ]] || { printf '[]'; return 0; }
  jq -ncR --arg b "$TODO_BACKEND" '[inputs | fromjson? | select(type == "object" and .backend == $b and (.id | type) == "string")]
    | (map(select(.done)) | map(.id)) as $closed
    | map(select((.done | not) and (.id | IN($closed[]) | not))) | unique_by(.id)' "$file"
}

_todo_ledger_add() {
  local file
  file="$(todo_ledger_file)"
  mkdir -p "$(dirname "$file")"
  jq -c "$@" >>"$file"
}

todo_add() {
  local title="" notes="" due="" issue="" repo="" main="" item line
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
      --) [[ $# -eq 2 && -z "$title" ]] || { _todo_err "$TODO_USAGE (-- goes last, before the title)"; return 1; }; title="$2"; shift 2 ;;
      -*) _todo_err "$TODO_USAGE"; return 1 ;;
      *) [[ -z "$title" ]] || { _todo_err "$TODO_USAGE (quote the title)"; return 1; }; title="$1"; shift ;;
    esac
  done
  title="$(printf '%s' "$title" | tr '\n\t\r' '   ' | sed 's/  */ /g; s/^ //; s/ $//')"
  [[ -n "$title" ]] || { _todo_err "$TODO_USAGE"; return 1; }
  [[ -z "$due" || "$due" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { _todo_err "--due takes a date as YYYY-MM-DD"; return 1; }
  [[ -z "$repo" || -n "$issue" ]] || { _todo_err "--repo names the checkout of --issue; pass both"; return 1; }
  if [[ -n "$issue" ]]; then
    [[ "$issue" =~ ^[A-Za-z0-9._-]+$ ]] || { _todo_err "issue id '$issue' has characters a beads id does not"; return 1; }
    repo="${repo:-$PWD}"
    main="$(git_backend_main "$repo")" || main="$(cd "$repo" 2>/dev/null && pwd -P)" \
      || { _todo_err "no folder $repo; pass the issue's checkout with --repo"; return 1; }
    # Before the backend: a todo must not point at an issue that is not there.
    (cd "$main" && bd show "$issue" --json </dev/null >/dev/null 2>&1) \
      || { _todo_err "bd does not know $issue in $main; pass its checkout with --repo"; return 1; }
    # Beads is local: the backend's reader gets the id only as a last line.
    notes="${notes:+$notes$'\n\n'}bercail: $issue in $(basename "$main")"
  fi
  _todo_load || return 1
  item="$(_todo_call "$TODO_TIMEOUT" add "$title" "$notes" "$due")" || return 1
  jq -e '(.id | type) == "string" and .id != ""' <<<"$item" >/dev/null 2>&1 \
    || { _todo_err "$TODO_BACKEND did not return the todo it made: $item"; return 1; }
  _todo_ledger_add -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg b "$TODO_BACKEND" --argjson item "$item" \
    --arg issue "$issue" --arg repo "$main" \
    '{at: $at, backend: $b, id: $item.id, url: $item.url, title: $item.title}
     + (if $issue == "" then {} else {issue: $issue, repo: $repo} end)'
  printf 'added: %s\n' "$(_todo_line "$item")"
  [[ -n "$issue" ]] || return 0
  line="bercail todo: \"$(jq -r .title <<<"$item")\" waits on the person in $TODO_BACKEND: $(jq -r '.url // "(no link)"' <<<"$item")"
  if (cd "$main" && bd comment "$issue" "$line" </dev/null >/dev/null 2>&1); then
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

# The open todos, each with the issue bercail linked it to, if any.
_todo_open_json() {
  local seconds="$1" items
  items="$(_todo_call "$seconds" list)" || return 1
  jq -c --argjson ledger "$(_todo_ledger_open)" '
    ($ledger | map({key: .id, value: .}) | from_entries) as $l
    | [.[] | . + ($l[.id] | if . then {issue, repo} else {} end | with_entries(select(.value)))]' <<<"$items"
}

todo_list() {
  local json=0 items
  case "${1:-}" in
    --json) json=1 ;;
    "") ;;
    *) _todo_err "usage: bercail todo list [--json]"; return 1 ;;
  esac
  _todo_load || return 1
  items="$(_todo_open_json "$TODO_TIMEOUT")" || return 1
  if ((json)); then
    jq . <<<"$items"
    return 0
  fi
  jq -r 'if length == 0 then "no open todos"
    else .[] | "- \(.id): " + ([.title, (if .due then "due \(.due)" else empty end), (.issue // empty), (.url // empty)] | join(" · ")) end' <<<"$items"
}

todo_show() {
  local id="${1:-}" item
  [[ $# -eq 1 && -n "$id" ]] || { _todo_err "usage: bercail todo show ID"; return 1; }
  _todo_load || return 1
  item="$(_todo_call "$TODO_TIMEOUT" show "$id")" || return 1
  jq -r --argjson ledger "$(_todo_ledger_open)" '
    (.id as $id | $ledger | map(select(.id == $id)) | first) as $l
    | .title,
      (if .done then "done" else "open" end) + (if .due then " · due \(.due)" else "" end)
        + (if $l.issue then " · for \($l.issue)" else "" end),
      (.url // empty),
      (if (.notes // "") != "" then "", .notes else empty end)' <<<"$item"
}

# Completes the todo in the backend, and marks it done in the ledger so the
# board stops asking Shep to pick it up.
todo_done() {
  local id="${1:-}" item
  [[ $# -eq 1 && -n "$id" ]] || { _todo_err "usage: bercail todo done ID"; return 1; }
  _todo_load || return 1
  item="$(_todo_call "$TODO_TIMEOUT" show "$id")" || return 1
  id="$(jq -r .id <<<"$item")"
  if ! jq -e .done <<<"$item" >/dev/null; then
    _todo_call "$TODO_TIMEOUT" complete "$id" || return 1
  fi
  _todo_ledger_add -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg b "$TODO_BACKEND" --arg id "$id" \
    '{at: $at, backend: $b, id: $id, done: true}'
  printf 'done: %s\n' "$(_todo_line "$item")"
}

# For Shep's board, as JSON: null without a backend; else {error} when it
# cannot be read, or {backend, open, finished}: the open todos, and
# the ones bercail added that are no longer open there but Shep has not marked
# done. Read when the board is, so nothing polls.
todo_board_json() {
  local open="" errs err
  [[ -n "$(toml_value "$BERCAIL_USER_CONFIG" todo backend)" ]] || { printf 'null'; return 0; }
  errs="$(mktemp)"
  _todo_load 2>"$errs" && open="$(_todo_open_json "$TODO_BOARD_TIMEOUT" 2>"$errs")" || true
  err="$(sed 's/^bercail todo: //' "$errs" | head -c 300 | tr '\n' ' ' | sed 's/ *$//')"
  rm -f "$errs"
  if [[ -z "$open" ]]; then
    jq -nc --arg e "${err:-the todo backend did not answer}" '{error: $e}'
    return 0
  fi
  jq -nc --arg b "$TODO_BACKEND" --argjson open "$open" --argjson ledger "$(_todo_ledger_open)" '
    ([$open[].id]) as $ids
    | {backend: $b, open: $open, finished: [$ledger[] | select(.id | IN($ids[]) | not)]}'
}

# doctor's line: the backend and whether it can reach the person's list.
# Never a failure: todos are optional.
doctor_todo() {
  local name line
  name="$(toml_value "$BERCAIL_USER_CONFIG" todo backend)"
  if [[ -z "$name" ]]; then
    log "  --  todos: no backend ([todo] backend in config.toml; docs/config.md#todos)"
    return 0
  fi
  if ! _todo_load 2>/dev/null; then
    log "  unknown  todo backend \"$name\" ([todo] backend in config.toml; bercail has: $(_todo_backends))"
    return 0
  fi
  line="$(_todo_call 15 check 2>/dev/null)" || line=$'--\tdid not answer within 15s'
  log "  ${line%%$'\t'*}  todos: $TODO_BACKEND, ${line#*$'\t'}"
}

cmd_todo() {
  local op="${1:-}"
  shift || true
  case "$op" in
    add) todo_add "$@" ;;
    list) todo_list "$@" ;;
    show) todo_show "$@" ;;
    done) todo_done "$@" ;;
    *) _todo_err "$TODO_USAGE"; return 1 ;;
  esac
}
