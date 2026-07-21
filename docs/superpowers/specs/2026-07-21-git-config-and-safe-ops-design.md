# Git config inheritance and safe-operation policy

**Date:** 2026-07-21
**Status:** Approved (pending implementation)

## Goal

Let Claude Code inside the sandbox use the host user's git identity and configuration, while restricting git to non-destructive and appending-only operations. Concretely: `git commit` works, `git commit --amend` does not.

## Context

The sandbox currently sets push-blocking git system config (`core.sshCommand`, `url.insteadOf`) in the container entrypoint but does not expose the host user's `~/.gitconfig`. Claude inside the container runs as an anonymous user with no git identity, which makes commit authorship wrong and discards user aliases, signing keys, and global ignores.

The sandbox also has no command-level filter: only push is blocked (via system config, which user config can override). Operations like `git reset --hard`, `git commit --amend`, `git rebase`, `git clean`, and `git branch -D` are all available and can destroy work or rewrite history.

## Design

### 1. Git config inheritance

Bind-mount two host paths into the container as **read-only**:

| Host path | Container path | Purpose |
|---|---|---|
| `~/.gitconfig` | `$SANDBOX_HOME/.gitconfig` | User-level git config (name, email, signingkey, aliases, global ignores) |
| `~/.config/git/` | `$SANDBOX_HOME/.config/git/` | XDG git config, attributes, ignores |

Both mounts are **conditional**: if the host path does not exist, the mount is skipped. Git then falls back to defaults. This avoids Docker creating empty stub dirs on the host (the same failure mode the `cleanup` container already mitigates for `WORKSPACE_DIR` paths, but here we prevent it at the source).

Read-only prevents Claude from modifying the host's git config. The `~/.gitconfig` RO mount is also the security boundary that makes blocking `git config` (see §3) acceptable: even if Claude could run `git config --global`, the filesystem would refuse the write.

**Interaction with existing push protections.** Git config precedence is system < global, so a user's `~/.gitconfig` *could* override `core.sshCommand` set via `git config --system`. This is acceptable because (a) `git push` is blocked at the wrapper subcommand level (§2), regardless of any config override, and (b) the threat model is accidental damage by Claude, not adversarial bypass. The existing system-level push config stays as defense-in-depth.

### 2. Git wrapper script

A new file `share/claude-sandboxed/git-wrapper` (executable bash) is bind-mounted read-only to `/usr/local/bin/git` in the container. The `node:22-bookworm` image's default `PATH` has `/usr/local/bin` before `/usr/bin`, so `git` invocations hit the wrapper. The wrapper `exec`s `/usr/bin/git` for allowed commands.

Wrapper flow:

1. Receive argv.
2. Parse global flags (`-C`, `-c`, `--git-dir`, etc.) to locate the subcommand (first positional arg).
3. If no subcommand (e.g. `git --version`, `git --help`, `git` alone) - pass through.
4. Apply policy (§3).
5. On block: print `[SECURITY] <reason>` to stderr, exit 1.
6. On allow: `exec /usr/bin/git "$@"`.

The wrapper does **not** strip user-supplied `-c` flags or rewrite args. Git accepts `-c` in many positions, plus `--config-env`, `GIT_CONFIG_*` env vars, etc. - chasing all of them is a rabbit hole. The defense is that push is blocked at the subcommand level, and `~/.gitconfig` is read-only.

**Bypass via `/usr/bin/git` directly is a known limitation.** Claude (or any process inside the container) can call `/usr/bin/git` by absolute path to skip the wrapper. This is documented in `docs/tradeoffs.md` as a soft-barrier tradeoff, consistent with the project's threat model: deterministic guarantees for the common case, not adversarial resistance. The project's existing push protection has the same property (system config can be overridden).

### 3. Policy (blocklist + flag checks)

The wrapper maintains two categories: fully-blocked subcommands, and flag-level checks on allowed subcommands. Anything not matched is allowed. Reads via `git config` are not special-cased - `git config` is blocked entirely (see §3.3).

#### 3.1 Blocked subcommands

Some subcommands are blocked entirely; others are blocked only when paired with a destructive sub-subcommand (noted in the Reason column). Anything not listed here is allowed subject to §3.2 flag checks.

| Subcommand | Scope | Reason |
|---|---|---|
| `push` | Fully blocked | Remote push (already blocked by system config; wrapper makes it explicit) |
| `reset` | Fully blocked | All forms (`--soft`, `--mixed`, `--hard`) move HEAD - rewrites history |
| `rebase` | Fully blocked | Rewrites commit history |
| `filter-branch`, `filter-repo` | Fully blocked | Bulk history rewrites |
| `clean` | Fully blocked | Deletes untracked files |
| `config` | Fully blocked | Any form - see §3.3 |
| `reflog` | Blocked with `expire` or `delete` | Deletes reflog entries (`reflog show`, `reflog exists` allowed) |
| `notes` | Blocked with `remove` or `prune` | Deletes notes (`notes list`, `notes show` allowed) |
| `worktree` | Blocked with `remove` or `prune` | Removes worktrees (`worktree list`, `worktree add` allowed) |

#### 3.2 Flag-level blocks on allowed subcommands

