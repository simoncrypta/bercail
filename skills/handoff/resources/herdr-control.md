# Herdr app and herdr-core control (condensed)

Two programs. `herdr-app` is the window: spaces, tabs, layouts. herdr-core
(`hc`) runs every terminal and agent; they keep running when the window
closes. The installed binaries win: `herdr-app commands`, `hc --help`,
`hc <command> --help`.

## Guard

```bash
test -n "${HC_TERMINAL_ID:-}"        # this shell is an hc terminal
herdr-app status >/dev/null 2>&1     # the app is open
```

## Look

```bash
herdr-app status                     # shown space, layout, focus
herdr-app ls                         # spaces, their folders, tabs, terminals
hc ls                                # live terminals (JSON when piped)
hc get <t>                           # one terminal: status, labels, cwd, parent
hc read <t>                          # its screen and history
```

Addresses look like `t7` or `t1b`. Parse them from JSON; do not invent them.
Agent status is `working`, `blocked`, `done` (finished while nobody looked)
or `idle`.

## Desk agents

A bercail desk is an hc terminal labelled `bercail.role=agent` and
`bercail.space=<space id>`, started as a sub-agent of the space's first
terminal. Find one by its labels (`hc get <t>`), then wait on it:

```bash
hc wait <t>                          # until it stops working
```

Main-repo to worktree handoff is `scripts/handoff-spawn` only
(`resources/handoff.md`). Never deliver a task by typing into a desk:

```bash
# wrong: types into the agent's TUI
hc send <t> "$TEXT"
hc keys <t> enter
herdr-app do space.select --id <child>
```

## Helpers in the same checkout

Not a substitute for a handoff:

```bash
hc run --bg --cwd "$PWD" just test   # a sub-agent of this terminal
hc wait <t> --output "test result"
hc read <t>
```

## Safety

- Do not switch the user's shown space unless asked (`space.new` selects the
  new space; bercail's helpers put the user back).
- Do not close, kill or `hc rm` what you did not start unless asked.
- Never `hc server stop` unless the user means it: it parks every terminal.
