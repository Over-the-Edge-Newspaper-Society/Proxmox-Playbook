# EventScrape on K3s

Event scraper for Prince George area sources, migrated from the Docker-in-LXC
deployment on CT 206.

Last verified: 2026-09-15.

## Services

| Deployment | Image | Exposed |
|---|---|---|
| `eventscrape-convex` | `ghcr.io/get-convex/convex-backend` | `convex-events.k8s.overtheedgepaper.ca` |
| `eventscrape-admin` | built on the node | `events.k8s.ote`, `events.k8s.overtheedgepaper.ca` |
| `eventscrape-worker` | built on the node | not exposed |
| `eventscrape-convex-dashboard` | `ghcr.io/get-convex/convex-dashboard` | **no Ingress** — port-forward only |

```bash
kubectl -n eventscrape port-forward svc/eventscrape-convex-dashboard 6791:6791
```

The dashboard is a full read/write UI over the database, so it is deliberately
not reachable from the LAN.

## Why Convex is publicly exposed here (and not for OTEManager)

OTEManager proxies Convex through a server-side bridge, so its Convex backend
stays internal. **EventScrape's admin SPA calls Convex directly from the
browser.** `VITE_CONVEX_URL` is baked into the admin bundle at build time and
Convex mints file URLs from the same origin, so it needs a real public hostname.

Consequence: **changing the Convex hostname requires rebuilding the admin
image.** The worker is server-side and uses `http://eventscrape-convex:3210`.

## Deploying

```bash
./scripts/eventscrape-deploy.sh             # build both images + roll out
./scripts/eventscrape-deploy.sh --rollback  # previous images
./scripts/eventscrape-deploy.sh --keep 5    # keep N old dev images per image
```

Both images share one tag and roll out together. Convex functions are **not**
deployed separately — for EventScrape they live inside the Convex database, so a
migrated database arrives with its functions already in place.

## Storage

The Convex PVC is `local-path` (40Gi), not the `nfs-nas` default — Convex uses
SQLite, which needs real filesystem locking. **The dataset lives on the node's
disk and does not survive a node rebuild.**

The dataset is ~650 MB: a 229 MB `db.sqlite3` plus a 407 MB `storage/` tree.

> `docker-compose.server.yml` in the app repo supports offloading storage to
> MinIO via `S3_*` vars. In the LXC deployment those were **all empty**
> (verified `length=0`), so storage was local. This matters because CT 200
> (minio) was stopped on 2026-09-14 — that did **not** affect EventScrape.

## The migration that was performed

Source: CT 206, Docker volume `eventscrape_convex_data`.

1. `docker compose -f docker-compose.server.yml stop worker backend` — both
   reported `Exited (0)`, so SQLite was quiesced.
2. `tar czf` inside the container, `pct pull` to the Proxmox host, streamed to
   the K3s node, extracted into the PVC with Convex scaled to 0.
3. Verified byte-exact: `db.sqlite3` md5 `b527a142…` and total `671475752`
   bytes matched the source on both sides.

**Stopping first was not optional.** The db checksum differed between a running
snapshot (`ce2dab…`) and the stopped one (`b527a1…`).

`CONVEX_INSTANCE_NAME` and `CONVEX_INSTANCE_SECRET` were carried over from the
LXC `.env` — the migrated database has that instance identity baked in, and a
mismatch prevents the backend opening it. They live in the
`eventscrape-convex-secret` Secret.

Verified after migration with `dashboard:stats`:

```json
"events": { "raw": 2973 },
"runs":   { "success": 4766, "error": 555, "partial": 422 }
```

and the worker logging `Synced 19 modules to Convex (created 11, updated 0)` —
the 8 that were not created already existed, which is the migrated data.

## The old LXC containers

**CT 206 `eventscrape`** — the source of this migration, now **fully stopped**
with `onboot: 0` so a host reboot does not resurrect it. Leaving it stopped is
deliberate: if both deployments run, they scrape the same sources into two
separate databases that immediately diverge.

Its disk is kept as the rollback: `/root/esc-snapshot.zip` (139 MB) and
`/opt/eventscrape` (506 MB).

To restore the LXC deployment:
`cd /opt/eventscrape && docker compose -f docker-compose.server.yml up -d`

**CT 106 `events`** — an older PostgreSQL-era generation, already broken before
any of this: `api` and `worker` crash-loop with `getaddrinfo ENOTFOUND postgres`
because the database container no longer exists. Its volumes still hold
`postgres_data` (98 MB), `backup_data` (207 MB) and `instagram_images` (130 MB).
Nothing was changed there.

## Scraper modules

The worker auto-discovers modules from `worker/src/modules/`. It logs the count
at startup:

```
✅ Loaded 19 scraper modules
🔄 Synced 19 modules to Convex
```

**19 loaded from 20 directories is correct.** `instagram` has no `index.ts` and
is not auto-discovered -- `worker.ts` imports `handleInstagramScrapeJob` from it
directly. Do not go looking for a bug there.

### Verifying a deployment

The image tag encodes the commit, so what is running can be checked against the
repo:

```bash
kubectl -n eventscrape get deploy eventscrape-worker \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# docker.io/eventscrape-local/worker:dev-<epoch>-<sha>-dirty
```

Unit tests run locally and need no cluster:

```bash
pnpm install --filter @eventscrape/worker --frozen-lockfile
cd worker && ./node_modules/.bin/vitest run
```

Two things to expect:

- A plain `pnpm install` at the root fails on `better-sqlite3` (a native build
  belonging to `apps/api`, unrelated to the worker). Filtering to the worker
  avoids it.
- Three integration tests fail without Playwright's browser binaries
  (`unbc_ca`, `prince_george_ca`, `unbctimberwolves_com`). `npx playwright
  install` fixes it; everything else passes without a browser.

### The browser pool fails open, silently

The worker initialises a Playwright pool at startup. If that times out it logs a
**warning** and carries on with website scrapes disabled:

```
⚠️  Browser pool init failed (website scrapes disabled): Timeout 180000ms exceeded
🎉 Worker ready — polling Convex job queues
```

The pod stays `Running` and `Ready`. It happened for real when the pod started
while the node was overloaded, so the worker looked healthy while scraping
nothing. There is no retry -- restart the Deployment and confirm:

```
✅ Browser pool initialized with 3 browsers
```
