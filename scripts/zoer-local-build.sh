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
#
# `docker build --memory` does NOT cap anything: BuildKit (the default builder)
# ignores it, which is how the 2026-10-01 and 10-02 deploys still starved the
# node (175 MB free, ~22 and ~39 min of API outage). Builds therefore run in a
# dedicated docker-container buildx builder whose container has the memory
# limit; a build that needs more fails with "cannot allocate memory" instead of
# taking the node down. The builder is named after its limit and reused, so its
# layer cache survives between deploys (the first build on it is cold).
BUILD_MEM="${ZOER_BUILD_MEM:-6g}"
BUILDER="zoer-capped-${BUILD_MEM}"

if [[ ! -e "$repo_root/.git" ]]; then  # a file in git worktrees
  echo "Zoer repo not found at $repo_root (set ZOER_REPO_ROOT)" >&2; exit 1
fi
# Every submodule the checkout declares must be initialised (a leading "-" in `git submodule status`).
# The list is read from the repo, so dropping or adding a submodule in Zoer needs no change here.
if git -C "$repo_root" submodule status --recursive 2>/dev/null | grep -q '^-'; then
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

remote "sudo -n docker buildx inspect '$BUILDER' >/dev/null 2>&1 || sudo -n docker buildx create --name '$BUILDER' --driver docker-container --driver-opt memory=$BUILD_MEM --driver-opt memory-swap=$BUILD_MEM >/dev/null"
echo "builder=$BUILDER (memory capped at $BUILD_MEM)"

echo "=== [2/6] browser-runtime ==="
runtime_hash="$(remote "cd '$server_root/source' && cat browser-runtime/Dockerfile browser-runtime/requirements.txt browser-runtime/runtime.py browser-runtime/pool.py browser-runtime/observation.py browser-runtime/automation.py browser-runtime/document_download.py browser-runtime/download_diagnostics.py browser-runtime/migrate_profile.py browser-runtime/opportunity_download.py browser-runtime/input-check.html browser-runtime/install_clearcote.py browser-runtime/clearcote-pin.json browser-runtime/install_update.py | sha256sum | cut -c1-16")"
runtime_image="docker.io/zoer-local/browser-runtime:$runtime_hash"
# Runtime tags identify the complete reviewed source set. Preserve an existing
# exact tag on backend-only deployments, as we already do for agent-runtime.
# Rebuilding against a moving base image consumes substantial disk and changes
# runtime bytes without a source/tag change.
remote "sudo -n docker image inspect '$runtime_image' >/dev/null 2>&1" || \
  remote "cd '$server_root/source' && sudo -n docker buildx build --builder '$BUILDER' --load -t '$runtime_image' browser-runtime"
remote "sudo -n docker save '$runtime_image' | sudo -n k3s ctr -n k8s.io images import -"
remote "sudo -n k3s ctr -n k8s.io images label '$runtime_image' io.cri-containerd.pinned=pinned >/dev/null"
echo "runtime_image=$runtime_image"
"$(dirname "${BASH_SOURCE[0]}")/zoer-browser-worker-runtime.sh" "$runtime_image"

echo "=== [3/6] agent-runtime ==="
agent_hash="$(cat "$repo_root/agent-runtime/Dockerfile" "$repo_root/backend/src/agent-runners/worker.ts" | shasum -a 256 | cut -c1-16)"
agent_image="docker.io/zoer-local/agent-runtime:$agent_hash"
remote "sudo -n docker image inspect '$agent_image' >/dev/null 2>&1" || \
  remote "cd '$server_root/source' && sudo -n docker buildx build --builder '$BUILDER' --load -f agent-runtime/Dockerfile -t '$agent_image' ."
remote "sudo -n docker save '$agent_image' | sudo -n k3s ctr -n k8s.io images import -"
echo "agent_image=$agent_image"

