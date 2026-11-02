#!/usr/bin/env bash
# =============================================================================
# validate-docker.sh — Docker, .dockerignore & Compose Security & Testing Gate (addon:docker)
# Modes:
#   validate-docker.sh [--lint|--sec|--test] [root_dir]
# Enforces:
#   1. Locked .hadolint.yaml configuration presence
#   2. Dockerfile AST & Multi-Stage Gate:
#      - Zero linter bypass pragmas (# hadolint ignore=, # check=skip=)
#      - Pinned base image tags/digests in FROM (bans :latest and untagged images)
#      - Multi-stage alias uniqueness, COPY --from=<stage> reference validity,
#        and zero unused/dead build stages
#      - Final runtime stage non-root USER (bans missing USER, root, or UID 0)
#      - Final runtime stage active HEALTHCHECK (bans missing or HEALTHCHECK NONE)
#      - RUN hardening (bans sudo, eval, curl/wget | sh, and uncleaned apk/apt/pip caches)
#      - Instruction hygiene (bans ADD URLs/non-archives, relative WORKDIR,
#        shell-form CMD/ENTRYPOINT, and hardcoded ENV/ARG secrets)
#   3. .dockerignore Context Leak Gate:
#      - Requires .dockerignore excluding .git and .env when COPY . is used
#   4. Docker Compose Hardening & Topology Testing Gate:
#      - Bans obsolete top-level 'version:' field
#      - Enforces pinned images, healthcheck, security_opt: [no-new-privileges:true],
#        explicit restart policy, non-root user, and zero plaintext environment secrets
#      - Bans privileged: true, host namespaces (network_mode/pid/ipc/uts: host),
#        and /var/run/docker.sock mounts
#      - Verifies secrets, volumes, networks, depends_on DAG acyclicity, and
#        build context / Dockerfile / target stage existence
#   5. Container Structure Test (container-structure-test.yaml) schema verification
# Managed by polyglot-guardrails (DO NOT EDIT MANUALLY)
# =============================================================================
set -euo pipefail

MODE="all"
case "${1:-}" in
  --lint)
    MODE="lint"
    shift
    ;;
  --sec)
    MODE="sec"
    shift
    ;;
  --test)
    MODE="test"
    shift
    ;;
esac

ROOT_DIR="${1:-.}"
ERRORS=0
DOCKERFILE_COUNT=0
COMPOSE_COUNT=0

if [[ ! -f "${ROOT_DIR}/.hadolint.yaml" ]]; then
  echo "❌ [DOCKER GATE] Missing locked .hadolint.yaml Dockerfile linter configuration." >&2
  ERRORS=$((ERRORS + 1))
fi

check_dockerignore_file() {
  local ignore_file="$1"
  local has_git=0
  local has_env=0

  if grep -vE '^[[:space:]]*#' "${ignore_file}" | grep -E -q '^[[:space:]]*(\*\*/)?\.git(/|\*)?[[:space:]]*$'; then
    has_git=1
  fi
  if grep -vE '^[[:space:]]*#' "${ignore_file}" | grep -E -q '^[[:space:]]*(\*\*/)?\.env(\*|\.\*)?[[:space:]]*$'; then
    has_env=1
  fi

  if [[ "${has_git}" -eq 0 || "${has_env}" -eq 0 ]]; then
    echo "❌ [DOCKER GATE] ${ignore_file}: '.dockerignore' must exclude both '.git' and '.env' (or '.env*') to prevent VCS and secret leakage into image layers." >&2
    ERRORS=$((ERRORS + 1))
  fi
}

