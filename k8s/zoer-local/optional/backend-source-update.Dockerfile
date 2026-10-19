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
COPY packages/api-types /app/packages/api-types
COPY convex /app/convex
COPY backend/src /app/backend/src
COPY backend/skills /app/backend/skills
COPY browser-runtime /app/browser-runtime
ARG ZOER_BROWSER_RUNTIME_IMAGE
ENV BROWSER_RUNTIME_IMAGE=${ZOER_BROWSER_RUNTIME_IMAGE}
ENV ZOER_DEV_BROWSER_RUNTIME_IMAGE=${ZOER_BROWSER_RUNTIME_IMAGE}
ARG ZOER_AGENT_RUNTIME_IMAGE
ENV AGENT_RUNTIME_IMAGE=${ZOER_AGENT_RUNTIME_IMAGE}
ENV ZOER_DEV_AGENT_RUNTIME_IMAGE=${ZOER_AGENT_RUNTIME_IMAGE}
RUN ulimit -c 0 && NODE_OPTIONS=--max-old-space-size=2048 bun x tsc --noEmit
