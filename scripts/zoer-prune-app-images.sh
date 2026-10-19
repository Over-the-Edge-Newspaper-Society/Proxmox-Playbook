#!/usr/bin/env bash
set -Eeuo pipefail
# Remove old Zoer backend/frontend images from Docker and k3s containerd,
# whatever their tag: dev-* deploys and hand-named builds (theme-capture-*,
# public-probe-*, ...) alike. Named builds were never pruned before and piled
# up at ~2 GB compressed (plus unpacked layers) each, in both stores.
#
#   ./scripts/zoer-prune-app-images.sh                 # dry run (default)
#   ./scripts/zoer-prune-app-images.sh --apply         # actually remove them
#   ./scripts/zoer-prune-app-images.sh --keep 1        # newest extras kept per component (default 2)
#
# Always kept, per component:
#   - the image each Deployment runs and its zoer.previous-image annotation
#     (what zoer-deploy.sh --rollback restores),
#   - anything a pod in any namespace is running,
#   - images created in the last ZOER_PRUNE_FRESH_HOURS (a build may be in flight),
#   - the --keep newest of the rest, by creation time (tag names do not sort).
#
# Run zoer-prune-runtimes.sh afterwards: browser/agent runtime images that only
# removed backend images referenced become stale and can then be reclaimed.

SERVER_HOST="${ZOER_K8S_DEV_HOST:-ubuntu@10.70.20.50}"
SSH_KEY="${ZOER_K8S_DEV_SSH_KEY:-$HOME/.ssh/personalprox_pve_ed25519}"
NS="${ZOER_NAMESPACE:-zoer}"
FRESH_HOURS="${ZOER_PRUNE_FRESH_HOURS:-3}"
KEEP=2
APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --keep) KEEP="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$KEEP" =~ ^[0-9]+$ ]] || { echo "--keep must be a number" >&2; exit 2; }

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/ote-k3s.yaml}"
ssh_args=(-o BatchMode=yes -o ConnectTimeout=15 -i "$SSH_KEY" -o IdentitiesOnly=yes)
remote() { ssh "${ssh_args[@]}" "$SERVER_HOST" "$@" </dev/null; }
norm() { sed -e 's#^docker\.io/##' -e 's#^library/##' -e '/^$/d'; }

protected="$(mktemp)"; present="$(mktemp)"; doomed="$(mktemp)"
cleanup() { rm -f "$protected" "$present" "$doomed"; }
trap cleanup EXIT

# What runs now, and what --rollback would restore.
kubectl get deploy -A -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{.metadata.annotations.zoer\.previous-image}{"\n"}{end}' 2>/dev/null \
  | grep 'zoer-local/' | norm >> "$protected" || true
kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
  | grep 'zoer-local/' | norm >> "$protected" || true
[[ -s "$protected" ]] || { echo "Could not read the cluster's images; refusing to prune." >&2; exit 1; }
sort -u "$protected" -o "$protected"

# "<epoch> <store> <ref>" for every backend/frontend image in either store.
remote 'for ref in $(sudo -n k3s ctr -n k8s.io images list -q | grep -E "zoer-local/(backend|frontend):"); do
          created=$(sudo -n k3s crictl inspecti -o json "$ref" 2>/dev/null | jq -r ".info.imageSpec.created // empty")
          [ -n "$created" ] && echo "$(date -u -d "$created" +%s) containerd $ref"
        done
        sudo -n docker images --format "{{.CreatedAt}}|{{.Repository}}:{{.Tag}}" 2>/dev/null \
          | grep -E "\|zoer-local/(backend|frontend):" | while IFS="|" read -r created ref; do
              echo "$(date -u -d "${created% UTC}" +%s) docker $ref"
            done' | awk '{ sub(/^docker\.io\//, "", $3); print }' > "$present"

now=$(date +%s)
fresh_after=$(( now - FRESH_HOURS * 3600 ))
for component in backend frontend; do
  echo "==> zoer-local/$component"
  # Newest creation time per tag across both stores, newest first.
  grep " zoer-local/$component:" "$present" | awk '{ if ($1 > t[$3]) t[$3] = $1 } END { for (r in t) print t[r], r }' \
    | sort -rn | {
      kept=0
      while read -r created ref; do
        if grep -qxF "$ref" "$protected"; then echo "     keep (in use / rollback) $ref"
        elif [[ "$created" -ge "$fresh_after" ]]; then echo "     keep (built < ${FRESH_HOURS}h ago) $ref"
        elif [[ "$kept" -lt "$KEEP" ]]; then kept=$((kept + 1)); echo "     keep (newest $kept/$KEEP) $ref"
        else echo "     REMOVE $ref"; echo "$ref" >> "$doomed"
        fi
      done
    }
done

if [[ ! -s "$doomed" ]]; then echo "Nothing to remove."; exit 0; fi
if [[ "$APPLY" != "1" ]]; then
  echo; echo "Dry run. Re-run with --apply to remove $(wc -l < "$doomed" | tr -d ' ') image(s)."
  exit 0
fi

echo "==> removing"
commands=""
while read -r ref; do
  commands+="sudo -n docker rmi '$ref' >/dev/null 2>&1 || true
sudo -n k3s ctr -n k8s.io images label 'docker.io/$ref' io.cri-containerd.pinned= >/dev/null 2>&1 || true
sudo -n k3s ctr -n k8s.io images rm 'docker.io/$ref' >/dev/null 2>&1 || true
echo '     removed $ref'
"
done < "$doomed"
remote "$commands"
remote "df -h / | tail -1" | sed 's/^/node disk: /'
