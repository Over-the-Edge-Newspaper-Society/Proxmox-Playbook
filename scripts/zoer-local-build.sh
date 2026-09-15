#!/usr/bin/env bash
set -Eeuo pipefail
# Builds the Zoer backend/frontend on the K3s NODE (amd64) and imports them
# straight into k3s containerd. Nothing is pushed to or pulled from a registry.
#
# Why on the node and not on your laptop: the cluster is amd64 and Apple Silicon
# is arm64. Cross-building under QEMU is slow and the Chromium/Playwright layers
# are exactly the ones that tend to break under emulation.
#
# Prerequisite: Docker installed on the node as a build engine (k3s keeps using
# containerd). Run once:
#   ZOER_K8S_DEV_HOST=ubuntu@10.70.20.50 \
#   ZOER_K8S_DEV_SSH_KEY=~/.ssh/personalprox_pve_ed25519 \
#   ~/github/zoer/scripts/k8s-server-dev.sh bootstrap
#
# Override any of these with environment variables.
repo_root="${ZOER_REPO_ROOT:-$HOME/github/zoer}"
server_host="${ZOER_K8S_DEV_HOST:-ubuntu@10.70.20.50}"
server_root="${ZOER_K8S_DEV_ROOT:-/srv/zoer-local-build}"
key="${ZOER_K8S_DEV_SSH_KEY:-$HOME/.ssh/personalprox_pve_ed25519}"

# Cap what a build container may consume. The frontend Vite build alone took
# 6.1 GB on a node that also runs the cluster; unbounded, it drove the node to
# 148 MB free with no swap, load 61, and took every app AND the API server down
# until the VM had to be hard-restarted. Capping trades a slower build for a
# cluster that stays up.
BUILD_MEM="${ZOER_BUILD_MEM:-6g}"

if [[ ! -d "$repo_root/.git" ]]; then
  echo "Zoer repo not found at $repo_root (set ZOER_REPO_ROOT)" >&2; exit 1
fi
if [[ ! -d "$repo_root/themes/resume/ahmadstyle" || ! -f "$repo_root/vendor/rendercv-toolkit/package.json" ]]; then
  echo "Submodules missing. Run: git -C '$repo_root' submodule update --init --recursive" >&2; exit 1
fi
ssh_args=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -i "$key" -o IdentitiesOnly=yes)
remote() { ssh "${ssh_args[@]}" "$server_host" "$@"; }

full_sha="$(git -C "$repo_root" rev-parse HEAD)"
short_sha="${full_sha:0:7}"
git_dirty=false; dirty_suffix=""
if [[ -n "$(git -C "$repo_root" status --porcelain)" ]]; then dirty_suffix="-dirty"; git_dirty=true; fi
image_tag="dev-$(date +%s)-$short_sha$dirty_suffix"
echo "IMAGE_TAG=$image_tag"
echo "$image_tag" > "${TMPDIR:-/tmp}/zoer-image-tag.txt"
echo "(tag also written to ${TMPDIR:-/tmp}/zoer-image-tag.txt)"

echo "=== [1/6] sync source ==="
remote "sudo -n install -d -o \$(id -u) -g \$(id -g) '$server_root/source' && sudo -n chown -R \$(id -u):\$(id -g) '$server_root/source'"
ssh_transport="ssh"; for i in "${ssh_args[@]}"; do ssh_transport+=" $(printf '%q' "$i")"; done
rsync -a --delete \
  --exclude='.git' --exclude='.DS_Store' --exclude='.env' --exclude='.env.*' \
  --exclude='node_modules' --exclude='dist' --exclude='.zoer-data' --exclude='.expect' \
  --exclude='.playwright-mcp' --exclude='tmp-root*.png' \
  --exclude='output' --exclude='artifacts' \
  -e "$ssh_transport" "$repo_root/" "$server_host:$server_root/source/"
echo "sync done"

echo "=== [2/6] browser-runtime ==="
runtime_hash="$(remote "cd '$server_root/source' && cat browser-runtime/Dockerfile browser-runtime/requirements.txt browser-runtime/runtime.py browser-runtime/automation.py browser-runtime/input-check.html browser-runtime/install_clearcote.py browser-runtime/clearcote-pin.json browser-runtime/install_update.py | sha256sum | cut -c1-16")"
runtime_image="docker.io/zoer-local/browser-runtime:$runtime_hash"
remote "cd '$server_root/source' && sudo -n docker build --memory=$BUILD_MEM --memory-swap=$BUILD_MEM -t '$runtime_image' browser-runtime && sudo -n docker save '$runtime_image' | sudo -n k3s ctr -n k8s.io images import -"
remote "sudo -n k3s ctr -n k8s.io images label '$runtime_image' io.cri-containerd.pinned=pinned >/dev/null"
echo "runtime_image=$runtime_image"

echo "=== [3/6] agent-runtime ==="
agent_hash="$(cat "$repo_root/agent-runtime/Dockerfile" "$repo_root/backend/src/agent-runners/worker.ts" | shasum -a 256 | cut -c1-16)"
agent_image="docker.io/zoer-local/agent-runtime:$agent_hash"
remote "sudo -n docker image inspect '$agent_image' >/dev/null 2>&1" || \
  remote "cd '$server_root/source' && sudo -n docker build --memory=$BUILD_MEM --memory-swap=$BUILD_MEM -f agent-runtime/Dockerfile -t '$agent_image' ."
remote "sudo -n docker save '$agent_image' | sudo -n k3s ctr -n k8s.io images import -"
echo "agent_image=$agent_image"

echo "=== [4/6] backend ==="
remote "cd '$server_root/source' && sudo -n docker build --memory=$BUILD_MEM --memory-swap=$BUILD_MEM --build-arg 'ZOER_BROWSER_RUNTIME_IMAGE=$runtime_image' --build-arg 'ZOER_AGENT_RUNTIME_IMAGE=$agent_image' --build-arg 'ZOER_GIT_COMMIT=$full_sha' --build-arg 'ZOER_GIT_DIRTY=$git_dirty' -f backend/Dockerfile -t 'docker.io/zoer-local/backend:$image_tag' ."

echo "=== [5/6] frontend ==="
remote "cd '$server_root/source' && sudo -n docker build --memory=$BUILD_MEM --memory-swap=$BUILD_MEM --build-arg 'ZOER_GIT_COMMIT=$full_sha' --build-arg 'ZOER_GIT_DIRTY=$git_dirty' -f frontend/Dockerfile -t 'docker.io/zoer-local/frontend:$image_tag' ."

echo "=== [6/6] import into k3s containerd ==="
remote "sudo -n docker save 'docker.io/zoer-local/backend:$image_tag' 'docker.io/zoer-local/frontend:$image_tag' | sudo -n k3s ctr -n k8s.io images import -"
remote "sudo -n k3s ctr -n k8s.io images list -q | grep -Fx 'docker.io/zoer-local/backend:$image_tag'"
remote "sudo -n k3s ctr -n k8s.io images list -q | grep -Fx 'docker.io/zoer-local/frontend:$image_tag'"

# Pin EVERY locally built image. Only browser-runtime was pinned before, and
# kubelet's image GC collected agent-runtime at 88% disk because no running pod
# referenced it - the backend only pulls it when it starts an agent.
for img in "$runtime_image" "$agent_image" \
           "docker.io/zoer-local/backend:$image_tag" \
           "docker.io/zoer-local/frontend:$image_tag"; do
  remote "sudo -n k3s ctr -n k8s.io images label '$img' io.cri-containerd.pinned=pinned >/dev/null" || true
done
echo "BUILD COMPLETE: $image_tag"
