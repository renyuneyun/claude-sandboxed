# Git Local-Override Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a boolean knob (`git.allow_local_operations`) and CLI flag (`--allow-local-git`) that switches the git wrapper into a mode where only `git push` is blocked and all local operations are allowed unconditionally, ignoring user `policy.allow`/`block` rules.

**Architecture:** A new env var `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS` flows from CLI flag / config / env through the launcher into the container. The git wrapper reads it at the top of its policy section; when `true`, it runs a single `push` check and skips both the user policy file and the built-in default blocks. Remote push protection in the container entrypoint (system git config) is unchanged.

**Tech Stack:** Bash, Docker Compose command assembly, yq-backed YAML configuration, shell test suites, Markdown documentation.

**Spec:** `docs/superpowers/specs/2026-08-05-git-local-override-design.md`

## Global Constraints

- `git.allow_local_operations` defaults to `false`. Precedence: CLI flag > env var > workspace config > user config > default.
- When `true`, the wrapper blocks only `git push`; user `policy.allow`/`block` rules are ignored entirely.
- The CLI flag `--allow-local-git` is a boolean (presence = `true`). No `--no-` variant; disabling from CLI when config has it on uses `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=false`.
- The system git config in the container entrypoint (SSH push block + GitHub URL rewrite) is unchanged - it remains as defense-in-depth remote push protection.
- `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS` is launcher-side only: not exported to the host environment, not interpolated by the compose file. The launcher passes it to the container via `-e` only when `true`.
- A warning is printed to stderr when `allow_local_operations == true` AND (`policy.allow` or `policy.block` is non-empty).
- Follow the existing `resolve_tool` pattern: store the CLI value in a `CLI_ALLOW_LOCAL_GIT` variable inside `parse_launcher_args`, then resolve via a new `resolve_allow_local` function so the logic is unit-testable.

---

### Task 1: Wrapper override gate

Add the override gate to `share/claude-sandboxed/git-wrapper` and test it in isolation with stubbed git. The wrapper reads `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS` from its environment; no launcher changes are needed for these tests (the env var is set directly on the wrapper invocation).

**Files:**
- Modify: `tests/git-wrapper/test.sh`
- Modify: `share/claude-sandboxed/git-wrapper`

- [ ] **Step 1: Write failing wrapper tests**

Append to `tests/git-wrapper/test.sh`, before the final `echo "$pass passed, $fail failed"` line:

