# K3s cluster — build, settings, and operations

Single-node K3s cluster on the Proxmox host, built by playbooks `70`–`85`.
This document covers what exists, why each setting is what it is, and the traps
that cost time.

Last verified: 2026-09-11.

## What is deployed

| Component | Version | Notes |
|---|---|---|
| K3s | v1.31.4+k3s1 | control plane + worker on one node |
| Traefik | v2.11.10 | bundled with K3s; holds a MetalLB IP |
| MetalLB | v0.14.9 | L2 mode, pool `10.70.20.240-250` |
| NFS CSI driver | v4.9.0 | provides the default StorageClass |
| Headlamp | chart 0.25.0 / app v0.25.1 | ClusterIP, not exposed |
| cert-manager | v1.21.2 | Let's Encrypt via Cloudflare DNS-01 |

## Addresses

| Address | What |
|---|---|
| `10.70.20.10` | Proxmox host. SSH + NFS server for the cluster. |
| `10.70.20.50` | `k3s-node-1` (VMID 210). Kubernetes API on `:6443`. |
| `10.70.20.240` | Traefik, via MetalLB. **All ingress traffic goes here.** |
| `10.70.20.240-250` | MetalLB pool. |
| `10.70.20.101` | UNAS Pro. Exports are IP allow-listed. |
| `10.70.20.104` | Nginx Proxy Manager (CT 108), **retired and stopped**. Kept only so the address is not reused. |

## VM sizing and the disk trap

VMID 210: 8 cores, **18 GB** ceiling / **10 GB** balloon floor, **250 GB** disk.

Both were grown after the fact: the disk 60 → 120 → 250 GB, and memory
12 → 18 GB. Note that PVE `memory` is the **boot-time** size — there is no
hot-add here, so raising it needs a full stop and start, not a reboot.

### `balloon` is a floor the host can pull you down to

`memory` is a ceiling, not an allocation. `balloon` is the **floor**, and the
host reclaims everything in between whenever it is short. The guest can be
running with far less RAM than `qm config` implies, and nothing in the guest
says so.

The floor was 4096. Under host pressure the balloon squeezed the node down to
**5.3 GB with 145 MB free** and 5.8M major page faults — the API server and SSH
both stopped answering. `free -m` inside the guest reported a 5.3 GB machine.

Check the real number from the host, not the guest:

```bash
echo "info balloon" | qm monitor 210
# balloon: actual=18432 max_mem=18432 total_mem=... free_mem=10162
```

Raising the target live is also the gentlest way out of that state — it gives
the guest enough memory to become responsive again, so you can fix the cause
instead of hard-resetting:

```bash
echo "balloon 9216" | qm monitor 210     # live, temporary
qm set 210 -balloon 10240                # persistent floor
```

The floor is now 10240, which is comfortable: the host has 27.7 GB and roughly
14 GB is committed.

The disk started at 60 GB and that was not enough. A full Zoer image build
produces roughly 16 GB of Docker layers plus separate containerd copies, which
pushed the node to 88% full. Two things break at that point:

1. **Kubelet garbage-collects images above 85%** (k3s default
   `image-gc-high-threshold`). It evicted a locally built image that no running
   pod referenced, and the first symptom was a deployment failing to find an
   image that had "definitely" been built.
2. Zoer's own build script refuses to start below **15 GiB free**.

Growing the disk is online and safe:

```bash
# on the Proxmox host
qm disk resize 210 scsi0 120G

# inside the VM
echo 1 | sudo tee /sys/class/block/sda/device/rescan
sudo growpart /dev/sda 1
sudo resize2fs /dev/sda1
```

Protect locally built images that no pod currently references:

```bash
sudo k3s ctr -n k8s.io images label <image> io.cri-containerd.pinned=pinned
```

## Storage

`nfs-nas` is the default StorageClass, `reclaimPolicy: Retain`. It points at
`10.70.20.10:/mnt/nas-k8s`, an NFS export served by the **Proxmox host**.

