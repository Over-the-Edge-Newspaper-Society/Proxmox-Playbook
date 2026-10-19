#!/usr/bin/env bash
# Import the exact native runtime on the opted-in browser node before rollout.
set -Eeuo pipefail
image="${1:?Pass the exact browser-runtime image tag}"
[[ "$image" =~ ^docker.io/zoer-local/browser-runtime:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || exit 2
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/ote-k3s.yaml}"
node="${PLAYWRIGHT_WORKER_NODE:-$(kubectl -n "${ZOER_NAMESPACE:-zoer}" get deployment zoer-backend -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PLAYWRIGHT_WORKER_NODE")].value}' 2>/dev/null || true)}"
[[ -n "$node" ]] || { echo 'No dedicated browser node configured; runtime remains on the application node.'; exit 0; }
[[ "$node" == zoer-browser-worker-1 ]] || { echo 'Review access for the configured browser node before importing.'; exit 1; }
host="${ZOER_PROXMOX_HOST:-root@10.70.20.10}"
server="${ZOER_K8S_DEV_HOST:-ubuntu@10.70.20.50}"
key="${ZOER_K8S_DEV_SSH_KEY:-$HOME/.ssh/personalprox_pve_ed25519}"
vmid="${ZOER_BROWSER_VMID:-211}"
[[ "$vmid" =~ ^[0-9]+$ ]] || exit 2
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
ssh_args=(-o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 -i "$key")
ip="$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
ssh "${ssh_args[@]}" "$host" "qm agent $vmid network-get-interfaces" > "$work/interfaces.json"
ssh "${ssh_args[@]}" "$host" "qm guest exec $vmid -- cat /etc/ssh/ssh_host_ed25519_key.pub" > "$work/key.json"
python3 - "$work" "$ip" <<'PY'
import json,ipaddress,sys
from pathlib import Path
p=Path(sys.argv[1]); ip=str(ipaddress.ip_address(sys.argv[2])); assert ipaddress.ip_address(ip).is_private
interfaces=json.loads((p/'interfaces.json').read_text())
assert any(a.get('ip-address')==ip for i in interfaces for a in i.get('ip-addresses',[])), 'Node address does not belong to the browser VM'
key=json.loads((p/'key.json').read_text()); assert key['exitcode']==0 and key['out-data'].startswith('ssh-ed25519 ')
(p/'known_hosts').write_text(ip+' '+key['out-data'].strip()+'\n')
PY
worker_args=("${ssh_args[@]}" -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$work/known_hosts")
if ! ssh "${worker_args[@]}" "ubuntu@$ip" 'sudo k3s ctr images ls -q' | grep -Fx "$image" >/dev/null; then
  read -r available capacity < <(ssh "${worker_args[@]}" "ubuntu@$ip" "df -Pk / | awk 'NR==2 {print \$4,\$2}'")
  size="$(ssh "${ssh_args[@]}" "$server" "sudo docker image inspect '$image' --format '{{.Size}}'")"
  [[ "$size" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ && "$capacity" =~ ^[0-9]+$ ]] || exit 1
  (( available > capacity / 10 + 2 * size / 1024 + 1048576 )) || { echo 'Insufficient browser-node disk reserve; preserve profiles and referenced images.'; exit 1; }
  ssh "${ssh_args[@]}" "$server" "sudo docker save '$image' | gzip -1" |
    ssh "${worker_args[@]}" "ubuntu@$ip" 'gzip -d | sudo k3s ctr images import --no-unpack -'
fi
ssh "${worker_args[@]}" "ubuntu@$ip" "sudo k3s ctr images label '$image' io.cri-containerd.pinned=pinned >/dev/null"
echo "Browser node $node has pinned runtime $image"
