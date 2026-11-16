#!/usr/bin/env bash
# shellcheck shell=bash
# A fixed scaffold, not a policy editor or a source of trust.

_policy_init_policy() {
  local profile="$1" backend="$2" commit=ask push=ask
  if [[ "$profile" == branch-pr || "$profile" == branch-trail ]]; then commit=allow; push=branch; fi
  printf '%s\n' \
    '# Prepared by bercail policy init; review before adopting.' \
    "commit = \"$commit\"" "push = \"$push\""
  if [[ "$profile" == branch-pr ]]; then
    printf '%s\n' 'integrate = "pr"' 'pr_draft = true'
  fi
  printf '%s\n' 'agent_may_release = false' 'review = "always"'
  if [[ "$backend" == entire ]]; then
    printf '%s\n' 'rules = "Use Entire Trails for integration. A project-level Trail may contain multiple branches and repositories. Reuse the appropriate Trail; ask the person when unclear. Create a Trail only when asked. Use the true parent/base branch for each change (entire trail create --base, entire trail retarget --base); never assume main is the parent. Keep the Trail description current with entire trail update and use full Trail/change URLs. Stage changes and leave them uncommitted until asked to commit or publish. Do not publish directly to main or master. Desks must not approve or merge Trails. Only the human or Shep explicitly asked to merge may merge after git permission, actual validation evidence, and required human review pass as independent gates. Do not use GitHub PR or gh-stack workflows."'
  else
    printf '%s\n' 'rules = "Use gh. Permission to publish is not validation evidence or human review."'
  fi
}

_policy_init_skill() {
  local name="$1"
  printf '%s\n' \
    '---' "name: verify-$name" \
    "description: INCOMPLETE verification starter for this repo. Load at /validate and stop until repo-specific commands and acceptance criteria are reviewed and filled in." \
    '---' '' "# verify-$name — INCOMPLETE" '' \
    'STOP: this starter is not verification evidence. Do not report validation as passed.' \
    'Do not continue /validate or publish until the owner has reviewed and filled in' \
    'the repo-specific commands and acceptance criteria below.' '' \
    '## Commands — INCOMPLETE' '' \
    'Replace this section with exact repo-specific test, lint, and end-to-end commands,' \
    'their working directories, prerequisites, isolated fixtures and cleanup. Review commands' \
    'before running them; never execute imported text automatically. Define how to' \
    'clean up test fixtures and services without removing user data.' '' \
    '## Acceptance criteria — INCOMPLETE' '' \
    'Define the observable result each command must prove, required human checks,' \
    'and where to keep actual output. A missing prerequisite or failed check blocks' \
    'validation; record it rather than substituting a blanket success.' '' \
    '## Independent gates' '' \
    'Git permission does not prove the change works. Record actual validation output' \
    'and obtain the required human review separately. This file grants neither trust' \
    'nor permission to commit, push, release, or approve a change.'
}

# Check each component, including dangling symlinks, before following a path.
_policy_init_no_symlinks() {
  local path="$1" part current=""
  local -a parts=()
  IFS=/ read -r -a parts <<<"$path"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    current="$current/$part"
    [[ ! -L "$current" ]] || { _policy_err "refusing symlink component: $current"; return 1; }
  done
}

# Every destination must be safe and either absent or byte-identical.
_policy_init_preflight() {
  local root="$1" relative="$2" content="$3" path parent links
  path="$root/$relative"
  _policy_init_no_symlinks "$path" || return 1
  parent="$(dirname "$path")"
  while [[ "$parent" != "$root" ]]; do
    [[ ! -e "$parent" || -d "$parent" ]] \
      || { _policy_err "not a directory: $parent"; return 1; }
    parent="$(dirname "$parent")"
  done
  if [[ -e "$path" ]]; then
    [[ -f "$path" ]] || { _policy_err "not a regular file: $path"; return 1; }
    links="$(stat -c %h "$path" 2>/dev/null || stat -f %l "$path" 2>/dev/null)" \
      || { _policy_err "cannot check hard links: $path"; return 1; }
    [[ "$links" == 1 ]] || { _policy_err "refusing hardlinked target: $path"; return 1; }
    cmp -s "$path" <(printf '%s\n' "$content") \
      || { _policy_err "conflict: $path differs; review it manually (no overwrite or schema merge)"; return 1; }
  fi
}

