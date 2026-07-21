#!/bin/bash
# Unit tests for git-wrapper.
# Run: bash tests/git-wrapper/test.sh

set -u

WRAPPER_DIR="$(cd "$(dirname "$0")/../../share/claude-sandboxed" && pwd)"
WRAPPER="$WRAPPER_DIR/git-wrapper"

STUB_DIR="$(mktemp -d)"
export STUB_DIR
trap 'rm -rf "$STUB_DIR"' EXIT

# Stub: records that it was called, exits 0.
cat > "$STUB_DIR/git" <<'EOF'
#!/bin/bash
touch "$STUB_DIR/called"
exit 0
EOF
chmod +x "$STUB_DIR/git"

pass=0
fail=0

# Assert the wrapper blocks the command (exit 1, [SECURITY] in stderr, real git not called).
assert_blocked() {
    local desc="$1"; shift
    rm -f "$STUB_DIR/called"
    local err code
    err="$(REAL_GIT="$STUB_DIR/git" "$WRAPPER" "$@" 2>&1 >/dev/null)" && code=0 || code=$?
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

# Assert the wrapper allows the command (exit 0, real git called).
assert_allowed() {
    local desc="$1"; shift
    rm -f "$STUB_DIR/called"
    REAL_GIT="$STUB_DIR/git" "$WRAPPER" "$@" >/dev/null 2>&1
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

# --- Tests ---

# Skeleton: pass-through cases
assert_allowed "git status"
assert_allowed "git log"
assert_allowed "git --version"
assert_allowed "git --help"
assert_allowed "git -C /tmp status"
assert_allowed "git -c user.name=x status"

# Task 2: fully blocked subcommands
assert_blocked "git push" push
assert_blocked "git push origin main" push origin main
assert_blocked "git reset" reset
assert_blocked "git reset --hard HEAD~1" reset --hard HEAD~1
assert_blocked "git reset --soft HEAD~1" reset --soft HEAD~1
assert_blocked "git rebase" rebase
assert_blocked "git rebase main" rebase main
assert_blocked "git filter-branch" filter-branch
assert_blocked "git filter-repo" filter-repo
assert_blocked "git clean" clean
assert_blocked "git clean -fd" clean -fd
assert_blocked "git config" config
assert_blocked "git config --get user.name" config --get user.name
assert_blocked "git config user.name X" config user.name X
assert_blocked "git config --global user.name X" config --global user.name X

# Task 2: parser must handle space-separated value flags to prevent bypass
assert_blocked "git --git-dir /tmp push" --git-dir /tmp push
assert_blocked "git --work-tree /tmp reset" --work-tree /tmp reset
assert_blocked "git --namespace foo push" --namespace foo push
assert_blocked "git --config-env user.name=ENVVAR push" --config-env user.name=ENVVAR push
assert_allowed "git --git-dir /tmp status" --git-dir /tmp status

# Task 3: conditionally blocked subcommands
assert_blocked "git reflog expire" reflog expire
assert_blocked "git reflog delete" reflog delete
assert_blocked "git reflog expire --all" reflog expire --all
assert_blocked "git reflog delete HEAD@{0}" reflog delete 'HEAD@{0}'
assert_allowed "git reflog show" reflog show
assert_allowed "git reflog exists HEAD" reflog exists HEAD
assert_allowed "git reflog (no sub-subcommand)" reflog
assert_blocked "git notes remove" notes remove
assert_blocked "git notes prune" notes prune
assert_blocked "git notes remove HEAD" notes remove HEAD
assert_allowed "git notes list" notes list
assert_allowed "git notes show HEAD" notes show HEAD
assert_allowed "git notes (no sub-subcommand)" notes
assert_blocked "git worktree remove" worktree remove
assert_blocked "git worktree prune" worktree prune
assert_blocked "git worktree remove /tmp/foo" worktree remove /tmp/foo
assert_allowed "git worktree list" worktree list
assert_allowed "git worktree add ../foo" worktree add ../foo
assert_allowed "git worktree (no sub-subcommand)" worktree

# Task 4: flag-level blocks (commit, tag, branch)
assert_blocked "git commit --amend" commit --amend
assert_blocked "git commit --amend --no-edit" commit --amend --no-edit
assert_blocked "git commit --reset-author" commit --reset-author
assert_allowed "git commit -m test" commit -m test
assert_allowed "git commit -am test" commit -am test
assert_blocked "git tag -d v1" tag -d v1
assert_blocked "git tag --delete v1" tag --delete v1
assert_blocked "git tag -f v1" tag -f v1
assert_blocked "git tag --force v1" tag --force v1
assert_allowed "git tag v1" tag v1
assert_allowed "git tag -a v1 -m msg" tag -a v1 -m msg
assert_blocked "git branch -d feature" branch -d feature
assert_blocked "git branch -D feature" branch -D feature
assert_blocked "git branch --delete feature" branch --delete feature
assert_allowed "git branch feature" branch feature
assert_allowed "git branch -a" branch -a

# Task 4: combined short flags (bypass prevention)
assert_blocked "git branch -df feature" branch -df feature
assert_blocked "git branch -Df feature" branch -Df feature
assert_blocked "git tag -fa v1 -m msg" tag -fa v1 -m msg
assert_blocked "git tag -af v1" tag -af v1
# Task 4: subcommand-alone boundary case
assert_allowed "git commit (no flags)" commit
assert_allowed "git tag (no args)" tag
assert_allowed "git branch (no args)" branch

# Task 5: flag-level blocks (stash, checkout, restore)
assert_blocked "git stash drop" stash drop
assert_blocked "git stash drop stash@{0}" stash drop 'stash@{0}'
assert_blocked "git stash clear" stash clear
assert_allowed "git stash" stash
assert_allowed "git stash push" stash push
assert_allowed "git stash pop" stash pop
assert_allowed "git stash list" stash list
assert_blocked "git checkout -B main" checkout -B main
assert_blocked "git checkout -f main" checkout -f main
assert_blocked "git checkout --force main" checkout --force main
assert_blocked "git checkout -- file.txt" checkout -- file.txt
assert_allowed "git checkout main" checkout main
assert_allowed "git checkout -b feature" checkout -b feature
assert_blocked "git restore --worktree file.txt" restore --worktree file.txt
assert_blocked "git restore -W file.txt" restore -W file.txt
assert_blocked "git restore --staged --worktree file.txt" restore --staged --worktree file.txt
assert_allowed "git restore --staged file.txt" restore --staged file.txt
# Task 5: combined short flags (bypass prevention)
assert_blocked "git checkout -Bf main" checkout -Bf main
assert_blocked "git checkout -fb feature" checkout -fb feature
assert_blocked "git restore -WS file.txt" restore -WS file.txt
# Task 5: subcommand-alone boundary case
assert_allowed "git checkout (no args)" checkout
assert_allowed "git restore (no args)" restore

# Task 6: flag-level blocks (rm, gc)
assert_blocked "git rm file.txt" rm file.txt
assert_blocked "git rm -f file.txt" rm -f file.txt
assert_blocked "git rm -r file.txt" rm -r file.txt
assert_allowed "git rm --cached file.txt" rm --cached file.txt
assert_allowed "git rm --cached -r file.txt" rm --cached -r file.txt
assert_blocked "git gc --prune" gc --prune
assert_blocked "git gc --prune=now" gc --prune=now
assert_allowed "git gc" gc
# Task 6: long-flag abbreviation
assert_allowed "git rm --cach file.txt" rm --cach file.txt
assert_blocked "git gc --pru" gc --pru

echo ""
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
