# Git Identity and Host-Config Passthrough Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `git.identity.name` / `git.identity.email` and `git.host_config_passthrough` config knobs so users can override commit identity inside the sandbox and optionally stop mounting host git config files.

**Architecture:** Identity is applied via `GIT_AUTHOR_NAME` / `GIT_COMMITTER_NAME` / `GIT_AUTHOR_EMAIL` / `GIT_COMMITTER_EMAIL` env vars passed to `docker compose run` with `-e` flags. Passthrough wraps the existing `~/.gitconfig` and `~/.config/git/` bind-mount logic in a boolean guard. Both knobs follow the existing env > workspace > user > default precedence via the path-agnostic `resolve()` helper - no new functions needed.

**Tech Stack:** Bash (launcher), YAML (config), `yq` (config parsing, host-only dependency), Docker Compose (runtime).

**Spec:** `docs/superpowers/specs/2026-07-23-git-identity-config-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `bin/claude-sandboxed` | Launcher. Adds three `resolve()` calls for git knobs (no `export`), wraps `GIT_VOLUME_ARGS` in passthrough guard, adds `GIT_ENV_ARGS` block, splices into `docker compose run`. |
| `tests/config/test.sh` | Extends with `resolve()` characterization cases for the three new yq paths. No new helpers. |
| `share/claude-sandboxed/config.example.yaml` | Adds commented-out `git:` section. |
| `README.md` | Schema section gains `git:` block, new "Git identity" subsection, Features checklist updated. |
| `docs/development.md` | Config resolution knob list extended, invariant note about launcher-side vars, manual test checklist items 10-13. |

Files NOT modified: `share/claude-sandboxed/docker-compose.yml`, `share/claude-sandboxed/git-wrapper`, `install.sh`, `packaging/PKGBUILD`, `CLAUDE.md`.

---

## Task 1: Characterization tests for `resolve()` with new git config paths

**Goal:** Add `resolve()` test cases for `.git.identity.name`, `.git.identity.email`, `.git.host_config_passthrough`. These pass immediately because `resolve()` is path-agnostic, but they lock in expected behavior and catch regressions.

**Note on TDD:** The `resolve()` function already handles any yq path. These tests are characterization tests, not classic TDD - there is no red phase. They pass on the first run. Their value is regression protection and documenting expected behavior for the new knobs.

**Files:**
- Modify: `tests/config/test.sh`

- [ ] **Step 1: Read the current test file to confirm the insertion point**

Run: `cat -n tests/config/test.sh`

Expected: see the existing `resolve` test block starting around line 75, ending around line 174 with the "empty string value" test. The final `echo ""` + `Results:` block is at lines 176-178.

- [ ] **Step 2: Add new test cases before the final `echo ""` line**

Insert this block immediately before the `echo ""` line (currently line 176):

```bash

# --- resolve tests for git config paths ---

# Setup: create config files with git sections for the new tests
printf 'git:\n  identity:\n    name: workspace-name\n    email: workspace@example.com\n  host_config_passthrough: false\n' > "$TMPDIR/git-workspace.yaml"
printf 'git:\n  identity:\n    name: user-name\n    email: user@example.com\n  host_config_passthrough: true\n' > "$TMPDIR/git-user.yaml"

# Test: git.identity.name - env var wins
SANDBOX_GIT_IDENTITY_NAME=env-name
WORKSPACE_CONFIG="$TMPDIR/git-workspace.yaml"
USER_CONFIG="$TMPDIR/git-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_GIT_IDENTITY_NAME .git.identity.name "")
if [[ "$result" == "env-name" ]]; then
    ok "resolve: git.identity.name env var wins"
else
    bad "resolve: git.identity.name env var wins (got '$result')"
fi

# Test: git.identity.name - workspace wins over user (no env)
unset SANDBOX_GIT_IDENTITY_NAME
WORKSPACE_CONFIG="$TMPDIR/git-workspace.yaml"
USER_CONFIG="$TMPDIR/git-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_GIT_IDENTITY_NAME .git.identity.name "")
if [[ "$result" == "workspace-name" ]]; then
    ok "resolve: git.identity.name workspace wins over user"
else
    bad "resolve: git.identity.name workspace wins over user (got '$result')"
fi

