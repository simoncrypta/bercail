#!/usr/bin/env bats
# bercail todo: what only the person can do, on the target the job routes to.
# A basecamp stand-in keeps its todos and to-do lists in JSON files; bd and hc
# stand-ins; a temp HOME. Nothing reaches Basecamp.

setup() {
  load test_helper
  isolate
  set -o pipefail
  export LOG="$BATS_TEST_TMPDIR/log" BC_DATA="$BATS_TEST_TMPDIR/bc" HC_DATA="$BATS_TEST_TMPDIR/hc"
  export HERDR_APP_BIN="$BATS_TEST_TMPDIR/no-herdr-app"
  export PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
  mkdir -p "$BC_DATA" "$HC_DATA" "$HOME/Work" "$XDG_CONFIG_HOME/bercail" "$XDG_STATE_HOME/bercail/shep"
  CONFIG="$XDG_CONFIG_HOME/bercail/config.toml"
  TARGETS="$XDG_CONFIG_HOME/bercail/todo.json"
  LEDGER="$XDG_STATE_HOME/bercail/todos.jsonl"
  WORK="$(cd "$HOME/Work" && pwd -P)"
  printf '[]\n' >"$BC_DATA/todos.json"
  jq -n '[{id: 333, title: "bercail", bucket: {id: 222, name: "Home"}, app_url: "https://3.basecamp.com/111/buckets/222/todolists/333"},
          {id: 334, title: "Errands", bucket: {id: 222, name: "Home"}, app_url: "https://3.basecamp.com/111/buckets/222/todolists/334"},
          {id: 1111111, title: "Lesentiel", bucket: {id: 7654321, name: "Show the vision"},
           app_url: "https://3.basecamp.com/1234567/buckets/7654321/todolists/1111111"}]' >"$BC_DATA/lists.json"
  printf '{"ok":true,"data":{"authenticated":true,"base_url":"https://3.basecampapi.com","token":"SECRET-TOKEN-123"}}\n' >"$BC_DATA/auth.json"
  printf '{"terminals":[]}\n' >"$HC_DATA/ls.json"

  # basecamp: todos in $BC_DATA/todos.json and to-do lists in $BC_DATA/lists.json
  # as Basecamp's API has them, in its --json envelope. $BC_DATA/fail makes every
  # call fail with that message; $BC_DATA/fail-<list> fails that list's calls.
  cat >"$BATS_TEST_TMPDIR/bin/basecamp" <<'EOF'
#!/usr/bin/env bash
printf 'basecamp %s\n' "$*" >>"$LOG"
db="$BC_DATA/todos.json" lists="$BC_DATA/lists.json"
if [[ -f "$BC_DATA/fail" ]]; then
  jq -nc --arg m "$(cat "$BC_DATA/fail")" '{ok: false, error: {message: $m}}'
  exit 1
fi
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && printf '%s' "${a#*=}"; done; }
val() { local a prev=""; for a in "${@:2}"; do [[ "$prev" == "$1" ]] && printf '%s' "$a"; prev="$a"; done; }
list="$(val --list "$@")"
[[ "$1 $2" != "todolists show" ]] || list="$3"
if [[ -n "$list" && -f "$BC_DATA/fail-$list" ]]; then
  jq -nc --arg m "$(cat "$BC_DATA/fail-$list")" '{ok: false, error: {message: $m}}'
  exit 1
