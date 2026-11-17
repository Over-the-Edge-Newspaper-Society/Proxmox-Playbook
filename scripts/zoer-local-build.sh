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

# Docker (where images are built) and k3s containerd (where they run) are separate
# stores. Content-tagged images only need to be in containerd, so look there first:
# checking Docker alone rebuilt a 10 GB runtime that was already pinned and running.
in_containerd() { remote "sudo -n k3s ctr -n k8s.io images ls -q | grep -Fx '$1' >/dev/null"; }
in_docker() { remote "sudo -n docker image inspect '$1' >/dev/null 2>&1"; }
# Base images for source-only builds must be in Docker, which is not where deploys
# leave them. Copy from containerd rather than failing or rebuilding.
ensure_in_docker() {
  in_docker "$1" && return 0
  in_containerd "$1" || { echo "$1 is on neither Docker nor containerd on the node." >&2; return 1; }
  echo "Loading $1 from containerd into Docker"
  remote "sudo -n k3s ctr -n k8s.io images export - '$1' | sudo -n docker load >/dev/null"
  in_docker "$1" || { echo "Could not load $1 into Docker." >&2; return 1; }
}

# Everything that can reject this build runs here, before anything is built. A
# stale source-only check used to fail at step 4, after the runtime steps had already
# taken about 30 GB and pushed the node to 93% disk.
echo "=== preflight ==="
source_base="${ZOER_BACKEND_SOURCE_BASE_IMAGE:-}"
reuse_frontend="${ZOER_FRONTEND_REUSE_IMAGE:-}"
frontend_base="${ZOER_FRONTEND_SOURCE_BASE_IMAGE:-}"
frontend_dist="${ZOER_FRONTEND_PREBUILT_DIR:-}"
for image in "$source_base" "$reuse_frontend" "$frontend_base"; do
  [[ -z "$image" || "$image" =~ ^docker.io/zoer-local/(backend|frontend):[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { echo "Source-only image must be an exact local development tag." >&2; exit 1; }
done
if [[ -n "$frontend_base" ]]; then
  [[ -z "$reuse_frontend" && -f "$frontend_dist/index.html" ]] || { echo "Choose a prebuilt frontend directory, without frontend reuse." >&2; exit 1; }
fi
source_heap="${ZOER_SOURCE_NODE_HEAP_MB:-3072}"
[[ "$source_heap" =~ ^[0-9]+$ && "$source_heap" -ge 512 && "$source_heap" -le 3072 ]] || { echo "Source heap must be 512–3072 MiB." >&2; exit 1; }
prechecked="${ZOER_SOURCE_PRECHECK_SHA256:-}"
[[ -z "$prechecked" || "$prechecked" =~ ^[a-f0-9]{64}$ ]] || { echo "Invalid source typecheck receipt." >&2; exit 1; }

if [[ -n "${ZOER_BROWSER_RUNTIME_REUSE_IMAGE:-}" ]]; then
  runtime_image="$ZOER_BROWSER_RUNTIME_REUSE_IMAGE"
  [[ "$runtime_image" =~ ^docker.io/zoer-local/browser-runtime:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { echo "Runtime reuse requires an exact local browser-runtime tag." >&2; exit 1; }
  in_containerd "$runtime_image" || in_docker "$runtime_image" || { echo "The selected browser runtime is not present on the build node." >&2; exit 1; }
else
  runtime_hash="$(remote "cd '$server_root/source' && cat browser-runtime/Dockerfile browser-runtime/requirements.txt browser-runtime/runtime.py browser-runtime/pool.py browser-runtime/observation.py browser-runtime/automation.py browser-runtime/document_download.py browser-runtime/download_diagnostics.py browser-runtime/migrate_profile.py browser-runtime/opportunity_download.py browser-runtime/input-check.html browser-runtime/install_clearcote.py browser-runtime/clearcote-pin.json browser-runtime/install_update.py | sha256sum | cut -c1-16")"
  runtime_image="docker.io/zoer-local/browser-runtime:$runtime_hash"
fi
# Runtime tags identify the complete reviewed source set. Preserve an existing
# exact tag on backend-only deployments, as we already do for agent-runtime.
# Rebuilding against a moving base image consumes substantial disk and changes
# runtime bytes without a source/tag change.
runtime_present=0
if in_containerd "$runtime_image" || in_docker "$runtime_image"; then runtime_present=1; fi
# The source-only disk gate allows 5 GiB; a runtime build needs several times that.
if [[ -n "$source_base" && "$runtime_present" == 0 && "${ZOER_ALLOW_RUNTIME_BUILD:-0}" != 1 ]]; then
  echo "Source-only update would build a new browser runtime ($runtime_image, over 10 GB)." >&2
  echo "Keep the running one with ZOER_BROWSER_RUNTIME_REUSE_IMAGE=<its image>, use a full build, or accept the cost with ZOER_ALLOW_RUNTIME_BUILD=1." >&2
  exit 1
fi

if [[ -n "$source_base" ]]; then
  # Source, built-in skills and reviewed runtime metadata are replaced. Fail closed if dependency/config inputs differ;
  # package changes still require a full build. Paths are relative to the workspace root, which is /app in the image.
  ensure_in_docker "$source_base"
  source_inputs="package.json bun.lock bunfig.toml backend/package.json backend/tsconfig.json backend/scripts/fix-agentos-codex-package.mjs sdk/packages/api-types/package.json sdk/packages/plugin-contracts/package.json"
  host_inputs="$(remote "cd '$server_root/source' && sha256sum $source_inputs")" || { echo "Source-only inputs are missing from this checkout; update this list or use a full build." >&2; exit 1; }
  base_inputs="$(remote "sudo -n docker run --rm --network none --read-only --workdir /app --entrypoint sha256sum '$source_base' $source_inputs")" || { echo "Source-only inputs are missing from $source_base; use a full build." >&2; exit 1; }
  [[ "$host_inputs" == "$base_inputs" ]] || { echo "Source-only backend dependency/config inputs differ; use a full build." >&2; exit 1; }
  if [[ -n "$prechecked" ]]; then
    actual="$(remote "sudo -n docker run --rm --network none --read-only --memory=128m --cpus=0.5 -v '$server_root/source:/source:ro' --entrypoint bun '$source_base' /source/scripts/backend-source-digest.ts")"
    [[ "$actual" == "$prechecked" ]] || { echo "Source changed since the successful local typecheck; recheck before deploying." >&2; exit 1; }
    echo "Verified locally typechecked source receipt: $actual"
  fi
fi
[[ -z "$frontend_base" ]] || ensure_in_docker "$frontend_base"
[[ -z "$reuse_frontend" ]] || ensure_in_docker "$reuse_frontend"
echo "preflight passed"
if [[ "${ZOER_BUILD_PREFLIGHT_ONLY:-0}" == 1 ]]; then echo "PREFLIGHT ONLY: nothing was built."; exit 0; fi

remote "sudo -n docker buildx inspect '$BUILDER' >/dev/null 2>&1 || sudo -n docker buildx create --name '$BUILDER' --driver docker-container --driver-opt memory=$BUILD_MEM --driver-opt memory-swap=$BUILD_MEM >/dev/null"
echo "builder=$BUILDER (memory capped at $BUILD_MEM)"

echo "=== [2/6] browser-runtime ==="
if in_containerd "$runtime_image"; then
  echo "Browser runtime is already imported."
else
  in_docker "$runtime_image" || \
    remote "cd '$server_root/source' && sudo -n docker buildx build --builder '$BUILDER' --load -t '$runtime_image' browser-runtime"
  remote "sudo -n docker save '$runtime_image' | sudo -n k3s ctr -n k8s.io images import -"
fi
remote "sudo -n k3s ctr -n k8s.io images label '$runtime_image' io.cri-containerd.pinned=pinned >/dev/null"
echo "runtime_image=$runtime_image"
if [[ -z "${ZOER_BROWSER_RUNTIME_REUSE_IMAGE:-}" ]]; then
  "$(dirname "${BASH_SOURCE[0]}")/zoer-browser-worker-runtime.sh" "$runtime_image"
else
  echo "Browser runtime and worker placement retained for this application-only rollout."
fi

echo "=== [3/6] agent-runtime ==="
agent_hash="$(cat "$repo_root/agent-runtime/Dockerfile" "$repo_root/backend/src/agent-runners/worker.ts" | shasum -a 256 | cut -c1-16)"
agent_image="docker.io/zoer-local/agent-runtime:$agent_hash"
if in_containerd "$agent_image"; then
  echo "Content-tagged agent runtime is already imported."
else
  in_docker "$agent_image" || \
    remote "cd '$server_root/source' && sudo -n docker buildx build --builder '$BUILDER' --load -f agent-runtime/Dockerfile -t '$agent_image' ."
  remote "sudo -n docker save '$agent_image' | sudo -n k3s ctr -n k8s.io images import -"
fi
echo "agent_image=$agent_image"

echo "=== [3b/6] build-runner ==="
# Repository build jobs (WordPress builds without a development computer). Content-tagged like
# agent-runtime; jobs run on this node (the browser workers are tainted).
build_runner_hash="$(shasum -a 256 < "$repo_root/build-runner-image/Dockerfile" | cut -c1-16)"
build_runner_image="docker.io/zoer-local/build-runner:$build_runner_hash"
if in_containerd "$build_runner_image"; then
  echo "Content-tagged build runner is already imported."
else
  in_docker "$build_runner_image" || \
    remote "cd '$server_root/source' && sudo -n docker buildx build --builder '$BUILDER' --load -t '$build_runner_image' build-runner-image"
  remote "sudo -n docker save '$build_runner_image' | sudo -n k3s ctr -n k8s.io images import -"
fi
remote "sudo -n k3s ctr -n k8s.io images label '$build_runner_image' io.cri-containerd.pinned=pinned >/dev/null"
echo "build_runner_image=$build_runner_image"

echo "=== [4/6] backend ==="
if [[ -n "$source_base" ]]; then
  source_dockerfile="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/k8s/zoer-local/optional/backend-source-update.Dockerfile"
  rsync -a -e "$ssh_transport" "$source_dockerfile" "$server_host:$server_root/source/.zoer-backend-source-update.Dockerfile"
  # The daemon-backed builder can resolve this node's existing local image;
  # isolated builders cannot. This Dockerfile only copies source and runs a
  # TypeScript check with a 3 GiB Node heap, without dependency/network installs.
  remote "cd '$server_root/source' && sudo -n docker buildx build --builder default --network none --load --build-arg 'ZOER_SOURCE_PRECHECK_SHA256=$prechecked' --build-arg 'ZOER_SOURCE_NODE_HEAP_MB=$source_heap' --build-arg 'ZOER_BACKEND_BASE_IMAGE=$source_base' --build-arg 'ZOER_AGENT_RUNTIME_IMAGE=$agent_image' --build-arg 'ZOER_BROWSER_RUNTIME_IMAGE=$runtime_image' --build-arg 'ZOER_BUILD_RUNNER_IMAGE=$build_runner_image' --build-arg 'ZOER_GIT_COMMIT=$full_sha' --build-arg 'ZOER_GIT_DIRTY=$git_dirty' -f '$server_root/source/.zoer-backend-source-update.Dockerfile' -t 'docker.io/zoer-local/backend:$image_tag' ."
else
  remote "cd '$server_root/source' && sudo -n docker buildx build --builder '$BUILDER' --load --build-arg 'ZOER_BROWSER_RUNTIME_IMAGE=$runtime_image' --build-arg 'ZOER_AGENT_RUNTIME_IMAGE=$agent_image' --build-arg 'ZOER_BUILD_RUNNER_IMAGE=$build_runner_image' --build-arg 'ZOER_GIT_COMMIT=$full_sha' --build-arg 'ZOER_GIT_DIRTY=$git_dirty' -f backend/Dockerfile -t 'docker.io/zoer-local/backend:$image_tag' ."
fi

echo "=== [5/6] frontend ==="
if [[ -n "$frontend_base" ]]; then
  # Static frontend assets are architecture independent; only the existing
  # amd64 Nginx image runs on the node. Never install or compile there in this mode.
  remote "sudo -n install -d -o \$(id -u) -g \$(id -g) '$server_root/frontend-prebuilt' '$server_root/frontend-prebuilt/dist'"
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
