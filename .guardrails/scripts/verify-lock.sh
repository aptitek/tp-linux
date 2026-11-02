#!/usr/bin/env bash
# =============================================================================
# polyglot-guardrails — Configuration Anti-Tamper & Lock Verifier
# Master Source: modules/core/files/.guardrails/scripts/verify-lock.sh
# Executed automatically by `task guard:check`, `task verify`, and `pre-commit`
# =============================================================================
set -euo pipefail

PROJECT_ROOT="${1:-$(pwd)}"
LOCK_FILE="${PROJECT_ROOT}/.guardrails.lock"
MANIFEST_FILE="${PROJECT_ROOT}/.guardrails/manifest.json"
LOCAL_TASKFILE="${PROJECT_ROOT}/Taskfile.local.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

compute_sha256() {
  local target_file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$target_file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$target_file" | awk '{print $1}'
  else
    echo "ERROR: Neither sha256sum nor shasum is available." >&2
    exit 1
  fi
}

# Structurally extract top-level YAML keys inside the `tasks:` mapping block
# Supports unquoted keys, single/double-quoted keys ("guard:check":), and inline mappings (verify: { ... })
extract_taskfile_keys() {
  local tf="$1"
  [[ ! -f "$tf" ]] && return 0
  awk '
    /^tasks:[[:space:]]*(#.*)?$/ { in_tasks = 1; indent = -1; next }
    in_tasks && /^[^[:space:]#]/ { in_tasks = 0 }
    in_tasks && /^[[:space:]]+["\047]?[A-Za-z0-9_.:-]+["\047]?:([[:space:]]|$)/ {
      match($0, /^[[:space:]]+/)
      curr_indent = RLENGTH
      if (indent == -1) {
        indent = curr_indent
      }
      if (curr_indent == indent) {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        sub(/:.*$/, "", line)
        gsub(/^["\047]|["\047]$/, "", line)
        print line
      }
    }
  ' "$tf"
}

if [[ ! -f "$MANIFEST_FILE" ]]; then
  echo -e "${RED}[GUARDRAILS ERROR] Missing manifest file: .guardrails/manifest.json${NC}" >&2
  exit 1
fi

if [[ ! -f "$LOCK_FILE" ]]; then
  echo -e "${RED}[GUARDRAILS ERROR] Missing lock file: .guardrails.lock${NC}" >&2
  echo -e "${YELLOW}Run 'task guard:sync' to regenerate locked configurations from the master source.${NC}" >&2
  exit 1
fi

violations=0
checked_count=0
declare -A locked_paths=()

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  [[ -z "$line" || "$line" =~ ^# ]] && continue

  expected_hash="${line%%  *}"
  rel_path="${line#*  }"
  full_path="${PROJECT_ROOT}/${rel_path}"
  locked_paths["$rel_path"]=1
  checked_count=$((checked_count + 1))

  if [[ ! -f "$full_path" ]]; then
    echo -e "${RED}[TAMPER DETECTED] Locked configuration file was deleted: ${rel_path}${NC}" >&2
    violations=$((violations + 1))
    continue
  fi

  actual_hash="$(compute_sha256 "$full_path")"
  if [[ "$actual_hash" != "$expected_hash" ]]; then
    echo -e "${RED}[TAMPER DETECTED] Illicit modification in locked file: ${rel_path}${NC}" >&2
    echo -e "  Expected SHA-256: ${expected_hash}" >&2
    echo -e "  Actual   SHA-256: ${actual_hash}" >&2
    violations=$((violations + 1))
  fi
done < "$LOCK_FILE"

# Ensure no untracked files were injected into .guardrails/ OR .agents/
for managed_dir in ".guardrails" ".agents"; do
  if [[ -d "${PROJECT_ROOT}/${managed_dir}" ]]; then
    while IFS= read -r -d '' file; do
      rel_file="${file#"${PROJECT_ROOT}/"}"
      if [[ -z "${locked_paths[$rel_file]+x}" ]]; then
        echo -e "${RED}[TAMPER DETECTED] Unregistered file injected into ${managed_dir}/: ${rel_file}${NC}" >&2
        violations=$((violations + 1))
      fi
    done < <(find "${PROJECT_ROOT}/${managed_dir}" -type f -print0)
  fi
done

# Structural Taskfile.local.yml key intersection check across Taskfile.yml and ALL .guardrails/taskfiles/*.yml
if [[ -f "$LOCAL_TASKFILE" ]]; then
  declare -A protected_tasks=()
  for sys_tf in "${PROJECT_ROOT}/Taskfile.yml" "${PROJECT_ROOT}/.guardrails/taskfiles/"*.yml; do
    [[ ! -f "$sys_tf" ]] && continue
    tf_base="$(basename "$sys_tf")"
    tf_ns=""
    if [[ "$tf_base" =~ ^Taskfile\.([a-z0-9_-]+)\.yml$ ]] && [[ "${BASH_REMATCH[1]}" != "base" ]]; then
      tf_ns="${BASH_REMATCH[1]}"
    fi
    while IFS= read -r tkey; do
      [[ -z "$tkey" ]] && continue
      protected_tasks["$tkey"]=1
      if [[ -n "$tf_ns" ]]; then
        protected_tasks["${tf_ns}:${tkey}"]=1
        protected_tasks["${tkey}:${tf_ns}"]=1
      fi
    done < <(extract_taskfile_keys "$sys_tf")
  done

  while IFS= read -r local_key; do
    [[ -z "$local_key" ]] && continue
    if [[ -n "${protected_tasks[$local_key]+x}" ]]; then
      echo -e "${RED}[TAMPER DETECTED] Taskfile.local.yml attempts to override protected guardrail task '${local_key}'.${NC}" >&2
      violations=$((violations + 1))
    fi
  done < <(extract_taskfile_keys "$LOCAL_TASKFILE")
fi

if [[ "$violations" -gt 0 ]]; then
  echo "" >&2
  echo -e "${RED}=============================================================================${NC}" >&2
  echo -e "${RED} ZERO CONFIG DRIFT POLICY VIOLATION (${violations} issue(s) detected)${NC}" >&2
  echo -e "${RED}=============================================================================${NC}" >&2
  echo -e "${YELLOW}Configuration and quality guardrail files are strictly locked and managed by${NC}" >&2
  echo -e "${YELLOW}polyglot-guardrails. Manual or AI-agent edits to locked files are forbidden.${NC}" >&2
  echo -e "${YELLOW}  -> To revert your local changes: git checkout -- <file> or run 'task guard:sync'${NC}" >&2
  echo -e "${YELLOW}  -> To add local project tasks: use 'Taskfile.local.yml' only.${NC}" >&2
  exit 1
fi

echo -e "${GREEN}[GUARDRAILS OK] Verified ${checked_count} locked configuration files against .guardrails.lock (Zero Config Drift).${NC}"
exit 0
