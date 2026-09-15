# OTEManager on K3s

Article management app, running on the cluster from an image built on the node.

Last verified: 2026-09-14.

## What changed from the LXC deployment

OTEManager used to run as **CT 202** against PostgreSQL (CT 201) and MinIO
(CT 200). It no longer uses either — commit `880d0af` ("Migrate database and
file storage to Convex") moved **both records and uploaded files** into Convex.

| | Old (CT 202) | Now |
|---|---|---|
| Database | PostgreSQL, CT 201 | Convex |
| File storage | MinIO S3, CT 200 | Convex |
| Runtime | Node on LXC | TanStack Start / Nitro in a pod |

**CTs 200 and 201 were stopped on 2026-09-14** (containers and disks kept, so
they can be started again instantly). Both were verified idle first — zero
Postgres client connections, zero MinIO connections, no MinIO log activity in
24h. Playbooks `10`–`30` still provision them if they are ever needed again.

## Architecture

```
Traefik 10.70.20.240
      │
      ├── otemanager.k8s.ote                  (HTTP)
      └── otemanager.k8s.overtheedgepaper.ca  (HTTPS, cert-manager)
      │
      ▼
 Deployment/otemanager  :3000
      │  server-only bridge, authenticated with CONVEX_SERVER_SECRET
      ▼
 Deployment/otemanager-convex  :3210 api  :3211 site
      │
      ▼
 PVC otemanager-convex-data  40Gi  storageClass: local-path
```

The browser never talks to Convex directly; the app proxies every call through a
server-side bridge, so the secret never reaches the client.

## Storage durability — read this

The Convex PVC uses **`local-path`, not the `nfs-nas` default**, and that is
deliberate: Convex stores data in SQLite, which needs real filesystem locking.
SQLite over NFS is a known corruption risk. Zoer's Convex is configured the same
way for the same reason.

The consequence: **this data lives on the K3s node's disk and does not survive a
VM rebuild.** It holds every article record and every uploaded file. Take
backups — Utilities → Backup & Restore in the app, or the CLI below.

## Build and deploy

```bash
# Build on the node (amd64), import into containerd, pin against image GC
./scripts/otemanager-local-build.sh          # prints IMAGE_TAG

# One-time per fresh Convex: admin key, functions, shared secret
./scripts/otemanager-bootstrap.sh

# Point the overlay at the tag and apply
sed -i '' "s/newTag: .*/newTag: <IMAGE_TAG>/" k8s/otemanager/overlay/kustomization.yaml
kubectl apply -k k8s/otemanager/overlay
```

The repo has no Dockerfile upstream; one was added at the root of the
OTEManager checkout. It is a two-stage build — Nitro produces a self-contained
`.output`, so the runtime stage carries no `node_modules`. **Node 24** is pinned
on purpose (`.nvmrc`); the project README notes the Nitro dev adapter drops
response headers under Node 26.

## Local development loop

Edit code on your machine, then one command builds it on the node and rolls it
out:

```bash
./scripts/otemanager-deploy.sh
```

The source is **rsynced, not pulled from git**, so uncommitted changes are
included. The image tag encodes the commit and a `-dirty` suffix when the tree
has local modifications, which makes it obvious what is running.

| Flag | Effect |
|---|---|
| *(none)* | Convex functions → build → apply → wait → prune |
| `--skip-convex` | Skip the Convex function deploy (faster when only app code changed) |
| `--keep N` | Keep N old dev images on the node (default 3) |
| `--rollback` | Return to the previously deployed image |

What it handles that a manual `build && apply` does not:

- **Convex functions deploy first.** If schema or functions changed, pushing the
  app image first means it calls functions that do not exist yet. This runs by
  default because it is idempotent and fast; `--skip-convex` opts out.
- **Automatic rollback.** The currently running image is recorded on the
  Deployment as the `ote.previous-image` annotation before applying. A failed
  rollout is reverted automatically and the app logs are printed.
- **Image pruning.** Every build leaves a tagged image in Docker *and* a copy in
  containerd. Left alone the node fills up, and above 85% kubelet's image GC
  starts evicting images — which breaks running deployments. The script keeps
  the most recent few and deletes the rest, never the tag it just deployed.
- **`.env.local` is moved aside and restored**, including on failure, so the
  Convex CLI targets the cluster rather than the local anonymous deployment.

### Checking what is deployed

```bash
kubectl -n otemanager get deploy otemanager \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

# what the previous image was, if you need to roll back
kubectl -n otemanager get deploy otemanager \
  -o jsonpath='{.metadata.annotations.ote\.previous-image}{"\n"}'
```

### Faster iteration without the cluster

For tight UI work, running the app locally is far quicker than a node build —
`npm run convex:dev` plus `npm run dev` against the isolated local Convex
deployment in `.convex/`, as the project README describes. Use the cluster
deploy when you want to test the real deployment: the built image, the
in-cluster Convex, ingress, and TLS.

## Convex bootstrap: three things, all required

A fresh self-hosted Convex starts completely empty. Until all three exist, the
app fails in ways that look like application bugs:

1. **Admin key** — generated inside the container with
   `/convex/generate_admin_key.sh`. Needed by the Convex CLI.
2. **Functions and schema** — `convex deploy` from the repo. Without them every
   query 404s.
3. **`CONVEX_SERVER_SECRET` set *inside* Convex** — `convex env set`. The value
   lives in **two** places: the `otemanager-app-secret` Secret (which the app
   sends) and Convex's own environment (which validates it). If they differ,
   every call is rejected.

`scripts/otemanager-bootstrap.sh` does all three.

> The repo's `.env.local` points the Convex CLI at a **local anonymous**
> deployment and silently overrides the self-hosted target. The bootstrap script
> moves it aside during the run and restores it on exit, including on failure.

## The relative-upload-URL trap

`CONVEX_CLOUD_ORIGIN` and `CONVEX_SITE_ORIGIN` map to the backend's
`--convex-origin` / `--convex-site` flags. They tell Convex how clients reach
it, and they are **required**.

Left unset, Convex hands out a **relative** upload URL and every file upload
dies:

```
TypeError: Failed to parse URL from /api/storage/upload?token=...
```

Records still import perfectly, so the failure appears only when files are
written — which reads like an app bug, not configuration. Set:

```yaml
- name: CONVEX_CLOUD_ORIGIN
  value: http://otemanager-convex:3210
- name: CONVEX_SITE_ORIGIN
  value: http://otemanager-convex:3211
```

Verify it returns an absolute URL before trusting uploads:

```bash
kubectl -n otemanager exec deploy/otemanager-convex -- \
  sh -c 'ps aux | grep -o "\-\-convex-origin [^ ]*"'
```

**Importing from outside the cluster:** the origin must be reachable from
wherever the importer runs. `http://otemanager-convex:3210` does not resolve on
a laptop. Either run the importer inside the cluster, or temporarily set the
origin to `http://127.0.0.1:3210` while port-forwarding, then set it back. The
stored records keep only a `storageId`, not a URL, so changing the origin
afterwards is safe.

## Backup and restore

```bash
kubectl -n otemanager port-forward svc/otemanager-convex 3210:3210 &

cd ~/github/OTEManager
mv .env.local .env.local.bak     # it targets the local anonymous deployment
export CONVEX_URL=http://127.0.0.1:3210
export CONVEX_SERVER_SECRET="$(kubectl -n otemanager get secret otemanager-app-secret \
  -o jsonpath='{.data.CONVEX_SERVER_SECRET}' | base64 -d)"

node --import tsx scripts/import-backup.ts /path/to/backup.zip --dry-run
node --import tsx scripts/import-backup.ts /path/to/backup.zip
mv .env.local.bak .env.local
```

Always `--dry-run` first: it validates the manifest, relationships, file sizes
and checksums without writing. Default mode is **merge** — existing record IDs
are kept and files matching on SHA-256 and size are skipped, so a re-run after a
failure resumes rather than duplicating.

## Operations

```bash
kubectl -n otemanager get pods,pvc,ingress,certificate
kubectl -n otemanager logs deploy/otemanager --tail=50
kubectl -n otemanager rollout restart deploy/otemanager
```

Removing everything: `kubectl delete namespace otemanager`. That **deletes the
Convex PVC and all data with it** — back up first.
