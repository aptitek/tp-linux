---
name: vibe-guardrails
description: Strict architectural, AST, and Zero-Config-Drift guardrails for AI coding agents working in polyglot-guardrails.
---

# Skill: Vibe Coding Guardrails (`polyglot-guardrails`)

## Golden Rules for AI Coding Agents
1. **Use `task` Exclusively**:
   - Run `task check:quick` / `task test:quick` during inner-loop TDD.
   - Run `task typecheck`, `task a11y`, `task i18n`, `task coverage`, and `task mutate` for cross-language verification.
   - Run `task check:commit` before committing.
   - Run `task verify` (`guard:check` -> `lint` -> `typecheck` -> `a11y` -> `i18n` -> `dup` -> `complexity` -> `sec` -> `test` -> `coverage` -> `mutate`) before finishing any task.
   - Never invoke `pnpm`, `npm`, `npx`, `uv`, `pip`, `poetry`, `gradle`, `./gradlew`, `detekt`, `composer`, `eslint`, `vitest`, `stryker`, `mutmut`, `infection`, or `jupyter` directly.
2. **Respect `.guardrails.lock` (Zero Config Drift)**:
   - Never modify `Taskfile.yml`, `eslint.config.mjs`, `tsconfig.base.json`, `mise.toml`, `lefthook.yml`, `.jscpd.json`, `commitlint.config.mjs`, `.dependency-cruiser.cjs`, `panda.config.ts`, `stryker.config.mjs`, `ruff.toml`, `detekt.yml`, or `.guardrails/**`.
   - Use `Taskfile.local.yml` only for project-specific business tasks.
   - Use `task feature:add -- <module>` to enable new framework or addon capabilities (`flet`, `nicegui`, `langchain`, `jupyter`, `minecraft`, `quilt`, `fabric`, `cloudflare`, `design-system`, `testing-fortress`, `storybook`, `content-md`, `drizzle-d1`, `lib-exports`).
3. **Comply with Web Locks, JVM/Minecraft Gates & Python/Jupyter Gates**:
   - **Locks 1–6 (Web/TypeScript)**: Functional purity (`complexity <= 3`), strict i18n (`src/i18n/strings.ts`), M3 token pairing, stateless Atomic components, Panda CSS recipes, and 1:1 TDD companions with 95% coverage & mutation thresholds.
   - **JVM & Minecraft Gates (`lang:java`, `lang:kotlin`, `fw:minecraft`, `fw:quilt`, `fw:fabric`)**: Detekt `maxIssues: 0`, Checkstyle/PMD complexity `<= 10`, zero `!!` or `GlobalScope`, strict Client/Server physical side-separation (`net.minecraft.client.*` forbidden in `server/` and `common/`), MixinExtras safety (`@Overwrite` and `@Redirect` forbidden), and valid `quilt.mod.json` / `fabric.mod.json` / 1.21+ singular datapack paths.
   - **Python (`uv`), Flet, NiceGUI, LangChain & Jupyter Gates (`lang:python`, `fw:flet`, `fw:nicegui`, `fw:langchain`, `fw:jupyter`)**: Exclusive `uv` workflow, `<= 256` lines per `.py` file, Ruff McCabe `<= 8` & `max-statements <= 20`, Flet MD3 `ft.Colors.*` tokens & 5-level Atomic Design, NiceGUI non-blocking async event-loop (`asyncio.sleep` / `run.io_bound`), LangChain LCEL / LangGraph `StateGraph` + `SecretStr`, and Jupyter clean-output gate (`outputs: []` via `task format`) & zero in-cell `!pip` installs.
   - **Zero Linter Bypasses**: `@ts-ignore`, `eslint-disable`, `@SuppressWarnings`, `@Suppress`, `# noqa`, `# type: ignore`, and `nosemgrep` are strictly forbidden.
