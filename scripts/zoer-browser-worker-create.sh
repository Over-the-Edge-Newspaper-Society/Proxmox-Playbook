#!/usr/bin/env bash
# Create the small browser-only VM. Joining Kubernetes is a separate operator step.
set -Eeuo pipefail
vmid="${ZOER_BROWSER_VMID:-211}"
host="${ZOER_PROXMOX_HOST:-root@10.70.20.10}"
key="${ZOER_SSH_KEY:-$HOME/.ssh/personalprox_pve_ed25519}"
[[ "$vmid" =~ ^[0-9]+$ ]] || exit 2
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 - "$key.pub" "$work/user-data.yaml" <<'PY'
import json,sys
from pathlib import Path
key=Path(sys.argv[1]).read_text().strip()
data={'hostname':'zoer-browser-worker-1','manage_etc_hosts':True,
      'ssh_pwauth':False,'disable_root':True,
      'users':[{'name':'ubuntu','groups':['adm','sudo'],'shell':'/bin/bash',
                'sudo':'ALL=(ALL) NOPASSWD:ALL','lock_passwd':True,'ssh_authorized_keys':[key]}],
      'package_update':True,'packages':['qemu-guest-agent','nfs-common','curl'],
      'runcmd':[['systemctl','enable','--now','qemu-guest-agent']]}
Path(sys.argv[2]).write_text('#cloud-config\n'+json.dumps(data,indent=2)+'\n')
PY
ssh_args=(-o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 -i "$key")
scp "${ssh_args[@]}" "$work/user-data.yaml" "$host:/tmp/zoer-browser-worker-$vmid.yaml"
ssh "${ssh_args[@]}" "$host" bash -s -- "$vmid" <<'SH'
set -Eeuo pipefail
vmid="$1"
if qm status "$vmid" >/dev/null 2>&1; then
  qm config "$vmid" | grep -qx 'name: zoer-browser-worker-1' || { echo 'VM ID belongs to another machine'; exit 1; }
  echo 'Browser VM exists; configuration and running state preserved.'
  exit 0
fi
available=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)
[[ "$available" -ge $((5 * 1024 * 1024)) ]] || { echo 'Need 5 GiB available before reserving 3 GiB.'; exit 1; }
mkdir -p /var/lib/vz/snippets
install -m 600 "/tmp/zoer-browser-worker-$vmid.yaml" "/var/lib/vz/snippets/zoer-browser-worker-$vmid.yaml"
qm clone 9000 "$vmid" --full 1 --name zoer-browser-worker-1 --storage local-lvm
qm set "$vmid" --memory 3072 --balloon 3072 --cores 2 --cpu host --onboot 1 \
  --ipconfig0 ip=dhcp --nameserver 10.70.20.1 \
  --cicustom "user=local:snippets/zoer-browser-worker-$vmid.yaml"
qm disk resize "$vmid" scsi0 32G
qm start "$vmid"
qm status "$vmid"
SH
