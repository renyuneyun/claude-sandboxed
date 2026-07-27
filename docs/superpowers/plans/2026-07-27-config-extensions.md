# Config Extensions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `claude.version`, `claude.config_passthrough`, `sandbox.cleanup`, and a regex-based `git.policy` (file-based) to the YAML config system, following the existing env > workspace > user > default precedence.

**Architecture:** Extend the existing `resolve()` pattern in `bin/claude-sandboxed` for scalar knobs. Add a new `resolve_list()` helper for the git policy arrays. Move `~/.claude` mounts from `docker-compose.yml` into the launcher as `CLAUDE_VOLUME_ARGS` (mirroring `GIT_VOLUME_ARGS`). Generate a policy file on the host, mount it into the container, and have `git-wrapper` parse it before applying the default policy.

**Tech Stack:** Bash, `yq` (host-only), Docker Compose, existing test harness (`tests/*/test.sh`).

**Spec:** `docs/superpowers/specs/2026-07-27-config-extensions-design.md`

---

## Commit Unit 1: `claude.version` + `sandbox.cleanup`

Simple resolve calls that don't touch the compose file or the wrapper. Tested via `tests/config/test.sh`.

### Task 1: Add `resolve` tests for `claude.version` and `sandbox.cleanup`

**Files:**
- Modify: `tests/config/test.sh` (append before the final `echo "Results:..."` line)

- [ ] **Step 1: Add test cases to `tests/config/test.sh`**

Append the following block before the final `echo ""` / `echo "Results:..."` lines at the end of the file:

