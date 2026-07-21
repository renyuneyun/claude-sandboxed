# Git Config Inheritance and Safe-Op Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Claude Code inside the sandbox use the host user's git config, and restrict git to non-destructive / appending-only operations via a wrapper script.

**Architecture:** A bash wrapper script (`share/claude-sandboxed/git-wrapper`) is bind-mounted to `/usr/local/bin/git` inside the container (preceding `/usr/bin/git` in `PATH`). It parses argv to find the subcommand, applies a blocklist of destructive subcommands plus flag-level checks on allowed subcommands, then `exec`s `/usr/bin/git` for allowed commands. The host's `~/.gitconfig` and `~/.config/git/` are bind-mounted read-only (conditionally, when they exist) so Claude sees the host user's git identity.

**Tech Stack:** Bash, Docker Compose, `node:22-bookworm` base image.

**Spec:** `docs/superpowers/specs/2026-07-21-git-config-and-safe-ops-design.md`

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `share/claude-sandboxed/git-wrapper` | New | Bash wrapper script: parse argv, apply policy, exec real git |
| `tests/git-wrapper/test.sh` | New | Unit tests for the wrapper using a stubbed real git |
| `tests/run-all.sh` | New | Test runner: discovers and runs all `tests/*/test.sh` scripts |
| `share/claude-sandboxed/docker-compose.yml` | Modify | Add bind mount for `git-wrapper` to `/usr/local/bin/git` |
| `bin/claude-sandboxed` | Modify | Add conditional `-v` flags for `~/.gitconfig` and `~/.config/git/` |
| `install.sh` | Modify | Install `git-wrapper` (mode 755) alongside `docker-compose.yml` |
| `packaging/PKGBUILD` | Modify | Install `git-wrapper` (mode 755) alongside `docker-compose.yml` |
| `README.md` | Modify | Document git policy, config inheritance, and how to run tests |
| `docs/architecture.md` | Modify | Add sections on config inheritance and operation policy |
| `docs/tradeoffs.md` | Modify | Add entries for wrapper approach and bypass limitation |
| `docs/development.md` | Modify | Add invariants, testing checklist items, and automated-test section |

---

### Task 1: Test infrastructure + wrapper skeleton

**Files:**
- Create: `tests/git-wrapper/test.sh`
- Create: `share/claude-sandboxed/git-wrapper`

- [ ] **Step 1: Create the test script with helpers and pass-through cases**

Create `tests/git-wrapper/test.sh`:

```bash
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

echo ""
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
```

- [ ] **Step 2: Create the wrapper skeleton (no policy yet)**

Create `share/claude-sandboxed/git-wrapper`:

```bash
#!/bin/bash
# Git wrapper for claude-sandboxed.
# Blocks destructive git operations (history rewriting, work discarding, pushes).
# Allows non-destructive and appending-only operations.
#
# Set REAL_GIT env var to override the path to the real git binary (for testing).

REAL_GIT="${REAL_GIT:-/usr/bin/git}"

# If no args, pass through (shows git help).
if [[ $# -eq 0 ]]; then
    exec "$REAL_GIT"
fi

# Parse global flags to find the subcommand (first positional arg).
# Handles -C <path> and -c <name>=<value>; other -X / --X flags are skipped.
subcommand=""
subcommand_idx=0
i=1
while [[ $i -le $# ]]; do
    arg="${!i}"
    case "$arg" in
        -C|-c)
            # Takes a value in the next arg.
            ((i += 2))
            continue
            ;;
        -*)
            # Other global flag, skip.
            ((i++))
            continue
            ;;
        *)
            subcommand="$arg"
            subcommand_idx=$i
            break
            ;;
    esac
done

# If no subcommand found, pass through (e.g. git --version, git --help).
if [[ -z "$subcommand" ]]; then
    exec "$REAL_GIT" "$@"
fi

# Block helper: print security message and exit 1.
block() {
    echo "[SECURITY] $1" >&2
    exit 1
}

# --- Policy checks (added in subsequent tasks) ---

# All checks passed, exec real git.
exec "$REAL_GIT" "$@"
```

- [ ] **Step 3: Make both scripts executable**

