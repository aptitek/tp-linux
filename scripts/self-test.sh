#!/usr/bin/env bash
# =============================================================================
# scripts/self-test.sh — Comprehensive End-to-End Verification Suite
# Executed via `task self-test`
# Tests:
#   1. Zero-Config-Drift & Docker/Compose AST/Security/Hadolint/Trivy gates
#   2. Removal of legacy host `docker exec` kernel/terminal hacks
#   3. Dev Container (.devcontainer/devcontainer.json) & VS Code configuration
#      (Ctrl+J -> /usr/bin/fish, /usr/bin/bash profile, extensions, tasks)
#   4. Jupyter Notebooks (tp.ipynb & workspace/tp-linux.ipynb) & Dockerfile
#      Bash + Fish + Python3 automatic kernel specs
#   5. Host toolchain & Windows 11 Chocolatey / WSL2 / Docker Desktop Auto-Start
#      & No-Auto-Pause / Auto-Update configuration
#   6. Live container & notebook execution (when Docker daemon is active)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  echo "  ✅ [PASS] $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "  ❌ [FAIL] $1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

echo "============================================================================="
echo " 1. Guardrails, Hadolint, Trivy & Docker/Compose Static Gates"
echo "============================================================================="
if bash ./.guardrails/scripts/verify-lock.sh "."; then
  pass "Zero-Config-Drift lockfile (.guardrails.lock) verified"
else
  fail "Zero-Config-Drift lockfile check failed"
fi

if bash ./.guardrails/scripts/validate-docker.sh --lint "." \
  && bash ./.guardrails/scripts/validate-docker.sh --sec "." \
  && bash ./.guardrails/scripts/validate-docker.sh --test "."; then
  pass "Dockerfile, .dockerignore, compose.yaml & container-structure-test.yaml gates passed"
else
  fail "validate-docker.sh failed"
fi

if command -v hadolint >/dev/null 2>&1; then
  if hadolint --config .hadolint.yaml Dockerfile; then
    pass "Hadolint strict Dockerfile check passed with 0 warnings"
  else
    fail "Hadolint reported warnings/errors on Dockerfile"
  fi
fi

if bash ./.guardrails/scripts/lint-secrets.sh "."; then
  pass "Secret scanner verified 0 hardcoded secrets"
else
  fail "Secret scanner failed"
fi

echo ""
echo "============================================================================="
echo " 2. Legacy Docker-Exec Removal & Dev Container / VS Code Config Verification"
echo "============================================================================="
if [[ ! -e ".vscode/docker-kernel.py" && ! -d ".vscode/kernels" ]]; then
  pass "Legacy host-to-docker exec kernel bridge (.vscode/docker-kernel.py & .vscode/kernels) removed"
else
  fail "Legacy .vscode/docker-kernel.py or .vscode/kernels still exists"
fi

if ! grep -Fq "docker exec" .vscode/settings.json; then
  pass "No 'docker exec' terminal profiles in .vscode/settings.json"
else
  fail "Found 'docker exec' in .vscode/settings.json"
fi

if ! grep -Fq "folderOpen" .vscode/tasks.json; then
  pass "No 'runOn: folderOpen' bash task in .vscode/tasks.json (fixes Windows /usr/bin/bash popup)"
else
  fail "Found 'folderOpen' in .vscode/tasks.json"
fi

if jq -e '.["terminal.integrated.defaultProfile.linux"] == "fish" and .["terminal.integrated.profiles.linux"].fish.path == "/usr/bin/fish" and .["terminal.integrated.profiles.linux"].bash.path == "/usr/bin/bash"' .vscode/settings.json >/dev/null; then
  pass ".vscode/settings.json configures Ctrl+J default Linux profile to /usr/bin/fish and bash to /usr/bin/bash"
else
  fail ".vscode/settings.json missing fish/bash terminal profile configuration"
fi

if jq -e '(.service == "tp-linux" or .build.dockerfile == "../Dockerfile") and .workspaceFolder == "/home/student/workspace" and .customizations.vscode.settings["terminal.integrated.defaultProfile.linux"] == "fish" and .customizations.vscode.settings["terminal.integrated.profiles.linux"].fish.path == "/usr/bin/fish" and (.initializeCommand | contains("ensure-docker"))' .devcontainer/devcontainer.json >/dev/null; then
  pass ".devcontainer/devcontainer.json configured with ensure-docker initializeCommand and Fish default terminal"
else
  fail ".devcontainer/devcontainer.json validation failed"
fi

ext_count="$(jq -r '.recommendations | length' .vscode/extensions.json)"
if [[ "${ext_count}" -ge 15 ]] && jq -e '.recommendations | index("ms-vscode-remote.remote-containers") and index("ms-toolsai.jupyter") and index("task.vscode-task") and index("bmalehorn.vscode-fish") and index("hverlin.mise-vscode")' .vscode/extensions.json >/dev/null; then
  pass ".vscode/extensions.json contains ${ext_count} recommended extensions (Dev Containers, Jupyter, Taskfile, Fish, Mise, Docker)"
else
  fail ".vscode/extensions.json missing required extension recommendations"
fi

