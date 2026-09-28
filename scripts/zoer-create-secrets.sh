#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 077
# Creates the core Secret required by Zoer. DDEV setup owns its optional Secret.
#
# The core secret is referenced by envFrom and must exist before startup.
#
# Neither AI_API_KEY nor SECRETS_KEY is required:
#   - AI_API_KEY  falls back to "ollama"  (backend/src/providers/registry.ts)
#   - SECRETS_KEY is generated and persisted to the data volume if unset
#                                          (backend/src/secrets.ts)
# JOB_STORE_PASSWORD *is* required — the Postgres job store reads it.
NS="${ZOER_NAMESPACE:-zoer}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/ote-k3s.yaml}"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

existing="$(kubectl -n "$NS" get secret zoer-app-secret --ignore-not-found -o name)"
if [[ -n "$existing" ]]; then
  echo "zoer-app-secret already exists — leaving it alone."
else
  JOB_STORE_PASSWORD="$(openssl rand -hex 24)"
  SECRETS_KEY="$(openssl rand -hex 32)"
  secret_file="$(mktemp)"
  trap 'rm -f "$secret_file"' EXIT
  printf 'JOB_STORE_PASSWORD=%s\nSECRETS_KEY=%s\n' "$JOB_STORE_PASSWORD" "$SECRETS_KEY" > "$secret_file"
  kubectl -n "$NS" create secret generic zoer-app-secret --from-env-file="$secret_file"
  echo "zoer-app-secret created with generated values."
  echo "NOTE: if you are restoring an existing Zoer instance, replace these with"
  echo "      the original values or the existing database/encrypted data is unreadable."
fi

# DDEV's optional secret is created by zoer-setup-ddev.sh only after the
# worker is healthy. Never apply an empty secret over an existing credential.
kubectl -n "$NS" get secret zoer-app-secret
