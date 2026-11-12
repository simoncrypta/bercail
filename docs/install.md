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

mise holds back each new release for its first 24 hours (`minimum_release_age`), so right after a release `mise use` still installs the previous one. To take a newer release sooner, pin it: `mise use -g packslip:github.com/simoncrypta/bercail@<version>`.

The first install trusts the repository's signer, and later installs must match it. `bercail install` runs the release's own `install.sh`. mise or packslip keeps the `bercail` command, so the installer does not copy a second one into `~/.local/bin`. Upgrade with `mise up` (or `packslip install` again), then `bercail update`.

## curl

curl is still supported. It installs the latest release: bercail.dev serves `install.sh` from that release's tag, and the installer reads every file from that tag:

```bash
curl -fsSL https://bercail.dev/install.sh | bash
```

`--yes` is non-interactive (`bercail install --yes` too; through curl, `| bash -s -- --yes`). From a clone: `./install.sh`. The installer's flags are in [cli](cli.md#install--cli).

master is unreleased trunk; neither the curl install nor its `bercail update` reads it. To install another tag, a branch, or a commit, set `BERCAIL_REF` and take `install.sh` from the same ref (`curl -fsSL https://raw.githubusercontent.com/simoncrypta/bercail/master/install.sh | BERCAIL_REF=master bash`, or `BERCAIL_REF=v0.13.0 bercail update`).

## What the installer does

Bercail runs on the Herdr app. When it is missing, the installer runs [herdr.dev](https://herdr.dev)'s own installer (`~/.local`, no sudo), which brings herdr-core (`hc`); the app keeps both updated after that. The installer copies the bercail layout and its three mods into `~/.config/herdr-app`: `bercail-desk` (the desk and Review), `bercail-agents` (Herdr's agents list, with a row for each desk), and `bercail-review` (the Stack tab of a `bercail review-pr` space). It adds its keys to the `layout:bercail` section of `keys.json`. Switch to it once with `Ctrl+Shift+L` → bercail.

It also installs what bercail needs, and does a little extra on Omarchy, Linux, and macOS. See [development](development.md#dependencies) for the list and [platforms](development.md#platforms) for the details. Every file it writes is listed in [config](config.md#files-bercail-manages).

## From herdr.dev

The layout is also shared on its own at [herdr.dev/layouts](https://herdr.dev/layouts/): [`bercail/`](../bercail) holds the layout, its two mods, its keys, and a [RECIPE.md](../bercail/RECIPE.md). When you ask your agent to add it, the recipe tells it to ask you, install bercail with the commands above, switch to the layout, and then tell you the keys and commands to start with.

If you'd rather add only the layout, you get the desk and Review, but the desk runs plain `pi` instead of bstack, Review needs tuicr installed separately, and there are no worktree spaces, handoff, skills, or webhooks. It needs the Herdr app (`herdr-app`, `~/.config/herdr-app`), not the `herdr` terminal and its `herdr plugin` system.

## Updating from an older release

`bercail update` reaches this release from v0.14.0 or later. From an older one, install v0.14.0 first, then update:

```bash
curl -fsSL https://raw.githubusercontent.com/simoncrypta/bercail/v0.14.0/install.sh | BERCAIL_REF=v0.14.0 bash
bercail update
```

The first update to v1 removes the `agentic-dev` command (it is `bercail`), moves `~/.local/state/agentic-dev` (the handoff log) into `~/.local/state/bercail`, and leaves a link at the old path, which you can delete once nothing of yours reads it. Handoff records whose worktree and repo are both gone are dropped in the move.

Nothing stops an older release's `bercail update` from going straight to this one: it copies the new CLI with its own code and file lists, and this release takes the update over from there. That path is not tested, and the steps that carried older installs forward (the `agentic-dev` directories and shell markers, the 0.9 keys, old worktrunk config lines) are gone. From 0.8 (the Herdr terminal and its layout plugin), the full install above also adds the Herdr app. bercail no longer touches `~/.config/herdr`, the old plugin, or the `herdr` binary; remove them when you no longer need them.

## First run

Then, in a repo:

```bash
dev          # this directory's space, with its desk agent
# or: t      # open the Herdr app
```

With [bstack](bstack.md) on, a space starts its desk as bstack's Pi lead on its own, shown in the desk column. Quit it and it stays quit until `Ctrl+Shift+A` or `dev`, even across a reboot; one still running at shutdown [comes back](config.md#desks-after-a-reboot). With bstack off nothing starts on its own; `Ctrl+Shift+A` or `dev` starts plain `pi`.
