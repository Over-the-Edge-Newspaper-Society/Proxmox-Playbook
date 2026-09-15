#!/usr/bin/env bash
set -Eeuo pipefail
# One command: local code change -> built on the K3s node -> running in the cluster.
#
#   ./scripts/zoer-deploy.sh             # build backend+frontend, apply, verify
#   ./scripts/zoer-deploy.sh --keep 2    # keep N old dev images per component (default 2)
#   ./scripts/zoer-deploy.sh --rollback  # back to the previously deployed images
#   ./scripts/zoer-deploy.sh --force     # deploy even if plugin workers are running
#   ./scripts/zoer-deploy.sh --skip-convex  # skip the Convex function deploy
#
# Zoer's own scripts/k8s-server-dev.sh cannot be used on this cluster: its `up`
# hard-requires a Flux Kustomization named "zoer", and there is no Flux here.
# This reproduces its build path and applies the manifests directly.
#
# Uncommitted changes ARE included - the source is rsynced, not pulled from git.
# The image tag carries the commit plus a -dirty suffix when the tree is modified.
#
# Zoer images are large (backend ~8.7GB). The build needs >=15 GiB free and
# takes 20-30 minutes from cold with no Docker layer cache.

NS="${ZOER_NAMESPACE:-zoer}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OVERLAY="$ROOT/k8s/zoer-local/overlay"
SERVER_HOST="${ZOER_K8S_DEV_HOST:-ubuntu@10.70.20.50}"
SSH_KEY="${ZOER_K8S_DEV_SSH_KEY:-$HOME/.ssh/personalprox_pve_ed25519}"
KEEP=2
ROLLBACK=0
FORCE=0
SKIP_CONVEX=0

export KUBECONFIG="${KUBECONFIG:-$HOME/github/personalprox/kubeconfig.yml}"
[[ -r "$KUBECONFIG" ]] || { echo "kubeconfig not readable at $KUBECONFIG (set KUBECONFIG)" >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "cannot reach the cluster with KUBECONFIG=$KUBECONFIG" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP="$2"; shift 2 ;;
    --rollback) ROLLBACK=1; shift ;;
    --force) FORCE=1; shift ;;
    --skip-convex) SKIP_CONVEX=1; shift ;;
    -h|--help) grep -m20 '^#' "$0" | tail -n +2 | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

ssh_args=(-o BatchMode=yes -o ConnectTimeout=10 -i "$SSH_KEY" -o IdentitiesOnly=yes)
remote() { ssh "${ssh_args[@]}" "$SERVER_HOST" "$@"; }
image_of() { kubectl -n "$NS" get deploy "$1" -o jsonpath='{.spec.template.spec.containers[0].image}'; }

if [[ "$ROLLBACK" == "1" ]]; then
  pb="$(kubectl -n "$NS" get deploy zoer-backend  -o jsonpath='{.metadata.annotations.zoer\.previous-image}' 2>/dev/null || true)"
  pf="$(kubectl -n "$NS" get deploy zoer-frontend -o jsonpath='{.metadata.annotations.zoer\.previous-image}' 2>/dev/null || true)"
  [[ -n "$pb" && -n "$pf" ]] || { echo "No recorded previous images to roll back to." >&2; exit 1; }
  echo "==> rolling back backend  -> $pb"
  echo "==> rolling back frontend -> $pf"
  kubectl -n "$NS" set image deploy/zoer-backend  "backend=$pb"
  kubectl -n "$NS" set image deploy/zoer-frontend "frontend=$pf"
  kubectl -n "$NS" rollout status deploy/zoer-backend  --timeout=600s
  kubectl -n "$NS" rollout status deploy/zoer-frontend --timeout=600s
  exit 0
fi

