#!/usr/bin/env bash
set -Eeuo pipefail
# One command: local code change -> built on the K3s node -> running in the cluster.
#
#   ./scripts/zoer-deploy.sh             # build backend+frontend, apply, verify
#   ./scripts/zoer-deploy.sh --keep 2    # keep N old dev images per component (default 2)
#   ./scripts/zoer-deploy.sh --rollback  # back to the previously deployed images
#   ./scripts/zoer-deploy.sh --force     # drain but do not wait for running work
#   ./scripts/zoer-deploy.sh --drain-timeout 900 # seconds to wait for the drain (default 600)
#   ./scripts/zoer-deploy.sh --no-drain  # legacy: no drain, refuse while plugin workers run
#   ./scripts/zoer-deploy.sh --without-ddev # disable / skip the DDEV worker
#   ./scripts/zoer-deploy.sh --with-ddev    # install and enable the DDEV worker
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
#
# Maintenance drain: after the build and before the rollout the backend is asked
# to drain (pause long-running work, stop claiming new steps). The script polls
# until it is safe to restart, rolls out, then resumes the paused work on the new
# backend. Any failure, timeout, rollback or Ctrl-C after the drain resumes the
# work on whichever backend pod answers. See docs/ZOER-LOCAL.md.

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
DRAIN=1
DRAIN_TIMEOUT=600

# shellcheck source=SCRIPTDIR/lib/zoer-maintenance.sh
source "$HERE/lib/zoer-maintenance.sh"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/ote-k3s.yaml}"
[[ -r "$KUBECONFIG" ]] || { echo "kubeconfig not readable at $KUBECONFIG (set KUBECONFIG)" >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "cannot reach the cluster with KUBECONFIG=$KUBECONFIG" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP="$2"; shift 2 ;;
    --rollback) ROLLBACK=1; shift ;;
    --force) FORCE=1; shift ;;
    --no-drain) DRAIN=0; shift ;;
    --drain-timeout) DRAIN_TIMEOUT="$2"; shift 2 ;;
    --skip-convex) SKIP_CONVEX=1; shift ;;
    --without-ddev) export ZOER_DDEV_ENABLED=0; shift ;;
    --with-ddev) export ZOER_DDEV_ENABLED=1; shift ;;
    -h|--help) awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$DRAIN_TIMEOUT" =~ ^[0-9]+$ ]] || { echo "--drain-timeout needs a number of seconds" >&2; exit 2; }
if [[ "$DRAIN" == "1" ]] && ! command -v jq >/dev/null; then
  echo "jq is required for the maintenance drain (install it, or use --no-drain)." >&2; exit 1
fi

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
  if zm_probe && [[ "$(zm_json '.draining')" == "true" ]]; then
    echo "!! the backend is still draining (drainId $(zm_json '.drainId'), expires $(zm_json '.expiresAt'))." >&2
    zm_manual_hint
  fi
  exit 0
fi

# Legacy guard (--no-drain, or a backend without the maintenance API): refuse
# while plugin workers exist, because rolling the backend severs an in-flight
# integration worker's capability stream mid-run. With the drain the backend
# pauses those workers itself and the drain wait also waits for their pods.
check_plugin_workers() {
  local w
  w="$(zm_plugin_pods)"
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

# From here on, a drained backend is resumed on any exit (failure, Ctrl-C...).
trap zm_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Probe before the long build so an old backend is reported up front.
MAINT_OK=0
if [[ "$DRAIN" == "1" ]]; then
  if zm_probe; then
    MAINT_OK=1
    if [[ "$(zm_json '.draining')" == "true" ]]; then
      echo "!! the backend is already draining (drainId $(zm_json '.drainId'), requested $(zm_json '.requestedAt'))." >&2
      echo "   A previous deploy probably died; this deploy reuses that drain and resumes it at the end." >&2
    fi
    w="$(zm_plugin_pods)"
    [[ -n "$w" ]] && { echo "==> plugin workers running now (the drain after the build pauses them):"; echo "    ${w//$'\n'/$'\n'    }"; }
  elif [[ "$ZM_STATUS" == "404" ]]; then
    echo "!! the running backend has no maintenance API (HTTP 404) - expected on the first deploy" >&2
    echo "   of the drain feature. Using the legacy plugin-worker guard for this deploy." >&2
  else
    echo "!! could not query the maintenance API (HTTP $ZM_STATUS); using the legacy plugin-worker guard for now." >&2
  fi
fi
[[ "$MAINT_OK" == "1" ]] || check_plugin_workers

# Reconcile the saved runtime choice before enabling it in the next pod.
"$HERE/zoer-create-secrets.sh"
ZOER_DDEV_DEFER_ROLLOUT=1 "$HERE/zoer-setup-ddev.sh"

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
# The build may use up to its cap (ZOER_BUILD_MEM, enforced by the capped buildx
# builder in zoer-local-build.sh); keep 1.5 GB beyond that for the running cluster.
build_mem="${ZOER_BUILD_MEM:-6g}"
case "$build_mem" in
  *[gG]) build_mem_mb=$(( ${build_mem%[gG]} * 1024 )) ;;
  *[mM]) build_mem_mb=${build_mem%[mM]} ;;
  *) echo "ZOER_BUILD_MEM must look like 6g or 5120m." >&2; exit 2 ;;
esac
MIN_FREE_MB="${ZOER_MIN_FREE_MB:-$(( build_mem_mb + 1536 ))}"
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

# Drain before the rollout (re-checked after the build, which takes many minutes).
if [[ "$DRAIN" == "1" ]]; then
  echo "==> draining Zoer (pausing long-running work; timeout ${DRAIN_TIMEOUT}s)"
  ttl=$(( DRAIN_TIMEOUT + 1500 )); (( ttl < 2700 )) && ttl=2700; (( ttl > 7200 )) && ttl=7200
  drain_rc=0; zm_drain "zoer-deploy $TAG" "$ttl" || drain_rc=$?
  case "$drain_rc" in
    0)
      if [[ "$FORCE" == "1" ]]; then
        echo "    --force: not waiting for the drain; current state:"
        zm_show_status | sed 's/^/    /'
      elif ! zm_wait_safe "$DRAIN_TIMEOUT"; then
        echo "!! work did not drain within ${DRAIN_TIMEOUT}s - nothing was deployed." >&2
        echo "   Re-run later, raise --drain-timeout, or use --force to restart anyway." >&2
        exit 1
      fi ;;
    1)
      echo "!! the backend has no maintenance API (HTTP 404) - falling back to the legacy plugin-worker guard." >&2
      check_plugin_workers ;;
    *)
      if [[ "$FORCE" != "1" ]]; then
        echo "!! could not drain the backend - nothing was deployed (use --force or --no-drain to override)." >&2
        exit 1
      fi
      echo "--force given; continuing without a confirmed drain." >&2
      check_plugin_workers ;;
  esac
else
  check_plugin_workers
fi

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
  exit 1   # the EXIT trap resumes paused work on the rolled-back backend
fi

if [[ "$ZM_DRAINED" == "1" ]]; then
  echo "==> resuming paused work on the new backend"
  if ! zm_resume_new 300; then
    echo "!! the deploy itself succeeded, but paused work was not resumed." >&2
    ZM_TRAP_WAIT=30
    exit 1
  fi
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
