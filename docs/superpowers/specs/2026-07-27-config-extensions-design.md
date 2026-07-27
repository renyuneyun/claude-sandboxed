# Config Extensions: claude.version, config_passthrough, cleanup, git.policy

**Date:** 2026-07-27
**Status:** Approved, pending implementation
**Scope:** Add config knobs for three already-implemented features (Claude version pinning, Claude config passthrough, automatic cleanup) and a regex-based customizable git operation policy.

## Goal

Extend the YAML config system to cover the remaining already-implemented features that lack config knobs, and make the git operation policy user-customizable via regex allow/block lists. All new knobs follow the existing env > workspace > user > default precedence.

## Non-goals

- Network mode configurability (network isolation is a separate TODO feature).
- Additional mountpoints (not implemented).
- Alternative Claude config path (not implemented).
- `git.identity.signingkey` / `gpgsign` (deferred).
- Arbitrary `git.config --system` key/value pairs (deferred).
- Disabling the built-in push/URL-rewrite entrypoint (deferred, security-sensitive).
- `git.policy.allow_push` / `allow_config` - push requires entrypoint changes (deferred); config opens alias-bypass hole (spec was explicit about blocking config entirely).

## Schema

New `claude:` top-level section. New fields under existing `sandbox:` and `git:` sections.

```yaml
claude:
  version: "2.1.152"            # string,  default: host's claude version
  config_passthrough: true      # bool,    default: true

sandbox:
  # ...existing uid/gid/username/home...
  cleanup: true                 # bool,    default: true

git:
  # ...existing identity + host_config_passthrough...
  policy:
    allow:                      # list of regex (ERE), default: empty
      - "^reset"
      - "^commit --amend"
    block:                      # list of regex (ERE), default: empty
      - "^stash pop"
```

All fields optional. Unknown fields ignored (forward-compat).

**Env var overrides:**

| Env var | Knob |
|---|---|
| `CLAUDE_VERSION` | `claude.version` |
| `CLAUDE_CONFIG_PASSTHROUGH` | `claude.config_passthrough` |
| `SANDBOX_CLEANUP` | `sandbox.cleanup` |
| `SANDBOX_GIT_POLICY_ALLOW` | `git.policy.allow` (newline-separated) |
| `SANDBOX_GIT_POLICY_BLOCK` | `git.policy.block` (newline-separated) |

Same precedence as existing knobs: env > workspace config > user config > default.

## Mechanism

### claude.version

Replace the existing line:
```bash
CLAUDE_VERSION="${CLAUDE_VERSION:-$(claude --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)}"
```
with:
```bash
CLAUDE_VERSION="$(resolve CLAUDE_VERSION .claude.version "$(claude --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)")"
```

Launcher-side only - not exported, not interpolated by compose. Used to build `CLAUDE_PACKAGE` (existing behavior). `resolve` already handles the env-var-first precedence, so `CLAUDE_VERSION=latest claude-sandboxed` still works.

### claude.config_passthrough

**Move the `~/.claude` and `~/.claude.json` mounts out of `docker-compose.yml` into the launcher** (Option A, approved). This mirrors how `GIT_VOLUME_ARGS` already works for git config.

New resolution + conditional mount block in `bin/claude-sandboxed`:
```bash
CLAUDE_CONFIG_PASSTHROUGH="$(resolve CLAUDE_CONFIG_PASSTHROUGH .claude.config_passthrough true)"

CLAUDE_VOLUME_ARGS=()
if [[ "$CLAUDE_CONFIG_PASSTHROUGH" == "true" ]]; then
    if [[ -d "$HOME/.claude" ]]; then
        CLAUDE_VOLUME_ARGS+=(-v "$HOME/.claude:${SANDBOX_HOME}/.claude")
    fi
    if [[ -f "$HOME/.claude.json" ]]; then
        CLAUDE_VOLUME_ARGS+=(-v "$HOME/.claude.json:${SANDBOX_HOME}/.claude.json")
    fi
fi
```

**Remove** these two lines from `share/claude-sandboxed/docker-compose.yml`:
```yaml
- ${HOME}/.claude:${SANDBOX_HOME}/.claude
- ${HOME}/.claude.json:${SANDBOX_HOME}/.claude.json
```

Splice `"${CLAUDE_VOLUME_ARGS[@]}"` into the `docker compose run` call alongside the existing `GIT_VOLUME_ARGS`.

The `~/.claude` mount is **read/write** (Claude Code writes settings, session state, etc. there) - same as the current compose mount. `~/.claude.json` is also read/write.