echo "=== [4/6] backend ==="
source_base="${ZOER_BACKEND_SOURCE_BASE_IMAGE:-}"
reuse_frontend="${ZOER_FRONTEND_REUSE_IMAGE:-}"
frontend_base="${ZOER_FRONTEND_SOURCE_BASE_IMAGE:-}"
frontend_dist="${ZOER_FRONTEND_PREBUILT_DIR:-}"
for image in "$source_base" "$reuse_frontend" "$frontend_base"; do
  [[ -z "$image" || "$image" =~ ^docker.io/zoer-local/(backend|frontend):[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { echo "Source-only image must be an exact local development tag." >&2; exit 1; }
done
if [[ -n "$source_base" ]]; then
  # Source, built-in skills and reviewed runtime metadata are replaced. Fail closed if dependency/config inputs differ;
  # The content-tagged runtime image is built/imported above; package changes still require a full build.
  host_inputs="$(remote "cd '$server_root/source/backend' && sha256sum package.json bun.lock tsconfig.json scripts/fix-agentos-codex-package.mjs")"
  base_inputs="$(remote "sudo -n docker run --rm --network none --read-only --entrypoint sha256sum '$source_base' package.json bun.lock tsconfig.json scripts/fix-agentos-codex-package.mjs")"
  [[ "$host_inputs" == "$base_inputs" ]] || { echo "Source-only backend dependency/config inputs differ; use a full build." >&2; exit 1; }
  source_dockerfile="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/k8s/zoer-local/optional/backend-source-update.Dockerfile"
  rsync -a -e "$ssh_transport" "$source_dockerfile" "$server_host:$server_root/backend-source-update.Dockerfile"
  # The daemon-backed builder can resolve this node's existing local image;
  # isolated builders cannot. This Dockerfile only copies source and runs a
  # TypeScript check with a 2 GiB Node heap, without dependency/network installs.
  remote "cd '$server_root/source' && sudo -n docker buildx build --builder default --network none --load --build-arg 'ZOER_BACKEND_BASE_IMAGE=$source_base' --build-arg 'ZOER_AGENT_RUNTIME_IMAGE=$agent_image' --build-arg 'ZOER_BROWSER_RUNTIME_IMAGE=$runtime_image' --build-arg 'ZOER_GIT_COMMIT=$full_sha' --build-arg 'ZOER_GIT_DIRTY=$git_dirty' -f '$server_root/backend-source-update.Dockerfile' -t 'docker.io/zoer-local/backend:$image_tag' ."
else
  remote "cd '$server_root/source' && sudo -n docker buildx build --builder '$BUILDER' --load --build-arg 'ZOER_BROWSER_RUNTIME_IMAGE=$runtime_image' --build-arg 'ZOER_AGENT_RUNTIME_IMAGE=$agent_image' --build-arg 'ZOER_GIT_COMMIT=$full_sha' --build-arg 'ZOER_GIT_DIRTY=$git_dirty' -f backend/Dockerfile -t 'docker.io/zoer-local/backend:$image_tag' ."
fi

echo "=== [5/6] frontend ==="
if [[ -n "$frontend_base" ]]; then
  [[ -z "$reuse_frontend" && -f "$frontend_dist/index.html" ]] || { echo "Choose a prebuilt frontend directory, without frontend reuse." >&2; exit 1; }
  # Static frontend assets are architecture independent; only the existing
  # amd64 Nginx image runs on the node. Never install or compile there in this mode.
  remote "mkdir -p '$server_root/frontend-prebuilt/dist'"
  rsync -a --delete -e "$ssh_transport" "$frontend_dist/" "$server_host:$server_root/frontend-prebuilt/dist/"
  rsync -a -e "$ssh_transport" "$repo_root/frontend/nginx.conf.template" "$server_host:$server_root/frontend-prebuilt/nginx.conf.template"
  frontend_dockerfile="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/k8s/zoer-local/optional/frontend-prebuilt-update.Dockerfile"
  rsync -a -e "$ssh_transport" "$frontend_dockerfile" "$server_host:$server_root/frontend-prebuilt/Dockerfile"
  remote "cd '$server_root/frontend-prebuilt' && sudo -n docker buildx build --builder default --network none --load --build-arg 'ZOER_FRONTEND_BASE_IMAGE=$frontend_base' --build-arg 'ZOER_GIT_COMMIT=$full_sha' --build-arg 'ZOER_GIT_DIRTY=$git_dirty' -t 'docker.io/zoer-local/frontend:$image_tag' ."
elif [[ -n "$reuse_frontend" ]]; then
  remote "sudo -n docker tag '$reuse_frontend' 'docker.io/zoer-local/frontend:$image_tag'"
else
  remote "cd '$server_root/source' && sudo -n docker buildx build --builder '$BUILDER' --load --build-arg 'ZOER_GIT_COMMIT=$full_sha' --build-arg 'ZOER_GIT_DIRTY=$git_dirty' -f frontend/Dockerfile -t 'docker.io/zoer-local/frontend:$image_tag' ."
fi

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
