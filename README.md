# claude-sandboxed

Runs Claude Code or Codex CLI inside a Docker sandbox with a shared workspace mount and git push protection. The package and command remain named `claude-sandboxed`; renaming is deferred.

The main rationale of this project is to run Claude Code in autonomous mode (with `--dangerously-skip-permissions`) more safely, reducing harms to the user's machine / files. Whitebox protection is the main design, to provide deterministic guarantees (contrary to Anthrophic's probabilistic classifier).

> To be fully transparent: the whitebox protection is not always useful for every case, as it would be too complicated. But I'd prefer it because that provides accountability, something that probabilistic classifiers will not have.
> "What can go wrong will go wrong."

## Requirements

- Docker with the Compose plugin (`docker compose`)
- A valid session or API key for the selected tool (`~/.claude` / `ANTHROPIC_API_KEY`, or `~/.codex` / `OPENAI_API_KEY`)
- `yq` (only if using config files - see [Configuration](#configuration))

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
claude-sandboxed
claude-sandboxed --tool codex
claude-sandboxed --tool codex ~/projects/my-app
claude-sandboxed --tool codex ~/projects/my-app -- --model gpt-5.4
claude-sandboxed ~/projects/my-app -- --resume
```

Claude is the default. Tool selection precedence is CLI `--tool` > `SANDBOX_TOOL` > workspace `tool` > user `tool` > Claude. Arguments after `--` are passed unchanged to the selected tool.

Set `CLAUDE_SANDBOXED_DIR` to override the directory containing `docker-compose.yml`.

Set `CLAUDE_VERSION` or `CODEX_VERSION` to pin the selected tool version inside the container. Each defaults to the corresponding host CLI version, or npm's latest when that CLI is not installed.

## Customization

### Configuration

Identity knobs can be set persistently via YAML config files instead of env vars. Two files are read, in priority order:

| File | Purpose |
|---|---|
| `$WORKSPACE_DIR/.claude-sandboxed.yaml` | Per-project override |
| `${XDG_CONFIG_HOME:-~/.config}/claude-sandboxed/config.yaml` | User defaults |

Both files are optional. Precedence per knob: env var > workspace config > user config > built-in default.

A commented template is installed at `<prefix>/share/claude-sandboxed/config.example.yaml` (e.g. `/usr/local/share/claude-sandboxed/config.example.yaml`). Copy it to get started:

```sh
mkdir -p ~/.config/claude-sandboxed
cp /usr/local/share/claude-sandboxed/config.example.yaml ~/.config/claude-sandboxed/config.yaml
```

Edit the copy, uncommenting the lines you want to change. All fields are commented out by default, so the copied file has no effect until you edit it.

Schema (all fields optional):

```yaml
tool: codex                       # claude or codex; default: claude

claude:
  version: "2.1.152"            # string,  default: host's claude version
  config_passthrough: true      # bool,    default: true
  config_dir: ~/.claude         # string,  default: ~/.claude
  config_file: ~/.claude.json   # string,  default: ~/.claude.json

codex:
  version: "1.2.3"              # string,  default: host's codex version
  config_passthrough: true      # bool,    default: true
  config_dir: ~/.codex          # string,  default: ~/.codex

sandbox:
  uid: 1000          # integer, default: $(id -u)
  gid: 1000          # integer, default: $(id -g)
  username: ryey     # string,  default: $(id -un)
  home: /home/ryey   # string,  default: /home/$username
  cleanup: true      # bool,    default: true

git:
  identity:
    name: claude-bot     # string,  default: "" (not set - inherit)
    email: bot@example.com  # string,  default: "" (not set)
  host_config_passthrough: true  # bool, default: true
  policy:
    allow:              # list of regex (ERE), default: empty
      - "^reset"
      - "^commit --amend"
    block:              # list of regex (ERE), default: empty
      - "^stash pop"
```

Example `~/.config/claude-sandboxed/config.yaml`:

```yaml
sandbox:
  username: claude-bot
  home: /home/claude-bot
```

Requires `yq` on the host. Either implementation works:
- **mikefarah's Go `yq`** - `go-yq` on Arch, `brew install yq` on macOS, or [download the binary](https://github.com/mikefarah/yq/releases)
- **kislyuk's Python `yq`** - `yq` on Arch, `pip install yq`

If `yq` is not installed, config files are ignored and env vars / defaults are used instead. A warning is printed to stderr when a config file exists but `yq` is missing. Malformed YAML files are also skipped with a warning.

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

### Git identity

Two knobs control git identity inside the sandbox:

| Knob | Default | Description |
|---|---|---|
| `git.identity.name` | `""` (unset) | Overrides `user.name` via `GIT_AUTHOR_NAME` / `GIT_COMMITTER_NAME` env vars |
| `git.identity.email` | `""` (unset) | Overrides `user.email` via `GIT_AUTHOR_EMAIL` / `GIT_COMMITTER_EMAIL` env vars |
| `git.host_config_passthrough` | `true` | When `false`, host `~/.gitconfig` and `~/.config/git/` are not mounted |

Env var overrides: `SANDBOX_GIT_IDENTITY_NAME`, `SANDBOX_GIT_IDENTITY_EMAIL`, `SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH`. Same precedence as identity knobs: env > workspace config > user config > default.

**How identity is applied:** when `git.identity.name` is set, the launcher passes `-e GIT_AUTHOR_NAME=...` and `-e GIT_COMMITTER_NAME=...` to `docker compose run` (same for email). Git's env-var precedence is above any config file, so the override takes effect regardless of whether host `~/.gitconfig` is mounted.

**Combinations:**

| `identity` | `host_config_passthrough` | Behavior |
|---|---|---|
| unset | `true` (default) | Host git identity inherited via `~/.gitconfig` (current behavior). |
| unset | `false` | No git identity in sandbox. `git commit` fails with "Please tell me who you are". |
| set | `true` (default) | Host config mounted, commit authorship overridden by env vars. |
| set | `false` | Clean slate: only sandbox identity applies. |

**Caveat:** `git config user.name` (the command) only reads config files - it ignores the env vars. So when passthrough is on and identity is overridden, `git config user.name` still prints the host's value. Commits are still authored correctly. `git var GIT_AUTHOR_IDENT` is the one git command that does respect the env vars.

### Tool versions

Pin a specific Claude Code version via config instead of the `CLAUDE_VERSION` env var:

```yaml
claude:
  version: "2.1.152"
```

Same precedence as other knobs: env var > workspace config > user config > host's installed version.

Codex mirrors this with `codex.version` and `CODEX_VERSION`:

```yaml
codex:
  version: "1.2.3"
```

### Claude config passthrough

By default, the host's `~/.claude` directory and `~/.claude.json` are mounted into the container so Claude Code has credentials, skills, and settings. Disable this for a more isolated environment:

```yaml
claude:
  config_passthrough: false
```

When disabled, Claude Code runs without host credentials. Set `ANTHROPIC_API_KEY` in your environment to authenticate without `~/.claude`. This is useful for running Claude with a clean slate - no host skills, no host settings, no host session history.

You can also point at custom host paths instead of the defaults:

```yaml
claude:
  config_dir: /shared/claude-config        # default: ~/.claude
  config_file: /shared/claude-config.json  # default: ~/.claude.json
```

The container-side path is always `${SANDBOX_HOME}/.claude` and `${SANDBOX_HOME}/.claude.json` (that's where Claude Code expects them); only the host-side path changes. This lets you share a dedicated Claude config across projects or use a config that differs from your host user's default.

### Codex config passthrough

Codex similarly bind-mounts the host's `~/.codex` directory read/write at `${SANDBOX_HOME}/.codex`. Disable it independently with `codex.config_passthrough: false`, or choose a custom host path with `codex.config_dir`. The matching environment overrides are `CODEX_CONFIG_PASSTHROUGH` and `CODEX_CONFIG_DIR`.

### Cleanup

The launcher runs a small `cleanup` container after the main container exits to remove empty stub directories Docker may have created inside the `claude-agent-home` volume. Disable it to skip that one quick container startup:

```yaml
sandbox:
  cleanup: false
```

Stubs are harmless (empty dirs); this is a minor optimization.

### Git policy config

The built-in git operation policy (see [Git policy](#git-policy) below) blocks destructive git operations. Customize it with regex-based allow/block lists that patch the default:

```yaml
git:
  policy:
    allow:
      - "^reset"           # allow all reset forms (--hard, --soft, etc.)
      - "^commit --amend"  # allow amend
    block:
      - "^stash pop"       # block stash pop (example)
```

Patterns are extended regex (ERE), matched against the git subcommand + args (global flags like `-C` are stripped first). Substring match by default; use `^` and `$` to anchor.

**Precedence** (first match wins):

1. User `allow` rules - if a pattern matches, the command runs even if the default would block it.
2. User `block` rules - if a pattern matches, the command is blocked even if the default allows it.
3. Built-in default policy (see list below).
4. Allowed (exec real git).

To inspect the effective policy inside the container:

```sh
cat /etc/claude-sandboxed/git-policy.conf
```

The file is only present when `git.policy` is set. When neither `allow` nor `block` is configured, the wrapper uses the built-in default policy directly.

### Authentication

Claude Code uses `~/.claude`, `~/.claude.json`, and optionally `ANTHROPIC_API_KEY`. Codex CLI uses `~/.codex` and optionally `OPENAI_API_KEY`. Existing config paths are bind-mounted read/write by default, and passthrough can be disabled independently for each profile. API keys are forwarded only when present.

### Git policy

Inside the sandbox, `git` is a wrapper script that blocks destructive operations and allows non-destructive / appending-only ones. Blocked operations print `[SECURITY] ...` to stderr and exit non-zero.

Block messages include guidance for the AI agent: the restriction is intentional and must not be bypassed. `git push` is always blocked; other destructive operations are generally prohibited. The agent is prompted to reconsider whether the underlying operation is genuinely needed and aligns with the user's intent, rather than asking the user to authorize individual operations.

**Fully blocked subcommands:** `push`, `reset`, `rebase`, `filter-branch`, `filter-repo`, `clean`, `config`, `commit-tree`, `update-ref`, `replace`, `fast-import`, `prune`, `symbolic-ref`.

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
    - [x] **Git operation policy** — a wrapper script blocks destructive git operations (push, reset, rebase, clean, commit --amend, branch -D, tag -f, etc.) and history-bypass plumbing (commit-tree, update-ref, replace, fast-import, prune, symbolic-ref) while allowing non-destructive and appending-only operations (commit, add, status, log, fetch, merge, branch -d, tag -d, etc.)
    - [x] **Git config inheritance** — the host user's `~/.gitconfig` and `~/.config/git/` are bind-mounted read-only so Claude commits with the host user's identity
    - [ ] **Sandbox information** — Allow the runtime (Claude Code, e.g.) to see that it's in the sandbox rather than on host system (later configurable)
- [x] **Transparent isolation** — the sandbox boundary is invisible to Claude Code: it sees the same user identity, credentials, paths, and Claude settings as on the host, while the rest of the system stays out of reach
    - [x] **Claude config passthrough** — the entire `~/.claude` directory (credentials, skills, settings, etc.) and `ANTHROPIC_API_KEY` are forwarded automatically
    - [x] **Host identity mirroring** — Claude Code runs as your host user (same UID, GID, username, and home path), so file ownership is consistent
    - [x] **Host network access** — the container shares the host network, so host-local services are reachable from inside (e.g. a proxy at `127.0.0.1:1080`, or a network-based MCP server running on the host)
    - [x] **Automatic cleanup** — the container is removed on exit
    - [ ] **Additional mountpoints** — Additional paths to mount into the container
        - [ ] Mechanism with manual switches
        - [ ] Automatic-sensing / Intelligent-sensing by trying to predict what might be needed (e.g. git worktree)
    - [ ] **Safe passthrough** — safely passthrough files and folders between host and sandbox, such as package caches
- [x] **Parallel sessions** — each invocation runs as an independent one-shot container, so multiple sandboxed sessions can run concurrently
- [x] **Pinnable Claude version** — set `CLAUDE_VERSION` to lock a specific Claude Code release inside the container
- [ ] **Automated tests**
- [ ] **Customization** — set preferences through config files (with docs and examples)
    - [x] **Config foundation** — YAML config loading (`yq`), env > workspace > user > default precedence, identity knobs (`sandbox_uid`/`gid`/`username`/`home`)
    - [ ] All isolation designs should be customizable
    - [x] **Git policy** — regex-based allow/block lists (`git.policy.allow` / `git.policy.block`) that patch the default wrapper policy
    - [x] **Git config** - per-sandbox identity override (`git.identity.name`/`email`) and host config passthrough toggle (`git.host_config_passthrough`)
    - [x] **Claude version** — pin Claude Code version via `claude.version`
    - [x] **Claude config passthrough** — toggle `~/.claude` mount via `claude.config_passthrough`
    - [x] **Cleanup** — toggle cleanup container via `sandbox.cleanup`
    - [ ] Additional paths
- [ ] **Alternative Claude config and env** — use a dedicated config path for Claude Code for better isolation
- [ ] **Network isolation** — container has its own network, isolated from the host
- [x] **More tools** — first-class Claude Code and Codex CLI profiles
    - [ ] Additional built-in coding agents
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
