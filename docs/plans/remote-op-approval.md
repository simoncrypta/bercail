# A dev-only desk secret, so a desk's dev reads need nobody at omarchy

Written 2026-11-22 against `077a6c4` for bercail-9pva. A first draft compared
four options and recommended a laptop relay (C). Simon picked B on the panel
(Q378): restore the desk secret, scoped to a dev-only vault. That reopens
Lesentiel's one-vault rule (Q254) for one separate dev vault, and nothing else.

## Why

A desk's `op read` asks the 1Password app on omarchy, so its prompt shows on
omarchy's screen. From the laptop (a Herdr client of omarchy) nobody can
answer it. With B, a desk reads dev secrets through a read-only service
account and nothing prompts. In that repo plain `op` is the service account
for every read, so a production item fails there. A desk that needs one runs
`/usr/bin/op`, which skips the shim and asks the app as today.

## What comes back from 0895f89

- `lib/desk-secret.sh`: the `[desk_secrets."<repo>"] op_service_account` key,
  the check on the token file (yours, with no group or other access, in a
  folder with none either, outside every repo, not empty), and the doctor line `ok  desk secret for <repo>: present,
  0600, service account`.
- `bstack/pi/op-shim/op`: reads the file each time `op` runs, and gives the
  token only to the real `op`'s own environment. It runs `op` only from
  `/usr/bin`, `/usr/local/bin` or `/opt/homebrew/bin`, where you cannot write
  it, and strips the token from the commands `op run` and `op plugin run`
  start.
- The guard sets the shim on PATH at session start for a desk's lead, a
  builder, autopilot and a headless run. Shep, a background Shep, Discuss and
  the judge do not get it. For every role in that repo, it blocks naming the
  file or its folder, `systemd-creds decrypt`, `$OP_SERVICE_ACCOUNT_TOKEN`,
  printing the environment, listing the vault, and an `op read` that prints to
  the screen.
- `policy show --json` reports `desk_secret`, and the docs, help and tests
  that went with it.

## What changed from then

- **Why v0.18 removed it.** S6 and J8 found no repo using it. Nothing was
  wrong with the design. Lesentiel now has a use, so the reason no longer
  holds.
- **The limit it had stays.** The guard is a seatbelt: a desk runs as Simon,
  and a script the guard never sees can read the token file. B answers that
  with the token's scope, not with more guard rules. The token reads one vault
  of dev secrets, cannot write, and expires. Those are set in 1Password when
  the account is made: doctor checks only that the token is a service
  account.
- **Fitted to master.** The file check carries its own mode helper, since the
  notify sinks it used are gone. It now refuses a file whose mode it cannot
  read, where the old helper took it for 0600, and a new test covers that. The
  council is gone from the role list, and the scratch-repo fields are gone
  from the policy JSON. The policy lookup keeps master's name. The guard
  checks a tool's path against the secret before master's warning for a write
  under TMPDIR, which would otherwise let that write through.

## The dev-vault boundary

The dev vault holds secrets that let a desk build and test against dev
machines, and nothing that changes production, the tailnet's policy, or
money beyond a capped dev key. From Lesentiel's `docs/secrets.md` inventory:

| Item | In the dev vault |
|---|---|
| kvmd login, dev GLKVM | yes |
| `local-machine` password (test target) | yes |
| Tailscale policy-read | yes |
| Model API key, dev (low spend cap, wave 3) | yes, when it exists |
| Tailscale policy-write, kvm-tagger | no: tailnet changes Simon approves |
| Cloudflare deploy token, the four API keys, Access client secrets, client kvmd logins, production model keys, Tailscale admin and minter clients | no |

Move the dev items rather than copy them. A copy leaves a second record in
`lesentiel` that drifts on the next rotation. Moving an item between vaults
in 1Password likely gives it a new item ID, so Lesentiel's `op://`
references to it change (for example in `docs/poc-diagnostic.md`). That is
a Lesentiel change, made once the IDs are known.

Writes stay outside B. The account is read-only, and the keys Lesentiel mints
belong in `lesentiel`, a production vault. Simon writes them with his own
`op`, as today.

## What Simon does in 1Password

1. Create a vault `lesentiel-dev`.
2. Move the three dev items above from `lesentiel` into it, and the dev model
   key once it exists.
3. Create a service account `lesentiel-dev-desks` with `read_items` on
   `lesentiel-dev` only: no write, no share, no vault creation, no
   Environments, and an expiry. A service account's vaults cannot change once
   it is created, so `lesentiel-desks`, made for `lesentiel`, cannot be
   narrowed: revoke it.
4. Save the new token in his Personal vault, as the old one was.

Then on omarchy, in a shell (not a desk), with the token on the clipboard:

```sh
mkdir -m 700 -p ~/.config/bercail/secrets
(umask 077 && wl-paste >~/.config/bercail/secrets/lesentiel-dev.op)
```

And in `~/.config/bercail/config.toml`:

```toml
[desk_secrets."~/Work/lesentiel/lesentiel"]
op_service_account = "~/.config/bercail/secrets/lesentiel-dev.op"
```

`bercail doctor` then says `ok  desk secret for ~/Work/lesentiel/lesentiel:
present, 0600, service account`. A desk started after that reads
`op://lesentiel-dev/<item-id>/<field>` with no prompt.

## What B leaves open

A desk that needs a production item runs `/usr/bin/op`, and the app's prompt
shows on omarchy's screen, so from the laptop that read waits until Simon is
back. That is
deliberate: production stays behind his own approval.
