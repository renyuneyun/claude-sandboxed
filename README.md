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

## Further reading

- [docs/architecture.md](docs/architecture.md) — architecture, volumes, security model
- [docs/development.md](docs/development.md) — invariants, resolution logic, PKGBUILD notes, test checklist
