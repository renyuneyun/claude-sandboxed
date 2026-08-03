# Git Wrapper Bypass Hint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the git wrapper's `block()` function with guidance text that tells the AI agent not to bypass the wrapper, to reconsider whether the operation is genuinely needed, and to avoid asking the user for individual operation authorization.

**Architecture:** Modify the single `block()` function in `share/claude-sandboxed/git-wrapper` - every blocked command flows through it, so one change applies to all blocks. Add one test verifying the guidance keywords appear in stderr. Update README with a note about the guidance.

**Tech Stack:** Bash, existing shell test harness (`tests/git-wrapper/test.sh`).

## Global Constraints

- Do not reveal bypass paths (`/usr/bin/git`, git aliases, `-c` config) in the message - mentioning them teaches the agent how to bypass.
- Do not ask the agent to "find alternative commands" - the message prompts reconsideration of the operation, not a search for workarounds.
- Do not encourage asking the user for individual operation authorization - the sandbox is for autonomous work.
- The set of blocked commands is unchanged. Only the block message changes.
- Do not change the user policy file contract, the wrapper's argument parsing, or any other logic.
- `packaging/pkg/` is an untracked build artifact - do not modify it.

---

## File Structure

- Modify `share/claude-sandboxed/git-wrapper`: extend the `block()` function (lines 48-51) with three guidance echo lines.
- Modify `tests/git-wrapper/test.sh`: add one test verifying the guidance keywords appear in stderr. Place at the end of the `# Task 7: history-bypass subcommands` section, before the `# --- Git policy file tests ---` comment.
- Modify `README.md`: add a note after line 267 (the "Blocked operations print `[SECURITY] ...` to stderr" line) describing the guidance.

---

### Task 1: Add bypass hint to block() function (TDD)

**Files:**
- Modify: `tests/git-wrapper/test.sh` (add new test section after the Task 7 section, before `# --- Git policy file tests ---`)
- Modify: `share/claude-sandboxed/git-wrapper:48-51`

- [ ] **Step 1: Write the failing test**

Open `tests/git-wrapper/test.sh`. Find the `# --- Git policy file tests ---` line (around line 223 after the Task 7 section was added in the previous feature). Insert this new section immediately before it:

```bash
# Task 8: block message includes bypass guidance
err="$(REAL_GIT="$STUB_DIR/git" "$WRAPPER" push 2>&1 >/dev/null)"
if [[ "$err" == *"Do not bypass"* && "$err" == *"always blocked"* && "$err" == *"Reconsider"* && "$err" == *"autonomous work"* ]]; then
    echo "PASS: block message includes bypass guidance"
    pass=$((pass+1))
else
    echo "FAIL: block message missing bypass guidance (got: $err)"
    fail=$((fail+1))
fi

```

- [ ] **Step 2: Run the tests and verify the new one fails**

Run: `bash tests/git-wrapper/test.sh`

Expected: One new `FAIL:` line: `FAIL: block message missing bypass guidance (got: ...)`. All other tests pass. The new test fails because the current `block()` function only emits one `[SECURITY]` line without the guidance keywords.

If any other test fails, stop and investigate - something unrelated is broken.

- [ ] **Step 3: Implement the block() function change**

Open `share/claude-sandboxed/git-wrapper`. Find the `block()` function (lines 48-51):

```bash
block() {
    echo "[SECURITY] $1" >&2
    exit 1
}
```

Replace with:

```bash
block() {
    echo "[SECURITY] $1" >&2
    echo "[SECURITY] This is intentional. Do not bypass it. git push is always blocked; other destructive operations are generally prohibited." >&2
    echo "[SECURITY] Reconsider whether the underlying operation is genuinely needed and aligns with the user's intent, rather than the specific command you attempted." >&2
    echo "[SECURITY] The sandbox is for autonomous work. Do not ask the user to authorize individual operations; escalate only as a last resort if no in-sandbox approach exists." >&2
    exit 1
}
```

- [ ] **Step 4: Run the tests and verify they all pass**

Run: `bash tests/git-wrapper/test.sh`

Expected: `Results: N passed, 0 failed` (where N is the previous total plus 1). The new test `PASS: block message includes bypass guidance` appears, and no existing tests regress - they check for `[SECURITY]` in stderr, which is still present (now on four lines instead of one).

- [ ] **Step 5: Commit**

```bash
git add share/claude-sandboxed/git-wrapper tests/git-wrapper/test.sh
git commit -m "$(cat <<'EOF'
feat: add bypass hint to git wrapper block messages

Extend block() with guidance: the restriction is intentional, do not
bypass it, reconsider whether the operation is genuinely needed, and
do not ask the user to authorize individual operations.
EOF
)"
```

---

### Task 2: Update README

**Files:**
- Modify: `README.md` (add note after line 267)

- [ ] **Step 1: Add the guidance note**

Open `README.md`. Find line 267:

```
Inside the sandbox, `git` is a wrapper script that blocks destructive operations and allows non-destructive / appending-only ones. Blocked operations print `[SECURITY] ...` to stderr and exit non-zero.
```

Insert this new paragraph immediately after it (and before the existing `**Fully blocked subcommands:**` line):

```
Block messages include guidance for the AI agent: the restriction is intentional and must not be bypassed. `git push` is always blocked; other destructive operations are generally prohibited. The agent is prompted to reconsider whether the underlying operation is genuinely needed and aligns with the user's intent, rather than asking the user to authorize individual operations.
```

- [ ] **Step 2: Verify the note renders correctly**

Run: `grep -n 'Block messages include guidance' README.md`

Expected: One line of output showing the new note.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document git wrapper bypass hint in README"
```

---

### Task 3: Final verification

**Files:** (none - verification only)

- [ ] **Step 1: Run the full test suite**

Run: `bash tests/run-all.sh`

Expected: All test suites pass (`tests/git-wrapper`, `tests/config`, `tests/launcher`). No `FAIL:` lines.

- [ ] **Step 2: Smoke test the guidance appears on a blocked command**

Run:

```bash
REAL_GIT=/usr/bin/git share/claude-sandboxed/git-wrapper push 2>&1 | head -4
```

Expected: four lines of output, each starting with `[SECURITY]`:
1. `git push is blocked by claude-sandboxed.`
2. `This is intentional. Do not bypass it. git push is always blocked; other destructive operations are generally prohibited.`
3. `Reconsider whether the underlying operation is genuinely needed and aligns with the user's intent, rather than the specific command you attempted.`
4. `The sandbox is for autonomous work. Do not ask the user to authorize individual operations; escalate only as a last resort if no in-sandbox approach exists.`

- [ ] **Step 3: Verify no regressions in allowed commands**

Run:

```bash
REAL_GIT=/usr/bin/git share/claude-sandboxed/git-wrapper status >/dev/null 2>&1 && echo "OK: status allowed" || echo "FAIL: status blocked"
REAL_GIT=/usr/bin/git share/claude-sandboxed/git-wrapper log >/dev/null 2>&1 && echo "OK: log allowed" || echo "FAIL: log blocked"
```

Expected: `OK: status allowed`, `OK: log allowed`. Allowed commands do not trigger `block()` and should be unaffected.

- [ ] **Step 4: Verify clean git status**

Run: `git status`

Expected: clean working tree (all changes committed). The only untracked file should be `.claude-sandboxed.yaml` (which predates this work).
