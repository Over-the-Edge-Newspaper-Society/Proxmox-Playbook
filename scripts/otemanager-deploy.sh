#!/usr/bin/env bash
set -Eeuo pipefail
# One command: local code change -> built on the node -> running in the cluster.
#
#   ./scripts/otemanager-deploy.sh                 # convex functions + image + rollout
#   ./scripts/otemanager-deploy.sh --skip-convex   # image only (faster)
#   ./scripts/otemanager-deploy.sh --keep 5        # keep N old dev images (default 3)
#   ./scripts/otemanager-deploy.sh --rollback      # back to the previous image
#
# What it does, in order:
#   1. deploys Convex functions/schema (unless --skip-convex)
#   2. builds the image on the K3s node and imports it into containerd
#   3. records the currently running image so a bad rollout can be undone
#   4. points the overlay at the new tag and applies it
#   5. waits for the rollout; on failure, automatically rolls back
#   6. prunes old dev images so the node disk does not fill up
#
# Uncommitted changes are included: the source is rsynced, not pulled from git.

# The cluster kubeconfig is written by the K3s playbook to the personalprox
# repo root. Override with KUBECONFIG if yours lives elsewhere.
export KUBECONFIG="${KUBECONFIG:-$HOME/github/personalprox/kubeconfig.yml}"
[[ -r "$KUBECONFIG" ]] || { echo "kubeconfig not readable at $KUBECONFIG (set KUBECONFIG)" >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "cannot reach the cluster with KUBECONFIG=$KUBECONFIG" >&2; exit 1; }

NS="${OTE_NAMESPACE:-otemanager}"
REPO="${OTE_REPO_ROOT:-$HOME/github/OTEManager}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OVERLAY="$ROOT/k8s/otemanager/overlay"
SERVER_HOST="${OTE_K8S_HOST:-ubuntu@10.70.20.50}"
SSH_KEY="${OTE_K8S_SSH_KEY:-$HOME/.ssh/personalprox_pve_ed25519}"
PORT="${OTE_CONVEX_PORT:-3210}"
KEEP=3
SKIP_CONVEX=0
ROLLBACK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-convex) SKIP_CONVEX=1; shift ;;
    --keep) KEEP="$2"; shift 2 ;;
    --rollback) ROLLBACK=1; shift ;;
    -h|--help) grep -m22 '^#' "$0" | tail -n +2 | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

ssh_args=(-o BatchMode=yes -o ConnectTimeout=10 -i "$SSH_KEY" -o IdentitiesOnly=yes)
remote() { ssh "${ssh_args[@]}" "$SERVER_HOST" "$@"; }
current_image() {
  kubectl -n "$NS" get deploy otemanager -o jsonpath='{.spec.template.spec.containers[0].image}'
}

# ---------------------------------------------------------------- rollback ---
if [[ "$ROLLBACK" == "1" ]]; then
  prev="$(kubectl -n "$NS" get deploy otemanager \
    -o jsonpath='{.metadata.annotations.ote\.previous-image}' 2>/dev/null || true)"
  [[ -n "$prev" ]] || { echo "No recorded previous image to roll back to." >&2; exit 1; }
  echo "==> rolling back to $prev"
  kubectl -n "$NS" set image deploy/otemanager "app=$prev"
  kubectl -n "$NS" rollout status deploy/otemanager --timeout=300s
  exit 0
fi

