#!/usr/bin/env bats
# bercail todo: what only the person can do, through the configured backend.
# A basecamp stand-in keeps its todos in a JSON file; bd and hc stand-ins; a
# temp HOME. Nothing reaches Basecamp.

setup() {
  load test_helper
  isolate
  set -o pipefail
  export LOG="$BATS_TEST_TMPDIR/log" BC_DATA="$BATS_TEST_TMPDIR/bc" HC_DATA="$BATS_TEST_TMPDIR/hc"
  export HERDR_APP_BIN="$BATS_TEST_TMPDIR/no-herdr-app"
  export PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
  mkdir -p "$BC_DATA" "$HC_DATA" "$HOME/Work" "$XDG_CONFIG_HOME/bercail" "$XDG_STATE_HOME/bercail/shep"
  CONFIG="$XDG_CONFIG_HOME/bercail/config.toml"
  LEDGER="$XDG_STATE_HOME/bercail/todos.jsonl"
  printf '[]\n' >"$BC_DATA/todos.json"
  printf '{"ok":true,"data":{"authenticated":true,"base_url":"https://3.basecampapi.com","token":"SECRET-TOKEN-123"}}\n' >"$BC_DATA/auth.json"
  printf '{"terminals":[]}\n' >"$HC_DATA/ls.json"

  # basecamp: todos in $BC_DATA/todos.json as Basecamp's API has them, in its
  # --json envelope. $BC_DATA/fail makes every call fail with that message.
  cat >"$BATS_TEST_TMPDIR/bin/basecamp" <<'EOF'
#!/usr/bin/env bash
printf 'basecamp %s\n' "$*" >>"$LOG"
db="$BC_DATA/todos.json"
if [[ -f "$BC_DATA/fail" ]]; then
  jq -nc --arg m "$(cat "$BC_DATA/fail")" '{ok: false, error: {message: $m}}'
  exit 1
fi
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && printf '%s' "${a#*=}"; done; }
case "$1 $2" in
  "auth status") cat "$BC_DATA/auth.json" ;;
  "todos create")
    title="$(cat)"
    printf 'stdin %s\n' "$title" >>"$LOG"
    id=$((900 + $(jq length "$db")))
    jq --arg t "$title" --arg d "$(arg --description "$@")" --arg due "$(arg --due "$@")" --argjson id "$id" \
      '. + [{id: $id, content: $t, title: $t, description: (if $d == "" then "" else "<div>\($d | gsub("\n"; "<br>"))</div>" end),
             due_on: (if $due == "" then null else $due end), completed: false,
             app_url: "https://3.basecamp.com/1/buckets/2/todos/\($id)"}]' "$db" >"$db.tmp" && mv "$db.tmp" "$db"
    jq -c --argjson id "$id" '{ok: true, data: (.[] | select(.id == $id))}' "$db" ;;
  "todos list")
    [[ ! -f "$BC_DATA/list-object" ]] || { printf '{"ok":true,"data":{"todos":[]}}\n'; exit 0; }
    jq -c '{ok: true, data: map(select(.completed | not))}' "$db" ;;
  "todos show")
    jq -ce --argjson id "${3##*/}" '{ok: true, data: (.[] | select(.id == $id))}' "$db" \
      || { printf '{"ok":false,"error":{"message":"Todo not found"}}\n'; exit 1; } ;;
  "todos complete")
    jq --argjson id "$3" 'map(if .id == $id then .completed = true else . end)' "$db" >"$db.tmp" && mv "$db.tmp" "$db"
    printf '{"ok":true,"data":{}}\n' ;;
  *) exit 2 ;;
esac
EOF
  # bd answers show and comments from .beads/fake in the repo it runs in, and logs comment.
  cat >"$BATS_TEST_TMPDIR/bin/bd" <<'EOF'
#!/usr/bin/env bash
printf 'bd %s in %s\n' "$*" "$PWD" >>"$LOG"
dir="$PWD/.beads/fake"
case "$1" in
  list) cat "$dir/list.json" 2>/dev/null || exit 1 ;;
  show) cat "$dir/$2.json" 2>/dev/null || exit 1 ;;
  comments) cat "$dir/$2.comments.json" 2>/dev/null || printf '[]\n' ;;
  comment) jq -n --arg t "$3" '{author: "bercail", created_at: "2026-11-15T12:00:00Z", text: $t}' >>"$dir/$2.added" ;;
  *) exit 2 ;;
esac
EOF
  cat >"$BATS_TEST_TMPDIR/bin/hc" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ls) cat "$HC_DATA/ls.json" ;;
  *) exit 5 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  : >"$LOG"
}