Note: `HOME` is currently exported by the launcher (used by the compose file for interpolation). After this change, the compose file no longer interpolates `HOME` for these mounts. The launcher uses `$HOME` directly in the `-v` args. `HOME` remains exported for now (the compose file may still reference it elsewhere, and removing the export is a separate invariant change - not part of this spec).

### sandbox.cleanup

New resolution + conditional:
```bash
SANDBOX_CLEANUP="$(resolve SANDBOX_CLEANUP .sandbox.cleanup true)"

# ... after the main docker compose run ...
if [[ "$SANDBOX_CLEANUP" == "true" && "$WORKSPACE_DIR" == "$SANDBOX_HOME"/* ]]; then
    docker compose -p "$COMPOSE_PROJECT" -f "$SANDBOX_COMPOSE_DIR/docker-compose.yml" run \
      --rm \
      cleanup
fi
```

The existing `WORKSPACE_DIR == SANDBOX_HOME/*` guard stays - the cleanup only matters when stub dirs could have been created inside the volume. The new `SANDBOX_CLEANUP` flag adds an opt-out.

Launcher-side only - not exported, not interpolated by compose.

### git.policy (file-based)

**Resolution:** new `resolve_list` helper returns newline-joined patterns from a YAML array.

```bash
# Resolve a list knob. Env var (newline-separated) > workspace config > user config.
# Returns newline-separated patterns, or empty string if nothing set.
resolve_list() {  # ENV_NAME YQ_PATH
  local env_name="$1" yq_path="$2"
  if [[ -n "${!env_name:-}" ]]; then echo "${!env_name}"; return; fi
  if [[ "$WORKSPACE_CONFIG_VALID" == "true" ]]; then
    local v; v=$(yq -r "$yq_path[]" "$WORKSPACE_CONFIG" 2>/dev/null) || v=""
    [[ -n "$v" ]] && { echo "$v"; return; }
  fi
  if [[ "$USER_CONFIG_VALID" == "true" ]]; then
    local v; v=$(yq -r "$yq_path[]" "$USER_CONFIG" 2>/dev/null) || v=""
    [[ -n "$v" ]] && { echo "$v"; return; }
  fi
  echo ""
}
```

`yq -r '.git.policy.allow[]'` prints each array element on its own line. If the key is missing, yq errors (suppressed by `2>/dev/null`) and `v` stays empty - the function falls through. This matches how the existing `resolve` handles missing scalar keys.

**Launcher generates a policy file** when either list is non-empty:
```bash
SANDBOX_GIT_POLICY_ALLOW="$(resolve_list SANDBOX_GIT_POLICY_ALLOW .git.policy.allow)"
SANDBOX_GIT_POLICY_BLOCK="$(resolve_list SANDBOX_GIT_POLICY_BLOCK .git.policy.block)"

GIT_POLICY_VOLUME_ARGS=()
POLICY_FILE=""
if [[ -n "$SANDBOX_GIT_POLICY_ALLOW" || -n "$SANDBOX_GIT_POLICY_BLOCK" ]]; then
    POLICY_FILE="$(mktemp)"
    {
        echo "[allow]"
        printf '%s\n' "$SANDBOX_GIT_POLICY_ALLOW"
        echo "[block]"
        printf '%s\n' "$SANDBOX_GIT_POLICY_BLOCK"
    } > "$POLICY_FILE"
    GIT_POLICY_VOLUME_ARGS+=(-v "$POLICY_FILE:/etc/claude-sandboxed/git-policy.conf:ro")
    trap 'rm -f "$POLICY_FILE"' EXIT
fi
```

File format - one pattern per line, sections delimited by `[allow]` / `[block]` headers:
```
[allow]
^reset
^commit --amend
[block]
^stash pop
```

Empty lines within a section (from the `printf` when the list is empty) are skipped by the parser. The file is mounted read-only.

Splice `"${GIT_POLICY_VOLUME_ARGS[@]}"` into the `docker compose run` call.

**Wrapper reads the policy file** before applying the built-in default policy:

```bash
POLICY_FILE="${GIT_POLICY_FILE:-/etc/claude-sandboxed/git-policy.conf}"

# Build command string for regex matching: subcommand + args, space-joined.
cmd_args="$subcommand"
for ((j=subcommand_idx+1; j<=$#; j++)); do
    cmd_args="$cmd_args ${!j}"
done

# Apply user policy (patches the default).
if [[ -f "$POLICY_FILE" ]]; then
    section=""
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        case "$line" in
            "[allow]") section="allow"; continue ;;
            "[block]") section="block"; continue ;;
        esac
        if [[ "$section" == "allow" ]]; then
            if [[ "$cmd_args" =~ $line ]]; then
                exec "$REAL_GIT" "$@"
            fi
        elif [[ "$section" == "block" ]]; then
            if [[ "$cmd_args" =~ $line ]]; then
                block "matches user block rule: $line"
            fi
        fi
    done < "$POLICY_FILE"
fi

# ... existing default policy case statement (unchanged) ...
```

