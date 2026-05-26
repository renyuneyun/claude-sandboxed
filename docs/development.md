# Internals

## Key invariants

These must not be broken without updating all affected documentation:

- `share/docker-compose.yml` must stay at `share/` relative to the repo root (dev-mode detection depends on it).
- The `ai-agent` service name must not change without updating every `docker compose exec` call in the script.
- `IS_SANDBOX=1` must remain set in the container environment.
- The git push-blocking entrypoint must remain.
- The three volume mounts (workspace, home cache, credential pass-through) must remain.
- `WORKSPACE_DIR` must be exported before `docker compose up` — the compose file interpolates it.
- The compose file resolution order must not be reordered without updating the section below.

## Compose file location resolution

Priority order (first match wins), implemented in `bin/claude-sandboxed`:

1. `$CLAUDE_SANDBOXED_DIR` — explicit override
2. `<script-dir>/../share/` — dev/repo checkout (`bin/` → `share/`)
3. `<script-prefix>/share/claude-sandboxed` — installed package

## PKGBUILD notes

- `arch=('any')` — no compiled code, pure shell + config.
- PKGBUILD lives in `packaging/`; run `cd packaging && makepkg -si` to build.
- `source=()` is empty — no fetching step. `_repodir="$(realpath ..)"` is evaluated at parse time (CWD is `packaging/`) and captures the repo root; `package()` installs from there directly.
- Adding new files to `bin/` or `share/` requires updating both `package()` and `install.sh`.
- Fill in `url=` before publishing to AUR; switch to `source=("git+https://...")` with `sha256sums=('SKIP')` and a proper `pkgver()` function at that point.

## Manual testing checklist

1. **Dev mode:** run `./bin/claude-sandboxed` from the repo root — should pick up `share/docker-compose.yml`.
2. **Installed mode:** run `cd packaging && makepkg -si`, then run `claude-sandboxed` from an unrelated directory — should pick up `/usr/share/claude-sandboxed/docker-compose.yml`.
3. **Override mode:** `CLAUDE_SANDBOXED_DIR=/some/path claude-sandboxed` — should use that path regardless.
4. **Push protection:** inside the container, `git push` should fail with the security message.