validate_single_dockerfile() {
  local df_path="$1"
  local awk_out=""

  if ! awk_out=$(awk -v file="${df_path}" '
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    function unquote(s,    fc, lc) {
      s = trim(s)
      if (length(s) >= 2) {
        fc = substr(s, 1, 1)
        lc = substr(s, length(s), 1)
        if ((fc == "\"" && lc == "\"") || (fc == "\047" && lc == "\047")) {
          return substr(s, 2, length(s) - 2)
        }
      }
      return s
    }
    function process_instruction(line, lno,    kw, rest, n, toks, idx, img, img_low, alias, slash_pos, base_img, wd, src_arg, has_from, k, from_ref, from_low, has_cache, m_str, eq_pos) {
      line = trim(line)
      if (line == "") return
      if (!match(line, /^[A-Za-z]+[[:space:]]*/)) return
      kw = toupper(trim(substr(line, 1, RLENGTH)))
      rest = trim(substr(line, RLENGTH + 1))

      if (kw == "FROM") {
        stage_count++
        n = split(rest, toks, /[[:space:]]+/)
        idx = 1
        while (idx <= n && toks[idx] ~ /^--/) idx++
        img = (idx <= n ? toks[idx] : "")
        img_low = tolower(img)
        alias = ""
        if (idx + 2 <= n && tolower(toks[idx + 1]) == "as") {
          alias = tolower(toks[idx + 2])
        }

        if (img_low == "scratch") {
          curr_is_scratch = 1
        } else if (img_low in stage_map) {
          curr_is_scratch = 0
          stage_used[img_low] = 1
        } else {
          curr_is_scratch = 0
          if (img_low ~ /:latest$/) {
            printf "❌ [DOCKER GATE] %s:L%d: Unpinned \047:latest\047 image tag in FROM (\047%s\047) is forbidden. Pin an explicit version or @sha256 digest.\n", file, lno, img > "/dev/stderr"
            errs++
          } else {
            slash_pos = match(img, /[^\/]+$/)
            base_img = (slash_pos > 0 ? substr(img, slash_pos) : img)
            if (base_img !~ /:/ && img_low !~ /@sha256:[0-9a-f]{64}/ && img !~ /\$/) {
              printf "❌ [DOCKER GATE] %s:L%d: Untagged base image \047%s\047 in FROM is forbidden. Pin an explicit version tag or @sha256 digest.\n", file, lno, img > "/dev/stderr"
              errs++
            }
          }
        }

        if (alias != "") {
          if (alias in stage_map) {
            printf "❌ [DOCKER GATE] %s:L%d: Duplicate multi-stage alias \047%s\047 in FROM instruction.\n", file, lno, alias > "/dev/stderr"
            errs++
          } else {
            stage_map[alias] = stage_count
            stage_name[stage_count] = alias
          }
        }

        curr_user = ""
        curr_hc = 0
        curr_hc_none = 0
        return
      }

      if (kw == "USER") {
        n = split(rest, toks, /[[:space:]]+/)
        curr_user = (n >= 1 ? unquote(toks[1]) : "")
        return
      }

      if (kw == "HEALTHCHECK") {
        if (toupper(rest) ~ /^NONE([[:space:]]|$)/) {
          curr_hc_none = 1
          printf "❌ [DOCKER GATE] %s:L%d: \047HEALTHCHECK NONE\047 is forbidden. Define an active HEALTHCHECK in the runtime stage.\n", file, lno > "/dev/stderr"
          errs++
        } else if (rest ~ /(^|[[:space:]])CMD([[:space:]]|$)/) {
          curr_hc = 1
        }
        return
      }

      if (kw == "WORKDIR") {
        n = split(rest, toks, /[[:space:]]+/)
        wd = (n >= 1 ? unquote(toks[1]) : "")
        if (wd !~ /^(\/|\$|[A-Za-z]:)/) {
          printf "❌ [DOCKER GATE] %s:L%d: Relative WORKDIR \047%s\047 is forbidden. Use an absolute path starting with \047/\047.\n", file, lno, wd > "/dev/stderr"
          errs++
        }
        return
      }

      if (kw == "ADD") {
        n = split(rest, toks, /[[:space:]]+/)
        idx = 1
        while (idx <= n && toks[idx] ~ /^--/) idx++
        src_arg = (idx <= n ? unquote(toks[idx]) : "")
        if (tolower(src_arg) ~ /^https?:\/\//) {
          printf "❌ [DOCKER GATE] %s:L%d: Fetching remote URL \047%s\047 via ADD is forbidden. Use curl/wget in RUN or COPY.\n", file, lno, src_arg > "/dev/stderr"
          errs++
        } else if (tolower(src_arg) !~ /\.(tar|tar\.gz|tgz|tar\.bz2|tbz2|tar\.xz|txz|tar\.zst)$/) {
          printf "❌ [DOCKER GATE] %s:L%d: Use \047COPY\047 instead of \047ADD\047 for non-archive path \047%s\047.\n", file, lno, src_arg > "/dev/stderr"
          errs++
        }
        return
      }

      if (kw == "COPY") {
        n = split(rest, toks, /[[:space:]]+/)
        has_from = 0
        idx = 1
        while (idx <= n && toks[idx] ~ /^--/) {
          if (tolower(toks[idx]) ~ /^--from=/) {
            has_from = 1
            from_ref = unquote(substr(toks[idx], 8))
            from_low = tolower(from_ref)
            if (from_low in stage_map) {
              stage_used[from_low] = 1
            } else if (from_low ~ /^[0-9]+$/) {
              if (int(from_low) >= stage_count - 1) {
                printf "❌ [DOCKER GATE] %s:L%d: COPY \047%s\047 references invalid or future stage index.\n", file, lno, toks[idx] > "/dev/stderr"
                errs++
              }
            } else if (from_ref !~ /[:\/]/) {
              printf "❌ [DOCKER GATE] %s:L%d: COPY \047--from=%s\047 references undefined build stage \047%s\047.\n", file, lno, from_ref, from_ref > "/dev/stderr"
              errs++
            }
          }
          idx++
        }
        if (!has_from && idx < n) {
          for (k = idx; k < n; k++) {
            if (unquote(toks[k]) == "." || unquote(toks[k]) == "./") {
              uses_broad_copy = 1
            }
          }
        }
        return
      }

      if (kw == "RUN") {
        has_cache = (tolower(rest) ~ /--mount=[^[:space:]]*type=cache/ ? 1 : 0)
        n = split(rest, toks, /[[:space:]]+/)
        idx = 1
        while (idx <= n && toks[idx] ~ /^--/) {
          if (tolower(toks[idx]) ~ /^--mount=.*from=/) {
            m_str = tolower(toks[idx])
            sub(/^.*from=/, "", m_str)
            sub(/,.*$/, "", m_str)
            if (m_str in stage_map) {
              stage_used[m_str] = 1
            }
          }
          idx++
        }

        if (rest ~ /(^|[;&|({[:space:]])[s]udo([[:space:]]|$)/) {
          printf "❌ [DOCKER GATE] %s:L%d: \047sudo\047 is forbidden inside RUN instructions.\n", file, lno > "/dev/stderr"
          errs++
        }
        if (rest ~ /(^|[;&|({[:space:]])[e]val([[:space:]]|$)/) {
          printf "❌ [DOCKER GATE] %s:L%d: \047eval\047 is forbidden inside RUN instructions.\n", file, lno > "/dev/stderr"
          errs++
        }
        if (rest ~ /(^|[;&|({[:space:]])([c]url|[w]get)[[:space:]][^;|]*\|[[:space:]]*([^[:space:]|;]*\/)?(ba)?sh([[:space:]]|$)/) {
          printf "❌ [DOCKER GATE] %s:L%d: Remote pipe-to-shell is forbidden inside RUN.\n", file, lno > "/dev/stderr"
          errs++
        }
        if (rest ~ /(^|[;&|({[:space:]])apk[[:space:]]+([^;&|]*[[:space:]])?add([[:space:]]|$)/ && rest !~ /--no-cache/ && !has_cache) {
          printf "❌ [DOCKER GATE] %s:L%d: \047apk add\047 must use \047--no-cache\047 (or BuildKit cache mount) to prevent layer bloat.\n", file, lno > "/dev/stderr"
          errs++
        }
        if (rest ~ /(^|[;&|({[:space:]])apt-get[[:space:]]+([^;&|]*[[:space:]])?install([[:space:]]|$)/ && (rest !~ /--no-install-recommends/ || (rest !~ /\/var\/lib\/apt\/lists/ && !has_cache))) {
          printf "❌ [DOCKER GATE] %s:L%d: \047apt-get install\047 must pass \047--no-install-recommends\047 and clean \047/var/lib/apt/lists/*\047 (or use cache mount).\n", file, lno > "/dev/stderr"
          errs++
        }
        if (rest ~ /(^|[;&|({[:space:]])pip3?[[:space:]]+install([[:space:]]|$)/ && rest !~ /--no-cache-dir/ && !has_cache) {
          printf "❌ [DOCKER GATE] %s:L%d: \047pip install\047 must use \047--no-cache-dir\047 or \047--mount=type=cache\047.\n", file, lno > "/dev/stderr"
          errs++
        }
        return
      }

      if (kw == "CMD" || kw == "ENTRYPOINT") {
        if (rest !~ /^\[.*\]$/) {
          printf "❌ [DOCKER GATE] %s:L%d: %s must use JSON exec array syntax \047[\"executable\", ...]\047 for proper PID 1 signal handling.\n", file, lno, kw > "/dev/stderr"
          errs++
        }
        return
      }

      if (kw == "ENV" || kw == "ARG") {
        n = split(rest, toks, /[[:space:]]+/)
        for (k = 1; k <= n; k++) {
          eq_pos = index(toks[k], "=")
          if (eq_pos > 1) {
            kname = toupper(substr(toks[k], 1, eq_pos - 1))
            kval = unquote(substr(toks[k], eq_pos + 1))
            if (kname ~ /(^|_)(SECRET|PASSWORD|PASSWD|TOKEN|API_KEY|PRIVATE_KEY|ACCESS_KEY|CLIENT_SECRET)(_|$)/) {
              if (kval != "" && kval !~ /^\$/ && kval !~ /^\/run\/secrets\//) {
                printf "❌ [DOCKER GATE] %s:L%d: Hardcoded secret in %s (\047%s\047) is forbidden. Inject secrets at runtime via \047/run/secrets/\047 or \047--mount=type=secret\047.\n", file, lno, kw, kname > "/dev/stderr"
                errs++
              }
            }
          }
        }
        return
      }
    }
    BEGIN {
      errs = 0
      acc = ""
      instr_line = 1
      stage_count = 0
      curr_user = ""
      curr_hc = 0
      curr_hc_none = 0
      curr_is_scratch = 0
      uses_broad_copy = 0
    }
    {
      raw = $0
      sub(/\r$/, "", raw)
      if (tolower(raw) ~ /#[[:space:]]*(hadolint[[:space:]]+ignore|check[[:space:]]*=[[:space:]]*skip)[[:space:]]*=/) {
        printf "❌ [DOCKER GATE] %s:L%d: Linter bypass pragma (\047# hadolint ignore=\047 / \047# check=skip=\047) is forbidden.\n", file, NR > "/dev/stderr"
        errs++
      }
      if (raw ~ /^[[:space:]]*#/) next
      if (raw ~ /^[[:space:]]*$/ && acc == "") next
      if (acc == "") instr_line = NR
      if (raw ~ /\\[[:space:]]*$/) {
        sub(/\\[[:space:]]*$/, " ", raw)
        acc = acc raw
        next
      }
      process_instruction(acc raw, instr_line)
      acc = ""
    }
    END {
      if (acc != "") {
        process_instruction(acc, instr_line)
      }
      if (stage_count == 0) {
        printf "❌ [DOCKER GATE] %s: Missing \047FROM\047 instruction in Dockerfile.\n", file > "/dev/stderr"
        errs++
      } else if (!curr_is_scratch) {
        if (curr_user == "") {
          printf "❌ [DOCKER GATE] %s: Missing non-root \047USER\047 instruction in final runtime stage.\n", file > "/dev/stderr"
          errs++
        } else if (tolower(curr_user) ~ /^(root|0)(:(root|0))?$/) {
          printf "❌ [DOCKER GATE] %s: Final stage effective USER cannot be \047root\047 or UID \0470\047 (found \047USER %s\047).\n", file, curr_user > "/dev/stderr"
          errs++
        }
        if (curr_hc == 0 && curr_hc_none == 0) {
          printf "❌ [DOCKER GATE] %s: Missing mandatory \047HEALTHCHECK\047 instruction in final runtime stage.\n", file > "/dev/stderr"
          errs++
        }
      }
      for (s = 1; s < stage_count; s++) {
        if ((s in stage_name) && !(stage_name[s] in stage_used)) {
          printf "❌ [DOCKER GATE] %s: Unused multi-stage build stage \047%s\047 (never referenced by FROM or COPY --from).\n", file, stage_name[s] > "/dev/stderr"
          errs++
        }
      }
      if (uses_broad_copy) {
        print "BROAD_COPY"
      }
      exit (errs > 0 ? 1 : 0)
    }
  ' "${df_path}"); then
    ERRORS=$((ERRORS + 1))
  fi

  if [[ "${awk_out}" == *"BROAD_COPY"* ]]; then
    local df_dir
    df_dir="$(dirname "${df_path}")"
    if [[ -f "${df_dir}/.dockerignore" ]]; then
      check_dockerignore_file "${df_dir}/.dockerignore"
    elif [[ -f "${ROOT_DIR}/.dockerignore" ]]; then
      check_dockerignore_file "${ROOT_DIR}/.dockerignore"
    else
      echo "❌ [DOCKER GATE] ${df_path}: 'COPY .' used without a '.dockerignore' file (risk of leaking .git and .env into image layers)." >&2
      ERRORS=$((ERRORS + 1))
    fi
  fi
}

validate_single_compose() {
  local cf_path="$1"
  local cf_dir
  cf_dir="$(dirname "${cf_path}")"
  local compose_out=""

  if ! compose_out=$(awk -v file="${cf_path}" '
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    function unquote(s,    fc, lc) {
      s = trim(s)
      if (length(s) >= 2) {
        fc = substr(s, 1, 1)
        lc = substr(s, length(s), 1)
        if ((fc == "\"" && lc == "\"") || (fc == "\047" && lc == "\047")) {
          return substr(s, 2, length(s) - 2)
        }
      }
      return s
    }
    function strip_inline_comment(s,    i, len, c, in_sq, in_dq, out, prev) {
      in_sq = 0; in_dq = 0; out = ""; len = length(s)
      for (i = 1; i <= len; i++) {
        c = substr(s, i, 1)
        if (c == "\047" && !in_dq) in_sq = !in_sq
        else if (c == "\"" && !in_sq) in_dq = !in_dq
        else if (c == "#" && !in_sq && !in_dq) {
          prev = (i > 1 ? substr(s, i - 1, 1) : " ")
          if (prev ~ /[[:space:]]/) break
        }
        out = out c
      }
      return trim(out)
    }
    function parse_inline_list(raw_val, target_type, svc,    inner, n, items, idx, it) {
      inner = trim(raw_val)
      if (inner !~ /^\[.*\]$/) return 0
      inner = substr(inner, 2, length(inner) - 2)
      n = split(inner, items, /,/)
      for (idx = 1; idx <= n; idx++) {
        it = unquote(items[idx])
        if (it == "") continue
        if (target_type == "secrets") svc_secs[svc, it] = 1
        else if (target_type == "networks") svc_nets[svc, it] = 1
        else if (target_type == "depends_on") {
          svc_deps[svc, it] = 1
          reach[svc, it] = 1
        }
      }
      return 1
    }
    function check_env_kv(svc, ekey, eval_str, lno,    ukey, uval) {
      ukey = toupper(trim(ekey))
      uval = unquote(eval_str)
      if (ukey ~ /(^|_)(SECRET|PASSWORD|PASSWD|TOKEN|API_KEY|PRIVATE_KEY|ACCESS_KEY|CLIENT_SECRET)(_|$)/) {
        if (uval != "" && uval !~ /^\$/ && uval !~ /^\/run\/secrets\//) {
          printf "❌ [COMPOSE GATE] %s:L%d (service \047%s\047): Plaintext secret in environment variable \047%s\047 is forbidden. Use Compose \047secrets:\047 (/run/secrets/) or \047${VAR:?err}\047 interpolation.\n", file, lno, svc, trim(ekey) > "/dev/stderr"
          errs++
        }
      }
    }
    BEGIN {
      errs = 0
      top_sec = ""
      sec_child_indent = -1
      svc_indent = -1
      prop_indent = -1
      sub_child_indent = -1
      curr_svc = ""
      sub_sec = ""
      svc_count = 0
    }
    {
      raw = $0
      sub(/\r$/, "", raw)
      if (raw ~ /^[[:space:]]*#/ || raw ~ /^[[:space:]]*$/) next

      match(raw, /^[[:space:]]*/)
      indent = RLENGTH
      trimmed = strip_inline_comment(substr(raw, indent + 1))
      if (trimmed == "") next

      if (indent == 0) {
        curr_svc = ""
        sub_sec = ""
        sec_child_indent = -1
        if (match(trimmed, /^[A-Za-z0-9._-]+:/)) {
          key = substr(trimmed, 1, RLENGTH - 1)
          if (key == "version") {
            printf "❌ [COMPOSE GATE] %s:L%d: Obsolete top-level \047version:\047 property is forbidden by the Compose Specification.\n", file, NR > "/dev/stderr"
            errs++
          }
          top_sec = key
        }
        next
      }

      if (top_sec == "secrets" || top_sec == "volumes" || top_sec == "networks") {
        if (sec_child_indent == -1) sec_child_indent = indent
        if (indent == sec_child_indent && match(trimmed, /^[A-Za-z0-9._-]+:/)) {
          iname = substr(trimmed, 1, RLENGTH - 1)
          if (top_sec == "secrets") {
            decl_secrets[iname] = 1
            sec_order[++decl_sec_count] = iname
          } else if (top_sec == "volumes") {
            decl_volumes[iname] = 1
          } else if (top_sec == "networks") {
            decl_networks[iname] = 1
          }
        }
        next
      }

      if (top_sec != "services") next

      if (svc_indent == -1) svc_indent = indent

      if (indent == svc_indent && match(trimmed, /^[A-Za-z0-9._-]+:/)) {
        curr_svc = substr(trimmed, 1, RLENGTH - 1)
        if (!(curr_svc in svc_seen)) {
          svc_seen[curr_svc] = 1
          svc_order[++svc_count] = curr_svc
        }
        prop_indent = -1
        sub_sec = ""
        sub_child_indent = -1
        next
      }

      if (curr_svc == "") next

      if ((prop_indent == -1 || indent == prop_indent) && indent > svc_indent && match(trimmed, /^[A-Za-z0-9._-]+:/)) {
        if (prop_indent == -1) prop_indent = indent
        prop = substr(trimmed, 1, RLENGTH - 1)
        val = trim(substr(trimmed, RLENGTH + 1))
        sub_sec = prop
        sub_child_indent = -1

        if (prop == "image") {
          svc_has_image[curr_svc] = 1
          uval = unquote(val)
          if (tolower(uval) ~ /:latest$/) {
            printf "❌ [COMPOSE GATE] %s:L%d (service \047%s\047): Unpinned \047:latest\047 image tag (\047%s\047) is forbidden.\n", file, NR, curr_svc, uval > "/dev/stderr"
            errs++
          } else {
            slash_p = match(uval, /[^\/]+$/)
            b_img = (slash_p > 0 ? substr(uval, slash_p) : uval)
            if (b_img !~ /:/ && tolower(uval) !~ /@sha256:[0-9a-f]{64}/ && uval !~ /\$/) {
              printf "❌ [COMPOSE GATE] %s:L%d (service \047%s\047): Untagged image \047%s\047 is forbidden. Pin an explicit tag or @sha256 digest.\n", file, NR, curr_svc, uval > "/dev/stderr"
              errs++
            }
          }
        } else if (prop == "build") {
          svc_has_build[curr_svc] = 1
          uval = unquote(val)
          if (uval != "") svc_build_ctx[curr_svc] = uval
        } else if (prop == "privileged") {
          uval = tolower(unquote(val))
          if (uval == "true" || uval == "yes" || uval == "1") {
            printf "❌ [COMPOSE GATE] %s:L%d (service \047%s\047): \047privileged: true\047 is strictly forbidden.\n", file, NR, curr_svc > "/dev/stderr"
            errs++
          }
        } else if (prop == "network_mode" || prop == "pid" || prop == "ipc" || prop == "uts") {
          uval = tolower(unquote(val))
          if (uval == "host") {
            printf "❌ [COMPOSE GATE] %s:L%d (service \047%s\047): Host namespace sharing (\047%s: host\047) is forbidden.\n", file, NR, curr_svc, prop > "/dev/stderr"
            errs++
          }
        } else if (prop == "user") {
          uval = tolower(unquote(val))
          if (uval ~ /^(root|0)(:(root|0))?$/) {
            printf "❌ [COMPOSE GATE] %s:L%d (service \047%s\047): Running service as root (\047user: %s\047) is forbidden.\n", file, NR, curr_svc, unquote(val) > "/dev/stderr"
            errs++
          }
        } else if (prop == "restart") {
          if (unquote(val) != "") svc_has_restart[curr_svc] = 1
        } else if (prop == "security_opt") {
          if (tolower(val) ~ /no-new-privileges[[:space:]]*:[[:space:]]*true/) svc_has_nnp[curr_svc] = 1
        } else if (prop == "healthcheck") {
          svc_has_hc[curr_svc] = 1
          if (val ~ /test[[:space:]]*:/) svc_has_hc_test[curr_svc] = 1
          if (tolower(val) ~ /disable[[:space:]]*:[[:space:]]*true/) svc_hc_disabled[curr_svc] = 1
        } else if (prop == "secrets" || prop == "networks" || prop == "depends_on") {
          parse_inline_list(val, prop, curr_svc)
        }
        next
      }

      if (prop_indent != -1 && indent > prop_indent) {
        if (sub_child_indent == -1) sub_child_indent = indent

        if (sub_sec == "security_opt") {
          if (tolower(trimmed) ~ /no-new-privileges[[:space:]]*:[[:space:]]*true/) svc_has_nnp[curr_svc] = 1
        } else if (sub_sec == "healthcheck") {
          if (trimmed ~ /^test[[:space:]]*:/) svc_has_hc_test[curr_svc] = 1
          if (tolower(trimmed) ~ /^disable[[:space:]]*:[[:space:]]*(true|"true"|\047true\047)/) svc_hc_disabled[curr_svc] = 1
        } else if (sub_sec == "build") {
          if (trimmed ~ /^context[[:space:]]*:/) {
            v = trimmed; sub(/^context[[:space:]]*:[[:space:]]*/, "", v)
            svc_build_ctx[curr_svc] = unquote(v)
          } else if (trimmed ~ /^dockerfile[[:space:]]*:/) {
            v = trimmed; sub(/^dockerfile[[:space:]]*:[[:space:]]*/, "", v)
            svc_build_df[curr_svc] = unquote(v)
          } else if (trimmed ~ /^target[[:space:]]*:/) {
            v = trimmed; sub(/^target[[:space:]]*:[[:space:]]*/, "", v)
            svc_build_target[curr_svc] = unquote(v)
          }
        } else if (sub_sec == "environment") {
          if (trimmed ~ /^-[[:space:]]+/) {
            v = trimmed; sub(/^-[[:space:]]+/, "", v); v = unquote(v)
            eq_p = index(v, "=")
            if (eq_p > 1) {
              check_env_kv(curr_svc, substr(v, 1, eq_p - 1), substr(v, eq_p + 1), NR)
            }
          } else if (match(trimmed, /^[A-Za-z0-9._-]+[[:space:]]*:/)) {
            ek = substr(trimmed, 1, RLENGTH - 1)
            ev = substr(trimmed, RLENGTH + 1)
            check_env_kv(curr_svc, ek, ev, NR)
          }
        } else if (sub_sec == "volumes") {
          if (trimmed ~ /\/var\/run\/docker\.sock/) {
            printf "❌ [COMPOSE GATE] %s:L%d (service \047%s\047): Mounting \047/var/run/docker.sock\047 is forbidden (container escape vector).\n", file, NR, curr_svc > "/dev/stderr"
            errs++
          }
          if (trimmed ~ /^-[[:space:]]+/) {
            v = trimmed; sub(/^-[[:space:]]+/, "", v); v = unquote(v)
            if (v !~ /^[A-Za-z0-9_]+:([[:space:]]|$)/ && index(v, ":") > 1) {
              vsrc = substr(v, 1, index(v, ":") - 1)
              if (vsrc != "" && vsrc !~ /^(\.|\/|~|\$|[A-Za-z]$)/) {
                svc_vols[curr_svc, vsrc] = 1
              }
            }
          }
        } else if (sub_sec == "secrets") {
          if (trimmed ~ /^-[[:space:]]+/) {
            v = trimmed; sub(/^-[[:space:]]+/, "", v)
            if (v !~ /:/) svc_secs[curr_svc, unquote(v)] = 1
          } else if (trimmed ~ /^source[[:space:]]*:/) {
            v = trimmed; sub(/^source[[:space:]]*:[[:space:]]*/, "", v)
            svc_secs[curr_svc, unquote(v)] = 1
          }
        } else if (sub_sec == "networks") {
          if (indent == sub_child_indent) {
            if (trimmed ~ /^-[[:space:]]+/) {
              v = trimmed; sub(/^-[[:space:]]+/, "", v)
              svc_nets[curr_svc, unquote(v)] = 1
            } else if (match(trimmed, /^[A-Za-z0-9._-]+:/)) {
              svc_nets[curr_svc, substr(trimmed, 1, RLENGTH - 1)] = 1
            }
          }
        } else if (sub_sec == "depends_on") {
          if (indent == sub_child_indent) {
            if (trimmed ~ /^-[[:space:]]+/) {
              v = trimmed; sub(/^-[[:space:]]+/, "", v)
              d = unquote(v)
              svc_deps[curr_svc, d] = 1
              reach[curr_svc, d] = 1
            } else if (match(trimmed, /^[A-Za-z0-9._-]+:/)) {
              d = substr(trimmed, 1, RLENGTH - 1)
              svc_deps[curr_svc, d] = 1
              reach[curr_svc, d] = 1
            }
          }
        } else if (sub_sec == "deploy") {
          if (trimmed ~ /^restart_policy[[:space:]]*:/) svc_has_restart[curr_svc] = 1
        }
      }
    }
    END {
      if (svc_count == 0) {
        printf "❌ [COMPOSE GATE] %s: Missing or empty \047services:\047 block in Compose file.\n", file > "/dev/stderr"
        errs++
      }
      for (i = 1; i <= svc_count; i++) {
        s = svc_order[i]
        if (!(s in svc_has_image) && !(s in svc_has_build)) {
          printf "❌ [COMPOSE GATE] %s (service \047%s\047): Service must define either \047image:\047 or \047build:\047.\n", file, s > "/dev/stderr"
          errs++
        }
        if (!(s in svc_has_nnp)) {
          printf "❌ [COMPOSE GATE] %s (service \047%s\047): Missing mandatory \047security_opt: [no-new-privileges:true]\047.\n", file, s > "/dev/stderr"
          errs++
        }
        if (s in svc_hc_disabled) {
          printf "❌ [COMPOSE GATE] %s (service \047%s\047): Disabling healthcheck (\047disable: true\047) is forbidden.\n", file, s > "/dev/stderr"
          errs++
        } else if (!(s in svc_has_hc) || !(s in svc_has_hc_test)) {
          printf "❌ [COMPOSE GATE] %s (service \047%s\047): Missing mandatory \047healthcheck:\047 definition with \047test:\047.\n", file, s > "/dev/stderr"
          errs++
        }
        if (!(s in svc_has_restart)) {
          printf "❌ [COMPOSE GATE] %s (service \047%s\047): Missing explicit \047restart:\047 policy (e.g. \047unless-stopped\047 or \047on-failure\047).\n", file, s > "/dev/stderr"
          errs++
        }
        if (s in svc_has_build) {
          b_ctx = (s in svc_build_ctx ? svc_build_ctx[s] : ".")
          b_df = (s in svc_build_df ? svc_build_df[s] : "Dockerfile")
          b_tgt = (s in svc_build_target ? svc_build_target[s] : "")
          printf "BUILD_SPEC\t%s\t%s\t%s\t%s\n", s, b_ctx, b_df, b_tgt
        }
      }

      for (comb in svc_secs) {
        split(comb, parts, SUBSEP)
        s = parts[1]; sec = parts[2]
        used_secrets[sec] = 1
        if (!(sec in decl_secrets)) {
          printf "❌ [COMPOSE GATE] %s (service \047%s\047): References undeclared secret \047%s\047 (missing from top-level \047secrets:\047).\n", file, s, sec > "/dev/stderr"
          errs++
        }
      }
      for (i = 1; i <= decl_sec_count; i++) {
        sec = sec_order[i]
        if (!(sec in used_secrets)) {
          printf "❌ [COMPOSE GATE] %s: Top-level secret \047%s\047 is unused by any service.\n", file, sec > "/dev/stderr"
          errs++
        }
      }

      for (comb in svc_vols) {
        split(comb, parts, SUBSEP)
        s = parts[1]; vol = parts[2]
        if (!(vol in decl_volumes)) {
          printf "❌ [COMPOSE GATE] %s (service \047%s\047): Mounts undeclared named volume \047%s\047 (missing from top-level \047volumes:\047).\n", file, s, vol > "/dev/stderr"
          errs++
        }
      }

      for (comb in svc_nets) {
        split(comb, parts, SUBSEP)
        s = parts[1]; net = parts[2]
        if (net != "default" && !(net in decl_networks)) {
          printf "❌ [COMPOSE GATE] %s (service \047%s\047): References undeclared network \047%s\047 (missing from top-level \047networks:\047).\n", file, s, net > "/dev/stderr"
          errs++
        }
      }

      for (comb in svc_deps) {
        split(comb, parts, SUBSEP)
        s = parts[1]; dep = parts[2]
        if (dep == s) {
          printf "❌ [COMPOSE GATE] %s (service \047%s\047): Self-dependency cycle in \047depends_on\047.\n", file, s > "/dev/stderr"
          errs++
        } else if (!(dep in svc_seen)) {
          printf "❌ [COMPOSE GATE] %s (service \047%s\047): \047depends_on\047 references undefined service \047%s\047.\n", file, s, dep > "/dev/stderr"
          errs++
        }
      }

      for (k = 1; k <= svc_count; k++) {
        sk = svc_order[k]
        for (i = 1; i <= svc_count; i++) {
          si = svc_order[i]
          if ((si, sk) in reach) {
            for (j = 1; j <= svc_count; j++) {
              sj = svc_order[j]
              if ((sk, sj) in reach) reach[si, sj] = 1
            }
          }
        }
      }
      for (i = 1; i <= svc_count; i++) {
        si = svc_order[i]
        if ((si, si) in reach && !((si, si) in svc_deps)) {
          printf "❌ [COMPOSE GATE] %s (service \047%s\047): Circular dependency cycle detected in \047depends_on\047 graph.\n", file, si > "/dev/stderr"
          errs++
          break
        }
      }

      exit (errs > 0 ? 1 : 0)
    }
  ' "${cf_path}"); then
    ERRORS=$((ERRORS + 1))
  fi

  if [[ -n "${compose_out}" ]]; then
    local spec_line svc_name b_ctx b_df b_tgt resolved_ctx resolved_df
    while IFS=$'\t' read -r spec_tag svc_name b_ctx b_df b_tgt; do
      [[ "${spec_tag:-}" != "BUILD_SPEC" ]] && continue
      [[ "${b_ctx}" == *"$"* || "${b_ctx}" == *"://"* ]] && continue
      resolved_ctx="${cf_dir}/${b_ctx}"
      if [[ "${b_df}" == /* ]]; then
        resolved_df="${b_df}"
      else
        resolved_df="${resolved_ctx}/${b_df}"
      fi
      if [[ ! -d "${resolved_ctx}" ]]; then
        echo "❌ [COMPOSE TEST GATE] ${cf_path} (service '${svc_name}'): Build context directory '${b_ctx}' does not exist." >&2
        ERRORS=$((ERRORS + 1))
      elif [[ ! -f "${resolved_df}" ]]; then
        echo "❌ [COMPOSE TEST GATE] ${cf_path} (service '${svc_name}'): Referenced Dockerfile '${b_df}' does not exist in context '${b_ctx}'." >&2
        ERRORS=$((ERRORS + 1))
      elif [[ -n "${b_tgt}" ]]; then
        if ! grep -vE '^[[:space:]]*#' "${resolved_df}" | grep -iE "^[[:space:]]*FROM[[:space:]]+.*[[:space:]]+AS[[:space:]]+${b_tgt}([[:space:]]|$)" >/dev/null 2>&1; then
          echo "❌ [COMPOSE TEST GATE] ${cf_path} (service '${svc_name}'): Build target stage '${b_tgt}' does not exist in '${resolved_df}'." >&2
          ERRORS=$((ERRORS + 1))
        fi
      fi
    done <<< "${compose_out}"
  fi
}

validate_container_structure_test() {
  local cst_file="$1"
  if ! grep -E -q 'schemaVersion[[:space:]]*:[[:space:]]*["'\'']?2\.0\.0["'\'']?' "${cst_file}"; then
    echo "❌ [DOCKER TEST GATE] ${cst_file}: Missing required 'schemaVersion: \"2.0.0\"' in container-structure-test specification." >&2
    ERRORS=$((ERRORS + 1))
  fi
  if ! grep -E -q '(commandTests|fileExistenceTests|fileContentTests|metadataTest|licenseTests)[[:space:]]*:' "${cst_file}"; then
    echo "❌ [DOCKER TEST GATE] ${cst_file}: container-structure-test file must define at least one test suite (commandTests, fileExistenceTests, fileContentTests, metadataTest, or licenseTests)." >&2
    ERRORS=$((ERRORS + 1))
  fi
}

# 1. Validate standalone .dockerignore files
while IFS= read -r -d '' di_file; do
  check_dockerignore_file "${di_file}"
done < <(find "${ROOT_DIR}" \
  -type d \( -name ".git" -o -name "node_modules" -o -name ".venv" -o -name "venv" -o -name ".guardrails" -o -name "modules" -o -name ".cache" \) -prune \
  -o -type f -name ".dockerignore" -print0)

# 2. Validate all Dockerfiles / Containerfiles
while IFS= read -r -d '' dockerfile; do
  DOCKERFILE_COUNT=$((DOCKERFILE_COUNT + 1))
  validate_single_dockerfile "${dockerfile}"
done < <(find "${ROOT_DIR}" \
  -type d \( -name ".git" -o -name "node_modules" -o -name ".venv" -o -name "venv" -o -name ".guardrails" -o -name "modules" -o -name ".cache" \) -prune \
  -o -type f \( -name "Dockerfile" -o -name "Dockerfile.*" -o -name "*.Dockerfile" -o -name "Containerfile" -o -name "Containerfile.*" \) -print0)

# 3. Validate all Docker Compose files
while IFS= read -r -d '' compose_file; do
  COMPOSE_COUNT=$((COMPOSE_COUNT + 1))
  validate_single_compose "${compose_file}"
done < <(find "${ROOT_DIR}" \
  -type d \( -name ".git" -o -name "node_modules" -o -name ".venv" -o -name "venv" -o -name ".guardrails" -o -name "modules" -o -name ".cache" \) -prune \
  -o -type f \( -name "compose.yaml" -o -name "compose.yml" -o -name "compose.*.yaml" -o -name "compose.*.yml" -o -name "docker-compose.yml" -o -name "docker-compose.yaml" -o -name "docker-compose.*.yml" -o -name "docker-compose.*.yaml" \) -print0)

# 4. Validate container-structure-test specifications (when present)
while IFS= read -r -d '' cst_file; do
  validate_container_structure_test "${cst_file}"
done < <(find "${ROOT_DIR}" \
  -type d \( -name ".git" -o -name "node_modules" -o -name ".venv" -o -name "venv" -o -name ".guardrails" -o -name "modules" -o -name ".cache" \) -prune \
  -o -type f \( -name "container-structure-test*.yaml" -o -name "container-structure-test*.yml" -o -name "container-structure-test*.json" \) -print0)

# 5. In --test mode with GUARDRAILS_FIXTURE_MODE=0, require at least one container specification
if [[ "${MODE}" == "test" && "${GUARDRAILS_FIXTURE_MODE:-0}" != "1" ]]; then
  if [[ "${DOCKERFILE_COUNT}" -eq 0 && "${COMPOSE_COUNT}" -eq 0 ]]; then
    echo "❌ [DOCKER TEST ERROR] No Dockerfile or Compose specification found in project (fail-closed)." >&2
    ERRORS=$((ERRORS + 1))
  fi
fi

if [[ "${ERRORS}" -gt 0 ]]; then
  echo "🚫 [DOCKER GATE] Failed with ${ERRORS} container/compose validation or test violation(s)." >&2
  exit 1
fi

echo "✅ [DOCKER GATE] Dockerfile, .dockerignore & Compose validation, security & topology checks passed."