| Subcommand | Blocked flags / forms | Reason |
|---|---|---|
| `commit` | `--amend`, `--reset-author` | Rewrites existing commit |
| `tag` | `-d`, `--delete`, `-f`, `--force` | Deletes or overwrites tag |
| `branch` | `-d`, `-D`, `--delete` | Deletes branch |
| `stash` | `drop`, `clear` sub-subcommands | Deletes stash entries (`pop` is allowed - clean-start assumption) |
| `checkout` | `-B`, `-f`, `--force`, `-- <pathspec>` | `-B` resets branch; `--` discards worktree changes |
| `restore` | `--worktree`, `-W` (with or without `--staged`) | Discards worktree changes |
| `rm` | (without `--cached`) | Deletes worktree files |
| `gc` | `--prune` | Deletes unreachable objects |

**Known gap:** `git checkout <pathspec>` (without `--`) is not caught. Distinguishing `<branch>` from `<pathspec>` requires `git rev-parse` validation per arg, which adds complexity for a rare case. Documented; users should prefer `git switch` (branches) and `git restore` (files), which have clean semantics.

#### 3.3 `git config` - blocked entirely

Allowing `git config` writes - even `--local` - opens a wrapper bypass: `git config alias.x '!/usr/bin/git push'` defines a shell alias that calls `/usr/bin/git` directly, bypassing the wrapper's push block. Other dangerous local-config writes include `core.hooksPath` (point at attacker-controlled hooks) and `core.editor` (run arbitrary command on commit).

Allowing `git config` reads is marginally useful (Claude can check identity) but has easy workarounds: `cat ~/.gitconfig` or `cat .git/config`.

**Decision: block `git config` entirely.** The read-only `~/.gitconfig` mount is the security boundary for global writes; blocking the subcommand entirely closes the alias-bypass hole and keeps the policy simple.

### 4. Files & integration

**New file:**

- `share/claude-sandboxed/git-wrapper` - executable bash. Bind-mounted RO to `/usr/local/bin/git`.

**Modified files:**

| File | Change |
|---|---|
| `share/claude-sandboxed/docker-compose.yml` | Add `${SANDBOX_COMPOSE_DIR}/git-wrapper:/usr/local/bin/git:ro` to `ai-agent.volumes`. |
| `bin/claude-sandboxed` | Export `SANDBOX_COMPOSE_DIR` for compose interpolation. Before `docker compose run`, check `~/.gitconfig` and `~/.config/git/` existence; append `-v` flags conditionally. |
| `README.md` | New "Git policy" subsection under Features: list blocked ops/flags, note `git config` is fully blocked, note `/usr/bin/git` bypass limitation. Update Features checklist. |
| `docs/architecture.md` | New "Git config inheritance" and "Git operation policy" sections. Update volume layout table. |
| `docs/tradeoffs.md` | New entry: wrapper script vs git aliases vs hooks (why wrapper). New entry: soft barrier vs hard barrier (the `/usr/bin/git` bypass). |
| `docs/development.md` | New invariants: wrapper mount must stay; `git-wrapper` must be executable; `/usr/local/bin` must precede `/usr/bin` in container `PATH`. New testing checklist items. |

### 5. Defense in depth

Two independent layers block `git push`:

1. Entrypoint sets `git config --system core.sshCommand ...` and `url.insteadOf` rules (existing).
2. Wrapper blocks `git push` at the subcommand level (new).

Either failing leaves the other working. The wrapper is the stronger layer because it cannot be overridden by user config.

## Testing plan

Add to `docs/development.md` testing checklist:

1. `git commit -m "test"` works and creates a commit with the host user's identity.
2. `git commit --amend` blocked with `[SECURITY]` message.
3. `git commit --reset-author` blocked.
4. `git push` blocked (both wrapper and system config layers).
5. `git reset --hard HEAD~1` blocked.
6. `git reset --soft HEAD~1` blocked (all `reset` forms blocked).
7. `git rebase main` blocked.
8. `git clean -fd` blocked.
9. `git branch -D feature` blocked; `git branch feature` works.
10. `git tag -d v1` blocked; `git tag v1` works.
11. `git tag -f v1` blocked.
12. `git stash drop` blocked; `git stash`, `git stash pop`, `git stash list` work.
13. `git checkout -b newbranch` works; `git checkout -B existing` blocked.
14. `git checkout -- file.txt` blocked.
15. `git restore --staged file.txt` works; `git restore --worktree file.txt` blocked.
16. `git rm --cached file.txt` works; `git rm file.txt` blocked.
17. `git config --get user.name` blocked.
18. `git config user.name "X"` blocked.
19. `git config alias.x '!/usr/bin/git push'` blocked (any `git config` is blocked).
20. `git status`, `git log`, `git add`, `git switch`, `git fetch`, `git merge`, `git cherry-pick`, `git revert` all work.
21. `which git` inside container shows `/usr/local/bin/git`.
22. Host without `~/.gitconfig`: container starts, `git` uses defaults, no error.
23. Host with `~/.gitconfig` containing `[user] name = ...`: commits inside container use that identity.
24. Host with `~/.gitconfig` containing `core.sshCommand = ...`: `git push` still blocked by wrapper.

## Out of scope

- Stripping user-supplied `-c` flags or `GIT_CONFIG_*` env vars. The `-c` surface is too broad; the wrapper relies on subcommand-level push blocking instead.
- Hard barrier against `/usr/bin/git` bypass (e.g. chmod 700 on `/usr/bin/git`, setuid wrapper). Out of scope for the non-adversarial threat model.
- Inheriting `~/.gnupg` for signed commits. Can be added later if needed.
- Inheriting `~/.git-credentials`. Push is blocked, so credential storage is unneeded.
- Per-repo `git config` writes. Blocked along with the rest of `git config`; can be revisited if a use case emerges.
- Network-level git restrictions (e.g. blocking `git fetch` from arbitrary URLs). Orthogonal to this spec.
