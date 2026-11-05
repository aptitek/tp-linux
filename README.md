# TP Linux — Ubuntu 26.04 (Dev Container + Jupyter Bash/Fish + Fish Shell)

Environnement de travaux pratiques Linux sous **Ubuntu 26.04** basé sur **VS Code Dev Containers**, **Jupyter (`tp.ipynb` avec kernel Bash & Fish)** et le shell interactif **Fish** (`Ctrl+J`).

---

## 1. Installation Automatisée (Windows 11, macOS, Linux)

### Sur Windows 11 (Recommandé — Chocolatey + WSL 2 + Auto-Update)
Double-cliquez sur **`setup.cmd`** ou exécutez dans PowerShell :

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
```

Ce script automatise intégralement :
1. **WSL 2 & Virtual Machine Platform** : active les fonctionnalités Windows requises par Docker Desktop et installe/met à jour le noyau WSL 2 (`wsl --install --no-distribution`, `wsl --update`, `wsl --set-default-version 2`).
2. **Chocolatey (`choco`)** : installe et met à jour :
   - `docker-desktop` (Docker Desktop)
   - `git` (Git for Windows avec `/usr/bin/bash` et `/bin/bash` configurés dans le `PATH` et via les jonctions `C:\usr\bin` et `C:\bin`)
   - `mise` (gestionnaire de toolchain polyglotte)
   - `vscode` (Visual Studio Code)
   - `go-task` (Taskfile CLI `task`)
3. **Mises à jour automatiques (`TP-Linux-AutoUpdate`)** : enregistre une tâche planifiée Windows exécutée au démarrage et quotidiennement pour maintenir `docker-desktop`, `git`, `mise`, `vscode`, `go-task`, `chocolatey` et `wsl` automatiquement à jour.
4. **Docker Desktop sans pause ni arrêt intempestif** :
   - Active le démarrage automatique (`AutoStart: true`) à l'ouverture de session Windows.
   - Désactive le mode économie / pause automatique (`UseResourceSaver: false`, `AutoPauseTimedActivity: false`).
   - Démarre et dépause automatiquement Docker Desktop via `scripts/ensure-docker.ps1`.
5. **Extensions VS Code** : installe automatiquement toutes les extensions recommandées de `.vscode/extensions.json`.

> **Note** : Si WSL 2 vient d'être activé pour la toute première fois sur votre PC Windows 11, redémarrez Windows une fois puis relancez `.\setup.cmd`.

### Sur Linux / macOS
```bash
bash ./setup.sh
```

---

## 2. Utilisation avec VS Code (Dev Containers)

1. Ouvrez ce dossier dans **VS Code**.
2. Cliquez sur **"Reopen in Container"** (ou `Ctrl+Shift+P` -> `Dev Containers: Reopen in Container`).
   - Grâce à `initializeCommand` dans `.devcontainer/devcontainer.json`, VS Code démarre et dépause automatiquement Docker Desktop s'il était arrêté ou en pause.
3. Une fois dans le conteneur :
   - Ouvrez **`tp.ipynb`** : le kernel **`Bash (TP Linux)`** (ainsi que **`Fish (TP Linux)`** et **`Python 3.13 (TP Linux)`**) est automatiquement préconfiguré.
   - Appuyez sur **`Ctrl+J`** : ouvre directement le terminal intégré sur **`/usr/bin/fish`** à l'intérieur du conteneur Ubuntu 26.04.

---

## 3. Commandes `task` (Taskfile)

| Action | Commande |
| :--- | :--- |
| Provisionner / mettre à jour le poste hôte | `task provision` |
| S'assurer que Docker Desktop est démarré et non en pause | `task docker:ready` |
| Construire et démarrer le conteneur `tp-linux` | `task up` |
| Ouvrir un shell Fish interactif dans le conteneur | `task shell` |
| Tester l'exécution de `tp.ipynb` (Bash & Fish) et du conteneur | `task notebook:test` |
| Lancer la suite complète de vérification (`guardrails` + `docker`) | `task verify` |

