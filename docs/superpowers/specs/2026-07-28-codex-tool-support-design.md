# Codex Tool Support

**Date:** 2026-07-28
**Status:** Approved, pending implementation
**Scope:** Add first-class Codex CLI support while preserving Claude compatibility and introducing a bounded profile boundary for future coding agents.

## Goal

Allow users to run either Claude Code or Codex CLI in the existing Docker sandbox. Claude remains the default, and all current Claude invocations keep working. The implementation should make another built-in tool straightforward to add later without exposing arbitrary commands or prematurely renaming the package.

## Non-goals

- Renaming the package, executable, config files, data directory, Compose project, services, or volumes.
- Supporting user-defined tool commands or packages.
- Supporting coding agents other than Claude Code and Codex CLI in this release.
- Generalizing every existing Claude-named configuration key.
- Changing the Docker image, filesystem boundary, network mode, git policy, cleanup behavior, or user-identity behavior.
- Replacing the Bash launcher with another implementation language.

## User Interface

### Tool selection

The launcher accepts a new `--tool NAME` option:

```bash
claude-sandboxed --tool codex
claude-sandboxed --tool codex ~/projects/my-app
```

Tool selection has this precedence:

1. CLI `--tool NAME`
2. `SANDBOX_TOOL`
3. Workspace config `tool`
4. User config `tool`
5. Default `claude`

The supported names are exactly `claude` and `codex`. An unknown name fails before Docker starts and reports the supported names.

### Tool argument passthrough

The first `--` ends launcher argument parsing. Every following argument is passed to the selected tool without re-parsing or word splitting:

```bash
claude-sandboxed --tool codex ~/projects/my-app -- --model gpt-5.4
claude-sandboxed ~/projects/my-app -- --resume
```

Before `--`, the launcher accepts its own options and at most one workspace argument. When the workspace is omitted, it remains the current directory. Existing forms remain valid:

```bash
claude-sandboxed
claude-sandboxed ~/projects/my-app
CLAUDE_VERSION=2.1.152 claude-sandboxed
```

## Configuration

The YAML schema gains a top-level tool selector and a Codex section:

```yaml
tool: codex

codex:
  version: "0.0.0"
  config_passthrough: true
  config_dir: ~/.codex
```

All fields are optional. Codex settings use the existing per-knob precedence:

| Environment variable | YAML key | Default |
|---|---|---|
| `CODEX_VERSION` | `codex.version` | Installed host Codex version; no pin if unavailable |
| `CODEX_CONFIG_PASSTHROUGH` | `codex.config_passthrough` | `true` |
| `CODEX_CONFIG_DIR` | `codex.config_dir` | `$HOME/.codex` |

The example version is illustrative; implementation and documentation must not hard-code it as a current recommended release.

Claude's existing `claude.*` keys and `CLAUDE_*` environment variables remain unchanged. Tool-specific settings may coexist in one config file; only the selected profile consumes its own settings.

When Codex config passthrough is enabled and the configured host directory exists, the launcher bind-mounts it read/write at `${SANDBOX_HOME}/.codex`. If the directory does not exist, no mount is added. Disabling passthrough adds no Codex config mount.

## Architecture

`bin/claude-sandboxed` remains the sole launcher. Its main flow becomes:

1. Parse launcher arguments into a CLI tool override, workspace, and an argument array after `--`.
2. Resolve the workspace to an absolute path.
3. Discover and validate the existing workspace and user configuration files.
4. Resolve the selected tool using the documented precedence.
5. Configure one explicit tool profile.
6. Resolve the existing generic sandbox identity, git, cleanup, and Compose settings.
7. Build tool-specific environment and volume arguments.
8. Run the selected tool in the existing `ai-agent` service.
9. Run the existing conditional cleanup.

The profile layer consists of sourceable Bash functions, following the existing testability pattern for `check_config`, `resolve`, and `resolve_list`. A profile supplies:

- npm package and optional version pin;
- host version detection;
- config passthrough mounts;
- environment-variable forwarding;
- the autonomy flag required inside the external Docker sandbox;
- the final tool command prefix.

The generic Docker, identity, git-policy, and cleanup flow does not branch on tool-specific details after a profile has populated those values.

The launcher keeps the existing `GIT_VOLUME_ARGS` and
`GIT_POLICY_VOLUME_ARGS` arrays unchanged. Only the existing
`CLAUDE_VOLUME_ARGS` array is generalized to `TOOL_VOLUME_ARGS` so the
selected profile can supply its own config mounts:

- `GIT_VOLUME_ARGS` contains optional, read-only bind mounts for the host
  user's `~/.gitconfig` and `~/.config/git`. These host files are normally
  shared by every invocation for that user.
- `TOOL_VOLUME_ARGS` contains optional, read/write bind mounts for the
  selected tool's host configuration. These normally persist across
  invocations on the host, although workspace configuration can select a
  project-specific host path.
- `GIT_POLICY_VOLUME_ARGS` contains an optional, read-only bind mount for the
  generated policy file. That host temporary file belongs to one launcher
  invocation and is removed by the launcher's exit trap.

These arrays contain Docker `-v` arguments; they are not Docker-managed
volumes. The existing `claude-agent-home` is a separate named volume,
namespaced by host UID through the Compose project. It remains shared across
tools, workspaces, and sessions for that UID until explicitly removed. The
workspace and git-wrapper remain bind mounts with their existing
project-specific and package-installation lifecycles, respectively. Every
agent container remains ephemeral because it runs with `--rm`.

### Claude profile

The Claude profile preserves existing behavior:

