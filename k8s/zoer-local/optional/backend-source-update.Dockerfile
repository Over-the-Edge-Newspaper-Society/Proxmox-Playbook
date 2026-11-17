# Opt-in source-only update of an existing local backend. The operator build
# helper verifies dependency/config inputs before selecting this pathway.
ARG ZOER_BACKEND_BASE_IMAGE=scratch
FROM ${ZOER_BACKEND_BASE_IMAGE}
ARG ZOER_GIT_COMMIT=unknown
ARG ZOER_GIT_DIRTY=false
ENV ZOER_GIT_COMMIT=${ZOER_GIT_COMMIT}
ENV ZOER_GIT_DIRTY=${ZOER_GIT_DIRTY}
LABEL org.opencontainers.image.revision=${ZOER_GIT_COMMIT}
LABEL sh.zoer.git.dirty=${ZOER_GIT_DIRTY}
COPY convex /app/convex
COPY backend/src /app/backend/src
COPY backend/skills /app/backend/skills
# The Python scraper (scrape.py) runs from here with the base image's /opt/zoer-scraper venv.
COPY backend/scripts /app/backend/scripts
RUN /opt/zoer-scraper/bin/python -c 'import ast,sys; ast.parse(open("/app/backend/scripts/scrape.py").read())'
COPY sdk/packages/api-types/src /app/sdk/packages/api-types/src
COPY sdk/packages/plugin-contracts/src /app/sdk/packages/plugin-contracts/src
COPY browser-runtime /app/browser-runtime
ARG ZOER_BROWSER_RUNTIME_IMAGE
ENV BROWSER_RUNTIME_IMAGE=${ZOER_BROWSER_RUNTIME_IMAGE}
ENV ZOER_DEV_BROWSER_RUNTIME_IMAGE=${ZOER_BROWSER_RUNTIME_IMAGE}
ARG ZOER_AGENT_RUNTIME_IMAGE
ENV AGENT_RUNNER_IMAGE=${ZOER_AGENT_RUNTIME_IMAGE}
ENV AGENT_RUNTIME_IMAGE=${ZOER_AGENT_RUNTIME_IMAGE}
ENV ZOER_DEV_AGENT_RUNTIME_IMAGE=${ZOER_AGENT_RUNTIME_IMAGE}
ARG ZOER_BUILD_RUNNER_IMAGE
ENV ZOER_BUILD_RUNNER_IMAGE=${ZOER_BUILD_RUNNER_IMAGE}
ARG ZOER_SOURCE_NODE_HEAP_MB=3072
ARG ZOER_SOURCE_PRECHECK_SHA256
LABEL sh.zoer.source-typecheck.sha256=${ZOER_SOURCE_PRECHECK_SHA256}
RUN if [ -z "$ZOER_SOURCE_PRECHECK_SHA256" ]; then ulimit -c 0 && NODE_OPTIONS=--max-old-space-size=${ZOER_SOURCE_NODE_HEAP_MB} bun x tsc --noEmit; fi