```bash

# --- resolve tests for claude.version and sandbox.cleanup ---

# Setup: config files with claude and sandbox sections
printf 'claude:\n  version: "1.0.0"\nsandbox:\n  cleanup: false\n' > "$TMPDIR/cs-workspace.yaml"
printf 'claude:\n  version: "2.0.0"\nsandbox:\n  cleanup: true\n' > "$TMPDIR/cs-user.yaml"

# Test: claude.version - env var wins
CLAUDE_VERSION=env-version
WORKSPACE_CONFIG="$TMPDIR/cs-workspace.yaml"
USER_CONFIG="$TMPDIR/cs-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve CLAUDE_VERSION .claude.version "default-ver")
if [[ "$result" == "env-version" ]]; then
    ok "resolve: claude.version env var wins"
else
    bad "resolve: claude.version env var wins (got '$result')"
fi

# Test: claude.version - workspace wins over user (no env)
unset CLAUDE_VERSION
WORKSPACE_CONFIG="$TMPDIR/cs-workspace.yaml"
USER_CONFIG="$TMPDIR/cs-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve CLAUDE_VERSION .claude.version "default-ver")
if [[ "$result" == "1.0.0" ]]; then
    ok "resolve: claude.version workspace wins over user"
else
    bad "resolve: claude.version workspace wins over user (got '$result')"
fi

# Test: claude.version - user fills gap when workspace absent
unset CLAUDE_VERSION
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/cs-user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve CLAUDE_VERSION .claude.version "default-ver")
if [[ "$result" == "2.0.0" ]]; then
    ok "resolve: claude.version user fills gap"
else
    bad "resolve: claude.version user fills gap (got '$result')"
fi

# Test: claude.version - default when nothing set
unset CLAUDE_VERSION
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
result=$(resolve CLAUDE_VERSION .claude.version "default-ver")
if [[ "$result" == "default-ver" ]]; then
    ok "resolve: claude.version default when nothing set"
else
    bad "resolve: claude.version default (got '$result')"
fi

# Test: sandbox.cleanup - default is "true"
unset SANDBOX_CLEANUP
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
result=$(resolve SANDBOX_CLEANUP .sandbox.cleanup true)
if [[ "$result" == "true" ]]; then
    ok "resolve: sandbox.cleanup default true"
else
    bad "resolve: sandbox.cleanup default (got '$result')"
fi

# Test: sandbox.cleanup - env var "false" wins
SANDBOX_CLEANUP=false
WORKSPACE_CONFIG="$TMPDIR/cs-workspace.yaml"
USER_CONFIG="$TMPDIR/cs-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_CLEANUP .sandbox.cleanup true)
if [[ "$result" == "false" ]]; then
    ok "resolve: sandbox.cleanup env var false wins"
else
    bad "resolve: sandbox.cleanup env false (got '$result')"
fi

# Test: sandbox.cleanup - workspace "false" when no env
unset SANDBOX_CLEANUP
WORKSPACE_CONFIG="$TMPDIR/cs-workspace.yaml"
USER_CONFIG="$TMPDIR/cs-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_CLEANUP .sandbox.cleanup true)
if [[ "$result" == "false" ]]; then
    ok "resolve: sandbox.cleanup workspace false"
else
    bad "resolve: sandbox.cleanup workspace false (got '$result')"
fi

# Test: sandbox.cleanup - user "true" wins over default when workspace absent
unset SANDBOX_CLEANUP
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/cs-user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_CLEANUP .sandbox.cleanup false)
if [[ "$result" == "true" ]]; then
    ok "resolve: sandbox.cleanup user true beats false default"
else
    bad "resolve: sandbox.cleanup user true (got '$result')"
fi
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/config/test.sh 2>&1 | tail -20`
Expected: New tests FAIL (the launcher doesn't resolve `claude.version` from config yet - the env-var-only path returns the default). The existing tests still pass.

Note: some new tests may pass by accident (e.g. `claude.version` default case) because the existing `resolve` function works. The tests that should fail are the ones where workspace/user config has a value but the env var is unset - those will return the default instead of the config value, because the launcher hasn't been modified to call `resolve` for `CLAUDE_VERSION` yet. Wait - actually, the tests call `resolve` directly, not the launcher. So they should pass immediately since `resolve` is path-agnostic. Re-evaluate: these tests verify `resolve()` works for the new paths. Since `resolve` is generic, they will pass. The implementation tasks (Task 2, Task 3) wire the new `resolve` calls into the launcher. So these tests are a pre-check that `resolve` handles the paths; they should PASS immediately.

If they pass immediately, that's fine - the tests document the expected behavior. Move on to Task 2.

### Task 2: Wire `claude.version` into the launcher

**Files:**
- Modify: `bin/claude-sandboxed:56`

- [ ] **Step 1: Move `CLAUDE_VERSION` resolution after config discovery**

The config discovery block (lines 59-65) runs AFTER the current `CLAUDE_VERSION` line. The `resolve` function needs `WORKSPACE_CONFIG_VALID` / `USER_CONFIG_VALID` to be set, which happens in the config discovery block. So we must move both `CLAUDE_VERSION` and `CLAUDE_PACKAGE` to AFTER the config discovery and identity resolution block.

In `bin/claude-sandboxed`, find lines 53-57:

```bash
# Claude Code version to run inside the container.
# Defaults to the version installed on the host to keep credentials compatible.
# Override with e.g. CLAUDE_VERSION=latest or CLAUDE_VERSION=2.1.152
CLAUDE_VERSION="${CLAUDE_VERSION:-$(claude --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)}"
CLAUDE_PACKAGE="@anthropic-ai/claude-code${CLAUDE_VERSION:+@${CLAUDE_VERSION}}"
```

Replace those 5 lines with a single comment:

```bash
# CLAUDE_VERSION and CLAUDE_PACKAGE resolved below, after config discovery.
```

Then, after the `SANDBOX_HOME` resolve line (line 72), add:

```bash

# Claude Code version to run inside the container.
# Precedence: env var > workspace config > user config > host's claude version.
CLAUDE_VERSION="$(resolve CLAUDE_VERSION .claude.version "$(claude --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)")"
CLAUDE_PACKAGE="@anthropic-ai/claude-code${CLAUDE_VERSION:+@${CLAUDE_VERSION}}"
```

- [ ] **Step 2: Run tests to verify nothing broke**

Run: `bash tests/run-all.sh 2>&1 | tail -5`
Expected: `All 2 test suite(s) passed.`

- [ ] **Step 3: Verify the launcher still works**

Run: `bash bin/claude-sandboxed --version`
Expected: prints `claude-sandboxed 0.1.0` (the `--version` flag exits before reaching the CLAUDE_VERSION resolution, so this just verifies the script parses).

### Task 3: Wire `sandbox.cleanup` into the launcher

**Files:**
- Modify: `bin/claude-sandboxed` (add resolve call + wrap cleanup block)

- [ ] **Step 1: Add `SANDBOX_CLEANUP` resolve call**

In `bin/claude-sandboxed`, after the `SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH` resolve line (line 80), add:

```bash

# Cleanup toggle. When false, the cleanup container does not run.
# Precedence: env var > workspace config > user config > default (true).
SANDBOX_CLEANUP="$(resolve SANDBOX_CLEANUP .sandbox.cleanup true)"
```

- [ ] **Step 2: Wrap the cleanup block in a conditional**

Find the cleanup block (lines 138-142):

```bash
if [[ "$WORKSPACE_DIR" == "$SANDBOX_HOME"/* ]]; then
  docker compose -p "$COMPOSE_PROJECT" -f "$SANDBOX_COMPOSE_DIR/docker-compose.yml" run \
    --rm \
    cleanup
fi
```

Replace with:

```bash
if [[ "$SANDBOX_CLEANUP" == "true" && "$WORKSPACE_DIR" == "$SANDBOX_HOME"/* ]]; then
  docker compose -p "$COMPOSE_PROJECT" -f "$SANDBOX_COMPOSE_DIR/docker-compose.yml" run \
    --rm \
    cleanup
fi
```

- [ ] **Step 3: Run tests**

Run: `bash tests/run-all.sh 2>&1 | tail -5`
Expected: `All 2 test suite(s) passed.`

### Task 4: Commit Unit 1

- [ ] **Step 1: Commit**

```bash
git add bin/claude-sandboxed tests/config/test.sh
git commit -m "$(cat <<'EOF'
feat: add claude.version and sandbox.cleanup config knobs

claude.version lets users pin a Claude Code version via YAML config
instead of env var only. sandbox.cleanup toggles the cleanup container
(default true). Both follow env > workspace > user > default precedence.
EOF
)"
```

---

## Commit Unit 2: `claude.config_passthrough`

Moves `~/.claude` and `~/.claude.json` mounts from `docker-compose.yml` into the launcher as `CLAUDE_VOLUME_ARGS`.

### Task 5: Add `resolve` tests for `claude.config_passthrough`

**Files:**
- Modify: `tests/config/test.sh` (append before final Results lines)

- [ ] **Step 1: Add test cases**

Append before the final `echo ""` / `echo "Results:..."` lines:

```bash

# --- resolve tests for claude.config_passthrough ---

printf 'claude:\n  config_passthrough: false\n' > "$TMPDIR/cp-workspace.yaml"
printf 'claude:\n  config_passthrough: true\n' > "$TMPDIR/cp-user.yaml"

# Test: claude.config_passthrough - default is "true"
unset CLAUDE_CONFIG_PASSTHROUGH
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
result=$(resolve CLAUDE_CONFIG_PASSTHROUGH .claude.config_passthrough true)
if [[ "$result" == "true" ]]; then
    ok "resolve: claude.config_passthrough default true"
else
    bad "resolve: claude.config_passthrough default (got '$result')"
fi

# Test: claude.config_passthrough - env var "false" wins
CLAUDE_CONFIG_PASSTHROUGH=false
WORKSPACE_CONFIG="$TMPDIR/cp-workspace.yaml"
USER_CONFIG="$TMPDIR/cp-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve CLAUDE_CONFIG_PASSTHROUGH .claude.config_passthrough true)
if [[ "$result" == "false" ]]; then
    ok "resolve: claude.config_passthrough env false wins"
else
    bad "resolve: claude.config_passthrough env false (got '$result')"
fi

# Test: claude.config_passthrough - workspace "false" when no env
unset CLAUDE_CONFIG_PASSTHROUGH
WORKSPACE_CONFIG="$TMPDIR/cp-workspace.yaml"
USER_CONFIG="$TMPDIR/cp-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve CLAUDE_CONFIG_PASSTHROUGH .claude.config_passthrough true)
if [[ "$result" == "false" ]]; then
    ok "resolve: claude.config_passthrough workspace false"
else
    bad "resolve: claude.config_passthrough workspace false (got '$result')"
fi

# Test: claude.config_passthrough - user "true" beats false default
unset CLAUDE_CONFIG_PASSTHROUGH
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/cp-user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve CLAUDE_CONFIG_PASSTHROUGH .claude.config_passthrough false)
if [[ "$result" == "true" ]]; then
    ok "resolve: claude.config_passthrough user true beats false default"
else
    bad "resolve: claude.config_passthrough user true (got '$result')"
fi
```

- [ ] **Step 2: Run tests**

Run: `bash tests/config/test.sh 2>&1 | tail -10`
Expected: All new tests PASS (resolve is path-agnostic).

### Task 6: Move `~/.claude` mounts into the launcher

**Files:**
- Modify: `bin/claude-sandboxed` (add resolve + CLAUDE_VOLUME_ARGS)
- Modify: `share/claude-sandboxed/docker-compose.yml` (remove two mount lines)

- [ ] **Step 1: Add `CLAUDE_CONFIG_PASSTHROUGH` resolve + `CLAUDE_VOLUME_ARGS`**

In `bin/claude-sandboxed`, after the `SANDBOX_CLEANUP` resolve call (added in Task 3), add:

```bash

# Claude config passthrough: mount host ~/.claude and ~/.claude.json into the container.
# When false, neither is mounted (useful with ANTHROPIC_API_KEY only for isolation).
CLAUDE_CONFIG_PASSTHROUGH="$(resolve CLAUDE_CONFIG_PASSTHROUGH .claude.config_passthrough true)"
```

Then, after the `GIT_VOLUME_ARGS` block (which ends around line 108), add a new `CLAUDE_VOLUME_ARGS` block:

```bash

# Claude config mounts: conditional on passthrough and host file existence.
# Read/write - Claude Code writes session state, settings, etc. here.
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

- [ ] **Step 2: Splice `CLAUDE_VOLUME_ARGS` into the `docker compose run` call**

Find the `docker compose run` call (around line 125). Add `"${CLAUDE_VOLUME_ARGS[@]}" \` after `"${GIT_VOLUME_ARGS[@]}" \`:

```bash
docker compose -p "$COMPOSE_PROJECT" -f "$SANDBOX_COMPOSE_DIR/docker-compose.yml" run \
  --rm \
  -e HOME="${SANDBOX_HOME}" \
  "${GIT_ENV_ARGS[@]}" \
  "${GIT_VOLUME_ARGS[@]}" \
  "${CLAUDE_VOLUME_ARGS[@]}" \
  -it ai-agent npx --yes "$CLAUDE_PACKAGE" --dangerously-skip-permissions
```

- [ ] **Step 3: Remove the two mount lines from `docker-compose.yml`**

In `share/claude-sandboxed/docker-compose.yml`, find and remove these two lines from the `ai-agent.volumes` section:

```yaml
      # 3. CLAUDE CONFIG PASS-THROUGH: Links your local credential configurations
      - ${HOME}/.claude:${SANDBOX_HOME}/.claude
      - ${HOME}/.claude.json:${SANDBOX_HOME}/.claude.json
```

Replace the comment with a note that these are now injected by the launcher:

```yaml
      # 3. CLAUDE CONFIG PASS-THROUGH: Injected dynamically by the launcher
      #    (CLAUDE_VOLUME_ARGS) so it can be toggled via config.
      #    See bin/claude-sandboxed for the conditional mount logic.
```

- [ ] **Step 4: Run tests**

Run: `bash tests/run-all.sh 2>&1 | tail -5`
Expected: `All 2 test suite(s) passed.`

- [ ] **Step 5: Verify the compose file still parses**

Run: `docker compose -f share/claude-sandboxed/docker-compose.yml config >/dev/null 2>&1 && echo OK || echo FAIL`
Expected: `OK` (may need `WORKSPACE_DIR` and `SANDBOX_*` env vars set; if it fails on interpolation, set them: `WORKSPACE_DIR=/tmp SANDBOX_UID=1000 SANDBOX_GID=1000 SANDBOX_USERNAME=test SANDBOX_HOME=/home/test docker compose -f share/claude-sandboxed/docker-compose.yml config >/dev/null && echo OK`)

### Task 7: Commit Unit 2

- [ ] **Step 1: Commit**

```bash
git add bin/claude-sandboxed share/claude-sandboxed/docker-compose.yml tests/config/test.sh
git commit -m "$(cat <<'EOF'
feat: add claude.config_passthrough config knob

Moves ~/.claude and ~/.claude.json mounts from docker-compose.yml into
the launcher as CLAUDE_VOLUME_ARGS, conditional on the new
claude.config_passthrough knob (default true). When false, neither
host path is mounted - useful with ANTHROPIC_API_KEY for a more
isolated environment.
EOF
)"
```

---

## Commit Unit 3: `git.policy` (file-based)

Adds `resolve_list` helper, policy file generation in the launcher, and policy file parsing in the wrapper.

### Task 8: Add `resolve_list` helper + tests

**Files:**
- Modify: `bin/claude-sandboxed` (add `resolve_list` function after `resolve`)
- Modify: `tests/config/test.sh` (add `resolve_list` tests)

- [ ] **Step 1: Add `resolve_list` function to `bin/claude-sandboxed`**

In `bin/claude-sandboxed`, after the `resolve()` function (which ends at line 37), add:

```bash

