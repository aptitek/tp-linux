#!/usr/bin/env bash
# =============================================================================
# polyglot-guardrails — Purely Functional Policy Compiler & VFS Transaction CLI
# Master Source: modules/core/files/.guardrails/scripts/guardrails-cli.sh
# Commands:
#   init        --target <dir> --source <path|url> --modules <m1,m2,...>
#   sync        [--target <dir>] [--source <path|url>]
#   feature-add <module> [--target <dir>]
#   check       [--target <dir>]
#   lock        [--target <dir>]
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

declare -gA ALIAS_TO_ID=()
declare -gA MODULE_PATH_MAP=()
declare -g REGISTRY_MASTER_DIR=""
declare -ga TEMP_CLONES=()

cleanup_temp_clones() {
  if [[ "${#TEMP_CLONES[@]}" -gt 0 ]]; then
    rm -rf "${TEMP_CLONES[@]}"
  fi
}
trap cleanup_temp_clones EXIT

JQ_MONOID_DEFS='
  def array_contains_item($arr; $x):
    if ($x | type) == "object" and ($x | has("name")) then
      any($arr[]; (. | type) == "object" and .name == $x.name)
    else
      ($arr | index($x)) != null
    end;
  def monoid_merge($a; $b):
    if ($a | type) == "object" and ($b | type) == "object" then
      reduce (($a | keys_unsorted) + ($b | keys_unsorted) | unique[]) as $k
        ({}; .[$k] = (
          if ($a | has($k)) and ($b | has($k)) then monoid_merge($a[$k]; $b[$k])
          elif ($b | has($k)) then $b[$k]
          else $a[$k]
          end
        ))
    elif ($a | type) == "array" and ($b | type) == "array" then
      reduce ($a + $b)[] as $x ([]; if array_contains_item(.; $x) then . else . + [$x] end)
    else
      $b
    end;
  def fold_monoid:
    reduce .[] as $item (null; if . == null then $item else monoid_merge(.; $item) end);
'

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

find_master_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" && "$dir" != "." && ! "$dir" =~ ^[A-Za-z]:/?$ ]]; do
    if [[ -f "${dir}/modules/core/module.json" ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

load_module_registry() {
  local master_dir="$1"
  if [[ "$REGISTRY_MASTER_DIR" == "$master_dir" && "${#ALIAS_TO_ID[@]}" -gt 0 ]]; then
    return 0
  fi
  ALIAS_TO_ID=()
  MODULE_PATH_MAP=()
  REGISTRY_MASTER_DIR="$master_dir"

  local -a meta_files=()
  while IFS= read -r -d '' mf; do
    meta_files+=("$mf")
    local mid
    mid="$(jq -r '.id' "$mf")"
    MODULE_PATH_MAP["$mid"]="$(dirname "$mf")"
  done < <(find "${master_dir}/modules" -type f -name "module.json" -print0)

  local alias_key canonical_id
  while IFS=$'\t' read -r alias_key canonical_id; do
    [[ -z "$alias_key" ]] && continue
    ALIAS_TO_ID["$alias_key"]="$canonical_id"
  done < <(jq -r '.id as $id | ([$id] + (.aliases // []))[] | "\(.)\t\($id)"' "${meta_files[@]}")
}

normalize_module_id() {
  local master_dir="$1"
  local raw="$2"
  load_module_registry "$master_dir"
  local resolved="${ALIAS_TO_ID[$raw]:-}"
  if [[ -z "$resolved" ]]; then
    echo -e "${RED}[GUARDRAILS ERROR] Unknown module identifier: '${raw}'${NC}" >&2
    return 1
  fi
  echo "$resolved"
}

layer_sort_key() {
  local mod_id="$1"
  case "$mod_id" in
    core) echo "0:${mod_id}" ;;
    lang:*) echo "1:${mod_id}" ;;
    fw:*) echo "2:${mod_id}" ;;
    addon:*) echo "3:${mod_id}" ;;
    *) echo "9:${mod_id}" ;;
  esac
}

