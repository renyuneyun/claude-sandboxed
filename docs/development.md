# Internals

## Key invariants

These must not be broken without updating all affected documentation:

- `share/claude-sandboxed/docker-compose.yml` must stay at `share/claude-sandboxed/` relative to the repo root (dev-mode detection depends on it).
- The `ai-agent` service name must not change without updating every `docker compose run` call in the script.
- `IS_SANDBOX=1` must remain set in the container environment.
- The git push-blocking entrypoint must remain.
- The `git-wrapper` bind mount (`./git-wrapper:/usr/local/bin/git:ro` in `ai-agent.volumes`) must remain. Removing it disables the git operation policy.
- `share/claude-sandboxed/git-wrapper` must be executable (mode 755). `install.sh` and `packaging/PKGBUILD` must install it with mode 755.
- `/usr/local/bin` must precede `/usr/bin` in the container's `PATH` (true for `node:22-bookworm` by default). If the base image changes, verify this.
- The conditional `~/.gitconfig` and `~/.config/git/` mounts in `bin/claude-sandboxed` must check existence before mounting (avoids Docker creating empty stub dirs on the host).
- The three volume mounts (workspace, home cache, credential pass-through) must remain.
- `WORKSPACE_DIR` must be exported before `docker compose up` — the compose file interpolates it.
- `SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USERNAME`, and `SANDBOX_HOME` must be exported before `docker compose up` — the compose file interpolates them for volume paths and the user-creation entrypoint.
- All `docker compose` invocations must pass `-p "$COMPOSE_PROJECT"` (set to `claude-sandboxed-${SANDBOX_UID}`) — this namespaces containers and volumes per user, preventing conflicts on multi-user machines.
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

1. **Dev mode:** run `./bin/claude-sandboxed` from the repo root — should pick up `share/claude-sandboxed/docker-compose.yml`.
2. **Installed mode:** run `cd packaging && makepkg -si`, then run `claude-sandboxed` from an unrelated directory — should pick up `/usr/share/claude-sandboxed/docker-compose.yml`.
3. **Override mode:** `CLAUDE_SANDBOXED_DIR=/some/path claude-sandboxed` — should use that path regardless.
4. **Push protection:** inside the container, `git push` should fail with the security message.
5. **Git wrapper:** inside the container, `which git` shows `/usr/local/bin/git`.
6. **Git policy - blocked:** inside the container, `git push`, `git reset --hard`, `git commit --amend`, `git clean -fd`, `git rebase`, `git config --get user.name` all fail with `[SECURITY]` messages.
7. **Git policy - allowed:** inside the container, `git status`, `git log`, `git add`, `git commit -m test` (in a repo), `git switch`, `git fetch` all work.
8. **Git config inheritance:** with `~/.gitconfig` on the host, commits inside the container use the host user's identity. Without `~/.gitconfig`, the container starts and git uses defaults.
9. **Automated tests:** run `bash tests/run-all.sh` from the repo root — all test suites pass.

## Automated tests

Automated tests live in `tests/`. Each subdirectory contains a `test.sh` script for one component. The runner (`tests/run-all.sh`) discovers and executes all `tests/*/test.sh` scripts.

Run all tests from the repo root:

```sh
bash tests/run-all.sh
```

Current test suites:

- `tests/git-wrapper/test.sh` — unit tests for the git wrapper script (policy enforcement, argument parsing). Uses a stubbed real git binary so tests run on the host without Docker.

To add a new test suite, create `tests/<component>/test.sh` and make it executable. The runner picks it up automatically. A test script should print `PASS:` / `FAIL:` lines and exit non-zero on any failure.

All automated tests must pass before release.
