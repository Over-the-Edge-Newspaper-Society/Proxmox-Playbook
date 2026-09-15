#!/usr/bin/env bash
set -Eeuo pipefail
# One command: local code change -> built on the node -> running in the cluster.
#
#   ./scripts/eventscrape-deploy.sh              # build both images, apply, verify
#   ./scripts/eventscrape-deploy.sh --keep 5     # keep N old dev images (default 3)
#   ./scripts/eventscrape-deploy.sh --rollback   # back to the previous images
#
# Builds BOTH the admin SPA and the scraper worker and rolls them out together;
# they share one tag. Convex functions are not deployed here — for EventScrape
# they live inside the Convex database itself.
#
# Uncommitted changes are included: the source is rsynced, not pulled from git.
#
# NOTE: the admin image bakes VITE_CONVEX_URL at build time. If the public
# Convex hostname changes, the admin image must be rebuilt.

NS="${ES_NAMESPACE:-eventscrape}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OVERLAY="$ROOT/k8s/eventscrape/overlay"
SERVER_HOST="${ES_K8S_HOST:-ubuntu@10.70.20.50}"
SSH_KEY="${ES_K8S_SSH_KEY:-$HOME/.ssh/personalprox_pve_ed25519}"
KEEP=3
ROLLBACK=0

export KUBECONFIG="${KUBECONFIG:-$HOME/github/personalprox/kubeconfig.yml}"
[[ -r "$KUBECONFIG" ]] || { echo "kubeconfig not readable at $KUBECONFIG (set KUBECONFIG)" >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "cannot reach the cluster with KUBECONFIG=$KUBECONFIG" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP="$2"; shift 2 ;;
    --rollback) ROLLBACK=1; shift ;;
    -h|--help) grep -m18 '^#' "$0" | tail -n +2 | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

ssh_args=(-o BatchMode=yes -o ConnectTimeout=10 -i "$SSH_KEY" -o IdentitiesOnly=yes)
remote() { ssh "${ssh_args[@]}" "$SERVER_HOST" "$@"; }
image_of() { kubectl -n "$NS" get deploy "$1" -o jsonpath='{.spec.template.spec.containers[0].image}'; }

if [[ "$ROLLBACK" == "1" ]]; then
  pa="$(kubectl -n "$NS" get deploy eventscrape-admin  -o jsonpath='{.metadata.annotations.es\.previous-image}' 2>/dev/null || true)"
  pw="$(kubectl -n "$NS" get deploy eventscrape-worker -o jsonpath='{.metadata.annotations.es\.previous-image}' 2>/dev/null || true)"
  [[ -n "$pa" && -n "$pw" ]] || { echo "No recorded previous images to roll back to." >&2; exit 1; }
  echo "==> rolling back admin -> $pa"
  echo "==> rolling back worker -> $pw"
  kubectl -n "$NS" set image deploy/eventscrape-admin  "admin=$pa"
  kubectl -n "$NS" set image deploy/eventscrape-worker "worker=$pw"
  kubectl -n "$NS" rollout status deploy/eventscrape-admin  --timeout=300s
  kubectl -n "$NS" rollout status deploy/eventscrape-worker --timeout=300s
  exit 0
fi

echo "==> building on $SERVER_HOST"
LOG="$(mktemp)"
"$HERE/eventscrape-local-build.sh" | tee "$LOG"
TAG="$(grep -oE 'BUILD COMPLETE: (.+)' "$LOG" | sed 's/BUILD COMPLETE: //')"
rm -f "$LOG"
[[ -n "$TAG" ]] || { echo "Build did not report a tag." >&2; exit 1; }

PREV_ADMIN="$(image_of eventscrape-admin  2>/dev/null || true)"
PREV_WORKER="$(image_of eventscrape-worker 2>/dev/null || true)"
echo "==> previous admin : ${PREV_ADMIN:-none}"
echo "==> previous worker: ${PREV_WORKER:-none}"

# Both images share the tag, so replace every newTag line.
sed -i.bak "s|newTag: .*|newTag: $TAG|g" "$OVERLAY/kustomization.yaml" && rm -f "$OVERLAY/kustomization.yaml.bak"
kubectl apply -k "$OVERLAY"

# Recorded after apply so kustomize never overwrites the annotation.
[[ -n "$PREV_ADMIN"  ]] && kubectl -n "$NS" annotate deploy/eventscrape-admin  "es.previous-image=$PREV_ADMIN"  --overwrite >/dev/null
[[ -n "$PREV_WORKER" ]] && kubectl -n "$NS" annotate deploy/eventscrape-worker "es.previous-image=$PREV_WORKER" --overwrite >/dev/null

echo "==> waiting for rollouts"
ok=1
kubectl -n "$NS" rollout status deploy/eventscrape-admin  --timeout=300s || ok=0
kubectl -n "$NS" rollout status deploy/eventscrape-worker --timeout=300s || ok=0
if [[ "$ok" == "0" ]]; then
  echo "!! rollout failed - rolling back" >&2
  [[ -n "$PREV_ADMIN"  ]] && kubectl -n "$NS" set image deploy/eventscrape-admin  "admin=$PREV_ADMIN"  || true
  [[ -n "$PREV_WORKER" ]] && kubectl -n "$NS" set image deploy/eventscrape-worker "worker=$PREV_WORKER" || true
  kubectl -n "$NS" rollout status deploy/eventscrape-admin  --timeout=300s || true
  kubectl -n "$NS" rollout status deploy/eventscrape-worker --timeout=300s || true
  echo "--- admin logs ---"  >&2; kubectl -n "$NS" logs deploy/eventscrape-admin  --tail=30 >&2 || true
  echo "--- worker logs ---" >&2; kubectl -n "$NS" logs deploy/eventscrape-worker --tail=30 >&2 || true
  exit 1
fi

# Prune per-repository so admin and worker tags are kept independently —
# sorting them together would keep 3 of one and none of the other.
echo "==> pruning old dev images (keeping $KEEP of each)"
for c in admin worker; do
  remote "sudo -n docker images --format '{{.Repository}}:{{.Tag}}' \
    | grep '^eventscrape-local/$c:dev-' | sort -r | tail -n +\$(( $KEEP + 1 )) \
    | xargs -r -n1 sudo -n docker rmi -f >/dev/null 2>&1 || true"
  remote "sudo -n k3s ctr -n k8s.io images list -q \
    | grep '^docker.io/eventscrape-local/$c:dev-' | grep -v ':$TAG\$' | sort -r | tail -n +\$(( $KEEP + 1 )) \
    | xargs -r -n1 sudo -n k3s ctr -n k8s.io images rm >/dev/null 2>&1 || true"
done

echo
echo "admin : $(image_of eventscrape-admin)"
echo "worker: $(image_of eventscrape-worker)"
remote "df -h / | tail -1" | sed 's/^/node disk: /'
# Traefik can hold a terminating pod's endpoint briefly after rollout completes.
for url in http://events.k8s.ote https://events.k8s.overtheedgepaper.ca; do
  printf '%-46s ' "$url"
  code=000
  for _ in $(seq 1 12); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url/" || echo 000)"
    [[ "$code" == "200" ]] && break
    sleep 5
  done
  echo "HTTP $code"
done