# Upstream refuses to deploy while plugin workers exist, with good reason:
# rolling the backend severs an in-flight integration worker's capability
# stream mid-run. Re-checked here because a build takes many minutes.
check_plugin_workers() {
  local w
  w="$(kubectl -n "$NS" get pods -l zoer.plugin-runner=true \
        --field-selector=status.phase!=Succeeded,status.phase!=Failed -o name 2>/dev/null || true)"
  if [[ -n "$w" ]]; then
    echo "Plugin workers are still running:" >&2; echo "$w" >&2
    if [[ "$FORCE" == "1" ]]; then
      echo "--force given; deploying anyway." >&2
    else
      echo "Let their runs finish, or re-run with --force." >&2
      exit 1
    fi
  fi
}
check_plugin_workers

# Deploy Convex functions BEFORE the new image. Zoer's backend calls Convex
# functions by name; ship app code that references a function the deployment
# does not have and it fails at runtime with
#   "credential store is missing the Convex function secrets:create"
# which reads like an application bug rather than a deploy-ordering mistake.
#
# This is exactly what bit the WordPress "Test and add site" flow: Zoer's Convex
# had NO functions deployed at all, because the original deploy never pushed
# them. Idempotent and quick, so it runs every time.
if [[ "$SKIP_CONVEX" != "1" ]]; then
  echo "==> deploying Convex functions"
  ZPOD="$(kubectl -n "$NS" get pod -l app=zoer-convex -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  if [[ -n "$ZPOD" ]]; then
    ZKEY="$(kubectl -n "$NS" exec "$ZPOD" -- sh -c 'cd /convex && ./generate_admin_key.sh' 2>/dev/null \
            | grep -oE '[A-Za-z0-9_-]+\|[A-Za-z0-9_-]+' | tail -1)"
    kubectl -n "$NS" port-forward svc/zoer-convex "${ZOER_CONVEX_PORT:-3215}:3210" >/dev/null 2>&1 &
    ZPF=$!
    for _ in $(seq 1 30); do curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${ZOER_CONVEX_PORT:-3215}/version" && break; sleep 1; done
    ( cd "${ZOER_REPO_ROOT:-$HOME/github/zoer}" \
      && CONVEX_SELF_HOSTED_URL="http://127.0.0.1:${ZOER_CONVEX_PORT:-3215}" \
         CONVEX_SELF_HOSTED_ADMIN_KEY="$ZKEY" \
         node_modules/.bin/convex deploy -y ) || echo "!! convex deploy failed - continuing, but app code may call missing functions" >&2
    kill $ZPF 2>/dev/null || true
  else
    echo "    (no zoer-convex pod found; skipping)" >&2
  fi
fi

# Pre-flight: refuse to build when the node has no memory headroom. A build
# here competes with the workloads it is deploying; starving the node takes out
# the API server and every app, and recovery needed a hard VM restart.
MIN_FREE_MB="${ZOER_MIN_FREE_MB:-6000}"
avail_mb="$(remote "free -m | awk '/^Mem:/{print \$7}'" 2>/dev/null || echo 0)"
echo "==> node memory available: ${avail_mb} MB (need >= ${MIN_FREE_MB} MB)"
if [[ "${avail_mb:-0}" -lt "$MIN_FREE_MB" ]]; then
  echo "!! Not enough free memory on $SERVER_HOST to build safely." >&2
  echo "   Free memory first (stop unused guests, or raise the VM's RAM), or" >&2
  echo "   override with ZOER_MIN_FREE_MB=<mb> if you accept the risk." >&2
  exit 1
fi

echo "==> building on $SERVER_HOST (this takes a while)"
LOG="$(mktemp)"
"$HERE/zoer-local-build.sh" | tee "$LOG"
TAG="$(grep -oE 'BUILD COMPLETE: (.+)' "$LOG" | sed 's/BUILD COMPLETE: //')"
rm -f "$LOG"
[[ -n "$TAG" ]] || { echo "Build did not report a tag." >&2; exit 1; }

# Builds are slow; a worker may have started in the meantime.
check_plugin_workers

PREV_B="$(image_of zoer-backend  2>/dev/null || true)"
PREV_F="$(image_of zoer-frontend 2>/dev/null || true)"
echo "==> previous backend : ${PREV_B:-none}"
echo "==> previous frontend: ${PREV_F:-none}"