**Precedence** (first match wins):
1. User `allow` rules - if any matches, `exec` real git immediately (skip default policy).
2. User `block` rules - if any matches, block.
3. Built-in default policy (existing case statement).
4. Allow (exec real git).

This is a **patch model**, not a full replacement. Users override specific default blocks via `allow`, and add new blocks via `block`. To effectively replace the default policy, a user can add `allow: [".*"]` to allow everything, then add specific `block` rules.

**Invalid regex:** bash `=~` with a malformed pattern errors at runtime. The wrapper will print the bash error and the command will not run. This is acceptable - users test their patterns and fix them. No upfront validation in the launcher (keeps it simple; the wrapper is the single point of enforcement).

**Debuggability:** users can `cat /etc/claude-sandboxed/git-policy.conf` inside the container to verify the effective policy. This is the main advantage over env vars.

### Integration into the launcher

The new resolution calls sit alongside the existing ones. The new arrays (`CLAUDE_VOLUME_ARGS`, `GIT_POLICY_VOLUME_ARGS`) are spliced into the existing `docker compose run` call.

The `docker compose run` call becomes:
```bash
docker compose -p "$COMPOSE_PROJECT" -f "$SANDBOX_COMPOSE_DIR/docker-compose.yml" run \
  --rm \
  -e HOME="${SANDBOX_HOME}" \
  "${GIT_ENV_ARGS[@]}" \
  "${GIT_VOLUME_ARGS[@]}" \
  "${CLAUDE_VOLUME_ARGS[@]}" \
  "${GIT_POLICY_VOLUME_ARGS[@]}" \
  -it ai-agent npx --yes "$CLAUDE_PACKAGE" --dangerously-skip-permissions
```

`CLAUDE_VOLUME_ARGS` and `GIT_POLICY_VOLUME_ARGS` are empty arrays by default (no-op when spliced).

## Default policy documentation

