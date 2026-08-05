# Proxy Environment Passthrough Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Forward conventional host proxy environment variables into Claude and Codex sandbox containers through a configurable passthrough option.

**Architecture:** Resolve one generic `proxy.env_passthrough` boolean with the launcher's existing precedence rules, then collect non-empty standard proxy variables into a dedicated `PROXY_ENV_ARGS` Bash array. Insert that array into `docker compose run` independently of the selected tool profile so `npx` and either agent receive the same environment.

**Tech Stack:** Bash, Docker Compose command assembly, yq-backed YAML configuration, shell test suites, Markdown documentation.

## Global Constraints

- `proxy.env_passthrough` defaults to `true` and is overridden by `SANDBOX_PROXY_ENV_PASSTHROUGH`.
- Forward `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY` and their lowercase equivalents independently, only when non-empty.
- Preserve proxy values exactly and never log, normalize, or store them in YAML.
- Apply behavior equally to Claude and Codex without changing `network_mode: host`.
- Preserve unrelated user changes and existing project invariants.

---

### Task 1: Configuration resolution and proxy argument collection

**Files:**
- Modify: `tests/config/test.sh`
- Modify: `tests/launcher/test.sh`
- Modify: `bin/claude-sandboxed`

**Interfaces:**
- Consumes: existing `resolve ENV_NAME YQ_PATH DEFAULT` scalar resolver.
- Produces: `SANDBOX_PROXY_ENV_PASSTHROUGH` resolved value and `PROXY_ENV_ARGS`, an array of Docker `-e NAME=value` pairs.

- [ ] **Step 1: Write failing configuration tests**

Add assertions proving `.proxy.env_passthrough` resolves from the environment, workspace config, user config, and the default `true` value.

- [ ] **Step 2: Write failing launcher tests**

Add a source-level test helper that sets sentinel uppercase and lowercase proxy variables, invokes the proxy argument collector, and asserts exact names, values, omission of empty variables, and disabled behavior. Extend the captured Docker invocation test to prove a sentinel proxy reaches Codex by default and is absent when passthrough is disabled.

- [ ] **Step 3: Run focused tests and verify RED**

Run:

```bash
bash tests/config/test.sh
bash tests/launcher/test.sh
```

Expected: new proxy assertions fail because proxy resolution and `PROXY_ENV_ARGS` do not exist.

- [ ] **Step 4: Implement minimal proxy collection**

Add a sourceable `configure_proxy_env` function that initializes `PROXY_ENV_ARGS`, returns early unless passthrough is `true`, iterates the eight fixed proxy names, and appends `-e` plus `NAME=value` for each non-empty indirect expansion. Resolve the setting in main and insert the array before tool-specific environment arguments in `docker compose run`.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run:

```bash
bash tests/config/test.sh
bash tests/launcher/test.sh
```

Expected: all configuration and launcher tests pass.

- [ ] **Step 6: Commit runtime behavior**

```bash
git add bin/claude-sandboxed tests/config/test.sh tests/launcher/test.sh
git commit -m "feat: forward proxy environment into sandbox"
```

---

### Task 2: User and maintainer documentation

**Files:**
- Modify: `share/claude-sandboxed/config.example.yaml`
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/development.md`
- Modify: `docs/tradeoffs.md`

**Interfaces:**
- Consumes: `proxy.env_passthrough`, `SANDBOX_PROXY_ENV_PASSTHROUGH`, and the eight supported environment names from Task 1.
- Produces: consistent user configuration guidance and maintainer invariants.

- [ ] **Step 1: Add the example configuration**

Document the default-enabled `proxy.env_passthrough` option and explain that disabling it prevents host proxy variables, including credentials, from entering the sandbox.

- [ ] **Step 2: Update user documentation**

Add a README proxy section listing supported uppercase and lowercase variables, configuration precedence, disable examples, and the distinction between host endpoint reachability and client selection.

- [ ] **Step 3: Update architecture and trade-offs**

Add generic proxy variables to the container environment model, explain their launcher-built argument array, and clarify that host networking neither copies proxy settings nor forces proxy use.

- [ ] **Step 4: Update development invariants**

Record the supported variable list, generic/tool-neutral ownership, conditional forwarding, value-preservation requirement, and expected test coverage.

- [ ] **Step 5: Check documentation consistency**

Run:

```bash
rg -n "env_passthrough|SANDBOX_PROXY_ENV_PASSTHROUGH|HTTP_PROXY|host network" README.md share/claude-sandboxed/config.example.yaml docs
git diff --check
```

Expected: all public names are consistent and `git diff --check` reports no errors.

- [ ] **Step 6: Commit documentation**

```bash
git add README.md share/claude-sandboxed/config.example.yaml docs/architecture.md docs/development.md docs/tradeoffs.md
git commit -m "docs: explain sandbox proxy passthrough"
```

---

### Task 3: Full verification

**Files:**
- Verify: all files changed by Tasks 1 and 2.

**Interfaces:**
- Consumes: completed implementation and documentation.
- Produces: evidence that the feature and existing behavior pass the full project checks.

- [ ] **Step 1: Run the complete test suite**

Run:

```bash
bash tests/run-all.sh
```

Expected: all configuration, git-wrapper, and launcher tests pass with zero failures.

- [ ] **Step 2: Run static checks**

Run:

```bash
bash -n bin/claude-sandboxed tests/config/test.sh tests/launcher/test.sh
git diff --check
```

Expected: both commands exit successfully without output.

- [ ] **Step 3: Inspect repository state**

Run:

```bash
git status --short
git log -3 --oneline
```

Expected: only pre-existing unrelated untracked packaging artifacts remain, and the feature commits appear in history.
