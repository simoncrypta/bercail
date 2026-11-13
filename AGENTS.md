# bercail

An agentic development environment on the Herdr app: one worktree per space, one
desk agent per space, review in tuicr. Bash CLI plus Herdr mods, skills, and docs.

## Layout

- `bin/bercail`: the CLI entry point. It sources `lib/*.sh`, one file per area
  (`notify.sh`, `doctor.sh`, `desk.sh`, `bstack.sh`, …).
- `install.sh`: installer and deploy; `manifest.json` holds the version.
- `config/`: files deployed under `~/.config` (shell, worktrunk, pi, systemd, …).
- `bercail/`: the Herdr layout and mods (`bercail/mods/*`).
- `skills/`: skills deployed to `~/.agents/skills`. `bstack/` is the bstack Pi setup.
- `tests/*.test.ts`: Vitest unit tests for the Pi extensions and the Worker (`vp test`).
  `tests/*_live.ts`: the real-Pi live proofs, run by their `live`-tagged bats test.
- `tests/*.bats`: one bats-core file per area, one `@test` per case, each in its own
  temp HOME with stand-ins (`hc`, `curl`, `pi`, …). `.agents/skills/verify-bercail/`
  drives the CLI end to end.
- `docs/`: the reference (`docs/README.md` is the index). `site/` is the bercail.dev
  site and its Worker.

## Commands

```bash
bin/bercail <cmd>                         # this checkout's CLI; a bare `bercail` runs the installed copy
npm ci                                    # once: bats-core and vite-plus are pinned devDependencies
bash tests/run.sh                         # the unit suite: bats, then vp test (CI runs this)
bash tests/run.sh tests/notify.bats       # one area
node_modules/.bin/bats -f 'regex' tests/notify.bats   # the tests whose names match
bash tests/run.sh --live                  # the real-Pi live proofs, tagged live
npm exec -- vp test -t 'regex'            # the TypeScript tests whose names match
bash tests/lint.sh                        # shellcheck -S warning on every shell file, vp check, the mods' lint (CI runs this)
npm exec -- vp check --fix                # format, lint and type-check the TypeScript and JavaScript
herdr-app check bercail/mods/bercail-desk # each mod you touch
.agents/skills/verify-bercail/run.sh      # throwaway-HOME drive; evidence in .bercail/verify/
```

There is no build step for the CLI. The site build needs `npm ci` first (see
`docs/development.md`).

## Conventions

- Match the code beside you: small bash functions with a one-line comment on why,
  `local` everything, `jq` for JSON, errors on stderr with a fix in the message.
- Secrets never go in argv or output. Pass them on stdin, in a 0600 file, or through
  a header file (see `notify_post`). Tests grep argv logs and output for the secret.
- A behavior change comes with a test in `tests/` that fails without it, written to
  `skills/unit-testing`. Each file's `setup` calls `isolate`; put stand-ins in
  `$BATS_TEST_TMPDIR/bin`, never the real HOME, Herdr core, or network. No `@test`
  may lean on another's state.
- Docs speak plainly and match the code; update `docs/` and the help text in
  `lib/help.sh` together.
- `.bercail/policy.toml` is this repo's git and release policy (`bin/bercail policy show`);
  Pi desks get it in their prompt and the guard enforces it once trusted. It is
  the one versioned file under `.bercail/`.
- master is unreleased trunk; a `v*` tag is the release. Only a tag deploys bercail.dev,
  and the curl install and its `bercail update` read the latest release's tag, never
  master (`docs/development.md#releasing`).
- Leave changes staged and uncommitted for review in tuicr. Use `gh` and `gh stack`
  for git hosting; never `gt`.

## Principles

bercail follows the [No AI Slop manifesto](https://www.slopmanifesto.com/):
slop is putting less effort into producing something than the reader must
spend understanding it. Each value, and what enforces it here:

- Outcomes over output: `diff_budget` and `review_budget` in the policy; /validate
  warns on an oversized change, and Shep warns before a desk when the review queue
  is full.
- Understanding over speed: every change ships a description (`skills/describe`),
  checked against the staged tree it describes.
- Our own thinking over a model's first draft: the issue is the spec, and review is
  by stakes. A change to a `high_stakes` path in `.bercail/policy.toml` waits for
  the person's LGTM before it lands.
- Better work over easier work: /validate runs `unslop` and asks the judge what
  could be removed, and a behavior change needs a test that fails without it.
- Improving the system over patching the output: a mistake seen twice gets a
  guardrail (a lint rule, a test, the guard, or a doctor check), not another fix
  by hand. Shep keeps the ledger (`bercail shep mistake`).
