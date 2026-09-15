# Paperless-ngx

Runs in the k3s cluster, namespace `paperless`. Manifests: `k8s/paperless/base/`.

- **URL:** `https://paperless.k8s.overtheedgepaper.ca` (also `http://paperless.k8s.ote`)
- **Version:** v3.1.3 (migrated from v2.18.4 in CT 102)
- **Documents:** 1,179, ~3.5 GB on the UniFi NAS over NFS

## Layout

| Component | Image | Storage |
|---|---|---|
| `paperless` | `ghcr.io/paperless-ngx/paperless-ngx:3.1.3` | NFS PV -> NAS `Documents/.data/paperless` |
| `paperless-postgres` | `postgres:16-alpine` | local-path 10Gi |
| `paperless-valkey` | `valkey/valkey:9` | ephemeral |
| `paperless-tika` | `apache/tika:latest` | stateless |
| `paperless-gotenberg` | `gotenberg/gotenberg:8` | stateless |

Documents are **mounted, not copied** -- the same NAS directory CT 102 used,
with `consume`, `data` and `media` as `subPath` mounts.

Tika and Gotenberg replaced CT 104 and CT 105. They are pure stateless
converters with no data of their own, so moving them was just a redeploy
(Gotenberg also went v7 -> v8).

## Two things that will bite

**v3 will not upgrade directly from v2.18.4.** Its own pre-flight check refuses:

```
V3 upgrade check failed: last applied documents migration is
'1068_alter_document_created'. Expected '1075_workflowaction_order' (v2.20.15)
```

The path is **v2.18.4 -> v2.20.15 -> v3.1.3**, running migrations at each hop.
The check runs before touching the database, so a direct attempt is safe but
useless. (Immich allowed v1 -> v3 directly; do not generalise from it.)

**`PAPERLESS_PORT` collides with Kubernetes service discovery.** Kubernetes
injects `<SERVICE>_PORT` env vars into every pod, so a Service named `paperless`
produces `PAPERLESS_PORT=tcp://10.43.85.138:8000`. Paperless reads that as its
own port setting and granian dies:

```
Invalid value for '--port': 'tcp://10.43.85.138:8000' is not a valid integer
```

The fix is to set it explicitly, which is already in `webserver.yaml`:

```yaml
- {name: PAPERLESS_PORT, value: "8000"}
```

Any app whose env prefix matches its Service name has this problem.

## After the migration

v3 squashed the v2 migration history, so `showmigrations` reports
`0002_squashed`. That is expected, not data loss.

The task queue carried stale pickled v2 tasks and had to be flushed once.

## Backups

`k8s/paperless/base/backup.yaml` -- CronJob `paperless-postgres-backup`.

- **Schedule:** `45 3 */2 * *`, `America/Vancouver` -- every 2 days at 03:45
  (offset from Immich's 03:15 so the two never hit the NAS together)
- **Retention:** 32 days (~16 dumps)
- **Destination:** NAS `Documents/.data/k8s-backups/paperless`
- **Size:** ~7.6 MB per dump

This covers **metadata only** -- tags, correspondents, document types, saved
views, users and the OCR content index. The documents themselves are already on
the NAS and are part of the NAS backup.

Restore:

```bash
kubectl -n paperless scale deploy paperless --replicas=0
gzip -dc paperless-YYYYMMDD-HHMM.sql.gz | kubectl -n paperless exec -i deploy/paperless-postgres -- psql -U paperless -d paperlessdb
kubectl -n paperless scale deploy paperless --replicas=1
```

Trigger an out-of-band run:

```bash
kubectl -n paperless create job manual-backup --from=cronjob/paperless-postgres-backup
```

## Rollback

CT 102 still exists, stopped, with its original data and v2.18.4. Note the
database was migrated **in place** -- a rollback needs the pre-migration dump,
not just `pct start 102`.
