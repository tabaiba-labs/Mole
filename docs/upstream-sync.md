# Upstream Sync Strategy

This repository keeps the original Mole git history at the root so the native macOS app can live alongside the CLI without losing upstream mergeability.

## Why the repo root is the Mole fork

- upstream Mole history and files are tracked directly at the repository root
- future native app code can be added in new top-level folders such as `App/`, `Packages/`, or `docs/`
- pulling upstream changes stays a normal git workflow instead of a fragile copy-sync process

## Recommended remote layout

When you create your own hosted repository for this product, use:

- `origin` -> your product repository
- `upstream` -> `https://github.com/tw93/Mole.git`

Example:

```bash
git remote rename origin upstream
git remote add origin <your-product-repo-url>
git fetch upstream
```

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

## Integration boundary

Keep GUI-specific behavior limited to the machine contract layer:

- orchestration in `bin/clean.sh`
- structured output in `lib/core/machine_output.sh`
- step metadata in `lib/clean/registry.sh`
- compatibility wrappers in `lib/clean/step_helpers.sh`

Avoid rewriting Mole cleanup heuristics in app code. The GUI should consume the contract, not duplicate cleanup logic.
