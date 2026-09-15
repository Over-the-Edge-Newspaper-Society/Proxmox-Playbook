# Proxmox Ansible Setup — OTEManager Infrastructure + K3s

Automated deployment on Proxmox VE using Ansible, in two stacks:

- **LXC stack (playbooks 00-60)** — OTEManager (article management system) across three
  containers: MinIO (S3 storage), PostgreSQL (database), and the Node.js app.
- **Kubernetes stack (playbooks 70-85)** — a single-node K3s cluster in a VM, with
  MetalLB, NFS-backed persistent storage, Traefik ingress and Headlamp.

**Further reading:**
- [docs/KUBERNETES.md](docs/KUBERNETES.md) — cluster components, VM sizing and the
  disk/image-GC trap, NFS storage, UniFi DNS, cert-manager and TLS gotchas.
- [docs/ZOER-LOCAL.md](docs/ZOER-LOCAL.md) — building Zoer on the node and
  deploying it, including the passwordless development access mode.
- [docs/OTEMANAGER.md](docs/OTEMANAGER.md) — OTEManager on K3s after its move to
  Convex, the local development loop (`scripts/otemanager-deploy.sh`), the
  Convex bootstrap steps, and backup/restore.
- [docs/EVENTSCRAPE.md](docs/EVENTSCRAPE.md) — EventScrape on K3s, why its Convex
  backend is publicly exposed, and the LXC-to-cluster data migration.
- [docs/INGRESS.md](docs/INGRESS.md) — the single naming scheme, UniFi wildcards,
  DNS-01 certificates, fronting off-cluster hosts, and the retirement of Nginx
  Proxy Manager.
- [docs/IMMICH.md](docs/IMMICH.md) — Immich v3 on K3s, the NAS-mounted library,
  the read-only and empty-database traps, and the Postgres backup CronJob.
- [docs/PAPERLESS.md](docs/PAPERLESS.md) — Paperless-ngx v3 on K3s, the mandatory
  v2.20.15 upgrade hop, the PAPERLESS_PORT collision, and backup/restore.

