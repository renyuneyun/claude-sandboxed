# YAML Config Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a YAML config file layer to `bin/claude-sandboxed` so users can set the four identity knobs (`sandbox_uid`, `sandbox_gid`, `sandbox_username`, `sandbox_home`) persistently, with env vars still taking precedence.

**Architecture:** Two bash functions (`check_config`, `resolve`) defined outside a main-execution guard in `bin/claude-sandboxed`, enabling testability via sourcing. Config files at `~/.config/claude-sandboxed/config.yaml` (user) and `$WORKSPACE_DIR/.claude-sandboxed.yaml` (workspace). Precedence: env var > workspace config > user config > default. `yq` parses YAML on the host; no container-side changes.

**Tech Stack:** Bash, `yq` (either mikefarah Go yq or kislyuk Python yq - both support `yq '.' file` and `yq -r '.path' file`).

**Spec:** `docs/superpowers/specs/2026-07-22-config-foundation-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `bin/claude-sandboxed` | Launcher script. Adds `check_config` + `resolve` functions (outside main guard). Main guard wraps execution logic. Config discovery + resolution replaces hardcoded identity defaults. |
| `tests/config/test.sh` | New. Unit tests for `check_config` and `resolve`. Sources the launcher to access functions. No Docker needed. |
| `README.md` | Adds `yq` to Requirements, new Configuration subsection, roadmap update. |
| `docs/development.md` | Adds Config resolution section + new invariant. |

Files NOT modified: `share/claude-sandboxed/docker-compose.yml`, `share/claude-sandboxed/git-wrapper`, `install.sh`, `packaging/PKGBUILD`.

---

## Task 1: Restructure `bin/claude-sandboxed` with main execution guard

**Goal:** Wrap the launcher's main logic in a source guard so the script can be sourced by tests without triggering `docker compose`. No new functions yet, no behavior change.

**Files:**
- Modify: `bin/claude-sandboxed`

- [ ] **Step 1: Read the current script to confirm line numbers**

Run: `cat -n bin/claude-sandboxed`

Expected: see the current structure with `set -e` on line 2, `VERSION` on line 4, and main logic from line 6 onward.

- [ ] **Step 2: Rewrite `bin/claude-sandboxed` with the main guard**

Replace the entire file with this content. The key changes: (1) `set -e` moves inside the guard, (2) `VERSION` stays outside (accessible when sourced), (3) all main logic wrapped in `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then ... fi`:

```bash
#!/usr/bin/env bash

VERSION="0.1.0"

# --- Main execution (only runs when executed, not sourced) ---

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
set -e

if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    echo "claude-sandboxed $VERSION"
    exit 0
fi

# Target folder defaults to the directory you are currently standing in
export WORKSPACE_DIR="${1:-$(pwd)}"
export WORKSPACE_DIR=$(cd "$WORKSPACE_DIR" && pwd)

# Claude Code version to run inside the container.
# Defaults to the version installed on the host to keep credentials compatible.
# Override with e.g. CLAUDE_VERSION=latest or CLAUDE_VERSION=2.1.152
CLAUDE_VERSION="${CLAUDE_VERSION:-$(claude --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)}"
CLAUDE_PACKAGE="@anthropic-ai/claude-code${CLAUDE_VERSION:+@${CLAUDE_VERSION}}"

# User identity mirrored into the container.
# Override any of these in your environment before invoking the script.
export SANDBOX_UID="${SANDBOX_UID:-$(id -u)}"
export SANDBOX_GID="${SANDBOX_GID:-$(id -g)}"
export SANDBOX_USERNAME="${SANDBOX_USERNAME:-$(id -un)}"
export SANDBOX_HOME="${SANDBOX_HOME:-/home/${SANDBOX_USERNAME}}"

# Per-user project name keeps containers and volumes isolated on multi-user machines.
# Each user gets their own container and their own claude-agent-home volume.
COMPOSE_PROJECT="claude-sandboxed-${SANDBOX_UID}"