> **`/mnt/nas-k8s` is a local directory on `pve-root`, not the NAS.**
> Every UNAS Pro export is restricted to a client allow-list containing only
> `10.70.20.10`, and the NAS has no K8s share — it exports `Images`, `Article`,
> `Documents`, `Immich` and nothing else. So cluster volumes live on the Proxmox
> root filesystem (94 GB) and are **not** redundant.
>
> To move them onto the NAS: either create a K8s share and add `10.70.20.10` to
> its allow-list then re-export through Proxmox (needs `fsid=`; nested NFS
> re-export is fragile), or add `10.70.20.50` to the NAS allow-list and point the
> StorageClass straight at `10.70.20.101`.

`no_root_squash` is required on the export — the CSI driver `chown`s each
volume directory it provisions. The export is scoped to `10.70.20.50/32`, not
the whole subnet, so other LAN hosts cannot read every cluster volume.

**Always smoke-test storage after changes.** A StorageClass pointing at a
non-existent export fails silently: Helm succeeds, pods start, and only PVCs
hang in `Pending`.

```bash
kubectl get sc              # nfs-nas should be (default)
kubectl get pvc -A          # nothing should sit in Pending
```

## DNS

Traefik routes by hostname, so every service needs a name resolving to
`10.70.20.240`. Records live on the **UniFi gateway** (Dream Machine Pro Max) as
local DNS records — split-horizon, so internal IPs stay out of public DNS.

| Type | Hostname | Value |
|---|---|---|
| A | `*.k8s.ote` | `10.70.20.240` |
| A | `*.k8s.overtheedgepaper.ca` | `10.70.20.240` |

Wildcards work on this gateway — verified by resolving a hostname that has no
Ingress behind it and getting a Traefik 404 rather than NXDOMAIN. That means
**new services need no DNS work**, only an Ingress.

`.k8s.ote` is a made-up suffix for plain HTTP. `.k8s.overtheedgepaper.ca` is a
real domain and is the one with TLS.

These two wildcards are now the **only** records. The per-host bare names
(`immich.overtheedgepaper.ca` and friends) pointed at Nginx Proxy Manager and
were deleted when it was retired — see [INGRESS.md](INGRESS.md), which also
covers fronting hosts that live outside the cluster.

## TLS

cert-manager issues certificates from Let's Encrypt using the **DNS-01**
challenge through Cloudflare. DNS-01 proves control of the *domain*, not the
host, so it works for services that are not publicly reachable.

```
k8s/cert-manager/cluster-issuer.yaml        ClusterIssuer: letsencrypt-cloudflare
k8s/cert-manager/wildcard-certificate.yaml  Certificate:   *.k8s.overtheedgepaper.ca
```

Setup:

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml

# Cloudflare token: Zone:DNS:Edit, scoped to overtheedgepaper.ca only
kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token='<TOKEN>'

kubectl apply -f k8s/cert-manager/cluster-issuer.yaml
kubectl apply -f k8s/cert-manager/wildcard-certificate.yaml
```

Renewal is automatic at ~2/3 of lifetime. Check with:

```bash
kubectl get clusterissuer letsencrypt-cloudflare
kubectl -n zoer get certificate
```

### Two TLS traps

**A wildcard matches exactly one label.** `*.overtheedgepaper.ca` covers
`zoer.overtheedgepaper.ca` but **not** `zoer.k8s.overtheedgepaper.ca`. The
two-level scheme needs its own `*.k8s.overtheedgepaper.ca` certificate. The
certificate also lists the bare `k8s.overtheedgepaper.ca` separately, because a
wildcard never matches the name it is rooted at.

**`.ote` can never have a real certificate.** It is not a real TLD, so no public
CA will ever issue for it. Use `.k8s.overtheedgepaper.ca` for HTTPS, or stand up
an internal CA and install its root on every device.

**An Ingress needs a `tls:` block, not just the annotation.** The Zoer HTTPS
ingresses had `traefik.ingress.kubernetes.io/router.tls: "true"` but no `tls:`
section, so Traefik served its own self-signed default certificate and browsers
warned. The annotation selects the entrypoint; the `tls:` block names the
secret:

```yaml
spec:
  ingressClassName: traefik
  tls:
    - secretName: k8s-overtheedgepaper-tls
      hosts:
        - zoer.k8s.overtheedgepaper.ca
