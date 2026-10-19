#!/usr/bin/env bash
# Join only the browser VM created by zoer-browser-worker-create.sh.
# The Proxmox guest agent supplies the address and SSH public host key.
set -Eeuo pipefail
vmid="${ZOER_BROWSER_VMID:-211}"
host="${ZOER_PROXMOX_HOST:-root@10.70.20.10}"
server="${ZOER_K3S_HOST:-ubuntu@10.70.20.50}"
key="${ZOER_SSH_KEY:-$HOME/.ssh/personalprox_pve_ed25519}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/ote-k3s.yaml}"
[[ "$vmid" =~ ^[0-9]+$ ]] || exit 2
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ssh_args=(-o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 -i "$key")
ssh "${ssh_args[@]}" "$host" "qm config $vmid" | grep -qx 'name: zoer-browser-worker-1'
ssh "${ssh_args[@]}" "$host" "qm agent $vmid network-get-interfaces" > "$work/interfaces.json"
ssh "${ssh_args[@]}" "$host" "qm guest exec $vmid -- cat /etc/ssh/ssh_host_ed25519_key.pub" > "$work/host-key.json"
python3 - "$work" <<'PY'
import ipaddress,json,sys
from pathlib import Path
p=Path(sys.argv[1]); interfaces=json.loads((p/'interfaces.json').read_text())
addresses=[a['ip-address'] for i in interfaces for a in i.get('ip-addresses',[])
           if a.get('ip-address-type')=='ipv4' and ipaddress.ip_address(a['ip-address']) in ipaddress.ip_network('10.70.20.0/24')]
assert len(addresses)==1,'Expected one private browser-worker address'
address=ipaddress.ip_address(addresses[0]); assert address.is_private
key=json.loads((p/'host-key.json').read_text()); assert key['exitcode']==0
public=key['out-data'].strip(); assert public.startswith('ssh-ed25519 ')
(p/'address').write_text(str(address)); (p/'known_hosts').write_text(str(address)+' '+public+'\n')
config={'server':'https://10.70.20.50:6443','token-file':'/etc/rancher/k3s/agent-token',
        'node-name':'zoer-browser-worker-1','node-label':['zoer.io/browser-worker=true'],
        'node-taint':['zoer.io/browser-worker=true:NoSchedule'],
        'kubelet-arg':['system-reserved=memory=256Mi','kube-reserved=memory=256Mi','max-pods=20']}
(p/'config.yaml').write_text(json.dumps(config,indent=2)+'\n')
PY
ip="$(cat "$work/address")"
worker_args=("${ssh_args[@]}" -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$work/known_hosts")
if ssh "${worker_args[@]}" "ubuntu@$ip" 'systemctl is-active --quiet k3s-agent'; then
  echo 'Existing K3s agent preserved.'
else
  curl -fsSL --proto '=https' https://get.k3s.io -o "$work/install-k3s.sh"
  ssh "${worker_args[@]}" "ubuntu@$ip" 'sudo install -d -m 700 /etc/rancher/k3s; sudo swapoff -a; sudo modprobe br_netfilter; sudo modprobe overlay; printf "net.ipv4.ip_forward=1\nnet.bridge.bridge-nf-call-iptables=1\nfs.inotify.max_user_instances=1024\nfs.inotify.max_user_watches=524288\n" | sudo tee /etc/sysctl.d/99-zoer-browser.conf >/dev/null; sudo sysctl -p /etc/sysctl.d/99-zoer-browser.conf >/dev/null'
  ssh "${ssh_args[@]}" "$server" 'sudo cat /var/lib/rancher/k3s/server/agent-token' |
    ssh "${worker_args[@]}" "ubuntu@$ip" 'sudo sh -c "umask 077; cat > /etc/rancher/k3s/agent-token"'
  scp "${worker_args[@]}" "$work/config.yaml" "$work/install-k3s.sh" "ubuntu@$ip:/tmp/"
  ssh "${worker_args[@]}" "ubuntu@$ip" 'sudo install -m 600 /tmp/config.yaml /etc/rancher/k3s/config.yaml; sudo env INSTALL_K3S_VERSION=v1.31.4+k3s1 INSTALL_K3S_EXEC=agent sh /tmp/install-k3s.sh'
fi
# local-path's short-lived storage helper also needs the browser-node toleration.
kubectl -n kube-system get configmap local-path-config -o json > "$work/local-path.json"
python3 - "$work" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads((p/'local-path.json').read_text()); helper=d['data']['helperPod.yaml']
if 'zoer.io/browser-worker' not in helper:
    assert 'tolerations:' not in helper,'Review existing storage helper tolerations before adding browser placement'
    helper=helper.replace('spec:\n','spec:\n  tolerations:\n  - key: zoer.io/browser-worker\n    operator: Equal\n    value: "true"\n    effect: NoSchedule\n',1)
(p/'patch.json').write_text(json.dumps({'data':{'helperPod.yaml':helper}}))
PY
kubectl -n kube-system patch configmap local-path-config --type merge --patch-file "$work/patch.json"
kubectl wait --for=condition=Ready node/zoer-browser-worker-1 --timeout=120s
