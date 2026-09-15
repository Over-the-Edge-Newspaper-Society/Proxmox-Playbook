#!/usr/bin/env bash
set -Eeuo pipefail
# Remove stale zoer-local browser-runtime / agent-runtime images.
#
#   ./scripts/zoer-prune-runtimes.sh            # dry run (default)
#   ./scripts/zoer-prune-runtimes.sh --apply    # actually remove them
#
# Why these need their own prune: the runtime images are tagged by CONTENT HASH
# and referenced by the BACKEND, not by any Deployment. Nothing runs them until
# the backend starts a browser or an agent, so "what is running" and kubelet's
# image GC are both wrong signals - GC already collected agent-runtime once.
#
# The reference is recoverable exactly. backend/Dockerfile bakes its build args
# into the image as ENV:
#     ZOER_BROWSER_RUNTIME_IMAGE -> BROWSER_RUNTIME_IMAGE
#     ZOER_AGENT_RUNTIME_IMAGE   -> AGENT_RUNNER_IMAGE
# so every backend image declares the runtimes it needs.
#
# CONTAINERD IS THE SOURCE OF TRUTH, not Docker. The deploy script prunes old
# backend images from Docker while containerd keeps them for --rollback; reading
# Docker alone under-protects and will happily delete a rollback dependency.
# containerd image config is read with `k3s crictl inspecti`.

SERVER_HOST="${ZOER_K8S_DEV_HOST:-ubuntu@10.70.20.50}"
SSH_KEY="${ZOER_K8S_DEV_SSH_KEY:-$HOME/.ssh/personalprox_pve_ed25519}"
NS="${ZOER_NAMESPACE:-zoer}"
FRESH_HOURS="${ZOER_PRUNE_FRESH_HOURS:-3}"
APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

export KUBECONFIG="${KUBECONFIG:-$HOME/github/personalprox/kubeconfig.yml}"
ssh_args=(-o BatchMode=yes -o ConnectTimeout=15 -i "$SSH_KEY" -o IdentitiesOnly=yes)
remote() { ssh "${ssh_args[@]}" "$SERVER_HOST" "$@"; }
norm() { sed -e 's#^docker\.io/##' -e 's#^library/##' -e '/^$/d'; }

protected="$(mktemp)"; present="$(mktemp)"; fresh="$(mktemp)"
cleanup() { rm -f "$protected" "$present" "$fresh"; }
trap cleanup EXIT

echo "==> reading backend images from containerd (authoritative) and Docker"
# Every backend image in either store declares its runtime refs. Taking the
# union across all of them is what keeps --rollback safe.
remote 'for i in $(sudo -n k3s ctr -n k8s.io images list -q | grep "zoer-local/backend:"); do
          sudo -n k3s crictl inspecti "$i" 2>/dev/null \
            | grep -oE "(BROWSER_RUNTIME_IMAGE|AGENT_RUNNER_IMAGE|ZOER_DEV_BROWSER_RUNTIME_IMAGE)=[^\"]+"
        done
        for i in $(sudo -n docker images --format "{{.Repository}}:{{.Tag}}" | grep "^zoer-local/backend:" || true); do
          sudo -n docker inspect "$i" --format "{{range .Config.Env}}{{println .}}{{end}}" 2>/dev/null \
            | grep -E "^(BROWSER_RUNTIME_IMAGE|AGENT_RUNNER_IMAGE|ZOER_DEV_BROWSER_RUNTIME_IMAGE)="
        done' 2>/dev/null | cut -d= -f2- | norm >> "$protected"

# The live backend, and anything a pod is running right now.
kubectl -n "$NS" exec deploy/zoer-backend -- sh -c \
  'echo "$BROWSER_RUNTIME_IMAGE"; echo "$AGENT_RUNNER_IMAGE"' 2>/dev/null | norm >> "$protected" || true
kubectl -n "$NS" get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
  | grep 'zoer-local/' | norm >> "$protected" || true
sort -u "$protected" -o "$protected"
echo "   protected by a backend/pod reference:"; sed 's/^/     /' "$protected"

echo "==> runtime images present (containerd ∪ Docker)"
remote 'sudo -n k3s ctr -n k8s.io images list -q | grep -E "zoer-local/(browser-runtime|agent-runtime):" || true
        sudo -n docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "^zoer-local/(browser-runtime|agent-runtime):" || true' 2>/dev/null \
  | norm | sort -u > "$present"
sed 's/^/     /' "$present"

# A runtime built minutes ago has no backend referencing it yet - its backend is
# still building. Freshness is computed locally from docker inspect's RFC3339
# .Created; parsing Docker's human CreatedAt with `date -d` on the node fails
# silently and marks fresh images stale.
remote 'for i in $(sudo -n docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "^zoer-local/(browser-runtime|agent-runtime):" || true); do
          printf "%s|%s\n" "$i" "$(sudo -n docker inspect -f "{{.Created}}" "$i" 2>/dev/null)"; done' 2>/dev/null \
| FRESH_HOURS="$FRESH_HOURS" python3 -c '
import sys,os,datetime
lim=float(os.environ.get("FRESH_HOURS","3"))*3600
now=datetime.datetime.now(datetime.timezone.utc)
for line in sys.stdin:
    line=line.strip()
    if "|" not in line: continue
    img,created=line.split("|",1)
    try: t=datetime.datetime.fromisoformat(created.strip().replace("Z","+00:00"))
    except Exception: continue
    if (now-t).total_seconds() < lim: print(img.replace("docker.io/","",1))
' | sort -u > "$fresh"
if [[ -s "$fresh" ]]; then
  echo "==> also protecting images built in the last ${FRESH_HOURS}h (a build may be in flight):"
  sed 's/^/     /' "$fresh"
  cat "$fresh" >> "$protected"; sort -u "$protected" -o "$protected"
fi

stale="$(comm -23 "$present" "$protected" || true)"
if [[ -z "$stale" ]]; then
  echo "==> nothing stale; every runtime image is still referenced."
  exit 0
fi

echo "==> STALE - referenced by no backend image and no running pod:"
echo "$stale" | sed 's/^/     /'

if [[ "$APPLY" != "1" ]]; then
  echo; echo "Dry run. Re-run with --apply to remove them."
  exit 0
fi

echo "==> removing"
while read -r img; do
  [[ -n "$img" ]] || continue
  remote "sudo -n docker rmi -f '$img' >/dev/null 2>&1 || true"
  # The pin must be cleared before containerd will drop it.
  remote "sudo -n k3s ctr -n k8s.io images label 'docker.io/$img' io.cri-containerd.pinned= >/dev/null 2>&1 || true"
  remote "sudo -n k3s ctr -n k8s.io images rm 'docker.io/$img' >/dev/null 2>&1 || true"
  echo "     removed $img"
done <<< "$stale"
remote "df -h / | tail -1" | sed 's/^/node disk: /'
