# Codex Tool Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add first-class Codex CLI support to `claude-sandboxed` while preserving every existing Claude invocation and leaving the package name unchanged.

**Architecture:** Keep one Bash launcher and extract sourceable argument-parsing and tool-profile functions. The generic launcher resolves identity, git policy, Compose, and cleanup once; the selected Claude or Codex profile supplies package, version, environment, config mounts, autonomy flags, and user arguments.

**Tech Stack:** Bash, `yq`, Docker Compose, npm/npx, existing shell test harness.

## Global Constraints

- Keep all package, executable, config, installation, Compose-project, service, and named-volume names unchanged.
- Support exactly the built-in `claude` and `codex` profiles; do not add arbitrary custom commands.
- Claude remains the default and its existing YAML and environment variables remain compatible.
- Tool precedence is CLI `--tool` > `SANDBOX_TOOL` > workspace `tool` > user `tool` > `claude`.
- Preserve argument boundaries after the first `--`.
- Keep the Docker image, network mode, identity behavior, git protections, and cleanup behavior unchanged.
- Keep `GIT_VOLUME_ARGS` and `GIT_POLICY_VOLUME_ARGS`; generalize only `CLAUDE_VOLUME_ARGS` to `TOOL_VOLUME_ARGS`.
- Keep tool-profile functions internal and sourceable for tests; they are not a public plugin API.
- Tests must not require Docker, network access, Claude, or Codex.

---

## File Structure

- Modify `bin/claude-sandboxed`: own CLI parsing, selection precedence, explicit tool profiles, and generic Compose command assembly.
- Create `tests/launcher/test.sh`: own source-level tests for parsing, selection, profiles, mounts, environment forwarding, versions, and argument ordering.
- Modify `tests/config/test.sh`: own scalar-resolution tests for the new YAML/environment keys.
- Modify `share/claude-sandboxed/docker-compose.yml`: retain only the generic `IS_SANDBOX` environment and update tool-neutral comments.
- Modify `share/claude-sandboxed/config.example.yaml`: document the optional selector and Codex settings.
- Modify `README.md`: document supported tools and public CLI/config behavior.
- Modify `docs/architecture.md`: document profile data flow, mount scopes, and tool-specific authentication.
- Modify `docs/development.md`: record new invariants, config resolution, tests, and manual checks.
- Modify `CLAUDE.md`: change only the one-line project description if it still describes a Claude-only launcher.

### Task 1: Parse Launcher Arguments and Resolve Tool Selection

**Files:**
- Modify: `bin/claude-sandboxed:5-74`
- Create: `tests/launcher/test.sh`

**Interfaces:**
- Consumes: existing `resolve ENV_NAME YQ_PATH DEFAULT`.
- Produces: `parse_launcher_args "$@"`, which sets global scalar `CLI_TOOL`, scalar `WORKSPACE_ARG`, and array `TOOL_USER_ARGS`; `resolve_tool CLI_OVERRIDE`, which prints `claude` or `codex` and rejects other values.

- [ ] **Step 1: Write failing parser and selection tests**

Create `tests/launcher/test.sh` with the existing suite style and these concrete assertions:

```bash
#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$SCRIPT_DIR/../../bin/claude-sandboxed"
# shellcheck source=/dev/null
source "$LAUNCHER"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then ok "$name"; else bad "$name (expected '$expected', got '$actual')"; fi
}

parse_launcher_args
assert_eq "parse: default workspace is empty sentinel" "" "$WORKSPACE_ARG"
assert_eq "parse: no CLI tool override" "" "$CLI_TOOL"
assert_eq "parse: no tool args" "0" "${#TOOL_USER_ARGS[@]}"

parse_launcher_args --tool codex "/tmp/project with spaces" -- --model "gpt-5.4" "prompt with spaces"
assert_eq "parse: tool" "codex" "$CLI_TOOL"
assert_eq "parse: workspace" "/tmp/project with spaces" "$WORKSPACE_ARG"
assert_eq "parse: passthrough count" "4" "${#TOOL_USER_ARGS[@]}"
assert_eq "parse: passthrough first" "--model" "${TOOL_USER_ARGS[0]}"
assert_eq "parse: passthrough spaced value" "prompt with spaces" "${TOOL_USER_ARGS[3]}"

if parse_launcher_args --tool >/dev/null 2>&1; then bad "parse: missing tool value"; else ok "parse: missing tool value"; fi
if parse_launcher_args --bogus >/dev/null 2>&1; then bad "parse: unsupported option"; else ok "parse: unsupported option"; fi
if parse_launcher_args one two >/dev/null 2>&1; then bad "parse: multiple workspaces"; else ok "parse: multiple workspaces"; fi

WORKSPACE_CONFIG_VALID=false
USER_CONFIG_VALID=false
unset SANDBOX_TOOL
assert_eq "select: default Claude" "claude" "$(resolve_tool "")"
SANDBOX_TOOL=codex
assert_eq "select: environment" "codex" "$(resolve_tool "")"
assert_eq "select: CLI beats environment" "claude" "$(resolve_tool claude)"
if resolve_tool unknown >/dev/null 2>&1; then bad "select: unknown tool"; else ok "select: unknown tool"; fi
unset SANDBOX_TOOL

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
```

