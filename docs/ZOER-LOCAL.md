# Zoer — local build and deployment on K3s

Runs [Zoer](https://github.com/ahzs645/zoer) on the K3s cluster from images
built **on the node**, with no registry involved. Use this to test a working
tree — including uncommitted changes — as a real deployment.

Last verified: 2026-09-11. Backend and frontend confirmed running from locally
built images; `/api/health` reports the working tree's commit with `dirty:true`.

## Why the node and not your laptop

The cluster is **amd64**; Apple Silicon is **arm64**. Cross-building with
`buildx` under QEMU is several times slower, and the Chromium/Playwright layers
in `browser-runtime` are exactly the ones most likely to fail under emulation.
Zoer's own `scripts/k8s-server-dev.sh` was written to build on the node for this
reason.

Docker is installed on the node purely as a **build engine**. K3s keeps using
containerd; built images are imported into it with `k3s ctr images import`.

## Relationship to Zoer's own `k8s-server-dev.sh`

Zoer ships `scripts/k8s-server-dev.sh`, which does the same build and then
*temporarily overrides* an existing Flux-managed deployment, recording the
previous state so `down` can restore it.

**That script's `up` cannot run on this cluster.** It hard-requires a Flux
`Kustomization` named `zoer`, and there is no Flux here at all. It is designed
to override a GitOps deployment, not to create one.

So this repo reproduces its build path exactly — same image names, same
containerd import — and applies manifests directly instead. Consequences:

- `k8s-server-dev.sh down` will **not** work. There is no
  `zoer-local-deploy-state` ConfigMap and no production images to restore.
- To remove Zoer entirely: `kubectl delete namespace zoer`.
- Its `bootstrap` subcommand **is** still the right way to install Docker.

## One-time setup

```bash
# 1. Docker on the node (uses Zoer's own bootstrap)
ZOER_K8S_DEV_HOST=ubuntu@10.70.20.50 \
ZOER_K8S_DEV_SSH_KEY=~/.ssh/personalprox_pve_ed25519 \
  ~/github/zoer/scripts/k8s-server-dev.sh bootstrap

# 2. Submodules (the build fails without them)
git -C ~/github/zoer submodule update --init --recursive

# 3. Secrets
./scripts/zoer-create-secrets.sh
```

The node needs **15 GiB free** before a build and comfortably more after. See
the disk section in [KUBERNETES.md](./KUBERNETES.md).

## Build and deploy

```bash
./scripts/zoer-deploy.sh              # build both images, apply, verify
./scripts/zoer-deploy.sh --rollback   # back to the previously deployed images
./scripts/zoer-deploy.sh --keep 1     # keep N old dev images per component
./scripts/zoer-deploy.sh --force      # deploy despite running plugin workers
```

Builds the current working tree on the node and rolls backend and frontend out
together — they share one tag. Uncommitted changes are included, since the
source is rsynced rather than pulled from git.

**Budget 20–30 minutes and check disk first.** Zoer's images are large (backend
~8.7 GB, browser-runtime ~6.5 GB); a cold rebuild adds roughly 33 GB across
Docker and containerd before pruning. The build refuses to start below 15 GiB
free. `--keep 1` is the sane default here — at these sizes `--keep 3` is ~50 GB.

Four images are built: `browser-runtime` → `agent-runtime` → `backend` →
`frontend`. Only backend and frontend are swapped into the Deployments; the
other two are referenced by the backend at runtime to spawn browser and agent
pods, which is precisely why they must be pinned.

### What the script handles

- **Deploys Convex functions before the image.** Zoer's backend calls Convex
  functions by name. If the app image references a function the Convex
  deployment does not have, it fails at runtime with messages like
  *"credential store is missing the Convex function `secrets:create`"* — which
  reads like an application bug rather than a deploy-ordering mistake.

  This is not hypothetical: Zoer's self-hosted Convex ran for days with **no
  functions deployed at all**, because the original deployment never pushed
  them. Every Convex-backed feature 404'd; the WordPress "Test and add site"
  flow was the first thing to surface it. `--skip-convex` opts out.

- **Refuses to deploy while plugin workers are running.** Rolling the backend
  severs an in-flight integration worker's capability stream. Upstream's
  `k8s-server-dev.sh` guards this too; the check runs twice — before the build
  and again after, because a build takes long enough for a worker to start.
  `--force` overrides it.
