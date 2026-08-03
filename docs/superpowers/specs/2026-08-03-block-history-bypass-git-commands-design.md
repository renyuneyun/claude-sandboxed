# Block History-Bypass Git Commands

**Date:** 2026-08-03
**Status:** Approved, pending implementation
**Scope:** Extend the git wrapper blocklist to cover plumbing commands that could circumvent existing history-manipulation blocks.

## Goal

Close bypass paths in the git wrapper. The wrapper currently blocks `rebase`, `filter-branch`, `filter-repo`, and `reset` (entirely), plus force/delete forms of `commit`, `branch`, `tag`, `checkout`, `switch`, `restore`, `stash`, `reflog`, `notes`, `worktree`, `rm`, and `gc`. Several plumbing-level subcommands are not blocked but can achieve equivalent history rewriting or object deletion. This change blocks them.

## Non-goals

- Blocking object-creation plumbing that cannot rewrite history on its own (e.g., `hash-object`, `write-tree`, `mktree`, `mktag`). These become harmless once `commit-tree` and `update-ref` are blocked, since they cannot move refs or create commits.
- Blocking `fast-export` (read-only export, no mutation).
- Blocking `fetch` / `pull` / `clone` (already subject to remote-side history; not a local bypass).
- Changing the user policy file contract or the safe-by-design policy for existing commands.
- Adding new dependencies.

## Commands to block (entirely)

| Command | Why it bypasses existing blocks |
|---|---|
| `commit-tree` | Creates commit objects directly from a tree and parent(s); forges arbitrary history without `rebase` or `filter-branch`. |
| `update-ref` | Moves or deletes refs. The "safe" form (without `-f`) still allows moving a ref to any commit (including an ancestor), which is equivalent to `git reset --hard <commit>` on that ref. |
| `replace` | Creates `refs/replace/<sha>` refs that substitute one object for another. Even the safe form (no `-f`, no `-d`) rewrites apparent history by overriding commit objects. |
| `fast-import` | Bulk-imports history from a stream. Constructs arbitrary commits and refs. |
| `prune` | Deletes unreachable objects. Direct parallel to `git gc --prune`, which is already blocked. |
| `symbolic-ref` | Mutates the HEAD pointer (or other symbolic refs) directly, bypassing `checkout` / `switch` safety checks. Also can delete symbolic refs with `-d`. |

## Why block entirely (not force-form distinction)

The existing safe-by-design policy (see `feedback_git_wrapper_policy.md` in user memory) says: allow operations that git itself protects against data loss (e.g., `branch -d` refuses to delete unmerged branches); block only the force variant.

These 6 commands have no git-protected safe form:

- `commit-tree` is a plumbing command. Git does what you ask; no protection.
- `update-ref` does not enforce fast-forward. Without `-f` it only checks the expected old value - it does not prevent moving a ref backwards. There is no "safe form" to preserve.
- `replace` without `-f` / `-d` still creates a replacement ref that overrides a commit object. The "safe" creation is itself history rewriting.
- `fast-import` has no protected form.
- `prune` has no protected form.
- `symbolic-ref` write form bypasses `checkout` safety. The read form (`git symbolic-ref HEAD`) is read-only and safe, but does not follow the `branch -d` pattern (a destructive op that git refuses in the dangerous variant); it is simply a non-destructive read. Per the user's criterion, since the safe form does not follow the `branch -d` pattern and `symbolic-ref` is rarely used by regular operations (the agent has alternatives like `git branch --show-current`), block entirely.

## Implementation

### `share/claude-sandboxed/git-wrapper`

Extend the fully-blocked case branch (currently line 87) to include the 6 new subcommands:

```bash
push|reset|rebase|filter-branch|filter-repo|clean|config|commit-tree|update-ref|replace|fast-import|prune|symbolic-ref)
    block "git $subcommand is blocked by claude-sandboxed."
    ;;
```

No new conditional logic is needed. All 6 are blocked unconditionally, like `push` and `rebase`.

### `tests/git-wrapper/test.sh`

Add `assert_blocked` tests for each new command, including common variants:

- `git commit-tree`
- `git commit-tree -p <sha> -m msg`
- `git update-ref`
- `git update-ref refs/heads/x <sha>`
- `git update-ref -d refs/heads/x`
- `git update-ref --force refs/heads/x <sha>`
- `git replace`
- `git replace <sha> <sha>`
- `git replace -d <sha>`
- `git fast-import`
- `git prune`
- `git prune --expire=now`
- `git symbolic-ref`
- `git symbolic-ref HEAD`
- `git symbolic-ref HEAD refs/heads/x`
- `git symbolic-ref -d HEAD`

(Placeholders like `<sha>` in tests use literal strings such as `deadbeef` - the wrapper blocks before git ever sees them, so they don't need to be valid hashes.)

### `README.md`

Update line 269 ("Fully blocked subcommands") to include the 6 new commands. Update line 296 (features list) to mention history-bypass plumbing.

### `docs/development.md`

Update manual testing checklist item 6 to include `git commit-tree` and `git update-ref` in the list of commands that should fail with `[SECURITY]` messages.

## What's not changing

- All existing blocks (full, conditional, and flag-level) remain unchanged.
- The user policy file (`/etc/claude-sandboxed/git-policy.conf`) still overrides defaults. An `[allow] ^commit-tree` rule would still unblock the command.
- No new dependencies.
- No changes to the docker-compose file, launcher, or install paths.

## Threat model

This is defense-in-depth against accidental damage, not adversarial resistance. The wrapper is a soft barrier - calling `/usr/bin/git` by absolute path bypasses it (already documented as a known limitation). The goal is to make history-rewriting require deliberate effort, so the agent doesn't accidentally rewrite history via plumbing commands that aren't in its usual vocabulary.