```bash

# --- Local-override mode tests ---
# When SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true, only push is blocked.
# User policy file is also ignored.

# Same as assert_blocked but with SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true.
assert_blocked_override() {
    local desc="$1"; shift
    rm -f "$STUB_DIR/called"
    local err code
    err="$(REAL_GIT="$STUB_DIR/git" SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true "$WRAPPER" "$@" 2>&1 >/dev/null)" && code=0 || code=$?
    if [[ $code -ne 1 ]]; then
        echo "FAIL: $desc (exit $code, expected 1)"
        fail=$((fail+1)); return
    fi
    if [[ "$err" != *"[SECURITY]"* ]]; then
        echo "FAIL: $desc (no [SECURITY] in stderr: $err)"
        fail=$((fail+1)); return
    fi
    if [[ -f "$STUB_DIR/called" ]]; then
        echo "FAIL: $desc (real git was called despite block)"
        fail=$((fail+1)); return
    fi
    echo "PASS: $desc"
    pass=$((pass+1))
}

# Same as assert_allowed but with SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true.
assert_allowed_override() {
    local desc="$1"; shift
    rm -f "$STUB_DIR/called"
    REAL_GIT="$STUB_DIR/git" SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true "$WRAPPER" "$@" >/dev/null 2>&1
    local code=$?
    if [[ $code -ne 0 ]]; then
        echo "FAIL: $desc (exit $code, expected 0)"
        fail=$((fail+1)); return
    fi
    if [[ ! -f "$STUB_DIR/called" ]]; then
        echo "FAIL: $desc (real git was not called)"
        fail=$((fail+1)); return
    fi
    echo "PASS: $desc"
    pass=$((pass+1))
}

# Push still blocked in override mode
assert_blocked_override "override: git push" push
assert_blocked_override "override: git push origin main" push origin main

# Previously-blocked local ops now allowed
assert_allowed_override "override: git reset --hard HEAD~1" reset --hard HEAD~1
assert_allowed_override "override: git reset --soft HEAD~1" reset --soft HEAD~1
assert_allowed_override "override: git commit --amend" commit --amend
assert_allowed_override "override: git commit --reset-author" commit --reset-author
assert_allowed_override "override: git branch -D x" branch -D x
assert_allowed_override "override: git branch --delete --force x" branch --delete --force x
assert_allowed_override "override: git config user.name X" config user.name X
assert_allowed_override "override: git config --global user.name X" config --global user.name X
assert_allowed_override "override: git clean -fd" clean -fd
assert_allowed_override "override: git rebase main" rebase main
assert_allowed_override "override: git stash drop" stash drop
assert_allowed_override "override: git stash clear" stash clear
assert_allowed_override "override: git tag -f v1" tag -f v1
assert_allowed_override "override: git tag --force v1" tag --force v1
assert_allowed_override "override: git checkout -B x" checkout -B x
assert_allowed_override "override: git checkout --force x" checkout --force x
assert_allowed_override "override: git switch -C x" switch -C x
assert_allowed_override "override: git restore --worktree x" restore --worktree x
assert_allowed_override "override: git rm file" rm file
assert_allowed_override "override: git gc --prune" gc --prune
assert_allowed_override "override: git reflog expire" reflog expire
assert_allowed_override "override: git notes remove" notes remove
assert_allowed_override "override: git worktree remove x" worktree remove x
assert_allowed_override "override: git commit-tree HEAD" commit-tree HEAD
assert_allowed_override "override: git update-ref refs/heads/x HEAD" update-ref refs/heads/x HEAD
assert_allowed_override "override: git replace refs/heads/x HEAD" replace refs/heads/x HEAD
assert_allowed_override "override: git filter-branch" filter-branch
assert_allowed_override "override: git filter-repo" filter-repo
assert_allowed_override "override: git fast-import" fast-import
assert_allowed_override "override: git prune" prune
assert_allowed_override "override: git symbolic-ref" symbolic-ref

# Default-allowed ops still allowed
assert_allowed_override "override: git status" status
assert_allowed_override "override: git log" log

# User policy file ignored in override mode
POLICY_TMP="$(mktemp)"
printf '[block]\n^status$\n[allow]\n^push$\n' > "$POLICY_TMP"
rm -f "$STUB_DIR/called"
REAL_GIT="$STUB_DIR/git" SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true GIT_POLICY_FILE="$POLICY_TMP" "$WRAPPER" status >/dev/null 2>&1
code=$?
if [[ $code -eq 0 && -f "$STUB_DIR/called" ]]; then
    echo "PASS: override: user policy block on status ignored"
    pass=$((pass+1))
else
    echo "FAIL: override: user policy block on status ignored (code=$code)"
    fail=$((fail+1))
fi
rm -f "$STUB_DIR/called"
REAL_GIT="$STUB_DIR/git" SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true GIT_POLICY_FILE="$POLICY_TMP" "$WRAPPER" push >/dev/null 2>&1
code=$?
if [[ $code -eq 1 && ! -f "$STUB_DIR/called" ]]; then
    echo "PASS: override: user policy allow on push ignored"
    pass=$((pass+1))
else
    echo "FAIL: override: user policy allow on push ignored (code=$code)"
    fail=$((fail+1))
fi
rm -f "$POLICY_TMP"
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
bash tests/git-wrapper/test.sh 2>&1 | grep -E "^(PASS|FAIL):" | grep "override:"
```

Expected: multiple `FAIL` lines - the override tests fail because the wrapper has no override gate yet (e.g., "override: git reset --hard HEAD~1" fails because the wrapper still blocks reset).

- [ ] **Step 3: Implement the override gate**

