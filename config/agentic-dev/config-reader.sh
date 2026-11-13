# shellcheck shell=bash
# Nothing reads this file. It stays in the repo because a v0.14.0 `bercail
# update` fetches it by name and stops if it is missing; the new tree then
# removes the installed copy. config.toml is read by lib/toml.sh. Delete this
# once the oldest release that can update here no longer lists it.