> **Current state (2026-09-14):** the OTEManager LXC stack is retired. CT 202 was
> destroyed on 2026-09-11, and **CTs 200 (minio) and 201 (postgres) were stopped**
> on 2026-09-14 — containers and disks kept, so they start again instantly.
> OTEManager now runs on K3s and uses **Convex for both records and files**, so it
> needs neither PostgreSQL nor S3. See [docs/OTEMANAGER.md](docs/OTEMANAGER.md).
> Playbooks `10`–`40` still rebuild the LXC stack if you ever want it back.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    Proxmox VE Host                       │
│                    10.70.20.10                           │
│                                                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │  VMID 200   │  │  VMID 201   │  │    VMID 202     │  │
│  │   MinIO     │  │  PostgreSQL │  │   OTEManager    │  │
│  │ 10.70.20.168│  │ 10.70.20.127│  │  10.70.20.116   │  │
│  │             │  │             │  │                 │  │
│  │  :9000 (S3) │  │  :5432      │  │  :3000 (web)   │  │
│  │  :9001 (UI) │  │             │  │                 │  │
│  │             │  │             │  │  S3 ──► MinIO   │  │
│  │  /data ─────┼──┼─── NAS     │  │  DB ──► Postgres│  │
│  └─────────────┘  └─────────────┘  └─────────────────┘  │
│                                                          │
│  NFS Mount: /mnt/pve/Documents/minio                     │
│  (UniFi NAS @ 10.70.20.101)                              │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │  VMID 210 — k3s-node-1 (Ubuntu 24.04)              │  │
│  │  10.70.20.50   8 cores / 12 GB / 60 GB             │  │
│  │                                                    │  │
│  │  K3s v1.31.4+k3s1 (control plane + worker)         │  │
│  │  Traefik  ──► 10.70.20.240 :80/:443 (MetalLB)      │  │
│  │  MetalLB pool: 10.70.20.240-250                    │  │
│  │  NFS CSI ──► 10.70.20.10:/mnt/nas-k8s (default SC) │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  NFS Export: /mnt/nas-k8s ──► 10.70.20.50 only           │
└──────────────────────────────────────────────────────────┘
```

### Kubernetes details

| VMID | Hostname | IP | Role | OS | Cores | RAM | Disk |
|------|----------|-----|------|-----|-------|-----|------|
| 9000 | ubuntu-2404-cloudinit | — | Cloud-init template | Ubuntu 24.04 | 2 | 2GB | 3.5GB |
| 210 | k3s-node-1 | 10.70.20.50 | K3s control plane + worker | Ubuntu 24.04 | 8 | 12GB (balloon 4GB) | 60GB |

Host capacity is the binding constraint: the mini PC is an **AMD Ryzen AI 9 HX 370**
with **12 cores / 24 threads and 27 GB RAM** — not the 60 GB some older notes claimed.
The K3s VM balloons down to 4 GB so the LXC stack keeps its headroom.

## Container Details

| VMID | Hostname | IP | Role | OS | Cores | RAM | Disk | Privileged |
|------|----------|-----|------|-----|-------|-----|------|------------|
| 200 | minio | 10.70.20.168 | S3 object storage | Debian 13 | 2 | 1GB | 8GB + NAS | Yes |
| 201 | postgres | 10.70.20.127 | PostgreSQL database | Debian 13 | 2 | 1GB | 16GB | No |
| 202 | otemanager | 10.70.20.116 | Node.js app | Debian 13 | 2 | 2GB | 16GB | No |

## Prerequisites

### On your Mac

- Ansible installed via pipx: `pipx install ansible-core`
- Python dependencies injected: `pipx inject ansible-core proxmoxer requests paramiko`
- Proxmox Ansible collection: `ansible-galaxy collection install -U community.proxmox`
- SSH key pair (`~/.ssh/id_ed25519`) copied to the Proxmox host's `ansible` user

### On Proxmox

- An `ansible` user with SSH access
- `sudo` installed (`apt install sudo`)
- Sudoers rule allowing `ansible` to run `pct` without a password:
  ```
  ansible ALL=(root) NOPASSWD: /usr/sbin/pct
  ```
  File: `/etc/sudoers.d/ansible_pct` (chmod 440)
- A Proxmox API token for `root@pam` (token name: `Ansible`, privilege separation: off)
- Debian 13 CT template downloaded (`debian-13-standard_13.1-1_amd64.tar.zst`)

### K3s prerequisites (playbooks 70-85)

- `community.proxmox` and `community.general` collections, plus `proxmoxer` and
  `requests` available to the *same* Python that runs Ansible.
- **Root SSH access to the Proxmox host.** The `ansible` user's sudoers grant covers
  `/usr/sbin/pct` only — it cannot run `qm`, install packages, or write
  `/etc/exports`. The `[proxmox_root]` inventory group exists for exactly this.
  If you would rather not use root, widen the sudoers file instead:
  ```
  ansible ALL=(root) NOPASSWD: /usr/sbin/pct, /usr/sbin/qm, /usr/bin/apt-get, /usr/sbin/exportfs
  ```
- An SSH keypair whose public half is injected into the K3s VM by cloud-init and
  whose private half Ansible uses to reach it. Set in two places that must agree:
  `k3s_vm_ssh_key_file` (role default) and `ansible_ssh_private_key_file`
  (inventory).
- **UniFi DHCP pool capped below `.240`** — see the MetalLB gotcha below.

## File Structure

```
proxmox-setup/
├── ansible.cfg                             # inventory + roles_path + become
├── inventory.ini                           # proxmox / proxmox_root / k3s groups
├── group_vars/
│   ├── proxmox.yml                         # Ansible Vault (encrypted credentials)
│   ├── proxmox.yml.example                 # template for the above
│   └── k3s.yml                             # K3s tuning (no secrets)
├── playbooks/
│   ├── 00-test-proxmox-api.yml             # Test API authentication
│   ├── 10-create-minio-lxc.yml             # Create MinIO container
│   ├── 15-bind-minio-nas.yml               # Bind NAS to MinIO /data
│   ├── 20-install-minio.yml                # Install and start MinIO
│   ├── 30-create-postgres-lxc.yml          # Create and configure PostgreSQL
│   ├── 40-create-otemanager-lxc.yml        # Create and deploy OTEManager app
│   ├── 50-setup-minio-bucket.yml           # Create S3 bucket, redeploy app
│   ├── 60-update-otemanager.yml            # Update OTEManager from GitHub
│   ├── 70-create-cloudinit-template.yml    # Ubuntu 24.04 template (VMID 9000)
│   ├── 75-setup-k8s-nfs-export.yml         # NFS export backing cluster PVs
│   ├── 80-create-k3s-cluster.yml           # VM + K3s + MetalLB/NFS-CSI/Headlamp
│   └── 85-bootstrap-flux.yml               # Flux CD GitOps (optional)
├── roles/
│   ├── k3s_vm/                             # clone template, cloud-init, start
│   ├── k3s_prepare/                        # swap off, kernel modules, sysctl
│   ├── k3s_install/                        # K3s server + fetch kubeconfig
│   ├── k3s_base_services/                  # NFS CSI, MetalLB, Headlamp
│   └── flux_bootstrap/                     # Flux CD
├── k8s/
│   ├── cert-manager/                       # ClusterIssuer + wildcard Certificate
│   │   ├── cluster-issuer.yaml             # letsencrypt-cloudflare (DNS-01)
│   │   └── wildcard-certificate.yaml       # *.k8s.overtheedgepaper.ca
│   ├── zoer-local/                         # Zoer from node-built images
│   │   ├── base/                           # manifests (fork of personalprox/k8s/zoer)
│   │   └── overlay/                        # image override -> zoer-local tags
│   ├── otemanager/                         # OTEManager + self-hosted Convex
│   │   ├── base/                           # convex, app, ingress, certificate
│   │   └── overlay/                        # image override -> otemanager-local tag
│   └── eventscrape/                        # EventScrape + self-hosted Convex
│       ├── base/                           # convex, admin, worker, dashboard
│       └── overlay/                        # image override -> eventscrape-local tags
├── scripts/
│   ├── zoer-local-build.sh                 # build on the node, import to containerd
│   ├── zoer-deploy.sh                      # dev loop: build -> apply -> verify
│   ├── zoer-create-secrets.sh              # the two Secrets the backend requires
│   ├── otemanager-local-build.sh           # build OTEManager on the node
│   ├── otemanager-bootstrap.sh             # Convex admin key, functions, secret
│   ├── otemanager-deploy.sh                # dev loop: build -> apply -> verify
│   ├── eventscrape-local-build.sh          # build admin + worker on the node
│   └── eventscrape-deploy.sh               # dev loop for EventScrape
├── docs/
│   ├── KUBERNETES.md                       # cluster settings, storage, DNS, TLS
│   ├── ZOER-LOCAL.md                       # Zoer local build + deploy + access modes
│   ├── OTEMANAGER.md                       # OTEManager on K3s + Convex bootstrap
│   └── EVENTSCRAPE.md                      # EventScrape on K3s + data migration
└── README.md
```

## Vault Variables

The encrypted `group_vars/proxmox.yml` contains:

```yaml
proxmox_api_host: "10.70.20.10"
proxmox_api_user: "root@pam"
proxmox_api_token_id: "Ansible"          # Case-sensitive!
proxmox_api_token_secret: "<secret>"
proxmox_validate_certs: false
proxmox_node: "proxmox"
minio_admin_password: "<secret>"
otemanager_db_password: "<secret>"
otemanager_postgres_ip: "10.70.20.127"
otemanager_minio_ip: "10.70.20.168"
```

Edit with: `ansible-vault edit group_vars/proxmox.yml`

The K3s playbooks reuse `proxmox_api_host`, `proxmox_api_user`, `proxmox_api_token_id`,
`proxmox_api_token_secret`, `proxmox_validate_certs` and `proxmox_node` — no new
secrets are required. Two optional additions:

| Variable | Default | Needed for |
|---|---|---|
| `proxmox_api_port` | `8006` (role default) | Only if the API moves off 8006 |
| `github_token` | unset | `85-bootstrap-flux.yml` only |

Non-secret K3s tuning (MetalLB range, NFS path, K3s version) lives unencrypted in
`group_vars/k3s.yml` so it can be reviewed in diffs.

## Playbook Run Order

Run all playbooks from `~/proxmox-setup`:

```bash
# 1. Test API connection
ansible-playbook -i inventory.ini playbooks/00-test-proxmox-api.yml --ask-vault-pass