The built-in default git policy (currently in the wrapper's case statement) gets documented in two places for user reference:

1. **`share/claude-sandboxed/config.example.yaml`** - a commented block in the `git.policy` section listing every blocked subcommand and flag, so users can copy and modify it.
2. **`README.md`** Git policy section - already partially documents this; will be made exhaustive and cross-referenced.

The wrapper itself remains the source of truth (code = docs risk). The docs will note "see `git-wrapper` for the authoritative list" to flag drift risk.

## Tests

### `tests/config/test.sh`

Extend with `resolve` cases for the new scalar paths:
- `resolve CLAUDE_VERSION .claude.version "default"` - env var, workspace, user, default
- `resolve CLAUDE_CONFIG_PASSTHROUGH .claude.config_passthrough true` - same four cases
- `resolve SANDBOX_CLEANUP .sandbox.cleanup true` - same four cases

Add `resolve_list` cases:
- Env var (newline-separated) wins over workspace and user
- Workspace list wins over user list
- User list fills gap when workspace absent
- Empty default when nothing set
- Missing key in valid file falls through (returns empty)
- Empty array in YAML returns empty

### `tests/git-wrapper/test.sh`

Add cases for the policy file:
- Policy file with `[allow]` section containing `^reset` -> `git reset --hard` is allowed (real git called)
- Policy file with `[allow]` containing `^commit --amend` -> `git commit --amend` is allowed
- Policy file with `[block]` containing `^stash pop` -> `git stash pop` is blocked with "[SECURITY]" message
- Policy file with `[allow]` containing `^reset` -> `git push` is still blocked (default policy still applies to non-matching commands)
- No policy file -> existing behavior (all default blocks still apply)
- Policy file with comments (`#`) and empty lines -> parsed correctly

The wrapper test already uses `REAL_GIT` env var for stubbing. For the policy file tests, set `GIT_POLICY_FILE` to point at a temp file with the test policy.

## Documentation updates

### `share/claude-sandboxed/config.example.yaml`

Add `claude:` section, `sandbox.cleanup`, and `git.policy` section. Include the full default policy as a commented reference block under `git.policy`.

### `README.md`

- **Schema section:** add `claude:` block and the new `sandbox.cleanup` / `git.policy` fields.
- **Customization > Configuration:** note the new knobs in the schema table.
- **New subsection: "Claude version"** - explain `claude.version` (pin a version via config, env var still works).
- **New subsection: "Claude config passthrough"** - explain `claude.config_passthrough` (default true; when false, `~/.claude` not mounted; useful with `ANTHROPIC_API_KEY` only).
- **New subsection: "Cleanup"** - explain `sandbox.cleanup` (default true; when false, stub dirs may accumulate in the volume; usually harmless).
- **Update "Git policy" section:** add `git.policy` subsection explaining the regex allow/block lists, the patch model, the file format, and the debuggability (`cat /etc/claude-sandboxed/git-policy.conf` inside the container). Include the full default policy list.

### `docs/development.md`

- **Config resolution section:** add the new knobs to the list. Note that `CLAUDE_VERSION`, `CLAUDE_CONFIG_PASSTHROUGH`, `SANDBOX_CLEANUP`, `SANDBOX_GIT_POLICY_ALLOW`, `SANDBOX_GIT_POLICY_BLOCK` are all launcher-side (not compose-interpolated, not exported).
- **Invariants:**
    - The `~/.claude` and `~/.claude.json` mounts are now in the launcher (`CLAUDE_VOLUME_ARGS`), not in `docker-compose.yml`. The compose file no longer mounts these.
    - The `GIT_POLICY_FILE` path (`/etc/claude-sandboxed/git-policy.conf`) is the contract between the launcher and the wrapper. Changing it requires updating both.
    - `resolve_list` must remain defined outside the main guard (for testability), same as `check_config` and `resolve`.
- **Manual test checklist** - add items:
    14. **Claude version:** with `claude.version: "2.1.152"` in workspace config, the container runs that version (verify with `claude --version` inside).
    15. **Claude config passthrough off:** with `claude.config_passthrough: false`, `~/.claude` is not mounted. `ls ~/.claude` inside the container shows nothing (or the volume's empty dir). Claude starts with `ANTHROPIC_API_KEY` set.
    16. **Cleanup off:** with `sandbox.cleanup: false`, no `cleanup` container runs after exit. Stub dirs may remain in the volume (harmless).
    17. **Git policy allow:** with `git.policy.allow: ["^reset"]`, `git reset --hard HEAD~1` works inside the container.
    18. **Git policy block:** with `git.policy.block: ["^stash pop"]`, `git stash pop` is blocked with a "[SECURITY]" message.
    19. **Git policy file:** `cat /etc/claude-sandboxed/git-policy.conf` inside the container shows the effective policy.
    20. **Git policy doesn't affect unmatched commands:** with `git.policy.allow: ["^reset"]`, `git push` is still blocked.

### `CLAUDE.md`

No changes (file listing and rules stay accurate).

## Files touched

| File | Change |
|---|---|
| `bin/claude-sandboxed` | Add `resolve_list`; resolve 5 new knobs; build `CLAUDE_VOLUME_ARGS` + `GIT_POLICY_VOLUME_ARGS`; wrap cleanup in conditional; splice new arrays into `docker compose run` |
| `share/claude-sandboxed/docker-compose.yml` | Remove `~/.claude` and `~/.claude.json` volume mounts (moved to launcher) |
| `share/claude-sandboxed/git-wrapper` | Add policy file parsing + matching before the default case statement |
| `share/claude-sandboxed/config.example.yaml` | Add `claude:` section, `sandbox.cleanup`, `git.policy` section with default policy reference |
| `tests/config/test.sh` | Add `resolve` cases for new scalar paths; add `resolve_list` cases |
| `tests/git-wrapper/test.sh` | Add policy file test cases |
| `README.md` | Schema updates; new subsections; exhaustive default policy list |
| `docs/development.md` | Config resolution updates; new invariants; manual test checklist items 14-20 |

## Files NOT touched

- `install.sh` - no new files to install (config.example.yaml already installed).
- `packaging/PKGBUILD` - same.

## Commit plan

Sensible units for git history:

1. **`claude.version` + `sandbox.cleanup`** - simple resolve calls, no compose/wrapper changes. Includes resolve tests.
2. **`claude.config_passthrough`** - moves mounts from compose to launcher. Includes compose file change.
3. **`git.policy`** - `resolve_list` helper, policy file generation, wrapper changes, wrapper tests. Largest unit.
4. **Docs + config.example.yaml** - README, development.md, config.example.yaml updates. Can be bundled with each commit or as a final docs commit.

## Deferred

Explicitly out of scope, but natural follow-ups:

- `git.policy.allow_push` - requires disabling the entrypoint's system-config push blocking (security-sensitive; separate design needed).
- `git.policy.allow_config` - opens alias-bypass hole; the spec was explicit about blocking config entirely. Could be revisited if a read-only `git config --get` use case emerges.
- Network mode configurability.
- Additional mountpoints config.
- Alternative Claude config path config.
- `git.identity.signingkey` / `gpgsign`.
- Arbitrary `git.config --system` key/value pairs.
