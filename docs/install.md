# install

## With Shep (recommended)

[Shep](https://x.ai/bot/Yber1TlDZinVy6FQZcPsF) is a Grok Bot template that knows how to install and set up bercail. Add it, connect this computer to it, and ask it to set up bercail. It asks before it runs anything.

## Install it yourself

The current release and its version pin are in the [README](../README.md#or-install-it-yourself). Below, `<version>` stands for that release.

## mise + packslip (recommended for a manual install)

[mise](https://mise.jdx.dev) + [packslip](https://github.com/jdx/packslip). Each `v*` release publishes `bercail.tar.gz` and a signed `packslip.sigstore.json`. mise checks that signature against this repository and the archive digest before it unpacks anything, and it runs no downloaded code.

```bash
mise use -g packslip:github.com/simoncrypta/bercail   # mise 2026.9.2+
bercail install                                       # full install from that release
```

Without mise, the packslip CLI installs the same release and links `bercail` into `~/.local/bin`:

```bash
packslip install github.com/simoncrypta/bercail      # packslip 1.5.1+
bercail install
```

mise holds back each new release for its first 24 hours (`minimum_release_age`), so right after a release `mise use` and `mise up` still install the previous one. To take bercail's releases the day they come out, exclude it from the hold once:

```bash
mise settings add minimum_release_age_excludes packslip:github.com/simoncrypta/bercail
```

Or pin one release: `mise use -g packslip:github.com/simoncrypta/bercail@<version>`. The tools bercail installs through mise (worktrunk, tuicr, beads, pi, jq, fzf) skip the hold: a minimum in `lib/deps.json` can move the day a release comes out.

The first install trusts the repository's signer, and later installs must match it. `bercail install` runs the release's own `install.sh`. mise or packslip keeps the `bercail` command, so the installer does not copy a second one into `~/.local/bin`. Upgrade with `mise up` (or `packslip install` again), then `bercail update`.

## curl

curl is still supported. It installs the latest release: bercail.dev serves `install.sh` from that release's tag, and the installer downloads that tag as one archive and unpacks it in `~/.local/share/bercail/release`, which `bercail update` replaces with the latest release:

```bash
curl -fsSL https://bercail.dev/install.sh | bash
```

`--yes` is non-interactive (`bercail install --yes` too; through curl, `| bash -s -- --yes`). From a clone: `./install.sh`. The installer's flags are in [cli](cli.md#install--cli).

master is unreleased trunk; neither the curl install nor its `bercail update` reads it. To install another tag, a branch, or a commit, set `BERCAIL_REF` and take `install.sh` from the same ref (`curl -fsSL https://raw.githubusercontent.com/simoncrypta/bercail/master/install.sh | BERCAIL_REF=master bash`). `BERCAIL_REF=<tag> bercail update` works for a release after v0.14.0; for v0.14.0 or older, use that tag's own `install.sh` the same way.

## What the installer does

Bercail runs on the Herdr app. When it is missing, the installer runs [herdr.dev](https://herdr.dev)'s own installer (`~/.local`, no sudo), which brings herdr-core (`hc`); the app keeps both updated after that. The installer copies the bercail layout and its three mods into `~/.config/herdr-app`: `bercail-desk` (the desk and Review), `bercail-agents` (Herdr's agents list, with a row for each desk), and `bercail-review` (the Stack tab of a `bercail review-pr` space). It adds its keys to the `layout:bercail` section of `keys.json`. Switch to it once with `Ctrl+Shift+L` → bercail.

It also installs what bercail needs, and does a little extra on Omarchy, Linux, and macOS. See [development](development.md#dependencies) for the list and [platforms](development.md#platforms) for the details. Every file it writes is listed in [config](config.md#files-bercail-manages).

## From herdr.dev

The layout is also shared on its own at [herdr.dev/layouts](https://herdr.dev/layouts/): [`bercail/`](../bercail) holds the layout, its two mods, its keys, and a [RECIPE.md](../bercail/RECIPE.md). When you ask your agent to add it, the recipe tells it to ask you, install bercail with the commands above, switch to the layout, and then tell you the keys and commands to start with.

If you'd rather add only the layout, you get the desk and Review, but the desk runs plain `pi` instead of bstack, Review needs tuicr installed separately, and there are no worktree spaces, handoff, skills, or Shep. It needs the Herdr app (`herdr-app`, `~/.config/herdr-app`), not the `herdr` terminal and its `herdr plugin` system.

## Updating from an older release

`bercail update` reaches this release from v0.15.0 or later. An install at v0.14.0 or older cannot update in place. v0.14.0's `bercail update`, for one, stops on `bin/agentic-dev`, a file this release no longer ships, after it has copied the new `bercail` command and shell files. Reinstall instead, with any install above (from a clone, `./install.sh`). It keeps your `config.toml`.

A reinstall over v0.14.0 or older leaves two things behind: the `agentic-dev` command in `~/.local/bin` (it runs `bercail`) and `~/.local/state/agentic-dev`, where those releases kept the handoff log. bercail reads neither; delete them once nothing of yours uses them.

An update rewrites `[graphite]` entries in `config.toml`, a name v1 no longer reads, as `[git]` entries (`true` is `"gt"`, `false` is `"gh"`).

`handoff-spawn` prints one name for each fact from v1 on. If a script of yours reads its JSON: `graphite` is gone (read `git`: `gh`, `gt` or `origin`), `socket` is gone (read `herdr`), `workspace` is gone (read `space`), and `--workspace` is `--space`.

bstack has no switch from v1 on: `bercail bstack on` and `off`, `./install.sh --no-bstack`, and `[bstack] enabled` are gone. The first update removes `enabled` from `config.toml`. If it was `false`, or the install was made with `--no-bstack`, that update sets up bstack's Pi profile and says so: the desk then runs bstack's lead with bercail's [guard](config.md#git-policy-per-repo), where it ran plain `pi`. Restoring an old plain-Pi desk also loads the current lead, keeping its session and any saved model or tool flags. Desks that already recorded the guard or the read-only review profile keep that profile.

The shell block no longer defines `t` (open the Herdr app) and `d` (short for `dev`), and no longer removes an alias of yours by those names. If you used them, add `alias t=herdr-app` or `alias d=dev` to your own shell rc, after bercail's block.

From 0.8 (the Herdr terminal and its layout plugin), the full install above also adds the Herdr app. bercail no longer touches `~/.config/herdr`, the old plugin, or the `herdr` binary; remove them when you no longer need them.

## A laptop, with bercail on another machine

A Herdr window on a laptop can drive bercail on another machine (here `box`): Shep, the desks, repos, Pi and its logins, beads, tuicr and worktrunk all stay on `box`, and the laptop gets only the Herdr app half. [bercail on another machine](config.md#bercail-on-another-machine) says what the mods then do, and what does not work across machines yet.

1. On `box`, install bercail as above, if it is not there yet.
2. On the laptop, install the [Herdr app](https://herdr.dev) and add `box`: `hc machine add box` (any target ssh reaches, `--name box` to choose the name). `hc machine ls` shows it. Herdr puts `hc` on `box` if it has none.
3. On the laptop, get bercail's files at the version `box` runs, and install the client half from them:

   ```bash
   git clone https://github.com/simoncrypta/bercail ~/Work/bercail
   git -C ~/Work/bercail switch --detach v<version>   # or the commit box runs
   ~/Work/bercail/install.sh --client box
   ```

   Or from the release `box` runs: `curl -fsSL https://raw.githubusercontent.com/simoncrypta/bercail/v<version>/install.sh | BERCAIL_REF=v<version> bash -s -- --client box`, or `mise use -g packslip:github.com/simoncrypta/bercail@<version> && bercail install --client box`. Without the version, both take the latest release.
4. `bercail doctor` on the laptop checks the Herdr app, the layout, mods and keys, that `hc` reaches `box`, and that `box` runs the same bercail version. Open the window, switch to the bercail layout (`Ctrl+Shift+L`), and `box`'s spaces, Shep and desks are there.

`--client box` installs the `bercail` command (`~/.local/bin/bercail` and its `lib/`), the layout, the five mods, the `layout:bercail` keys, and `[herdr] backend = "box"` in `~/.config/bercail/config.toml`, keeping anything else in that file. It installs the Herdr app and `jq` if they are missing, and nothing else: no shell block, worktrunk hooks, skills, Pi, bstack, Shep, tuicr or Omarchy extras. It removes nothing an earlier full install left, and a client doctor does not look at those parts: on a laptop that had one, run `bercail uninstall` first (answer no to removing `~/.config/bercail`), then `--client`.

It records the mode in `~/.local/share/bercail/install-mode`. From then on, `bercail update`, `install.sh` without `--client`, and `bercail dry-run` stay client-only, `bercail doctor` checks only the above, and `bercail reconfigure` refuses (it belongs on `box`). `--client <other>` points the laptop at another machine. To make the laptop a full install, delete that file and `[herdr] backend` from `config.toml`, then install again.

Update both together: `bercail update` on `box`, then on the laptop. The mods on the laptop call `box`'s bercail, so a version apart can break them; doctor says when the versions differ, and which one to update.

On a laptop installed from a clone, `bercail update` first fetches the latest release's tag from github.com/simoncrypta/bercail (never the clone's `origin`, which may be a fork, and never `box`). It deploys only when the clone is checked out at that tag's commit with no changes. Otherwise it deploys nothing, exits 1, and prints the command that checks the release out:

```bash
git -C ~/Work/bercail fetch --no-tags https://github.com/simoncrypta/bercail refs/tags/v<version> && git -C ~/Work/bercail switch --detach FETCH_HEAD
```

`BERCAIL_REF=v<version> bercail update` checks the clone against that release instead, for a `box` that runs an older one; it takes a tag only. `BERCAIL_REF=HEAD bercail update` deploys the clone as it sits, with a warning that it is a dev build. Two clones of master both report master's version, so doctor cannot tell their commits apart. A laptop that ran a bercail older than this check still copies its clone as it sits: check the release out once with the command above, then run `bercail update`.

**Why a clone, not a copy from `box`.** The laptop could copy bercail's files from `box` over `hc`, and always match it. Then `box` would choose the code the laptop runs: the mods are unrestricted code with the laptop's access to every machine it added. Today trust goes one way, the laptop runs things on `box` and nothing on `box` reaches the laptop; a copy from `box` would turn that around. A clone or a release comes from the same source `box` was installed from, and doctor catches a version apart.

## First run

Then, in a repo:

```bash
dev          # this directory's space, with its desk agent
# or: t      # open the Herdr app
```

A space starts its desk as [bstack](bstack.md)'s Pi lead on its own, shown in the desk column. Quit it and it stays quit until `Ctrl+Shift+A` or `dev`, even across a reboot; one still running at shutdown [comes back](config.md#desks-after-a-reboot).
