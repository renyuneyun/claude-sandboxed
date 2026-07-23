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
- The entrypoint's `git config --system` calls must use `/usr/bin/git` (not `git`). The wrapper at `/usr/local/bin/git` blocks `config`, which would break the `&&` chain and skip `runuser`, leaving Claude Code running as root.
- The three volume mounts (workspace, home cache, credential pass-through) must remain.
- `WORKSPACE_DIR` must be exported before `docker compose up` — the compose file interpolates it.
- `SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USERNAME`, and `SANDBOX_HOME` must be exported before `docker compose up` — the compose file interpolates them for volume paths and the user-creation entrypoint.
- `SANDBOX_GIT_IDENTITY_NAME`, `SANDBOX_GIT_IDENTITY_EMAIL`, and `SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH` are launcher-side only — they are NOT exported and NOT interpolated by the compose file. The launcher reads them to build `-e` and `-v` flags for `docker compose run`. Do not add them to the "must be exported" list above.
- `WORKSPACE_DIR` must be resolved to an absolute path before `WORKSPACE_CONFIG` is derived from it (the workspace config path is `$WORKSPACE_DIR/.claude-sandboxed.yaml`).
- Config file functions (`check_config`, `resolve`) must remain defined outside the main execution guard so tests can source the launcher and call them directly.
- All `docker compose` invocations must pass `-p "$COMPOSE_PROJECT"` (set to `claude-sandboxed-${SANDBOX_UID}`) — this namespaces containers and volumes per user, preventing conflicts on multi-user machines.
- The compose file resolution order must not be reordered without updating the section below.

## Config resolution

Identity knobs (`SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USERNAME`, `SANDBOX_HOME`) and git knobs (`SANDBOX_GIT_IDENTITY_NAME`, `SANDBOX_GIT_IDENTITY_EMAIL`, `SANDBOX_GIT_HOST_CONFIG_PASSTHROUGH`) are resolved per-knob from four sources in priority order:

1. **Env var** (`SANDBOX_UID`, etc.) - if set and non-empty.
2. **Workspace config** (`$WORKSPACE_DIR/.claude-sandboxed.yaml`) - if the key is present and non-null.
3. **User config** (`${XDG_CONFIG_HOME:-$HOME/.config}/claude-sandboxed/config.yaml`) - if the key is present and non-null.
4. **Default** - identity knobs: `$(id -u)`, `$(id -g)`, `$(id -un)`, `/home/$SANDBOX_USERNAME`. Git knobs: `""`, `""`, `true`.

Two bash functions in `bin/claude-sandboxed` implement this:

- `check_config FILE` - returns 0 if the file exists, `yq` is on `PATH`, and the YAML parses; returns 1 (with a stderr warning) otherwise. Missing files return 1 silently.
- `resolve ENV_NAME YQ_PATH DEFAULT` - checks the env var, then the validated workspace config, then the validated user config, then the default. Consults `WORKSPACE_CONFIG_VALID` / `USER_CONFIG_VALID` flags set by up-front `check_config` calls.

`yq` is a host-only dependency. Either mikefarah's Go `yq` or kislyuk's Python `yq` works - the spec uses only `yq '.' file` (validation) and `yq -r '.path' file` (key lookup), which are common-denominator operations.

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
10. **Git identity override:** with `git.identity.name`/`email` set in workspace config, `git commit` inside the container uses the overridden identity. Verify: `git log -1 --format='%an <%ae>'` shows the configured name/email, not host's.
11. **Host passthrough off:** with `git.host_config_passthrough: false`, `/usr/bin/git config user.name` inside the container returns nothing (or git's compiled default), not host's value. `cat ~/.gitconfig` fails (file doesn't exist). Note: `git config` (without `/usr/bin/`) is blocked by the wrapper — use `/usr/bin/git` to introspect.
12. **Identity + passthrough off:** both `git.identity` set and `host_config_passthrough: false`. `git commit` inside the container uses the sandbox identity. `git log -1 --format='%an <%ae>'` shows the configured name/email.
13. **Identity + passthrough on (default):** `git.identity` set, `host_config_passthrough` unset (default true). `git commit` uses the env-var identity. `git config user.name` (via `/usr/bin/git`) still reports host's value (env vars don't affect `git config --get`).

## Automated tests

Automated tests live in `tests/`. Each subdirectory contains a `test.sh` script for one component. The runner (`tests/run-all.sh`) discovers and executes all `tests/*/test.sh` scripts.

Run all tests from the repo root:

```sh
bash tests/run-all.sh
```

Current test suites:

- `tests/git-wrapper/test.sh` — unit tests for the git wrapper script (policy enforcement, argument parsing). Uses a stubbed real git binary so tests run on the host without Docker.
- `tests/config/test.sh` — unit tests for config resolution (`check_config`, `resolve`). Sources the launcher directly. Requires `yq` on `PATH`; skipped if `yq` is not installed.

To add a new test suite, create `tests/<component>/test.sh` and make it executable. The runner picks it up automatically. A test script should print `PASS:` / `FAIL:` lines and exit non-zero on any failure.

All automated tests must pass before release.