# 2. Create MinIO container
ansible-playbook -i inventory.ini playbooks/10-create-minio-lxc.yml --ask-vault-pass

# 3. Bind NAS storage to MinIO
ansible-playbook -i inventory.ini playbooks/15-bind-minio-nas.yml --ask-vault-pass

# 4. Install MinIO service
ansible-playbook -i inventory.ini playbooks/20-install-minio.yml --ask-vault-pass

# 5. Create PostgreSQL container and database
ansible-playbook -i inventory.ini playbooks/30-create-postgres-lxc.yml --ask-vault-pass

# 6. Create OTEManager container and deploy app
ansible-playbook -i inventory.ini playbooks/40-create-otemanager-lxc.yml --ask-vault-pass

# 7. Create S3 bucket and wire up S3 storage
ansible-playbook -i inventory.ini playbooks/50-setup-minio-bucket.yml --ask-vault-pass
```

### Kubernetes stack

Order matters: **75 must run before 80.** `80` makes `nfs-nas` the cluster's default
StorageClass, and if the export does not exist yet every PVC hangs in `Pending`
forever with no useful error.

```bash
# 1. Build the Ubuntu 24.04 cloud-init template (once; skips if VMID 9000 exists)
ansible-playbook playbooks/70-create-cloudinit-template.yml --ask-vault-pass