# Test: git.identity.name - user fills gap when workspace absent
unset SANDBOX_GIT_IDENTITY_NAME
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/git-user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_GIT_IDENTITY_NAME .git.identity.name "")
if [[ "$result" == "user-name" ]]; then
    ok "resolve: git.identity.name user fills gap when workspace absent"
else
    bad "resolve: git.identity.name user fills gap (got '$result')"
fi

# Test: git.identity.name - empty default when nothing set
unset SANDBOX_GIT_IDENTITY_NAME
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
result=$(resolve SANDBOX_GIT_IDENTITY_NAME .git.identity.name "")
if [[ "$result" == "" ]]; then
    ok "resolve: git.identity.name empty default when nothing set"
else
    bad "resolve: git.identity.name empty default (got '$result')"
fi

# Test: git.identity.email - workspace value via yq path
unset SANDBOX_GIT_IDENTITY_EMAIL
WORKSPACE_CONFIG="$TMPDIR/git-workspace.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=false
result=$(resolve SANDBOX_GIT_IDENTITY_EMAIL .git.identity.email "")
if [[ "$result" == "workspace@example.com" ]]; then
    ok "resolve: git.identity.email workspace value"
else
    bad "resolve: git.identity.email workspace value (got '$result')"
fi

# Test: git.host_config_passthrough - default is "true"
unset SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/nonexistent.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
result=$(resolve SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH .git.host_config_passthrough true)
if [[ "$result" == "true" ]]; then
    ok "resolve: git.host_config_passthrough default true"
else
    bad "resolve: git.host_config_passthrough default (got '$result')"
fi

# Test: git.host_config_passthrough - env var "false" wins
SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH=false
WORKSPACE_CONFIG="$TMPDIR/git-workspace.yaml"
USER_CONFIG="$TMPDIR/git-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH .git.host_config_passthrough true)
if [[ "$result" == "false" ]]; then
    ok "resolve: git.host_config_passthrough env var false wins"
else
    bad "resolve: git.host_config_passthrough env false (got '$result')"
fi

# Test: git.host_config_passthrough - workspace "false" when no env
unset SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH
WORKSPACE_CONFIG="$TMPDIR/git-workspace.yaml"
USER_CONFIG="$TMPDIR/git-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH .git.host_config_passthrough true)
if [[ "$result" == "false" ]]; then
    ok "resolve: git.host_config_passthrough workspace false (no env)"
else
    bad "resolve: git.host_config_passthrough workspace false (got '$result')"
fi

# Test: git.host_config_passthrough - user "true" wins over default when workspace absent
unset SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH
WORKSPACE_CONFIG="$TMPDIR/nonexistent.yaml"
USER_CONFIG="$TMPDIR/git-user.yaml"
WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=true
result=$(resolve SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH .git.host_config_passthrough false)
if [[ "$result" == "true" ]]; then
    ok "resolve: git.host_config_passthrough user true beats false default"
else
    bad "resolve: git.host_config_passthrough user true (got '$result')"
fi
```

- [ ] **Step 3: Run the test suite to verify all tests pass**

Run: `bash tests/config/test.sh`

Expected: output ends with `Results: N passed, 0 failed` where N is the previous count plus 9 new passes. Exit code 0.

- [ ] **Step 4: Run the full test suite to confirm nothing else broke**

Run: `bash tests/run-all.sh`

Expected: `All N test suite(s) passed.`

- [ ] **Step 5: Commit**

```bash
git add tests/config/test.sh
git commit -m "test: add resolve() cases for git identity and passthrough knobs"
```

---

## Task 2: Add config resolution, conditional mount, and env-var injection to launcher

**Goal:** Wire the three new knobs into `bin/claude-sandboxed`: resolve them from config, gate the host git-config mount on passthrough, and inject identity env vars into `docker compose run`.

**Files:**
- Modify: `bin/claude-sandboxed`

- [ ] **Step 1: Read the current launcher to confirm line numbers**

Run: `cat -n bin/claude-sandboxed`

Expected: identity resolution at lines 69-72, `GIT_VOLUME_ARGS` block at lines 91-97, `docker compose run` at lines 101-105.

- [ ] **Step 2: Add three `resolve()` calls after the existing identity resolution**

In `bin/claude-sandboxed`, find this block (around lines 69-72):

```bash
export SANDBOX_UID="$(resolve SANDBOX_UID .sandbox.uid "$(id -u)")"
export SANDBOX_GID="$(resolve SANDBOX_GID .sandbox.gid "$(id -g)")"
export SANDBOX_USERNAME="$(resolve SANDBOX_USERNAME .sandbox.username "$(id -un)")"
export SANDBOX_HOME="$(resolve SANDBOX_HOME .sandbox.home "/home/$SANDBOX_USERNAME")"
```

Immediately after it, insert:

```bash

