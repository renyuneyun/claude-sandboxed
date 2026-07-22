# YAML Configuration Foundation

**Date:** 2026-07-22
**Status:** Approved, pending implementation
**Scope:** Foundation only - config loading mechanism + four identity knobs

## Goal

Add a YAML config file layer to `bin/claude-sandboxed` so users can set the four identity knobs (`sandbox_uid`, `sandbox_gid`, `sandbox_username`, `sandbox_home`) persistently, with env vars still taking precedence. This proves the config-loading pattern for future, richer configuration (git policy, isolation knobs, network mode).

## Non-goals

- Git operation policy configurability (future scope).
- Git `--system` config rules (future scope).
- Isolation knobs such as `network_mode`, volume passthroughs (future scope).
- Config validation beyond what downstream tools (e.g. `useradd`) enforce naturally.
- Container-side changes of any kind. `yq` is a host-only dependency.

## Config file locations

| File | Purpose |
|---|---|
| `${XDG_CONFIG_HOME:-$HOME/.config}/claude-sandboxed/config.yaml` | User defaults |
| `$WORKSPACE_DIR/.claude-sandboxed.yaml` | Per-project override (workspace root = positional arg or `$PWD`) |

Both files are optional. Neither needs to exist. `WORKSPACE_DIR` is resolved (absolute, `cd`-normalized) by the launcher before config discovery, so the workspace config path is always absolute.

## Schema

```yaml
sandbox:
  uid: 1000          # integer
  gid: 1000          # integer
  username: ryey     # string
  home: /home/ryey   # string, absolute path
```

All fields optional. Unknown top-level fields and unknown `sandbox:` fields are ignored (forward-compat for future sections and future knobs). Future sections (`git:`, `network:`) will sit alongside `sandbox:` without affecting current resolution.

## Precedence

Per knob, first match wins:

1. **Env var** (`SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USERNAME`, `SANDBOX_HOME`) - if set and non-empty.
2. **Workspace config** (`$WORKSPACE_DIR/.claude-sandboxed.yaml`) - if the key is present and non-null.
3. **User config** (`~/.config/claude-sandboxed/config.yaml`) - if the key is present and non-null.
4. **Default** - existing defaults: `$(id -u)`, `$(id -g)`, `$(id -un)`, `/home/$SANDBOX_USERNAME`.

This matches conventional config-resolution behavior: env vars for one-off overrides (CI, quick tweaks), config files for persistent preferences.

## Resolution mechanism

Two helpers in `bin/claude-sandboxed`:

```bash
# Validate one config file: must exist, yq must be on PATH, YAML must parse.
# Returns 0 (valid) or 1 (skip this file). Emits warnings to stderr on failure.
check_config() {  # FILE
  local f="$1"
  [[ -f "$f" ]] || return 1
  if ! command -v yq >/dev/null 2>&1; then
    echo "claude-sandboxed: yq not found; ignoring $f" >&2
    return 1
  fi
  if ! yq '.' "$f" >/dev/null 2>&1; then
    echo "claude-sandboxed: malformed YAML in $f; ignoring" >&2
    return 1
  fi
  return 0
}

# Resolve one knob. Env var > validated workspace config > validated user config > default.
# Consults the *_VALID flags set by the up-front check_config calls (see Integration).
resolve() {  # ENV_NAME YQ_PATH DEFAULT
  local env_name="$1" yq_path="$2" default="$3"
  if [[ -n "${!env_name:-}" ]]; then echo "${!env_name}"; return; fi
  if [[ "$WORKSPACE_CONFIG_VALID" == "true" ]]; then
    local v; v=$(yq -r "$yq_path" "$WORKSPACE_CONFIG" 2>/dev/null) || v=""
    [[ "$v" != "null" && -n "$v" ]] && { echo "$v"; return; }
  fi
  if [[ "$USER_CONFIG_VALID" == "true" ]]; then
    local v; v=$(yq -r "$yq_path" "$USER_CONFIG" 2>/dev/null) || v=""
    [[ "$v" != "null" && -n "$v" ]] && { echo "$v"; return; }
  fi
  echo "$default"
}
```

The launcher calls `check_config` once per file up front (see Integration), setting `WORKSPACE_CONFIG_VALID` / `USER_CONFIG_VALID`. `resolve` consults those flags, so each file's warning is emitted at most once per launcher invocation - not four times (once per knob).

`yq` is invoked at most 8 times for key lookups (2 files × 4 keys) plus at most 2 validation calls. For a one-shot CLI launcher the overhead is invisible.

`yq -r` outputs `null` for missing keys; the `[[ "$v" != "null" && -n "$v" ]]` check filters those out so a missing key in a present file falls through to the next source.

## Error handling

| Scenario | Behavior |
|---|---|
| `yq` not on `PATH`, no config files present | Silent. No behavior change for existing users. |
| `yq` not on `PATH`, config file present | Warn to stderr: `claude-sandboxed: yq not found; ignoring <file>`. Skip config, fall back to env/defaults. |
| Malformed YAML (yq exits non-zero) | Warn to stderr naming the file. Skip that file, continue with the other. |
| Wrong-type value (e.g. `uid: "abc"`) | Not validated. Downstream `useradd -u abc` fails with its own error. Acceptable for foundation scope. |
| Empty string value in YAML | Treated as missing (`-n "$v"` check). Falls through to next source. |