resolve_modules() {
  local master_dir="$1"
  shift
  local requested=("$@")
  load_module_registry "$master_dir"

  # Pass 1: Reachability & 3-color cycle detection (0=unvisited, 1=visiting, 2=visited)
  local -A visit_color=()
  local -A reachable=()

  collect_reachable() {
    local mod_id
    mod_id="$(normalize_module_id "$master_dir" "$1")"
    local color="${visit_color[$mod_id]:-0}"
    if [[ "$color" -eq 2 ]]; then
      return 0
    fi
    if [[ "$color" -eq 1 ]]; then
      echo -e "${RED}[GUARDRAILS DAG ERROR] Circular dependency detected involving '${mod_id}'${NC}" >&2
      return 1
    fi
    visit_color["$mod_id"]=1

    local mod_dir="${MODULE_PATH_MAP[$mod_id]:-}"
    local meta_file="${mod_dir}/module.json"
    if [[ -z "$mod_dir" || ! -f "$meta_file" ]]; then
      echo -e "${RED}[GUARDRAILS ERROR] Module metadata not found: ${meta_file}${NC}" >&2
      return 1
    fi

    local dep
    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      collect_reachable "$dep"
    done < <(jq -r '.depends_on[]?' "$meta_file")

    visit_color["$mod_id"]=2
    reachable["$mod_id"]=1
  }

  collect_reachable "core"
  for req in "${requested[@]}"; do
    [[ -z "$req" ]] && continue
    collect_reachable "$req"
  done

  # Verify mutual exclusion (conflicts_with) across all reachable modules
  local mod_u conflict_raw conflict_id
  for mod_u in "${!reachable[@]}"; do
    local meta_u="${MODULE_PATH_MAP[$mod_u]}/module.json"
    while IFS= read -r conflict_raw; do
      [[ -z "$conflict_raw" ]] && continue
      conflict_id="$(normalize_module_id "$master_dir" "$conflict_raw")"
      if [[ -n "${reachable[$conflict_id]+x}" ]]; then
        echo -e "${RED}[GUARDRAILS CONFLICT ERROR] Module '${mod_u}' conflicts with '${conflict_id}'.${NC}" >&2
        return 1
      fi
    done < <(jq -r '.conflicts_with[]?' "$meta_u")
  done

  # Pass 2: Canonical Commutative Topological Sort
  local -a canonical_candidates=()
  while IFS= read -r sorted_entry; do
    [[ -z "$sorted_entry" ]] && continue
    canonical_candidates+=("${sorted_entry#*:}")
  done < <(
    for m in "${!reachable[@]}"; do
      layer_sort_key "$m"
    done | LC_ALL=C sort -u
  )

  local -A emitted=()
  local -a resolved=()

  topo_emit() {
    local mod_id="$1"
    if [[ -n "${emitted[$mod_id]+x}" ]]; then
      return 0
    fi
    local meta_file="${MODULE_PATH_MAP[$mod_id]}/module.json"
    local -a sorted_deps=()
    while IFS= read -r dep_entry; do
      [[ -z "$dep_entry" ]] && continue
      sorted_deps+=("${dep_entry#*:}")
    done < <(
      while IFS= read -r raw_dep; do
        [[ -z "$raw_dep" ]] && continue
        local norm_dep
        norm_dep="$(normalize_module_id "$master_dir" "$raw_dep")"
        layer_sort_key "$norm_dep"
      done < <(jq -r '.depends_on[]?' "$meta_file") | LC_ALL=C sort -u
    )

    local dep
    for dep in "${sorted_deps[@]}"; do
      topo_emit "$dep"
    done
    emitted["$mod_id"]=1
    resolved+=("$mod_id")
  }

  local cand
  for cand in "${canonical_candidates[@]}"; do
    topo_emit "$cand"
  done

  printf '%s\n' "${resolved[@]}"
}

resolve_source_dir() {
  local source_spec="$1"
  if [[ -d "$source_spec" ]]; then
    (cd "$source_spec" && pwd)
    return 0
  fi

  local tmp_clone
  tmp_clone="$(mktemp -d -t guardrails-src-XXXXXX)"
  TEMP_CLONES+=("$tmp_clone")
  git clone --depth 1 -c core.autocrlf=false "$source_spec" "$tmp_clone" >/dev/null 2>&1
  echo "$tmp_clone"
}

get_source_commit() {
  local src_dir="$1"
  if git -C "$src_dir" rev-parse --short HEAD >/dev/null 2>&1; then
    git -C "$src_dir" rev-parse --short HEAD
  else
    echo "local-uncommitted"
  fi
}

generate_vfs_lockfile() {
  local vfs_dir="$1"
  local lock_file="${vfs_dir}/.guardrails.lock"
  local -a vfs_files=()

  while IFS= read -r -d '' fpath; do
    local rel_f="${fpath#"${vfs_dir}/"}"
    [[ "$rel_f" == ".guardrails.lock" ]] && continue
    vfs_files+=("$rel_f")
  done < <(find "$vfs_dir" -type f -print0)

  mapfile -t sorted_files < <(printf '%s\n' "${vfs_files[@]}" | LC_ALL=C sort -u)

  {
    echo "# ============================================================================="
    echo "# .guardrails.lock — DO NOT EDIT MANUALLY (Zero Config Drift)"
    echo "# Managed automatically by polyglot-guardrails ('task guard:sync')."
    echo "# ============================================================================="
    local rel_path hash
    for rel_path in "${sorted_files[@]}"; do
      hash="$(compute_sha256 "${vfs_dir}/${rel_path}")"
      printf '%s  %s\n' "$hash" "$rel_path"
    done
  } > "$lock_file"
}