- [ ] **Step 2: Run the launcher suite and verify the missing functions fail**

Run: `bash tests/launcher/test.sh`

Expected: non-zero exit with `parse_launcher_args: command not found`.

- [ ] **Step 3: Add sourceable parser and selector functions**

Add after `resolve_list` and before the main guard:

```bash
launcher_error() {
  echo "claude-sandboxed: $*" >&2
  return 2
}

parse_launcher_args() {
  CLI_TOOL=""
  WORKSPACE_ARG=""
  TOOL_USER_ARGS=()

  while (($#)); do
    case "$1" in
      --)
        shift
        TOOL_USER_ARGS=("$@")
        return 0
        ;;
      --tool)
        (($# >= 2)) || { launcher_error "--tool requires claude or codex"; return; }
        CLI_TOOL="$2"
        shift 2
        ;;
      -*)
        launcher_error "unsupported option before --: $1"
        return
        ;;
      *)
        [[ -z "$WORKSPACE_ARG" ]] || {
          launcher_error "expected at most one workspace before --"
          return
        }
        WORKSPACE_ARG="$1"
        shift
        ;;
    esac
  done
}

resolve_tool() {
  local cli_tool="$1" selected
  if [[ -n "$cli_tool" ]]; then
    selected="$cli_tool"
  else
    selected="$(resolve SANDBOX_TOOL .tool claude)"
  fi
  case "$selected" in
    claude|codex) echo "$selected" ;;
    *) launcher_error "unsupported tool '$selected'; supported tools: claude, codex" ;;
  esac
}
```

Preserve the existing `--version`/`-V` handling in main before calling `parse_launcher_args`.

- [ ] **Step 4: Extend selection tests to cover workspace and user YAML**

Append before the summary in `tests/launcher/test.sh`:

```bash
if command -v yq >/dev/null 2>&1; then
    LAUNCHER_TMP="$(mktemp -d)"
    trap 'rm -rf "$LAUNCHER_TMP"' EXIT
    printf 'tool: codex\n' > "$LAUNCHER_TMP/workspace.yaml"
    printf 'tool: claude\n' > "$LAUNCHER_TMP/user.yaml"
    WORKSPACE_CONFIG="$LAUNCHER_TMP/workspace.yaml"
    USER_CONFIG="$LAUNCHER_TMP/user.yaml"
    WORKSPACE_CONFIG_VALID=true
    USER_CONFIG_VALID=true
    assert_eq "select: workspace beats user" "codex" "$(resolve_tool "")"
    SANDBOX_TOOL=claude
    assert_eq "select: environment beats workspace" "claude" "$(resolve_tool "")"
    assert_eq "select: CLI beats all config" "codex" "$(resolve_tool codex)"
    unset SANDBOX_TOOL

    WORKSPACE_CONFIG_VALID=false
    assert_eq "select: user fills workspace gap" "claude" "$(resolve_tool "")"
fi
```

Move the final summary and `[[ $fail -eq 0 ]]` after this block.

- [ ] **Step 5: Run parser tests and all existing tests**

Run: `bash tests/launcher/test.sh && bash tests/run-all.sh`

Expected: launcher suite passes; config and git-wrapper suites remain green or config reports its existing `yq` skip.

- [ ] **Step 6: Commit the parser and selection seam**

```bash
git add bin/claude-sandboxed tests/launcher/test.sh
git commit -m "feat: parse tool selection and passthrough args"
```

### Task 2: Add Claude and Codex Profiles

**Files:**
- Modify: `bin/claude-sandboxed:56-197`
- Modify: `tests/launcher/test.sh`
- Modify: `tests/config/test.sh`