# Resolve a list knob. Returns newline-joined values from a YAML array.
# Env var (newline-separated) > workspace config > user config.
# Returns empty string if nothing set. Consults the *_VALID flags.
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

- [ ] **Step 2: Add `resolve_list` tests to `tests/config/test.sh`**

Append before the final Results lines:

```bash

# --- resolve_list tests ---

printf 'git:\n  policy:\n    allow:\n      - "^reset"\n      - "^commit --amend"\n    block:\n      - "^stash pop"\n' > "$TMPDIR/policy-workspace.yaml"
printf 'git:\n  policy:\n    allow:\n      - "^push"\n' > "$TMPDIR/policy-user.yaml"

# Test: resolve_list - env var (newline-separated) wins
SANDBOX_GIT_POLICY_ALLOW=$'^env1\n^env2'
WORKSPACE_CONFIG="$TMPDIR/policy-workspace.yaml"
USER_CONFIG="$TMPDIR/policy-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve_list SANDBOX_GIT_POLICY_ALLOW .git.policy.allow)
if [[ "$result" == $'^env1\n^env2' ]]; then
    ok "resolve_list: env var wins"
else
    bad "resolve_list: env var wins (got '$result')"
fi

# Test: resolve_list - workspace wins over user (no env)
unset SANDBOX_GIT_POLICY_ALLOW
WORKSPACE_CONFIG="$TMPDIR/policy-workspace.yaml"
USER_CONFIG="$TMPDIR/policy-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve_list SANDBOX_GIT_POLICY_ALLOW .git.policy.allow)
if [[ "$result" == $'^reset\n^commit --amend' ]]; then
    ok "resolve_list: workspace wins over user"
else
    bad "resolve_list: workspace wins over user (got '$result')"
fi

# Test: resolve_list - user fills gap when workspace absent
unset SANDBOX_GIT_POLICY_ALLOW
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/policy-user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve_list SANDBOX_GIT_POLICY_ALLOW .git.policy.allow)
if [[ "$result" == "^push" ]]; then
    ok "resolve_list: user fills gap"
else
    bad "resolve_list: user fills gap (got '$result')"
fi

# Test: resolve_list - empty when nothing set
unset SANDBOX_GIT_POLICY_ALLOW
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
result=$(resolve_list SANDBOX_GIT_POLICY_ALLOW .git.policy.allow)
if [[ -z "$result" ]]; then
    ok "resolve_list: empty when nothing set"
else
    bad "resolve_list: empty when nothing set (got '$result')"
fi

# Test: resolve_list - missing key in valid file returns empty
printf 'git: {}\n' > "$TMPDIR/no-policy.yaml"
unset SANDBOX_GIT_POLICY_ALLOW
WORKSPACE_CONFIG="$TMPDIR/no-policy.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=false
result=$(resolve_list SANDBOX_GIT_POLICY_ALLOW .git.policy.allow)
if [[ -z "$result" ]]; then
    ok "resolve_list: missing key returns empty"
else
    bad "resolve_list: missing key returns empty (got '$result')"
fi

# Test: resolve_list - block list from workspace
unset SANDBOX_GIT_POLICY_BLOCK
WORKSPACE_CONFIG="$TMPDIR/policy-workspace.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=false
result=$(resolve_list SANDBOX_GIT_POLICY_BLOCK .git.policy.block)
if [[ "$result" == "^stash pop" ]]; then
    ok "resolve_list: block list from workspace"
else
    bad "resolve_list: block list from workspace (got '$result')"
fi
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `bash tests/config/test.sh 2>&1 | tail -15`
Expected: All new `resolve_list` tests PASS.

### Task 9: Add policy file generation + mount in the launcher

**Files:**
- Modify: `bin/claude-sandboxed` (add resolve_list calls, policy file generation, GIT_POLICY_VOLUME_ARGS, splice into compose run)

- [ ] **Step 1: Add policy resolution + file generation**

In `bin/claude-sandboxed`, after the `GIT_ENV_ARGS` block (which ends around line 121), add:

```bash