In `share/claude-sandboxed/git-wrapper`, insert this block after the `if [[ -z "$subcommand" ]]; then exec "$REAL_GIT" "$@"; fi` block (currently around line 45) and before the `# --- User policy file ---` comment:

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

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
bash tests/git-wrapper/test.sh
```

Expected: all `PASS:`, including the new `override:` lines. Final line: `N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add share/claude-sandboxed/git-wrapper tests/git-wrapper/test.sh
git commit -m "feat: add git local-override mode to wrapper"
```

---

### Task 2: Launcher CLI flag parsing

Add `--allow-local-git` to `parse_launcher_args` and initialize `CLI_ALLOW_LOCAL_GIT`. Follow the existing `--tool` pattern: store in a CLI-specific variable, resolve later.

**Files:**
- Modify: `tests/launcher/test.sh`
- Modify: `bin/claude-sandboxed`

- [ ] **Step 1: Write failing launcher parse tests**

In `tests/launcher/test.sh`, after the existing `parse_launcher_args --tool codex ...` block (around line 80), add:

```bash

parse_launcher_args --allow-local-git
assert_eq "parse: allow-local-git sets CLI_ALLOW_LOCAL_GIT" "true" "${CLI_ALLOW_LOCAL_GIT:-}"

parse_launcher_args
assert_eq "parse: no flag leaves CLI_ALLOW_LOCAL_GIT empty" "" "${CLI_ALLOW_LOCAL_GIT:-}"

parse_launcher_args --allow-local-git --tool codex
assert_eq "parse: allow-local-git with tool" "true" "${CLI_ALLOW_LOCAL_GIT:-}"
assert_eq "parse: tool with allow-local-git" "codex" "$CLI_TOOL"

parse_launcher_args --tool codex --allow-local-git
assert_eq "parse: flag order independence (tool)" "codex" "$CLI_TOOL"
assert_eq "parse: flag order independence (override)" "true" "${CLI_ALLOW_LOCAL_GIT:-}"

# Reset state
unset CLI_ALLOW_LOCAL_GIT
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
bash tests/launcher/test.sh 2>&1 | grep -E "^(PASS|FAIL):" | grep "allow-local-git\|flag order"
```

Expected: multiple `FAIL` lines because `CLI_ALLOW_LOCAL_GIT` is not set (the parser doesn't recognize `--allow-local-git` yet, so it errors out as an unsupported option).

- [ ] **Step 3: Implement CLI flag parsing**

In `bin/claude-sandboxed`, modify `parse_launcher_args()`:

First, add `CLI_ALLOW_LOCAL_GIT=""` to the initialization block at the top of the function. The current block:

```bash
parse_launcher_args() {
  CLI_TOOL=""
  WORKSPACE_ARG=""
  TOOL_USER_ARGS=()
```

becomes:

```bash
parse_launcher_args() {
  CLI_TOOL=""
  CLI_ALLOW_LOCAL_GIT=""
  WORKSPACE_ARG=""
  TOOL_USER_ARGS=()
```

Then add a new case in the `while` loop's `case` statement, before the `--tool)` case:

```bash
      --allow-local-git)
        CLI_ALLOW_LOCAL_GIT=true
        shift
        ;;
      --tool)
```

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
bash tests/launcher/test.sh
```

Expected: all `PASS:`, including the new `allow-local-git` lines. Final line: `N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/claude-sandboxed tests/launcher/test.sh
git commit -m "feat: parse --allow-local-git CLI flag"
```

---

### Task 3: Launcher knob resolution

Add a `resolve_allow_local` function (following the `resolve_tool` pattern) and resolve `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS` in main execution. Add config resolution tests for `.git.allow_local_operations`.

**Files:**
- Modify: `tests/launcher/test.sh`
- Modify: `tests/config/test.sh`
- Modify: `bin/claude-sandboxed`

- [ ] **Step 1: Write failing launcher resolution tests**

In `tests/launcher/test.sh`, after the `resolve_tool` tests (around line 113, after the `if command -v yq ... fi` block), add:

