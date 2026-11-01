# install

The current release and its version pin are at the top of the [README](../README.md#quick-start). Below, `<version>` stands for that release.

## mise + packslip (recommended)

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

curl is still supported. It reads the repository tip and does not need a release:

```bash
curl -fsSL https://setup.simoncrypta.dev/install.sh | bash
```

`--yes` is non-interactive (`bercail install --yes` too; through curl, `| bash -s -- --yes`). From a clone: `./install.sh`. The installer's flags are in [cli](cli.md#install--cli).

## What the installer does

Bercail runs on the Herdr app. When it is missing, the installer runs [herdr.dev](https://herdr.dev)'s own installer (`~/.local`, no sudo), which brings herdr-core (`hc`); the app keeps both updated after that. The installer copies the bercail layout and its two mods into `~/.config/herdr-app`: `bercail-desk` (the desk and Review) and `bercail-agents` (Herdr's agents list, with a row for each desk). It adds its keys to the `layout:bercail` section of `keys.json`. Switch to it once with `Ctrl+Shift+L` → bercail.

It also installs what bercail needs, and does a little extra on Omarchy, Linux, and macOS. See [development](development.md#dependencies) for the list and [platforms](development.md#platforms) for the details. Every file it writes is listed in [config](config.md#files-bercail-manages).

## From herdr.dev

The layout is also shared on its own at [herdr.dev/layouts](https://herdr.dev/layouts/): [`bercail/`](../bercail) holds the layout, its two mods, its keys, and a [RECIPE.md](../bercail/RECIPE.md). When you ask your agent to add it, the recipe tells it to ask you, install bercail with the commands above, switch to the layout, and then tell you the keys and commands to start with.

If you'd rather add only the layout, you get the desk and Review, but the desk runs `cursor-agent` (or your `[agent] command`) instead of bstack, Review needs tuicr installed separately, and there are no worktree spaces, handoff, skills, or webhooks. It needs the Herdr app (`herdr-app`, `~/.config/herdr-app`), not the `herdr` terminal and its `herdr plugin` system.

## Coming from 0.8

From 0.8 (the Herdr terminal and its layout plugin): run the full install once (`bercail install`, or the curl line) so it adds the Herdr app; `bercail update` alone doesn't install the Herdr app or the other dependencies (it only adds the desk agent and the review tool when they are missing). bercail no longer touches `~/.config/herdr`, the old plugin, or the `herdr` binary; remove them when you no longer need them. Webhook sinks in `notify.d` keep working, but their payload is now `bercail.agent_status/v2` (see [agent status webhooks](shep.md#agent-status-webhooks)).

## First run

Then, in a repo:

```bash
dev          # this directory's space, with its desk agent
# or: t      # open the Herdr app
```

With [bstack](bstack.md) on, a space starts its desk as bstack (opencode with your terminal's colors) on its own, shown in the desk column. Quit it and it stays quit until `Ctrl+Shift+A` or `dev`. With bstack off nothing starts on its own; `Ctrl+Shift+A` or `dev` starts `[agent] command` from `~/.config/bercail/config.toml`. Handoff stages do not read either; each stage names its own binary.
