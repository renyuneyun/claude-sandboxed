#!/bin/bash
# Run all test suites under tests/.
# Each subdirectory of tests/ contains a test.sh script for one component.
# The runner discovers and executes all tests/*/test.sh scripts.
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail=0
ran=0
for test_script in "$TESTS_DIR"/*/test.sh; do
    [[ -f "$test_script" ]] || continue
    echo "=== Running $test_script ==="
    if bash "$test_script"; then
        ran=$((ran+1))
    else
        fail=1
        ran=$((ran+1))
    fi
    echo ""
done

if [[ $ran -eq 0 ]]; then
    echo "No tests found."
    exit 1
fi

if [[ $fail -ne 0 ]]; then
    echo "FAILED: some test suites failed."
    exit 1
fi
echo "All $ran test suite(s) passed."
