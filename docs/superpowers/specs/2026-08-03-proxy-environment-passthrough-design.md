# Proxy Environment Passthrough

**Date:** 2026-08-03
**Status:** Approved
**Scope:** Forward conventional host proxy environment variables into the sandbox through a configurable, tool-neutral launcher option.

## Goal

Make host proxy configuration available to `npx`, Claude Code, and Codex CLI inside the Docker sandbox without storing proxy URLs or credentials in project configuration.

## Configuration

The YAML schema gains one optional setting:

```yaml
proxy:
  env_passthrough: true
```

The matching environment override is `SANDBOX_PROXY_ENV_PASSTHROUGH`. It uses the existing scalar precedence:

1. `SANDBOX_PROXY_ENV_PASSTHROUGH`
2. Workspace `.claude-sandboxed.yaml`
3. User `config.yaml`
4. Default `true`

Only the literal resolved value `true` enables passthrough, matching the launcher's existing boolean knobs. Setting the option to `false` forwards no proxy variables.

The configuration controls passthrough only. Proxy URLs, bypass lists, and credentials are not accepted as YAML values.

## Runtime Behavior

When passthrough is enabled, the launcher checks the following host variables independently and adds each non-empty value to the `docker compose run` environment arguments:

- `HTTP_PROXY`
- `HTTPS_PROXY`
- `ALL_PROXY`
- `NO_PROXY`
- `http_proxy`
- `https_proxy`
- `all_proxy`
- `no_proxy`

Unset and empty variables are omitted. Uppercase and lowercase names remain distinct, so if both forms are present both are forwarded unchanged. Values are assembled with Bash arrays so spaces and special characters do not undergo word splitting.

The proxy arguments are generic sandbox settings, separate from the selected tool's `TOOL_ENV_ARGS`. They apply equally to Claude and Codex and are passed to the container before `npx` starts. This ensures package resolution and the selected agent see the same proxy environment.

`network_mode: host` remains unchanged. Host networking makes host-local proxy listeners reachable; environment passthrough configures clients to use those listeners. It does not force or transparently redirect traffic through a proxy.

## Security and Error Handling

Passthrough defaults to enabled for compatibility with the launcher's transparent-isolation goal. Users who do not want host proxy values, including embedded credentials, exposed inside the sandbox can disable it globally or per workspace.

The launcher does not log proxy values, validate proxy URL syntax, rewrite `NO_PROXY`, or infer proxy settings from desktop applications. It forwards only variables already present in the launcher's host environment.

## Testing

Source-level configuration tests cover environment, workspace, user, and default resolution for `proxy.env_passthrough`.

Launcher tests cover:

- default enabled behavior;
- all uppercase and lowercase names;
- omission of unset or empty variables;
- exact value preservation;
- disabling through `SANDBOX_PROXY_ENV_PASSTHROUGH=false`;
- proxy arguments reaching the final Docker invocation for Codex;
- no proxy arguments reaching Docker when disabled.

The full existing test suite must remain green and requires no Docker or network access.

## Documentation

Update the example configuration, README, architecture, development invariants, and network trade-off documentation. The documentation must distinguish endpoint reachability from client proxy configuration and explain the credential-exposure trade-off of default passthrough.

## Files Expected to Change

| File | Change |
|---|---|
| `bin/claude-sandboxed` | Resolve the setting, build generic proxy environment arguments, and include them in the Docker command |
| `tests/config/test.sh` | Cover configuration precedence |
| `tests/launcher/test.sh` | Cover variable collection and final command assembly |
| `share/claude-sandboxed/config.example.yaml` | Document the new option |
| `README.md` | Document proxy behavior and configuration |
| `docs/architecture.md` | Add proxy variables to the container environment model |
| `docs/development.md` | Add proxy passthrough invariants and test guidance |
| `docs/tradeoffs.md` | Clarify host networking versus proxy selection |

## Non-goals

- Explicit proxy URLs in YAML.
- Automatic desktop or operating-system proxy discovery.
- Proxy URL validation or normalization.
- Enforcing that all sandbox traffic uses a proxy.
- Changing Docker network isolation or adding a proxy sidecar.