```bash

# --- resolve_allow_local tests ---
# Follows the resolve_tool pattern: CLI value wins, else resolve() from env/config/default.

# Without yq, only env var and default matter
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
unset SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS
assert_eq "resolve_allow_local: default false" "false" "$(resolve_allow_local "")"
assert_eq "resolve_allow_local: CLI true wins" "true" "$(resolve_allow_local true)"
SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true
assert_eq "resolve_allow_local: env true" "true" "$(resolve_allow_local "")"
SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=false
assert_eq "resolve_allow_local: env false" "false" "$(resolve_allow_local "")"
assert_eq "resolve_allow_local: CLI true beats env false" "true" "$(resolve_allow_local true)"
unset SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS

if command -v yq >/dev/null 2>&1; then
    ALLOW_TMP="$(mktemp -d)"
    PROFILE_TMP_DIRS+=("$ALLOW_TMP")
    printf 'git:\n  allow_local_operations: true\n' > "$ALLOW_TMP/workspace.yaml"
    printf 'git:\n  allow_local_operations: false\n' > "$ALLOW_TMP/user.yaml"
    WORKSPACE_CONFIG="$ALLOW_TMP/workspace.yaml"
    USER_CONFIG="$ALLOW_TMP/user.yaml"
    WORKSPACE_CONFIG_VALID=true
    USER_CONFIG_VALID=true
    unset SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS
    assert_eq "resolve_allow_local: workspace true beats user false" "true" "$(resolve_allow_local "")"
    WORKSPACE_CONFIG_VALID=false
    assert_eq "resolve_allow_local: user false when workspace invalid" "false" "$(resolve_allow_local "")"
    SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true
    assert_eq "resolve_allow_local: env beats workspace" "true" "$(resolve_allow_local "")"
    assert_eq "resolve_allow_local: CLI beats env" "false" "$(resolve_allow_local false)"
    unset SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS
fi

# Restore state for subsequent tests
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
```

- [ ] **Step 2: Write failing config resolution tests**

In `tests/config/test.sh`, after the `git.host_config_passthrough` tests (search for `resolve: git.host_config_passthrough env var "false" wins`), add:

```bash

# --- resolve tests for git.allow_local_operations ---

# Setup: config files with allow_local_operations
printf 'git:\n  allow_local_operations: true\n' > "$TMPDIR/allow-workspace.yaml"
printf 'git:\n  allow_local_operations: false\n' > "$TMPDIR/allow-user.yaml"

# Test: git.allow_local_operations - env var wins
SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=false
WORKSPACE_CONFIG="$TMPDIR/allow-workspace.yaml"
USER_CONFIG="$TMPDIR/allow-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS .git.allow_local_operations false)
if [[ "$result" == "false" ]]; then
    ok "resolve: git.allow_local_operations env var wins"
else
    bad "resolve: git.allow_local_operations env var wins (got '$result')"
fi

# Test: git.allow_local_operations - workspace wins over user (no env)
unset SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS
WORKSPACE_CONFIG="$TMPDIR/allow-workspace.yaml"
USER_CONFIG="$TMPDIR/allow-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS .git.allow_local_operations false)
if [[ "$result" == "true" ]]; then
    ok "resolve: git.allow_local_operations workspace wins over user"
else
    bad "resolve: git.allow_local_operations workspace wins over user (got '$result')"
fi

# Test: git.allow_local_operations - user fills gap when workspace absent
unset SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/allow-user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS .git.allow_local_operations false)
if [[ "$result" == "false" ]]; then
    ok "resolve: git.allow_local_operations user fills gap when workspace absent"
else
    bad "resolve: git.allow_local_operations user fills gap (got '$result')"
fi

# Test: git.allow_local_operations - default false when nothing set
unset SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
result=$(resolve SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS .git.allow_local_operations false)
if [[ "$result" == "false" ]]; then
    ok "resolve: git.allow_local_operations default false"
else
    bad "resolve: git.allow_local_operations default (got '$result')"
fi
```

- [ ] **Step 3: Run tests and verify RED**

Run:

```bash
bash tests/launcher/test.sh 2>&1 | grep -E "^(PASS|FAIL):" | grep "resolve_allow_local"
bash tests/config/test.sh 2>&1 | grep -E "^(PASS|FAIL):" | grep "allow_local_operations"
```

Expected: launcher tests fail because `resolve_allow_local` is not defined. Config tests should PASS already (they test the existing `resolve` function with a new yq path, which works without code changes) - if they pass, that's fine; they're added for coverage.

- [ ] **Step 4: Implement resolve_allow_local function**