fi
case "$1 $2" in
  "auth status") cat "$BC_DATA/auth.json" ;;
  "todos create")
    title="$(cat)"
    printf 'stdin %s\n' "$title" >>"$LOG"
    id=$((900 + $(jq length "$db")))
    jq --arg t "$title" --arg d "$(arg --description "$@")" --arg due "$(arg --due "$@")" --argjson id "$id" --arg l "$list" \
      '. + [{id: $id, content: $t, title: $t, description: (if $d == "" then "" else "<div>\($d | gsub("\n"; "<br>"))</div>" end),
             due_on: (if $due == "" then null else $due end), completed: false, list: $l,
             app_url: "https://3.basecamp.com/1/buckets/2/todos/\($id)"}]' "$db" >"$db.tmp" && mv "$db.tmp" "$db"
    jq -c --argjson id "$id" '{ok: true, data: (.[] | select(.id == $id))}' "$db" ;;
  "todos list")
    [[ ! -f "$BC_DATA/list-object" ]] || { printf '{"ok":true,"data":{"todos":[]}}\n'; exit 0; }
    jq -c --arg l "$list" '{ok: true, data: map(select((.completed | not) and .list == $l))}' "$db" ;;
  "todos show")
    jq -ce --argjson id "${3##*/}" '{ok: true, data: (.[] | select(.id == $id))}' "$db" \
      || { printf '{"ok":false,"error":{"message":"Todo not found"}}\n'; exit 1; } ;;
  "todos complete")
    jq --argjson id "$3" 'map(if .id == $id then .completed = true else . end)' "$db" >"$db.tmp" && mv "$db.tmp" "$db"
    printf '{"ok":true,"data":{}}\n' ;;
  "todolists show")
    jq -ce --argjson id "$3" --argjson p "$(val --in "$@")" '{ok: true, data: (.[] | select(.id == $id and .bucket.id == $p))}' "$lists" \
      || { printf '{"ok":false,"error":{"message":"Todolist not found"}}\n'; exit 1; } ;;
  "todolists list")
    jq -c --argjson p "$(val --in "$@")" '{ok: true, data: map(select(.bucket.id == $p))}' "$lists" ;;
  "todolists create")
    id=$((700 + $(jq length "$lists")))
    jq --arg t "$3" --argjson p "$(val --in "$@")" --argjson id "$id" \
      '. + [{id: $id, title: $t, bucket: {id: $p, name: "Show the vision"},
             app_url: "https://3.basecamp.com/1234567/buckets/\($p)/todolists/\($id)"}]' "$lists" >"$lists.tmp" && mv "$lists.tmp" "$lists"
    jq -c --argjson id "$id" '{ok: true, data: (.[] | select(.id == $id))}' "$lists" ;;
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

