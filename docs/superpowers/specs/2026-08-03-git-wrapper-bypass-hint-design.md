# Git Wrapper Bypass Hint

**Date:** 2026-08-03
**Status:** Approved, pending implementation
**Scope:** Extend the git wrapper's block message with guidance telling the AI agent not to bypass the wrapper and to reconsider whether the operation is genuinely needed and aligns with the user's intent.

## Goal

Reduce accidental bypasses of the git wrapper. The wrapper is a soft barrier - calling `/usr/bin/git` by absolute path, using `git -c alias.x='!...'`, or similar tricks bypass it. The current block message (`[SECURITY] git <cmd> is blocked by claude-sandboxed.`) doesn't explain that the block is intentional or what the agent should do instead. An agent that doesn't understand the boundary might "helpfully" work around the block.

The fix is to extend the block message with guidance: this is intentional, don't bypass it, and reconsider whether the underlying operation is genuinely needed and aligns with the user's intent. This applies to every blocked operation - push, reset, rebase, commit-tree, update-ref, branch -D, tag -f, stash drop, etc. - not just one specific command.

The sandbox is designed for autonomous operation. The message should not encourage the agent to ask the user to authorize individual operations - that is an anti-pattern, because it blocks the task, which is rarely what the user wants. The agent should work within the sandbox's constraints and only escalate to the user as a last resort.

## Non-goals

- Proactive system-prompt injection (Approach B from brainstorming). The reactive block message is sufficient for now; proactive injection can be added later as a follow-up if needed.
- Per-operation authorization mechanism. The hint is advisory - the user still authorizes by running the command on the host or by editing the policy file. No new unlock flow.
- Encouraging the agent to ask the user for individual operation authorization. The sandbox is for autonomous work; the message prompts the agent to reconsider whether the operation is needed, not to escalate to the user.
- Revealing bypass paths (e.g., `/usr/bin/git`, git aliases, `-c` config). Mentioning them teaches the agent how to bypass.
- Asking the agent to "find alternative commands." The message prompts reconsideration of the operation, not a search for workaround commands.
- Tool-specific hints. The message is tool-agnostic and works the same for Claude Code and Codex.
- Changing what is blocked. The set of blocked commands is unchanged.

## Implementation

### `share/claude-sandboxed/git-wrapper`

Modify the `block()` function (currently lines 48-51). Current:

```bash
block() {
    echo "[SECURITY] $1" >&2
    exit 1
}
```

New:

```bash
block() {
    echo "[SECURITY] $1" >&2
    echo "[SECURITY] This is intentional. Do not bypass it. git push is always blocked; other destructive operations are generally prohibited." >&2
    echo "[SECURITY] Reconsider whether the underlying operation is genuinely needed and aligns with the user's intent, rather than the specific command you attempted." >&2
    echo "[SECURITY] The sandbox is for autonomous work. Do not ask the user to authorize individual operations; escalate only as a last resort if no in-sandbox approach exists." >&2
    exit 1
}
```

Call sites are unchanged. Every `block "git <cmd> is blocked by claude-sandboxed."` call now produces four lines of stderr: the original block notice, the policy (intentional + what's blocked), the reconsideration prompt, and the autonomy/escalation guidance.

**Why four echo lines instead of one long line:** each line starts with `[SECURITY]` so any tool or script that greps for the prefix catches all of them. Multi-line output is also more readable in a terminal than a single wrapped line. Each line has one clear purpose (block notice / policy / reconsider / escalation), so the agent can parse them independently.

**Why bypass paths are not listed:** mentioning `/usr/bin/git`, git aliases, or `-c` config - even to say "don't use them" - teaches the agent those paths exist. The message says "do not bypass" without revealing how.

**Why the message prompts reconsideration rather than suggesting alternatives:** the goal is for the agent to step back and ask whether the operation itself is needed and matches user intent, not to search for workaround commands. Suggesting alternatives would keep the agent in "find a command that works" mode.

### `tests/git-wrapper/test.sh`

Add one test verifying the guidance text appears in stderr. Place it near the end of the `# Task 7: history-bypass subcommands` section (before the `# --- Git policy file tests ---` line):

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

The existing `assert_blocked` tests continue to pass - they check for `[SECURITY]` in stderr, which is still present (now on four lines instead of one).

### `README.md`

Update the "Git policy" section. After the line that describes blocked operations printing `[SECURITY] ...` to stderr (line 267), add a note:

```
Block messages include guidance for the AI agent: the restriction is intentional and must not be bypassed. `git push` is always blocked; other destructive operations are generally prohibited. The agent is prompted to reconsider whether the underlying operation is genuinely needed and aligns with the user's intent, rather than asking the user to authorize individual operations.
```

This sets expectations for users reading the README too - they know the agent will be told about the boundary.

### `docs/development.md`

No change needed. The manual testing checklist already verifies blocked commands fail with `[SECURITY]` messages; the guidance text is an extension of that message, not a separate behavior.

## What's not changing

- The set of blocked commands (fully blocked, conditionally blocked, and flag-level blocked).
- The user policy file contract.
- The wrapper's argument parsing or any other logic.
- The launcher, docker-compose file, or install paths.
- No new dependencies.

## Threat model

This is defense-in-depth against accidental damage, consistent with the existing threat model. The hint is advisory - an agent determined to bypass will still find ways. The goal is to make the agent understand the boundary is intentional and reconsider whether the operation is genuinely needed, so it doesn't bypass out of confusion or a desire to "fix" the block. The guidance preserves autonomous operation; escalation to the user is a last resort, not the default.