todo() { "$ROOT/bin/bercail" todo "$@"; }

basecamp_config() {
  cat >"$CONFIG" <<'EOF'
[todo]
backend = "basecamp"

[todo.basecamp]
account = "111"
project = "222"
todolist = "333"
EOF
}

# A main checkout at ~/Work/$1 with beads issue $2 titled $3.
repo_with_issue() {
  local dir="$HOME/Work/$1"
  git init -q -b main "$dir"
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  mkdir -p "$dir/.beads/fake"
  jq -n --arg id "$2" --arg t "$3" '{id: $id, title: $t, status: "open", labels: []}' >"$dir/.beads/fake/$2.json"
  jq -n --arg id "$2" --arg t "$3" '[{id: $id, title: $t, status: "in_progress", labels: []}]' >"$dir/.beads/fake/list.json"
}

@test "todo add, list, show and done go through the backend to the configured Basecamp list" {
  local out
  basecamp_config
  out="$(todo add --notes "Log in at the admin page" --due 2026-11-20 -- "--create the tailnet login")" || fail "add: $out"
  [[ "$out" == "added: --create the tailnet login · due 2026-11-20 · https://3.basecamp.com/1/buckets/2/todos/900" ]] || fail "add: $out"
  grep -qx 'basecamp todos create - --in 222 --list 333 --description=Log in at the admin page --due=2026-11-20 --account 111 --json' "$LOG" \
    || fail "create argv: $(cat "$LOG")"
  grep -qx 'stdin --create the tailnet login' "$LOG" || fail "the title did not go on stdin: $(cat "$LOG")"
  todo add "Plug in the Zigbee stick" >/dev/null || fail "second add"

  out="$(todo list)" || fail "list: $out"
  [[ "$out" == "- 900: --create the tailnet login · due 2026-11-20 · https://3.basecamp.com/1/buckets/2/todos/900
- 901: Plug in the Zigbee stick · https://3.basecamp.com/1/buckets/2/todos/901" ]] || fail "list: $out"
  grep -q 'basecamp todos list --in 222 --list 333 --all --account 111 --json' "$LOG" || fail "list argv: $(cat "$LOG")"
  [[ "$(todo list --json | jq -c '.[0]')" == '{"id":"900","title":"--create the tailnet login","notes":"Log in at the admin page","due":"2026-11-20","done":false,"url":"https://3.basecamp.com/1/buckets/2/todos/900"}' ]] \
    || fail "list --json: $(todo list --json)"

  out="$(todo show https://3.basecamp.com/1/buckets/2/todos/900)" || fail "show: $out"
  [[ "$out" == "--create the tailnet login
open · due 2026-11-20
https://3.basecamp.com/1/buckets/2/todos/900

Log in at the admin page" ]] || fail "show: $out"

  out="$(todo "done" 900)" || fail "done: $out"
  [[ "$out" == "done: --create the tailnet login · due 2026-11-20 · https://3.basecamp.com/1/buckets/2/todos/900" ]] || fail "done: $out"
  grep -qx 'basecamp todos complete 900 --account 111 --json' "$LOG" || fail "complete argv: $(cat "$LOG")"
  [[ "$(todo list)" == "- 901: Plug in the Zigbee stick · https://3.basecamp.com/1/buckets/2/todos/901" ]] || fail "after done: $(todo list)"
  [[ "$(jq -sc 'map({id, done}) ' "$LEDGER")" == '[{"id":"900","done":null},{"id":"901","done":null},{"id":"900","done":true}]' ]] \
    || fail "ledger: $(cat "$LEDGER")"
}

@test "todo add --issue comments the todo's link on the issue, and puts the id only in the notes' last line" {
  local out comment
  basecamp_config
  repo_with_issue app app-7 "Put the HA box on the tailnet"
  out="$(cd "$BATS_TEST_TMPDIR" && todo add "Create the tailnet login" --issue app-7 --repo "$HOME/Work/app")" || fail "add: $out"
  [[ "$out" == "added: Create the tailnet login · https://3.basecamp.com/1/buckets/2/todos/900
linked on app-7" ]] || fail "add: $out"
  comment="$(jq -r .text "$HOME/Work/app/.beads/fake/app-7.added")"
  [[ "$comment" == 'bercail todo: "Create the tailnet login" waits on the person in basecamp: https://3.basecamp.com/1/buckets/2/todos/900' ]] \
    || fail "comment: $comment"
  [[ "$(jq -r '.[0].title' "$BC_DATA/todos.json")" == "Create the tailnet login" ]] || fail "the title carries more than the title"
  [[ "$(todo list --json | jq -r '.[0].notes')" == "bercail: app-7 in app" ]] || fail "notes: $(todo list --json)"
  [[ "$(todo list)" == "- 900: Create the tailnet login · app-7 · https://3.basecamp.com/1/buckets/2/todos/900" ]] || fail "list: $(todo list)"
}

@test "todo add --issue for an issue bd does not know writes nothing to Basecamp" {
  local out
  basecamp_config
  repo_with_issue app app-7 "Put the HA box on the tailnet"
  out="$(cd "$HOME/Work/app" && todo add "Create the login" --issue app-9 2>&1)" && fail "an unknown issue passed: $out"
  [[ "$out" == "bercail todo: bd does not know app-9 in $(cd "$HOME/Work/app" && pwd -P); pass its checkout with --repo" ]] || fail "error: $out"
  ! grep -q '^basecamp' "$LOG" || fail "basecamp ran: $(cat "$LOG")"
  [[ ! -e "$LEDGER" ]] || fail "the ledger has an entry: $(cat "$LEDGER")"
}

@test "an unknown or missing backend, and an incomplete Basecamp config, fail clearly and run nothing" {
  local out
  out="$(todo list 2>&1)" && fail "no backend passed: $out"
  [[ "$out" == "bercail todo: no todo backend: set [todo] backend = \"basecamp\" in $CONFIG (docs/config.md#todos)" ]] || fail "none: $out"
  printf '[todo]\nbackend = "linear"\n' >"$CONFIG"
  out="$(todo add "Do it" 2>&1)" && fail "an unknown backend passed: $out"
  [[ "$out" == "bercail todo: unknown [todo] backend \"linear\" in $CONFIG; bercail has: basecamp" ]] || fail "unknown: $out"
  printf '[todo]\nbackend = "../todo"\n' >"$CONFIG"
  out="$(todo list 2>&1)" && fail "a path as backend passed: $out"
  [[ "$out" == *'unknown [todo] backend "../todo"'* ]] || fail "path: $out"
  printf '[todo]\nbackend = "basecamp"\n[todo.basecamp]\naccount = "111"\n' >"$CONFIG"
  out="$(todo add "Do it" 2>&1)" && fail "an incomplete config passed: $out"
  [[ "$out" == "bercail todo: set account, project and todolist under [todo.basecamp]"* ]] || fail "incomplete: $out"
  ! grep -q '^basecamp' "$LOG" || fail "basecamp ran: $(cat "$LOG")"
  basecamp_config
  out="$(todo add "Do it" --notes - 2>&1)" && fail "notes of - passed: $out"
  [[ "$out" == "bercail todo: --notes cannot be just -" ]] || fail "notes -: $out"
  ! grep -q '^basecamp' "$LOG" || fail "basecamp ran: $(cat "$LOG")"
  out="$(todo frobnicate 2>&1)" && fail "an unknown subcommand passed"
  [[ "$out" == "bercail todo: usage: bercail todo add"* ]] || fail "usage: $out"
}

@test "a Basecamp error reaches the person in one line, and nothing is recorded" {
  local out
  basecamp_config
  printf 'Not logged in to https://3.basecampapi.com' >"$BC_DATA/fail"
  out="$(todo add "Do it" 2>&1)" && fail "a failed create passed: $out"
  [[ "$out" == "bercail todo: basecamp todos create failed: Not logged in to https://3.basecampapi.com" ]] || fail "error: $out"
  [[ ! -e "$LEDGER" ]] || fail "the ledger has an entry: $(cat "$LEDGER")"
}

@test "shep board shows open todos under what waits on the person, then the done ones until Shep marks them done" {
  local out
  basecamp_config
  repo_with_issue app app-7 "Put the HA box on the tailnet"
  printf '%s\n' "$HOME/Work/app" >"$XDG_STATE_HOME/bercail/shep/repos"
  todo add "Create the tailnet login" --issue app-7 --repo "$HOME/Work/app" >/dev/null || fail "add"
  todo add "Plug in the Zigbee stick" --due 2026-11-20 >/dev/null || fail "add"
  out="$("$ROOT/bin/bercail" shep board)" || fail "board: $out"
  [[ "$(sed -n '/^Waiting on the person:/,$p' <<<"$out")" == "Waiting on the person:
- todo for app-7: Create the tailnet login · open in basecamp · https://3.basecamp.com/1/buckets/2/todos/900
- todo: Plug in the Zigbee stick · due 2026-11-20 · open in basecamp · https://3.basecamp.com/1/buckets/2/todos/901" ]] \
    || fail "board: $out"
  # The person ticks it off in Basecamp.
  jq 'map(.completed = (.id == 900))' "$BC_DATA/todos.json" >"$BC_DATA/t" && mv "$BC_DATA/t" "$BC_DATA/todos.json"
  out="$("$ROOT/bin/bercail" shep board)" || fail "board: $out"
  grep -qx -- '- todo for app-7: Create the tailnet login · done in basecamp; continue app-7, then bercail todo done 900' <<<"$out" \
    || fail "done todo: $out"
  todo "done" 900 >/dev/null || fail "done"
  out="$("$ROOT/bin/bercail" shep board)" || fail "board: $out"
  ! grep -q 'Create the tailnet login' <<<"$out" || fail "a todo Shep marked done is still on the board: $out"
  ! grep -q 'basecamp todos complete' "$LOG" || fail "done completed a todo the person had already done: $(cat "$LOG")"
  # A list that is not one fails, instead of calling every todo done.
  touch "$BC_DATA/list-object"
  out="$("$ROOT/bin/bercail" shep board)" || fail "board on a list that is not one: $out"
  grep -qx -- '- todos: basecamp todos list did not return a list: {"todos":\[\]}' <<<"$out" || fail "not a list: $out"
  ! grep -q 'done in basecamp' <<<"$out" || fail "a todo shows as done: $out"
  printf 'Not logged in' >"$BC_DATA/fail"
  out="$("$ROOT/bin/bercail" shep board)" || fail "board when basecamp fails: $out"
  grep -qx -- '- todos: basecamp todos list failed: Not logged in' <<<"$out" || fail "failing backend: $out"
}

@test "shep board says nothing of todos without a backend" {
  local out
  out="$("$ROOT/bin/bercail" shep board)" || fail "board: $out"
  [[ "$out" == "Waiting on the person:
- nothing" ]] || fail "board: $out"
  ! grep -q '^basecamp' "$LOG" || fail "basecamp ran: $(cat "$LOG")"
}

@test "shep brief shows a todo comment on its own line, not as the desk's report" {
  local out dir="$HOME/Work/app/.beads/fake"
  repo_with_issue app app-7 "Put the HA box on the tailnet"
  jq -n '[{author: "Desk", created_at: "2026-11-15T10:00:00Z", text: "Staged: the tailnet config."},
          {author: "bercail", created_at: "2026-11-15T11:00:00Z", text: "bercail todo: \"Create the tailnet login\" waits on the person in basecamp: https://3.basecamp.com/1/buckets/2/todos/900"}]' \
    >"$dir/app-7.comments.json"
  out="$("$ROOT/bin/bercail" shep brief app-7 --repo "$HOME/Work/app")" || fail "brief: $out"
  grep -qx 'todo: "Create the tailnet login" waits on the person in basecamp: https://3.basecamp.com/1/buckets/2/todos/900' <<<"$out" \
    || fail "no todo line: $out"
  grep -q '^latest report: comment 1 of 2, Desk' <<<"$out" || fail "the todo displaced the report: $out"
}

@test "doctor names the todo backend and whether it is logged in, never the token" {
  local out
  out="$("$ROOT/bin/bercail" doctor 2>&1)" || true
  grep -qx '  --  todos: no backend (\[todo\] backend in config.toml; docs/config.md#todos)' <<<"$out" || fail "no backend: $out"
  basecamp_config
  out="$("$ROOT/bin/bercail" doctor 2>&1)" || true
  grep -qx '  ok  todos: basecamp, logged in; to-do list 333 in project 222' <<<"$out" || fail "logged in: $out"
  ! grep -q 'SECRET-TOKEN' <<<"$out" || fail "doctor printed the token"
  printf '{"ok":true,"data":{"authenticated":false},"notice":"Run: basecamp auth login"}\n' >"$BC_DATA/auth.json"
  out="$("$ROOT/bin/bercail" doctor 2>&1)" || true
  grep -qx '  --  todos: basecamp, not logged in (you run: basecamp auth login --device-code)' <<<"$out" || fail "logged out: $out"
  printf '[todo]\nbackend = "linear"\n' >"$CONFIG"
  out="$("$ROOT/bin/bercail" doctor 2>&1)" || true
  grep -qx '  unknown  todo backend "linear" (\[todo\] backend in config.toml; bercail has: basecamp)' <<<"$out" || fail "unknown: $out"
  ! grep -q 'unknown  \[todo' <<<"$out" || fail "doctor calls a todo key unknown: $out"
}
