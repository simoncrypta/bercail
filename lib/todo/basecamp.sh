#!/usr/bin/env bash
# shellcheck shell=bash
# bercail todo's Basecamp backend, through the basecamp CLI (0.30.0) and its
# --json envelope ({ok, data}). Todos go to one to-do list, named in
# config.toml:
#
#   [todo.basecamp]
#   account = "1234567"    # https://3.basecamp.com/<account>/buckets/<project>/todolists/<todolist>
#   project = "2345678"
#   todolist = "3456789"
#
# Sourced by lib/todo.sh, which defines the interface.

_todo_basecamp_bin() { printf '%s' "${BASECAMP_BIN:-basecamp}"; }

# [todo.basecamp] KEY, or a message naming the keys when one is not a number.
_todo_basecamp_conf() {
  local key value
  for key in account project todolist; do
    value="$(toml_value "$BERCAIL_USER_CONFIG" todo.basecamp "$key")"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
      _todo_err "set account, project and todolist under [todo.basecamp] in $BERCAIL_USER_CONFIG: the numbers in your to-do list's URL, https://3.basecamp.com/<account>/buckets/<project>/todolists/<todolist>"
      return 1
    fi
    printf -v "TODO_BASECAMP_${key^^}" '%s' "$value"
  done
}

# basecamp ARGS on the configured account; prints the envelope's data. Its
# error, when it fails, goes to stderr in one line.
_todo_basecamp() {
  local out errs why rc=0
  errs="$(mktemp)"
  out="$("$(_todo_basecamp_bin)" "$@" --account "$TODO_BASECAMP_ACCOUNT" --json 2>"$errs")" || rc=$?
  if ((rc == 0)) && jq -e 'type == "object" and .ok != false and has("data")' <<<"$out" >/dev/null 2>&1; then
    rm -f "$errs"
    jq -c .data <<<"$out"
    return 0
  fi
  why="$(jq -r '.error.message? // .error? // .message? // .summary? // empty | strings' <<<"$out" 2>/dev/null)" || why=""
  [[ -n "$why" ]] || why="$(cat "$errs")"
  rm -f "$errs"
  _todo_err "basecamp $1 $2 failed: $(printf '%s' "${why:-exit $rc}" | head -c 300 | tr '\n' ' ')"
  return 1
}

# A Basecamp todo as bercail's {id, title, notes, due, done, url}. Notes come
# back as HTML: tags dropped, the common entities decoded.
TODO_BASECAMP_ITEM='def item: {id: (.id | tostring), title: (.title // .content // ""),
  notes: ((.description // "") | gsub("<br\\s*/?>|</(p|div|li)>"; "\n") | gsub("<[^>]*>"; "")
    | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&quot;"; "\"") | gsub("&#39;"; "'"'"'") | gsub("&nbsp;"; " ")
    | gsub("&amp;"; "&") | sub("\n+$"; "")),
  due: .due_on, done: (.completed == true), url: .app_url};'

todo_basecamp_check() {
  local out
  if ! command -v "$(_todo_basecamp_bin)" >/dev/null 2>&1; then
    printf 'missing\tthe basecamp CLI is not installed (https://github.com/basecamp/basecamp-cli)\n'
    return 0
  fi
  if ! _todo_basecamp_conf 2>/dev/null; then
    printf 'incomplete\tset account, project and todolist under [todo.basecamp] (docs/config.md#todos)\n'
    return 0
  fi
  # Local: --check would ask the server.
  out="$("$(_todo_basecamp_bin)" auth status --json 2>/dev/null </dev/null)" || out=""
  if jq -e '.data.authenticated == true' <<<"$out" >/dev/null 2>&1; then
    printf 'ok\tlogged in; to-do list %s in project %s\n' "$TODO_BASECAMP_TODOLIST" "$TODO_BASECAMP_PROJECT"
  else
    printf -- '--\tnot logged in (you run: basecamp auth login --device-code)\n'
  fi
}

todo_basecamp_add() {
  local title="$1" notes="$2" due="$3" data
  local -a args
  _todo_basecamp_conf || return 1
  # basecamp reads a description of - from stdin, where the title is.
  [[ "$notes" != - ]] || { _todo_err "--notes cannot be just -"; return 1; }
  args=(todos create - --in "$TODO_BASECAMP_PROJECT" --list "$TODO_BASECAMP_TODOLIST")
  # --flag=value: a value that starts with - stays a value.
  [[ -z "$notes" ]] || args+=("--description=$notes")
  [[ -z "$due" ]] || args+=("--due=$due")
  # The title on stdin, as basecamp's - asks: never read as a flag.
  data="$(printf '%s' "$title" | _todo_basecamp "${args[@]}")" || return 1
  jq -c "$TODO_BASECAMP_ITEM"'item' <<<"$data"
}

todo_basecamp_list() {
  local data
  _todo_basecamp_conf || return 1
  data="$(_todo_basecamp todos list --in "$TODO_BASECAMP_PROJECT" --list "$TODO_BASECAMP_TODOLIST" --all </dev/null)" || return 1
  # Not a list: an empty one would make the board call every todo done.
  jq -e 'type == "array"' <<<"$data" >/dev/null 2>&1 \
    || { _todo_err "basecamp todos list did not return a list: $(head -c 200 <<<"$data")"; return 1; }
  jq -c "$TODO_BASECAMP_ITEM"'[.[] | item | select(.done | not)]' <<<"$data"
}

# ID: a todo id, or its Basecamp URL.
todo_basecamp_show() {
  local data
  _todo_basecamp_conf || return 1
  data="$(_todo_basecamp todos show "$1" --no-comments </dev/null)" || return 1
  jq -c "$TODO_BASECAMP_ITEM"'item' <<<"$data"
}

todo_basecamp_complete() {
  _todo_basecamp_conf || return 1
  _todo_basecamp todos complete "$1" </dev/null >/dev/null
}
