# bercail

An agentic development environment on the Herdr app: one worktree per space, one
desk agent per space, review in tuicr. Bash CLI plus Herdr mods, skills, and docs.

## Layout

- `bin/bercail`: the CLI entry point. It sources `lib/*.sh`, one file per area
  (`notify.sh`, `doctor.sh`, `desk.sh`, `bstack.sh`, …).
- `install.sh`: installer and deploy; `manifest.json` holds the version.
- `config/`: files deployed under `~/.config` (shell, worktrunk, pi, opencode, systemd, …).
- `bercail/`: the Herdr layout and mods (`bercail/mods/*`).
- `skills/`: skills deployed to `~/.agents/skills`. `bstack/` is the bstack Pi/opencode setup.
- `tests/*_test.sh`: one bash script per area, each in its own temp HOME with stand-ins
  (`hc`, `curl`, `openclaw`, …). `.agents/skills/verify-bercail/` drives the CLI end to end.
- `docs/`: the reference (`docs/README.md` is the index). `site/` and `workers/` are
  the bercail.dev site and its Worker.

## Commands

```bash
bin/bercail <cmd>                         # this checkout's CLI; a bare `bercail` runs the installed copy
bash tests/notify_test.sh                 # one area
for t in tests/*_test.sh; do bash "$t" || break; done   # everything (CI runs tests/*.sh)
shellcheck -S warning lib/notify.sh       # lint the files you touch; the tree has older warnings
herdr-app check bercail/mods/bercail-desk # each mod you touch
.agents/skills/verify-bercail/run.sh      # throwaway-HOME drive; evidence in .bercail/verify/
```

There is no build step for the CLI. The site build needs `npm ci` first (see
`docs/development.md`).

Known noise (2026-11, v0.12.0): `verify-bercail` reports four FAIL checks (doctor's bstack
section, ready.md, council command and seat) on a clean HEAD too. Under `~/Work`,
mise in its temp HOME tries to install tools, so its `reconfigure` steps fail as well.
Run it from a copy under `/tmp` to compare. `tests/handoff_spawn_test.sh` can fail its
Ctrl-C check when the machine is busy; rerun it on its own.

## Conventions

- Match the code beside you: small bash functions with a one-line comment on why,
  `local` everything, `jq` for JSON, errors on stderr with a fix in the message.
- Secrets never go in argv or output. Pass them on stdin, in a 0600 file, or through
  a header file (see `notify_post`). Tests grep argv logs and output for the secret.
- A behavior change comes with a test in `tests/` that fails without it. Use
  stand-ins in `$TMP_DIR/bin`, never the real HOME, Herdr core, or network.
- Docs speak plainly and match the code; update `docs/` and the help text in
  `bin/bercail` and `lib/help.sh` together.
- Leave changes staged and uncommitted for review in tuicr. Use `gh` and `gh stack`
  for git hosting; never `gt`.
