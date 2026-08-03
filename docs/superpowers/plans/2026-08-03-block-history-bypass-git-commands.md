# Block History-Bypass Git Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Block 6 plumbing-level git subcommands (`commit-tree`, `update-ref`, `replace`, `fast-import`, `prune`, `symbolic-ref`) in the git wrapper so they can't be used to circumvent existing history-manipulation blocks.

**Architecture:** Add the 6 subcommands to the existing fully-blocked case branch in `share/claude-sandboxed/git-wrapper`. No conditional logic or flag parsing needed - all 6 are blocked unconditionally, like `push` and `rebase`. Update tests, README, and docs to match.

**Tech Stack:** Bash, existing shell test harness (`tests/git-wrapper/test.sh`).

## Global Constraints

- Block all 6 commands entirely (no force-form distinction). They are plumbing with no git-protected safe form.
- Do not change existing blocks, conditional blocks, flag-level blocks, or the user policy file contract.
- Do not add new dependencies.
- Do not change the docker-compose file, launcher, install paths, or any other code.
- `packaging/pkg/` is an untracked build artifact - do not modify it; changes to `share/` propagate on next `makepkg`.

---

## File Structure

- Modify `share/claude-sandboxed/git-wrapper`: extend the fully-blocked case branch (line 87) with 6 new subcommands.
- Modify `tests/git-wrapper/test.sh`: add `assert_blocked` tests for the 6 new commands and common variants.
- Modify `README.md`: update "Fully blocked subcommands" line (269) and features list (296).
- Modify `docs/development.md`: update manual testing checklist item 6 (line 73).

---

### Task 1: Block the 6 history-bypass commands (TDD)

**Files:**
- Modify: `tests/git-wrapper/test.sh` (add new test section after line 204, before the `--- Git policy file tests ---` comment on line 206)
- Modify: `share/claude-sandboxed/git-wrapper:87`

**Interfaces:**
- Consumes: existing `assert_blocked` helper in the test file.
- Consumes: existing `block` function and `case "$subcommand"` dispatch in the wrapper.
- Produces: 6 new subcommands blocked at the same point as `push`/`reset`/`rebase`/etc.

- [ ] **Step 1: Write the failing tests**

Open `tests/git-wrapper/test.sh`. Find the line `# --- Git policy file tests ---` (around line 206). Insert this new section immediately before it:

```bash
# Task 7: history-bypass subcommands (plumbing that circumvents rebase/filter-branch blocks)
assert_blocked "git commit-tree" commit-tree
assert_blocked "git commit-tree -p deadbeef -m msg" commit-tree -p deadbeef -m msg
assert_blocked "git update-ref" update-ref
assert_blocked "git update-ref refs/heads/x deadbeef" update-ref refs/heads/x deadbeef
assert_blocked "git update-ref -d refs/heads/x" update-ref -d refs/heads/x
assert_blocked "git update-ref --force refs/heads/x deadbeef" update-ref --force refs/heads/x deadbeef
assert_blocked "git replace" replace
assert_blocked "git replace deadbeef feedface" replace deadbeef feedface
assert_blocked "git replace -d deadbeef" replace -d deadbeef
assert_blocked "git fast-import" fast-import
assert_blocked "git prune" prune
assert_blocked "git prune --expire=now" prune --expire=now
assert_blocked "git symbolic-ref" symbolic-ref
assert_blocked "git symbolic-ref HEAD" symbolic-ref HEAD
assert_blocked "git symbolic-ref HEAD refs/heads/x" symbolic-ref HEAD refs/heads/x
assert_blocked "git symbolic-ref -d HEAD" symbolic-ref -d HEAD

```

- [ ] **Step 2: Run the tests and verify the new ones fail**

Run: `bash tests/git-wrapper/test.sh`

Expected: 16 new `FAIL:` lines for the new tests (real git was called despite expected block), plus existing tests passing. The new tests fail because the wrapper does not yet block these subcommands.

If any new test shows `PASS` instead of `FAIL`, stop and investigate - the command may already be blocked, or the test is malformed.

- [ ] **Step 3: Implement the block in the wrapper**

Open `share/claude-sandboxed/git-wrapper`. Find line 87:

```bash
    push|reset|rebase|filter-branch|filter-repo|clean|config)
        block "git $subcommand is blocked by claude-sandboxed."
        ;;
```

Replace with:

```bash
    push|reset|rebase|filter-branch|filter-repo|clean|config|commit-tree|update-ref|replace|fast-import|prune|symbolic-ref)
        block "git $subcommand is blocked by claude-sandboxed."
        ;;
```

- [ ] **Step 4: Run the tests and verify they all pass**

Run: `bash tests/git-wrapper/test.sh`

Expected: `Results: N passed, 0 failed` (where N is the previous total plus 16). No `FAIL:` lines.

- [ ] **Step 5: Commit**

