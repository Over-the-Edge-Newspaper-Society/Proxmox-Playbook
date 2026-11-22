# Zoer BypassV3 token helper

Browserless generator for reCAPTCHA v3 tokens, vendored from
[`EvickaStudio/BypassV3`](https://github.com/EvickaStudio/BypassV3)
(Apache-2.0). Used from this repo to drive end-to-end tests of a Zoer-owned
backend's reCAPTCHA v3 verification without spinning up Chromium, CloakBrowser,
or BlitzBrowser.

The vendored library is a pure-Python HTTP client. It calls Google's reCAPTCHA
anchor and reload endpoints directly, extracts the response token, and returns
it. No browser runtime is involved on either side.

## Scope

Upstream's README limits use to "applications you own or are authorized to
test." This vendored copy sits in `scripts/bypassv3/` for that reason only:
exercising a reCAPTCHA v3 verifier on a Zoer-owned test app (your own backend,
your own site key, your own origin).

Do not use the generated tokens against third-party sites' bot protection.
That is outside upstream's scope and outside why this copy is in the repo.

## Layout

| Path | Purpose |
|---|---|
| `scripts/bypassv3/bypass.py` | Verbatim upstream library |
| `scripts/bypassv3/__init__.py` | Re-exports `ReCaptchaV3Bypass`, carries the scope note |
| `scripts/bypassv3/cli.py` | Importable `main()` for the token CLI |
| `scripts/bypassv3/LICENSE` | Apache-2.0 full text |
| `scripts/bypassv3/NOTICE.md` | Upstream URL, pinned commit, update recipe |
| `scripts/zoer-bypassv3-token.py` | Executable shim that delegates to `bypassv3.cli.main()` |
| `k8s/zoer-local/base/bypassv3.yaml` | Deployment + Service for the in-cluster helper |
| `k8s/zoer-local/base/bypassv3/bypass.py` | Byte-equal copy of the vendored library (kustomize cannot reach `scripts/`) |
| `k8s/zoer-local/base/bypassv3/server.py` | Stdlib HTTP service that wraps the library |
| `k8s/zoer-local/base/bypassv3/requirements.txt` | Pinned `requests==2.34.2`, installed at pod start |
| `k8s/zoer-local/base/bypassv3/NOTICE.md` | Points back at `scripts/bypassv3/` for attribution |
| `tests/test_zoer_bypassv3_token.py` | Vendor-layout checks and CLI tests against mocked network |
| `tests/test_zoer_bypassv3_service.py` | ConfigMap-copy sha256 check, manifest shape, ephemeral HTTP server tests |

## Requirements

- Python 3.12+ (the upstream library uses `str | None`, `str.removeprefix`,
  and walrus in a few spots).
- `requests` on the Python path. The existing Zoer scripts assume it; if your
  venv lacks it, `pip install 'requests>=2.34.2'`.

## Usage

Site-key mode resolves the anchor URL by hitting `api.js`/`enterprise.js` to
learn the current reCAPTCHA JS release, then pulls a token:

```bash
./scripts/zoer-bypassv3-token.py \
  --site-key <YOUR_TEST_APP_SITE_KEY> \
  --origin https://app.k8s.ote \
  --action login
```

Anchor-URL mode skips version resolution; paste the full anchor URL from a real
browser's network tab if you already have one captured:

```bash
./scripts/zoer-bypassv3-token.py \
  --anchor-url 'https://www.google.com/recaptcha/api2/anchor?ar=1&k=...&co=...&hl=en&v=...&size=invisible'
```

Both modes print the token on stdout and exit `0`, or print a `no token`
message on stderr and exit `1`. Pipe the token into whatever drives the test
request:

```bash
TOKEN=$(./scripts/zoer-bypassv3-token.py --site-key "$KEY" --origin https://app.k8s.ote --action login)
curl -fsS -X POST "https://app.k8s.ote/api/login" \
  --data-urlencode "g-recaptcha-response=$TOKEN" \
  --data-urlencode "email=test@example.test"
```

Flags:

- `--site-key` / `--anchor-url` — one is required; mutually exclusive.
- `--origin` — required with `--site-key`. Must be the scheme-and-host the
  test app serves from (what the browser would send as `Origin`).
- `--action` — the reCAPTCHA v3 action bound into the token (e.g. `login`,
  `submit`). Must match what the verifying backend expects.
- `--enterprise` — resolve against the reCAPTCHA Enterprise endpoint.
- `--max-retries` — attempts before giving up (default 3).

## In-cluster service (`zoer-bypassv3`)

For automation that drives Zoer's browser pods (CloakBrowser, BlitzBrowser) to
exercise a reCAPTCHA v3 flow on a Zoer-owned test app, a small HTTP service
runs alongside the browsers in the `zoer` namespace. The service is
browserless: it calls Google's reCAPTCHA endpoints directly and returns a
token.

- **Deployment / Service:** `zoer-bypassv3` on `ClusterIP` port 8080. No
  Ingress — the service is reachable only from inside the cluster.
- **Image:** stock `python:3.12-slim` pinned by digest; Python code is mounted
  from the kustomize-generated ConfigMap `zoer-bypassv3-app`. `requests` is
  `pip install --user --no-cache-dir`-ed on pod start (needs PyPI egress).
- **Endpoints:**
  - `GET /healthz` → `200 {"ok": true}` (used by both readiness and liveness
    probes).
  - `POST /token` with a JSON body of either shape; returns `200 {"token": "..."}`
    on success or `4xx`/`5xx` with an `error` string.

Site-key request:

```http
POST /token HTTP/1.1
Content-Type: application/json

{"site_key": "...", "origin": "https://app.k8s.ote", "action": "login",
 "enterprise": false, "max_retries": 3}
```

Anchor-URL request (if you have one captured from the real browser's network tab):

```http
POST /token HTTP/1.1
Content-Type: application/json

{"anchor_url": "https://www.google.com/recaptcha/api2/anchor?...",
 "action": "login", "max_retries": 3}
```

From a browser-automation pod in the same namespace:

```bash
curl -fsS -X POST http://zoer-bypassv3:8080/token \
  -H 'Content-Type: application/json' \
  -d '{"site_key":"'"$KEY"'","origin":"https://app.k8s.ote","action":"login"}'
# -> {"token": "..."}
```

Deployment is managed by `scripts/zoer-deploy.sh` through the shared kustomize
flow (added as a resource in `k8s/zoer-local/base/kustomization.yaml`). The
browser Deployments (`zoer-cloakbrowser`, `zoer-blitzbrowser`, workers) are
NOT modified; automation calls this service and injects the returned token
into the test app's reCAPTCHA field.

## Testing it in the repo

```bash
python3 -m unittest tests.test_zoer_bypassv3_token tests.test_zoer_bypassv3_service
```

Both suites patch `ReCaptchaV3Bypass` and never touch Google. The CLI suite
verifies the vendored layout, argparse surface, and token print/error paths.
The service suite enforces byte-equality between the two copies of
`bypass.py`, checks the kustomization wiring, and drives `server.py` through
an ephemeral local HTTP server.

## Updating the vendored copy

The library is pinned at commit `f470220d3e8d75302d4384b6487de7696b35372c`
(upstream `main`, 2026-11-11). See `scripts/bypassv3/NOTICE.md` for the
step-by-step update recipe; keep it verbatim from upstream so Apache-2.0
Section 4(b) (modification notices) does not apply.