Warnings go to stderr and do not exit the launcher. The user sees the warning but the command still runs with whatever values resolved from other sources.

## Integration into `bin/claude-sandboxed`

Insert config discovery + up-front validation + resolution **before** the existing `export SANDBOX_UID=...` block, replacing the hardcoded defaults:

```bash
USER_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/claude-sandboxed/config.yaml"
WORKSPACE_CONFIG="$WORKSPACE_DIR/.claude-sandboxed.yaml"

# Validate each file once; resolve() consults these flags instead of re-calling check_config.
WORKSPACE_CONFIG_VALID=false; check_config "$WORKSPACE_CONFIG" && WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=false;       check_config "$USER_CONFIG"     && USER_CONFIG_VALID=true

export SANDBOX_UID="$(resolve SANDBOX_UID .sandbox.uid "$(id -u)")"
export SANDBOX_GID="$(resolve SANDBOX_GID .sandbox.gid "$(id -g)")"
export SANDBOX_USERNAME="$(resolve SANDBOX_USERNAME .sandbox.username "$(id -un)")"
export SANDBOX_HOME="$(resolve SANDBOX_HOME .sandbox.home "/home/$SANDBOX_USERNAME")"
```

`resolve` consults the `*_VALID` flags instead of calling `check_config` itself, so each file's warning (if any) is emitted exactly once. `SANDBOX_HOME` resolves last so its default can reference the already-resolved `SANDBOX_USERNAME`.

No changes to `docker-compose.yml`, the entrypoint, `git-wrapper`, or any container-side code. All values still reach the container through the existing env-var channel (the compose file already interpolates `SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USERNAME`, `SANDBOX_HOME`).

The launcher's existing main logic (workspace resolution, `docker compose run`, cleanup) is wrapped in a `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then ... fi` guard so the script can be sourced by tests to access `resolve` / `check_config` without triggering docker. This is the only structural change to the launcher beyond adding the two functions and the config discovery block.

## Testing

New `tests/config/test.sh`. Runs on host, no Docker needed. Cases:

1. Env var wins over workspace and user config (both files set the same key).
2. Workspace wins over user config (only both files set the key, no env var).
3. User config fills in when env and workspace are absent.
4. Default is used when nothing is set.
5. Malformed YAML in one file doesn't break the other (the good file's values still resolve).
6. Missing `yq` (stubbed as a missing binary on `PATH`) falls back to env/defaults without crashing; warning is printed if a config file is present.
7. Missing key in a present file falls through to the next source (yq returns `null`).

Tests use a temp dir with crafted YAML files and source the `resolve` / `check_config` functions directly from `bin/claude-sandboxed`. To enable sourcing without triggering docker compose, the launcher wraps its main execution in a `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then ... fi` guard so functions are defined on source but main logic only runs when executed. Tests print `PASS:` / `FAIL:` lines and exit non-zero on any failure, matching the convention of the existing `tests/git-wrapper/test.sh`.

The runner `tests/run-all.sh` picks up `tests/config/test.sh` automatically - no changes to the runner needed.

## Documentation updates

### `README.md`
- **Requirements:** add `yq` with a note: only needed if using config files. Either implementation works - mikefarah's Go `yq` (`go-yq` on Arch, `brew install yq` on macOS) or kislyuk's Python `yq` (`yq` on Arch, `pip install yq`). The spec uses only `yq '.' file` (validation) and `yq -r '.path' file` (key lookup), which are common-denominator operations supported by both.
- **Customization:** new "Configuration" subsection showing the YAML schema and both file locations, with a short example.
- **Features roadmap:** mark "Customization" as in-progress - foundation done, git policy and git config still pending.

### `docs/development.md`
- Short new section "Config resolution" describing the precedence order, file locations, and the `yq` host-only dependency.
- Add an invariant: `WORKSPACE_DIR` must be resolved to an absolute path before `WORKSPACE_CONFIG` is derived from it.

## Files touched

| File | Change |
|---|---|
| `bin/claude-sandboxed` | Add `check_config` + `resolve` helpers, config discovery, up-front validation, replace hardcoded defaults with `resolve` calls, wrap main logic in a source-guard for testability |
| `tests/config/test.sh` | New test suite |
| `README.md` | Requirements + Configuration subsection + roadmap update |
| `docs/development.md` | Config resolution section + new invariant |

## Files NOT touched

- `share/claude-sandboxed/docker-compose.yml`
- `share/claude-sandboxed/git-wrapper`
- `install.sh`
- `packaging/PKGBUILD`

No container-side changes. No new runtime deps inside the container.

## Open questions

None. All decisions settled during brainstorming:
- Scope: foundation only.
- Format: YAML, parsed by `yq` on host.
- Location: user config + workspace override.
- Precedence: env > workspace > user > default.
- Knobs: all four identity knobs.
- Approach: per-key `yq` lookups (Approach A).
