# claude-sandboxed

Runs [Claude Code](https://github.com/anthropics/claude-code) inside a Docker sandbox with a shared workspace mount and git push protection.

The main rationale of this project is to run Claude Code in autonomous mode (with `--dangerously-skip-permissions`) more safely, reducing harms to the user's machine / files. Whitebox protection is the main design, to provide deterministic guarantees (contrary to Anthrophic's probabilistic classifier).

> To be fully transparent: the whitebox protection is not always useful for every case, as it would be too complicated. But I'd prefer it because that provides accountability, something that probabilistic classifiers will not have.
> "What can go wrong will go wrong."

## Requirements

- Docker with the Compose plugin (`docker compose`)
- A valid Claude Code session or configuration using external APIs (`~/.claude` credentials)

## Installation

You may directly run `bin/claude-sandboxed`, but it may change. Proper installation is always preferred.

### Arch Linux

```sh
git clone <repo-url>
cd claude-sandboxed/packaging
makepkg -si
```

### Any Unix (macOS, WSL, Linux) (To be tested)

```sh
git clone <repo-url>
cd claude-sandboxed
sudo ./install.sh
```

Installs to `/usr/local` by default. Override with `PREFIX`:

```sh
PREFIX=~/.local ./install.sh   # no sudo needed here
```

Any standard `<prefix>/bin` + `<prefix>/share` layout works (Homebrew `/opt/homebrew`, `/usr/local`, `~/.local`, etc.).

## Usage

```sh
# Sandbox the current directory
claude-sandboxed

# Sandbox a specific directory
claude-sandboxed ~/projects/my-app
```

Set `CLAUDE_SANDBOXED_DIR` to override the directory containing `docker-compose.yml`.

Set `CLAUDE_VERSION` to pin a specific Claude Code version inside the container (e.g. `CLAUDE_VERSION=2.1.152`). Defaults to the version installed on the host.

## Customization

### User identity

By default the launcher mirrors your host identity into the container so that files created inside are owned by you outside:

| Variable | Default | Description |
|---|---|---|
| `SANDBOX_UID` | `$(id -u)` | UID used inside the container |
| `SANDBOX_GID` | `$(id -g)` | GID used inside the container |
| `SANDBOX_USERNAME` | `$(id -un)` | Username created inside the container |
| `SANDBOX_HOME` | `/home/$SANDBOX_USERNAME` | Home directory path inside the container |

Override any of them before invoking the script:

```sh
SANDBOX_UID=4444 SANDBOX_GID=4444 SANDBOX_USERNAME=ryey claude-sandboxed
```

When `SANDBOX_UID=0`, the container runs as root and the user-creation step is skipped.

### Authentication

Claude Code uses credentials from `~/.claude` and `~/.claude.json`, which are bind-mounted from the host (read/write).

If `ANTHROPIC_API_KEY` is set in your environment it is passed into the container automatically, avoiding keyring re-authentication inside the sandbox.

### Git policy

Inside the sandbox, `git` is a wrapper script that blocks destructive operations and allows non-destructive / appending-only ones. Blocked operations print `[SECURITY] ...` to stderr and exit non-zero.

**Fully blocked subcommands:** `push`, `reset`, `rebase`, `filter-branch`, `filter-repo`, `clean`, `config`.

**Conditionally blocked subcommands:** `reflog expire|delete`, `notes remove|prune`, `worktree remove|prune`, `stash drop|clear`, `branch -d|-D|--delete`, `tag -d|--delete|-f|--force`.

**Flag-level blocks on allowed subcommands:**

| Subcommand | Blocked flags |
|---|---|
| `commit` | `--amend`, `--reset-author` |
| `checkout` | `-B`, `-f`, `--force`, `-- <pathspec>` |
| `switch` | `-C`, `--discard-changes` |
| `restore` | `--worktree`, `-W` |
| `rm` | (without `--cached`) |
| `gc` | `--prune` |

