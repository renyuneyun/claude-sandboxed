#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$SCRIPT_DIR/../../bin/claude-sandboxed"
# shellcheck source=/dev/null
source "$LAUNCHER"

pass=0
fail=0
PROFILE_TMP_DIRS=()
cleanup_launcher_tests() {
    local dir
    for dir in "${PROFILE_TMP_DIRS[@]}"; do
        rm -rf "$dir"
    done
}
trap cleanup_launcher_tests EXIT

ok() { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then ok "$name"; else bad "$name (expected '$expected', got '$actual')"; fi
}

unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
unset http_proxy https_proxy all_proxy no_proxy

if declare -F configure_proxy_env >/dev/null; then
    SANDBOX_PROXY_ENV_PASSTHROUGH=true
    HTTP_PROXY='http://uppercase-http.test:8001'
    HTTPS_PROXY='http://user:p@ss@uppercase-https.test:8002/path with space'
    ALL_PROXY='socks5://uppercase-all.test:8003'
    NO_PROXY='localhost,127.0.0.1,.internal.test'
    http_proxy='http://lowercase-http.test:9001'
    https_proxy='http://lowercase-https.test:9002'
    all_proxy='socks5://lowercase-all.test:9003'
    no_proxy='localhost,.lowercase.test'
    configure_proxy_env
    assert_eq "proxy: all eight variables produce argument pairs" "16" "${#PROXY_ENV_ARGS[@]}"
    PROXY_JOINED="$(printf '<%s>' "${PROXY_ENV_ARGS[@]}")"
    [[ "$PROXY_JOINED" == *'<HTTPS_PROXY=http://user:p@ss@uppercase-https.test:8002/path with space>'* ]] &&
      ok "proxy: values preserve spaces and punctuation" ||
      bad "proxy: values preserve spaces and punctuation ($PROXY_JOINED)"
    [[ "$PROXY_JOINED" == *'<HTTP_PROXY=http://uppercase-http.test:8001>'* &&
       "$PROXY_JOINED" == *'<ALL_PROXY=socks5://uppercase-all.test:8003>'* &&
       "$PROXY_JOINED" == *'<NO_PROXY=localhost,127.0.0.1,.internal.test>'* &&
       "$PROXY_JOINED" == *'<http_proxy=http://lowercase-http.test:9001>'* &&
       "$PROXY_JOINED" == *'<https_proxy=http://lowercase-https.test:9002>'* &&
       "$PROXY_JOINED" == *'<all_proxy=socks5://lowercase-all.test:9003>'* &&
       "$PROXY_JOINED" == *'<no_proxy=localhost,.lowercase.test>'* ]] &&
      ok "proxy: uppercase and lowercase names are forwarded independently" ||
      bad "proxy: uppercase and lowercase names ($PROXY_JOINED)"

    HTTPS_PROXY=
    configure_proxy_env
    assert_eq "proxy: empty variables are omitted" "14" "${#PROXY_ENV_ARGS[@]}"

    SANDBOX_PROXY_ENV_PASSTHROUGH=false
    configure_proxy_env
    assert_eq "proxy: disabled passthrough emits no arguments" "0" "${#PROXY_ENV_ARGS[@]}"
else
    bad "proxy: configure_proxy_env function exists"
fi

unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
unset http_proxy https_proxy all_proxy no_proxy SANDBOX_PROXY_ENV_PASSTHROUGH

parse_launcher_args
assert_eq "parse: default workspace is empty sentinel" "" "$WORKSPACE_ARG"
assert_eq "parse: no CLI tool override" "" "$CLI_TOOL"
assert_eq "parse: no tool args" "0" "${#TOOL_USER_ARGS[@]}"

parse_launcher_args --tool codex "/tmp/project with spaces" -- --model "gpt-5.4" "prompt with spaces"
assert_eq "parse: tool" "codex" "$CLI_TOOL"
assert_eq "parse: workspace" "/tmp/project with spaces" "$WORKSPACE_ARG"
assert_eq "parse: passthrough count" "3" "${#TOOL_USER_ARGS[@]}"
assert_eq "parse: passthrough first" "--model" "${TOOL_USER_ARGS[0]}"
assert_eq "parse: passthrough spaced value" "prompt with spaces" "${TOOL_USER_ARGS[2]}"

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