# Git identity and host-config passthrough.
# Not exported: these are consumed only by this launcher to build -e / -v flags
# for `docker compose run`. The compose file does not interpolate them, so they
# do NOT belong on the "must be exported" invariant list in docs/development.md.
SANDBOX_GIT_IDENTITY_NAME="$(resolve SANDBOX_GIT_IDENTITY_NAME .git.identity.name "")"
SANDBOX_GIT_IDENTITY_EMAIL="$(resolve SANDBOX_GIT_IDENTITY_EMAIL .git.identity.email "")"
SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH="$(resolve SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH .git.host_config_passthrough true)"
```

- [ ] **Step 3: Wrap `GIT_VOLUME_ARGS` in passthrough guard**

Find this block (around lines 88-97):

```bash
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
```

Replace it with:

```bash
# Git config inheritance: bind-mount host ~/.gitconfig and ~/.config/git/
# read-only when they exist AND host_config_passthrough is true, so Claude
# uses the host user's git identity. Conditional mounting avoids Docker
# creating empty stub dirs on the host.
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

- [ ] **Step 4: Add `GIT_ENV_ARGS` block before the `docker compose run` call**

Find this block (around lines 99-105):

```bash
# Run Claude in a one-shot container that is removed automatically on exit.
# Each invocation gets its own container; named volumes (claude-agent-home) persist across runs.
docker compose -p "$COMPOSE_PROJECT" -f "$SANDBOX_COMPOSE_DIR/docker-compose.yml" run \
  --rm \
  -e HOME="${SANDBOX_HOME}" \
  "${GIT_VOLUME_ARGS[@]}" \
  -it ai-agent npx --yes "$CLAUDE_PACKAGE" --dangerously-skip-permissions
```

Replace it with:

```bash
# Git identity overrides: passed as -e flags so they only appear when set.
# Listing them in docker-compose.yml environment: would leak host GIT_AUTHOR_*
# into the container when config doesn't set them - the opposite of what we want.
GIT_ENV_ARGS=()
if [[ -n "$SANDBOX_GIT_IDENTITY_NAME" ]]; then
    GIT_ENV_ARGS+=(-e GIT_AUTHOR_NAME="$SANDBOX_GIT_IDENTITY_NAME")
    GIT_ENV_ARGS+=(-e GIT_COMMITTER_NAME="$SANDBOX_GIT_IDENTITY_NAME")
fi
if [[ -n "$SANDBOX_GIT_IDENTITY_EMAIL" ]]; then
    GIT_ENV_ARGS+=(-e GIT_AUTHOR_EMAIL="$SANDBOX_GIT_IDENTITY_EMAIL")
    GIT_ENV_ARGS+=(-e GIT_COMMITTER_EMAIL="$SANDBOX_GIT_IDENTITY_EMAIL")
fi

# Run Claude in a one-shot container that is removed automatically on exit.
# Each invocation gets its own container; named volumes (claude-agent-home) persist across runs.
docker compose -p "$COMPOSE_PROJECT" -f "$SANDBOX_COMPOSE_DIR/docker-compose.yml" run \
  --rm \
  -e HOME="${SANDBOX_HOME}" \
  "${GIT_ENV_ARGS[@]}" \
  "${GIT_VOLUME_ARGS[@]}" \
  -it ai-agent npx --yes "$CLAUDE_PACKAGE" --dangerously-skip-permissions
```

- [ ] **Step 5: Verify the launcher still parses**

Run: `bash -n bin/claude-sandboxed`

Expected: no output, exit code 0 (syntax check passes).

- [ ] **Step 6: Run the full test suite to confirm no regressions**

Run: `bash tests/run-all.sh`

Expected: `All N test suite(s) passed.`

- [ ] **Step 7: Commit**

```bash
git add bin/claude-sandboxed
git commit -m "feat: wire git identity and passthrough config into launcher"
```

---