# 2. Create the NFS export that backs cluster PersistentVolumes
ansible-playbook playbooks/75-setup-k8s-nfs-export.yml --ask-vault-pass

# 3. Create the VM, install K3s, deploy base services
ansible-playbook playbooks/80-create-k3s-cluster.yml --ask-vault-pass

# 4. Optional — GitOps. Needs `github_token` in the vault.
ansible-playbook playbooks/85-bootstrap-flux.yml --ask-vault-pass
```

`ansible.cfg` sets `inventory = inventory.ini`, so `-i inventory.ini` is now optional.

### Using the cluster

`80-create-k3s-cluster.yml` writes `kubeconfig.yml` to the project root and patches
the server address to the VM's real IP:

```bash
export KUBECONFIG=$(pwd)/kubeconfig.yml
kubectl get nodes
```

Headlamp is a ClusterIP service, so reach it with a port-forward:

```bash
kubectl port-forward -n headlamp svc/headlamp 8080:80    # http://localhost:8080
kubectl create token headlamp --namespace headlamp --duration=87600h
```

## Lessons Learned / Gotchas

### Proxmox API Token

- **Token ID is case-sensitive.** Proxmox created `Ansible` (capital A) but we initially used `ansible` (lowercase), which caused 401 errors.
- **`api_token_id` should be just the token name** (e.g., `Ansible`), not the full `user!token` format. The Ansible module combines `api_user` + `api_token_id` internally. Using `root@pam!Ansible` resulted in the module constructing `root@pam!root@pam!Ansible`.
- The token secret is **only shown once** at creation time. If you lose it, delete and recreate the token.

### Container Creation

- The `disk` parameter must use the `storage:size` format (e.g., `local-lvm:8`), not just a number. Using just a number triggers "Only root can pass arbitrary filesystem paths" with API tokens.
- The `state: started` task requires the `hostname` parameter to identify the container.
- VMID conflicts: always check `pct list` before picking an ID. VMID 115 looked free but was already a VM.

### NFS + Unprivileged Containers (the big one)

- **Unprivileged LXCs remap UIDs** (container UID 0 = host UID 100000). NFS with `root_squash` (default) blocks `chown` from remapped UIDs, making it impossible to fix file ownership.
- **`chmod 777` doesn't help** — even with world-writable permissions, MinIO performs stricter ownership checks and refuses to start.
- **Solution: use a privileged container** for MinIO when the backend is NFS. Privileged containers don't remap UIDs, so root inside = root on host. Since LXC containers are still isolated (not bare metal), this is an acceptable tradeoff for NFS-backed storage.
- After switching to privileged, we had to wipe the old `.minio.sys` directory (owned by the previous unprivileged UID mapping) from the Proxmox host shell before MinIO would start cleanly.

### MinIO on NFS

- Even in a privileged container, NFS `root_squash` maps root writes to `nobody:nogroup`. MinIO still failed with "Unable to write to the backend" despite `777` permissions.
- **Fix:** Run MinIO as root inside the privileged container and set `/data` to `777`. The combination of privileged container + world-writable NFS directory allows MinIO to function.
- MinIO environment variables are stored in `/etc/default/minio` (read via `EnvironmentFile` in the systemd unit) rather than inline `Environment=` directives, which avoids shell escaping issues with special characters in passwords.

### SSH / sudo

- Proxmox doesn't ship with `sudo` — had to install it (`apt install sudo`).
- The `ansible` user's sudoers rule only covers `/usr/sbin/pct`, not `chown` or other commands. Host-level operations (like fixing NFS ownership) must be done from the Proxmox web UI shell as root.
- Don't include `:8006` in SSH targets — that's the Proxmox web UI port, not SSH.

### Ansible Vault

- Ansible auto-detects encrypted files in `group_vars/` and tries to decrypt them for every playbook run, even if the playbook doesn't use vault variables. Always pass `--ask-vault-pass`.
- Special characters (backslashes, etc.) in vault values can break YAML parsing. Use single quotes for passwords with special characters.

### Git Clone in Containers

- `git clone` inside LXC containers can appear to hang — it's just slow due to network/DNS resolution in the container. Be patient.
- If `npm install` runs before `git pull`, the modified `package-lock.json` blocks the pull. Use `git checkout -- .` before `git pull` to discard local changes.

### OTEManager S3 Integration

- The app had a storage abstraction layer already in place (`StorageProvider` interface) but the S3 implementation was stubbed out.
- We implemented `storage/s3.ts` using `@aws-sdk/client-s3` with `forcePathStyle: true` (required for MinIO compatibility).
- The factory in `storage/index.ts` auto-selects S3 vs local storage based on whether `S3_BUCKET` and `AWS_ACCESS_KEY_ID` environment variables are set.

### K3s: the default StorageClass can point at nothing (the big one)

`k3s_base_services` demotes `local-path` and makes `nfs-nas` the cluster default. If
the NFS export does not exist, **nothing errors at install time.** Helm succeeds, the
StorageClass appears, pods start. The failure only shows up later: every PVC sits in
`Pending`, and the CSI events are vague about why. Run `75-setup-k8s-nfs-export.yml`
first, and smoke-test with a throwaway PVC before trusting the cluster:

```bash
kubectl get sc            # nfs-nas should be (default)
kubectl get pvc -A        # nothing should linger in Pending
```

### K3s: VMID collisions

The K3s VM defaults to **210**, not 200. VMIDs 100-114 and 200-206 belong to the LXC
stack — `200` is `minio` and `201` is `postgres`. Same lesson as the VMID 115 case
above: always check `pct list` **and** `qm list` before choosing an ID.

### K3s: MetalLB vs DHCP

MetalLB hands out `10.70.20.240-250` from the same flat subnet the LXCs use. If the
UniFi DHCP pool also covers that range, MetalLB and DHCP will eventually assign the
same address. The symptom is intermittent unreachability that looks like an ARP or
L2 bug. Cap the DHCP pool below `.240` in the UniFi controller first.

### K3s: `connection: local` loses to the inventory

A play that declares `connection: local` is still overridden by `ansible_connection`
set on the host in the inventory. An API-only playbook will try to SSH and fail with
`UNREACHABLE`. Set it as a play **var** instead:

```yaml
- hosts: proxmox
  become: false
  vars:
    ansible_connection: local
