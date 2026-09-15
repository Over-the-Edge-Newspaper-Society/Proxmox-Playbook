#!/usr/bin/env bash
set -Eeuo pipefail
# Builds the OTEManager image on the K3s NODE (amd64) and imports it directly
# into k3s containerd. Nothing is pushed to or pulled from a registry.
#
# Same reasoning as the Zoer build: the cluster is amd64, Apple Silicon is
# arm64, and cross-building under QEMU is slow and fragile.
#
# Prerequisite: Docker on the node as a build engine (see docs/ZOER-LOCAL.md,
# "One-time setup"). Override any value with an environment variable.
repo_root="${OTE_REPO_ROOT:-$HOME/github/OTEManager}"
server_host="${OTE_K8S_HOST:-ubuntu@10.70.20.50}"
server_root="${OTE_K8S_ROOT:-/srv/otemanager-local-build}"
key="${OTE_K8S_SSH_KEY:-$HOME/.ssh/personalprox_pve_ed25519}"

[[ -d "$repo_root/.git" ]] || { echo "OTEManager repo not found at $repo_root (set OTE_REPO_ROOT)" >&2; exit 1; }
[[ -f "$repo_root/Dockerfile" ]] || { echo "No Dockerfile at $repo_root" >&2; exit 1; }

ssh_args=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -i "$key" -o IdentitiesOnly=yes)
remote() { ssh "${ssh_args[@]}" "$server_host" "$@"; }

full_sha="$(git -C "$repo_root" rev-parse HEAD)"
short_sha="${full_sha:0:7}"
dirty_suffix=""
[[ -n "$(git -C "$repo_root" status --porcelain)" ]] && dirty_suffix="-dirty"
image_tag="dev-$(date +%s)-$short_sha$dirty_suffix"
image="docker.io/otemanager-local/app:$image_tag"
echo "IMAGE_TAG=$image_tag"

echo "=== [1/3] sync source ==="
remote "sudo -n install -d -o \$(id -u) -g \$(id -g) '$server_root/source'"
ssh_transport="ssh"; for i in "${ssh_args[@]}"; do ssh_transport+=" $(printf '%q' "$i")"; done
rsync -a --delete \
  --exclude='.git' --exclude='.DS_Store' --exclude='node_modules' \
  --exclude='.output' --exclude='.convex' --exclude='.tanstack' \
  --exclude='artifacts' --exclude='*.zip' --exclude='.env' --exclude='.env.*' \
  -e "$ssh_transport" "$repo_root/" "$server_host:$server_root/source/"

echo "=== [2/3] build ==="
remote "cd '$server_root/source' && sudo -n docker build -t '$image' ."

echo "=== [3/3] import into k3s containerd + pin ==="
remote "sudo -n docker save '$image' | sudo -n k3s ctr -n k8s.io images import -"
# Pin so kubelet's image GC cannot collect it under disk pressure.
remote "sudo -n k3s ctr -n k8s.io images label '$image' io.cri-containerd.pinned=pinned >/dev/null"
remote "sudo -n k3s ctr -n k8s.io images list -q | grep -Fx '$image'"
echo "BUILD COMPLETE: $image_tag"
