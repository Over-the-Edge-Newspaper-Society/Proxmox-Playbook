#!/usr/bin/env bash
set -Eeuo pipefail
# Creates the two Secrets the Zoer backend needs before it will start.
#
# Both are referenced by `envFrom` in k8s/zoer-local/base/backend.yaml WITHOUT
# `optional: true`, so if either is missing the pod never starts — it sits in
# CreateContainerConfigError, which is easy to misread as an image problem.
#
# Neither AI_API_KEY nor SECRETS_KEY is required:
#   - AI_API_KEY  falls back to "ollama"  (backend/src/providers/registry.ts)
#   - SECRETS_KEY is generated and persisted to the data volume if unset
#                                          (backend/src/secrets.ts)
# JOB_STORE_PASSWORD *is* required — the Postgres job store reads it.
NS="${ZOER_NAMESPACE:-zoer}"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

if kubectl -n "$NS" get secret zoer-app-secret >/dev/null 2>&1; then
  echo "zoer-app-secret already exists — leaving it alone."
else
  JOB_STORE_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
  SECRETS_KEY="$(openssl rand -hex 32)"
  kubectl -n "$NS" create secret generic zoer-app-secret \
    --from-literal=JOB_STORE_PASSWORD="$JOB_STORE_PASSWORD" \
    --from-literal=SECRETS_KEY="$SECRETS_KEY"
  echo "zoer-app-secret created with generated values."
  echo "NOTE: if you are restoring an existing Zoer instance, replace these with"
  echo "      the original values or the existing database/encrypted data is unreadable."
fi

# Referenced by envFrom but has no required keys; it must simply exist.
kubectl -n "$NS" create secret generic zoer-ddev-bridge \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "zoer-ddev-bridge present."

kubectl -n "$NS" get secret zoer-app-secret zoer-ddev-bridge