```

Verify with certificate validation **on** (no `-k`) — `ssl_verify=0` means it
validated against the public trust store:

```bash
curl -s -o /dev/null -w "%{http_code} ssl_verify=%{ssl_verify_result}\n" \
  https://zoer.k8s.overtheedgepaper.ca/
```

### The NAS exports exact subpaths, not share roots

The UNAS Pro allow-list grants each client a **specific path**, not the share
above it. Mounting the share root is refused even though a path inside it works
fine:

```
Images/.data/immich/data   mounts        <- what the Immich PV uses
Images                     access denied
Immich                     access denied
```

So the cluster cannot browse or clean up anything outside the exact exported
directories. Housekeeping elsewhere on a share -- an orphaned folder, a stray
upload directory -- has to be done through the UniFi UI or SMB, or by adding
that path to the allow-list first.

### Do NOT run a recursive scan of a NAS share from a pod

A `du -sh` / `find` across a whole share stats every file over NFS. The dentry
and inode cache that generates is charged to the node, and on a ballooned VM
there is far less headroom than `qm config` suggests.

Doing this took the cluster down: load hit **226**, the API server and SSH both
went unreachable for ~15 minutes.

If a scan is genuinely needed: give the pod a `resources.limits.memory`, use
`-maxdepth`, and prefer `ls` over recursive `du`. Better, run it somewhere that
is not the Kubernetes node.

## Operational gotchas

### `kubectl apply -k` can take a service down

Images built on the node are tagged at build time and patched into the **live**
Deployment by the deploy script. The manifests in `k8s/*/base` keep
`:placeholder`, which is not a real tag.

So applying a whole base re-applies `:placeholder`, and the Deployment rolls to
a pod that can never start:

```
docker.io/eventscrape-local/worker:placeholder   ImagePullBackOff
```

This is not hypothetical -- reapplying `eventscrape/base` to fix an unrelated
namespace mistake put the worker in ImagePullBackOff for 70 minutes. The admin
UI kept answering 200 from its old ReplicaSet, so nothing looked wrong from
outside.

Affected: `eventscrape-admin`, `eventscrape-worker`, `otemanager`.

- To change one file, apply **that file**, not the base:
  `kubectl apply -f k8s/eventscrape/base/ingress.yaml`
- To deploy code, use the script.
- To recover:

```bash
k3s ctr -n k8s.io images ls -q | grep eventscrape     # find the real tag
kubectl -n eventscrape set image deploy/eventscrape-worker \
  '*=docker.io/eventscrape-local/worker:<tag>'
```

Check for it with a server dry-run, which reports drift without changing
anything:

```bash
kubectl apply -k k8s/eventscrape/base --dry-run=server
```


**A ConfigMap edit does not restart pods.** After changing the nginx CSP config,
the manifest said one thing and the wire said another for several minutes. If
config "should have applied" but has not, check the actual response and then
`kubectl rollout restart deploy/<name>`.

**`kubectl apply` of a changed Ingress is instant; a Deployment env change rolls
pods.** Expect a brief 502 through Traefik while the old pod terminates and the
endpoint list catches up.

**The `ansible` user cannot run `qm`.** Its sudoers grant is `/usr/sbin/pct`
only. The K3s playbooks use the `[proxmox_root]` inventory group over root SSH
for `qm`, package installs, and `/etc/exports`.
