# Proxmox Ansible Setup — OTEManager Infrastructure

Automated deployment of OTEManager (article management system) on Proxmox VE using Ansible. Three LXC containers running MinIO (S3 storage), PostgreSQL (database), and the OTEManager Node.js application.

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
└──────────────────────────────────────────────────────────┘
```

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

## File Structure

```
proxmox-setup/
├── inventory.ini                           # Proxmox host definition
├── group_vars/
│   └── proxmox.yml                         # Ansible Vault (encrypted credentials)
├── playbooks/
│   ├── 00-test-proxmox-api.yml             # Test API authentication
│   ├── 10-create-minio-lxc.yml             # Create MinIO container
│   ├── 15-bind-minio-nas.yml               # Bind NAS to MinIO /data
│   ├── 20-install-minio.yml                # Install and start MinIO
│   ├── 30-create-postgres-lxc.yml          # Create and configure PostgreSQL
│   ├── 40-create-otemanager-lxc.yml        # Create and deploy OTEManager app
│   └── 50-setup-minio-bucket.yml           # Create S3 bucket, redeploy app
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

## Access Points

| Service | URL | Credentials |
|---------|-----|-------------|
| OTEManager | http://10.70.20.116:3000 | N/A (no auth yet) |
| MinIO Console | http://10.70.20.168:9001 | admin / (vault password) |
| MinIO S3 API | http://10.70.20.168:9000 | admin / (vault password) |
| PostgreSQL | 10.70.20.127:5432 | otemanager / (vault password) |
| Proxmox UI | https://10.70.20.10:8006 | root / (your password) |

## Redeploying OTEManager

After pushing code changes to GitHub:

```bash
ansible-playbook -i inventory.ini playbooks/50-setup-minio-bucket.yml --ask-vault-pass
```

This pulls latest code, installs dependencies, rebuilds, and restarts the service.

## Future Considerations

- **Static IPs:** Containers currently use DHCP. Consider assigning static IPs so the vault variables don't need updating if a container restarts with a new address.
- **Semaphore/AWX:** Now that playbooks are working, they can be imported into a web UI for button-click deploys, scheduling, and logs.
- **Backups:** PostgreSQL dumps and MinIO data (already on NAS) should be included in a backup strategy.
- **Reverse proxy:** Route through your existing Nginx Proxy Manager (VMID 108) for HTTPS and clean URLs.
- **NFS export tuning:** Consider `no_root_squash` or `anonuid/anongid` on the UniFi NAS for cleaner MinIO permissions.