# Git operation policy: user-defined allow/block regex lists that patch the
# default wrapper policy. Passed into the container as a generated file
# mounted at /etc/claude-sandboxed/git-policy.conf.
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

- [ ] **Step 2: Splice `GIT_POLICY_VOLUME_ARGS` into the `docker compose run` call**

Find the `docker compose run` call. Add `"${GIT_POLICY_VOLUME_ARGS[@]}" \` after `"${CLAUDE_VOLUME_ARGS[@]}" \`:

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

- [ ] **Step 3: Run tests**

Run: `bash tests/run-all.sh 2>&1 | tail -5`
Expected: `All 2 test suite(s) passed.`

### Task 10: Add policy file parsing to the wrapper

**Files:**
- Modify: `share/claude-sandboxed/git-wrapper` (add policy parsing before the default case statement)
- Modify: `tests/git-wrapper/test.sh` (add policy file tests)

- [ ] **Step 1: Add policy file tests to `tests/git-wrapper/test.sh`**

In `tests/git-wrapper/test.sh`, the existing `assert_blocked` and `assert_allowed` helpers use `REAL_GIT="$STUB_DIR/git"`. For policy tests, we need to also set `GIT_POLICY_FILE`. Add these tests before the final `echo "Results:..."` line:

```bash

# --- Git policy file tests ---