Run:
```bash
chmod +x share/claude-sandboxed/git-wrapper tests/git-wrapper/test.sh
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
bash tests/git-wrapper/test.sh
```
Expected: all 6 tests pass, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tests/git-wrapper/test.sh share/claude-sandboxed/git-wrapper
git commit -m "feat: add git-wrapper skeleton with test infrastructure"
```

---

### Task 2: Block fully-blocked subcommands

**Files:**
- Modify: `tests/git-wrapper/test.sh` (add test cases)
- Modify: `share/claude-sandboxed/git-wrapper` (extend parser + add blocklist case)

- [ ] **Step 1: Add failing test cases**

In `tests/git-wrapper/test.sh`, add these lines after the existing `assert_allowed` tests, before the `echo ""` summary line:

```bash
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
```

- [ ] **Step 2: Run tests to verify new cases fail**

Run:
```bash
bash tests/git-wrapper/test.sh
```
Expected: 19 new tests FAIL (15 blocked subcommand cases exit 0 instead of 1; 4 parser-bypass blocked cases also fail because the parser misidentifies the value as the subcommand; 1 `--git-dir` allowed case passes since `/tmp` isn't in the blocklist). The 6 original pass-through tests still pass.

- [ ] **Step 3: Extend the parser to handle space-separated value flags**

In `share/claude-sandboxed/git-wrapper`, find the parser's `case "$arg" in` block (around line 22). Replace the `-C|-c)` case with an expanded list of value-taking global flags:

```bash
        -C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env)
            # Takes a value in the next arg.
            ((i += 2))
            continue
            ;;
```

This prevents `git --git-dir /tmp push` (and similar with `--work-tree`, `--namespace`, `--super-prefix`, `--config-env`) from being misparsed as `subcommand=/tmp` (which would bypass the blocklist).

- [ ] **Step 4: Add the blocklist case to the wrapper**

In `share/claude-sandboxed/git-wrapper`, replace the `# --- Policy checks (added in subsequent tasks) ---` comment with:

```bash
# --- Policy checks ---

case "$subcommand" in
    push|reset|rebase|filter-branch|filter-repo|clean|config)
        block "git $subcommand is blocked by claude-sandboxed."
        ;;
esac
```

- [ ] **Step 5: Run tests to verify all pass**

Run:
```bash
bash tests/git-wrapper/test.sh
```
Expected: all 26 tests pass (6 pass-through + 15 blocked + 5 parser-bypass).

- [ ] **Step 6: Commit**

```bash
git add tests/git-wrapper/test.sh share/claude-sandboxed/git-wrapper
git commit -m "feat: block destructive git subcommands (push, reset, rebase, clean, config)"
```

---

### Task 3: Block conditionally-blocked subcommands

**Files:**
- Modify: `tests/git-wrapper/test.sh`
- Modify: `share/claude-sandboxed/git-wrapper`

- [ ] **Step 1: Add failing test cases**

In `tests/git-wrapper/test.sh`, add after the Task 2 tests:

```bash
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
```

- [ ] **Step 2: Run tests to verify new cases fail**

Run:
```bash
bash tests/git-wrapper/test.sh
```
Expected: 9 new `assert_blocked` cases FAIL. The 10 `assert_allowed` cases pass (no policy yet, so they pass through).

- [ ] **Step 3: Add conditional block checks to the wrapper**

In `share/claude-sandboxed/git-wrapper`, add these cases inside the existing `case "$subcommand" in` block, before the `esac`:

```bash
    reflog)
        for ((j=subcommand_idx+1; j<=$#; j++)); do
            case "${!j}" in
                expire|delete)
                    block "git reflog ${!j} is blocked by claude-sandboxed."
                    ;;
            esac
        done
        ;;
    notes)
        for ((j=subcommand_idx+1; j<=$#; j++)); do
            case "${!j}" in
                remove|prune)
                    block "git notes ${!j} is blocked by claude-sandboxed."
                    ;;
            esac
        done
        ;;
    worktree)
        for ((j=subcommand_idx+1; j<=$#; j++)); do
            case "${!j}" in
                remove|prune)
                    block "git worktree ${!j} is blocked by claude-sandboxed."
                    ;;
            esac
        done
        ;;
```

- [ ] **Step 4: Run tests to verify all pass**

