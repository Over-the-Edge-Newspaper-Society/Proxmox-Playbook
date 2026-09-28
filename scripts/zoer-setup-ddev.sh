#!/usr/bin/env bash
# Idempotent DDEV setup. Defaults on for new installs; thereafter remembers the
# saved choice. Opt out with --disable or ZOER_DDEV_ENABLED=0.
set -Eeuo pipefail
set +x
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${ZOER_NAMESPACE:-zoer}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/ote-k3s.yaml}"
server_host="${ZOER_K8S_DEV_HOST:-ubuntu@10.70.20.50}"
key="${ZOER_K8S_DEV_SSH_KEY:-$HOME/.ssh/personalprox_pve_ed25519}"
bind_ip="${ZOER_DDEV_BIND_IP:-10.70.20.50}"
pod_cidr="${ZOER_DDEV_POD_CIDR:-10.42.0.0/16}"
repo="${ZOER_REPO_ROOT:-$HOME/github/zoer}"
mode="${ZOER_DDEV_ENABLED:-}"
case "${1:-}" in --enable) mode=1;; --disable) mode=0;; '') ;; *) echo 'Usage: zoer-setup-ddev.sh [--enable|--disable]' >&2; exit 2;; esac
[[ $# -le 1 ]] || exit 2
if [[ -z "$mode" ]]; then mode="$(kubectl -n "$NS" get configmap zoer-ddev-config --ignore-not-found -o jsonpath='{.data.DDEV_ENABLED}')"; fi
mode="${mode:-1}"
[[ "$mode" == 0 || "$mode" == 1 ]] || { echo 'ZOER_DDEV_ENABLED must be 0 or 1.' >&2; exit 2; }
[[ "$NS" =~ ^[a-z0-9][a-z0-9-]*$ ]] || exit 2
ssh_args=(-o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes -i "$key")
remote() { ssh "${ssh_args[@]}" "$server_host" "$@"; }
local_dir="$(mktemp -d)"
remote_dir=''
cleanup() { rm -rf "$local_dir"; if [[ "$remote_dir" == /tmp/zoer-ddev-setup.* ]]; then remote "rm -rf '$remote_dir'" >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT
remote_dir="$(remote 'mktemp -d /tmp/zoer-ddev-setup.XXXXXXXX')"
[[ "$remote_dir" =~ ^/tmp/zoer-ddev-setup\.[A-Za-z0-9]+$ ]] || exit 2
ssh_transport=ssh; for arg in "${ssh_args[@]}"; do ssh_transport+=" $(printf '%q' "$arg")"; done
rsync -a -e "$ssh_transport" "$HERE/zoer-ddev-host.sh" "$server_host:$remote_dir/"
: > "$local_dir/seed"
if [[ "$mode" == 1 ]]; then
  [[ -f "$repo/ddev-bridge/src/index.ts" ]] || { echo 'Zoer bridge source not found.' >&2; exit 1; }
  rsync -a --exclude=node_modules --exclude='.env*' -e "$ssh_transport" "$repo/ddev-bridge/" "$server_host:$remote_dir/bridge/"
  kubectl -n "$NS" get secret zoer-ddev-bridge --ignore-not-found -o json > "$local_dir/secret.json"
  python3 - "$local_dir" <<'PY'
import base64,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); data=root.joinpath('secret.json').read_text()
value=json.loads(data).get('data',{}).get('DDEV_BRIDGE_TOKEN','') if data.strip() else ''
root.joinpath('seed').write_bytes(base64.b64decode(value,validate=True))
PY
fi
operation=disable; [[ "$mode" == 0 ]] || operation=enable
printf -v command '%q ' sudo -n bash "$remote_dir/zoer-ddev-host.sh" "$operation" "$bind_ip" "$pod_cidr" "$remote_dir/bridge" "${ZOER_DDEV_BUN_VERSION:-1.3.14}"
remote "$command" < "$local_dir/seed"
url=''
if [[ "$mode" == 1 ]]; then
  url="http://$bind_ip:4085"
  remote "sudo -n sed -n 's/^DDEV_BRIDGE_TOKEN=/DDEV_BRIDGE_TOKEN=/p' /etc/zoer/ddev-bridge.env" > "$local_dir/bridge.env"
  # Verify reachability from the real backend before advertising availability.
  if kubectl -n "$NS" get deployment zoer-backend --ignore-not-found -o name | grep -q .; then
    kubectl -n "$NS" exec -i deployment/zoer-backend -- bun -e 'const input=await Bun.stdin.text(); const token=input.trim().replace(/^DDEV_BRIDGE_TOKEN=/,""); const r=await fetch(process.argv[1]+"/health",{headers:{authorization:"Bearer "+token},signal:AbortSignal.timeout(15000)}); if(!r.ok || !(await r.json()).ok)process.exit(1); console.log("Backend can reach the authenticated DDEV bridge.");' "$url" < "$local_dir/bridge.env"
  fi
  kubectl -n "$NS" create secret generic zoer-ddev-bridge --from-env-file="$local_dir/bridge.env" --dry-run=client -o yaml | kubectl apply --server-side --field-manager=zoer-ddev-setup -f - >/dev/null
fi
before="$(kubectl -n "$NS" get configmap zoer-ddev-config --ignore-not-found -o jsonpath='{.data.DDEV_ENABLED}:{.data.DDEV_BRIDGE_URL}')"
kubectl -n "$NS" create configmap zoer-ddev-config --from-literal=DDEV_ENABLED="$mode" --from-literal=DDEV_BRIDGE_URL="$url" --dry-run=client -o yaml | kubectl apply --server-side --field-manager=zoer-ddev-setup -f - >/dev/null
if [[ "${ZOER_DDEV_DEFER_ROLLOUT:-0}" != 1 && ( "$before" != "$mode:$url" || ( "$mode" == 1 && ! -s "$local_dir/seed" ) ) ]]; then
  if kubectl -n "$NS" get deployment zoer-backend --ignore-not-found -o name | grep -q .; then
    kubectl -n "$NS" rollout restart deployment/zoer-backend
    kubectl -n "$NS" rollout status deployment/zoer-backend --timeout=300s
  fi
fi
echo "DDEV setup saved: enabled=$mode."