`git config` is blocked entirely (including reads) because allowing `git config --local` writes would let Claude define an alias like `alias.x = !/usr/bin/git push` that bypasses the wrapper. Use `cat ~/.gitconfig` or `cat .git/config` to read config.

**Known limitations:**
- The wrapper is a soft barrier. Calling `/usr/bin/git` by absolute path bypasses it. This is consistent with the project's threat model (accidental damage, not adversarial resistance).
- The wrapper does not strip `-c` flags or `GIT_CONFIG_*` env vars. A command like `git -c alias.x='!/usr/bin/git push' x` would bypass the push block. This is acceptable because push is also blocked by system git config (defense in depth), and the threat model is non-adversarial.
- Long-flag abbreviations (e.g., `--forc` for `--force`) bypass flag-level checks in subcommands that use exact-match patterns (`commit`, `tag`, `branch`, `checkout`, `restore`). The `rm` and `gc` cases use prefix matching and are not affected. Claude uses full flag names in practice, so this is a low-risk gap.

## Features

- [x] **Sandboxed execution** — confines Claude Code to the target workspace, protecting the rest of your system from unintended changes
    - [x] **Workspace isolation** — only the target project directory is mounted; the rest of the host filesystem is unreachable inside the container
    - [x] **Isolated environment and cache** — packages and global tools install into a persistent container volume, never touching the host
    - [x] **Git operation policy** — a wrapper script blocks destructive git operations (push, reset, rebase, clean, commit --amend, branch -D, tag -f, etc.) while allowing non-destructive and appending-only operations (commit, add, status, log, fetch, merge, branch -d, tag -d, etc.)
    - [x] **Git config inheritance** — the host user's `~/.gitconfig` and `~/.config/git/` are bind-mounted read-only so Claude commits with the host user's identity
    - [ ] **Sandbox information** — Allow the runtime (Claude Code, e.g.) to see that it's in the sandbox rather than on host system (later configurable)
- [x] **Transparent isolation** — the sandbox boundary is invisible to Claude Code: it sees the same user identity, credentials, paths, and Claude settings as on the host, while the rest of the system stays out of reach
    - [x] **Claude config passthrough** — the entire `~/.claude` directory (credentials, skills, settings, etc.) and `ANTHROPIC_API_KEY` are forwarded automatically
    - [x] **Host identity mirroring** — Claude Code runs as your host user (same UID, GID, username, and home path), so file ownership is consistent
    - [x] **Host network access** — the container shares the host network, so host-local services are reachable from inside (e.g. a proxy at `127.0.0.1:1080`, or a network-based MCP server running on the host)
    - [x] **Automatic cleanup** — the container is removed on exit
    - [ ] **Safe passthrough** — safely passthrough files and folders between host and sandbox, such as package caches
- [x] **Parallel sessions** — each invocation runs as an independent one-shot container, so multiple sandboxed sessions can run concurrently
- [x] **Pinnable Claude version** — set `CLAUDE_VERSION` to lock a specific Claude Code release inside the container
- [ ] **Automated tests**
- [ ] **Customiztion** — set preferences through config files (with docs and examples)
    - [ ] All isolation designs should be customizable
    - [ ] Git operation policy
    - [ ] Git config
- [ ] **Alternative Claude config and env** — use a dedicated config path for Claude Code for better isolation
- [ ] **Network isolation** — container has its own network, isolated from the host
- [ ] **More tools** — support more tools / coding agents apart from Claude Code
- [ ] **More runtimes** — support other runtimes than Docker

## Testing

Automated tests live in `tests/`. Run all tests from the repo root:

```sh
bash tests/run-all.sh
```

Each subdirectory of `tests/` contains a `test.sh` script for one component. The runner discovers and executes all of them. Tests run on the host (no Docker required) — the git wrapper tests use a stubbed real git binary.

## Further reading

- [docs/architecture.md](docs/architecture.md) — architecture, volumes, security model
- [docs/tradeoffs.md](docs/tradeoffs.md) — design decisions: privilege dropping, network isolation, and alternatives
- [docs/development.md](docs/development.md) — invariants, resolution logic, PKGBUILD notes, test checklist