## Task 3: Update `config.example.yaml` with `git:` section

**Goal:** Ship the commented-out template so users can copy and uncomment.

**Files:**
- Modify: `share/claude-sandboxed/config.example.yaml`

- [ ] **Step 1: Read the current example file**

Run: `cat share/claude-sandboxed/config.example.yaml`

Expected: see the existing `sandbox:` section with four commented-out identity knobs.

- [ ] **Step 2: Append the `git:` section**

After the existing `sandbox:` block, append:

```yaml

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
```

- [ ] **Step 3: Verify YAML still parses (when uncommented)**

Run:

```bash
# Strip comment markers and blank lines, then validate with yq.
sed -e 's/^# //' -e 's/^#//' share/claude-sandboxed/config.example.yaml | grep -v '^$' | yq '.' >/dev/null && echo OK
```

Expected: prints `OK`. (If `yq` is not installed, skip this step - the example file is all comments, so it cannot be malformed YAML.)

- [ ] **Step 4: Commit**

```bash
git add share/claude-sandboxed/config.example.yaml
git commit -m "feat: add git identity and passthrough to config example"
```

---

## Task 4: Update `README.md`

**Goal:** Document the new knobs in the schema, add a "Git identity" subsection, and check off the `Git config` TODO item in Features.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read the current README sections that need changes**

Run: `cat -n README.md`

Note the line numbers for:
- The schema block (around lines 82-88)
- The "### User identity" subsection (around line 104)
- The "### Git policy" subsection (around line 130)
- The Features checklist `Customization` section (around lines 175-180)

- [ ] **Step 2: Extend the schema block**

Find this block (around lines 82-88):

```yaml
sandbox:
  uid: 1000          # integer, default: $(id -u)
  gid: 1000          # integer, default: $(id -g)
  username: ryey     # string,  default: $(id -un)
  home: /home/ryey   # string,  default: /home/$username
```

Replace it with:

```yaml
sandbox:
  uid: 1000          # integer, default: $(id -u)
  gid: 1000          # integer, default: $(id -g)
  username: ryey     # string,  default: $(id -un)
  home: /home/ryey   # string,  default: /home/$username

git:
  identity:
    name: claude-bot     # string,  default: "" (not set - inherit)
    email: bot@example.com  # string,  default: "" (not set)
  host_config_passthrough: true  # bool, default: true
```

- [ ] **Step 3: Add a "Git identity" subsection after "### User identity"**

Find the end of the "### User identity" subsection. It ends with this line (around line 121):

```markdown
When `SANDBOX_UID=0`, the container runs as root and the user-creation step is skipped.
```

Immediately after it, insert:

```markdown

### Git identity

Two knobs control git identity inside the sandbox:

| Knob | Default | Description |
|---|---|---|
| `git.identity.name` | `""` (unset) | Overrides `user.name` via `GIT_AUTHOR_NAME` / `GIT_COMMITTER_NAME` env vars |
| `git.identity.email` | `""` (unset) | Overrides `user.email` via `GIT_AUTHOR_EMAIL` / `GIT_COMMITTER_EMAIL` env vars |
| `git.host_config_passthrough` | `true` | When `false`, host `~/.gitconfig` and `~/.config/git/` are not mounted |

Env var overrides: `SANDBOX_GIT_IDENTITY_NAME`, `SANDBOX_GIT_IDENTITY_EMAIL`, `SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH`. Same precedence as identity knobs: env > workspace config > user config > default.

**How identity is applied:** when `git.identity.name` is set, the launcher passes `-e GIT_AUTHOR_NAME=...` and `-e GIT_COMMITTER_NAME=...` to `docker compose run` (same for email). Git's env-var precedence is above any config file, so the override takes effect regardless of whether host `~/.gitconfig` is mounted.

**Combinations:**

| `identity` | `host_config_passthrough` | Behavior |
|---|---|---|
| unset | `true` (default) | Host git identity inherited via `~/.gitconfig` (current behavior). |
| unset | `false` | No git identity in sandbox. `git commit` fails with "Please tell me who you are". |
| set | `true` (default) | Host config mounted, commit authorship overridden by env vars. |
| set | `false` | Clean slate: only sandbox identity applies. |

**Caveat:** `git config user.name` (the command) only reads config files - it ignores the env vars. So when passthrough is on and identity is overridden, `git config user.name` still prints the host's value. Commits are still authored correctly. `git var GIT_AUTHOR_IDENT` is the one git command that does respect the env vars.
```

