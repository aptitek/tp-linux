---
name: clean-code-guard
description: >-
  Review and write production code enforcing Clean Code, SOLID, DRY, KISS, YAGNI,
  Lock 1 functional purity, and LLM-specific failure-mode checks. Activate before
  or after writing, editing, or refactoring code.
---

# Skill: Clean Code & Functional Purity Guard (`clean-code-guard`)

Apply these rules on every code change and run the self-check before delivery.

## 1. Functions, Naming, and Biometric Limits (Lock 1)
1. **Names reveal intent**: Never use `data`, `res`, `item`, `temp`, `val`, `obj`, `info`, `helper`, `utils`, or unqualified `handle_*`/`process_*`.
2. **Biometric ceilings (`src/`)**:
   - Cyclomatic complexity `<= 3`
   - Max nesting depth `<= 1` (use guard clauses / early returns; `else` is forbidden)
   - Max lines per function `<= 28`, max statements `<= 12`
   - Max parameters `<= 3` (use a `readonly` options object when more context is needed)
   - Max file length `<= 150` non-blank/non-comment lines
3. **Pure & Total Functions**:
   - Use `const` bindings exclusively (`let` and `var` are banned).
   - Never mutate objects or arrays in place; use `[...items]`, `.map()`, `.filter()`, `.reduce()`, `.toSorted()`.
   - Return explicit `Result<T, E>` discriminated unions instead of throwing exceptions (`throw` and `try/catch` are banned in pure modules).
   - Never use type assertions (`as T`), non-null assertions (`x!`), or user-defined type predicates (`x is T`). Parse with Zod or narrow via discriminated unions.

## 2. SOLID, DRY, KISS, YAGNI
1. **Single Responsibility (SRP)**: One actor and one reason to change per module.
2. **Knowledge Deduplication (DRY)**: `.jscpd.json` enforces `0%` code duplication across the repository, and `design-system.mjs` enforces commutative recipe deduplication.
3. **Zero Speculative Code (YAGNI)**: Never add unused parameters, feature flags, or unreferenced exports (`knip` fails on any unused file, export, or dependency).

## 3. AI-Specific Failure-Mode Checks
1. **Never swallow errors** or return fake/hardcoded success fixtures in production code.
2. **Guard the boundary; trust the internal contract**: Validate untrusted inputs at I/O boundaries (e.g. with Zod `safeParse`), and rely on strict TypeScript types internally.
3. **Never weaken or skip tests**: Fix the implementation, never the quality gate.
4. **Verify with `task check:quick` and `task verify`** before reporting completion.
