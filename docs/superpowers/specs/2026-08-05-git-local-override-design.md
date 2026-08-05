# Git Local-Override Mode

**Date:** 2026-08-05
**Status:** Approved, pending implementation
**Scope:** Add a boolean knob (`git.allow_local_operations`) and CLI flag (`--allow-local-git`) that switches the git wrapper into a mode where only `git push` is blocked and all local operations are allowed unconditionally. User `policy.allow`/`block` rules are ignored in this mode.

## Goal

The default git wrapper policy blocks ~12 local subcommands and many flag-level forms to prevent accidental damage (history rewriting, work discarding, config tampering). This is the right default for autonomous `--dangerously-skip-permissions` operation.

However, there are times when the user trusts the agent with local repository operations and wants to lift the local-only restrictions for a session - without losing the remote push protection. Today the only way to do this is to enumerate every operation in `git.policy.allow`, which is verbose and must be repeated per workspace or per invocation.

The new flag provides a single coarse switch: "allow all local operations, keep blocking remote (push)." It is intended for quick command-line override:

```sh
claude-sandboxed --allow-local-git
```

## Non-goals

- **Allowing `git push`.** Push stays blocked at the wrapper level and via the system git config in the entrypoint (defense in depth). The flag is about local operations only.
- **Granular custom modes.** The existing `git.policy.allow`/`block` regex lists already cover granular custom policies. The new flag is a coarse binary switch, not a replacement for that machinery.
- **Per-operation authorization flow.** No new unlock UI. The user authorizes by setting the flag.
- **Mode enum.** A `git.policy.mode: default | local-only | permissive` enum was considered and rejected for now - the boolean is simpler and matches the "quick override from command line" intuition. There is a direct migration path to an enum if more modes are needed later (see [Extensibility](#extensibility)).
- **A `--no-allow-local-git` CLI variant.** Disabling from CLI when config has it on is done via `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=false` env var.

## Semantics

When `git.allow_local_operations` is `true`:

- The wrapper blocks only `git push`.
- User `policy.allow`/`block` rules are ignored entirely.
- All other operations are allowed, including: `reset --hard`, `rebase`, `filter-branch`, `filter-repo`, `clean`, `config`, `commit-tree`, `update-ref`, `replace`, `fast-import`, `prune`, `symbolic-ref`, `reflog expire|delete`, `notes remove|prune`, `worktree remove|prune`, `stash drop|clear`, `branch -D`, `tag -f`, `commit --amend|--reset-author`, `checkout -B|-f|-- <pathspec>`, `switch -C|--discard-changes`, `restore --worktree|-W`, `rm` (without `--cached`), `gc --prune`.

Unchanged when `true`:

- System git config in the container entrypoint (SSH push block + GitHub URL rewrite) remains as defense-in-depth.
- `IS_SANDBOX=1` and all other invariants from `docs/development.md`.
- The `git-wrapper` bind mount, `/usr/local/bin` preceding `/usr/bin` in `PATH`, etc.

## Knob naming

| Source | Name |
|---|---|
| Config (YAML) | `git.allow_local_operations: true` |
| CLI flag | `--allow-local-git` |
| Env var (host, resolved by launcher) | `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` |
| Env var (passed into container) | `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS` (same name) |

Precedence (consistent with existing knobs): env var > workspace config > user config > default (`false`). The CLI flag sets the env var to `true`.

## Implementation

### `bin/claude-sandboxed` (launcher)

1. **Parse the CLI flag** in `parse_launcher_args()`. Add a case to the existing `while` loop, following the same pattern as `--tool` (store in a CLI-specific variable, resolve later):

   ```bash
   --allow-local-git)
       CLI_ALLOW_LOCAL_GIT=true
       shift
       ;;
   ```

   Also initialize `CLI_ALLOW_LOCAL_GIT=""` at the top of `parse_launcher_args()`, next to the existing `CLI_TOOL=""` initialization. The flag is a boolean (presence = `true`). No value accepted. Unknown options before `--` still error out as today.

2. **Resolve the knob** after the existing git policy resolution (after the `SANDBOX_GIT_POLICY_ALLOW`/`BLOCK` `resolve_list` calls). Follow the `resolve_tool` pattern - CLI value takes precedence over `resolve()`:

   ```bash
   if [[ -n "${CLI_ALLOW_LOCAL_GIT:-}" ]]; then
       SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS="$CLI_ALLOW_LOCAL_GIT"
   else
       SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS="$(resolve SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS .git.allow_local_operations false)"
   fi
   ```

3. **Warn on conflicting config** - after resolving, if `allow_local_operations == true` AND (`SANDBOX_GIT_POLICY_ALLOW` or `SANDBOX_GIT_POLICY_BLOCK` is non-empty), print to stderr:

   ```
   claude-sandboxed: git.allow_local_operations is enabled; git.policy.allow/block rules will be ignored.
   ```

   Non-fatal - the launcher continues. This catches the case where a user has both set and doesn't realize the policy rules are inert.

4. **Pass to container** - add a new env arg array, conditionally filled:

   ```bash
   GIT_MODE_ENV_ARGS=()
   if [[ "$SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS" == "true" ]]; then
       GIT_MODE_ENV_ARGS+=(-e SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true)
   fi
   ```

   Insert `"${GIT_MODE_ENV_ARGS[@]}"` into the `docker compose run` command (between `"${GIT_ENV_ARGS[@]}"` and `"${GIT_VOLUME_ARGS[@]}"` is a reasonable spot).

### `share/claude-sandboxed/git-wrapper`

Add an override gate after the subcommand is parsed (after the `if [[ -z "$subcommand" ]]; then exec "$REAL_GIT" "$@"; fi` block, before the `POLICY_FILE` block):

```bash
# --- Local-override mode ---
# When enabled, only push is blocked; user policy file and built-in
# default blocks are skipped entirely.
ALLOW_LOCAL="${SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS:-false}"
if [[ "$ALLOW_LOCAL" == "true" ]]; then
    if [[ "$subcommand" == "push" ]]; then
        echo "[SECURITY] git push is blocked by claude-sandboxed." >&2
        echo "[SECURITY] Local-override mode is active: all local operations are allowed; only remote-affecting operations (push) are blocked." >&2
        echo "[SECURITY] Reconsider whether pushing to remote aligns with the user's intent." >&2
        echo "[SECURITY] The sandbox is for autonomous work. Do not ask the user to authorize individual operations; escalate only as a last resort if no in-sandbox approach exists." >&2
        exit 1
    fi
    exec "$REAL_GIT" "$@"
fi
```

**Placement rationale**: before the `POLICY_FILE` block so the user policy file is also skipped. The existing `block()` helper isn't reused because its second hardcoded line ("other destructive operations are generally prohibited") would be inaccurate in override mode.

No other wrapper changes needed - the rest of the policy logic is untouched and remains the default-mode path.

### `share/claude-sandboxed/config.example.yaml`

Add under the `git:` section, after `host_config_passthrough` and before `policy:`:

```yaml
  # When true, the wrapper blocks only git push and allows all local
  # operations unconditionally (reset --hard, commit --amend, branch -D,
  # config, rebase, etc.). User policy.allow/block rules are ignored.
  # Useful for quick override from the command line: --allow-local-git.
  # Default: false.
  # allow_local_operations: false
```

### `docs/development.md`

Update invariants:

- Add `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS` to the launcher-side-only env list (the bullet starting with "`SANDBOX_TOOL`, all `CLAUDE_*` and all `CODEX_*` profile knobs, `SANDBOX_PROXY_ENV_PASSTHROUGH`, `SANDBOX_CLEANUP`, `SANDBOX_GIT_POLICY_ALLOW`, and `SANDBOX_GIT_POLICY_BLOCK`..."). `GIT_MODE_ENV_ARGS` follows the same conditional-fill pattern as `GIT_ENV_ARGS` and `PROXY_ENV_ARGS` (only populated when the knob is `true`).
- Add manual test checklist items for override mode (see [Testing](#testing) below).

### `README.md`

Add a new subsection "### Local-override mode" under "### Git policy config" (or as a peer subsection). Content:

> When `git.allow_local_operations` is `true`, the wrapper blocks only `git push` and allows all local operations unconditionally - including `reset --hard`, `commit --amend`, `branch -D`, `clean -fd`, `rebase`, `config`, and the history-bypass plumbing commands. User `policy.allow`/`block` rules are ignored entirely in this mode.
>
> Intended for quick override from the command line when you trust the agent with local repository operations:
>
> ```sh
> claude-sandboxed --allow-local-git
> ```
>
> Remote push protection is unchanged: the wrapper still blocks `git push`, and the system git config in the container entrypoint still blocks SSH pushes and rewrites GitHub URLs to `https://prohibited/` as defense in depth.
>
> A warning is printed to stderr when `allow_local_operations: true` is combined with non-empty `policy.allow` or `policy.block`, since the policy rules become inert in override mode.

Also:

- Add `allow_local_operations: false  # bool, default: false` to the schema block under `git:` (between `host_config_passthrough` and `policy:` matches the order in `config.example.yaml`).

## Testing

### `tests/git-wrapper/test.sh`

Add new test helpers that accept an env prefix, or parameterize the existing `assert_blocked` / `assert_allowed` helpers. Then add a section:

- `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` + `git push` -> blocked
- `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` + `git push origin main` -> blocked
- `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` + `git reset --hard HEAD~1` -> allowed
- `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` + `git commit --amend` -> allowed
- `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` + `git branch -D x` -> allowed
- `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` + `git config user.name X` -> allowed
- `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` + `git clean -fd` -> allowed
- `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` + `git rebase main` -> allowed
- `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` + `git stash drop` -> allowed
- `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` + `git update-ref refs/heads/x HEAD` -> allowed
- `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` + `git commit-tree HEAD` -> allowed
- `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` + `git tag -f v1` -> allowed
- `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` + `git checkout -B x` -> allowed
- `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` + `git status` -> allowed (default-allowed op still allowed)
- `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` + user `GIT_POLICY_FILE` with `[block] "^status"` -> `git status` still allowed (policy file ignored)
- `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` + user `GIT_POLICY_FILE` with `[allow] "^push"` -> `git push` still blocked (policy file ignored)

### `tests/launcher/test.sh`

- `parse_launcher_args --allow-local-git` -> `CLI_ALLOW_LOCAL_GIT == true`
- `parse_launcher_args` (no flag) -> `CLI_ALLOW_LOCAL_GIT` unset (empty)
- `parse_launcher_args --allow-local-git --tool codex` -> both `CLI_ALLOW_LOCAL_GIT` and `CLI_TOOL` set
- Resolution precedence: env var > workspace config > user config > default (covered by the existing `resolve()` test pattern; add one case for `.git.allow_local_operations`)
- Warning emitted when `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` AND (`SANDBOX_GIT_POLICY_ALLOW` or `SANDBOX_GIT_POLICY_BLOCK` non-empty): capture stderr, grep for `git.allow_local_operations is enabled; git.policy.allow/block rules will be ignored.`
- Warning not emitted when override is on and policy lists are empty
- Warning not emitted when override is off
- `GIT_MODE_ENV_ARGS` contains `-e SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true` when override is on; empty when off

### `tests/config/test.sh`

- Add `git.allow_local_operations` to the YAML schema validation tests (true/false/null parsing, precedence).

### Manual testing checklist (added to `docs/development.md`)

- Inside container with `--allow-local-git`: `git push` blocked, `git reset --hard`, `git commit --amend`, `git config user.name X`, `git clean -fd`, `git rebase` all work.
- `cat /etc/claude-sandboxed/git-policy.conf` shows the policy file is still mounted (when configured) but ignored by the wrapper.
- Warning printed to stderr on host when both override and policy lists are configured.

## Extensibility

The boolean flag is effectively a "mode shortcut." The wrapper structure isolates the override path at the top, so extension points are clear:

1. **Add another boolean** - works if modes don't conflict. Cheap, no breaking change.
2. **Promote to a mode enum** (`git.policy.mode: default | local-only | permissive`) - if combinations get complex. Migration is mechanical: `allow_local_operations: true` -> `policy.mode: local-only`. The old boolean can be kept as a deprecated alias for a release.
3. **Re-include user policy in override mode** - move the policy-file block above the override gate, or add a sub-flag.

The existing `policy.allow`/`block` lists already cover granular custom modes. The new flag is a coarse switch, not a replacement for that machinery. No realistic future extension is blocked by this design.

## Open questions

None. All decisions confirmed during brainstorming:
- Approach A (env-var gate at top of wrapper) selected.
- "Override everything" semantics (user `policy.block` also ignored when flag is on).
- Naming: `git.allow_local_operations` / `--allow-local-git` / `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS`.
- `git config` allowed in override mode (consistent with "all local operations allowed").
- System git config in entrypoint unchanged (defense-in-depth remote push protection).
- Warning emitted on conflicting config (override + non-empty policy lists).