# Resolve the data directory relative to this script's install prefix, supporting
# any layout (/usr, /usr/local, /opt/homebrew, etc.) and direct repo usage.
# Override by setting CLAUDE_SANDBOXED_DIR in your environment.
if [[ -n "$CLAUDE_SANDBOXED_DIR" ]]; then
    SANDBOX_COMPOSE_DIR="$CLAUDE_SANDBOXED_DIR"
else
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SANDBOX_COMPOSE_DIR="$(cd "$_script_dir/../share/claude-sandboxed" && pwd)"
fi

# Git config inheritance: bind-mount host ~/.gitconfig and ~/.config/git/
# read-only when they exist, so Claude uses the host user's git identity.
# Conditional mounting avoids Docker creating empty stub dirs on the host.
GIT_VOLUME_ARGS=()
if [[ -f "$HOME/.gitconfig" ]]; then
    GIT_VOLUME_ARGS+=(-v "$HOME/.gitconfig:${SANDBOX_HOME}/.gitconfig:ro")
fi
if [[ -d "$HOME/.config/git" ]]; then
    GIT_VOLUME_ARGS+=(-v "$HOME/.config/git:${SANDBOX_HOME}/.config/git:ro")
fi

# Run Claude in a one-shot container that is removed automatically on exit.
# Each invocation gets its own container; named volumes (claude-agent-home) persist across runs.
docker compose -p "$COMPOSE_PROJECT" -f "$SANDBOX_COMPOSE_DIR/docker-compose.yml" run \
  --rm \
  -e HOME="${SANDBOX_HOME}" \
  "${GIT_VOLUME_ARGS[@]}" \
  -it ai-agent npx --yes "$CLAUDE_PACKAGE" --dangerously-skip-permissions