```

Also set `become: false` there — `ansible.cfg` applies `become = True` globally, and
sudoing for a local HTTP call is pointless at best.

### K3s: NFS export scope and `no_root_squash`

The export uses `no_root_squash` because the NFS CSI driver must `chown` the volume
directories it provisions — the same UID-remapping family of problem as the MinIO
case above, from the other direction. It is scoped to `10.70.20.50/32` rather than
`10.70.20.0/24`: a subnet-wide export would give every host on the LAN read-write
access to every PersistentVolume in the cluster.

### K3s: storage is local-disk-backed, not NAS-backed

`/mnt/nas-k8s` is a plain directory on `pve-root` (**94 GB total, ~82 GB free**), not
a NAS share. The UNAS Pro restricts each export to a client allow-list that currently
holds only `10.70.20.10`, and it has no K8s share at all — it exports `Images`,
`Article`, `Documents` and `Immich`. To move cluster volumes onto the NAS, either add
a K8s share and re-export it through Proxmox (needs `fsid=`, and nested NFS
re-export is fragile), or add `10.70.20.50` to the NAS allow-list and point the
StorageClass straight at `10.70.20.101`.

### Proxmox has two addresses — do not confuse them

The web UI and the host itself are not the same address. **SSH always targets
`10.70.20.10`**, never whatever answers the web name.

| Purpose | Address |
|---|---|
| SSH, and the direct API | `10.70.20.10` (`:8006` for the UI) |
| Proxied web UI | `https://proxmox.k8s.overtheedgepaper.ca` → Traefik at `10.70.20.240` |