generate_lockfile() {
  local target_dir="$1"
  local lock_file="${target_dir}/.guardrails.lock"
  local -a existing_files=()

  if [[ -f "$lock_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      local rel="${line#*  }"
      if [[ -f "${target_dir}/${rel}" ]]; then
        existing_files+=("$rel")
      fi
    done < "$lock_file"
  fi

  for dir_name in ".guardrails" ".agents"; do
    if [[ -d "${target_dir}/${dir_name}" ]]; then
      while IFS= read -r -d '' gf; do
        existing_files+=("${gf#"${target_dir}/"}")
      done < <(find "${target_dir}/${dir_name}" -type f -print0)
    fi
  done

  mapfile -t sorted_files < <(printf '%s\n' "${existing_files[@]}" | LC_ALL=C sort -u)

  {
    echo "# ============================================================================="
    echo "# .guardrails.lock — DO NOT EDIT MANUALLY (Zero Config Drift)"
    echo "# Managed automatically by polyglot-guardrails ('task guard:sync')."
    echo "# ============================================================================="
    local rel_path hash
    for rel_path in "${sorted_files[@]}"; do
      hash="$(compute_sha256 "${target_dir}/${rel_path}")"
      printf '%s  %s\n' "$hash" "$rel_path"
    done
  } > "$lock_file"
}

copy_tree_strict_no_collision() {
  local src_root="$1"
  local vfs_dir="$2"
  local mod_id="$3"
  local -n owners_ref="$4"

  [[ ! -d "$src_root" ]] && return 0

  while IFS= read -r -d '' src_file; do
    local rel_path="${src_file#"${src_root}/"}"
    local dest_file="${vfs_dir}/${rel_path}"
    if [[ -e "$dest_file" ]]; then
      local prev_owner="${owners_ref[$rel_path]:-unknown}"
      echo -e "${RED}[GUARDRAILS COLLISION ERROR] Static file collision on '${rel_path}' between '${prev_owner}' and '${mod_id}'. Move shared configs to 'fragments/' for monoidal merge.${NC}" >&2
      return 1
    fi
    mkdir -p "$(dirname "$dest_file")"
    cp -P "$src_file" "$dest_file"
    owners_ref["$rel_path"]="$mod_id"
  done < <(find "$src_root" -type f -print0)
}

fold_json_fragments() {
  local vfs_dir="$1"
  local rel_path="$2"
  shift 2
  local frag_files=("$@")
  local dest_file="${vfs_dir}/${rel_path}"
  mkdir -p "$(dirname "$dest_file")"

  jq -s "${JQ_MONOID_DEFS} fold_monoid" "${frag_files[@]}" > "$dest_file"
}

fold_toml_json_fragments() {
  local vfs_dir="$1"
  local toml_rel_path="$2"
  shift 2
  local frag_files=("$@")
  local dest_file="${vfs_dir}/${toml_rel_path}"
  mkdir -p "$(dirname "$dest_file")"

  jq -rs "${JQ_MONOID_DEFS}
    def toml_val(\$v): (\$v | tojson);
    def toml_key(\$k): if (\$k | test(\"^[A-Za-z0-9_-]+\$\")) then \$k else (\$k | tojson) end;
    def emit_scalars(\$obj):
      [(\$obj | to_entries[] | select((.value | type) != \"object\") | \"\(toml_key(.key)) = \(toml_val(.value))\")];
    def emit_tables(\$obj; \$prefix):
      [(\$obj | to_entries[] | select((.value | type) == \"object\")) as \$e |
        (if \$prefix == \"\" then toml_key(\$e.key) else \"\(\$prefix).\(toml_key(\$e.key))\" end) as \$sec |
        (emit_scalars(\$e.value)) as \$sc |
        (if (\$sc | length) > 0 then [\"\", \"[\(\$sec)]\"] + \$sc else [] end) +
        emit_tables(\$e.value; \$sec)
      ] | add // [];
    fold_monoid
    | ([
        \"# =============================================================================\",
        \"# ${toml_rel_path} — Compiled by polyglot-guardrails Monoidal TOML Algebra\",
        \"# Managed by polyglot-guardrails (DO NOT EDIT MANUALLY)\",
        \"# =============================================================================\"
      ] + emit_scalars(.) + emit_tables(.; \"\"))
    | join(\"\\n\")
  " "${frag_files[@]}" > "$dest_file"
}

synthesize_lefthook_and_scopes() {
  local vfs_dir="$1"
  shift
  local meta_files=("$@")

  local scopes_json
  scopes_json="$(jq -s '[.[].commit_scopes[]?] | unique' "${meta_files[@]}")"
  printf '%s\n' "$scopes_json" > "${vfs_dir}/.guardrails/commit-scopes.json"

  local scopes_pipe
  scopes_pipe="$(jq -r '.[]' "${vfs_dir}/.guardrails/commit-scopes.json" | paste -sd '|' -)"

  cat > "${vfs_dir}/lefthook.yml" <<EOF
# =============================================================================
# lefthook.yml — Git Hooks Guardrails (Compiled by polyglot-guardrails)
# Dynamically compiled commit scopes from active modules in manifest.json.
# Managed by polyglot-guardrails (DO NOT EDIT MANUALLY)
# =============================================================================
commit-msg:
  commands:
    commitlint:
      run: |
        MSG_FILE="{1}"
        if [ -f "\$MSG_FILE" ]; then
          HEADER=\$(head -n 1 "\$MSG_FILE")
          if [ "\${#HEADER}" -gt 100 ] || ! echo "\$HEADER" | grep -E -q '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)\\((${scopes_pipe})\\): .{14,99}[^.]\$'; then
            echo "[COMMITLINT ERROR] Commit header must be <= 100 chars, not end with '.', and match '<type>(<scope>): <subject (>= 15 chars)>' with an allowed architectural scope (${scopes_pipe})." >&2
            exit 1
          fi
        fi

pre-commit:
  parallel: false
  commands:
    guard-check:
      run: \$(command -v task || command -v go-task) guard:check
    format-and-lint:
      run: \$(command -v task || command -v go-task) format lint STAGED_FILES="{staged_files}"
    complexity:
      run: \$(command -v task || command -v go-task) complexity STAGED_FILES="{staged_files}"

pre-push:
  parallel: false
  commands:
    verify:
      run: \$(command -v task || command -v go-task) verify
EOF
}

synthesize_taskfile() {
  local vfs_dir="$1"
  shift
  local active_modules=("$@")
  local taskfile="${vfs_dir}/Taskfile.yml"
  {
    echo "# ============================================================================="
    echo "# Taskfile.yml — Universal Bootstrap & Polyglot Guardrails Contract"
    echo "# Managed by polyglot-guardrails (DO NOT EDIT MANUALLY)"
    echo "# Active modules: ${active_modules[*]}"
    echo "# For project-specific tasks or variables, create 'Taskfile.local.yml'."
    echo "#"
    echo "# Universal One-Liner Bootstrap (Linux / macOS / Windows MSYS2 / Git Bash):"
    echo "#   curl -fsSL https://raw.githubusercontent.com/aptitek/metadevkit/main/scripts/bootstrap.sh | bash -s -- python,django"
    echo "#   curl -fsSLO https://raw.githubusercontent.com/aptitek/metadevkit/main/Taskfile.yml && task init MODULES=python,django"
    echo "# Windows PowerShell (Auto-installs MSYS2 + go-task + mise + initializes project):"
    echo "#   irm https://raw.githubusercontent.com/aptitek/metadevkit/main/scripts/bootstrap.ps1 | iex"
    echo "# ============================================================================="
    echo "version: '3'"
    echo ""
    echo "vars:"
    echo "  MODULES: '{{.MODULES | default \"core,lang:ts\"}}'"
    echo "  REPO_URL: '{{.REPO_URL | default \"https://github.com/aptitek/metadevkit.git\"}}'"
    echo ""
    echo "includes:"
    echo "  base:"
    echo "    taskfile: ./.guardrails/taskfiles/Taskfile.base.yml"
    echo "    flatten: true"
    echo "    optional: true"
    local mod_id
    for mod_id in "${active_modules[@]}"; do
      [[ "${mod_id}" == "core" ]] && continue
      local short="${mod_id#*:}"
      if [[ -f "${vfs_dir}/.guardrails/taskfiles/Taskfile.${short}.yml" ]]; then
        echo "  ${short}:"
        echo "    taskfile: ./.guardrails/taskfiles/Taskfile.${short}.yml"
        echo "    optional: true"
      fi
    done
    echo "  local:"
    echo "    taskfile: ./Taskfile.local.yml"
    echo "    optional: true"
    echo ""
    echo "tasks:"
    echo "  default:"
    echo "    desc: \"Bootstrap project if uninitialized, otherwise run full verification suite\""
    echo "    cmds:"
    echo "      - |"
    echo "        if [ ! -f ./.guardrails/manifest.json ]; then"
    echo "          {{.TASK_EXE}} bootstrap MODULES=\"{{.MODULES}}\" REPO_URL=\"{{.REPO_URL}}\""
    echo "        else"
    echo "          {{.TASK_EXE}} verify"
    echo "        fi"
    echo ""
    echo "  bootstrap:"
    echo "    desc: \"Auto-provision prerequisites (MSYS2 on Windows, mise) and initialize project from local or remote master\""
    echo "    cmds:"
    echo "      - |"
    echo "        if [ \"\${OS:-}\" = \"Windows_NT\" ] || uname -s 2>/dev/null | grep -qiE \"mingw|msys|cygwin\"; then"
    echo "          if [ ! -x \"/c/msys64/usr/bin/bash.exe\" ] && [ ! -x \"C:/msys64/usr/bin/bash.exe\" ] && command -v winget.exe >/dev/null 2>&1; then"
    echo "            winget.exe install -e --id MSYS2.MSYS2 --accept-source-agreements --accept-package-agreements </dev/null || [ -x \"/c/msys64/usr/bin/bash.exe\" ] || [ -x \"C:/msys64/usr/bin/bash.exe\" ]"
    echo "          fi"
    echo "          for msys_bin in \"/c/msys64/usr/bin\" \"C:/msys64/usr/bin\"; do"
    echo "            if [ -d \"\$msys_bin\" ]; then"
    echo "              export PATH=\"\${msys_bin}:\${PATH}\""
    echo "              if [ -x \"\${msys_bin}/pacman.exe\" ]; then"
    echo "                \"\${msys_bin}/pacman.exe\" -S --noconfirm --needed bash git jq curl tar </dev/null"
    echo "              fi"
    echo "              break"
    echo "            fi"
    echo "          done"
    echo "        fi"
    echo "        if [ \"\${GUARDRAILS_FIXTURE_MODE:-0}\" != \"1\" ] && ! command -v mise >/dev/null 2>&1; then"
    echo "          if command -v winget.exe >/dev/null 2>&1; then"
    echo "            winget.exe install -e --id jdx.mise --accept-source-agreements --accept-package-agreements </dev/null || command -v mise >/dev/null 2>&1"
    echo "          elif command -v brew >/dev/null 2>&1; then"
    echo "            brew install mise </dev/null"
    echo "          elif command -v curl >/dev/null 2>&1; then"
    echo "            mise_tmp=\"\$(mktemp -d)\""
    echo "            curl -fsSL https://mise.run -o \"\${mise_tmp}/install.sh\" && sh \"\${mise_tmp}/install.sh\" </dev/null"
    echo "            rm -rf \"\${mise_tmp}\""
    echo "            export PATH=\"\${HOME}/.local/bin:\${HOME}/.local/share/mise/shims:\${PATH}\""
    echo "          fi"
    echo "        fi"
    echo "        if [ -d \"{{.REPO_URL}}/modules/core\" ]; then"
    echo "          GUARDRAILS_ORIGIN_URL=\"{{.REPO_URL}}\" bash \"{{.REPO_URL}}/modules/core/files/.guardrails/scripts/guardrails-cli.sh\" init --target \".\" --source \"{{.REPO_URL}}\" --modules \"{{.MODULES}}\" {{.CLI_ARGS}}"
    echo "        else"
    echo "          tmp_src=\"\$(mktemp -d)\""
    echo "          trap 'rm -rf \"\${tmp_src}\"' EXIT"
    echo "          git clone --depth 1 -c core.autocrlf=false \"{{.REPO_URL}}\" \"\${tmp_src}\""
    echo "          GUARDRAILS_ORIGIN_URL=\"{{.REPO_URL}}\" bash \"\${tmp_src}/modules/core/files/.guardrails/scripts/guardrails-cli.sh\" init --target \".\" --source \"\${tmp_src}\" --modules \"{{.MODULES}}\" {{.CLI_ARGS}}"
    echo "        fi"
    echo "        if [ \"\${GUARDRAILS_FIXTURE_MODE:-0}\" != \"1\" ] && command -v mise >/dev/null 2>&1; then"
    echo "          mise trust -a </dev/null"
    echo "          mise install </dev/null"
    echo "        fi"
    echo ""
    echo "  init:"
    echo "    desc: \"Initialize or convert a project (auto-bootstraps from remote if .guardrails is absent)\""
    echo "    cmds:"
    echo "      - |"
    echo "        if [ -f ./.guardrails/scripts/guardrails-cli.sh ]; then"
    echo "          if [ -n \"{{.CLI_ARGS}}\" ]; then"
    echo "            bash ./.guardrails/scripts/guardrails-cli.sh init {{.CLI_ARGS}}"
    echo "          else"
    echo "            src_url=\"{{.REPO_URL}}\""
    echo "            if [ -f ./.guardrails/manifest.json ] && [ \"\$src_url\" = \"https://github.com/aptitek/metadevkit.git\" ]; then"
    echo "              manifest_src=\"\$(jq -r '.master_source // empty' ./.guardrails/manifest.json)\""
    echo "              [ -n \"\$manifest_src\" ] && src_url=\"\$manifest_src\""
    echo "            fi"
    echo "            bash ./.guardrails/scripts/guardrails-cli.sh init --target \".\" --source \"\$src_url\" --modules \"{{.MODULES}}\""
    echo "          fi"
    echo "        else"
    echo "          {{.TASK_EXE}} bootstrap MODULES=\"{{.MODULES}}\" REPO_URL=\"{{.REPO_URL}}\" CLI_ARGS=\"{{.CLI_ARGS}}\""
    echo "        fi"
  } > "$taskfile"
}

apply_modules() {
  local target_dir="$1"
  local source_spec="$2"
  shift 2
  local input_modules=("$@")

  local master_dir
  master_dir="$(resolve_source_dir "$source_spec")"
  load_module_registry "$master_dir"

  local -a active_modules=()
  mapfile -t active_modules < <(resolve_modules "$master_dir" "${input_modules[@]}")
  if [[ "${#active_modules[@]}" -eq 0 ]]; then
    return 1
  fi

  mkdir -p "$target_dir"
  target_dir="$(cd "$target_dir" && pwd)"

  echo -e "${BLUE}[GUARDRAILS] Synchronizing modules: ${active_modules[*]}${NC}"

  # ===========================================================================
  # PHASE 1: Pure VFS Synthesis (Isolated in $vfs_dir)
  # ===========================================================================
  local vfs_dir
  vfs_dir="$(mktemp -d -t guardrails-vfs-XXXXXX)"

  mkdir -p \
    "${vfs_dir}/.guardrails/ast" \
    "${vfs_dir}/.guardrails/taskfiles" \
    "${vfs_dir}/.guardrails/scripts" \
    "${vfs_dir}/.agents/rules" \
    "${vfs_dir}/.agents/skills"

  local mise_file="${vfs_dir}/mise.toml"
  {
    echo "# ============================================================================="
    echo "# mise.toml — Managed by polyglot-guardrails (DO NOT EDIT MANUALLY)"
    echo "# Active modules: ${active_modules[*]}"
    echo "# ============================================================================="
    echo "[tools]"
  } > "$mise_file"

  local gitignore_file="${vfs_dir}/.gitignore"
  {
    echo "# ============================================================================="
    echo "# .gitignore — Managed by polyglot-guardrails (DO NOT EDIT MANUALLY)"
    echo "# Active modules: ${active_modules[*]}"
    echo "# For project-specific ignore rules, create '.gitignore.local'."
    echo "# ============================================================================="
  } > "$gitignore_file"

  local agents_file="${vfs_dir}/AGENTS.md"
  : > "$agents_file"

  local -A active_set=()
  local -a active_meta_files=()
  local mod_id
  for mod_id in "${active_modules[@]}"; do
    active_set["$mod_id"]=1
    active_meta_files+=("${MODULE_PATH_MAP[$mod_id]}/module.json")
  done

  local -A vfs_owners=()
  local -A fragment_rel_paths=()

  for mod_id in "${active_modules[@]}"; do
    local mod_path="${MODULE_PATH_MAP[$mod_id]}"
    local meta_file="${mod_path}/module.json"

    if [[ -f "${mod_path}/mise.fragment.toml" ]]; then
      echo "" >> "$mise_file"
      cat "${mod_path}/mise.fragment.toml" >> "$mise_file"
    fi

    if [[ -f "${mod_path}/gitignore.fragment" ]]; then
      echo "" >> "$gitignore_file"
      cat "${mod_path}/gitignore.fragment" >> "$gitignore_file"
    fi

    if [[ -f "${mod_path}/AGENTS.fragment.md" ]]; then
      if [[ -s "$agents_file" ]]; then
        echo "" >> "$agents_file"
      fi
      cat "${mod_path}/AGENTS.fragment.md" >> "$agents_file"
    fi

    if [[ -d "${mod_path}/files" ]]; then
      if ! copy_tree_strict_no_collision "${mod_path}/files" "$vfs_dir" "$mod_id" vfs_owners; then
        rm -rf "$vfs_dir"
        return 1
      fi
    fi

    # Evaluate declarative conditional_files from module.json
    local cond_count
    cond_count="$(jq '.conditional_files | length' "$meta_file")"
    if [[ "$cond_count" -gt 0 ]]; then
      local idx
      for ((idx = 0; idx < cond_count; idx++)); do
        local all_satisfied=1
        local req_mod
        while IFS= read -r req_mod; do
          [[ -z "$req_mod" ]] && continue
          if [[ -z "${active_set[$req_mod]+x}" ]]; then
            all_satisfied=0
            break
          fi
        done < <(jq -r ".conditional_files[$idx].when_all[]?" "$meta_file")

        if [[ "$all_satisfied" -eq 1 ]]; then
          local cond_src
          cond_src="$(jq -r ".conditional_files[$idx].source_dir" "$meta_file")"
          if [[ -d "${mod_path}/${cond_src}" ]]; then
            if ! copy_tree_strict_no_collision "${mod_path}/${cond_src}" "$vfs_dir" "$mod_id" vfs_owners; then
              rm -rf "$vfs_dir"
              return 1
            fi
          fi
        fi
      done
    fi

    if [[ -d "${mod_path}/fragments" ]]; then
      while IFS= read -r -d '' frag_f; do
        local f_rel="${frag_f#"${mod_path}/fragments/"}"
        fragment_rel_paths["$f_rel"]=1
      done < <(find "${mod_path}/fragments" -type f -print0)
    fi
  done

  # Fold all discovered fragments in canonical topological order via jq Monoid
  local frag_rel
  for frag_rel in "${!fragment_rel_paths[@]}"; do
    local -a sources=()
    for mod_id in "${active_modules[@]}"; do
      local candidate="${MODULE_PATH_MAP[$mod_id]}/fragments/${frag_rel}"
      if [[ -f "$candidate" ]]; then
        sources+=("$candidate")
      fi
    done
    if [[ "${#sources[@]}" -gt 0 ]]; then
      local target_rel="$frag_rel"
      [[ "$frag_rel" == *.toml.json ]] && target_rel="${frag_rel%.json}"
      if [[ -n "${vfs_owners[$target_rel]+x}" ]]; then
        echo -e "${RED}[GUARDRAILS COLLISION ERROR] Fragment '${target_rel}' collides with static file from '${vfs_owners[$target_rel]}'.${NC}" >&2
        rm -rf "$vfs_dir"
        return 1
      fi
      case "$frag_rel" in
        *.toml.json) fold_toml_json_fragments "$vfs_dir" "$target_rel" "${sources[@]}" ;;
        *.json) fold_json_fragments "$vfs_dir" "$target_rel" "${sources[@]}" ;;
      esac
    fi
  done

  if [[ -f "${target_dir}/.gitignore.local" ]]; then
    echo "" >> "$gitignore_file"
    echo "# --- Project-specific (.gitignore.local) ---" >> "$gitignore_file"
    cat "${target_dir}/.gitignore.local" >> "$gitignore_file"
  fi

  synthesize_lefthook_and_scopes "$vfs_dir" "${active_meta_files[@]}"
  synthesize_taskfile "$vfs_dir" "${active_modules[@]}"

  chmod +x "${vfs_dir}/.guardrails/scripts/"*.sh 2>/dev/null || true

  local commit_sha
  commit_sha="$(get_source_commit "$master_dir")"
  local modules_json
  modules_json="$(printf '%s\n' "${active_modules[@]}" | jq -R . | jq -s .)"
  local manifest_source="${GUARDRAILS_ORIGIN_URL:-$source_spec}"
  if [[ "${target_dir}" == "${master_dir}" ]]; then
    manifest_source="."
  fi

  jq -n \
    --arg version "1.0.0" \
    --arg source "$manifest_source" \
    --arg commit "$commit_sha" \
    --argjson modules "$modules_json" \
    '{
      schema_version: $version,
      master_source: $source,
      master_commit: $commit,
      modules: $modules
    }' > "${vfs_dir}/.guardrails/manifest.json"

  # ===========================================================================
  # PHASE 2: Deterministic Lockfile Calculation on VFS (Zero CandidateFiles)
  # ===========================================================================
  generate_vfs_lockfile "$vfs_dir"

  # ===========================================================================
  # PHASE 3: Differential Orphan Purge & Atomic VFS Reconciliation
  # ===========================================================================
  if [[ -f "${target_dir}/.guardrails.lock" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      local old_rel="${line#*  }"
      if [[ ! -f "${vfs_dir}/${old_rel}" ]]; then
        rm -f "${target_dir}/${old_rel}"
      fi
    done < "${target_dir}/.guardrails.lock"
  fi

  while IFS= read -r -d '' vfs_file; do
    local rel_dest="${vfs_file#"${vfs_dir}/"}"
    mkdir -p "$(dirname "${target_dir}/${rel_dest}")"
    rm -f "${target_dir}/${rel_dest}"
    cp -P "$vfs_file" "${target_dir}/${rel_dest}"
  done < <(find "$vfs_dir" -type f -print0)

  for managed_root in "${target_dir}/.guardrails" "${target_dir}/.agents" "${target_dir}/.storybook"; do
    if [[ -d "$managed_root" ]]; then
      find "$managed_root" -type d -empty -delete 2>/dev/null || true
    fi
  done
  mkdir -p \
    "${target_dir}/.guardrails/ast" \
    "${target_dir}/.guardrails/taskfiles" \
    "${target_dir}/.guardrails/scripts" \
    "${target_dir}/.agents/rules" \
    "${target_dir}/.agents/skills"

  rm -rf "$vfs_dir"

  echo -e "${GREEN}[GUARDRAILS] Successfully synchronized ${#active_modules[@]} module(s) and locked configuration checksums.${NC}"
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  init)
    target_dir="."
    source_spec=""
    modules_csv="core,lang:ts"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --target) target_dir="$2"; shift 2 ;;
        --source) source_spec="$2"; shift 2 ;;
        --modules) modules_csv="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
      esac
    done
    if [[ -z "$source_spec" ]]; then
      if ! source_spec="$(find_master_root 2>/dev/null)"; then
        if [[ -f "${target_dir}/.guardrails/manifest.json" ]]; then
          source_spec="$(jq -r '.master_source // empty' "${target_dir}/.guardrails/manifest.json")"
        fi
        source_spec="${source_spec:-https://github.com/aptitek/metadevkit.git}"
      fi
    fi
    IFS=',' read -r -a raw_mods <<< "$modules_csv"
    apply_modules "$target_dir" "$source_spec" "${raw_mods[@]}"
    ;;

  sync)
    target_dir="."
    source_override=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --target) target_dir="$2"; shift 2 ;;
        --source) source_override="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
      esac
    done
    manifest="${target_dir}/.guardrails/manifest.json"
    if [[ ! -f "$manifest" ]]; then
      echo -e "${RED}[GUARDRAILS ERROR] Cannot sync: ${manifest} not found.${NC}" >&2
      exit 1
    fi
    source_spec="${source_override:-$(jq -r '.master_source' "$manifest")}"
    mapfile -t current_mods < <(jq -r '.modules[]' "$manifest")
    apply_modules "$target_dir" "$source_spec" "${current_mods[@]}"
    ;;

  feature-add)
    if [[ $# -lt 1 ]]; then
      echo -e "${RED}Usage: guardrails-cli.sh feature-add <module> [--target <dir>]${NC}" >&2
      exit 1
    fi
    new_mod=""
    target_dir="."
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --target) target_dir="$2"; shift 2 ;;
        *)
          if [[ -z "$new_mod" ]]; then
            new_mod="$1"
          fi
          shift
          ;;
      esac
    done
    manifest="${target_dir}/.guardrails/manifest.json"
    if [[ ! -f "$manifest" ]]; then
      echo -e "${RED}[GUARDRAILS ERROR] Cannot add feature: ${manifest} not found.${NC}" >&2
      exit 1
    fi
    source_spec="$(jq -r '.master_source' "$manifest")"
    master_dir="$(resolve_source_dir "$source_spec")"
    canonical_mod="$(normalize_module_id "$master_dir" "$new_mod")"
    mapfile -t current_mods < <(jq -r '.modules[]' "$manifest")
    current_mods+=("$canonical_mod")
    echo -e "${BLUE}[GUARDRAILS] Adding module '${canonical_mod}' to project...${NC}"
    GUARDRAILS_ORIGIN_URL="${GUARDRAILS_ORIGIN_URL:-$source_spec}" apply_modules "$target_dir" "$master_dir" "${current_mods[@]}"
    ;;

  check)
    target_dir="."
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --target) target_dir="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${target_dir}/.guardrails/scripts/verify-lock.sh" ]]; then
      bash "${target_dir}/.guardrails/scripts/verify-lock.sh" "$target_dir"
    else
      bash "${script_dir}/verify-lock.sh" "$target_dir"
    fi
    ;;

  lock)
    target_dir="."
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --target) target_dir="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    generate_lockfile "$target_dir"
    ;;

  *)
    echo "Usage: guardrails-cli.sh {init|sync|feature-add|check|lock}"
    exit 1
    ;;
esac