Run:
```bash
bash tests/git-wrapper/test.sh
```
Expected: all 45 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tests/git-wrapper/test.sh share/claude-sandboxed/git-wrapper
git commit -m "feat: block destructive reflog/notes/worktree sub-subcommands"
```

---

### Task 4: Flag-level blocks - commit, tag, branch

**Files:**
- Modify: `tests/git-wrapper/test.sh`
- Modify: `share/claude-sandboxed/git-wrapper`

- [ ] **Step 1: Add failing test cases**

In `tests/git-wrapper/test.sh`, add after the Task 3 tests:

```bash
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
```

- [ ] **Step 2: Run tests to verify new cases fail**

Run:
```bash
bash tests/git-wrapper/test.sh
```
Expected: 14 new `assert_blocked` cases FAIL. The 9 `assert_allowed` cases pass.

- [ ] **Step 3: Add flag-level checks for commit, tag, branch**

In `share/claude-sandboxed/git-wrapper`, add these cases inside the existing `case "$subcommand" in` block, before the `esac`:

```bash
    commit)
        for ((j=subcommand_idx+1; j<=$#; j++)); do
            case "${!j}" in
                --amend|--reset-author)
                    block "git commit ${!j} is blocked by claude-sandboxed."
                    ;;
            esac
        done
        ;;
    tag)
        for ((j=subcommand_idx+1; j<=$#; j++)); do
            arg="${!j}"
            case "$arg" in
                --delete|--force)
                    block "git tag $arg is blocked by claude-sandboxed."
                    ;;
                -[!-]*)
                    if [[ "$arg" == *[df]* ]]; then
                        block "git tag $arg is blocked by claude-sandboxed."
                    fi
                    ;;
            esac
        done
        ;;
    branch)
        for ((j=subcommand_idx+1; j<=$#; j++)); do
            arg="${!j}"
            case "$arg" in
                --delete)
                    block "git branch $arg is blocked by claude-sandboxed."
                    ;;
                -[!-]*)
                    if [[ "$arg" == *[dD]* ]]; then
                        block "git branch $arg is blocked by claude-sandboxed."
                    fi
                    ;;
            esac
        done
        ;;
```

Note: `tag` and `branch` use a `case`+`if` pattern to catch combined short flags (e.g., `git branch -df feature`, `git tag -fa v1`) that would bypass a pure exact-match `case`. The `-[!-]*` pattern matches any short flag arg (starting with `-`, not `--`), and the `if` checks whether it contains the destructive character. `commit` is unaffected (its flags are long-form only, no combining).

- [ ] **Step 4: Run tests to verify all pass**

Run:
```bash
bash tests/git-wrapper/test.sh
```
Expected: all 68 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tests/git-wrapper/test.sh share/claude-sandboxed/git-wrapper
git commit -m "feat: block --amend on commit, -d/-f on tag, -d/-D on branch"
```

---

### Task 5: Flag-level blocks - stash, checkout, restore

**Files:**
- Modify: `tests/git-wrapper/test.sh`
- Modify: `share/claude-sandboxed/git-wrapper`

- [ ] **Step 1: Add failing test cases**

In `tests/git-wrapper/test.sh`, add after the Task 4 tests:

```bash
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
```

- [ ] **Step 2: Run tests to verify new cases fail**

Run:
```bash
bash tests/git-wrapper/test.sh
```
Expected: 13 new `assert_blocked` cases FAIL. The 9 `assert_allowed` cases pass.

- [ ] **Step 3: Add flag-level checks for stash, checkout, restore**

In `share/claude-sandboxed/git-wrapper`, add these cases inside the existing `case "$subcommand" in` block, before the `esac`:

```bash
    stash)
        for ((j=subcommand_idx+1; j<=$#; j++)); do
            case "${!j}" in
                drop|clear)
                    block "git stash ${!j} is blocked by claude-sandboxed."
                    ;;
            esac
        done
        ;;
    checkout)
        for ((j=subcommand_idx+1; j<=$#; j++)); do
            arg="${!j}"
            case "$arg" in
                --force)
                    block "git checkout $arg is blocked by claude-sandboxed."
                    ;;
                --)
                    block "git checkout -- <pathspec> is blocked by claude-sandboxed."
                    ;;
                -[!-]*)
                    if [[ "$arg" == *[Bf]* ]]; then
                        block "git checkout $arg is blocked by claude-sandboxed."
                    fi
                    ;;
            esac
        done
        ;;
    restore)
        for ((j=subcommand_idx+1; j<=$#; j++)); do
            arg="${!j}"
            case "$arg" in
                --worktree)
                    block "git restore $arg is blocked by claude-sandboxed."
                    ;;
                -[!-]*)
                    if [[ "$arg" == *W* ]]; then
                        block "git restore $arg is blocked by claude-sandboxed."
                    fi
                    ;;
            esac
        done
        ;;
```