In `bin/claude-sandboxed`, add a new function after `resolve_tool()` (around line 105, after the closing `}` of `resolve_tool`):

```bash
resolve_allow_local() {
  local cli_value="$1" selected
  if [[ -n "$cli_value" ]]; then
    selected="$cli_value"
  else
    selected="$(resolve SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS .git.allow_local_operations false)"
  fi
  echo "$selected"
}
```

- [ ] **Step 5: Resolve the knob in main execution**

In `bin/claude-sandboxed`, in the main execution block, after the `SANDBOX_GIT_POLICY_BLOCK` resolve_list call (search for `SANDBOX_GIT_POLICY_BLOCK="$(resolve_list`), add:

```bash

# Git local-override mode: when true, the wrapper blocks only git push
# and ignores the user policy file. CLI flag > env > config > default.
SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS="$(resolve_allow_local "$CLI_ALLOW_LOCAL_GIT")"
```

- [ ] **Step 6: Run tests and verify GREEN**

Run:

```bash
bash tests/launcher/test.sh
bash tests/config/test.sh
```

Expected: all `PASS:`. Final line of each: `N passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add bin/claude-sandboxed tests/launcher/test.sh tests/config/test.sh
git commit -m "feat: resolve git.allow_local_operations knob"
```

---

### Task 4: Pass env var to container

Add `GIT_MODE_ENV_ARGS` array, conditionally filled when `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS == true`, and insert it into the `docker compose run` command. Test via the captured Docker invocation.

**Files:**
- Modify: `tests/launcher/test.sh`
- Modify: `bin/claude-sandboxed`

- [ ] **Step 1: Write failing integration test**

In `tests/launcher/test.sh`, after the existing `run_captured_launcher` integration tests (around line 235, after the `unset TEST_HTTP_PROXY TEST_PROXY_PASSTHROUGH` line), add:

```bash

# --- GIT_MODE_ENV_ARGS integration tests ---
CAPTURE_DIR_OVERRIDE="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$CAPTURE_DIR_OVERRIDE")
run_captured_launcher "$CAPTURE_DIR_OVERRIDE" --allow-local-git "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<-e><SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true>"* ]] &&
  ok "integration: --allow-local-git reaches Docker env" ||
  bad "integration: --allow-local-git reaches Docker env ($CAPTURED_JOINED)"

CAPTURE_DIR_NO_OVERRIDE="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$CAPTURE_DIR_NO_OVERRIDE")
run_captured_launcher "$CAPTURE_DIR_NO_OVERRIDE" "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" != *"<SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true>"* ]] &&
  ok "integration: no override flag omits env var" ||
  bad "integration: no override flag omits env var ($CAPTURED_JOINED)"

CAPTURE_DIR_ENV_OVERRIDE="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$CAPTURE_DIR_ENV_OVERRIDE")
SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true run_captured_launcher "$CAPTURE_DIR_ENV_OVERRIDE" "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<-e><SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true>"* ]] &&
  ok "integration: env var override reaches Docker" ||
  bad "integration: env var override reaches Docker ($CAPTURED_JOINED)"
unset SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
bash tests/launcher/test.sh 2>&1 | grep -E "^(PASS|FAIL):" | grep "override.*reaches Docker\|omits env var"
```

Expected: `FAIL` lines because `GIT_MODE_ENV_ARGS` is not populated or inserted into the docker command yet.

- [ ] **Step 3: Implement GIT_MODE_ENV_ARGS**

In `bin/claude-sandboxed`, in the main execution block, after the `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS` resolution (added in Task 3 Step 5) and after the `GIT_POLICY_VOLUME_ARGS` block (search for `trap 'rm -f "$POLICY_FILE"' EXIT`), add:

```bash

# Git local-override env var: passed into the container only when true.
GIT_MODE_ENV_ARGS=()
if [[ "$SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS" == "true" ]]; then
    GIT_MODE_ENV_ARGS+=(-e SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS=true)
fi
```

Then modify the `docker compose run` command to insert `"${GIT_MODE_ENV_ARGS[@]}"`. The current command:

```bash
docker compose -p "$COMPOSE_PROJECT" -f "$SANDBOX_COMPOSE_DIR/docker-compose.yml" run \
  --rm \
  -e HOME="${SANDBOX_HOME}" \
  "${PROXY_ENV_ARGS[@]}" \
  "${TOOL_ENV_ARGS[@]}" \
  "${GIT_ENV_ARGS[@]}" \
  "${GIT_VOLUME_ARGS[@]}" \
  "${TOOL_VOLUME_ARGS[@]}" \
  "${GIT_POLICY_VOLUME_ARGS[@]}" \
  -it ai-agent \
  npx --yes "$TOOL_PACKAGE" "${TOOL_DEFAULT_ARGS[@]}" "${TOOL_USER_ARGS[@]}"
```

becomes:

```bash
docker compose -p "$COMPOSE_PROJECT" -f "$SANDBOX_COMPOSE_DIR/docker-compose.yml" run \
  --rm \
  -e HOME="${SANDBOX_HOME}" \
  "${PROXY_ENV_ARGS[@]}" \
  "${TOOL_ENV_ARGS[@]}" \
  "${GIT_ENV_ARGS[@]}" \
  "${GIT_MODE_ENV_ARGS[@]}" \
  "${GIT_VOLUME_ARGS[@]}" \
  "${TOOL_VOLUME_ARGS[@]}" \
  "${GIT_POLICY_VOLUME_ARGS[@]}" \
  -it ai-agent \
  npx --yes "$TOOL_PACKAGE" "${TOOL_DEFAULT_ARGS[@]}" "${TOOL_USER_ARGS[@]}"
```

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
bash tests/launcher/test.sh
```

Expected: all `PASS:`. Final line: `N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/claude-sandboxed tests/launcher/test.sh
git commit -m "feat: pass git allow_local_operations to container"
```

---

### Task 5: Warn on conflicting config

Print a warning to stderr when `allow_local_operations == true` AND (`SANDBOX_GIT_POLICY_ALLOW` or `SANDBOX_GIT_POLICY_BLOCK` is non-empty). Test by capturing the launcher's stderr.

**Files:**
- Modify: `tests/launcher/test.sh`
- Modify: `bin/claude-sandboxed`

- [ ] **Step 1: Write failing warning tests**

In `tests/launcher/test.sh`, after the `GIT_MODE_ENV_ARGS` integration tests (added in Task 4), add:

```bash

# --- Conflicting config warning tests ---
# Runs the launcher as a subprocess and captures stderr to check for the warning.
run_launcher_stderr() {
    local capture_dir="$1"
    shift
    mkdir -p "$capture_dir/bin" "$capture_dir/home"
    printf '#!/bin/sh\nexit 0\n' > "$capture_dir/bin/docker"
    chmod +x "$capture_dir/bin/docker"
    HOME="$capture_dir/home" \
    XDG_CONFIG_HOME="$capture_dir/home/.config" \
    SANDBOX_UID=1234 \
    SANDBOX_GID=1234 \
    SANDBOX_USERNAME=tester \
    SANDBOX_HOME=/home/tester \
    SANDBOX_CLEANUP=false \
    CLAUDE_VERSION=integration-test \
    CLAUDE_SANDBOXED_DIR="$SCRIPT_DIR/../../share/claude-sandboxed" \
    PATH="$capture_dir/bin:$PATH" \
      bash "$LAUNCHER" "$@" 2>&1 >/dev/null
}

WARN_DIR_1="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$WARN_DIR_1")
output=$(run_launcher_stderr "$WARN_DIR_1" --allow-local-git "$SCRIPT_DIR/../..")
if [[ "$output" == *"git.allow_local_operations is enabled"* && "$output" == *"git.policy.allow/block rules will be ignored"* ]]; then
    bad "warn: no policy set, no warning expected (got warning)"
else
    ok "warn: no policy set, no warning"
fi

WARN_DIR_2="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$WARN_DIR_2")
output=$(SANDBOX_GIT_POLICY_BLOCK="^stash pop" run_launcher_stderr "$WARN_DIR_2" --allow-local-git "$SCRIPT_DIR/../..")
if [[ "$output" == *"git.allow_local_operations is enabled; git.policy.allow/block rules will be ignored."* ]]; then
    ok "warn: override + policy.block emits warning"