POLICY_TMP="$(mktemp)"

# Helper: run wrapper with a policy file set.
assert_blocked_with_policy() {
    local desc="$1"; shift
    local policy_content="$1"; shift
    printf '%s' "$policy_content" > "$POLICY_TMP"
    rm -f "$STUB_DIR/called"
    local err code
    err="$(REAL_GIT="$STUB_DIR/git" GIT_POLICY_FILE="$POLICY_TMP" "$WRAPPER" "$@" 2>&1 >/dev/null)" && code=0 || code=$?
    if [[ $code -ne 1 || "$err" != *"[SECURITY]"* ]]; then
        echo "FAIL: $desc (expected block, got code=$code err='$err')"
        fail=$((fail+1)); return
    fi
    echo "PASS: $desc"
    pass=$((pass+1))
}

assert_allowed_with_policy() {
    local desc="$1"; shift
    local policy_content="$1"; shift
    printf '%s' "$policy_content" > "$POLICY_TMP"
    rm -f "$STUB_DIR/called"
    REAL_GIT="$STUB_DIR/git" GIT_POLICY_FILE="$POLICY_TMP" "$WRAPPER" "$@" >/dev/null 2>&1
    local code=$?
    if [[ $code -ne 0 || ! -f "$STUB_DIR/called" ]]; then
        echo "FAIL: $desc (expected allow, got code=$code)"
        fail=$((fail+1)); return
    fi
    echo "PASS: $desc"
    pass=$((pass+1))
}

# Test: allow rule unblocks a default-blocked command
assert_allowed_with_policy "policy allow unblocks git reset --hard" \
    '[allow]
^reset' reset --hard HEAD~1

# Test: allow rule unblocks git commit --amend
assert_allowed_with_policy "policy allow unblocks git commit --amend" \
    '[allow]
^commit --amend' commit --amend

# Test: block rule blocks an allowed command
assert_blocked_with_policy "policy block blocks git stash pop" \
    '[block]
^stash pop' stash pop

# Test: allow rule for one command doesn't affect unrelated blocked commands
assert_blocked_with_policy "policy allow ^reset does not unblock git push" \
    '[allow]
^reset' push

# Test: block rule doesn't affect unrelated allowed commands
assert_allowed_with_policy "policy block ^stash pop does not block git status" \
    '[block]
^stash pop' status

# Test: comments and empty lines in policy file are skipped
assert_allowed_with_policy "policy file with comments and empty lines" \
    '[allow]
# this is a comment

^reset

# another comment' reset --hard

# Test: no policy file means default behavior (push still blocked)
rm -f "$STUB_DIR/called"
REAL_GIT="$STUB_DIR/git" "$WRAPPER" push >/dev/null 2>&1
code=$?
if [[ $code -eq 1 && ! -f "$STUB_DIR/called" ]]; then
    echo "PASS: no policy file - default blocks still apply"
    pass=$((pass+1))
else
    echo "FAIL: no policy file - default blocks still apply (code=$code)"
    fail=$((fail+1))
fi