Note: `checkout` and `restore` use the `case`+`if` pattern (same as `tag`/`branch` in Task 4) to catch combined short flags. `stash` uses the pure `case` pattern (sub-subcommand matching, same as `reflog`/`notes`/`worktree`). Lowercase `-b` (checkout create branch) is allowed; uppercase `-B` (reset branch) is blocked. `-S`/`--staged` (restore staged) is allowed; `-W`/`--worktree` is blocked.

- [ ] **Step 4: Run tests to verify all pass**

Run:
```bash
bash tests/git-wrapper/test.sh
```
Expected: all 90 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tests/git-wrapper/test.sh share/claude-sandboxed/git-wrapper
git commit -m "feat: block destructive stash/checkout/restore flag forms"
```

---

### Task 6: Flag-level blocks - rm, gc

**Files:**
- Modify: `tests/git-wrapper/test.sh`
- Modify: `share/claude-sandboxed/git-wrapper`

- [ ] **Step 1: Add failing test cases**

In `tests/git-wrapper/test.sh`, add after the Task 5 tests:

```bash
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
```

- [ ] **Step 2: Run tests to verify new cases fail**

Run:
```bash
bash tests/git-wrapper/test.sh
```
Expected: 6 new `assert_blocked` cases FAIL. The 4 `assert_allowed` cases pass.

- [ ] **Step 3: Add flag-level checks for rm, gc**

In `share/claude-sandboxed/git-wrapper`, add these cases inside the existing `case "$subcommand" in` block, before the `esac`:

```bash
    rm)
        has_cached=false
        for ((j=subcommand_idx+1; j<=$#; j++)); do
            case "${!j}" in
                --cac*)
                    has_cached=true
                    ;;
            esac
        done
        if ! $has_cached; then
            block "git rm without --cached is blocked by claude-sandboxed."
        fi
        ;;
    gc)
        for ((j=subcommand_idx+1; j<=$#; j++)); do
            case "${!j}" in
                --pru*)
                    block "git gc ${!j} is blocked by claude-sandboxed."
                    ;;
            esac
        done
        ;;
```

Note: The `--cac*)` and `--pru*)` patterns catch long-flag abbreviations (e.g., `--cach` for `--cached`, `--pru` for `--prune`). Git accepts unambiguous prefixes of long flags, so exact-match patterns (`--cached)`) would miss these. The 3-char prefix is a balance between catching natural abbreviations and avoiding false positives from future flags. Very short abbreviations (`--ca`, `--pr`) are not caught - this is a known limitation consistent with the threat model (Claude uses full flag names).

- [ ] **Step 4: Run tests to verify all pass**

Run:
```bash
bash tests/git-wrapper/test.sh
```
Expected: all 100 tests pass.

- [ ] **Step 5: Commit**

```bash
git add tests/git-wrapper/test.sh share/claude-sandboxed/git-wrapper
git commit -m "feat: block git rm (without --cached) and git gc --prune"
```

---

### Task 7: Install wrapper in the container

**Files:**
- Modify: `share/claude-sandboxed/docker-compose.yml`
- Modify: `install.sh`
- Modify: `packaging/PKGBUILD`

- [ ] **Step 1: Add the wrapper bind mount to docker-compose.yml**

In `share/claude-sandboxed/docker-compose.yml`, under `ai-agent.volumes`, add a new entry after the `${HOME}/.claude.json` line. The `./` prefix makes the path relative to the compose file's directory (`share/claude-sandboxed/`):

```yaml
    volumes:
      # 1. DYNAMIC MOUNT: Injected dynamically by the wrapper launcher.
      #    Mounted at its exact host path so Claude sees the same absolute path as the host.
      - ${WORKSPACE_DIR}:${WORKSPACE_DIR}
      # 2. PERSISTENT CACHE: Saves manual tools, packages, global settings, and histories
      - claude-agent-home:${SANDBOX_HOME}
      # 3. CLAUDE CONFIG PASS-THROUGH: Links your local credential configurations
      - ${HOME}/.claude:${SANDBOX_HOME}/.claude
      - ${HOME}/.claude.json:${SANDBOX_HOME}/.claude.json
      # 4. GIT WRAPPER: Intercepts git calls to block destructive operations.
      #    Read-only; /usr/local/bin precedes /usr/bin in PATH inside node:22-bookworm.
      - ./git-wrapper:/usr/local/bin/git:ro