if grep -Fq ".:/home/student/workspace" compose.yaml; then
  pass "compose.yaml mounts repository root (.:/home/student/workspace) so tp.ipynb is directly accessible in Dev Container"
else
  fail "compose.yaml does not mount .:/home/student/workspace"
fi

echo ""
echo "============================================================================="
echo " 3. Jupyter Notebooks (tp.ipynb & workspace/tp-linux.ipynb) & Kernel Specs"
echo "============================================================================="
for nb in "tp.ipynb" "workspace/tp-linux.ipynb"; do
  if jq -e '.metadata.kernelspec.name == "bash" and .metadata.kernelspec.language == "bash" and (.cells | length > 0)' "${nb}" >/dev/null; then
    pass "${nb} has valid Bash kernelspec and non-empty cells"
  else
    fail "${nb} kernelspec or cells invalid"
  fi
  if jq -e '[.cells[] | select(.cell_type == "code") | (.outputs | length == 0) and (.execution_count == null)] | all' "${nb}" >/dev/null; then
    pass "${nb} complies with clean-output gate (outputs: [] and execution_count: null)"
  else
    fail "${nb} has dirty cell outputs"
  fi
done

if grep -Fq "/home/student/.local/share/jupyter/kernels/bash/kernel.json" Dockerfile \
  && grep -Fq "/home/student/.local/share/jupyter/kernels/fish/kernel.json" Dockerfile \
  && grep -Fq "/home/student/.local/share/jupyter/kernels/python3/kernel.json" Dockerfile \
  && grep -Fq "fish_kernel.py" Dockerfile; then
  pass "Dockerfile automatically installs and registers Bash, Fish, and Python 3.13 Jupyter kernels"
else
  fail "Dockerfile missing Bash/Fish/Python3 kernel setup"
fi

echo ""
echo "============================================================================="
echo " 4. Host Provisioning & Windows 11 Automation Verification"
echo "============================================================================="
for script_file in "setup.ps1" "setup.cmd" "setup.sh" "scripts/ensure-docker.ps1" "scripts/ensure-docker.sh"; do
  if [[ -f "${script_file}" ]]; then
    pass "Provisioning script '${script_file}' exists"
  else
    fail "Missing provisioning script '${script_file}'"
  fi
done

for cmd_name in git bash mise task; do
  if command -v "${cmd_name}" >/dev/null 2>&1; then
    pass "Command '${cmd_name}' is available on PATH ($(command -v "${cmd_name}"))"
  else
    fail "Command '${cmd_name}' is missing from PATH"
  fi
done

if [[ -x "/usr/bin/bash" ]]; then
  pass "/usr/bin/bash is present and executable ($(/usr/bin/bash --version | head -n 1))"
else
  fail "/usr/bin/bash is missing or not executable"
fi

if [[ "${OS:-}" == "Windows_NT" ]] || uname -s 2>/dev/null | grep -qiE "mingw|msys|cygwin"; then
  if [[ -f "C:/usr/bin/bash.exe" && -f "C:/bin/bash.exe" ]]; then
    pass "Windows C:\\usr\\bin\\bash.exe and C:\\bin\\bash.exe junctions are active"
  else
    fail "Windows C:\\usr\\bin\\bash.exe or C:\\bin\\bash.exe missing"
  fi

  if [[ -f "C:/Program Files/Docker/Docker/Docker Desktop.exe" ]]; then
    pass "Docker Desktop is installed at C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe"
  else
    fail "Docker Desktop executable not found"
  fi

  if [[ -f "C:/ProgramData/tp-linux/auto-update.ps1" ]]; then
    pass "Automatic update script C:\\ProgramData\\tp-linux\\auto-update.ps1 is installed"
  else
    fail "Missing C:\\ProgramData\\tp-linux\\auto-update.ps1"
  fi

  docker_store="${APPDATA:-}/Docker/settings-store.json"
  if [[ -f "${docker_store}" ]] && jq -e '.AutoStart == true and .UseResourceSaver == false and .AutoPauseTimedActivity == false and .WslEngineEnabled == true' "${docker_store}" >/dev/null; then
    pass "Docker Desktop settings-store.json configured (AutoStart=true, UseResourceSaver=false, AutoPauseTimedActivity=false, WslEngineEnabled=true)"
  else
    fail "Docker Desktop settings-store.json not properly configured"
  fi
fi

echo ""
echo "============================================================================="
echo " 5. Live Docker Container & Notebook Execution Check"
echo "============================================================================="
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  echo "  [Info] Docker daemon is running — building and testing live container & notebooks..."
  task local:up
  task local:notebook:test
  pass "Live container build, Fish login shell, and tp.ipynb execution (Bash & Fish kernels) succeeded"
else
  echo "  ℹ️  [SKIP LIVE CONTAINER] Docker daemon is not yet running (pending one-time Windows reboot to activate VirtualMachinePlatform hypervisor)."
  echo "      Run 'task self-test' or 'task local:notebook:test' after rebooting Windows to execute live container tests."
fi

echo ""
echo "============================================================================="
echo " SELF-TEST SUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "============================================================================="
if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  exit 1
fi