- **Pins all four images** against kubelet's image GC. The build script
  originally pinned only `browser-runtime`, and `agent-runtime` was duly
  garbage-collected at 88% disk — nothing was running that referenced it, since
  the backend only pulls it when an agent starts.
- **Records the previous images** as the `zoer.previous-image` annotation before
  applying, and reverts automatically if either rollout fails.
- **Prunes per component**, never touching `browser-runtime` or `agent-runtime`
  — those carry content-hash tags the backend still references.
- **Excludes generated artifacts.** `output/` alone is ~689 MB across 49k files
  and was previously rsynced into the build context on every build; it is now in
  `.gitignore`, `.dockerignore` and the rsync excludes.

## Verifying it is really your build

```bash
curl -s http://zoer.k8s.ote/api/health
# {"status":"ok","build":{"commit":"b216426...","dirty":true}}
```

`commit` is the working tree's HEAD and `dirty` reflects uncommitted changes, so
this distinguishes a local build from a pulled registry image.

## Hostnames

| URL | Protocol |
|---|---|
| `http://zoer.k8s.ote` | HTTP |
| `https://zoer.k8s.overtheedgepaper.ca` | HTTPS, real Let's Encrypt cert |

Sibling services follow the same pattern: `blitz-dashboard`, `blitz-engine`
(responds on `/status`, not `/`), `cloak-browser`.

Both name sets are served in parallel by separate Ingress objects. Renaming a
hostname means changing **six** places, not one — see "Renaming" below.

## Development access mode

The deployment runs with authentication disabled:

```yaml
AUTH_PASSWORD_ENABLED: "0"        # open access, no login
AUTH_DEMO_ENABLED: "0"
DEV_ALLOW_PASSWORDLESS_GITHUB: "1"
```

`DEV_ALLOW_PASSWORDLESS_GITHUB` is required in addition to the first two.
Without it the backend refuses **all** GitHub account operations while in
passwordless mode (`backend/src/repo-providers.ts` throws). Only the exact
string `"1"` enables it.

> **Anyone who can reach this instance has full workspace access and use of the
> configured GitHub account, with no login.** This is LAN-only development
> configuration. Do not expose it through the reverse proxy or VPN. To restore
> authentication, set `AUTH_PASSWORD_ENABLED: "1"` in
> `k8s/zoer-local/base/backend.yaml` and re-apply.

## Renaming a hostname

`.k8s.home` → `.k8s.ote` required edits in six places. Changing only the Ingress
leaves the app broken in ways that look like frontend bugs:

1. Ingress `host` (and the `tls.hosts` entry, for HTTPS)
2. `CORS_ORIGIN` on the backend — stale value means the backend rejects every
   API call from the new origin
3. `CSP_FRAME_SRC_EXTRA` on the backend
4. `CSP_CONNECT_SRC_EXTRA` on the backend
5. The same two CSP variables on the **frontend**
6. The `Content-Security-Policy` header in the nginx gateway ConfigMap

After editing the ConfigMap, `kubectl rollout restart deploy/zoer-gateway` — an
in-place ConfigMap edit does not restart pods.

## Known gaps

**AI calls fail.** `AI_BASE_URL` is `http://192.168.1.51:11434/v1`, an AI VM on
the retired `192.168.1.0/24` network that no longer exists. The backend starts
fine (`AI_API_KEY` falls back to `"ollama"`), but model calls cannot connect.
Point it at a reachable endpoint.

**Two manifests are excluded.** `wordpress-domains.yaml` and
`sites-domains.yaml` from the upstream repo declare cert-manager `Certificate`
resources for public `*.k8s.ahmad.sh` domains. They are omitted from
`k8s/zoer-local/base/kustomization.yaml`. cert-manager is now installed, so they
could be restored if those domains are wanted.

**Generated secrets.** `JOB_STORE_PASSWORD` and `SECRETS_KEY` were generated
fresh. If restoring an existing Zoer instance, replace them with the originals
or existing encrypted data becomes unreadable.

**These manifests are a fork.** `k8s/zoer-local/base/` was copied from
`personalprox/k8s/zoer/` and modified (hostnames, auth flags, local images).
That repo is the Flux GitOps source for production Zoer and was deliberately
left untouched — editing it could alter production on the next reconcile.
Upstream changes do not flow here automatically.
