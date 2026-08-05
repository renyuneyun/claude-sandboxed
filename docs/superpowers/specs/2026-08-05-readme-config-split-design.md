# README configuration split

## Goal

Shorten `README.md` by moving detailed configuration reference to a dedicated doc, while keeping the README's role (introduce project, install, basic usage, features, testing, links) intact.

## Non-goals

- Rewriting prose for style.
- Changing the `Features` section content (user explicitly asked to keep it in README).
- Changing the install/usage/requirements sections.
- Touching `docs/architecture.md`, `docs/tradeoffs.md`, `docs/development.md`.

## Current state

`README.md` is 392 lines. The bulk (~275 lines, lines 60-335) is the `Customization` section, which inlines every config knob, the full YAML schema, identity tables, passthrough details, git policy config, and the git policy reference (blocked subcommands + flag-level blocks + known limitations).

## Target state

### `README.md` (~150-170 lines)

Sections kept verbatim:
- Title, tagline, rationale (lines 1-8)
- Requirements (lines 10-14)
- Installation (lines 16-42)
- Usage (lines 44-58)
- Features (lines 337-376)
- Testing (lines 378-386)

Section replaced:
- `Customization` (lines 60-335) → new short `Configuration` section (~15 lines):
  - One paragraph: YAML config files at workspace and user level, optional, read by `yq`.
  - Precedence rule (one line): env var > workspace config > user config > built-in default.
  - Quick-start: copy `<prefix>/share/claude-sandboxed/config.example.yaml` to `~/.config/claude-sandboxed/config.yaml`.
  - Link to `docs/configuration.md` for the full schema and per-knob details.

Section updated:
- `Further reading` (lines 388-392): add `docs/configuration.md` entry.

### `docs/configuration.md` (NEW, ~250 lines)

Sections moved verbatim or near-verbatim from README:
- Intro: config file locations table (workspace + user), precedence, `yq` requirement and the two implementations.
- Full YAML schema block (lines 84-120 of README).
- Worked example block (lines 122-128).
- User identity (lines 136-153): env var table, override example, `SANDBOX_UID=0` note.
- Git identity (lines 155-178): knobs table, env var overrides, "how identity is applied" paragraph, combinations table, caveat.
- Tool versions (lines 180-196): `claude.version` and `codex.version` examples.
- Claude config passthrough (lines 198-217): toggle, custom paths, container-side path note.
- Codex config passthrough (lines 219-221).
- Proxy environment passthrough (lines 223-247).
- Cleanup (lines 249-258).
- Git policy config (lines 260-289): allow/block lists, regex semantics, precedence, `/etc/claude-sandboxed/git-policy.conf` inspection.
- Local-override mode (lines 291-303).
- Authentication (lines 305-307).
- Git policy reference (lines 309-335): wrapper description, fully blocked subcommands, conditionally blocked subcommands, flag-level blocks table, `git config` rationale, known limitations.

Cross-links:
- README `Configuration` section → `docs/configuration.md`.
- `docs/configuration.md` intro → README `Features` section (for context on what the knobs tune).
- `docs/configuration.md` `Further reading` not needed; the README remains the entry point.

## Verification

- `README.md` line count <= 180.
- `docs/configuration.md` exists and contains every section listed above.
- All cross-links resolve (relative paths).
- No content lost: every line in the old `Customization` section appears in `docs/configuration.md` either verbatim or lightly edited.
- `git diff --stat` shows: README shorter, one new file, no other files touched.
- Existing tests still pass (`bash tests/run-all.sh`) - no code changes, so this is a sanity check only.

## Risks

- Anchor links: the old README had `[Configuration](#configuration)` style anchors. The new short section keeps the `Configuration` anchor, so external links to `#configuration` still work. Anchors for moved sections (e.g. `#git-policy`, `#user-identity`) will break - acceptable since this is an early-stage project (per memory) and no external docs are known to link to these anchors.