rm -f "$POLICY_TMP"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/git-wrapper/test.sh 2>&1 | tail -15`
Expected: New policy tests FAIL (the wrapper doesn't read `GIT_POLICY_FILE` yet).

- [ ] **Step 3: Add policy file parsing to `share/claude-sandboxed/git-wrapper`**

In `share/claude-sandboxed/git-wrapper`, find the line `# --- Policy checks ---` (around line 53). Insert the following block BEFORE that line (after the `block()` helper definition):

```bash

# --- User policy file (patches the default policy) ---
# Format: [allow] and [block] section headers, one regex per line.
# Lines starting with # or empty are skipped. Regex is ERE, matched
# against "subcommand args..." (global flags stripped). Substring match
# by default; use ^ and $ to anchor.
POLICY_FILE="${GIT_POLICY_FILE:-/etc/claude-sandboxed/git-policy.conf}"
if [[ -f "$POLICY_FILE" ]]; then
    # Build command string for regex matching.
    cmd_args="$subcommand"
    for ((j=subcommand_idx+1; j<=$#; j++)); do
        cmd_args="$cmd_args ${!j}"
    done
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

```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/git-wrapper/test.sh 2>&1 | tail -15`
Expected: All policy tests PASS, plus existing tests still pass.

- [ ] **Step 5: Run full test suite**

Run: `bash tests/run-all.sh 2>&1 | tail -5`
Expected: `All 2 test suite(s) passed.`

### Task 11: Commit Unit 3

- [ ] **Step 1: Commit**

```bash
git add bin/claude-sandboxed share/claude-sandboxed/git-wrapper tests/config/test.sh tests/git-wrapper/test.sh
git commit -m "$(cat <<'EOF'
feat: add git.policy config knob with regex allow/block lists

git.policy.allow and git.policy.block are regex lists (ERE) that patch
the default wrapper policy: allow rules override default blocks, block
rules add to them. The launcher resolves the lists from config, writes
them to a temp file in [allow]/[block] section format, and mounts it
into the container at /etc/claude-sandboxed/git-policy.conf. The
wrapper parses the file and applies user rules before the default
policy. Users can cat the file inside the container to debug.

Also adds resolve_list helper for YAML array resolution.
EOF
)"
```

---

## Commit Unit 4: Docs + config.example.yaml

### Task 12: Update `config.example.yaml`

**Files:**
- Modify: `share/claude-sandboxed/config.example.yaml`

- [ ] **Step 1: Rewrite `config.example.yaml` with all new sections**

Replace the entire contents of `share/claude-sandboxed/config.example.yaml` with:

```yaml
# claude-sandboxed configuration file
#
# Copy this file to one of these locations:
#   ${XDG_CONFIG_HOME:-~/.config}/claude-sandboxed/config.yaml   (user defaults)
#   $WORKSPACE_DIR/.claude-sandboxed.yaml                         (per-project override)
#
# All fields are optional. Uncomment and edit the values you want to change.
# Precedence per knob: env var > workspace config > user config > built-in default.

claude:
  # Claude Code version to run inside the container.
  # Default: host's claude version (from `claude --version`).
  # version: "2.1.152"

  # When false, host ~/.claude and ~/.claude.json are not mounted into
  # the container. Useful with ANTHROPIC_API_KEY for a more isolated
  # environment. Default: true.
  # config_passthrough: true

sandbox:
  # uid: 1000          # default: $(id -u)
  # gid: 1000          # default: $(id -g)
  # username: ryey     # default: $(id -un)
  # home: /home/ryey   # default: /home/$username

  # When false, the cleanup container that removes empty stub dirs
  # does not run. Stubs are harmless; this only saves one quick
  # container startup. Default: true.
  # cleanup: true

git:
  # Identity overrides applied via GIT_AUTHOR_NAME / GIT_COMMITTER_NAME /
  # GIT_AUTHOR_EMAIL / GIT_COMMITTER_EMAIL env vars inside the container.
  # When unset, git uses whatever user.name / user.email it finds in the
  # container (from host_config_passthrough or git's defaults).
  #
  # Note: `git config user.name` (the command) ignores these env vars - it
  # reads config files only. Commits are still authored correctly; only
  # introspection via `git config` is affected. `git var GIT_AUTHOR_IDENT`
  # is the one command that does respect the env vars.
  identity:
    # name: claude-bot
    # email: bot@example.com
  # When false, host ~/.gitconfig and ~/.config/git/ are not mounted into
  # the container. Default: true (preserves host git identity inheritance).
  # host_config_passthrough: true

  # User-defined git operation policy. Regex patterns (ERE) matched against
  # the git subcommand + args (global flags like -C are stripped first).
  # Substring match by default; use ^ and $ to anchor.
  #
  # allow: overrides the default block list below. If a pattern matches,
  #        the command runs even if the default would block it.
  # block: adds to the default block list. If a pattern matches, the
  #        command is blocked even if the default allows it.
  #
  # The effective policy can be inspected inside the container:
  #   cat /etc/claude-sandboxed/git-policy.conf
  #
  # Default policy (built-in, for reference):
  #   Fully blocked subcommands:
  #     push, reset, rebase, filter-branch, filter-repo, clean, config
  #   Conditionally blocked (sub-subcommand or flag):
  #     reflog expire|delete
  #     notes remove|prune
  #     worktree remove|prune
  #     stash drop|clear
  #     branch -d|-D|--delete
  #     tag -d|--delete|-f|--force
  #     commit --amend|--reset-author
  #     checkout -B|-f|--force|-- <pathspec>
  #     switch -C|--discard-changes
  #     restore --worktree|-W
  #     rm (without --cached)
  #     gc --prune
  #   Everything else is allowed.
  policy:
    allow:
      # - "^reset"           # allow all reset forms (--hard, --soft, etc.)
      # - "^commit --amend"  # allow amend
    block:
      # - "^stash pop"       # example: block stash pop
