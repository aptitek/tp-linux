#!/usr/bin/env bash
# =============================================================================
# ensure-docker.sh — Cross-platform Docker Desktop / Daemon readiness helper
# Automatically starts and unpauses Docker Desktop on Windows, macOS, and Linux.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${OS:-}" == "Windows_NT" ]] || uname -s 2>/dev/null | grep -qiE "mingw|msys|cygwin"; then
  if command -v powershell.exe >/dev/null 2>&1; then
    win_script="$(cygpath -w "${SCRIPT_DIR}/ensure-docker.ps1" 2>/dev/null || echo "${SCRIPT_DIR}/ensure-docker.ps1")"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${win_script}"
    exit $?
  fi
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if [[ "$(docker inspect -f '{{.State.Paused}}' tp-linux 2>/dev/null || true)" == "true" ]]; then
    docker unpause tp-linux >/dev/null 2>&1 || true
  fi
  exit 0
fi

echo "[Docker] Docker daemon is not running or is paused. Attempting to start..."

uname_out="$(uname -s 2>/dev/null || echo Unknown)"
case "${uname_out}" in
  Darwin*)
    docker desktop start >/dev/null 2>&1 || open -a Docker >/dev/null 2>&1 || true
    ;;
  Linux*)
    if grep -qi microsoft /proc/version 2>/dev/null && command -v powershell.exe >/dev/null 2>&1; then
      powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process 'C:\Program Files\Docker\Docker\Docker Desktop.exe' -ErrorAction SilentlyContinue" || true
    else
      docker desktop start >/dev/null 2>&1 \
        || systemctl --user start docker-desktop >/dev/null 2>&1 \
        || systemctl start docker >/dev/null 2>&1 \
        || true
    fi
    ;;
esac

elapsed=0
timeout_sec=120
while [[ "${elapsed}" -lt "${timeout_sec}" ]]; do
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if [[ "$(docker inspect -f '{{.State.Paused}}' tp-linux 2>/dev/null || true)" == "true" ]]; then
      docker unpause tp-linux >/dev/null 2>&1 || true
    fi
    echo "[Docker] Docker daemon is ready."
    exit 0
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done

echo "[Docker] ERROR: Docker daemon did not become ready within ${timeout_sec}s." >&2
exit 1

