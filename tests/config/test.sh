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

echo ""
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