```

### Task 13: Update `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the schema block in the Configuration section**

Find the schema block in the Configuration section (around line 82-94) and replace it with:

```yaml
claude:
  version: "2.1.152"            # string,  default: host's claude version
  config_passthrough: true      # bool,    default: true

sandbox:
  uid: 1000          # integer, default: $(id -u)
  gid: 1000          # integer, default: $(id -g)
  username: ryey     # string,  default: $(id -un)
  home: /home/ryey   # string,  default: /home/$username
  cleanup: true      # bool,    default: true

git:
  identity:
    name: claude-bot     # string,  default: "" (not set - inherit)
    email: bot@example.com  # string,  default: "" (not set)
  host_config_passthrough: true  # bool, default: true
  policy:
    allow:              # list of regex (ERE), default: empty
      - "^reset"
      - "^commit --amend"
    block:              # list of regex (ERE), default: empty
      - "^stash pop"
```

- [ ] **Step 2: Add new subsections under Customization**

After the existing "Git identity" subsection (which ends around line 152), add these new subsections:

```markdown
### Claude version

Pin a specific Claude Code version via config instead of the `CLAUDE_VERSION` env var:

```yaml
claude:
  version: "2.1.152"
```

Same precedence as other knobs: env var > workspace config > user config > host's installed version.

### Claude config passthrough

By default, the host's `~/.claude` directory and `~/.claude.json` are mounted into the container so Claude Code has credentials, skills, and settings. Disable this for a more isolated environment:

```yaml
claude:
  config_passthrough: false
```

When disabled, Claude Code runs without host credentials. Set `ANTHROPIC_API_KEY` in your environment to authenticate without `~/.claude`. This is useful for running Claude with a clean slate - no host skills, no host settings, no host session history.

### Cleanup

The launcher runs a small `cleanup` container after the main container exits to remove empty stub directories Docker may have created inside the `claude-agent-home` volume. Disable it to skip that one quick container startup:

```yaml
sandbox:
  cleanup: false
```

Stubs are harmless (empty dirs); this is a minor optimization.

### Git policy

The built-in git operation policy (see [Git policy](#git-policy) below) blocks destructive git operations. Customize it with regex-based allow/block lists that patch the default:

```yaml
git:
  policy:
    allow:
      - "^reset"           # allow all reset forms (--hard, --soft, etc.)
      - "^commit --amend"  # allow amend
    block:
      - "^stash pop"       # block stash pop (example)
```

Patterns are extended regex (ERE), matched against the git subcommand + args (global flags like `-C` are stripped first). Substring match by default; use `^` and `$` to anchor.

**Precedence** (first match wins):

1. User `allow` rules - if a pattern matches, the command runs even if the default would block it.
2. User `block` rules - if a pattern matches, the command is blocked even if the default allows it.
3. Built-in default policy (see list below).
4. Allowed (exec real git).

To inspect the effective policy inside the container:

```sh
cat /etc/claude-sandboxed/git-policy.conf
```

The file is only present when `git.policy` is set. When neither `allow` nor `block` is configured, the wrapper uses the built-in default policy directly.
```

- [ ] **Step 3: Update the Features checklist**

Find the Features section and update the Customization sub-items. The `Git config` item is already checked. Add a new checked item for `Git policy`:

Change:
```markdown
    - [ ] Git operation policy
```
to:
```markdown
    - [x] **Git policy** - regex-based allow/block lists (`git.policy.allow` / `git.policy.block`) that patch the default wrapper policy
```

And add new checked items for the other new knobs under the existing `Git config` line:

```markdown
    - [x] **Claude version** - pin Claude Code version via `claude.version`
    - [x] **Claude config passthrough** - toggle `~/.claude` mount via `claude.config_passthrough`
    - [x] **Cleanup** - toggle cleanup container via `sandbox.cleanup`
```

Place these right after the `Git config` checked item.

### Task 14: Update `docs/development.md`

**Files:**
- Modify: `docs/development.md`

- [ ] **Step 1: Update the Config resolution section**

Find the "Config resolution" section (around line 27). Update the knob list paragraph to include the new knobs:

Replace:
```markdown
Identity knobs (`SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USERNAME`, `SANDBOX_HOME`) and git knobs (`SANDBOX_GIT_IDENTITY_NAME`, `SANDBOX_GIT_IDENTITY_EMAIL`, `SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH`) are resolved per-knob from four sources in priority order:
```
with:
```markdown
Identity knobs (`SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USERNAME`, `SANDBOX_HOME`), git knobs (`SANDBOX_GIT_IDENTITY_NAME`, `SANDBOX_GIT_IDENTITY_EMAIL`, `SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH`), and the new knobs (`CLAUDE_VERSION`, `CLAUDE_CONFIG_PASSTHROUGH`, `SANDBOX_CLEANUP`, `SANDBOX_GIT_POLICY_ALLOW`, `SANDBOX_GIT_POLICY_BLOCK`) are resolved per-knob from four sources in priority order:
```