if command -v yq >/dev/null 2>&1; then
    LAUNCHER_TMP="$(mktemp -d)"
    PROFILE_TMP_DIRS+=("$LAUNCHER_TMP")
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

reset_profile_context() {
    PROFILE_TMP="$(mktemp -d)"
    PROFILE_TMP_DIRS+=("$PROFILE_TMP")
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
/bin/mkdir -p "$EMPTY_BIN"
PATH="$EMPTY_BIN"
configure_tool codex
assert_eq "profile Codex: absent host CLI is unpinned" "@openai/codex" "$TOOL_PACKAGE"
PATH="$OLD_PATH"

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
    CLAUDE_VERSION=integration-test \
    CODEX_VERSION=integration-test \
    HTTP_PROXY="${TEST_HTTP_PROXY:-}" \
    HTTPS_PROXY= ALL_PROXY= NO_PROXY= \
    http_proxy= https_proxy= all_proxy= no_proxy= \
    SANDBOX_PROXY_ENV_PASSTHROUGH="${TEST_PROXY_PASSTHROUGH:-true}" \
    CLAUDE_SANDBOXED_DIR="$SCRIPT_DIR/../../share/claude-sandboxed" \
    PATH="$capture_dir/bin:$PATH" \
      bash "$LAUNCHER" "$@"
    mapfile -d '' -t CAPTURED_DOCKER_ARGS < "$capture_dir/docker.args"
}

CAPTURE_DIR="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$CAPTURE_DIR")
TEST_HTTP_PROXY='http://codex-proxy.test:7890'
run_captured_launcher "$CAPTURE_DIR" --tool codex "$SCRIPT_DIR/../.." -- --model "gpt test" resume
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<@openai/codex"* ]] &&
  ok "integration: Codex package reaches Docker" ||
  bad "integration: Codex package reaches Docker ($CAPTURED_JOINED)"
[[ "$CAPTURED_JOINED" == *"<--dangerously-bypass-approvals-and-sandbox><--model><gpt test><resume>"* ]] &&
  ok "integration: defaults precede exact passthrough args" ||
  bad "integration: passthrough ordering ($CAPTURED_JOINED)"
[[ "$CAPTURED_JOINED" == *"<-e><HTTP_PROXY=http://codex-proxy.test:7890>"* ]] &&
  ok "integration: proxy reaches Codex Docker invocation" ||
  bad "integration: proxy reaches Codex Docker invocation ($CAPTURED_JOINED)"

CAPTURE_DIR_2="$(mktemp -d)"
PROFILE_TMP_DIRS+=("$CAPTURE_DIR_2")
TEST_PROXY_PASSTHROUGH=false
run_captured_launcher "$CAPTURE_DIR_2" "$SCRIPT_DIR/../.."
CAPTURED_JOINED="$(printf '<%s>' "${CAPTURED_DOCKER_ARGS[@]}")"
[[ "$CAPTURED_JOINED" == *"<@anthropic-ai/claude-code"*"<--dangerously-skip-permissions>"* ]] &&
  ok "integration: default invocation remains Claude" ||
  bad "integration: default invocation remains Claude ($CAPTURED_JOINED)"
[[ "$CAPTURED_JOINED" != *"<HTTP_PROXY=http://codex-proxy.test:7890>"* ]] &&
  ok "integration: disabled proxy does not reach Docker" ||
  bad "integration: disabled proxy reaches Docker ($CAPTURED_JOINED)"
unset TEST_HTTP_PROXY TEST_PROXY_PASSTHROUGH

assert_rejected_before_docker() {
    local name="$1" expected_error="$2"
    shift 2
    local reject_dir
    reject_dir="$(mktemp -d)"
    PROFILE_TMP_DIRS+=("$reject_dir")
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

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