# Clean up empty stub directories that Docker created inside the claude-agent-home volume
# as mount-point parents for WORKSPACE_DIR. This must run after the main container exits
# (and its bind mounts are released) using a separate container that mounts only the volume.
#
# We walk upward from the parent of WORKSPACE_DIR toward SANDBOX_HOME, removing each
# directory only if it is empty (rmdir fails silently otherwise, so real data is safe).
if [[ "$WORKSPACE_DIR" == "$SANDBOX_HOME"/* ]]; then
  docker compose -p "$COMPOSE_PROJECT" -f "$SANDBOX_COMPOSE_DIR/docker-compose.yml" run \
    --rm \
    cleanup
fi

fi
```

- [ ] **Step 3: Verify `--version` still works**

Run: `./bin/claude-sandboxed --version`

Expected: `claude-sandboxed 0.1.0`

- [ ] **Step 4: Verify the script can be sourced without side effects**

Run: `bash -c 'source bin/claude-sandboxed && echo "sourced OK, VERSION=$VERSION"'`

Expected: `sourced OK, VERSION=0.1.0` (no docker output, no errors)

- [ ] **Step 5: Verify existing tests still pass**

Run: `bash tests/run-all.sh`

Expected: `All 1 test suite(s) passed.` (git-wrapper tests unaffected)

- [ ] **Step 6: Commit**

```bash
git add bin/claude-sandboxed
git commit -m "refactor: wrap launcher main logic in source guard

Move set -e and all main logic inside an if [[ \"\${BASH_SOURCE[0]}\" ==
\"\${0}\" ]] guard so the script can be sourced by tests to access
functions without triggering docker compose. No behavior change when
executed."
```

---

## Task 2: Add `check_config` function (TDD)

**Goal:** Add the `check_config` function that validates a config file (exists, yq on PATH, YAML parses). Test it in isolation.

**Files:**
- Create: `tests/config/test.sh`
- Modify: `bin/claude-sandboxed` (add function outside main guard)

- [ ] **Step 1: Write the failing test for `check_config`**

Create `tests/config/test.sh`:

```bash
#!/bin/bash
# Unit tests for config resolution (check_config + resolve).
# Run: bash tests/config/test.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$SCRIPT_DIR/../../bin/claude-sandboxed"

# Source the launcher to get check_config and resolve functions.
# The main guard ensures sourcing doesn't trigger docker compose.
# shellcheck source=/dev/null
source "$LAUNCHER"

# yq is required for most tests; skip the suite if not installed.
if ! command -v yq >/dev/null 2>&1; then
    echo "SKIP: yq not installed; skipping config tests"
    exit 0
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

pass=0
fail=0

ok() { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# --- check_config tests ---

# Test: missing file -> return 1, no warning
err=$(check_config "$TMPDIR/nonexistent.yaml" 2>&1 >/dev/null) && code=0 || code=$?
if [[ $code -eq 1 && -z "$err" ]]; then
    ok "check_config: missing file returns 1 silently"
else
    bad "check_config: missing file (code=$code, err='$err')"
fi

# Test: valid YAML -> return 0, no warning
printf 'sandbox:\n  uid: 1000\n' > "$TMPDIR/valid.yaml"
err=$(check_config "$TMPDIR/valid.yaml" 2>&1 >/dev/null) && code=0 || code=$?
if [[ $code -eq 0 && -z "$err" ]]; then
    ok "check_config: valid YAML returns 0"
else
    bad "check_config: valid YAML (code=$code, err='$err')"
fi

# Test: malformed YAML -> return 1, warning contains "malformed YAML"
printf 'sandbox:\n  uid: [unterminated\n' > "$TMPDIR/malformed.yaml"
err=$(check_config "$TMPDIR/malformed.yaml" 2>&1 >/dev/null) && code=0 || code=$?
if [[ $code -eq 1 && "$err" == *"malformed YAML"* ]]; then
    ok "check_config: malformed YAML warns and returns 1"
else
    bad "check_config: malformed YAML (code=$code, err='$err')"
fi

# Test: yq not on PATH + file present -> return 1, warning contains "yq not found"
err=$(PATH="/nonexistent" check_config "$TMPDIR/valid.yaml" 2>&1 >/dev/null) && code=0 || code=$?
if [[ $code -eq 1 && "$err" == *"yq not found"* ]]; then
    ok "check_config: yq missing warns and returns 1"
else
    bad "check_config: yq missing (code=$code, err='$err')"
fi

# Test: empty file (valid YAML, no content) -> return 0
printf '' > "$TMPDIR/empty.yaml"
err=$(check_config "$TMPDIR/empty.yaml" 2>&1 >/dev/null) && code=0 || code=$?
if [[ $code -eq 0 && -z "$err" ]]; then
    ok "check_config: empty file returns 0"
else
    bad "check_config: empty file (code=$code, err='$err')"
fi

echo ""
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/config/test.sh`

Expected: FAIL - `check_config: command not found` errors, because the function doesn't exist yet. The test script will source the launcher successfully but fail when calling `check_config`.

- [ ] **Step 3: Add `check_config` function to `bin/claude-sandboxed`**

In `bin/claude-sandboxed`, insert this block **between** the `VERSION="0.1.0"` line and the `# --- Main execution ---` comment:

```bash

# --- Config resolution helpers (defined outside main guard for testability) ---

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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/config/test.sh`

Expected: `All 5 tests passed.` (or similar - all PASS, 0 FAIL)

- [ ] **Step 5: Run all tests to verify no regressions**

Run: `bash tests/run-all.sh`

Expected: both git-wrapper and config suites pass.

- [ ] **Step 6: Commit**

```bash
git add bin/claude-sandboxed tests/config/test.sh
git commit -m "feat: add check_config for YAML config validation

check_config validates that a config file exists, yq is on PATH, and
the YAML parses. Returns 0 (valid) or 1 (skip). Warns to stderr on
yq-missing or malformed YAML. Defined outside the main guard so tests
can call it directly."
```

---

## Task 3: Add `resolve` function (TDD)

**Goal:** Add the `resolve` function that resolves one knob through the precedence chain (env > workspace > user > default). Test all precedence cases.

**Files:**
- Modify: `tests/config/test.sh` (add resolve tests)
- Modify: `bin/claude-sandboxed` (add function)

- [ ] **Step 1: Add resolve tests to `tests/config/test.sh`**

Insert this block **before** the final `echo ""` / `Results` lines in `tests/config/test.sh`:

```bash

# --- resolve tests ---
# resolve depends on globals: WORKSPACE_CONFIG, USER_CONFIG,
# WORKSPACE_CONFIG_VALID, USER_CONFIG_VALID. Tests set these directly.

# Setup: create valid config files for resolve tests
printf 'sandbox:\n  uid: 1111\n  gid: 2222\n  username: workspaceuser\n  home: /home/workspaceuser\n' > "$TMPDIR/workspace.yaml"
printf 'sandbox:\n  uid: 3333\n  gid: 4444\n  username: useruser\n  home: /home/useruser\n' > "$TMPDIR/user.yaml"
printf 'sandbox:\n  username: onlyusername\n' > "$TMPDIR/partial.yaml"

# Test: env var wins over workspace and user config
SANDBOX_UID=9999
WORKSPACE_CONFIG="$TMPDIR/workspace.yaml"
USER_CONFIG="$TMPDIR/user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_UID .sandbox.uid 0)
if [[ "$result" == "9999" ]]; then
    ok "resolve: env var wins over workspace and user"
else
    bad "resolve: env var wins (got '$result')"
fi

# Test: workspace wins over user (no env var)
unset SANDBOX_UID
WORKSPACE_CONFIG="$TMPDIR/workspace.yaml"
USER_CONFIG="$TMPDIR/user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_UID .sandbox.uid 0)
if [[ "$result" == "1111" ]]; then
    ok "resolve: workspace wins over user"
else
    bad "resolve: workspace wins over user (got '$result')"
fi

# Test: user fills gap when workspace absent (VALID=false)
unset SANDBOX_UID
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_UID .sandbox.uid 0)
if [[ "$result" == "3333" ]]; then
    ok "resolve: user fills gap when workspace absent"
else
    bad "resolve: user fills gap (got '$result')"
fi

# Test: default when nothing set (both VALID=false)
unset SANDBOX_UID
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
result=$(resolve SANDBOX_UID .sandbox.uid 5555)
if [[ "$result" == "5555" ]]; then
    ok "resolve: default when nothing set"
else
    bad "resolve: default when nothing set (got '$result')"
fi

# Test: missing key in valid workspace file falls through to default
unset SANDBOX_UID
WORKSPACE_CONFIG="$TMPDIR/partial.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=false
result=$(resolve SANDBOX_UID .sandbox.uid 6666)
if [[ "$result" == "6666" ]]; then
    ok "resolve: missing key falls through to default"
else
    bad "resolve: missing key falls through (got '$result')"
fi

# Test: malformed workspace (VALID=false) skipped, user used
unset SANDBOX_UID
WORKSPACE_CONFIG="$TMPDIR/malformed.yaml"
USER_CONFIG="$TMPDIR/user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_UID .sandbox.uid 0)
if [[ "$result" == "3333" ]]; then
    ok "resolve: malformed workspace skipped, user used"
else
    bad "resolve: malformed workspace skipped (got '$result')"
fi

# Test: empty string value in YAML treated as missing, falls through
printf 'sandbox:\n  uid:\n' > "$TMPDIR/emptyval.yaml"
unset SANDBOX_UID
WORKSPACE_CONFIG="$TMPDIR/emptyval.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=false
result=$(resolve SANDBOX_UID .sandbox.uid 7777)
if [[ "$result" == "7777" ]]; then
    ok "resolve: empty string value falls through to default"
else
    bad "resolve: empty string value falls through (got '$result')"
fi
```

- [ ] **Step 2: Run the test to verify the new tests fail**

Run: `bash tests/config/test.sh`

Expected: the 5 `check_config` tests PASS, the 7 new `resolve` tests FAIL with `resolve: command not found`.

- [ ] **Step 3: Add `resolve` function to `bin/claude-sandboxed`**

In `bin/claude-sandboxed`, insert this block **immediately after** the `check_config` function (still before the main guard):

```bash

# Resolve one knob. Env var > validated workspace config > validated user config > default.
# Consults the *_VALID flags set by the up-front check_config calls in main.
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

- [ ] **Step 4: Run the test to verify all tests pass**

Run: `bash tests/config/test.sh`

Expected: all 12 tests PASS (5 check_config + 7 resolve).

- [ ] **Step 5: Run all tests to verify no regressions**

Run: `bash tests/run-all.sh`

Expected: both suites pass.

- [ ] **Step 6: Commit**

```bash
git add bin/claude-sandboxed tests/config/test.sh
git commit -m "feat: add resolve function for config precedence chain

resolve picks a value for one knob by checking env var, then validated
workspace config, then validated user config, then the default. Uses
the *_VALID flags set by check_config to skip invalid files silently.
yq -r returns 'null' for missing keys, which resolve filters out."
```

---

## Task 4: Wire up config discovery and replace hardcoded defaults

**Goal:** Replace the hardcoded `SANDBOX_UID`/`GID`/`USERNAME`/`HOME` defaults with config discovery + `resolve` calls inside the main guard.

**Files:**
- Modify: `bin/claude-sandboxed`

- [ ] **Step 1: Replace the identity block in the main guard**

In `bin/claude-sandboxed`, find this block inside the main guard:

```bash
# User identity mirrored into the container.
# Override any of these in your environment before invoking the script.
export SANDBOX_UID="${SANDBOX_UID:-$(id -u)}"
export SANDBOX_GID="${SANDBOX_GID:-$(id -g)}"
export SANDBOX_USERNAME="${SANDBOX_USERNAME:-$(id -un)}"
export SANDBOX_HOME="${SANDBOX_HOME:-/home/${SANDBOX_USERNAME}}"
```

Replace it with:

```bash
# Config file discovery.
USER_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/claude-sandboxed/config.yaml"
WORKSPACE_CONFIG="$WORKSPACE_DIR/.claude-sandboxed.yaml"

# Validate each config file once; resolve() consults these flags.
WORKSPACE_CONFIG_VALID=false; check_config "$WORKSPACE_CONFIG" && WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=false;       check_config "$USER_CONFIG"     && USER_CONFIG_VALID=true

# User identity mirrored into the container.
# Precedence: env var > workspace config > user config > default.
export SANDBOX_UID="$(resolve SANDBOX_UID .sandbox.uid "$(id -u)")"
export SANDBOX_GID="$(resolve SANDBOX_GID .sandbox.gid "$(id -g)")"
export SANDBOX_USERNAME="$(resolve SANDBOX_USERNAME .sandbox.username "$(id -un)")"
export SANDBOX_HOME="$(resolve SANDBOX_HOME .sandbox.home "/home/$SANDBOX_USERNAME")"
```

- [ ] **Step 2: Verify `--version` still works (no docker needed)**

Run: `./bin/claude-sandboxed --version`

Expected: `claude-sandboxed 0.1.0`

- [ ] **Step 3: Verify the script still sources cleanly**

Run: `bash -c 'source bin/claude-sandboxed && echo OK'`

Expected: `OK` (no errors, no docker output)

- [ ] **Step 4: Run all tests**

Run: `bash tests/run-all.sh`

Expected: both suites pass.

- [ ] **Step 5: Manual check - create a user config and verify it's read**

Run:
```bash
mkdir -p /tmp/cs-test-config/claude-sandboxed
cat > /tmp/cs-test-config/claude-sandboxed/config.yaml <<'EOF'
sandbox:
  uid: 4444
  gid: 4444
  username: testuser
  home: /home/testuser
EOF
XDG_CONFIG_HOME=/tmp/cs-test-config bash -c '
source bin/claude-sandboxed
# Simulate the main guard body (functions are available, but main logic is guarded)
USER_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/claude-sandboxed/config.yaml"
WORKSPACE_CONFIG="/tmp/nonexistent-workspace.yaml"
WORKSPACE_CONFIG_VALID=false; check_config "$WORKSPACE_CONFIG" && WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=false; check_config "$USER_CONFIG" && USER_CONFIG_VALID=true
echo "uid=$(resolve SANDBOX_UID .sandbox.uid 0)"
echo "username=$(resolve SANDBOX_USERNAME .sandbox.username default)"
'
rm -rf /tmp/cs-test-config
```

Expected:
```
uid=4444
username=testuser
```

- [ ] **Step 6: Commit**

```bash
git add bin/claude-sandboxed
git commit -m "feat: wire up config discovery and resolve calls

Replace hardcoded SANDBOX_UID/GID/USERNAME/HOME defaults with config
file discovery + resolve calls. USER_CONFIG at XDG_CONFIG_HOME path,
WORKSPACE_CONFIG at workspace root. Both validated once up front;
resolve consults the *_VALID flags. Env vars still take precedence."
```

---

## Task 5: Update `README.md`

**Goal:** Document `yq` requirement, add Configuration subsection, update roadmap.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add `yq` to Requirements**

In `README.md`, find the Requirements section:

```markdown
## Requirements

- Docker with the Compose plugin (`docker compose`)
- A valid Claude Code session or configuration using external APIs (`~/.claude` credentials)
```

Replace with:

```markdown
## Requirements

- Docker with the Compose plugin (`docker compose`)
- A valid Claude Code session or configuration using external APIs (`~/.claude` credentials)
- `yq` (only if using config files - see [Configuration](#configuration))
```

- [ ] **Step 2: Add Configuration subsection under Customization**

In `README.md`, find the start of the Customization section (`## Customization`). Insert this new subsection **immediately after** the `## Customization` header and **before** the `### User identity` subsection:

```markdown
### Configuration

Identity knobs can be set persistently via YAML config files instead of env vars. Two files are read, in priority order:

| File | Purpose |
|---|---|
| `$WORKSPACE_DIR/.claude-sandboxed.yaml` | Per-project override |
| `${XDG_CONFIG_HOME:-~/.config}/claude-sandboxed/config.yaml` | User defaults |

Both files are optional. Precedence per knob: env var > workspace config > user config > built-in default.

Schema (all fields optional):

```yaml
sandbox:
  uid: 1000          # integer, default: $(id -u)
  gid: 1000          # integer, default: $(id -g)
  username: ryey     # string,  default: $(id -un)
  home: /home/ryey   # string,  default: /home/$username
```

Example `~/.config/claude-sandboxed/config.yaml`:

```yaml
sandbox:
  username: claude-bot
  home: /home/claude-bot
```

Requires `yq` on the host. Either implementation works:
- **mikefarah's Go `yq`** - `go-yq` on Arch, `brew install yq` on macOS, or [download the binary](https://github.com/mikefarah/yq/releases)
- **kislyuk's Python `yq`** - `yq` on Arch, `pip install yq`

If `yq` is not installed, config files are silently ignored and env vars / defaults are used. If a config file exists but `yq` is missing, a warning is printed to stderr.

```

- [ ] **Step 3: Update the Features roadmap**

In `README.md`, find the roadmap entry for Customization:

```markdown
- [ ] **Customizton** - set preferences through config files (with docs and examples)
    - [ ] All isolation designs should be customizable
    - [ ] Git operation policy
    - [ ] Git config
```

Replace with (fixing the typo "Customizton" -> "Customization"):

```markdown
- [ ] **Customization** - set preferences through config files (with docs and examples)
    - [x] **Config foundation** - YAML config loading (`yq`), env > workspace > user > default precedence, identity knobs (`sandbox_uid`/`gid`/`username`/`home`)
    - [ ] All isolation designs should be customizable
    - [ ] Git operation policy
    - [ ] Git config
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document YAML config files in README

Add yq to Requirements, new Configuration subsection under Customization
(schema, file locations, precedence, example), and mark the config
foundation as done in the roadmap."
```

---

## Task 6: Update `docs/development.md`

**Goal:** Document config resolution mechanism and add the new invariant.

**Files:**
- Modify: `docs/development.md`

- [ ] **Step 1: Add config resolution invariant**

In `docs/development.md`, find the Key invariants section. Add this line to the list (after the existing `WORKSPACE_DIR` / `SANDBOX_*` invariant lines, near the top of the list):

```markdown
- `WORKSPACE_DIR` must be resolved to an absolute path before `WORKSPACE_CONFIG` is derived from it (the workspace config path is `$WORKSPACE_DIR/.claude-sandboxed.yaml`).
- Config file functions (`check_config`, `resolve`) must remain defined outside the main execution guard so tests can source the launcher and call them directly.
```

- [ ] **Step 2: Add Config resolution section**

In `docs/development.md`, find the `## Compose file location resolution` section. Insert this new section **immediately before** it:

```markdown
## Config resolution

Identity knobs (`SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USERNAME`, `SANDBOX_HOME`) are resolved per-knob from four sources in priority order:

1. **Env var** (`SANDBOX_UID`, etc.) - if set and non-empty.
2. **Workspace config** (`$WORKSPACE_DIR/.claude-sandboxed.yaml`) - if the key is present and non-null.
3. **User config** (`${XDG_CONFIG_HOME:-$HOME/.config}/claude-sandboxed/config.yaml`) - if the key is present and non-null.
4. **Default** (`$(id -u)`, `$(id -g)`, `$(id -un)`, `/home/$SANDBOX_USERNAME`).

Two bash functions in `bin/claude-sandboxed` implement this:

- `check_config FILE` - returns 0 if the file exists, `yq` is on `PATH`, and the YAML parses; returns 1 (with a stderr warning) otherwise. Missing files return 1 silently.
- `resolve ENV_NAME YQ_PATH DEFAULT` - checks the env var, then the validated workspace config, then the validated user config, then the default. Consults `WORKSPACE_CONFIG_VALID` / `USER_CONFIG_VALID` flags set by up-front `check_config` calls.

`yq` is a host-only dependency. Either mikefarah's Go `yq` or kislyuk's Python `yq` works - the spec uses only `yq '.' file` (validation) and `yq -r '.path' file` (key lookup), which are common-denominator operations.

```

- [ ] **Step 3: Commit**

```bash
git add docs/development.md
git commit -m "docs: document config resolution in development.md

Add Config resolution section (precedence, check_config/resolve
functions, yq host-only dep) and two new invariants (WORKSPACE_DIR
must be absolute before deriving WORKSPACE_CONFIG; config functions
must stay outside the main guard for testability)."
```

---

## Task 7: Final verification

**Goal:** Verify the complete implementation works end-to-end.

- [ ] **Step 1: Run all tests**

Run: `bash tests/run-all.sh`

Expected: `All 2 test suite(s) passed.` (git-wrapper + config)

- [ ] **Step 2: Verify `--version` works**

Run: `./bin/claude-sandboxed --version`

Expected: `claude-sandboxed 0.1.0`

- [ ] **Step 3: Verify sourcing works (no side effects)**

Run: `bash -c 'source bin/claude-sandboxed && echo "VERSION=$VERSION"'`

Expected: `VERSION=0.1.0` (no docker output, no errors)

- [ ] **Step 4: Verify config file is read end-to-end (no docker)**

Run:
```bash
mkdir -p /tmp/cs-final-test/claude-sandboxed
cat > /tmp/cs-final-test/claude-sandboxed/config.yaml <<'EOF'
sandbox:
  uid: 4321
  gid: 4321
  username: finaltest
  home: /home/finaltest
EOF
# Source and manually invoke the config resolution (simulates main guard body)
XDG_CONFIG_HOME=/tmp/cs-final-test bash -c '
source bin/claude-sandboxed
WORKSPACE_DIR=/tmp
USER_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/claude-sandboxed/config.yaml"
WORKSPACE_CONFIG="$WORKSPACE_DIR/.claude-sandboxed.yaml"
WORKSPACE_CONFIG_VALID=false; check_config "$WORKSPACE_CONFIG" && WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=false; check_config "$USER_CONFIG" && USER_CONFIG_VALID=true
echo "uid=$(resolve SANDBOX_UID .sandbox.uid 0)"
echo "gid=$(resolve SANDBOX_GID .sandbox.gid 0)"
echo "username=$(resolve SANDBOX_USERNAME .sandbox.username default)"
echo "home=$(resolve SANDBOX_HOME .sandbox.home /default)"
'
rm -rf /tmp/cs-final-test
```

Expected:
```
uid=4321
gid=4321
username=finaltest
home=/home/finaltest
```

- [ ] **Step 5: Verify env var overrides config**

Run:
```bash
mkdir -p /tmp/cs-env-test/claude-sandboxed
cat > /tmp/cs-env-test/claude-sandboxed/config.yaml <<'EOF'
sandbox:
  uid: 4321
EOF
XDG_CONFIG_HOME=/tmp/cs-env-test SANDBOX_UID=8888 bash -c '
source bin/claude-sandboxed
USER_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/claude-sandboxed/config.yaml"
WORKSPACE_CONFIG="/nonexistent"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false; check_config "$USER_CONFIG" && USER_CONFIG_VALID=true
echo "uid=$(resolve SANDBOX_UID .sandbox.uid 0)"
'
rm -rf /tmp/cs-env-test
```

Expected:
```
uid=8888
```

- [ ] **Step 6: Verify all commits are in place**

Run: `git log --oneline -7`

Expected: 6 commits from this plan (Tasks 1-6), most recent first.

- [ ] **Step 7: No commit needed if all verification passes**

If any verification fails, fix the issue and amend the relevant task's commit.

---

## Self-Review Notes

**Spec coverage check:**
- Config file locations (user + workspace) → Task 4 (discovery), Task 5 (docs)
- Schema (nested under `sandbox:`) → Task 5 (README docs), Tasks 2-3 (tests use this schema)
- Precedence (env > workspace > user > default) → Task 3 (resolve tests cover all 4 levels)
- Resolution mechanism (check_config + resolve) → Tasks 2-3
- Error handling (yq missing, malformed YAML, empty values) → Task 2 (check_config tests), Task 3 (resolve tests for empty-value and malformed-file cases)
- Integration into bin/claude-sandboxed → Task 4
- Testing (7 cases from spec) → Task 3 covers all 7 spec cases + extra edge cases (8 total resolve tests)
- Documentation updates → Tasks 5-6
- Main guard for testability → Task 1

**Placeholder scan:** No TBDs, TODOs, or "fill in later". All code is complete.

**Type consistency:** `check_config` signature is `(FILE)` in spec, Task 2, and Task 4. `resolve` signature is `(ENV_NAME YQ_PATH DEFAULT)` in spec, Task 3, and Task 4. `*_VALID` flag names match between Task 3 (resolve function) and Task 4 (wiring).
