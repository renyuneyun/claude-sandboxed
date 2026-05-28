# claude-sandboxed

Runs [Claude Code](https://github.com/anthropics/claude-code) inside a Docker sandbox with a shared workspace mount and git push protection.

## Requirements

- Docker with the Compose plugin (`docker compose`)
- A valid Claude Code session (`~/.claude` credentials)

## Installation

### Arch Linux

```sh
git clone <repo-url>
cd claude-sandboxed/packaging
makepkg -si
```

### Any Unix (macOS, WSL, Linux)

```sh
git clone <repo-url>
cd claude-sandboxed
sudo ./install.sh
```

Installs to `/usr/local` by default. Override with `PREFIX`:

```sh
PREFIX=~/.local ./install.sh   # no sudo needed
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

## User identity

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

## Further reading

- [docs/architecture.md](docs/architecture.md) — architecture, volumes, security model
- [docs/tradeoffs.md](docs/tradeoffs.md) — design decisions: privilege dropping, network isolation, and alternatives
- [docs/development.md](docs/development.md) — invariants, resolution logic, PKGBUILD notes, test checklist