**Interfaces:**
- Consumes: `resolve`, selected tool name, `HOME`, `SANDBOX_HOME`, validated config globals, and optional host API-key variables.
- Produces: `detect_host_version COMMAND`; `configure_tool TOOL_NAME`, which populates `TOOL_PACKAGE`, array `TOOL_DEFAULT_ARGS`, array `TOOL_ENV_ARGS`, and array `TOOL_VOLUME_ARGS`.

- [ ] **Step 1: Add failing profile tests**

Add a reset helper and profile assertions before the launcher-suite summary:

```bash
reset_profile_context() {
    PROFILE_TMP="$(mktemp -d)"
    HOME="$PROFILE_TMP/host-home"
    SANDBOX_HOME="/home/tester"
    mkdir -p "$HOME/.claude" "$HOME/.codex"
    printf '{}\n' > "$HOME/.claude.json"
    WORKSPACE_CONFIG="$PROFILE_TMP/missing-workspace.yaml"
    USER_CONFIG="$PROFILE_TMP/missing-user.yaml"
    WORKSPACE_CONFIG_VALID=false
    USER_CONFIG_VALID=false
    unset CLAUDE_VERSION CLAUDE_CONFIG_PASSTHROUGH CLAUDE_CONFIG_DIR CLAUDE_CONFIG_FILE
    unset CODEX_VERSION CODEX_CONFIG_PASSTHROUGH CODEX_CONFIG_DIR
    unset ANTHROPIC_API_KEY OPENAI_API_KEY
}

reset_profile_context
CLAUDE_VERSION=2.1.152
ANTHROPIC_API_KEY=anthropic-secret
OPENAI_API_KEY=openai-secret
configure_tool claude
assert_eq "profile Claude: package" "@anthropic-ai/claude-code@2.1.152" "$TOOL_PACKAGE"
assert_eq "profile Claude: autonomy flag" "--dangerously-skip-permissions" "${TOOL_DEFAULT_ARGS[0]}"
assert_eq "profile Claude: two mounts" "4" "${#TOOL_VOLUME_ARGS[@]}"
assert_eq "profile Claude: only one API key pair" "2" "${#TOOL_ENV_ARGS[@]}"
assert_eq "profile Claude: API key name" "ANTHROPIC_API_KEY=anthropic-secret" "${TOOL_ENV_ARGS[1]}"

reset_profile_context
CODEX_VERSION=1.2.3
ANTHROPIC_API_KEY=anthropic-secret
OPENAI_API_KEY=openai-secret
configure_tool codex
assert_eq "profile Codex: package" "@openai/codex@1.2.3" "$TOOL_PACKAGE"
assert_eq "profile Codex: autonomy flag" "--dangerously-bypass-approvals-and-sandbox" "${TOOL_DEFAULT_ARGS[0]}"
assert_eq "profile Codex: one mount" "2" "${#TOOL_VOLUME_ARGS[@]}"
assert_eq "profile Codex: mount destination" "$HOME/.codex:$SANDBOX_HOME/.codex" "${TOOL_VOLUME_ARGS[1]}"
assert_eq "profile Codex: only one API key pair" "2" "${#TOOL_ENV_ARGS[@]}"
assert_eq "profile Codex: API key name" "OPENAI_API_KEY=openai-secret" "${TOOL_ENV_ARGS[1]}"

reset_profile_context
CODEX_CONFIG_PASSTHROUGH=false
configure_tool codex
assert_eq "profile Codex: disabled passthrough" "0" "${#TOOL_VOLUME_ARGS[@]}"

reset_profile_context
CODEX_CONFIG_DIR="$PROFILE_TMP/custom codex"
mkdir -p "$CODEX_CONFIG_DIR"
configure_tool codex
assert_eq "profile Codex: custom mount preserves spaces" "$CODEX_CONFIG_DIR:$SANDBOX_HOME/.codex" "${TOOL_VOLUME_ARGS[1]}"
```

Change `reset_profile_context` to register each temporary directory in a `PROFILE_TMP_DIRS` array and use one suite-level cleanup trap so repeated calls do not overwrite the earlier selection-test trap.

- [ ] **Step 2: Run profile tests and verify failure**

Run: `bash tests/launcher/test.sh`

Expected: non-zero exit with `configure_tool: command not found`.

- [ ] **Step 3: Implement version detection and explicit profiles**

Add these functions before the main guard:

```bash
detect_host_version() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || return 0
  "$command_name" --version 2>/dev/null |
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+' |
    head -1
}

configure_tool() {
  local tool="$1" version
  TOOL_PACKAGE=""
  TOOL_DEFAULT_ARGS=()
  TOOL_ENV_ARGS=()
  TOOL_VOLUME_ARGS=()

  case "$tool" in
    claude)
      version="$(resolve CLAUDE_VERSION .claude.version "$(detect_host_version claude)")"
      TOOL_PACKAGE="@anthropic-ai/claude-code${version:+@${version}}"
      TOOL_DEFAULT_ARGS=(--dangerously-skip-permissions)

      CLAUDE_CONFIG_PASSTHROUGH="$(resolve CLAUDE_CONFIG_PASSTHROUGH .claude.config_passthrough true)"
      CLAUDE_CONFIG_DIR="$(resolve CLAUDE_CONFIG_DIR .claude.config_dir "$HOME/.claude")"
      CLAUDE_CONFIG_FILE="$(resolve CLAUDE_CONFIG_FILE .claude.config_file "$HOME/.claude.json")"
      if [[ "$CLAUDE_CONFIG_PASSTHROUGH" == "true" ]]; then
        [[ -d "$CLAUDE_CONFIG_DIR" ]] &&
          TOOL_VOLUME_ARGS+=(-v "$CLAUDE_CONFIG_DIR:${SANDBOX_HOME}/.claude")
        [[ -f "$CLAUDE_CONFIG_FILE" ]] &&
          TOOL_VOLUME_ARGS+=(-v "$CLAUDE_CONFIG_FILE:${SANDBOX_HOME}/.claude.json")
      fi
      [[ -n "${ANTHROPIC_API_KEY:-}" ]] &&
        TOOL_ENV_ARGS+=(-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY")
      ;;
    codex)
      version="$(resolve CODEX_VERSION .codex.version "$(detect_host_version codex)")"
      TOOL_PACKAGE="@openai/codex${version:+@${version}}"
      TOOL_DEFAULT_ARGS=(--dangerously-bypass-approvals-and-sandbox)

      CODEX_CONFIG_PASSTHROUGH="$(resolve CODEX_CONFIG_PASSTHROUGH .codex.config_passthrough true)"
      CODEX_CONFIG_DIR="$(resolve CODEX_CONFIG_DIR .codex.config_dir "$HOME/.codex")"
      if [[ "$CODEX_CONFIG_PASSTHROUGH" == "true" && -d "$CODEX_CONFIG_DIR" ]]; then
        TOOL_VOLUME_ARGS+=(-v "$CODEX_CONFIG_DIR:${SANDBOX_HOME}/.codex")
      fi
      [[ -n "${OPENAI_API_KEY:-}" ]] &&
        TOOL_ENV_ARGS+=(-e OPENAI_API_KEY="$OPENAI_API_KEY")
      ;;
    *)
      launcher_error "unsupported tool '$tool'; supported tools: claude, codex"
      ;;
  esac
}
```

Remove the current straight-line Claude version, Claude config resolution, and `CLAUDE_VOLUME_ARGS` blocks from main only after `configure_tool` is wired in Task 3.

- [ ] **Step 4: Add host-version and unpinned-fallback tests**

Create a stub directory in `tests/launcher/test.sh` and assert both cases:

```bash
reset_profile_context
STUB_BIN="$PROFILE_TMP/bin"
mkdir -p "$STUB_BIN"
printf '#!/bin/sh\nprintf "codex-cli 4.5.6\\n"\n' > "$STUB_BIN/codex"
chmod +x "$STUB_BIN/codex"
OLD_PATH="$PATH"
PATH="$STUB_BIN:$PATH"
configure_tool codex
assert_eq "profile Codex: host version fallback" "@openai/codex@4.5.6" "$TOOL_PACKAGE"
PATH="$OLD_PATH"

reset_profile_context
EMPTY_BIN="$PROFILE_TMP/empty-bin"
mkdir -p "$EMPTY_BIN"
PATH="$EMPTY_BIN"
configure_tool codex
assert_eq "profile Codex: absent host CLI is unpinned" "@openai/codex" "$TOOL_PACKAGE"
PATH="$OLD_PATH"
```

Use `/bin/mkdir` inside the empty-`PATH` setup or create the directory before replacing `PATH`. Restore `PATH` immediately after the call.

- [ ] **Step 5: Add scalar config-resolution tests**

Append concrete `resolve` cases in `tests/config/test.sh` for:

```bash
printf 'tool: codex\ncodex:\n  version: "1.2.3"\n  config_passthrough: false\n  config_dir: /workspace/codex\n' > "$TMPDIR/codex-workspace.yaml"
printf 'tool: claude\ncodex:\n  version: "4.5.6"\n  config_passthrough: true\n  config_dir: /user/codex\n' > "$TMPDIR/codex-user.yaml"

WORKSPACE_CONFIG="$TMPDIR/codex-workspace.yaml"
USER_CONFIG="$TMPDIR/codex-user.yaml"
WORKSPACE_CONFIG_VALID=true
USER_CONFIG_VALID=true
unset SANDBOX_TOOL CODEX_VERSION CODEX_CONFIG_PASSTHROUGH CODEX_CONFIG_DIR

result=$(resolve SANDBOX_TOOL .tool claude)
[[ "$result" == "codex" ]] && ok "resolve: tool workspace wins" || bad "resolve: tool workspace wins (got '$result')"
result=$(resolve CODEX_VERSION .codex.version "")
[[ "$result" == "1.2.3" ]] && ok "resolve: codex.version workspace wins" || bad "resolve: codex.version workspace wins (got '$result')"
result=$(resolve CODEX_CONFIG_PASSTHROUGH .codex.config_passthrough true)
[[ "$result" == "false" ]] && ok "resolve: codex passthrough false preserved" || bad "resolve: codex passthrough false (got '$result')"
result=$(resolve CODEX_CONFIG_DIR .codex.config_dir "$HOME/.codex")
[[ "$result" == "/workspace/codex" ]] && ok "resolve: codex config dir workspace wins" || bad "resolve: codex config dir (got '$result')"

CODEX_VERSION=9.9.9
result=$(resolve CODEX_VERSION .codex.version "")
[[ "$result" == "9.9.9" ]] && ok "resolve: codex.version env wins" || bad "resolve: codex.version env wins (got '$result')"
unset CODEX_VERSION

WORKSPACE_CONFIG_VALID=false
result=$(resolve CODEX_VERSION .codex.version "")
[[ "$result" == "4.5.6" ]] && ok "resolve: codex.version user fallback" || bad "resolve: codex.version user fallback (got '$result')"
```

- [ ] **Step 6: Run profile, config, and complete suites**

Run: `bash tests/launcher/test.sh && bash tests/config/test.sh && bash tests/run-all.sh`

Expected: all available suites pass.

- [ ] **Step 7: Commit the profile boundary**

```bash
git add bin/claude-sandboxed tests/launcher/test.sh tests/config/test.sh
git commit -m "feat: add Claude and Codex tool profiles"
```

### Task 3: Wire Profiles into the Docker Invocation

**Files:**
- Modify: `bin/claude-sandboxed:58-211`
- Modify: `share/claude-sandboxed/docker-compose.yml:1-20`
- Modify: `tests/launcher/test.sh`

**Interfaces:**
- Consumes: `parse_launcher_args`, `resolve_tool`, `configure_tool`, `TOOL_USER_ARGS`, and all existing generic launcher arrays.
- Produces: the existing `docker compose run` call with selected `TOOL_PACKAGE`, `TOOL_DEFAULT_ARGS`, `TOOL_USER_ARGS`, `TOOL_ENV_ARGS`, and `TOOL_VOLUME_ARGS`.

- [ ] **Step 1: Add failing end-to-end command-capture tests**

Add a helper that runs the real launcher with a stub `docker` executable:

```bash
run_captured_launcher() {
    local capture_dir="$1"
    shift
    mkdir -p "$capture_dir/bin" "$capture_dir/home"
    printf '#!/bin/sh\nprintf "%%s\\0" "$@" > "$DOCKER_CAPTURE"\n' > "$capture_dir/bin/docker"
    chmod +x "$capture_dir/bin/docker"
    DOCKER_CAPTURE="$capture_dir/docker.args" \
    HOME="$capture_dir/home" \
    XDG_CONFIG_HOME="$capture_dir/home/.config" \
    SANDBOX_UID=1234 \
    SANDBOX_GID=1234 \
    SANDBOX_USERNAME=tester \
    SANDBOX_HOME=/home/tester \
    SANDBOX_CLEANUP=false \
    CLAUDE_SANDBOXED_DIR="$SCRIPT_DIR/../../share/claude-sandboxed" \
    PATH="$capture_dir/bin:$PATH" \
      bash "$LAUNCHER" "$@"
    mapfile -d '' -t CAPTURED_DOCKER_ARGS < "$capture_dir/docker.args"
}

CAPTURE_DIR="$(mktemp -d)"
run_captured_launcher "$CAPTURE_DIR" --tool codex "$SCRIPT_DIR/../.." -- --model "gpt test" resume
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<@openai/codex"* ]] &&
  ok "integration: Codex package reaches Docker" ||
  bad "integration: Codex package reaches Docker ($CAPTURED_JOINED)"
[[ "$CAPTURED_JOINED" == *"<--dangerously-bypass-approvals-and-sandbox><--model><gpt test><resume>"* ]] &&
  ok "integration: defaults precede exact passthrough args" ||
  bad "integration: passthrough ordering ($CAPTURED_JOINED)"

CAPTURE_DIR_2="$(mktemp -d)"
run_captured_launcher "$CAPTURE_DIR_2" "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<@anthropic-ai/claude-code"*"<--dangerously-skip-permissions>"* ]] &&
  ok "integration: default invocation remains Claude" ||
  bad "integration: default invocation remains Claude ($CAPTURED_JOINED)"
```

