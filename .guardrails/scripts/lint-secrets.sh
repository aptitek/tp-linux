#!/usr/bin/env bash
# =============================================================================
# lint-secrets.sh — Portable Secret Scanner Quality Gate (core)
# Prevents hardcoded API keys, credentials, private keys, and tokens.
# Zero-Bypass Policy: no inline comment suppression is permitted.
# Managed by polyglot-guardrails (DO NOT EDIT MANUALLY)
# =============================================================================
set -euo pipefail

ROOT_DIR="${1:-.}"
ERRORS=0

PEM_HEAD="-----BEGIN"
PEM_TAIL="PRIVATE KEY-----"
SECRET_RE="(${PEM_HEAD} (RSA |DSA |EC |OPENSSH |PGP )?${PEM_TAIL}|\\b(AKIA|ASIA)[0-9A-Z]{16}\\b|\\b((ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{36,255}|github_pat_[A-Za-z0-9_]{22,255})\\b|\\bglpat-[A-Za-z0-9_-]{20,}\\b|\\b(sk|rk)_live_[0-9a-zA-Z]{24,}\\b|\\bAIza[0-9A-Za-z_-]{35}\\b|\\bnpm_[A-Za-z0-9]{36}\\b|\\bsqp_[a-zA-Z0-9]{40}\\b)"

while IFS= read -r -d '' file; do
  base="$(basename "${file}")"
  if [[ "${base}" == ".env.example" || "${base}" == ".env.template" || "${base}" == ".guardrails.lock" || "${base}" == "pnpm-lock.yaml" || "${base}" == "uv.lock" ]]; then
    continue
  fi
  if grep -E -- "${SECRET_RE}" "${file}" >/dev/null 2>&1; then
    echo "❌ [Secret Scanner] ${file} — Detected hardcoded secret or private key." >&2
    ERRORS=$((ERRORS + 1))
  fi
done < <(find "${ROOT_DIR}" \
  -type d \( -name ".git" -o -name "node_modules" -o -name ".venv" -o -name "venv" -o -name ".cache" -o -name ".task" -o -name "dist" -o -name "build" -o -name "coverage" -o -name "__pycache__" -o -name "vendor" \) -prune \
  -o -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.mjs" -o -name "*.py" -o -name "*.java" -o -name "*.kt" -o -name "*.php" -o -name "*.sh" -o -name "*.json" -o -name "*.yml" -o -name "*.yaml" -o -name "*.toml" -o -name "*.env*" \) -print0)

if [[ "${ERRORS}" -gt 0 ]]; then
  exit 1
fi

echo "✅ [Secret Scanner] Repository verified, zero secrets exposed."
