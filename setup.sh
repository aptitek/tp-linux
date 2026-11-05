#!/usr/bin/env bash
# =============================================================================
# setup.sh — Universal Cross-Platform Setup & Auto-Update Script
# Delegates to setup.ps1 on Windows; uses Homebrew / native package managers on
# macOS & Linux to install and keep Docker, Git, Mise, VS Code, and Taskfile updated.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${OS:-}" == "Windows_NT" ]] || uname -s 2>/dev/null | grep -qiE "mingw|msys|cygwin"; then
  if command -v powershell.exe >/dev/null 2>&1; then
    win_script="$(cygpath -w "${REPO_ROOT}/setup.ps1" 2>/dev/null || echo "${REPO_ROOT}/setup.ps1")"
    exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${win_script}" "$@"
  fi
fi

uname_s="$(uname -s 2>/dev/null || echo Linux)"

if [[ "${uname_s}" == "Darwin" ]]; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "[Setup] Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  echo "[Setup] Installing and upgrading git, mise, go-task, docker, and visual-studio-code via Homebrew..."
  brew update
  brew install git mise go-task || true
  brew upgrade git mise go-task || true
  brew install --cask docker visual-studio-code || true
  brew upgrade --cask docker visual-studio-code || true
elif [[ "${uname_s}" == "Linux" ]]; then
  if grep -qi microsoft /proc/version 2>/dev/null && command -v powershell.exe >/dev/null 2>&1; then
    win_script="$(wslpath -w "${REPO_ROOT}/setup.ps1" 2>/dev/null || echo "${REPO_ROOT}/setup.ps1")"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${win_script}" "$@"
  else
    if ! command -v mise >/dev/null 2>&1; then
      tmp_mise="$(mktemp -d)"
      curl -fsSL https://mise.run -o "${tmp_mise}/install.sh"
      sh "${tmp_mise}/install.sh"
      rm -rf "${tmp_mise}"
      export PATH="${HOME}/.local/bin:${HOME}/.local/share/mise/shims:${PATH}"
    fi
  fi
fi

if command -v mise >/dev/null 2>&1; then
  (cd "${REPO_ROOT}" && mise trust -a && mise install && mise upgrade)
fi

if command -v code >/dev/null 2>&1 && [[ -f "${REPO_ROOT}/.vscode/extensions.json" ]] && command -v jq >/dev/null 2>&1; then
  while IFS= read -r ext; do
    [[ -z "${ext}" ]] && continue
    code --install-extension "${ext}" --force || true
  done < <(jq -r '.recommendations[]' "${REPO_ROOT}/.vscode/extensions.json")
fi

bash "${REPO_ROOT}/scripts/ensure-docker.sh" || true
if command -v task >/dev/null 2>&1 && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  (cd "${REPO_ROOT}" && task up)
fi

