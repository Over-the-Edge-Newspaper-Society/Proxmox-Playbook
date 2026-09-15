# Ingress, DNS and certificates

Every self-hosted web app is reached through **Traefik in the k3s cluster**.
Nginx Proxy Manager is retired.

## Naming

One scheme, no exceptions:

| Form | Example | TLS | Served by |
|---|---|---|---|
| `<app>.k8s.overtheedgepaper.ca` | `immich.k8s.overtheedgepaper.ca` | yes, Let's Encrypt | Traefik `websecure` |
| `<app>.k8s.ote` | `immich.k8s.ote` | no | Traefik `web` |

Bare `<app>.overtheedgepaper.ca` names no longer exist. They were NPM-only and
were removed when it was retired.

Nothing resolves on public DNS. Both suffixes are UniFi local records:

```
*.k8s.ote                  A  10.70.20.240
*.k8s.overtheedgepaper.ca  A  10.70.20.240
```

`10.70.20.240` is the MetalLB address of the Traefik Service. A new app needs
**no DNS change** -- the wildcards already cover it.

## Certificates

cert-manager, `letsencrypt-cloudflare` ClusterIssuer, **DNS-01** via the
Cloudflare API. DNS-01 matters here: the A records point at a private address
and are not publicly resolvable, so HTTP-01 could never work. DNS-01 only needs
a `_acme-challenge` TXT record, which cert-manager writes through the API.

A wildcard for `*.k8s.overtheedgepaper.ca` already exists
(`k8s-overtheedgepaper-wildcard`), so per-app `Certificate` objects are
optional. Each app currently has its own for isolation.

## Reaching something OUTSIDE the cluster

Traefik can front a plain LAN address -- see `k8s/infra/base/proxmox.yaml`.
The pattern is a `Service` with **no selector** plus hand-written endpoints.

Two traps, both of which cost real time:

**1. Use `Endpoints`, not `EndpointSlice`.** k3s ships Traefik **2.11**, whose
Kubernetes provider reads only `core/v1` `Endpoints`. A hand-written
`discovery.k8s.io/v1` `EndpointSlice` is ignored completely; Traefik logs
`Cannot create service: endpoints not found` and the route returns **404**.
EndpointSlice support arrived in Traefik v3. The mirroring controller copies
`Endpoints` into a slice automatically, so this is also v3-ready.

**2. A self-signed backend needs an `IngressRoute`, not an `Ingress`.** The
documented annotation

```yaml
traefik.ingress.kubernetes.io/service.serverstransport: infra-insecure-backend@kubernetescrd
```

is **silently ignored** by Traefik 2.11 on a plain `Ingress` -- no warning, no
log line. `traefik.ingress.kubernetes.io/service.serversscheme: https` *is*
honoured, so Traefik dials the backend over TLS, fails to verify the
self-signed certificate, and returns **500**. Traefik's own API confirms it:

```bash
kubectl -n kube-system port-forward deploy/traefik 9111:9000
curl -s localhost:9111/api/http/services | jq '.[] | select(.name|test("proxmox"))'
#   "serversTransport": null      <-- annotation dropped
```

The `IngressRoute` CRD takes `serversTransport` as a real field, and works.

## Proxmox UI, and the circular dependency

`proxmox.k8s.overtheedgepaper.ca` is proxied by Traefik -- which runs in VM
**210**, which runs **on that hypervisor**. If the k3s node is down, so is the
name you would use to fix it.

> **Break-glass: `https://10.70.20.10:8006`.** Always works, never depends on
> the cluster. Keep it bookmarked. Expect a self-signed certificate warning --
> that is correct and expected; only the Traefik hop has a real certificate.

## Retired

CT 108 (`nginxproxymanager`) is **stopped, not destroyed**. It held eight proxy
hosts; at retirement five upstreams were already dead and three had moved into
the cluster:

| Hostname | Upstream | Disposition |
|---|---|---|
| `Immich.overtheedgepaper.ca` | `10.70.20.132:2283` | in cluster |
| `paperless.overtheedgepaper.ca` | `10.70.20.198:8000` | in cluster |
| `Eventscrape.overtheedgepaper.ca` | `10.70.20.139:80` | in cluster |
| `proxmox.overtheedgepaper.ca` | `10.70.20.10:8006` | in cluster (`infra` ns) |
| `homarr.overtheedgepaper.ca` | `10.70.20.153:7575` | upstream gone |
| `komodo.overtheedgepaper.ca` | `10.70.20.171:9120` | upstream gone |
| `jetkvm.overtheedgepaper.ca` | `10.70.20.109:80` | upstream gone |
| `npm.overtheedgepaper.ca` | itself | gone with it |

Also stopped as redundant: **CT 104** (Tika) and **CT 105** (Gotenberg), both
replaced by in-cluster Deployments in the `paperless` namespace.

To roll back: `pct start 108`, then repoint the UniFi records at
`10.70.20.104`.
