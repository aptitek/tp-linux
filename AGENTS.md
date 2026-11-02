# AGENTS.md — Strict AI Vibe-Coding Guardrails Contract

> **MANAGED BY `polyglot-guardrails` — Single Source of Truth (DO NOT EDIT MANUALLY).**
> Load `.agents/skills/vibe-guardrails/SKILL.md` before writing or modifying any code.

## 1. Mandatory Universal Command Interface (`task`)
You MUST interact with the repository **exclusively** through the universal `task` runner (`go-task`).
**Direct execution of underlying package managers or linters (`pnpm`, `npm`, `npx`, `uv`, `pip`, `poetry`, `pytest`, `ruff`, `mypy`, `gradle`, `./gradlew`, `detekt`, `composer`, `eslint`, `vitest`, `wrangler`, `jupyter`) is strictly FORBIDDEN.**

| Action | Allowed Command |
| :--- | :--- |
| Run full meta-framework verification | `task verify` |
| Run automated end-to-end integration self-test | `task self-test` |
| Tier 1 (< 3s): Fast inner-loop AST + lint check | `task check:quick` |
| Tier 1 (< 3s): Fast unit test check | `task test:quick` |
| Tier 2 (< 10s): Pre-commit verification gate | `task check:commit` |
| Tier 3: Pre-push full architectural fortress gate | `task check:push` / `task verify` |
| Run cross-language static typechecking | `task typecheck` |
| Run cross-language WCAG 2.2 AA / UI accessibility | `task a11y` |
| Run cross-language i18n locale parity & literal check | `task i18n` |
| Run cross-language branch & line coverage verification | `task coverage` |
| Run cross-language mutation testing | `task mutate` |
| Initialize or bootstrap a project | `task init MODULES=<m1,m2>` / `task bootstrap` |
| Verify config lock | `task guard:check` |
| Sync guardrails | `task guard:sync` |
| Sign / regenerate `.guardrails.lock` checksums | `task guard:sign` / `task guard:lock` |
| Update devkit, mise toolchain & dependencies | `task update` |
| Add module/addon | `task feature:add -- <mod>` |

---

## 2. Anti-Tamper & Zero Config Drift Policy (`.guardrails.lock`)
All configuration files tracked in `.guardrails.lock` are cryptographically locked via SHA-256 checksums:
- Core foundation files: `.gitignore`, `.gitattributes`, `Taskfile.yml`, `mise.toml`, `lefthook.yml`, `AGENTS.md`
- Everything inside `.guardrails/**` and `.agents/**`
- Module-specific configuration files installed by active modules in `.guardrails/manifest.json`

---

## 3. Zero Linter / Typechecker Bypass Policy (`.guardrails/ast/no-linter-bypass.yml`)
Suppressing errors via comments or annotations (`eslint-disable`, `@ts-ignore`, `@ts-expect-error`, `@ts-nocheck`, `# noqa`, `# type: ignore`, `@SuppressWarnings`, `@Suppress`, `@file:Suppress`, `@phpstan-ignore`, `nosemgrep`) is strictly forbidden.

---

## 4. Active Module Quality Gates

### `addon:docker` — Dockerfile & Docker Compose Validation, Hardening & Testing Fortress
- **Locked Configs**: `.hadolint.yaml` (strict Hadolint ruleset, `failure-threshold: warning`, `disable-ignore-pragma: true`).
- **Dockerfile Quality & Security Gates**: Bans `:latest` and untagged `FROM` images, validates multi-stage `AS <stage>` / `COPY --from=<stage>` references and rejects unused build stages, enforces final-stage non-root `USER` (bans `root`/`0`) and active `HEALTHCHECK` (bans `HEALTHCHECK NONE`), requires JSON exec-form `CMD`/`ENTRYPOINT`, bans `ADD` URLs, `sudo`, `eval`, `curl | sh`, relative `WORKDIR`, uncleaned `apk`/`apt-get`/`pip` caches, hardcoded `ENV`/`ARG` secrets, and requires `.dockerignore` excluding `.git` and `.env` when copying build context.
- **Compose Quality, Security & Testing Gates**: Bans obsolete top-level `version:`, `:latest`/untagged `image:`, `privileged: true`, host namespaces (`network_mode`/`pid`/`ipc`/`uts: host`), `/var/run/docker.sock` mounts, root `user:`, and plaintext `environment:` secrets; requires `healthcheck:`, `security_opt: [no-new-privileges:true]`, and explicit `restart:` on every service; tests `depends_on` DAG acyclicity, `secrets`/`volumes`/`networks` reference integrity, `build.context`/`dockerfile`/`target` stage existence, and `container-structure-test.yaml` schemas via `task test`.
