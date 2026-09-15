#!/usr/bin/env bash
set -Eeuo pipefail
# Builds the EventScrape admin SPA and scraper worker on the K3s NODE (amd64)
# and imports them into k3s containerd. No registry involved.
#
# The admin image bakes VITE_CONVEX_URL at BUILD time. It must equal the URL the
# BROWSER uses to reach Convex, because the SPA calls Convex directly. Change
# the public hostname and you must rebuild the admin image.
repo_root="${ES_REPO_ROOT:-$HOME/github/EventScrape}"
server_host="${ES_K8S_HOST:-ubuntu@10.70.20.50}"
server_root="${ES_K8S_ROOT:-/srv/eventscrape-local-build}"
key="${ES_K8S_SSH_KEY:-$HOME/.ssh/personalprox_pve_ed25519}"
convex_url="${ES_CONVEX_PUBLIC_URL:-https://convex-events.k8s.overtheedgepaper.ca}"

[[ -d "$repo_root/.git" ]] || { echo "EventScrape repo not found at $repo_root (set ES_REPO_ROOT)" >&2; exit 1; }

ssh_args=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -i "$key" -o IdentitiesOnly=yes)
remote() { ssh "${ssh_args[@]}" "$server_host" "$@"; }

full_sha="$(git -C "$repo_root" rev-parse HEAD)"
short_sha="${full_sha:0:7}"
dirty=""; [[ -n "$(git -C "$repo_root" status --porcelain)" ]] && dirty="-dirty"
tag="dev-$(date +%s)-$short_sha$dirty"
echo "IMAGE_TAG=$tag"
echo "VITE_CONVEX_URL=$convex_url"

echo "=== [1/4] sync source ==="
remote "sudo -n install -d -o \$(id -u) -g \$(id -g) '$server_root/source'"
transport="ssh"; for i in "${ssh_args[@]}"; do transport+=" $(printf '%q' "$i")"; done
rsync -a --delete \
  --exclude='.git' --exclude='.DS_Store' --exclude='node_modules' \
  --exclude='dist' --exclude='.env' --exclude='.env.*' --exclude='*.zip' \
  -e "$transport" "$repo_root/" "$server_host:$server_root/source/"

echo "=== [2/4] build admin (VITE_CONVEX_URL baked in) ==="
remote "cd '$server_root/source' && sudo -n docker build \
  --build-arg VITE_CONVEX_URL='$convex_url' \
  -f apps/admin/Dockerfile -t 'docker.io/eventscrape-local/admin:$tag' ."

echo "=== [3/4] build worker ==="
remote "cd '$server_root/source' && sudo -n docker build \
  -f worker/Dockerfile -t 'docker.io/eventscrape-local/worker:$tag' ."

echo "=== [4/4] import into containerd + pin against image GC ==="
remote "sudo -n docker save 'docker.io/eventscrape-local/admin:$tag' 'docker.io/eventscrape-local/worker:$tag' | sudo -n k3s ctr -n k8s.io images import -"
for c in admin worker; do
  remote "sudo -n k3s ctr -n k8s.io images label 'docker.io/eventscrape-local/$c:$tag' io.cri-containerd.pinned=pinned >/dev/null"
  remote "sudo -n k3s ctr -n k8s.io images list -q | grep -Fx 'docker.io/eventscrape-local/$c:$tag'"
done
echo "BUILD COMPLETE: $tag"
