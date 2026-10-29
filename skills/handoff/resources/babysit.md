# After handoff

`handoff-spawn` prints `{label, path, branch, issue, agent_started, space, desk, ...}` and
appends `~/.local/state/agentic-dev/handoffs.jsonl`. Report that. Inspect a
child only if the user asks.

Example: `Fix-auth_Myapp`, `/home/you/Work/myapp.fix-auth`, `fix-auth`, `myapp-12a`.

```bash
wt list
hc get <desk>                         # its status (desk from the spawn JSON)
```

Do not `hc send`, type into a desk, auto-answer approvals, or switch to or
close a child's space unless asked. When the user comes back, report the
remembered list; escalate `blocked` desks and hook trust.