Historically the web name pointed at `10.70.20.104` (Nginx Proxy Manager), and
SSH to `.104` failed with `Permission denied` because it was a different machine
with a different host key. NPM is retired, but the rule is unchanged: the proxy
address is not the host address. See [docs/INGRESS.md](docs/INGRESS.md).

## Access Points

| Service | URL | Credentials |
|---------|-----|-------------|
| OTEManager | http://otemanager.k8s.ote · https://otemanager.k8s.overtheedgepaper.ca | Now on K3s (CT 202 retired) |
| MinIO Console | http://10.70.20.168:9001 | **CT 200 stopped** — admin / (vault password) |
| MinIO S3 API | http://10.70.20.168:9000 | **CT 200 stopped** |
| PostgreSQL | 10.70.20.127:5432 | **CT 201 stopped** — otemanager / (vault password) |
| Proxmox UI | https://10.70.20.10:8006 | root / (your password) |
| Proxmox UI (via Traefik) | https://proxmox.k8s.overtheedgepaper.ca | root / (your password) |
| Immich | http://immich.k8s.ote · https://immich.k8s.overtheedgepaper.ca | v3.2.1 on K3s (CT 100 stopped) |
| Paperless-ngx | http://paperless.k8s.ote · https://paperless.k8s.overtheedgepaper.ca | v3.1.3 on K3s (CT 102 stopped) |
| EventScrape | http://events.k8s.ote · https://events.k8s.overtheedgepaper.ca | On K3s (CT 106 stopped) |
| Zoer | http://zoer.k8s.ote · https://zoer.k8s.overtheedgepaper.ca | Built on the node |
| K3s API | https://10.70.20.50:6443 | `kubeconfig.yml` in project root |
| Traefik ingress | http://10.70.20.240 / https://10.70.20.240 | — |
| Headlamp | `kubectl port-forward -n headlamp svc/headlamp 8080:80` | service-account token |

## Updating OTEManager

After pushing code changes to GitHub:

```bash
ansible-playbook -i inventory.ini playbooks/60-update-otemanager.yml --ask-vault-pass
```

This playbook:
1. Checks for available updates (shows commit messages)
2. Pulls latest code from GitHub (only if updates exist)
3. Installs npm dependencies
4. Runs database migrations (`drizzle-kit push --force`)
5. Rebuilds the application
6. Restarts the service
7. Verifies the service is running and shows current version

**Options:**
- Run with migrations: `ansible-playbook -i inventory.ini playbooks/60-update-otemanager.yml --ask-vault-pass -e run_migrations=true`

**Note:** Migrations are disabled by default since they can hang in non-interactive mode. Run migrations manually when schema changes:
```bash
ssh ansible@10.70.20.10 "sudo pct exec 202 -- bash -lc 'cd /opt/otemanager && npx drizzle-kit push'"
```

**Note:** The playbook skips the build/restart steps if there are no updates available.