# ------------------------------------------------------- convex functions ---
if [[ "$SKIP_CONVEX" == "0" ]]; then
  # Schema/function changes must land BEFORE the new app image, or the app
  # calls functions that do not exist yet. Deploying is idempotent and fast
  # when nothing changed, so it runs by default.
  echo "==> deploying Convex functions"
  POD="$(kubectl -n "$NS" get pod -l app=otemanager-convex -o jsonpath='{.items[0].metadata.name}')"
  ADMIN_KEY="$(kubectl -n "$NS" exec "$POD" -- sh -c 'cd /convex && ./generate_admin_key.sh' \
    | grep -oE '[A-Za-z0-9_-]+\|[A-Za-z0-9_-]+' | tail -1)"
  kubectl -n "$NS" port-forward svc/otemanager-convex "$PORT:3210" >/dev/null 2>&1 &
  PF=$!
  cleanup_pf() {
    kill $PF 2>/dev/null || true
    [[ -f "$REPO/.env.local.deploy-bak" ]] && mv "$REPO/.env.local.deploy-bak" "$REPO/.env.local"
  }
  trap cleanup_pf EXIT
  for _ in $(seq 1 30); do curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/version" && break; sleep 1; done
  # .env.local points the CLI at a local anonymous deployment and would win.
  [[ -f "$REPO/.env.local" ]] && mv "$REPO/.env.local" "$REPO/.env.local.deploy-bak"
  ( cd "$REPO" \
    && CONVEX_SELF_HOSTED_URL="http://127.0.0.1:$PORT" \
       CONVEX_SELF_HOSTED_ADMIN_KEY="$ADMIN_KEY" \
       node_modules/.bin/convex deploy -y )
  cleanup_pf
  trap - EXIT
fi

# ------------------------------------------------------------------ build ---
echo "==> building on $SERVER_HOST"
BUILD_LOG="$(mktemp)"
"$HERE/otemanager-local-build.sh" | tee "$BUILD_LOG"
TAG="$(grep -oE 'BUILD COMPLETE: (.+)' "$BUILD_LOG" | sed 's/BUILD COMPLETE: //')"
rm -f "$BUILD_LOG"
[[ -n "$TAG" ]] || { echo "Build did not report a tag." >&2; exit 1; }

# ----------------------------------------------------------------- deploy ---
PREV="$(current_image)"
echo "==> previous image: ${PREV:-none}"
sed -i.bak "s|newTag: .*|newTag: $TAG|" "$OVERLAY/kustomization.yaml" && rm -f "$OVERLAY/kustomization.yaml.bak"

kubectl apply -k "$OVERLAY"
# Record for --rollback. Annotating after apply keeps it out of the kustomize
# source, so it never gets overwritten by the next apply.
[[ -n "$PREV" ]] && kubectl -n "$NS" annotate deploy/otemanager "ote.previous-image=$PREV" --overwrite >/dev/null

echo "==> waiting for rollout"
if ! kubectl -n "$NS" rollout status deploy/otemanager --timeout=300s; then
  echo "!! rollout failed - rolling back to ${PREV:-<none>}" >&2
  if [[ -n "$PREV" ]]; then
    kubectl -n "$NS" set image deploy/otemanager "app=$PREV"
    kubectl -n "$NS" rollout status deploy/otemanager --timeout=300s || true
  fi
  echo "Recent app logs:" >&2
  kubectl -n "$NS" logs deploy/otemanager --tail=40 >&2 || true
  exit 1
fi

# ------------------------------------------------------------------ prune ---
# Each build leaves a tagged image in Docker and a copy in containerd. Without
# pruning the node fills up; image GC then evicts images and deployments break.
echo "==> pruning old dev images (keeping $KEEP)"
remote "sudo -n docker images --format '{{.Repository}}:{{.Tag}}' \
  | grep '^otemanager-local/app:dev-' | sort -r | tail -n +\$(( $KEEP + 1 )) \
  | xargs -r -n1 sudo -n docker rmi -f >/dev/null 2>&1 || true"
remote "sudo -n k3s ctr -n k8s.io images list -q \
  | grep '^docker.io/otemanager-local/app:dev-' | sort -r | tail -n +\$(( $KEEP + 1 )) \
  | grep -v ':$TAG\$' | xargs -r -n1 sudo -n k3s ctr -n k8s.io images rm >/dev/null 2>&1 || true"

echo
echo "Deployed: $(current_image)"
remote "df -h / | tail -1" | sed 's/^/node disk: /'
# Traefik can briefly hold the terminating pod's endpoint after the rollout
# reports complete, which shows up as a 502. Retry before calling it a failure.
for url in http://otemanager.k8s.ote https://otemanager.k8s.overtheedgepaper.ca; do
  printf '%-46s ' "$url"
  code=000
  for _ in $(seq 1 12); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url/" || echo 000)"
    [[ "$code" == "200" ]] && break
    sleep 5
  done
  echo "HTTP $code"
done
