"""HTTP service wrapping the vendored BypassV3 library.

Scope: Zoer-owned apps or systems you are explicitly authorized to test.
The service generates reCAPTCHA v3 tokens over Google's HTTP endpoints; no
browser is involved. Intended caller is your own backend or test automation
submitting the returned token to your own reCAPTCHA v3 verifier.

Endpoints:
    GET  /healthz           -> 200 {"ok": true}
    POST /token             -> 200 {"token": "..."} on success; 4xx/5xx on failure
        body (JSON object), one of:
            {"site_key": "...", "origin": "https://app...", "action": "login",
             "enterprise": false, "max_retries": 3}
            {"anchor_url": "https://www.google.com/recaptcha/api2/anchor?...",
             "action": "login", "max_retries": 3}

The ConfigMap mounts bypass.py beside this file, so the import path is flat.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bypass import ReCaptchaV3Bypass  # noqa: E402  (flat ConfigMap layout)


def build_bypass(params: dict) -> ReCaptchaV3Bypass:
    """Translate the JSON request body into a ReCaptchaV3Bypass instance."""
    action = params.get("action")
    max_retries = int(params.get("max_retries", 3))
    anchor_url = params.get("anchor_url")
    site_key = params.get("site_key")
    if anchor_url and site_key:
        raise ValueError("pass site_key OR anchor_url, not both")
    if anchor_url:
        return ReCaptchaV3Bypass(
            anchor_url, action=action, max_retries=max_retries
        )
    if site_key:
        origin = params.get("origin")
        if not origin:
            raise ValueError("origin is required with site_key")
        return ReCaptchaV3Bypass.from_site_key(
            site_key,
            origin,
            action=action,
            enterprise=bool(params.get("enterprise", False)),
            max_retries=max_retries,
        )
    raise ValueError("either site_key+origin or anchor_url is required")


class Handler(BaseHTTPRequestHandler):
    server_version = "zoer-bypassv3/1"

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self._json(200, {"ok": True})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path != "/token":
            self._json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length else b""
            params = json.loads(raw) if raw else {}
        except (ValueError, json.JSONDecodeError) as exc:
            self._json(400, {"error": f"bad request body: {exc}"})
            return
        if not isinstance(params, dict):
            self._json(400, {"error": "body must be a JSON object"})
            return

        try:
            instance = build_bypass(params)
        except ValueError as exc:
            self._json(400, {"error": str(exc)})
            return

        try:
            token = instance.bypass()
        except Exception as exc:  # noqa: BLE001 - surface upstream failure to caller
            self._json(502, {"error": f"bypass failed: {exc}"})
            return

        if not token:
            self._json(502, {"error": "no token returned"})
            return
        self._json(200, {"token": token})

    def _json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write(
            f"zoer-bypassv3 {self.address_string()} - {fmt % args}\n"
        )


def main() -> int:
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"zoer-bypassv3 listening on 0.0.0.0:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