## Backup & Restore

### In-app backup (via OTEManager UI)

The app has a built-in backup/restore page at `/utilities/backup` that:
- **Export:** dumps all database records + downloads all files from MinIO into a ZIP
- **Import:** reads a ZIP, inserts data into Postgres, uploads files to MinIO

### Manual backup

**PostgreSQL dump:**
```bash
ssh ansible@10.70.20.10 "sudo pct exec 201 -- bash -lc 'su - postgres -c \"pg_dumpall\"'" > pg_dumpall.sql
```

**MinIO files (already on NAS):** files live at `/mnt/pve/Documents/minio` on the Proxmox host, which is your UniFi NAS via NFS. Back up the NAS separately.

### Manual restore

**1. Copy SQL dump to Proxmox host and push into the Postgres container:**
```bash
scp pg_dumpall.sql ansible@10.70.20.10:/tmp/pg_dumpall.sql
ssh ansible@10.70.20.10 "sudo pct push 201 /tmp/pg_dumpall.sql /tmp/pg_dumpall.sql"
```

**2. Restore the database:**
```bash
ssh ansible@10.70.20.10 "sudo pct exec 201 -- bash -lc 'su - postgres -c \"psql -f /tmp/pg_dumpall.sql\"'"
```

**3. Grant permissions** (the dump may create tables owned by a different user):
```bash
ssh ansible@10.70.20.10 "sudo pct exec 201 -- bash -lc \"su - postgres -c \\\"psql -d otemanager -c 'GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO otemanager; GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO otemanager;'\\\"\""
```

**4. Upload files to MinIO** (install `mc` on your Mac first: `brew install minio/stable/mc`):
```bash
mc alias set minio http://10.70.20.168:9000 admin YOUR_MINIO_PASSWORD
mc cp --recursive /path/to/backup/uploads/ minio/ote-articles/
```

**5. Restart OTEManager:**
```bash
ssh ansible@10.70.20.10 "sudo pct exec 202 -- systemctl restart otemanager"
```

## OTEManager Code Changes

The following changes were made to the OTEManager app to support this infrastructure:

| File | Change |
|------|--------|
| `storage/s3.ts` | New S3 storage provider using `@aws-sdk/client-s3` with MinIO (`forcePathStyle: true`) |
| `storage/index.ts` | Updated factory to auto-select S3 provider when `S3_BUCKET` + `AWS_ACCESS_KEY_ID` are set |
| `storage/types.ts` | Added `saveFile()` method to `StorageProvider` interface (for backup restore) |
| `storage/local.ts` | Added `saveFile()` implementation |
| `app/routes/api/files.$.ts` | Fixed wildcard param: `params._splat` instead of `params._` (TanStack Start) |
| `app/components/article/PhotoGallery.tsx` | Changed file URLs from `/uploads/` to `/api/files/` |
| `app/components/article/DocumentList.tsx` | Changed file URLs from `/uploads/` to `/api/files/` |
| `app/routes/index.tsx` | Added `suppressHydrationWarning` to fix SSR hydration mismatch on relative time |

## Vault Template

A template is provided at `group_vars/proxmox.yml.example`. To create your vault:

```bash
cp group_vars/proxmox.yml.example group_vars/proxmox.yml
ansible-vault encrypt group_vars/proxmox.yml
```

Then edit with `ansible-vault edit group_vars/proxmox.yml` and fill in real values.

To avoid typing the password on every run, put it in a file and point `ansible.cfg`
at it (the commented `vault_password_file` line), then `chmod 600` that file and keep
it **outside** the repo.

## Future Considerations

- **Static IPs:** Containers currently use DHCP. Consider assigning static IPs so the vault variables don't need updating if a container restarts with a new address.
- **Semaphore/AWX:** Now that playbooks are working, they can be imported into a web UI for button-click deploys, scheduling, and logs.
- **Reverse proxy:** Done — Traefik in the cluster serves everything and NPM (VMID 108) is stopped. See [docs/INGRESS.md](docs/INGRESS.md).
- **NFS export tuning:** Consider `no_root_squash` or `anonuid/anongid` on the UniFi NAS for cleaner MinIO permissions.
