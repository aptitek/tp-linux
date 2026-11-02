---
name: docker-expert
description: "Author, validate, and test hardened multi-stage Dockerfiles, .dockerignore, Compose files, and container-structure-test specs."
---

# Docker & Compose Hardening & Testing (`docker-expert` / `addon:docker`)

## 1. Hard Dockerfile & `.dockerignore` Gates (`validate-docker.sh` + `.hadolint.yaml`)
| Gate | Requirement |
| :--- | :--- |
| **Locked Config** | `.hadolint.yaml` (`failure-threshold: warning`, `disable-ignore-pragma: true`; `# hadolint ignore=` and `# check=skip=` banned) |
| **Base Images (`FROM`)** | Pin explicit version tags or `@sha256:...` digests; `:latest` and untagged images are forbidden |
| **Multi-Stage Graph** | Unique `AS <stage>` aliases; valid `COPY --from=<stage>` references; zero unused/dead build stages |
| **Non-Root Runtime** | Final stage must switch to a non-root `USER` (bans missing `USER`, `root`, or UID `0`) |
| **Mandatory `HEALTHCHECK`** | Final stage must define an active `HEALTHCHECK ... CMD [...]` (`HEALTHCHECK NONE` is forbidden) |
| **Exec-Form Signals** | `CMD` and `ENTRYPOINT` must use JSON exec array syntax `["executable", ...]` for PID 1 `SIGTERM` delivery |
| **`RUN` & Cache Hygiene** | Bans `sudo`, `eval`, and `curl \| sh`; requires `apk add --no-cache`, `apt-get install --no-install-recommends` + apt list cleanup, or `--mount=type=cache` |
| **Context Leak (`.dockerignore`)** | Using `COPY .` requires a `.dockerignore` excluding both `.git` and `.env` / `.env*` |
| **Secret Hygiene** | Never hardcode secrets/tokens/passwords in `ENV` or `ARG`; use `/run/secrets/` or `--mount=type=secret` |

## 2. Hard Docker Compose & Topology Testing Gates (`compose.yaml`)
| Gate | Requirement |
| :--- | :--- |
| **Modern Compose Spec** | Omit obsolete top-level `version:` attribute; define non-empty `services:` |
| **Service Hardening** | Every service requires `security_opt: [no-new-privileges:true]`, active `healthcheck:` (`test:`), and explicit `restart:` policy |
| **Privilege & Host Bans** | Bans `privileged: true`, `user: root`/`0`, `/var/run/docker.sock` mounts, and `network_mode`/`pid`/`ipc`/`uts: host` |
| **Reference & DAG Testing** | `task test` verifies `secrets:`, `volumes:`, and `networks:` declarations, `depends_on` DAG acyclicity, and `build.context`/`dockerfile`/`target` stage existence |

## 3. Deep References (Load On-Demand Only)
- Complete multi-stage `Dockerfile`, `.dockerignore`, hardened `compose.yaml`, and `container-structure-test.yaml`: [references/dockerfile-and-compose.md](./references/dockerfile-and-compose.md)