Update the "Default" line (item 4) to mention the new defaults:

Replace:
```markdown
4. **Default** - identity knobs: `$(id -u)`, `$(id -g)`, `$(id -un)`, `/home/$SANDBOX_USERNAME`. Git knobs: `""`, `""`, `true`.
```
with:
```markdown
4. **Default** - identity knobs: `$(id -u)`, `$(id -g)`, `$(id -un)`, `/home/$SANDBOX_USERNAME`. Git identity knobs: `""`, `""`. `SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH`: `true`. `CLAUDE_VERSION`: host's claude version. `CLAUDE_CONFIG_PASSTHROUGH`: `true`. `SANDBOX_CLEANUP`: `true`. `SANDBOX_GIT_POLICY_ALLOW` / `SANDBOX_GIT_POLICY_BLOCK`: empty.
```

- [ ] **Step 2: Add `resolve_list` to the function descriptions**

After the `resolve` description (around line 37), add:

```markdown
- `resolve_list ENV_NAME YQ_PATH` - like `resolve` but for YAML arrays. Returns newline-joined values. Used for `git.policy.allow` and `git.policy.block`. No default parameter (empty if nothing set).
```

- [ ] **Step 3: Update the invariants**

Find the invariants section. Add new invariants after the existing `SANDBOX_GIT_*` invariant (around line 19):

```markdown
- `CLAUDE_VERSION`, `CLAUDE_CONFIG_PASSTHROUGH`, `SANDBOX_CLEANUP`, `SANDBOX_GIT_POLICY_ALLOW`, and `SANDBOX_GIT_POLICY_BLOCK` are launcher-side only - they are NOT exported and NOT interpolated by the compose file. The launcher reads them to build `-e` and `-v` flags for `docker compose run`.
- The `~/.claude` and `~/.claude.json` mounts are in the launcher (`CLAUDE_VOLUME_ARGS`), not in `docker-compose.yml`. The compose file must not mount these paths.
- The `GIT_POLICY_FILE` path (`/etc/claude-sandboxed/git-policy.conf`) is the contract between the launcher and the wrapper. Changing it requires updating both.
- `resolve_list` must remain defined outside the main guard (for testability), same as `check_config` and `resolve`.
- The policy file cleanup trap (`trap 'rm -f "$POLICY_FILE"' EXIT`) must remain. Without it, temp policy files leak in `/tmp`.
```

- [ ] **Step 4: Add manual test checklist items 14-20**

Find the manual testing checklist (ends around item 13). Add:

```markdown
14. **Claude version:** with `claude.version: "2.1.152"` in workspace config, the container runs that version (verify with `claude --version` inside).
15. **Claude config passthrough off:** with `claude.config_passthrough: false`, `~/.claude` is not mounted. `ls ~/.claude` inside the container shows nothing (or the volume's empty dir). Claude starts with `ANTHROPIC_API_KEY` set.
16. **Cleanup off:** with `sandbox.cleanup: false`, no `cleanup` container runs after exit. Stub dirs may remain in the volume (harmless).
17. **Git policy allow:** with `git.policy.allow: ["^reset"]`, `git reset --hard HEAD~1` works inside the container.
18. **Git policy block:** with `git.policy.block: ["^stash pop"]`, `git stash pop` is blocked with a "[SECURITY]" message.
19. **Git policy file:** `cat /etc/claude-sandboxed/git-policy.conf` inside the container shows the effective policy.
20. **Git policy doesn't affect unmatched commands:** with `git.policy.allow: ["^reset"]`, `git push` is still blocked.
```

- [ ] **Step 5: Update the "Current test suites" list**

Find the "Current test suites" section (around line 85). The existing descriptions are accurate; no change needed (the new test cases are added to existing suites, not new suites).

### Task 15: Commit Unit 4

- [ ] **Step 1: Commit**

```bash
git add share/claude-sandboxed/config.example.yaml README.md docs/development.md
git commit -m "$(cat <<'EOF'
docs: document new config knobs (claude.version, passthrough, cleanup, git.policy)

Updates config.example.yaml with all new sections including the full
default git policy as a reference block. README gets new subsections
for each knob. development.md gets updated invariants, config
resolution details, and manual test checklist items 14-20.
EOF
)"
```

---

## Final verification

- [ ] **Step 1: Run full test suite**

Run: `bash tests/run-all.sh`
Expected: `All 2 test suite(s) passed.` with all individual tests passing.

- [ ] **Step 2: Verify the launcher parses**

Run: `bash -n bin/claude-sandboxed && echo OK`
Expected: `OK` (no syntax errors).

- [ ] **Step 3: Verify the wrapper parses**

Run: `bash -n share/claude-sandboxed/git-wrapper && echo OK`
Expected: `OK`.

- [ ] **Step 4: Verify config.example.yaml is valid YAML**

Run: `yq '.' share/claude-sandboxed/config.example.yaml >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 5: Check git log**

Run: `git log --oneline -6`
Expected: 4 new commits (one per commit unit) on top of the spec commit.