```

- [ ] **Step 2: Add git-wrapper to install.sh**

In `install.sh`, after the line that installs `docker-compose.yml` (line 16), add:

```bash
install -m755 "$SCRIPT_DIR/share/claude-sandboxed/git-wrapper" "$DATA_DIR/git-wrapper"
```

- [ ] **Step 3: Add git-wrapper to PKGBUILD**

In `packaging/PKGBUILD`, inside the `package()` function, after the line that installs `docker-compose.yml` (line 17), add:

```bash
    install -Dm755 "$_repodir/share/claude-sandboxed/git-wrapper" "$pkgdir/usr/share/claude-sandboxed/git-wrapper"
```

- [ ] **Step 4: Manual test - dev mode**

Run from the repo root:
```bash
./bin/claude-sandboxed
```

Inside the container, verify:
```bash
which git
# Expected: /usr/local/bin/git

git --version
# Expected: git version 2.x.x (passes through to real git)

git status
# Expected: normal git status output (in an empty dir this errors; test inside a repo)

git push
# Expected: [SECURITY] git push is blocked by claude-sandboxed.

git commit --amend
# Expected: [SECURITY] git commit --amend is blocked by claude-sandboxed.
```

Type `exit` to leave the container.

- [ ] **Step 5: Commit**

```bash
git add share/claude-sandboxed/docker-compose.yml install.sh packaging/PKGBUILD
git commit -m "feat: bind-mount git-wrapper to /usr/local/bin/git in container"
```

---

### Task 8: Conditional gitconfig mounts in launcher

**Files:**
- Modify: `bin/claude-sandboxed`

- [ ] **Step 1: Add conditional volume args before the docker compose run call**

In `bin/claude-sandboxed`, locate the `docker compose -p "$COMPOSE_PROJECT" ... run` block (around line 44). Insert this block immediately before it, after the `SANDBOX_COMPOSE_DIR` resolution:

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

- [ ] **Step 2: Pass the volume args to docker compose run**

In the same `docker compose ... run` command, add `"${GIT_VOLUME_ARGS[@]}"` between `-e HOME="${SANDBOX_HOME}"` and `-it`. The full command becomes:

```bash
docker compose -p "$COMPOSE_PROJECT" -f "$SANDBOX_COMPOSE_DIR/docker-compose.yml" run \
  --rm \
  -e HOME="${SANDBOX_HOME}" \
  "${GIT_VOLUME_ARGS[@]}" \
  -it ai-agent npx --yes "$CLAUDE_PACKAGE" --dangerously-skip-permissions
```

- [ ] **Step 3: Manual test - with gitconfig**

If you have `~/.gitconfig` on the host (the maintainer currently does not - set one for testing with `git config --global user.name "Test" && git config --global user.email "test@example.com"`):

```bash
./bin/claude-sandboxed
```

Inside the container:
```bash
cat ~/.gitconfig
# Expected: matches host ~/.gitconfig content

git config --get user.name
# Expected: [SECURITY] git config is blocked by claude-sandboxed.
# (Use `cat ~/.gitconfig` instead - the wrapper blocks git config entirely.)

# In a git repo inside the workspace:
git commit -m test --allow-empty
# Expected: commit succeeds, author is the host user's identity
```

- [ ] **Step 4: Manual test - without gitconfig**

Temporarily rename `~/.gitconfig` and `~/.config/git` (if present), then:
```bash
./bin/claude-sandboxed
```

Inside the container:
```bash
ls ~/.gitconfig 2>&1
# Expected: No such file or directory (mount was skipped)

