# Immich

Runs in the k3s cluster, namespace `immich`. Manifests: `k8s/immich/base/`.

- **URL:** `https://immich.k8s.overtheedgepaper.ca` (also `http://immich.k8s.ote`)
- **Version:** v3.2.1 (migrated from v1.143.1 in CT 100)
- **Library:** ~123 GB, 5,280 assets, on the UniFi NAS over NFS

## Layout

| Component | Image | Storage |
|---|---|---|
| `immich-server` | `ghcr.io/immich-app/immich-server:v3.2.1` | NFS PV -> NAS `Images/.data/immich/data` |
| `immich-machine-learning` | `ghcr.io/immich-app/immich-machine-learning:v3.2.1` | model cache, local-path |
| `immich-postgres` | `ghcr.io/immich-app/postgres:16-vectorchord0.4.3-pgvector0.8.0` | local-path 20Gi |
| `immich-valkey` | `valkey/valkey` | ephemeral |

The photo library is **mounted, not copied** -- the same NAS directory CT 100
used. Nothing was duplicated during the migration.

Postgres is deliberately **not** on NFS. Postgres over NFS risks corruption on
an unclean stop, so it sits on the node disk (`local-path`) and is protected by
dumps instead -- see Backups.

## Two things that will bite

**v3 cannot run on a read-only mount.** It writes `.immich` folder-integrity
markers at startup. Mounting the library read-only fails with
`EROFS: read-only file system, open '/data/encoded-video/.immich'`. Read-only is
still useful as a *migration* safety net, but it must be removed before v3
starts for real.

Note that `spec.nfs.readOnly: true` on the PV **does not actually enforce
anything** -- a pod could still write. Real enforcement needs `ro` in
`mountOptions`.

**Restore into an EMPTY database.** If v3 is allowed to start first, it creates
its own schema, and restoring the old dump over it produces dozens of errors
(`relation "asset" already exists`, `multiple primary keys for table "user"`).
The dump must land in a genuinely empty database:

```sql
DROP DATABASE immich WITH (FORCE);
CREATE DATABASE immich OWNER immich;
```

Then restore, then start the server. Done that way: **0 errors**.

## Backups

`k8s/immich/base/backup.yaml` -- CronJob `immich-postgres-backup`.

- **Schedule:** `15 3 */2 * *`, `America/Vancouver` -- every 2 days at 03:15
- **Retention:** 32 days (~16 dumps)
- **Destination:** NAS `Documents/.data/k8s-backups/immich` (itself backed up)

Dumps are written as `.partial` and renamed only on success, so a truncated run
can never masquerade as a good backup.

Restore:

```bash
kubectl -n immich scale deploy immich-server --replicas=0
gzip -dc immich-YYYYMMDD-HHMM.sql.gz | kubectl -n immich exec -i deploy/immich-postgres -- psql -U immich -d immich
kubectl -n immich scale deploy immich-server --replicas=1
```

Only the database is covered here. The photos live on the NAS and are part of
the NAS backup.

## Mobile app

The Immich app stores the server URL **per device**. When the bare
`Immich.overtheedgepaper.ca` name was retired, every client had to be pointed at
`https://immich.k8s.overtheedgepaper.ca`.

## Rollback

CT 100 still exists, stopped, with its original data. `pct start 100` brings the
old v1.143.1 instance back. Do not run both against the same NAS library.