- package: `@anthropic-ai/claude-code`;
- version: `CLAUDE_VERSION` / `claude.version`, defaulting to the installed host Claude version and otherwise leaving the npm package unpinned;
- config: existing `CLAUDE_CONFIG_PASSTHROUGH`, `CLAUDE_CONFIG_DIR`, and `CLAUDE_CONFIG_FILE` behavior;
- environment: forward `ANTHROPIC_API_KEY` when present;
- autonomy flag: `--dangerously-skip-permissions`.

### Codex profile

The Codex profile provides:

- package: `@openai/codex`;
- version: `CODEX_VERSION` / `codex.version`, defaulting to the installed host Codex version and otherwise leaving the npm package unpinned;
- config: `CODEX_CONFIG_PASSTHROUGH` and `CODEX_CONFIG_DIR`, mounted at `${SANDBOX_HOME}/.codex`;
- environment: forward `OPENAI_API_KEY` when present;
- autonomy flag: `--dangerously-bypass-approvals-and-sandbox`.

The autonomy flag is intentional: Codex runs without its nested approval and sandbox layer because the launcher already places it in the externally hardened Docker environment. The existing `IS_SANDBOX=1` container environment remains unchanged.

### Command assembly

The conceptual command is:

```bash
docker compose ... run \
  --rm \
  -e HOME="${SANDBOX_HOME}" \
  "${TOOL_ENV_ARGS[@]}" \
  "${GIT_ENV_ARGS[@]}" \
  "${GIT_VOLUME_ARGS[@]}" \
  "${TOOL_VOLUME_ARGS[@]}" \
  "${GIT_POLICY_VOLUME_ARGS[@]}" \
  -it ai-agent \
  npx --yes "$TOOL_PACKAGE" "${TOOL_DEFAULT_ARGS[@]}" "${TOOL_USER_ARGS[@]}"
```

Arrays are used throughout so spaces and argument boundaries are preserved. Tool defaults precede user passthrough arguments, allowing Codex global options to appear before user-selected subcommands such as `resume`.

Tool-specific API keys move out of the static Compose environment list. The Claude profile adds `ANTHROPIC_API_KEY`; the Codex profile adds `OPENAI_API_KEY`. Selecting one tool does not implicitly forward the other tool's API key.

## Error Handling

Before invoking Docker, the launcher rejects:

- `--tool` without a value;
- unsupported launcher options before `--`;
- more than one workspace argument before `--`;
- unsupported tool names;
- a workspace that does not exist or cannot be resolved.

Errors identify the invalid input and show the accepted form or supported tools where useful. Tool-user arguments after `--` are opaque and are never rejected by the launcher.

Host version detection is best-effort. If the selected host CLI is absent or its version cannot be parsed, the npm package remains unpinned so `npx` resolves its normal latest version. Failure to find a host CLI is not an error.

## Testing

Source-level tests cover:

- default selection remains Claude;
- CLI tool selection;
- `SANDBOX_TOOL` selection;
- workspace and user config selection;
- the full CLI > environment > workspace > user > default precedence;
- unknown tool rejection;
- missing `--tool` value, unsupported launcher options, and multiple workspace arguments;
- default current-directory behavior and explicit workspace resolution;
- arguments after `--`, including spaces and option-like values, retain exact boundaries;
- Claude profile package, version pin, mounts, environment, and autonomy flag remain unchanged;
- Codex profile package and autonomy flag;
- Codex version resolution from environment, workspace config, user config, host CLI, and the unpinned fallback;
- default, custom, missing, and disabled Codex config-directory mounts;
- Claude forwards only `ANTHROPIC_API_KEY`;
- Codex forwards only `OPENAI_API_KEY`;
- final command ordering places tool defaults before passthrough arguments;
- invalid input fails before Docker is called.

The tests must not require Docker, network access, Claude, or Codex. External commands are stubbed or profile outputs are inspected directly. Existing config and git-wrapper suites must remain green.

Manual tests cover an interactive Claude launch, an interactive Codex launch using host config, Codex API-key authentication with passthrough disabled, version pins for both tools, and argument passthrough for both tools.

## Documentation

Update:

- `README.md` with supported tools, selection precedence, CLI examples, passthrough syntax, Codex authentication/configuration, and the unchanged package-name caveat;
- `share/claude-sandboxed/config.example.yaml` with `tool` and `codex` examples;
- `docs/architecture.md` with the generic runtime flow and tool-specific mounts/environment;
- `docs/development.md` with profile invariants, sourceable test seams, configuration resolution, and manual tests;
- `CLAUDE.md` only if its short project description or file guidance becomes inaccurate.

Documentation describes Claude and Codex as the two first-class profiles. It does not claim arbitrary-tool support.

## Stability Boundary

The profile functions are an internal boundary, not a public plugin API. They deliberately make a later built-in tool easier to add, but their shape may be revised after Claude and Codex behavior proves stable. The stable public contract introduced here is limited to:

- `--tool claude|codex`;
- `SANDBOX_TOOL`;
- top-level YAML `tool`;
- Codex YAML and environment settings documented above;
- argument passthrough after `--`.

All package and installation names remain `claude-sandboxed` until a separate rename design is approved.

## Files Expected to Change

| File | Change |
|---|---|
| `bin/claude-sandboxed` | Parse CLI, resolve tool, add profiles, assemble generic tool arguments |
| `share/claude-sandboxed/docker-compose.yml` | Remove tool-specific static API-key forwarding |
| `share/claude-sandboxed/config.example.yaml` | Add tool selection and Codex settings |
| `tests/config/test.sh` | Cover new scalar configuration keys |
| `tests/launcher/test.sh` | Cover parsing, profiles, errors, and command assembly |
| `README.md` | Document user-facing behavior |
| `docs/architecture.md` | Document multi-tool architecture |
| `docs/development.md` | Update invariants and test guidance |
| `CLAUDE.md` | Update only if needed for accuracy |