git --version
# Expected: works (uses defaults)
```

Exit and restore the renamed files.

- [ ] **Step 5: Commit**

```bash
git add bin/claude-sandboxed
git commit -m "feat: bind-mount host ~/.gitconfig and ~/.config/git read-only"
```

---

### Task 9: Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/tradeoffs.md`
- Modify: `docs/development.md`

- [ ] **Step 1: Update README.md**

In `README.md`, locate the "Features" section. Update the "Git push protection" line (currently `- [x] **Git push protection** - blocks git pushes ...`) to a broader "Git operation policy" entry, and add a new subsection. Replace:

```markdown
    - [x] **Git push protection** - blocks git pushes (SSH and HTTPS to GitHub) to prevent accidental upstream changes
```

with:

```markdown
    - [x] **Git operation policy** - a wrapper script blocks destructive git operations (push, reset, rebase, clean, commit --amend, branch -D, tag -d, etc.) while allowing non-destructive and appending-only operations (commit, add, status, log, fetch, merge, etc.)
    - [x] **Git config inheritance** - the host user's `~/.gitconfig` and `~/.config/git/` are bind-mounted read-only so Claude commits with the host user's identity
```

Then, under the "## Customization" section, add a new subsection at the end:

```markdown
### Git policy

Inside the sandbox, `git` is a wrapper script that blocks destructive operations and allows non-destructive / appending-only ones. Blocked operations print `[SECURITY] ...` to stderr and exit non-zero.

**Fully blocked subcommands:** `push`, `reset`, `rebase`, `filter-branch`, `filter-repo`, `clean`, `config`.

**Conditionally blocked subcommands:** `reflog expire|delete`, `notes remove|prune`, `worktree remove|prune`, `stash drop|clear`, `branch -d|-D|--delete`, `tag -d|--delete|-f|--force`.

**Flag-level blocks on allowed subcommands:**

| Subcommand | Blocked flags |
|---|---|
| `commit` | `--amend`, `--reset-author` |
| `checkout` | `-B`, `-f`, `--force`, `-- <pathspec>` |
| `restore` | `--worktree`, `-W` |
| `rm` | (without `--cached`) |
| `gc` | `--prune` |

`git config` is blocked entirely (including reads) because allowing `git config --local` writes would let Claude define an alias like `alias.x = !/usr/bin/git push` that bypasses the wrapper. Use `cat ~/.gitconfig` or `cat .git/config` to read config.

**Known limitation:** the wrapper is a soft barrier. Calling `/usr/bin/git` by absolute path bypasses it. This is consistent with the project's threat model (accidental damage, not adversarial resistance).
```

Then, add a new top-level section after "## Features" (before "## Further reading"):

```markdown
## Testing

Automated tests live in `tests/`. Run all tests from the repo root:

```sh
bash tests/run-all.sh
```

Each subdirectory of `tests/` contains a `test.sh` script for one component. The runner discovers and executes all of them. Tests run on the host (no Docker required) - the git wrapper tests use a stubbed real git binary.
```

- [ ] **Step 2: Update docs/architecture.md**

In `docs/architecture.md`, update the "Git push protection" section at the end. Replace the existing section (lines 46-53) with:

```markdown
## Git config inheritance

The host user's `~/.gitconfig` and `~/.config/git/` are bind-mounted into the container at the corresponding paths under `$SANDBOX_HOME`, read-only. Mounts are conditional: if the host path does not exist, the mount is skipped (git uses defaults). Read-only prevents Claude from modifying the host's git config.

Git config precedence is system < global, so a user's `~/.gitconfig` could override `core.sshCommand` set via `git config --system`. This is acceptable because `git push` is blocked at the wrapper level (see below), and the threat model is accidental damage, not adversarial bypass.

## Git operation policy

A wrapper script at `share/claude-sandboxed/git-wrapper` is bind-mounted to `/usr/local/bin/git` in the container (read-only). The `node:22-bookworm` image's default `PATH` has `/usr/local/bin` before `/usr/bin`, so `git` invocations hit the wrapper. The wrapper parses argv, applies a blocklist of destructive subcommands plus flag-level checks on allowed subcommands, then `exec`s `/usr/bin/git` for allowed commands.

The wrapper does **not** strip user-supplied `-c` flags or `GIT_CONFIG_*` env vars. The defense is that push is blocked at the subcommand level, and `~/.gitconfig` is read-only.

**Bypass via `/usr/bin/git` directly is a known limitation.** See `docs/tradeoffs.md`.

### Blocked operations

- **Fully blocked subcommands:** `push`, `reset`, `rebase`, `filter-branch`, `filter-repo`, `clean`, `config`
- **Conditionally blocked:** `reflog expire|delete`, `notes remove|prune`, `worktree remove|prune`, `stash drop|clear`, `branch -d|-D|--delete`, `tag -d|--delete|-f|--force`
- **Flag-level blocks:** `commit --amend|--reset-author`, `checkout -B|-f|--force|-- <pathspec>`, `restore --worktree|-W`, `rm` (without `--cached`), `gc --prune`

### Defense in depth

Two independent layers block `git push`:

1. Entrypoint sets `git config --system core.sshCommand ...` and `url.insteadOf` rules (existing).
2. Wrapper blocks `git push` at the subcommand level (new).

Either failing leaves the other working.
```