- [ ] **Step 4: Check off the `Git config` TODO in Features**

Find this block in the Features section (around lines 175-180):

```markdown
- [ ] **Customization** - set preferences through config files (with docs and examples)
    - [x] **Config foundation** - YAML config loading (`yq`), env > workspace > user > default precedence, identity knobs (`sandbox_uid`/`gid`/`username`/`home`)
    - [ ] All isolation designs should be customizable
    - [ ] Git operation policy
    - [ ] Git config
    - [ ] Additional paths
```

Replace the `    - [ ] Git config` line with:

```markdown
    - [x] **Git config** - per-sandbox identity override (`git.identity.name`/`email`) and host config passthrough toggle (`git.host_config_passthrough`)
```

- [ ] **Step 5: Verify the README still reads correctly**

Run: `cat README.md | head -200`

Expected: the schema block shows both `sandbox:` and `git:` sections; the "Git identity" subsection appears between "User identity" and "Git policy"; the Features checklist shows `Git config` checked.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: document git identity and passthrough config in README"
```

---

## Task 5: Update `docs/development.md`

**Goal:** Add the new knobs to the config resolution section, note the launcher-side vs compose-interpolated distinction, and add manual test checklist items.

**Files:**
- Modify: `docs/development.md`

- [ ] **Step 1: Read the current development.md sections that need changes**

Run: `cat -n docs/development.md`

Note the line numbers for:
- The "Config resolution" section (around lines 24-38)
- The invariants list (around lines 5-22)
- The manual testing checklist (around lines 56-66)

- [ ] **Step 2: Extend the config resolution knob list**

Find this paragraph (around line 26):

```markdown
Identity knobs (`SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USERNAME`, `SANDBOX_HOME`) are resolved per-knob from four sources in priority order:
```

Replace it with:

```markdown
Identity knobs (`SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USERNAME`, `SANDBOX_HOME`) and git knobs (`SANDBOX_GIT_IDENTITY_NAME`, `SANDBOX_GIT_IDENTITY_EMAIL`, `SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH`) are resolved per-knob from four sources in priority order:
```

Then find the numbered list that follows (around lines 28-31):

```markdown
1. **Env var** (`SANDBOX_UID`, etc.) - if set and non-empty.
2. **Workspace config** (`$WORKSPACE_DIR/.claude-sandboxed.yaml`) - if the key is present and non-null.
3. **User config** (`${XDG_CONFIG_HOME:-$HOME/.config}/claude-sandboxed/config.yaml`) - if the key is present and non-null.
4. **Default** (`$(id -u)`, `$(id -g)`, `$(id -un)`, `/home/$SANDBOX_USERNAME`).
```

Replace item 4 with:

```markdown
4. **Default** - identity knobs: `$(id -u)`, `$(id -g)`, `$(id -un)`, `/home/$SANDBOX_USERNAME`. Git knobs: `""`, `""`, `true`.
```

- [ ] **Step 3: Add a note about launcher-side vs compose-interpolated vars**

Find this invariant (around line 18):

```markdown
- `SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USERNAME`, and `SANDBOX_HOME` must be exported before `docker compose up` - the compose file interpolates them for volume paths and the user-creation entrypoint.
```

Immediately after it, insert:

```markdown
- `SANDBOX_GIT_IDENTITY_NAME`, `SANDBOX_GIT_IDENTITY_EMAIL`, and `SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH` are launcher-side only - they are NOT exported and NOT interpolated by the compose file. The launcher reads them to build `-e` and `-v` flags for `docker compose run`. Do not add them to the "must be exported" list above.
```

- [ ] **Step 4: Add manual test checklist items 10-13**

Find the end of the manual testing checklist. It currently ends with item 9 (around line 66):

```markdown
9. **Automated tests:** run `bash tests/run-all.sh` from the repo root - all test suites pass.
```

Immediately after it, insert:

```markdown
10. **Git identity override:** with `git.identity.name`/`email` set in workspace config, `git commit` inside the container uses the overridden identity. Verify: `git log -1 --format='%an <%ae>'` shows the configured name/email, not host's.
11. **Host passthrough off:** with `git.host_config_passthrough: false`, `/usr/bin/git config user.name` inside the container returns nothing (or git's compiled default), not host's value. `cat ~/.gitconfig` fails (file doesn't exist). Note: `git config` (without `/usr/bin/`) is blocked by the wrapper - use `/usr/bin/git` to introspect.
12. **Identity + passthrough off:** both `git.identity` set and `host_config_passthrough: false`. `git commit` inside the container uses the sandbox identity. `git log -1 --format='%an <%ae>'` shows the configured name/email.
13. **Identity + passthrough on (default):** `git.identity` set, `host_config_passthrough` unset (default true). `git commit` uses the env-var identity. `git config user.name` (via `/usr/bin/git`) still reports host's value (env vars don't affect `git config --get`).
```

- [ ] **Step 5: Commit**

```bash
git add docs/development.md
git commit -m "docs: add git config knobs and test checklist to development.md"
```

---

## Task 6: Final verification

**Goal:** Confirm the full test suite passes and the launcher syntax is clean. End-to-end Docker verification (items 10-13 in `docs/development.md`) is left for the user to run manually.

**Files:** none modified.

- [ ] **Step 1: Run the full automated test suite**

Run: `bash tests/run-all.sh`

Expected: `All N test suite(s) passed.` Exit code 0.

- [ ] **Step 2: Syntax-check the launcher**

Run: `bash -n bin/claude-sandboxed`

Expected: no output, exit code 0.

- [ ] **Step 3: Verify the launcher wires the new knobs using a `docker` stub**

This confirms the launcher's array-building logic produces the right `-e` and `-v` flags without starting a real container. The stub shadows `docker` on `PATH` and logs the args it receives.

```bash
TMPDIR_VERIFY="$(mktemp -d)"
mkdir -p "$TMPDIR_VERIFY/bin"
cat > "$TMPDIR_VERIFY/bin/docker" <<'STUB'
#!/bin/bash
# Log all args so we can inspect what the launcher passed.
echo "docker-stub called with: $*" >> "$DOCKER_STUB_LOG"
# Simulate `docker compose run` success so the launcher's `set -e` doesn't trip.
exit 0
STUB
chmod +x "$TMPDIR_VERIFY/bin/docker"

# Workspace with git identity override and passthrough off.
mkdir -p "$TMPDIR_VERIFY/ws"
cat > "$TMPDIR_VERIFY/ws/.claude-sandboxed.yaml" <<EOF
git:
  identity:
    name: verify-bot
    email: verify@example.com
  host_config_passthrough: false
EOF

DOCKER_STUB_LOG="$TMPDIR_VERIFY/call.log" \
  PATH="$TMPDIR_VERIFY/bin:$PATH" \
  /home/ryey/coding/claude-sandboxed/bin/claude-sandboxed "$TMPDIR_VERIFY/ws" \
  </dev/null >/dev/null 2>&1 || true

echo "--- docker stub received:"
cat "$TMPDIR_VERIFY/call.log"

# Assertions: identity env vars passed, no .gitconfig mount.
if grep -q -- '-e GIT_AUTHOR_NAME=verify-bot' "$TMPDIR_VERIFY/call.log" \
  && grep -q -- '-e GIT_COMMITTER_EMAIL=verify@example.com' "$TMPDIR_VERIFY/call.log" \
  && ! grep -q -- '\.gitconfig' "$TMPDIR_VERIFY/call.log"; then
  echo "PASS: launcher passes identity env vars and omits gitconfig mount"
else
  echo "FAIL: see $TMPDIR_VERIFY/call.log"
  exit 1
fi

rm -rf "$TMPDIR_VERIFY"
```

Expected: `PASS: launcher passes identity env vars and omits gitconfig mount`. The stub log shows `-e GIT_AUTHOR_NAME=verify-bot`, `-e GIT_COMMITTER_NAME=verify-bot`, `-e GIT_AUTHOR_EMAIL=verify@example.com`, `-e GIT_COMMITTER_EMAIL=verify@example.com`, and no `-v .../.gitconfig:...` argument.

- [ ] **Step 4: Report manual test items 10-13 as a follow-up**

Print this message to the user:

```
Automated tests pass. Manual Docker verification (items 10-13 in docs/development.md) is left for you to run when convenient. The tests require a working Docker setup and a test git repo.
```

No commit needed - this task is verification only.
