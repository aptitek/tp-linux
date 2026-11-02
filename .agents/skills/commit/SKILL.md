---
name: commit
description: >-
  Create git commits following strict Conventional Commits and architectural scope
  rules enforced by commitlint.config.mjs and lefthook.yml. Use whenever committing
  code, preparing a commit message, or saving changes in git.
---

# Skill: Architectural Conventional Commits (`commit`)

Every commit message is validated by `commitlint.config.mjs` and the `lefthook.yml` `commit-msg` hook.

## 1. Mandatory Format
```text
<type>(<scope>): <subject>

<body>

<footer>
```
- **Header max length**: `100` characters (`subject-min-length: 15`).
- **Allowed `<type>` values**: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.
- **Mandatory `<scope>` values** (`scope-empty: never`):
  - `core`, `ui`, `tokens`, `routes`, `db`, `i18n`, `ci`, `lint`, `theme`, `worker`, `minecraft`, `quilt`, `fabric`, `mixin`, `network`, `test`, `tests`, `docs`, `deps`, `config`, `security`, `a11y`, `storybook`, `guardrails`, `scripts`
- **Subject rules**: lowercase start (`subject-case: lower-case`), imperative mood, no trailing period, at least 15 characters long.

## 2. Pre-Commit Verification Checklist
1. Stage implementation files together with their 1:1 `.test.ts(x)` and `.stories.tsx` companions.
2. Run `task check:commit` (or `task verify`) to ensure `guard:check`, `lint`, `complexity`, and `test` pass before committing.
3. Never use `--no-verify` to bypass `lefthook` git hooks.