Also update the "Volume layout" table to add the git config mounts and the wrapper mount. Add these rows after the existing `~/.claude.json` row:

```markdown
| `~/.gitconfig` (host, if exists) | `$SANDBOX_HOME/.gitconfig` | User-level git config (identity, aliases, signing keys) - read-only |
| `~/.config/git/` (host, if exists) | `$SANDBOX_HOME/.config/git/` | XDG git config, attributes, ignores - read-only |
| `git-wrapper` (compose dir) | `/usr/local/bin/git` | Git wrapper script (policy enforcement) - read-only |
```

- [ ] **Step 3: Update docs/tradeoffs.md**

In `docs/tradeoffs.md`, append a new section at the end:

```markdown
---

## Git operation policy: wrapper script vs git aliases vs hooks

### Wrapper script (chosen)

A bash wrapper at `/usr/local/bin/git` (bind-mounted from `share/claude-sandboxed/git-wrapper`) intercepts every `git` invocation. It parses argv, applies a blocklist of destructive subcommands plus flag-level checks, then `exec`s `/usr/bin/git` for allowed commands.

**Why chosen:** Handles flag-level checks naturally (`git commit --amend` blocked while `git commit -m` allowed). Centralised, inspectable, works for all users. Cannot be overridden by user git config.

**Trade-off:** Soft barrier - calling `/usr/bin/git` by absolute path bypasses it. See "Soft barrier vs hard barrier" below.

### Git aliases via `git config --system` (not chosen)

Alias `push`, `reset`, etc. to commands that fail.

**Why not used:** Aliases are bypassable via `git -c alias.push=push push`. Cannot express flag-level checks (`commit --amend` is not a separate alias from `commit`). Does not cover all destructive ops.

### Per-repo git hooks (not chosen)

Install `pre-commit`, `post-rewrite`, etc. in each repo's `.git/hooks`.

**Why not used:** Per-repo (Claude would need to init them). `--no-verify` bypasses most hooks. Does not cover `reset --hard`, `clean`, etc.

---

## Soft barrier vs hard barrier for git operations

### Current: soft barrier (wrapper script)

The wrapper at `/usr/local/bin/git` intercepts `git` invocations. Claude (or any process) can bypass it by calling `/usr/bin/git` directly.

**Why acceptable:** The threat model is accidental damage by Claude, not adversarial bypass. Claude uses `git <subcommand>` - it does not call `/usr/bin/git` by absolute path in normal operation. The existing push protection (system git config) has the same soft-barrier property (user config can override system config).

### Hard barrier options (not implemented)

- `chmod 700 /usr/bin/git` + setuid wrapper binary: blocks non-root access to real git. Requires a compiled setuid binary (setuid scripts don't work on Linux). Significant complexity.
- AppArmor/SELinux profile: restricts which binaries can execute git. Requires host-level MAC configuration, harms portability.
- Custom git binary with built-in restrictions: requires building git from source, ongoing maintenance.

Hard barriers are out of scope for the non-adversarial threat model. If the threat model changes (e.g. running untrusted Claude plugins), revisit.
```

- [ ] **Step 4: Update docs/development.md**

In `docs/development.md`, under "Key invariants", add these entries after the existing "git push-blocking entrypoint must remain" line:

```markdown
- The `git-wrapper` bind mount (`./git-wrapper:/usr/local/bin/git:ro` in `ai-agent.volumes`) must remain. Removing it disables the git operation policy.
- `share/claude-sandboxed/git-wrapper` must be executable (mode 755). `install.sh` and `packaging/PKGBUILD` must install it with mode 755.
- `/usr/local/bin` must precede `/usr/bin` in the container's `PATH` (true for `node:22-bookworm` by default). If the base image changes, verify this.
- The conditional `~/.gitconfig` and `~/.config/git/` mounts in `bin/claude-sandboxed` must check existence before mounting (avoids Docker creating empty stub dirs on the host).
```

Also fix the stale path on line 7: change `share/docker-compose.yml` to `share/claude-sandboxed/docker-compose.yml`.

Then, under "Manual testing checklist", add these items:

```markdown
5. **Git wrapper:** inside the container, `which git` shows `/usr/local/bin/git`.
6. **Git policy - blocked:** inside the container, `git push`, `git reset --hard`, `git commit --amend`, `git clean -fd`, `git rebase`, `git config --get user.name` all fail with `[SECURITY]` messages.
7. **Git policy - allowed:** inside the container, `git status`, `git log`, `git add`, `git commit -m test` (in a repo), `git switch`, `git fetch` all work.
8. **Git config inheritance:** with `~/.gitconfig` on the host, commits inside the container use the host user's identity. Without `~/.gitconfig`, the container starts and git uses defaults.
9. **Automated tests:** run `bash tests/run-all.sh` from the repo root - all test suites pass.
```

Then, add a new section at the end of `docs/development.md`:

```markdown
## Automated tests

Automated tests live in `tests/`. Each subdirectory contains a `test.sh` script for one component. The runner (`tests/run-all.sh`) discovers and executes all `tests/*/test.sh` scripts.

Run all tests from the repo root:

```sh
bash tests/run-all.sh
```

Current test suites:

- `tests/git-wrapper/test.sh` - unit tests for the git wrapper script (policy enforcement, argument parsing). Uses a stubbed real git binary so tests run on the host without Docker.

To add a new test suite, create `tests/<component>/test.sh` and make it executable. The runner picks it up automatically. A test script should print `PASS:` / `FAIL:` lines and exit non-zero on any failure.

All automated tests must pass before release.
```

- [ ] **Step 5: Commit**

```bash
git add README.md docs/architecture.md docs/tradeoffs.md docs/development.md
git commit -m "docs: document git config inheritance and operation policy"
```

---

### Task 10: Test runner

**Files:**
- Create: `tests/run-all.sh`

- [ ] **Step 1: Create the test runner script**

Create `tests/run-all.sh`:

```bash
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
```

- [ ] **Step 2: Make the runner executable**

Run:
```bash
chmod +x tests/run-all.sh
```

- [ ] **Step 3: Run the runner to verify it discovers and passes the git-wrapper tests**

Run:
```bash
bash tests/run-all.sh
```
Expected output: prints `=== Running .../tests/git-wrapper/test.sh ===`, followed by the 100 `PASS:` lines from the test suite, then `Results: 100 passed, 0 failed`, then `All 1 test suite(s) passed.` Exit code 0.

- [ ] **Step 4: Commit**

```bash
git add tests/run-all.sh
git commit -m "test: add tests/run-all.sh runner for all test suites"
```

---

## Self-Review Checklist (for the implementer to verify before declaring done)

- [ ] All 100 unit tests in `tests/git-wrapper/test.sh` pass.
- [ ] `bash tests/run-all.sh` from the repo root passes (discovers and runs the git-wrapper suite).
- [ ] `which git` inside the container shows `/usr/local/bin/git`.
- [ ] `git push` inside the container fails with `[SECURITY]` message.
- [ ] `git commit --amend` inside the container fails with `[SECURITY]` message.
- [ ] `git commit -m test` inside a repo inside the container succeeds (assuming `~/.gitconfig` exists on host).
- [ ] `git config --get user.name` inside the container fails (config is blocked entirely).
- [ ] Without `~/.gitconfig` on host, container still starts and `git` works (uses defaults).
- [ ] `install.sh` and `PKGBUILD` install `git-wrapper` with mode 755.
- [ ] README, architecture, tradeoffs, development docs all updated.
- [ ] No placeholders or TODOs left in any committed file.
