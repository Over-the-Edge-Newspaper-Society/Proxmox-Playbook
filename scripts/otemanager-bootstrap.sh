#!/usr/bin/env bash
set -Eeuo pipefail
# One-time Convex bootstrap for OTEManager.
#
# The self-hosted Convex backend starts EMPTY: no functions, no schema, no
# shared secret. Until all three exist the app returns errors that look like
# application bugs. This script does the three things, in order:
#
#   1. generate an admin key inside the Convex container
#   2. deploy the Convex functions + schema from the repo
#   3. set CONVEX_SERVER_SECRET *inside* Convex so it matches what the app sends
#
# Step 3 is the one that is easy to miss. The value lives in two places — the
# `otemanager-app-secret` Secret (read by the app) and Convex's own environment
# (which validates it). If they differ, every call is rejected.
#
# Requires: kubectl context on the cluster, and the OTEManager repo with
# `npm install` already run (it uses the repo's pinned convex CLI).
# The cluster kubeconfig is written by the K3s playbook to the personalprox
# repo root. Override with KUBECONFIG if yours lives elsewhere.
export KUBECONFIG="${KUBECONFIG:-$HOME/github/personalprox/kubeconfig.yml}"
[[ -r "$KUBECONFIG" ]] || { echo "kubeconfig not readable at $KUBECONFIG (set KUBECONFIG)" >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "cannot reach the cluster with KUBECONFIG=$KUBECONFIG" >&2; exit 1; }

NS="${OTE_NAMESPACE:-otemanager}"
REPO="${OTE_REPO_ROOT:-$HOME/github/OTEManager}"
PORT="${OTE_CONVEX_PORT:-3210}"

[[ -x "$REPO/node_modules/.bin/convex" ]] || {
  echo "convex CLI not found. Run: (cd '$REPO' && npm install)" >&2; exit 1; }

echo "==> waiting for the Convex backend"
kubectl -n "$NS" rollout status deploy/otemanager-convex --timeout=240s

POD="$(kubectl -n "$NS" get pod -l app=otemanager-convex -o jsonpath='{.items[0].metadata.name}')"
echo "==> generating admin key in $POD"
ADMIN_KEY="$(kubectl -n "$NS" exec "$POD" -- sh -c 'cd /convex && ./generate_admin_key.sh' \
  | grep -oE '[A-Za-z0-9_-]+\|[A-Za-z0-9_-]+' | tail -1)"
[[ -n "$ADMIN_KEY" ]] || { echo "could not parse the admin key" >&2; exit 1; }

SERVER_SECRET="$(kubectl -n "$NS" get secret otemanager-app-secret \
  -o jsonpath='{.data.CONVEX_SERVER_SECRET}' | base64 -d)"
[[ -n "$SERVER_SECRET" ]] || { echo "otemanager-app-secret has no CONVEX_SERVER_SECRET" >&2; exit 1; }

echo "==> port-forwarding Convex to 127.0.0.1:$PORT"
kubectl -n "$NS" port-forward "svc/otemanager-convex" "$PORT:3210" >/dev/null 2>&1 &
PF=$!
cleanup() {
  kill $PF 2>/dev/null || true
  # The repo's .env.local points the CLI at a LOCAL anonymous deployment and
  # would override the self-hosted target, so it is moved aside during the run.
  [[ -f "$REPO/.env.local.bootstrap-bak" ]] && mv "$REPO/.env.local.bootstrap-bak" "$REPO/.env.local"
}
trap cleanup EXIT
for _ in $(seq 1 30); do curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/version" && break; sleep 1; done

[[ -f "$REPO/.env.local" ]] && mv "$REPO/.env.local" "$REPO/.env.local.bootstrap-bak"

cd "$REPO"
export CONVEX_SELF_HOSTED_URL="http://127.0.0.1:$PORT"
export CONVEX_SELF_HOSTED_ADMIN_KEY="$ADMIN_KEY"

echo "==> deploying Convex functions"
node_modules/.bin/convex deploy -y

echo "==> setting CONVEX_SERVER_SECRET inside Convex"
node_modules/.bin/convex env set CONVEX_SERVER_SECRET "$SERVER_SECRET"

echo "==> Convex environment:"
node_modules/.bin/convex env list | sed -E 's/=.*/=<set>/'
echo
echo "Bootstrap complete. Keep this admin key if you want to run convex CLI"
echo "commands later (it is not stored anywhere by this script):"
echo "  $ADMIN_KEY"