# Two targets: home (Errands, account 111) and lesentiel (account 1234567).
two_targets() {
  todo target add home https://3.basecamp.com/111/buckets/222/todolists/334 >/dev/null || fail "add home"
  todo target add lesentiel https://app.basecamp.com/1234567/buckets/7654321/todolists/1111111 >/dev/null || fail "add lesentiel"
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

@test "an old [todo.basecamp] in config.toml is the default target \"config\": add, list, show and done reach its list" {
  local out
  basecamp_config
  out="$(todo add --notes "Log in at the admin page" --due 2026-11-20 -- "--create the tailnet login")" || fail "add: $out"
  [[ "$out" == "added to config: --create the tailnet login · due 2026-11-20 · https://3.basecamp.com/1/buckets/2/todos/900" ]] || fail "add: $out"
  grep -qx 'basecamp todos create - --in 222 --list 333 --description=Log in at the admin page --due=2026-11-20 --account 111 --json' "$LOG" \
    || fail "create argv: $(cat "$LOG")"
  grep -qx 'stdin --create the tailnet login' "$LOG" || fail "the title did not go on stdin: $(cat "$LOG")"
  # A todo from before targets: on the list, and in the ledger with no target, which makes it config's.
  jq '. + [{id: 901, title: "Plug in the Zigbee stick", description: "", due_on: null, completed: false, list: "333",
            app_url: "https://3.basecamp.com/1/buckets/2/todos/901"}]' "$BC_DATA/todos.json" >"$BC_DATA/t" && mv "$BC_DATA/t" "$BC_DATA/todos.json"
  printf '{"at":"2026-11-15T00:00:00Z","backend":"basecamp","id":"901","url":"u","title":"t","issue":"old-1","repo":"/x"}\n' >>"$LEDGER"

  out="$(todo list)" || fail "list: $out"
  [[ "$out" == "config:
- 900: --create the tailnet login · due 2026-11-20 · https://3.basecamp.com/1/buckets/2/todos/900
- 901: Plug in the Zigbee stick · old-1 · https://3.basecamp.com/1/buckets/2/todos/901" ]] || fail "list: $out"
  grep -q 'basecamp todos list --in 222 --list 333 --all --account 111 --json' "$LOG" || fail "list argv: $(cat "$LOG")"
  [[ "$(todo list --json | jq -c '.[0]')" == '{"target":"config","id":"900","title":"--create the tailnet login","notes":"Log in at the admin page","due":"2026-11-20","done":false,"url":"https://3.basecamp.com/1/buckets/2/todos/900"}' ]] \
    || fail "list --json: $(todo list --json)"

  out="$(todo show https://3.basecamp.com/1/buckets/2/todos/900)" || fail "show: $out"
  [[ "$out" == "--create the tailnet login
open in config · due 2026-11-20
https://3.basecamp.com/1/buckets/2/todos/900

Log in at the admin page" ]] || fail "show: $out"

  out="$(todo "done" 900)" || fail "done: $out"
  [[ "$out" == "done in config: --create the tailnet login · due 2026-11-20 · https://3.basecamp.com/1/buckets/2/todos/900" ]] || fail "done: $out"
  grep -qx 'basecamp todos complete 900 --account 111 --json' "$LOG" || fail "complete argv: $(cat "$LOG")"
  [[ "$(jq -sc 'map({target, id, done})' "$LEDGER")" == '[{"target":"config","id":"900","done":null},{"target":null,"id":"901","done":null},{"target":"config","id":"900","done":true}]' ]] \
    || fail "ledger: $(cat "$LEDGER")"

  # A target from bercail todo target, set as the default, takes over from it.
  out="$(todo target rm config 2>&1)" && fail "removed config.toml's list: $out"
  [[ "$out" == "bercail todo: \"config\" is [todo] in $CONFIG; delete [todo] and its table there to remove it" ]] || fail "rm config: $out"
  todo target add home https://3.basecamp.com/111/buckets/222/todolists/334 >/dev/null || fail "add home"
  [[ "$(todo route --default home)" == "default: home" ]] || fail "route --default"
  out="$(todo add "Renew the domain")" || fail "add after the move: $out"
  [[ "$out" == "added to home: Renew the domain · https://3.basecamp.com/1/buckets/2/todos/902" ]] || fail "after the move: $out"
  grep -q 'basecamp todos create - --in 222 --list 334 --account 111 --json' "$LOG" || fail "went to the old list: $(cat "$LOG")"
  [[ "$(todo add "Old list" --target config)" == "added to config: Old list"* ]] || fail "config is still a target"
}

@test "todo target add reads the list a to-do list URL names, on both Basecamp hosts, and keeps it in todo.json" {
  local out
  out="$(todo target add home https://3.basecamp.com/111/buckets/222/todolists/334)" || fail "add: $out"
  [[ "$out" == 'added home: basecamp, to-do list "Errands" in Home · https://3.basecamp.com/111/buckets/222/todolists/334' ]] || fail "add: $out"
  grep -qx 'basecamp todolists show 334 --in 222 --account 111 --json' "$LOG" || fail "the list was not read: $(cat "$LOG")"
  out="$(todo target add lesentiel 'https://app.basecamp.com/1234567/buckets/7654321/todolists/1111111?tab=open#top')" || fail "add: $out"
  [[ "$out" == 'added lesentiel: basecamp, to-do list "Lesentiel" in Show the vision · https://3.basecamp.com/1234567/buckets/7654321/todolists/1111111' ]] \
    || fail "app.basecamp.com: $out"
  [[ "$(jq -c '.targets.lesentiel | {backend, account, project, todolist}' "$TARGETS")" == '{"backend":"basecamp","account":"1234567","project":"7654321","todolist":"1111111"}' ]] \
    || fail "todo.json: $(cat "$TARGETS")"

  out="$(todo target list)" || fail "list: $out"
  [[ "$out" == '- home: basecamp, to-do list "Errands" in Home · https://3.basecamp.com/111/buckets/222/todolists/334
- lesentiel: basecamp, to-do list "Lesentiel" in Show the vision · https://3.basecamp.com/1234567/buckets/7654321/todolists/1111111
no default: a todo with no route needs --target (bercail todo route --default <target>)' ]] || fail "list: $out"

  repo_with_issue lesentiel les-1 "Show the vision"
  [[ "$(todo route "$HOME/Work/lesentiel" lesentiel)" == "$WORK/lesentiel → lesentiel" ]] || fail "route"
  todo route --default home >/dev/null || fail "default"
  [[ "$(todo target list --json | jq -c 'map({name, default, routes})')" == "[{\"name\":\"home\",\"default\":true,\"routes\":[]},{\"name\":\"lesentiel\",\"default\":false,\"routes\":[\"$WORK/lesentiel\"]}]" ]] \
    || fail "list --json: $(todo target list --json)"
  [[ "$(todo target show lesentiel)" == '- lesentiel: basecamp, to-do list "Lesentiel" in Show the vision · https://3.basecamp.com/1234567/buckets/7654321/todolists/1111111 · routes ~/Work/lesentiel' ]] \
    || fail "show: $(todo target show lesentiel)"
  [[ "$(todo target show home --json | jq -c '{name, default, todolist}')" == '{"name":"home","default":true,"todolist":"334"}' ]] || fail "show --json"

  # Adding a name again points it at the new list; its routes stay.
  out="$(todo target add lesentiel https://3.basecamp.com/111/buckets/222/todolists/333 --json)" || fail "re-add: $out"
  [[ "$(jq -c '{name, todolist, routes}' <<<"$out")" == "{\"name\":\"lesentiel\",\"todolist\":\"333\",\"routes\":[\"$WORK/lesentiel\"]}" ]] || fail "re-add: $out"

  [[ "$(todo target rm lesentiel)" == "removed lesentiel, and its routes" ]] || fail "rm"
  [[ "$(jq -c . "$TARGETS" | jq -c '{routes, default, names: (.targets | keys)}')" == '{"routes":{},"default":"home","names":["home"]}' ]] || fail "after rm: $(cat "$TARGETS")"
  todo target rm home >/dev/null || fail "rm home"
  [[ "$(jq -c . "$TARGETS")" == '{"targets":{},"routes":{}}' ]] || fail "the default outlived its target: $(cat "$TARGETS")"
  out="$(todo target show home 2>&1)" && fail "show of a removed target passed"
  [[ "$out" == 'bercail todo: no todo target "home" (bercail todo target list)' ]] || fail "show removed: $out"
}

@test "todo target add writes nothing for a URL that is not one list it can read; a todoset's error lists its lists, and --create makes one" {
  local out todoset=https://app.basecamp.com/1234567/buckets/7654321/todosets/77
  out="$(todo target add lesentiel "$todoset" 2>&1)" && fail "a todoset passed: $out"
  [[ "$out" == "bercail todo: $todoset is a project's to-dos, not one list. Its lists:
- Lesentiel: https://3.basecamp.com/1234567/buckets/7654321/todolists/1111111
Pass one of those URLs, or --create \"<list name>\" to make one there" ]] || fail "todoset: $out"
  grep -qx 'basecamp todolists list --in 7654321 --todoset 77 --all --account 1234567 --json' "$LOG" || fail "list argv: $(cat "$LOG")"
  out="$(todo target add errands https://3.basecamp.com/111/projects/999 2>&1)" && fail "an empty project passed: $out"
  [[ "$out" == *"is a project's to-dos, not one list. It has no list yet; pass --create \"<list name>\" to make one there" ]] || fail "empty project: $out"
  out="$(todo target add home https://3.basecamp.com/111/buckets/222/todolists/999 2>&1)" && fail "a list the login cannot see passed: $out"
  [[ "$out" == "bercail todo: basecamp todolists show failed: Todolist not found" ]] || fail "unseen list: $out"
  out="$(todo target add home https://3.basecamp.com/111/buckets/222/todos/5 2>&1)" && fail "a todo URL passed: $out"
  [[ "$out" == "bercail todo: https://3.basecamp.com/111/buckets/222/todos/5 is not a Basecamp to-do list: open the list and copy its URL"* ]] || fail "todo URL: $out"
  out="$(todo target add home https://example.com/lists/1 2>&1)" && fail "another site passed: $out"
  [[ "$out" == "bercail todo: no backend knows https://example.com/lists/1; name one with --backend (bercail has: basecamp)" ]] || fail "other site: $out"
  out="$(todo target add home https://3.basecamp.com/111/buckets/222/todolists/334 --create "New" 2>&1)" && fail "--create on a list passed: $out"
  [[ "$out" == "bercail todo: --create makes a list in a project: pass the project's To-dos URL"* ]] || fail "--create on a list: $out"
  out="$(todo target add config https://3.basecamp.com/111/buckets/222/todolists/334 2>&1)" && fail "the name config passed: $out"
  [[ "$out" == 'bercail todo: "config" is the list [todo] in config.toml names; pick another name' ]] || fail "config: $out"
  out="$(todo target add "Home List" https://3.basecamp.com/111/buckets/222/todolists/334 2>&1)" && fail "a bad name passed: $out"
  [[ "$out" == "bercail todo: a target name is 1-32 of a-z 0-9 - _"* ]] || fail "bad name: $out"
  [[ ! -e "$TARGETS" ]] || fail "a failed add wrote todo.json: $(cat "$TARGETS")"
  ! grep -q 'todolists create' "$LOG" || fail "a list was made: $(cat "$LOG")"

  out="$(todo target add lesentiel "$todoset" --create "Simon's todos")" || fail "--create: $out"
  [[ "$out" == "added lesentiel: basecamp, to-do list \"Simon's todos\" in Show the vision · https://3.basecamp.com/1234567/buckets/7654321/todolists/703" ]] || fail "--create: $out"
  grep -qx "basecamp todolists create Simon's todos --in 7654321 --todoset 77 --account 1234567 --json" "$LOG" || fail "create argv: $(cat "$LOG")"
  [[ "$(jq -r '.targets.lesentiel.todolist' "$TARGETS")" == 703 ]] || fail "todo.json: $(cat "$TARGETS")"
}

@test "todo add goes to --target, else the route of the job's repo or the issue's, else the default; with none it says what to run" {
  local out
  two_targets
  repo_with_issue app app-7 "Put the HA box on the tailnet"
  repo_with_issue lesentiel les-3 "Show the vision"
  git -C "$HOME/Work/lesentiel" worktree add -q "$HOME/Work/lesentiel.deck" -b deck
  : >"$LOG"
  out="$(todo add "Plug in the stick" 2>&1)" && fail "no route and no default passed: $out"
  [[ "$out" == "bercail todo: no todo target for a todo with no repo: pass --target (the targets: home, lesentiel), route the repo (bercail todo route <repo> <target>), or set a default (bercail todo route --default <target>)" ]] \
    || fail "none: $out"
  out="$(todo add "Plug in the stick" --repo "$HOME/Work/app" 2>&1)" && fail "an unrouted repo passed: $out"
  [[ "$out" == "bercail todo: no todo target for $WORK/app: pass --target"* ]] || fail "unrouted repo: $out"
  ! grep -q '^basecamp' "$LOG" || fail "basecamp ran: $(cat "$LOG")"

  # The repo's route, from one of its worktrees too.
  todo route "$HOME/Work/lesentiel" lesentiel >/dev/null || fail "route lesentiel"
  out="$(todo add "Approve the vision deck" --repo "$HOME/Work/lesentiel.deck")" || fail "by repo: $out"
  [[ "$out" == "added to lesentiel: Approve the vision deck · https://3.basecamp.com/1/buckets/2/todos/900" ]] || fail "by repo: $out"
  grep -qx 'basecamp todos create - --in 7654321 --list 1111111 --account 1234567 --json' "$LOG" || fail "lesentiel argv: $(cat "$LOG")"
  # The repo of --issue, asked from its checkout.
  todo route "$HOME/Work/app" home >/dev/null || fail "route app"
  out="$(cd "$HOME/Work/app" && todo add "Create the tailnet login" --issue app-7)" || fail "by issue: $out"
  [[ "$out" == "added to home: Create the tailnet login · https://3.basecamp.com/1/buckets/2/todos/901
linked on app-7" ]] || fail "by issue: $out"
  [[ "$(jq -r .text "$HOME/Work/app/.beads/fake/app-7.added")" == 'bercail todo: "Create the tailnet login" waits on the person in basecamp (home): https://3.basecamp.com/1/buckets/2/todos/901' ]] \
    || fail "comment: $(cat "$HOME/Work/app/.beads/fake/app-7.added")"
  # --target over the route.
  [[ "$(todo add "Sign the form" --repo "$HOME/Work/lesentiel" --target home)" == "added to home: Sign the form"* ]] || fail "explicit"
  # The default for the rest, and for a repo whose route is gone.
  todo route --default lesentiel >/dev/null || fail "default"
  [[ "$(todo add "Renew the domain")" == "added to lesentiel: Renew the domain"* ]] || fail "default"
  [[ "$(todo route --rm "$HOME/Work/app")" == "no route for $WORK/app" ]] || fail "route --rm"
  [[ "$(todo add "Print the badge" --repo "$HOME/Work/app")" == "added to lesentiel: Print the badge"* ]] || fail "fallback to the default"
  [[ "$(jq -sc 'map(.target)' "$LEDGER")" == '["lesentiel","home","home","lesentiel","lesentiel"]' ]] || fail "ledger: $(cat "$LEDGER")"

  out="$(todo add "x" --target nope 2>&1)" && fail "an unknown target passed: $out"
  [[ "$out" == 'bercail todo: no todo target "nope"; the targets are: home, lesentiel (bercail todo target list)' ]] || fail "unknown: $out"
  todo route "$HOME/Work/app" nope 2>/dev/null && fail "routed to an unknown target"

  # list groups by target; done finds the todo's target in the ledger.
  out="$(todo list)" || fail "list: $out"
  [[ "$out" == "home:
- 901: Create the tailnet login · app-7 · https://3.basecamp.com/1/buckets/2/todos/901
- 902: Sign the form · https://3.basecamp.com/1/buckets/2/todos/902
lesentiel:
- 900: Approve the vision deck · https://3.basecamp.com/1/buckets/2/todos/900
- 903: Renew the domain · https://3.basecamp.com/1/buckets/2/todos/903
- 904: Print the badge · https://3.basecamp.com/1/buckets/2/todos/904" ]] || fail "list: $out"
  [[ "$(todo "done" 902)" == "done in home: Sign the form · https://3.basecamp.com/1/buckets/2/todos/902" ]] || fail "done"
  grep -qx 'basecamp todos complete 902 --account 111 --json' "$LOG" || fail "done went to another account: $(cat "$LOG")"
}

@test "todo add --issue puts the id only in the notes' last line, and an issue bd does not know writes nothing" {
  local out
  basecamp_config
  repo_with_issue app app-7 "Put the HA box on the tailnet"
  todo add "Create the tailnet login" --issue app-7 --repo "$HOME/Work/app" >/dev/null || fail "add"
  [[ "$(jq -r '.[0].title' "$BC_DATA/todos.json")" == "Create the tailnet login" ]] || fail "the title carries more than the title"
  [[ "$(todo list --json | jq -r '.[0].notes')" == "bercail: app-7 in app" ]] || fail "notes: $(todo list --json)"
  rm "$LEDGER"
  : >"$LOG"
  out="$(cd "$HOME/Work/app" && todo add "Create the login" --issue app-9 2>&1)" && fail "an unknown issue passed: $out"
  [[ "$out" == "bercail todo: bd does not know app-9 in $WORK/app; pass its checkout with --repo" ]] || fail "error: $out"
  ! grep -q '^basecamp' "$LOG" || fail "basecamp ran: $(cat "$LOG")"
  [[ ! -e "$LEDGER" ]] || fail "the ledger has an entry: $(cat "$LEDGER")"
}

@test "todo add --issue trail:N links the todo in the trail's comments on this machine, and a trail Entire does not have writes nothing" {
  local out file
  need node
  basecamp_config
  git init -q -b main "$HOME/Work/app"
  git -C "$HOME/Work/app" remote add origin entire://entire.example/et/proj/app
  # entire knows trail 3 only.
  cat >"$BATS_TEST_TMPDIR/bin/entire" <<'EOF'
#!/usr/bin/env bash
printf 'entire %s\n' "$*" >>"$LOG"
trail='{"number":3,"title":"Put the HA box on the tailnet","status":"open","phase":"planning","repoIds":["R1"],"changes":[]}'
case "$1 $2" in
  "repo view") echo '{"id":"R1"}' ;;
  "trail list") echo "{\"items\":[$trail],\"nextPageToken\":null}" ;;
  "trail show") [[ "$3" == 3 ]] || { echo "project trail #$3 not found" >&2; exit 1; }; echo "$trail" ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/entire"
  todo add "Create the tailnet login" --issue trail:3 --repo "$HOME/Work/app" >/dev/null || fail "add"
  [[ "$(todo list --json | jq -r '.[0].notes')" == "bercail: trail:3 in app" ]] || fail "notes: $(todo list --json)"
  file="$(find "$XDG_STATE_HOME/bercail/jobs" -name 3.comments.jsonl)"
  jq -e '.text | startswith("bercail todo: \"Create the tailnet login\" waits on the person in basecamp")' "$file" >/dev/null \
    || fail "link: $(cat "$file")"
  ! grep -q '^bd ' "$LOG" || fail "bd ran: $(cat "$LOG")"
  rm "$LEDGER"
  : >"$LOG"
  out="$(todo add "Create the login" --issue trail:9 --repo "$HOME/Work/app" 2>&1)" && fail "an unknown trail passed: $out"
  [[ "$out" == "bercail todo: Entire has no trail:9 for $WORK/app (bercail job show trail:9 --repo $WORK/app); pass its checkout with --repo" ]] || fail "error: $out"
  ! grep -q '^basecamp' "$LOG" || fail "basecamp ran: $(cat "$LOG")"
  [[ ! -e "$LEDGER" ]] || fail "the ledger has an entry: $(cat "$LEDGER")"
}

@test "no target, an unknown backend, an incomplete config and a broken todo.json fail clearly and run nothing" {
  local out
  out="$(todo list 2>&1)" && fail "no target passed: $out"
  [[ "$out" == "bercail todo: no todo target yet: bercail todo target add <name> <to-do list URL> (docs/config.md#todos)" ]] || fail "none: $out"
  out="$(todo add "Do it" 2>&1)" && fail "add with no target passed: $out"
  [[ "$out" == "bercail todo: no todo target yet: bercail todo target add <name> <to-do list URL> (docs/config.md#todos)" ]] || fail "add none: $out"
  printf '[todo]\nbackend = "linear"\n' >"$CONFIG"
  out="$(todo add "Do it" 2>&1)" && fail "an unknown backend passed: $out"
  [[ "$out" == "bercail todo: unknown [todo] backend \"linear\" in $CONFIG; bercail has: basecamp" ]] || fail "unknown: $out"
  printf '[todo]\nbackend = "../todo"\n' >"$CONFIG"
  out="$(todo list 2>&1)" && fail "a path as backend passed: $out"
  [[ "$out" == *'unknown [todo] backend "../todo"'* ]] || fail "path: $out"
  printf '[todo]\nbackend = "basecamp"\n[todo.basecamp]\naccount = "111"\n' >"$CONFIG"
  out="$(todo add "Do it" 2>&1)" && fail "an incomplete config passed: $out"
  [[ "$out" == "bercail todo: set account, project and todolist for todo target config ([todo.basecamp] in $CONFIG)"* ]] || fail "incomplete: $out"
  ! grep -q '^basecamp' "$LOG" || fail "basecamp ran: $(cat "$LOG")"
  basecamp_config
  out="$(todo add "Do it" --notes - 2>&1)" && fail "notes of - passed: $out"
  [[ "$out" == "bercail todo: --notes cannot be just -" ]] || fail "notes -: $out"
  ! grep -q '^basecamp' "$LOG" || fail "basecamp ran: $(cat "$LOG")"
  printf 'not json' >"$TARGETS"
  out="$(todo add "Do it" 2>&1)" && fail "a broken todo.json passed: $out"
  [[ "$out" == "bercail todo: $TARGETS is not the JSON bercail todo writes; fix it, or move it away and add the targets again" ]] || fail "broken: $out"
  out="$(todo route --default config 2>&1)" && fail "a write over a broken todo.json passed"
  [[ "$(cat "$TARGETS")" == "not json" ]] || fail "the broken file was overwritten"
  out="$(todo frobnicate 2>&1)" && fail "an unknown subcommand passed"
  [[ "$out" == "bercail todo: usage: bercail todo add"* ]] || fail "usage: $out"
  out="$(todo target frobnicate 2>&1)" && fail "an unknown target subcommand passed"
  [[ "$out" == "bercail todo: usage: bercail todo target add"* ]] || fail "target usage: $out"
}

@test "a Basecamp error reaches the person in one line, and nothing is recorded" {
  local out
  basecamp_config
  printf 'Not logged in to https://3.basecampapi.com' >"$BC_DATA/fail"
  out="$(todo add "Do it" 2>&1)" && fail "a failed create passed: $out"
  [[ "$out" == "bercail todo: basecamp todos create failed: Not logged in to https://3.basecampapi.com" ]] || fail "error: $out"
  [[ ! -e "$LEDGER" ]] || fail "the ledger has an entry: $(cat "$LEDGER")"
}

@test "shep board groups open todos by target under what waits on the person, then the done ones until Shep marks them done" {
  local out
  two_targets
  repo_with_issue app app-7 "Put the HA box on the tailnet"
  printf '%s\n' "$HOME/Work/app" >"$XDG_STATE_HOME/bercail/shep/repos"
  todo route --default home >/dev/null && todo route "$HOME/Work/app" lesentiel >/dev/null || fail "routes"
  todo add "Create the tailnet login" --issue app-7 --repo "$HOME/Work/app" >/dev/null || fail "add"
  todo add "Plug in the Zigbee stick" --due 2026-11-20 >/dev/null || fail "add"
  out="$("$ROOT/bin/bercail" shep board)" || fail "board: $out"
  [[ "$(sed -n '/^Waiting on the person:/,/^Decisions/{/^Decisions/!p}' <<<"$out")" == "Waiting on the person:
- todo: Plug in the Zigbee stick · due 2026-11-20 · open in home · https://3.basecamp.com/1/buckets/2/todos/901
- todo for app-7: Create the tailnet login · open in lesentiel · https://3.basecamp.com/1/buckets/2/todos/900" ]] \
    || fail "board: $out"
  # The person ticks it off in Basecamp.
  jq 'map(.completed = (.id == 900))' "$BC_DATA/todos.json" >"$BC_DATA/t" && mv "$BC_DATA/t" "$BC_DATA/todos.json"
  out="$("$ROOT/bin/bercail" shep board)" || fail "board: $out"
  grep -qx -- '- todo for app-7: Create the tailnet login · done in lesentiel; continue app-7, then bercail todo done 900' <<<"$out" \
    || fail "done todo: $out"
  todo "done" 900 >/dev/null || fail "done"
  out="$("$ROOT/bin/bercail" shep board)" || fail "board: $out"
  ! grep -q 'Create the tailnet login' <<<"$out" || fail "a todo Shep marked done is still on the board: $out"
  ! grep -q 'basecamp todos complete' "$LOG" || fail "done completed a todo the person had already done: $(cat "$LOG")"
  # One target that does not answer is one line; the others still show.
  printf 'Access denied' >"$BC_DATA/fail-1111111"
  out="$("$ROOT/bin/bercail" shep board)" || fail "board with one failing target: $out"
  [[ "$(sed -n '/^Waiting on the person:/,/^Decisions/{/^Decisions/!p}' <<<"$out")" == "Waiting on the person:
- todo: Plug in the Zigbee stick · due 2026-11-20 · open in home · https://3.basecamp.com/1/buckets/2/todos/901
- todos in lesentiel: basecamp todos list failed: Access denied" ]] || fail "one failing: $out"
  # A list that is not one fails, instead of calling every todo done.
  touch "$BC_DATA/list-object"
  out="$("$ROOT/bin/bercail" shep board)" || fail "board on a list that is not one: $out"
  grep -qx -- '- todos in home: basecamp todos list did not return a list: {"todos":\[\]}' <<<"$out" || fail "not a list: $out"
  ! grep -q 'done in' <<<"$out" || fail "a todo shows as done: $out"
  printf 'not json' >"$TARGETS"
  out="$("$ROOT/bin/bercail" shep board)" || fail "board on a broken todo.json: $out"
  grep -qx -- "- todos: $TARGETS is not the JSON bercail todo writes; fix it, or move it away and add the targets again" <<<"$out" || fail "broken: $out"
}

@test "shep board says nothing of todos without a target" {
  local out
  out="$("$ROOT/bin/bercail" shep board)" || fail "board: $out"
  [[ "${out%%$'\n'Decisions*}" == "Waiting on the person:
- nothing" ]] || fail "board: $out"
  ! grep -q '^basecamp' "$LOG" || fail "basecamp ran: $(cat "$LOG")"
}

@test "shep brief shows a todo comment on its own line, not as the desk's report" {
  local out dir="$HOME/Work/app/.beads/fake"
  repo_with_issue app app-7 "Put the HA box on the tailnet"
  jq -n '[{author: "Desk", created_at: "2026-11-15T10:00:00Z", text: "Staged: the tailnet config."},
          {author: "bercail", created_at: "2026-11-15T11:00:00Z", text: "bercail todo: \"Create the tailnet login\" waits on the person in basecamp (home): https://3.basecamp.com/1/buckets/2/todos/900"}]' \
    >"$dir/app-7.comments.json"
  out="$("$ROOT/bin/bercail" shep brief app-7 --repo "$HOME/Work/app")" || fail "brief: $out"
  grep -qx 'todo: "Create the tailnet login" waits on the person in basecamp (home): https://3.basecamp.com/1/buckets/2/todos/900' <<<"$out" \
    || fail "no todo line: $out"
  grep -q '^latest report: comment 1 of 2, Desk' <<<"$out" || fail "the todo displaced the report: $out"
}

@test "doctor has a line per target, whether its list answers, and a hint to move config.toml's list; never the token" {
  local out
  out="$("$ROOT/bin/bercail" doctor 2>&1)" || true
  grep -qx '  --  todos: no target (bercail todo target add <name> <to-do list URL>; docs/config.md#todos)' <<<"$out" || fail "no target: $out"
  basecamp_config
  todo target add lesentiel https://app.basecamp.com/1234567/buckets/7654321/todolists/1111111 >/dev/null || fail "add"
  out="$("$ROOT/bin/bercail" doctor 2>&1)" || true
  [[ "$(grep 'todos' <<<"$out")" == '  ok  todos config: basecamp, logged in; to-do list "bercail" in Home
  ok  todos lesentiel: basecamp, logged in; to-do list "Lesentiel" in Show the vision
  hint  todos: "config" is [todo] in config.toml; move it: bercail todo target add <name> <its URL>, bercail todo route --default <name>, then delete [todo] and [todo.basecamp] from config.toml' ]] \
    || fail "two targets: $out"
  printf 'Access denied' >"$BC_DATA/fail-1111111"
  out="$("$ROOT/bin/bercail" doctor 2>&1)" || true
  grep -qx '  unreachable  todos lesentiel: basecamp, logged in, but to-do list 1111111 does not answer: basecamp todolists show failed: Access denied' <<<"$out" \
    || fail "unreachable: $out"
  ! grep -q 'SECRET-TOKEN' <<<"$out" || fail "doctor printed the token"
  printf '{"ok":true,"data":{"authenticated":false},"notice":"Run: basecamp auth login"}\n' >"$BC_DATA/auth.json"
  out="$("$ROOT/bin/bercail" doctor 2>&1)" || true
  grep -qx '  --  todos lesentiel: basecamp, not logged in (you run: basecamp auth login --device-code)' <<<"$out" || fail "logged out: $out"
  printf '[todo]\nbackend = "linear"\n' >"$CONFIG"
  out="$("$ROOT/bin/bercail" doctor 2>&1)" || true
  grep -qx "  unknown  todos config: unknown \[todo\] backend \"linear\" in $CONFIG; bercail has: basecamp" <<<"$out" || fail "unknown: $out"
  ! grep -q 'unknown  \[todo' <<<"$out" || fail "doctor calls a todo key unknown: $out"
  printf 'not json' >"$TARGETS"
  out="$("$ROOT/bin/bercail" doctor 2>&1)" || true
  grep -qx "  broken  todos: $TARGETS is not the JSON bercail todo writes; fix it, or move it away and add the targets again" <<<"$out" || fail "broken: $out"
}
