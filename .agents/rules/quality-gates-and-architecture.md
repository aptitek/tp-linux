# Architectural Guardrails & First-Time-Right Quality Gates

This repository (`polyglot-guardrails`) is the Single Source of Truth for a zero-tolerance, Haskell-grade architectural fortress. Every child project and module is gated by static AST analysis, strict Conventional Commits (`commitlint.config.mjs`), zero code duplication (`.jscpd.json` threshold `0%`), secret scanning (`.secretlintrc.json`), and automated test/coverage/mutation gates.

## 1. Mandatory Universal Command Interface (`task`)
- Always use `task` (`go-task`): `task verify`, `task self-test`, `task lint`, `task init -- --target <dir> --modules <m1,m2>`.
- Never invoke underlying package managers or linters directly.
- Never use linter or typechecker suppression comments (`eslint-disable`, `@ts-ignore`, `@ts-expect-error`, `@ts-nocheck`, `# noqa`, `# type: ignore`, `@SuppressWarnings`, `@Suppress`, `@file:Suppress`, `@phpstan-ignore`, `nosemgrep`).

## 2. The 6 Formal Haskell-Grade Architectural Locks & JVM / Minecraft Gates
1. **Lock 1 (`lang:ts` — Functional Purity & Total Functions)**: `complexity <= 3`, `max-depth <= 1`, `max-lines <= 150`, `max-lines-per-function <= 28`, `max-params <= 3` in `src/`. Bans `let`/`var`, mutation, loops, `else`, `as T`, `x!`, `is T`, `throw` in pure modules, and `export *`.
2. **Lock 2 (`fw:react` — Strict i18n & Zero Hardcoded Strings)**: Bans raw user-facing string literals in JSX and functions; requires `src/i18n/strings.ts`.
3. **Lock 3 (`addon:design-system` — M3 Token Purity & Color Pairing)**: Bans hardcoded colors/durations/radii/fonts and enforces MD3 `bg` ↔ `color` semantic token pairing.
4. **Lock 4 (`fw:react` — True Atomic Purity & Stateless Atoms)**: Bans raw HTML (`<div>`), `<panda.div>`, `style={}`, Tailwind classes, `useEffect` in UI/routes, and all `use*` hooks in `src/components/atoms/`.
5. **Lock 5 (`addon:design-system` — Panda CSS Recipes & Canonical Deduplication)**: Max 3 inline layout props on JSX containers, mandatory `defaultVariants`, styled slot anatomy, and commutative recipe block deduplication.
6. **Lock 6 (`addon:testing-fortress` — Test Assertion Purity & 1:1 TDD Companions)**: Bans `it.skip`/`test.only`, weak matchers (`toBeTruthy`/`toMatchSnapshot`), and `vi.mock()`. Requires 1:1 `.test.ts(x)` companions, 95% per-file Vitest coverage, and 95% StrykerJS mutation score.
7. **JVM & Minecraft Modding Fortress (`lang:java`, `lang:kotlin`, `fw:minecraft`, `fw:quilt`, `fw:fabric`)**:
   - Detekt `maxIssues: 0` & `warningsAsErrors: true`, Checkstyle/PMD complexity `<= 10`, zero wildcard imports, zero `!!` non-null assertions in `src/main/`, zero `GlobalScope`.
   - Strict Client/Server physical side separation (`net.minecraft.client.*` and `com.mojang.blaze3d.*` banned in `server/` and `common/`; `net.minecraft.server.dedicated.*` banned in `client/`).
   - Mixin safety (`@Overwrite` and `@Redirect` banned; `injectors.defaultRequire: 1` required in `*.mixins.json`).
