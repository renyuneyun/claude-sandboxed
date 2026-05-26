# How it works

## Overview

1. The launcher script starts a Docker Compose service (`ai-agent`) in the background.
2. It `exec`s into the running container and launches Claude Code with `--dangerously-skip-permissions`.
3. The container entrypoint configures git globally to block all remote pushes before Claude starts.
4. On exit, the container keeps running so subsequent invocations are fast.

Claude Code can be granted `--dangerously-skip-permissions` to operate fully autonomously. Running it inside a container limits the blast radius: it can freely read and write the mounted workspace, but cannot touch the rest of the host filesystem and cannot push to remote repositories.

## Volume layout

| Mount | Container path | Purpose |
|---|---|---|
| Workspace arg (or `$PWD`) | `/workspace` | The project Claude works on |
| Named volume `claude-agent-home` | `/root` | Persists npm cache, global tools, shell history across runs |
| `~/.claude` (host) | `/root/.claude` | Pass-through for Claude credentials |

## Git push protection

The container entrypoint sets these git globals before Claude starts:

- `core.sshCommand` → prints a security warning and exits non-zero (blocks SSH-based pushes)
- `url.'https://prohibited/'.insteadOf 'https://github.com/'` → redirects HTTPS GitHub URLs
- `url.'https://prohibited/'.insteadOf 'git@github.com:'` → redirects SSH GitHub URLs

Claude can still commit locally; it simply cannot push to any remote.
