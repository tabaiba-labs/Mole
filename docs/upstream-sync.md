# Upstream Sync Strategy

This repository is the Mole engine fork used by the desktop app.

The desktop app itself lives in a separate repository root and includes this fork as a submodule at `dependencies/Mole/`.

## Why this repo stays separate from the desktop app

- upstream Mole history and files stay isolated from app-level code
- GUI integration changes can be reviewed and merged as Mole engine changes
- pulling upstream Mole changes stays a normal git workflow instead of a manual vendor sync process

## Recommended remote layout

For this fork, use:

- `origin` -> `https://github.com/tabaiba-labs/Mole.git`
- `upstream` -> `https://github.com/tw93/Mole.git`

## Normal update flow

1. Fetch upstream:

```bash
git fetch upstream
```

2. Merge or rebase onto the upstream branch you track:

```bash
git merge upstream/main
```

3. Resolve conflicts, with special attention to these integration files:

- `bin/clean.sh`
- `lib/core/machine_output.sh`
- `lib/clean/registry.sh`
- `lib/clean/step_helpers.sh`
- `lib/core/file_ops.sh`
- `lib/clean/dev.sh`

4. Re-run the JSONL smoke checks for:

- `clean --preflight`
- `clean --dry-run --scope user`
- `clean --scope user`

## CI Policy For This Fork

This fork keeps CI intentionally small.

- `test.yml` is the only workflow expected to run automatically
- `test.yml` validates the upstream Mole test suite and the JSONL smoke checks
- `codeql.yml`, `release.yml`, and `update-contributors.yml` are manual-only in this fork
- `check.yml` is removed in this fork to avoid auto-formatting or bot-driven pushes

The goal is to keep one reliable validation path for safety-critical cleanup changes without carrying unnecessary upstream automation.

## Integration boundary

Keep GUI-specific behavior limited to the machine contract layer:

- orchestration in `bin/clean.sh`
- structured output in `lib/core/machine_output.sh`
- step metadata in `lib/clean/registry.sh`
- compatibility wrappers in `lib/clean/step_helpers.sh`

Avoid rewriting Mole cleanup heuristics in app code. The GUI should consume the contract, not duplicate cleanup logic.

## Relationship To The App Repo

- the desktop app repository tracks this fork as a submodule at `dependencies/Mole/`
- the app repo should only update the submodule pointer after Mole-side changes are committed and pushed here
- app-level docs live in the desktop app root `docs/`, not in this fork
