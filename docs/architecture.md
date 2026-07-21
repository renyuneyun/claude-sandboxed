# How it works

## Overview

1. The launcher runs `docker compose run --rm`, starting a fresh container per invocation.
2. The container entrypoint runs as root and:
   a. Creates the target user and group (mirroring host UID/GID) if they do not already exist.
   b. Configures git system-wide to block all remote pushes.
   c. Drops to the target user via `runuser` and exec-s Claude Code.
3. The container is removed automatically on exit (`--rm`); named volumes persist across runs.
4. After the main container exits, a second one-shot `cleanup` container removes any empty stub directories that Docker created inside the `claude-agent-home` volume as mount-point parents for `WORKSPACE_DIR`. This step only runs when `WORKSPACE_DIR` is nested under `SANDBOX_HOME`.

Claude Code is granted `--dangerously-skip-permissions` to operate fully autonomously. Running it inside a container limits the blast radius: it can freely read and write the mounted workspace, but cannot touch the rest of the host filesystem and cannot push to remote repositories.

Multiple sessions can run in parallel — each invocation gets its own container. Per-user project naming (`claude-sandboxed-${SANDBOX_UID}`) keeps containers and volumes isolated on multi-user machines.

## Network isolation

**Current status: no network isolation.** The container uses `network_mode: host`, meaning it shares the host's network namespace. This was chosen for simplicity — it allows the container to access host-local services such as a proxy at `127.0.0.1:1080` without extra configuration.

Improving network isolation is a planned future goal. The current focus is on filesystem and git-level sandboxing.

## Volume layout

| Mount | Container path | Purpose |
|---|---|---|
| Workspace arg (or `$PWD`) | Same absolute path as on host | The project Claude works on |
| Named volume `claude-agent-home` | `$SANDBOX_HOME` | Persists npm cache, global tools, shell history across runs |
| `~/.claude` (host) | `$SANDBOX_HOME/.claude` | Pass-through for Claude Code config and credentials |
| `~/.claude.json` (host) | `$SANDBOX_HOME/.claude.json` | Pass-through for Claude account/session credentials |
| `~/.gitconfig` (host, if exists) | `$SANDBOX_HOME/.gitconfig` | User-level git config (identity, aliases, signing keys) — read-only |
| `~/.config/git/` (host, if exists) | `$SANDBOX_HOME/.config/git/` | XDG git config, attributes, ignores — read-only |
| `git-wrapper` (compose dir) | `/usr/local/bin/git` | Git wrapper script (policy enforcement) — read-only |

## Container environment

Two environment variables are set or forwarded inside the container:

| Variable | Source | Purpose |
|---|---|---|
| `IS_SANDBOX=1` | Hard-coded | Signals to Claude Code that it is running inside a sandbox, enabling `--dangerously-skip-permissions` |
| `ANTHROPIC_API_KEY` | Host environment (if set) | Forwarded from the host so Claude Code can authenticate via API key without keyring access |

## Root user mode

When `SANDBOX_UID=0` the entrypoint skips user and group creation and does not call `runuser` — Claude Code runs directly as root inside the container. This is mainly useful for CI environments where the container already runs as root.

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
