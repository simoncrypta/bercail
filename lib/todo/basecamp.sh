#!/usr/bin/env bash
# shellcheck shell=bash
# bercail todo's Basecamp backend, through the basecamp CLI (0.30.0) and its
# --json envelope ({ok, data}). A target is one to-do list: its account,
# project and todolist, the numbers in its URL,
#
#   https://3.basecamp.com/<account>/buckets/<project>/todolists/<todolist>
#
# from bercail todo target add, or from [todo.basecamp] in config.toml.
#
# Sourced by lib/todo.sh, which defines the interface.

_todo_basecamp_bin() { printf '%s' "${BASECAMP_BIN:-basecamp}"; }

# The target's account, project and todolist, or a message naming them when
# one is not a number.
_todo_basecamp_conf() {
  local key value
  for key in account project todolist; do
    value="$(jq -r --arg k "$key" '.[$k] // "" | tostring' <<<"$TODO_TARGET_JSON")"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
      _todo_err "set account, project and todolist for todo target $TODO_TARGET ($TODO_TARGET_FROM): the numbers in its to-do list's URL, https://3.basecamp.com/<account>/buckets/<project>/todolists/<todolist>"
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

# The to-do lists Basecamp serves, on both of its hosts.
TODO_BASECAMP_URL='^https?://(3|app)\.basecamp\.com/([0-9]+)/'

todo_basecamp_owns() {
  [[ "$1" =~ $TODO_BASECAMP_URL ]]
}

# URL [CREATE]: the to-do list the URL names, read to prove the login sees it,
# as the target's fields. A project's or its to-dos' URL names no one list: with
# CREATE, a new list of that name is made there; without, the error lists them.
todo_basecamp_target() {
  local url="$1" create="${2:-}" project="" todoset="" list="" data lists
  local base='https?://(3|app)\.basecamp\.com/([0-9]+)' end='([/?#].*)?$'
  if [[ "$url" =~ ^$base/buckets/([0-9]+)/todolists/([0-9]+)$end ]]; then
    project="${BASH_REMATCH[3]}" list="${BASH_REMATCH[4]}"
  elif [[ "$url" =~ ^$base/buckets/([0-9]+)/todosets/([0-9]+)$end ]]; then
    project="${BASH_REMATCH[3]}" todoset="${BASH_REMATCH[4]}"
  elif [[ "$url" =~ ^$base/projects/([0-9]+)$end ]]; then
    project="${BASH_REMATCH[3]}"
  else
    _todo_err "$url is not a Basecamp to-do list: open the list and copy its URL, https://3.basecamp.com/<account>/buckets/<project>/todolists/<todolist>"
    return 1
  fi
  TODO_BASECAMP_ACCOUNT="${BASH_REMATCH[2]}"
  if [[ -n "$list" && -n "$create" ]]; then
    _todo_err "--create makes a list in a project: pass the project's To-dos URL (…/buckets/<project>/todosets/<id>), not a list's"
    return 1
  fi
  if [[ -z "$list" && -n "$create" ]]; then
    # The name is basecamp's argument: one that starts with - would be a flag.
    [[ "$create" != -* ]] || { _todo_err "a list name cannot start with -"; return 1; }
    data="$(_todo_basecamp todolists create "$create" --in "$project" ${todoset:+--todoset "$todoset"} </dev/null)" || return 1
    list="$(jq -r '.id // empty | tostring' <<<"$data")"
    [[ -n "$list" ]] || { _todo_err "basecamp todolists create did not return the list it made: $(head -c 200 <<<"$data")"; return 1; }
  fi
  if [[ -z "$list" ]]; then
    data="$(_todo_basecamp todolists list --in "$project" ${todoset:+--todoset "$todoset"} --all </dev/null)" || return 1
    lists="$(jq -r 'if type == "array" then .[] | "- \(.title // .name): \(.app_url)" else empty end' <<<"$data")"
    if [[ -n "$lists" ]]; then
      _todo_err "$url is a project's to-dos, not one list. Its lists:"$'\n'"$lists"$'\n'"Pass one of those URLs, or --create \"<list name>\" to make one there"
    else
      _todo_err "$url is a project's to-dos, not one list. It has no list yet; pass --create \"<list name>\" to make one there"
    fi
    return 1
  fi
  data="$(_todo_basecamp todolists show "$list" --in "$project" </dev/null)" || return 1
  jq -c --arg a "$TODO_BASECAMP_ACCOUNT" --arg p "$project" --arg l "$list" --arg url "$url" '
    {account: $a, project: $p, todolist: $l, url: (.app_url // $url),
     label: "to-do list \"\(.title // .name // $l)\" in \(.bucket.name // "project \($p)")"}' <<<"$data"
}

# Whether the target's list answers: installed, logged in (local), then a read
# of the list itself.
todo_basecamp_check() {
  local out data errs
  if ! command -v "$(_todo_basecamp_bin)" >/dev/null 2>&1; then
    printf 'missing\tthe basecamp CLI is not installed (https://github.com/basecamp/basecamp-cli)\n'
    return 0
  fi
  if ! _todo_basecamp_conf 2>/dev/null; then
    printf 'incomplete\taccount, project and todolist are not all numbers (%s; docs/config.md#todos)\n' "$TODO_TARGET_FROM"
    return 0
  fi
  out="$("$(_todo_basecamp_bin)" auth status --json 2>/dev/null </dev/null)" || out=""
  if ! jq -e '.data.authenticated == true' <<<"$out" >/dev/null 2>&1; then
    printf -- '--\tnot logged in (you run: basecamp auth login --device-code)\n'
    return 0
  fi
  errs="$(mktemp)"
  if data="$(_todo_basecamp todolists show "$TODO_BASECAMP_TODOLIST" --in "$TODO_BASECAMP_PROJECT" </dev/null 2>"$errs")"; then
    jq -r --arg l "$TODO_BASECAMP_TODOLIST" '"ok\tlogged in; to-do list \"\(.title // .name // $l)\" in \(.bucket.name // "its project")"' <<<"$data"
  else
    printf 'unreachable\tlogged in, but to-do list %s does not answer: %s\n' "$TODO_BASECAMP_TODOLIST" "$(sed 's/^bercail todo: //' "$errs" | tr '\n' ' ' | sed 's/ *$//')"
  fi
  rm -f "$errs"
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
