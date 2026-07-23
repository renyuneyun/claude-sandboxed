# Git Identity and Host-Config Passthrough Config

**Date:** 2026-07-23
**Status:** Approved, pending implementation
**Scope:** Two new config knobs under `git:` - per-sandbox identity override and host git-config passthrough toggle.

## Goal

Let users (1) override `user.name` / `user.email` inside the sandbox so commits are visually distinct from host commits, and (2) stop mounting host `~/.gitconfig` and `~/.config/git/` into the container so host git settings stay out of the sandbox. Both knobs independent, both following the existing env > workspace > user > default precedence.

## Non-goals

- Git operation policy configurability (which subcommands/flags the wrapper blocks) - future scope.
- Arbitrary `git config --system` key/value pairs (e.g. `init.defaultBranch`, `safe.directory`) - future scope.
- Disabling the built-in push/URL-rewrite entrypoint - out of scope, security-sensitive.
- `git.identity.signingkey`, `git.identity.gpgsign`, `gpg.format`, etc. - deferred (see "Deferred" below).
- Container entrypoint changes. Identity is applied via env vars at `docker compose run` level, not by the entrypoint.
- Unit tests for the launcher's array-building logic (`GIT_VOLUME_ARGS`, `GIT_ENV_ARGS`). That logic lives inside the main guard and is straight-line bash; covered by the manual test checklist instead.

## Schema

New `git:` top-level section, sits alongside the existing `sandbox:` section:

```yaml
git:
  identity:
    name: claude-bot        # string, default: "" (not set)
    email: bot@example.com  # string, default: "" (not set)
  host_config_passthrough: true  # bool, default: true
```

All fields optional. Unknown fields under `git:` and `git.identity:` are ignored (forward-compat).

**Env var overrides** (follow the existing `SANDBOX_*` namespace):

| Env var | Knob |
|---|---|
| `SANDBOX_GIT_IDENTITY_NAME` | `git.identity.name` |
| `SANDBOX_GIT_IDENTITY_EMAIL` | `git.identity.email` |
| `SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH` | `git.host_config_passthrough` |

Precedence per knob: env var > workspace config > user config > default. Same as the four identity knobs.

## Mechanism

### Identity: env vars

When `SANDBOX_GIT_IDENTITY_NAME` is non-empty, the launcher passes `-e GIT_AUTHOR_NAME=...` and `-e GIT_COMMITTER_NAME=...` to `docker compose run`. Same for email with `GIT_AUTHOR_EMAIL` / `GIT_COMMITTER_EMAIL`.

Git's env-var precedence is above any config file (system < global < local < env), so the override takes effect regardless of whether host `~/.gitconfig` is mounted. This is why the two knobs are fully independent.

**Why `-e` flags instead of `environment:` entries in `docker-compose.yml`:** Listing `GIT_AUTHOR_NAME` in `environment:` with no value means "pass through from host env". That would leak the host's `GIT_AUTHOR_NAME` into the sandbox when config doesn't set it - the opposite of what we want. Using `-e` on `docker compose run` means the var only appears when the launcher explicitly sets it.

**Caveat:** `git config user.name` (the command) only reads config files - it ignores `GIT_AUTHOR_NAME` / `GIT_COMMITTER_NAME` env vars. So when `host_config_passthrough: true` and identity is overridden, `git config user.name` still prints the host's value from `~/.gitconfig`. Commits are still authored correctly (env vars win for commit authorship), but introspection via `git config` is misleading. `git var GIT_AUTHOR_IDENT` is the one git command that does respect the env vars. Claude commits via `git commit`, which uses env vars, so this is a narrow cosmetic issue. Documented in the README.

### Host-config passthrough: conditional mount

The existing `GIT_VOLUME_ARGS` block in `bin/claude-sandboxed` is wrapped in a passthrough guard:

```bash
GIT_VOLUME_ARGS=()
if [[ "$SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH" == "true" ]]; then
    if [[ -f "$HOME/.gitconfig" ]]; then
        GIT_VOLUME_ARGS+=(-v "$HOME/.gitconfig:${SANDBOX_HOME}/.gitconfig:ro")
    fi
    if [[ -d "$HOME/.config/git" ]]; then
        GIT_VOLUME_ARGS+=(-v "$HOME/.config/git:${SANDBOX_HOME}/.config/git:ro")
    fi
fi
```

Default `true` preserves current behavior. When `false`, neither host file is mounted; git inside the container falls back to its compiled defaults (or the sandbox identity env vars, if set).

**Combinations:**

| `identity` | `host_config_passthrough` | Behavior |
|---|---|---|
| unset | `true` (default) | Current behavior: host git identity inherited via `~/.gitconfig`. |
| unset | `false` | No git identity in sandbox. `git commit` fails with "Please tell me who you are". Documented, not enforced. |
| set | `true` (default) | Host config mounted, but commit authorship overridden by env vars. |
| set | `false` | Clean slate: only sandbox identity applies. |

## Launcher changes (`bin/claude-sandboxed`)

**Resolution** (after the existing identity resolution, ~line 73):

```bash
SANDBOX_GIT_IDENTITY_NAME="$(resolve SANDBOX_GIT_IDENTITY_NAME .git.identity.name "")"
SANDBOX_GIT_IDENTITY_EMAIL="$(resolve SANDBOX_GIT_IDENTITY_EMAIL .git.identity.email "")"
SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH="$(resolve SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH .git.host_config_passthrough true)"
```

No `export` on these three. They are shell-local variables consumed only by the launcher to build CLI flags; the compose file never interpolates them and no child process needs them. (`resolve()` uses bash indirect expansion `${!env_name}` which reads shell variables regardless of export status, so env-var overrides still work.)

