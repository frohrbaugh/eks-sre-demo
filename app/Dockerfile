# syntax=docker/dockerfile:1
#
# Single-stage: the runtime needs no compiler, so a builder stage would add
# complexity without removing anything from the final image.

FROM python:3.14-slim AS runtime

ARG GIT_SHA=dev

LABEL org.opencontainers.image.title="sre-demo-api" \
      org.opencontainers.image.description="Demo API for the EKS SRE portfolio project" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.licenses="MIT"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    APP_VERSION=${GIT_SHA}

# Fixed UID/GID so the Kubernetes securityContext can assert them (runAsUser:
# 10001). --no-create-home because the filesystem is read-only at runtime.
RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app

# Dependencies first: this layer only rebuilds when the lock file changes.
# --require-hashes makes every transitive dependency digest-pinned, so a
# compromised or re-published package cannot silently enter the image.
COPY requirements.lock ./requirements.lock
RUN python -m pip install --no-cache-dir --require-hashes -r requirements.lock

COPY app ./app

USER 10001:10001
EXPOSE 8080

# Exec form so uvicorn receives SIGTERM directly and can shut down gracefully
# within terminationGracePeriodSeconds.
CMD ["python", "-m", "uvicorn", "app.main:app", \
     "--host", "0.0.0.0", "--port", "8080", \
     "--proxy-headers", "--forwarded-allow-ips", "*"]