# Backend and frontend share one tag, so replace every newTag line.
sed -i.bak "s|newTag: .*|newTag: $TAG|g" "$OVERLAY/kustomization.yaml" && rm -f "$OVERLAY/kustomization.yaml.bak"
kubectl apply -k "$OVERLAY"

# Annotated after apply so kustomize never overwrites it.
[[ -n "$PREV_B" ]] && kubectl -n "$NS" annotate deploy/zoer-backend  "zoer.previous-image=$PREV_B" --overwrite >/dev/null
[[ -n "$PREV_F" ]] && kubectl -n "$NS" annotate deploy/zoer-frontend "zoer.previous-image=$PREV_F" --overwrite >/dev/null

echo "==> waiting for rollouts"
ok=1
kubectl -n "$NS" rollout status deploy/zoer-backend  --timeout=600s || ok=0
kubectl -n "$NS" rollout status deploy/zoer-frontend --timeout=600s || ok=0
if [[ "$ok" == "0" ]]; then
  echo "!! rollout failed - rolling back" >&2
  [[ -n "$PREV_B" ]] && kubectl -n "$NS" set image deploy/zoer-backend  "backend=$PREV_B"  || true
  [[ -n "$PREV_F" ]] && kubectl -n "$NS" set image deploy/zoer-frontend "frontend=$PREV_F" || true
  kubectl -n "$NS" rollout status deploy/zoer-backend  --timeout=600s || true
  kubectl -n "$NS" rollout status deploy/zoer-frontend --timeout=600s || true
  echo "--- backend logs ---" >&2; kubectl -n "$NS" logs deploy/zoer-backend --tail=40 >&2 || true
  exit 1
fi

# Prune per component so backend and frontend are kept independently, and never
# touch browser-runtime / agent-runtime (content-hash tags the backend still
# references to launch browsers and agents).
echo "==> pruning old dev images (keeping $KEEP of each)"
for c in backend frontend; do
  remote "sudo -n docker images --format '{{.Repository}}:{{.Tag}}' \
    | grep '^zoer-local/$c:dev-' | sort -r | tail -n +\$(( $KEEP + 1 )) \
    | xargs -r -n1 sudo -n docker rmi -f >/dev/null 2>&1 || true"
  remote "sudo -n k3s ctr -n k8s.io images list -q \
    | grep '^docker.io/zoer-local/$c:dev-' | grep -v ':$TAG\$' | sort -r | tail -n +\$(( $KEEP + 1 )) \
    | xargs -r -n1 sudo -n k3s ctr -n k8s.io images rm >/dev/null 2>&1 || true"
done

# Runtime images are tagged by content hash and referenced by the backend, not
# by a Deployment, so the per-component prune above cannot touch them safely.
# This pass reads every backend image's baked-in refs (containerd included) and
# removes only genuinely unreferenced runtimes.
echo "==> checking for stale runtime images"
"$HERE/zoer-prune-runtimes.sh" ${ZOER_PRUNE_RUNTIMES:+--apply} || true
[[ -z "${ZOER_PRUNE_RUNTIMES:-}" ]] && echo "    (dry run; set ZOER_PRUNE_RUNTIMES=1 to remove them automatically)"

echo
echo "backend : $(image_of zoer-backend)"
echo "frontend: $(image_of zoer-frontend)"
remote "df -h / | tail -1" | sed 's/^/node disk: /'
# Traefik can briefly hold a terminating pod's endpoint after rollout completes.
for url in http://zoer.k8s.ote https://zoer.k8s.overtheedgepaper.ca; do
  printf '%-44s ' "$url"
  code=000
  for _ in $(seq 1 12); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url/" || echo 000)"
    [[ "$code" == "200" ]] && break
    sleep 5
  done
  echo "HTTP $code"
done
echo "build provenance:"
curl -s --max-time 15 http://zoer.k8s.ote/api/health | sed 's/^/  /'; echo