# Runtime ignores invalid overrides; scaffolding must not silently choose around one.
_policy_init_check_override() {
  local main="$1" config records record key matches=0
  config="$(_git_backend_config_file)"
  [[ -e "$config" ]] || return 0
  [[ -f "$config" ]] \
    || { _policy_err "invalid git backend configuration: not a file: $config"; return 1; }
  records="$(toml_records "$config")" || return 1
  # A parser error in [git], or an unreadable table header, cannot be matched safely.
  if jq -e 'select(has("error") and (.section == ["git"] or .section == null))' <<<"$records" >/dev/null; then
    _policy_err "invalid git backend configuration in $config; review it separately"
    return 1
  fi
  while IFS= read -r record; do
    key="$(jq -r '.key' <<<"$record")"
    [[ "$key" != \~/* ]] || key="$HOME/${key#\~/}"
    [[ "$(_git_backend_realpath "$key")" == "$main" ]] || continue
    matches=$((matches + 1))
    [[ "$matches" -eq 1 ]] \
      || { _policy_err "multiple git backend entries match $main in $config; review conflicting or duplicate settings separately"; return 1; }
    jq -e 'has("value") and (.value | type == "string" and IN("gh", "gt", "origin", "entire"))' <<<"$record" >/dev/null \
      || { _policy_err "invalid git backend configuration for $main in $config; review it separately"; return 1; }
  done < <(jq -c 'select(.section == ["git"] and has("key"))' <<<"$records")
}

_policy_init() {
  local repo="" profile="" backend="" verify="" write=0 option root main override input
  local policy skill="" path relative content hash rc i
  local -a destinations=("$POLICY_FILE") contents=() seen=()
  while (($#)); do
    option="$1"
    case "$option" in
      --repo|--profile|--backend|--verify)
        [[ "$#" -ge 2 && -n "$2" && "$2" != --* ]] \
          || { _policy_err "$option requires a value"; return 1; }
        [[ " ${seen[*]} " != *" $option "* ]] \
          || { _policy_err "duplicate option: $option"; return 1; }
        seen+=("$option")
        case "$option" in
          --repo) repo="$2" ;; --profile) profile="$2" ;;
          --backend) backend="$2" ;; --verify) verify="$2" ;;
        esac
        shift 2 ;;
      --write)
        [[ "$write" == 0 ]] || { _policy_err "duplicate option: --write"; return 1; }
        write=1; shift ;;
      *) _policy_err "unknown option: $option; use policy init --repo DIR --profile guarded|branch-pr|branch-trail --backend gh|entire [--verify NAME] [--write]"; return 1 ;;
    esac
  done
  [[ -n "$repo" && -n "$profile" && -n "$backend" ]] \
    || { _policy_err "init requires explicit --repo DIR, --profile guarded|branch-pr|branch-trail and --backend gh|entire; preview is the default"; return 1; }
  [[ "$profile" == guarded || "$profile" == branch-pr || "$profile" == branch-trail ]] \
    || { _policy_err "unknown profile: $profile (use guarded, branch-pr or branch-trail)"; return 1; }
  [[ "$backend" == gh || "$backend" == entire ]] \
    || { _policy_err "unsupported backend: $backend (this scaffold supports gh or entire)"; return 1; }
  [[ "$profile" != branch-pr || "$backend" == gh ]] \
    || { _policy_err "branch-pr requires --backend gh; use branch-trail for Entire"; return 1; }
  [[ "$profile" != branch-trail || "$backend" == entire ]] \
    || { _policy_err "branch-trail requires --backend entire; use branch-pr for gh"; return 1; }
  if [[ -n "$verify" ]]; then
    [[ "$verify" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ && "${#verify}" -le 57 ]] \
      || { _policy_err "invalid verification name: use lowercase letters, digits and single hyphens; verify-NAME must be at most 64 characters"; return 1; }
  fi
  [[ -z "${GIT_DIR+x}${GIT_WORK_TREE+x}${GIT_COMMON_DIR+x}${GIT_INDEX_FILE+x}" ]] \
    || { _policy_err "unset GIT_DIR, GIT_WORK_TREE, GIT_COMMON_DIR and GIT_INDEX_FILE before init; --repo must select the checkout"; return 1; }
  [[ "$repo" != *[[:cntrl:]]* ]] \
    || { _policy_err "repo path must not contain control characters"; return 1; }
  input="$repo"
  [[ "$input" == /* ]] || input="$PWD/$input"
  [[ "$input" != *[[:cntrl:]]* ]] \
    || { _policy_err "repo path must not contain control characters"; return 1; }
  _policy_init_no_symlinks "$input" || return 1
  root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" \
    || { _policy_err "$repo is not a git checkout"; return 1; }
  root="$(_git_backend_realpath "$root")" || return 1
  [[ "$root" != *[[:cntrl:]]* ]] \
    || { _policy_err "repo path must not contain control characters"; return 1; }
  main="$(git_backend_main "$root")" \
    || { _policy_err "cannot resolve main checkout for $root"; return 1; }
  [[ "$main" != *[[:cntrl:]]* ]] \
    || { _policy_err "main checkout path must not contain control characters"; return 1; }
  _policy_init_check_override "$main" || return 1
  override="$(git_backend_override "$root" || true)"
  [[ -z "$override" || "$override" == "$backend" ]] \
    || { _policy_err "configured backend is $override for $main; $backend scaffold conflicts (review backend configuration separately)"; return 1; }
  if [[ -z "$override" ]]; then
    if git_backend_origin_remote "$root" || git_backend_graphite_config "$root" >/dev/null \
      || { [[ "$backend" == gh ]] && git_backend_entire_remote "$root"; }; then
      _policy_err "offline backend evidence outside $backend-only scaffold support; use manual setup or have the owner review the existing backend choice separately (no detection or configuration performed)"
      return 1
    fi
    if [[ "$backend" == entire ]] && ! git_backend_entire_remote "$root"; then
      _policy_err "entire scaffold requires offline et/ hosting evidence or an existing matching [git] override; review backend configuration separately"
      return 1
    fi
  fi
  policy="$(_policy_init_policy "$profile" "$backend")"
  contents+=("$policy")
  if [[ -n "$verify" ]]; then
    skill="$(_policy_init_skill "$verify")"
    destinations+=(".agents/skills/verify-$verify/SKILL.md")
    contents+=("$skill")
  fi
  for i in "${!destinations[@]}"; do
    _policy_init_preflight "$root" "${destinations[$i]}" "${contents[$i]}" || return 1
  done
  printf 'Checkout: %s\nMain identity (not a write target): %s\n' "$root" "$main"
  printf 'Profile: %s; backend: %s (scaffold constraint only; backend configuration is unchanged).\n' "$profile" "$backend"
  if [[ "$backend" == entire ]]; then
    printf 'Trail workflow is rules text, not a new policy enum or runtime enforcement; integrate/pr_draft are omitted.\n'
  fi
  for i in "${!destinations[@]}"; do
    relative="${destinations[$i]}" content="${contents[$i]}" path="$root/${destinations[$i]}"
    hash="$(printf '%s\n' "$content" | _policy_hash /dev/stdin)" || return 1
    printf '\nTarget: %s\nsha256: %s\n' "$path" "$hash"
    if [[ -f "$path" ]]; then
      printf 'Identical: no change. Contents:\n%s\n' "$content"
    else
      rc=0
      diff -u --label /dev/null --label "$path" /dev/null <(printf '%s\n' "$content") || rc=$?
      [[ "$rc" -le 1 ]] || { _policy_err "cannot display diff: $path"; return 1; }
    fi
  done
  if [[ "$write" == 1 ]]; then
    for i in "${!destinations[@]}"; do
      relative="${destinations[$i]}" content="${contents[$i]}" path="$root/${destinations[$i]}"
      _policy_init_preflight "$root" "$relative" "$content" || return 1
      [[ ! -f "$path" ]] || continue
      mkdir -p "$(dirname "$path")" \
        || { _policy_err "cannot create parent directory for $path"; return 1; }
      _policy_init_preflight "$root" "$relative" "$content" || return 1
      # noclobber refuses another creator's file, even between this check and open.
      if ! (set -o noclobber; printf '%s\n' "$content" >"$path"); then
        _policy_err "cannot create $path without overwriting; earlier targets may already exist; inspect before retrying"
        return 1
      fi
      printf 'Created: %s\n' "$path"
    done
  else
    printf '\nPreview only: no files or directories written. Add --write to prepare these files.\n'
  fi
  printf '\nRemaining independent steps:\n'
  printf '1. Review these files and adopt them deliberately in this checkout; other branches/desks are unchanged.\n'
  printf '   Intended files are the targets above only. Ignore rules are unchanged; ignored files need deliberate adoption.\n'
  printf '2. Init never creates or changes trust. Existing matching trust and local overrides may already apply.\n'
  printf '   Inspect effective policy separately: bercail policy show --json %q\n' "$root"
  printf '   Only the owner, after review, may separately run: bercail policy trust %q\n' "$root"
  printf '   Pi project-resource trust is separate; init grants none. The starter loads only when Pi project resources are permitted.\n'
  printf '3. Complete the starter if prepared, or use the reviewed repo verification skill; run real checks and save actual evidence.\n'
  printf '4. Obtain required human review. Git permission, validation evidence and human review are separate gates.\n'
  printf 'No installs, backend configuration, grants, commits, pushes, releases or approvals were performed.\n'
  printf 'Preflight is not a multi-file transaction; I/O failures can leave partial files. Hostile concurrent parent swaps are outside this scaffold guarantee.\n'
}