This differs from the four existing identity knobs (`SANDBOX_UID` etc.), which are exported because `docker-compose.yml` interpolates them. The existing invariant in `docs/development.md` ("must be exported before `docker compose up` - the compose file interpolates them") applies only to compose-interpolated vars. The new `SANDBOX_GIT_*` vars do **not** belong on that invariant list - adding them would be misleading. Note this distinction in `docs/development.md` when updating.

**Conditional git-config mount** (replaces the existing `GIT_VOLUME_ARGS` block, ~lines 91-97): shown above.

**Identity env-var injection** (new block, just before the `docker compose run` call):

```bash
GIT_ENV_ARGS=()
if [[ -n "$SANDBOX_GIT_IDENTITY_NAME" ]]; then
    GIT_ENV_ARGS+=(-e GIT_AUTHOR_NAME="$SANDBOX_GIT_IDENTITY_NAME")
    GIT_ENV_ARGS+=(-e GIT_COMMITTER_NAME="$SANDBOX_GIT_IDENTITY_NAME")
fi
if [[ -n "$SANDBOX_GIT_IDENTITY_EMAIL" ]]; then
    GIT_ENV_ARGS+=(-e GIT_AUTHOR_EMAIL="$SANDBOX_GIT_IDENTITY_EMAIL")
    GIT_ENV_ARGS+=(-e GIT_COMMITTER_EMAIL="$SANDBOX_GIT_IDENTITY_EMAIL")
fi
```

`"${GIT_ENV_ARGS[@]}"` is spliced into the existing `docker compose run` command between `-e HOME=...` and `"${GIT_VOLUME_ARGS[@]}"`.

**No changes** to `check_config`, `resolve`, the entrypoint in `docker-compose.yml`, or `git-wrapper`.

## Tests

`tests/config/test.sh` - extend with `resolve` cases for the three new paths. No new helpers needed; `resolve` is path-agnostic.

New cases:

- `resolve SANDBOX_GIT_IDENTITY_NAME .git.identity.name ""` with env set -> env value
- `resolve SANDBOX_GIT_IDENTITY_NAME .git.identity.name ""` with workspace config set, no env -> workspace value
- `resolve SANDBOX_GIT_IDENTITY_NAME .git.identity.name ""` with nothing set -> `""` (empty default)
- `resolve SANDBOX_GIT_IDENTITY_EMAIL .git.identity.email ""` with user config set, no env, no workspace -> user value
- `resolve SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH .git.host_config_passthrough true` with nothing set -> `"true"`
- `resolve SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH .git.host_config_passthrough true` with env `false` -> `"false"`
- `resolve SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH .git.host_config_passthrough true` with workspace config `false`, no env -> `"false"`

The conditional `GIT_VOLUME_ARGS` / `GIT_ENV_ARGS` logic is inside the main guard (not sourceable). Extending the unit test suite to cover it would require extracting those into functions. Decision: skip - it's 10 lines of straight-line bash, and the manual test checklist covers it end-to-end. Adding a function just for testability would fragment the launcher's main flow.

## Documentation updates

**`share/claude-sandboxed/config.example.yaml`** - add the new section, all commented out:

```yaml
git:
  # Identity overrides applied via GIT_AUTHOR_NAME / GIT_COMMITTER_NAME /
  # GIT_AUTHOR_EMAIL / GIT_COMMITTER_EMAIL env vars inside the container.
  # When unset, git uses whatever user.name / user.email it finds in the
  # container (from host_config_passthrough or git's defaults).
  identity:
    # name: claude-bot
    # email: bot@example.com
  # When false, host ~/.gitconfig and ~/.config/git/ are not mounted into
  # the container. Default: true (preserves host git identity inheritance).
  # host_config_passthrough: true
```

**`README.md`:**

- Schema section: add the `git:` block alongside `sandbox:`.
- New "Git identity" subsection under "Customization" explaining the two knobs, the env-var mechanism, the "passthrough off + no identity = commits fail" caveat, and the `git config user.name` cosmetic caveat.
- Update the "Git config inheritance" feature bullet under "Features" to mention it's now configurable.
- Check the `Git config` sub-item under the "Customization" TODO in Features.

**`docs/development.md`:**

- Add `git.identity.name` / `email` / `host_config_passthrough` to the "Config resolution" section's knob list.
- Note that the new `SANDBOX_GIT_*` vars are launcher-side (not compose-interpolated) and do **not** belong on the "must be exported before `docker compose up`" invariant.
- Add manual test checklist items 10-13:

10. **Git identity override:** with `git.identity.name`/`email` set in workspace config, `git commit` inside the container uses the overridden identity (verify with `git log --format='%an <%ae>'`).
11. **Host passthrough off:** with `git.host_config_passthrough: false`, `git config user.name` inside the container returns nothing (or git's compiled default), not host's value. `cat ~/.gitconfig` fails (file doesn't exist).
12. **Identity + passthrough off:** both set together - commits use the sandbox identity.
13. **Identity + passthrough on (default):** identity env vars override host's `~/.gitconfig` values for commit authorship.

**`CLAUDE.md`** - no changes (file listing and rules stay accurate).

## Deferred

Explicitly out of scope for this spec, but natural follow-ups:

- `git.identity.signingkey` - per-sandbox GPG signing key.
- `git.identity.gpgsign` / `commit.gpgsign` - toggle signing per sandbox.
- `gpg.format` / `gpg.ssh.program` - support SSH signing.
- `git.config` - arbitrary `git config --system` key/value pairs (e.g. `init.defaultBranch`, `safe.directory`, `core.editor`).
- Disabling the built-in push/URL-rewrite entrypoint (security-sensitive; needs separate design).
- Git operation policy configurability (which subcommands/flags the wrapper blocks).

These are listed here so future maintainers know what was considered and deferred, not forgotten.