else
    bad "warn: override + policy.block emits warning (got '$output')"
fi

WARN_DIR_3="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$WARN_DIR_3")
output=$(SANDBOX_GIT_POLICY_ALLOW="^reset" run_launcher_stderr "$WARN_DIR_3" --allow-local-git "$SCRIPT_DIR/../..")
if [[ "$output" == *"git.allow_local_operations is enabled; git.policy.allow/block rules will be ignored."* ]]; then
    ok "warn: override + policy.allow emits warning"
else
    bad "warn: override + policy.allow emits warning (got '$output')"
fi

WARN_DIR_4="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$WARN_DIR_4")
output=$(SANDBOX_GIT_POLICY_BLOCK="^stash pop" run_launcher_stderr "$WARN_DIR_4" "$SCRIPT_DIR/../..")
if [[ "$output" == *"git.allow_local_operations is enabled"* ]]; then
    bad "warn: no override, no warning expected (got warning)"
else
    ok "warn: no override, no warning"
fi
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
bash tests/launcher/test.sh 2>&1 | grep -E "^(PASS|FAIL):" | grep "warn:"
```

Expected: `FAIL` on the "override + policy.* emits warning" tests because the warning is not implemented yet. The "no warning" tests should PASS.

- [ ] **Step 3: Implement the warning**

In `bin/claude-sandboxed`, in the main execution block, after the `GIT_MODE_ENV_ARGS` block (added in Task 4 Step 3), add:

```bash

# Warn when local-override is on but user policy lists are also set (they'll be ignored).
if [[ "$SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS" == "true" && \
      ( -n "$SANDBOX_GIT_POLICY_ALLOW" || -n "$SANDBOX_GIT_POLICY_BLOCK" ) ]]; then
    echo "claude-sandboxed: git.allow_local_operations is enabled; git.policy.allow/block rules will be ignored." >&2
fi
```

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
bash tests/launcher/test.sh
```

Expected: all `PASS:`. Final line: `N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/claude-sandboxed tests/launcher/test.sh
git commit -m "feat: warn when git allow_local_operations ignores policy rules"
```

---

### Task 6: Documentation

Update `config.example.yaml`, `README.md`, and `docs/development.md` to document the new knob, flag, and invariants.

**Files:**
- Modify: `share/claude-sandboxed/config.example.yaml`
- Modify: `README.md`
- Modify: `docs/development.md`

- [ ] **Step 1: Update config.example.yaml**

In `share/claude-sandboxed/config.example.yaml`, find the `git:` section. After the `host_config_passthrough:` block and before the `policy:` block, add:

```yaml

  # When true, the wrapper blocks only git push and allows all local
  # operations unconditionally (reset --hard, commit --amend, branch -D,
  # config, rebase, etc.). User policy.allow/block rules are ignored.
  # Useful for quick override from the command line: --allow-local-git.
  # Default: false.
  # allow_local_operations: false
```

- [ ] **Step 2: Update README.md schema block**

In `README.md`, find the schema block under `### Configuration` (search for `git:` within the YAML schema). After the `host_config_passthrough: true  # bool, default: true` line and before the `policy:` line, add:

```yaml
  allow_local_operations: false  # bool, default: false
```

- [ ] **Step 3: Add README subsection**

In `README.md`, find the `### Git policy config` subsection. After it ends (before the next `###` heading), add a new subsection:

```markdown
### Local-override mode

When `git.allow_local_operations` is `true`, the wrapper blocks only `git push` and allows all local operations unconditionally - including `reset --hard`, `commit --amend`, `branch -D`, `clean -fd`, `rebase`, `config`, and the history-bypass plumbing commands. User `policy.allow`/`block` rules are ignored entirely in this mode.

Intended for quick override from the command line when you trust the agent with local repository operations:

```sh
claude-sandboxed --allow-local-git
```

Remote push protection is unchanged: the wrapper still blocks `git push`, and the system git config in the container entrypoint still blocks SSH pushes and rewrites GitHub URLs to `https://prohibited/` as defense in depth.