```bash
git add share/claude-sandboxed/git-wrapper tests/git-wrapper/test.sh
git commit -m "$(cat <<'EOF'
feat: block history-bypass git plumbing in wrapper

Block commit-tree, update-ref, replace, fast-import, prune, and
symbolic-ref. These are plumbing-level commands that bypass existing
rebase/filter-branch/reset blocks.
EOF
)"
```

---

### Task 2: Update README

**Files:**
- Modify: `README.md:269` (fully blocked subcommands list)
- Modify: `README.md:296` (features list)

- [ ] **Step 1: Update the "Fully blocked subcommands" line**

Open `README.md`. Find line 269:

```
**Fully blocked subcommands:** `push`, `reset`, `rebase`, `filter-branch`, `filter-repo`, `clean`, `config`.
```

Replace with:

```
**Fully blocked subcommands:** `push`, `reset`, `rebase`, `filter-branch`, `filter-repo`, `clean`, `config`, `commit-tree`, `update-ref`, `replace`, `fast-import`, `prune`, `symbolic-ref`.
```

- [ ] **Step 2: Update the features list**

Find line 296:

```
    - [x] **Git operation policy** - a wrapper script blocks destructive git operations (push, reset, rebase, clean, commit --amend, branch -D, tag -f, etc.) while allowing non-destructive and appending-only operations (commit, add, status, log, fetch, merge, branch -d, tag -d, etc.)
```

Replace with:

```
    - [x] **Git operation policy** - a wrapper script blocks destructive git operations (push, reset, rebase, clean, commit --amend, branch -D, tag -f, etc.) and history-bypass plumbing (commit-tree, update-ref, replace, fast-import, prune, symbolic-ref) while allowing non-destructive and appending-only operations (commit, add, status, log, fetch, merge, branch -d, tag -d, etc.)
```

- [ ] **Step 3: Verify README renders correctly**

Run: `grep -n 'commit-tree\|update-ref\|replace\|fast-import\|prune\|symbolic-ref' README.md`

Expected: 2 lines of output (line 269 and line 296), each containing the new commands.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document history-bypass git command blocks in README"
```

---

### Task 3: Update docs/development.md

**Files:**
- Modify: `docs/development.md:73` (manual testing checklist item 6)

- [ ] **Step 1: Update manual testing checklist item 6**

Open `docs/development.md`. Find line 73:

```
6. **Git policy - blocked:** inside the container, `git push`, `git reset --hard`, `git commit --amend`, `git clean -fd`, `git rebase`, `git config --get user.name` all fail with `[SECURITY]` messages.
```

Replace with:

```
6. **Git policy - blocked:** inside the container, `git push`, `git reset --hard`, `git commit --amend`, `git clean -fd`, `git rebase`, `git config --get user.name`, `git commit-tree`, `git update-ref` all fail with `[SECURITY]` messages.
```

- [ ] **Step 2: Commit**

```bash
git add docs/development.md
git commit -m "docs: add history-bypass commands to manual testing checklist"
```

---

### Task 4: Final verification

**Files:** (none - verification only)

- [ ] **Step 1: Run the full test suite**

Run: `bash tests/run-all.sh`

Expected: All test suites pass (`tests/git-wrapper`, `tests/config`, `tests/launcher`). No `FAIL:` lines.

- [ ] **Step 2: Verify the wrapper blocks all 6 commands**

Run this smoke test directly:

```bash
for cmd in commit-tree update-ref replace fast-import prune symbolic-ref; do
    REAL_GIT=/usr/bin/git share/claude-sandboxed/git-wrapper "$cmd" 2>&1 | grep -q "\[SECURITY\]" && echo "OK: $cmd blocked" || echo "FAIL: $cmd not blocked"
done
```

Expected: 6 lines of `OK: <cmd> blocked`.

- [ ] **Step 3: Verify no regressions in allowed commands**

Run:

```bash
REAL_GIT=/usr/bin/git share/claude-sandboxed/git-wrapper status >/dev/null 2>&1 && echo "OK: status allowed" || echo "FAIL: status blocked"
REAL_GIT=/usr/bin/git share/claude-sandboxed/git-wrapper log >/dev/null 2>&1 && echo "OK: log allowed" || echo "FAIL: log blocked"
REAL_GIT=/usr/bin/git share/claude-sandboxed/git-wrapper branch -d feature 2>&1 | grep -q "\[SECURITY\]" && echo "FAIL: branch -d blocked" || echo "OK: branch -d allowed"
```

Expected: `OK: status allowed`, `OK: log allowed`, `OK: branch -d allowed`.

- [ ] **Step 4: Verify clean git status**

Run: `git status`

Expected: clean working tree (all changes committed), no untracked files except `.claude-sandboxed.yaml` (which predates this work).

If there are uncommitted changes, commit them or investigate before declaring done.
