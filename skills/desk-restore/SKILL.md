---
name: desk-restore
description: >-
  Puts a desk agent back on its Pi session by hand when `bercail desk restore`
  could not: a desk with no record, or a session started before records existed.
  Finds the sessions written right before the shutdown and matches them by
  folder and content. Use when a desk came back
  after a reboot as a bare shell, or when asked which session belonged to a desk.
---

# desk-restore

`bercail desk restore` handles desks with a usable record. This skill is for
the rest. The conversations are not lost; what is lost is which one belonged in
which terminal.

## 1. List the desks to fix

```bash
bercail desk restore --dry-run
```

A line with `would resume` needs no help: run `bercail desk restore`. Work only
on lines saying `no record`, `no session yet` or `cannot resume`. A line saying
`closed before the shutdown` was closed on purpose: leave it unless asked.

For each one, get its folder and space:

```bash
hc get <address> --json | jq '{cwd, labels}'
```

## 2. Find when the machine went down

```bash
journalctl -b -1 -n 1 -o short-unix --no-pager -q | cut -d. -f1
```

If a core restart took the desk rather than a reboot, use the terminal's last
activity instead (`status_ms`, or when you know it happened).

## 3. Find the candidate sessions

Sessions in that folder, newest first. Those updated shortly before the shutdown
were most likely running, but an idle agent writes nothing, so look further back
when nothing fits.

```bash
# Each session file's first line is its header, with its id and cwd
rg -l --fixed-strings -- "$(jq -cn --arg cwd "$FOLDER" '{cwd:$cwd}' | sed 's/^{//;s/}$//')" \
  ~/.pi/agent/sessions --glob '*.jsonl'
```

Set `SHUTDOWN` to the seconds from step 2, and check the files' mtimes against
a ten-minute window before it. Treat a broader search as investigation,
not permission to resume an old session.

## 4. Match by content

Even one candidate needs a content check. With several, the folder does not
decide it. Evidence, strongest first:

- `~/.local/state/agentic-dev/handoffs.jsonl`: the line whose `desk` is this
  address names the `issue`; the right session talks about that issue.
- The session title and its first messages against the branch and the beads issue.
- The last messages against the state of the worktree.

If two candidates still fit equally, ask the person. A desk on the wrong session
looks fine and does the wrong work.

## 5. Put it back

Check the terminal is still live, has the expected `bercail.role=agent` and
`bercail.space` labels, and sits at a bare shell: `foreground.name` is a shell,
`foreground.pid == pid`, `reason` is null, and `reported` is false. Check all
live terminals' `records` and process arguments for the session ID. If it is
already open, leave this pane alone. Recheck immediately before sending.
It keeps its address, so it
stays the same desk in the same space. `exec`, so quitting the agent ends the
desk as usual. Do not resend the issue prompt: the session has it.

```bash
AGENT="$HOME/.local/bin/bercail-desk-agent"
# Use the verified session, address and folder.
argv=(pi --session-id "$SESSION")
printf -v command 'cd %q && exec %q' "$FOLDER" "$AGENT"
printf -v args ' %q' "${argv[@]}"
hc send "$ADDRESS" "$command$args"
```

Say which desks you put back and on what evidence, and which you left alone.