A warning is printed to stderr when `allow_local_operations: true` is combined with non-empty `policy.allow` or `policy.block`, since the policy rules become inert in override mode.
```

- [ ] **Step 4: Update docs/development.md invariants**

In `docs/development.md`, find the invariant bullet that lists launcher-side-only env vars. It starts with:

```
- `SANDBOX_TOOL`, all `CLAUDE_*` and all `CODEX_*` profile knobs, `SANDBOX_PROXY_ENV_PASSTHROUGH`, `SANDBOX_CLEANUP`, `SANDBOX_GIT_POLICY_ALLOW`, and `SANDBOX_GIT_POLICY_BLOCK` are launcher-side only
```

Append `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS` to that list. The full bullet becomes:

```
- `SANDBOX_TOOL`, all `CLAUDE_*` and all `CODEX_*` profile knobs, `SANDBOX_PROXY_ENV_PASSTHROUGH`, `SANDBOX_CLEANUP`, `SANDBOX_GIT_POLICY_ALLOW`, `SANDBOX_GIT_POLICY_BLOCK`, and `SANDBOX_GIT_ALLOW_LOCAL_OPERATIONS` are launcher-side only - they are NOT exported and NOT interpolated by the compose file. The launcher reads them to choose/configure a profile and build `-e` and `-v` flags for `docker compose run`. `GIT_MODE_ENV_ARGS` follows the same conditional-fill pattern as `GIT_ENV_ARGS` and `PROXY_ENV_ARGS` (only populated when the knob is `true`).
```

- [ ] **Step 5: Add manual test checklist items**

In `docs/development.md`, find the `## Manual testing checklist` section. After the last git policy item (item 21, "Git policy doesn't affect unmatched commands"), add:

```markdown
22. **Git local-override:** with `--allow-local-git`, inside the container `git push` is blocked but `git reset --hard`, `git commit --amend`, `git config user.name X`, `git clean -fd`, `git rebase` all work.
23. **Git local-override config:** with `git.allow_local_operations: true` in workspace config, the same behavior as `--allow-local-git` applies.
24. **Git local-override warning:** with `--allow-local-git` and `git.policy.block: ["^stash pop"]` both set, the launcher prints a warning to stderr about policy rules being ignored.
25. **Git local-override policy ignored:** with `--allow-local-git` and a policy file that blocks `git status`, `git status` still works inside the container.
```

Renumber the subsequent items (Claude/Codex tests) if they conflict; otherwise append after the existing list.

- [ ] **Step 6: Run all tests and verify nothing broke**

Run:

```bash
bash tests/run-all.sh
```

Expected: all test suites pass. Final output includes `N passed, 0 failed` for each suite.

- [ ] **Step 7: Commit**

```bash
git add share/claude-sandboxed/config.example.yaml README.md docs/development.md
git commit -m "docs: document git local-override mode"
```

---

### Task 7: Final verification

Run the full test suite and manual smoke checks to confirm everything works end-to-end.

**Files:** None (verification only)

- [ ] **Step 1: Run all automated tests**

Run:

```bash
bash tests/run-all.sh
```

Expected: all test suites pass with `0 failed`.

- [ ] **Step 2: Verify CLI flag parsing**

Run:

```sh
./bin/claude-sandboxed --help 2>&1 || true
./bin/claude-sandboxed --allow-local-git --version
```

Expected: `--version` prints the version. The `--allow-local-git` flag is accepted (no "unsupported option" error).

- [ ] **Step 3: Verify warning appears (requires Docker)**

If Docker is available, run:

```sh
SANDBOX_GIT_POLICY_BLOCK="^stash pop" ./bin/claude-sandboxed --allow-local-git . 2>&1 | head -5
```

Expected: first line includes `claude-sandboxed: git.allow_local_operations is enabled; git.policy.allow/block rules will be ignored.` (Then the launcher proceeds to start Docker; interrupt with Ctrl-C if you don't want a full session.)

If Docker is not available, skip this step - the automated tests cover the warning logic.

- [ ] **Step 4: Final commit if any fixups needed**

If steps 1-3 revealed any issues, fix them and commit. Otherwise, no commit needed - the implementation is complete.

```bash
git status
git log --oneline -7
```

Expected: clean working tree (besides the user's local `.claude-sandboxed.yaml` if present). Recent commits show the feature commits from Tasks 1-6.
