# Multi-Stage `Dockerfile`, `.dockerignore`, `compose.yaml` & Structure Test Reference

## 1. `.dockerignore`
```dockerignore
.git
.env
.env.*
.venv
__pycache__
.cache
.guardrails
tests
*.md
```

## 2. Multi-Stage `Dockerfile`
```dockerfile
FROM ghcr.io/astral-sh/uv:python3.12-alpine AS builder
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy
WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev

COPY . /app
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev

FROM ghcr.io/astral-sh/uv:python3.12-alpine AS runtime
RUN apk add --no-cache ffmpeg && addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app
COPY --from=builder --chown=appuser:appgroup /app /app
ENV PATH="/app/.venv/bin:$PATH" PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
USER appuser
EXPOSE 8550
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8550/health')"]
CMD ["python", "-m", "my_app.main"]
```

## 3. Hardened `compose.yaml`
```yaml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
      target: runtime
    ports:
      - "8550:8550"
    environment:
      - ENV=production
    secrets:
      - gemini_api_key
      - google_tts_api_key
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8550/health')"]
      interval: 30s
      timeout: 5s
      retries: 3
    restart: unless-stopped

secrets:
  gemini_api_key:
    file: ./secrets/gemini_api_key.txt
  google_tts_api_key:
    file: ./secrets/google_tts_api_key.txt
```

## 4. `container-structure-test.yaml`
```yaml
schemaVersion: "2.0.0"

metadataTest:
  user: "appuser"
  workdir: "/app"
  exposedPorts: ["8550"]

fileExistenceTests:
  - name: "Virtualenv Python binary exists"
    path: "/app/.venv/bin/python"
    shouldExist: true

commandTests:
  - name: "Non-root user verification"
    command: "id"
    args: ["-u"]
    expectedOutput: ["100.*"]
```
