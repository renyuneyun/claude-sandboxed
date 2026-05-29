# CLAUDE.md

This is a sandboxed Claude Code launcher. Read `README.md` for a full description of how it works.

## Files

| File | Purpose |
|---|---|
| `bin/claude-sandboxed` | Bash launcher script |
| `share/claude-sandboxed/docker-compose.yml` | Container definition and other runtime data files |
| `packaging/PKGBUILD` | Arch Linux package recipe |
| `install.sh` | Cross-platform install script (macOS, WSL, Linux) |
| `README.md` | Full documentation |

## Rules

- Keep `README.md` up to date whenever you change behaviour, CLI interface, volumes, or install paths.
- Do not break the invariants listed in `docs/development.md`.