Register both capture directories in the suite cleanup array.

- [ ] **Step 2: Run the integration tests and verify the launcher still ignores new parsing/profile values**

Run: `bash tests/launcher/test.sh`

Expected: profile unit tests pass, but integration assertions fail because main still treats `--tool` as the workspace and still invokes `CLAUDE_PACKAGE`.

- [ ] **Step 3: Replace the main entry setup and tool-specific straight-line blocks**

After the existing version check, use:

```bash
parse_launcher_args "$@"

export WORKSPACE_DIR="${WORKSPACE_ARG:-$(pwd)}"
if [[ ! -d "$WORKSPACE_DIR" ]]; then
  launcher_error "workspace does not exist or is not a directory: $WORKSPACE_DIR"
  exit 2
fi
export WORKSPACE_DIR
WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" && pwd)" || {
  launcher_error "cannot resolve workspace: $WORKSPACE_DIR"
  exit 2
}
export WORKSPACE_DIR
```

After config validation and after resolving `SANDBOX_HOME`, add:

```bash
SELECTED_TOOL="$(resolve_tool "$CLI_TOOL")"
configure_tool "$SELECTED_TOOL"
```

Delete the old Claude-only version-resolution block, Claude config-resolution block, and `CLAUDE_VOLUME_ARGS` block. Keep `GIT_VOLUME_ARGS`, `GIT_ENV_ARGS`, and `GIT_POLICY_VOLUME_ARGS` behavior unchanged.

- [ ] **Step 4: Assemble the generic selected-tool command**

Replace the final agent invocation with:

```bash
# Run the selected coding agent in a one-shot container.
docker compose -p "$COMPOSE_PROJECT" -f "$SANDBOX_COMPOSE_DIR/docker-compose.yml" run \
  --rm \
  -e HOME="${SANDBOX_HOME}" \
  "${TOOL_ENV_ARGS[@]}" \
  "${GIT_ENV_ARGS[@]}" \
  "${GIT_VOLUME_ARGS[@]}" \
  "${TOOL_VOLUME_ARGS[@]}" \
  "${GIT_POLICY_VOLUME_ARGS[@]}" \
  -it ai-agent \
  npx --yes "$TOOL_PACKAGE" "${TOOL_DEFAULT_ARGS[@]}" "${TOOL_USER_ARGS[@]}"
```

Do not change the cleanup invocation or Compose project name.

- [ ] **Step 5: Make the Compose service tool-neutral**

Change the environment and comments to:

```yaml
    environment:
      - IS_SANDBOX=1  # Signals that the agent runs inside the external sandbox
```

Remove static `ANTHROPIC_API_KEY` forwarding. Rename comments from “Claude config” to “selected-tool config,” but retain the `ai-agent` service, `claude-agent-home` volume, workspace mount, git wrapper, entrypoint, image, and network mode exactly.

- [ ] **Step 6: Add validation-before-Docker integration assertions**

Add a counting Docker stub and run the launcher with `--tool unknown`, `--tool`, `--bad`, two workspaces, and a nonexistent workspace. For each case assert non-zero status, the expected error substring, and absence of the Docker capture file:

```bash
assert_rejected_before_docker() {
    local name="$1" expected_error="$2"
    shift 2
    local reject_dir
    reject_dir="$(mktemp -d)"
    mkdir -p "$reject_dir/bin" "$reject_dir/home"
    printf '#!/bin/sh\n: > "$DOCKER_CAPTURE"\n' > "$reject_dir/bin/docker"
    chmod +x "$reject_dir/bin/docker"
    local output code
    output=$(DOCKER_CAPTURE="$reject_dir/called" HOME="$reject_dir/home" \
      PATH="$reject_dir/bin:$PATH" bash "$LAUNCHER" "$@" 2>&1) && code=0 || code=$?
    if [[ $code -ne 0 && "$output" == *"$expected_error"* && ! -e "$reject_dir/called" ]]; then
      ok "$name"
    else
      bad "$name (code=$code, output='$output', docker_called=$([[ -e "$reject_dir/called" ]] && echo yes || echo no))"
    fi
}

assert_rejected_before_docker "integration: unknown tool rejected" "supported tools: claude, codex" --tool unknown
assert_rejected_before_docker "integration: missing tool rejected" "--tool requires" --tool
assert_rejected_before_docker "integration: unknown option rejected" "unsupported option" --bad
assert_rejected_before_docker "integration: multiple workspaces rejected" "at most one workspace" one two
assert_rejected_before_docker "integration: missing workspace rejected" "workspace does not exist" /definitely/not/a/workspace
```

- [ ] **Step 7: Run syntax, launcher, Compose, and regression checks**

Run:

```bash
bash -n bin/claude-sandboxed
bash tests/launcher/test.sh
docker compose -f share/claude-sandboxed/docker-compose.yml config
bash tests/run-all.sh
```

Expected: Bash syntax passes, all shell suites pass, and Compose renders successfully. If Docker Compose is unavailable, record that validation as skipped and do not install Docker.

- [ ] **Step 8: Commit the working multi-tool launcher**

```bash
git add bin/claude-sandboxed share/claude-sandboxed/docker-compose.yml tests/launcher/test.sh
git commit -m "feat: launch Claude or Codex in the sandbox"
```

### Task 4: Document the Stable Public Contract

**Files:**
- Modify: `share/claude-sandboxed/config.example.yaml:1-28`
- Modify: `README.md:1-199,273-304`
- Modify: `docs/architecture.md:1-50`
- Modify: `docs/development.md:3-104`
- Modify: `CLAUDE.md:3`

**Interfaces:**
- Consumes: implemented CLI, YAML keys, environment names, mount behavior, and tool profiles from Tasks 1-3.
- Produces: user and maintainer documentation matching the tested behavior.

- [ ] **Step 1: Update the installed example configuration**

Add this before the existing `claude:` block in `config.example.yaml`:

```yaml
# Coding agent to run. Supported values: claude, codex.
# Default: claude.
# tool: codex
```

Add this after the Claude block:

```yaml
codex:
  # Codex CLI version to run inside the container.
  # Default: host's codex version; npm's latest when codex is not installed.
  # version: "1.2.3"

  # When false, the host Codex config directory is not mounted.
  # Use OPENAI_API_KEY for authentication without host config. Default: true.
  # config_passthrough: true

  # Custom host path mounted at ${SANDBOX_HOME}/.codex.
  # Default: ~/.codex.
  # config_dir: /path/to/custom/.codex
```

Keep every package/config path headed by `claude-sandboxed`.

- [ ] **Step 2: Update README usage, schema, authentication, and feature status**

Document these exact public examples:

```bash
claude-sandboxed
claude-sandboxed --tool codex
claude-sandboxed --tool codex ~/projects/my-app
claude-sandboxed --tool codex ~/projects/my-app -- --model gpt-5.4
claude-sandboxed ~/projects/my-app -- --resume
```

State:

- Claude is the default.
- Selection precedence is CLI > `SANDBOX_TOOL` > workspace `tool` > user `tool` > Claude.
- Arguments after `--` pass unchanged to the selected tool.
- Claude uses `~/.claude`, `~/.claude.json`, and optionally `ANTHROPIC_API_KEY`.
- Codex uses `~/.codex` and optionally `OPENAI_API_KEY`.
- Both config mounts default to read/write passthrough and can be disabled independently.
- `CODEX_VERSION`, `CODEX_CONFIG_PASSTHROUGH`, and `CODEX_CONFIG_DIR` mirror the documented YAML keys.
- The package remains named `claude-sandboxed`; renaming is deferred.
- Mark the “More tools” feature as Claude and Codex complete, while retaining a future item for additional built-in agents.

- [ ] **Step 3: Update architecture with profile and volume lifecycles**

Describe the nine-step flow from the design and include this lifecycle table:

| Mount | Scope | Lifecycle |
|---|---|---|
| Workspace bind | Selected project | Host files persist; container is ephemeral |
| `claude-agent-home` named volume | Host UID | Shared across tools/workspaces/sessions until Docker removal |
| Tool-config bind | Host user by default; configurable per workspace | Host files persist; read/write |
| Git-config bind | Host user | Host files persist; read-only in container |
| Generated policy bind | One launcher invocation | Temporary host file removed by exit trap; read-only |
| Git-wrapper bind | Package installation | Persists with installation; read-only |

Change Claude-only prose to “selected coding agent” where it describes generic runtime behavior. Retain explicit names where describing each profile and autonomy flag.

- [ ] **Step 4: Update development invariants and test guidance**

Record:

- `parse_launcher_args`, `resolve_tool`, `detect_host_version`, and `configure_tool` remain sourceable.
- `GIT_VOLUME_ARGS` and `GIT_POLICY_VOLUME_ARGS` retain their existing meanings.
- `TOOL_VOLUME_ARGS` replaces `CLAUDE_VOLUME_ARGS`.
- Tool API keys are dynamically forwarded and must not return to static Compose environment entries.
- `SANDBOX_TOOL`, all `CLAUDE_*`, and all `CODEX_*` profile knobs are launcher-side only.
- `claude-agent-home`, `claude-sandboxed-${SANDBOX_UID}`, `ai-agent`, and installed paths remain unchanged.
- Add `tests/launcher/test.sh` to the automated-suite list.

Add manual checks for default Claude, explicit Codex with host login, Codex with passthrough disabled plus `OPENAI_API_KEY`, pinned versions for both tools, exact passthrough arguments, unsupported-tool rejection, and concurrent Claude/Codex sessions sharing only the documented per-UID named volume.

- [ ] **Step 5: Update the contributor description for both profiles**

Change the opening sentence of `CLAUDE.md` from:

```markdown
This is a sandboxed Claude Code launcher.
```

to:

```markdown
This is a Docker-sandboxed coding-agent launcher with first-class Claude Code and Codex CLI profiles.
```

Do not rename the file or any path listed in it.

- [ ] **Step 6: Verify documentation and installed example consistency**

Run:

```bash
rg -n 'TOOL_VOLUME_ARGS|CLAUDE_VOLUME_ARGS|ANTHROPIC_API_KEY|OPENAI_API_KEY|CODEX_VERSION|SANDBOX_TOOL|--tool|claude-agent-home' \
  README.md CLAUDE.md docs/architecture.md docs/development.md \
  share/claude-sandboxed/config.example.yaml share/claude-sandboxed/docker-compose.yml
git diff --check
bash tests/run-all.sh
```

Expected: old `CLAUDE_VOLUME_ARGS` appears only in historical design/plan documents, current docs consistently describe both profiles, diff check is clean, and all suites pass.

- [ ] **Step 7: Commit documentation**

```bash
git add README.md CLAUDE.md docs/architecture.md docs/development.md share/claude-sandboxed/config.example.yaml
git commit -m "docs: document Claude and Codex profiles"
```

### Task 5: Final Verification

**Files:**
- Verify only; modify earlier task files only when a failing check identifies a defect.

**Interfaces:**
- Consumes: all deliverables from Tasks 1-4.
- Produces: evidence that the implementation matches the approved spec.

- [ ] **Step 1: Run every automated and static check from a clean shell**

Run:

```bash
bash -n bin/claude-sandboxed
bash -n tests/launcher/test.sh
bash tests/run-all.sh
docker compose -f share/claude-sandboxed/docker-compose.yml config
git diff --check
git status --short
```

Expected: syntax checks pass; all discovered suites pass (with only the pre-existing allowed `yq` skip); Compose renders; diff check is empty; status contains no uncommitted implementation changes.

- [ ] **Step 2: Audit the package-name constraint**

Run:

```bash
git diff 02b7bc4..HEAD -- bin install.sh packaging share README.md CLAUDE.md docs/architecture.md docs/development.md |
  rg '^[+-].*(pkgname=|claude-sandboxed|CLAUDE_SANDBOXED_DIR|claude-agent-home|ai-agent)'
```

Expected: additions update prose or retain existing names; there is no rename of the package, executable, config paths, data path, Compose project, service, or named volume.

- [ ] **Step 3: Review commit boundaries**

Run: `git log --oneline 5598309..HEAD`

Expected: focused commits exist for parsing/selection, profiles, launcher wiring, and documentation, with no unrelated files.

- [ ] **Step 4: Record any unavailable manual runtime validation**

If interactive Docker authentication cannot be exercised in the environment, report the unrun manual checks explicitly. Do not claim interactive Claude or Codex authentication was verified unless each was actually launched.
