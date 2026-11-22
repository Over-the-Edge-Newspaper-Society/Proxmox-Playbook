"""Tests for the in-cluster zoer-bypassv3 service.

Covers:
  * Byte-equality between the vendored library at scripts/bypassv3/bypass.py and
    the Kustomize copy at k8s/zoer-local/base/bypassv3/bypass.py (kustomize's
    default loader won't reach outside the base directory, so the file is
    duplicated and must be kept in sync).
  * Static shape of the k8s manifest and kustomization.
  * Behavioral tests of server.py via a real ephemeral HTTP server; the
    underlying ReCaptchaV3Bypass is patched so no network traffic leaves the
    test process.
"""
import hashlib
import io
import json
import socket
import sys
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "scripts/bypassv3"
K8S_BASE = ROOT / "k8s/zoer-local/base"
K8S_APP = K8S_BASE / "bypassv3"
K8S_MANIFEST = K8S_BASE / "bypassv3.yaml"
KUSTOMIZATION = K8S_BASE / "kustomization.yaml"

sys.path.insert(0, str(K8S_APP))
# Importing server also runs its `from bypass import ReCaptchaV3Bypass`, which
# proves the ConfigMap's flat layout works on the sys.path the pod uses.
import server as svc  # noqa: E402


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class CopyConsistencyTests(unittest.TestCase):
    def test_bypass_py_matches_vendored_copy(self):
        self.assertEqual(
            _sha256(VENDOR / "bypass.py"),
            _sha256(K8S_APP / "bypass.py"),
            "k8s/zoer-local/base/bypassv3/bypass.py has drifted from "
            "scripts/bypassv3/bypass.py; re-copy it verbatim.",
        )

    def test_notice_points_at_canonical_copy(self):
        notice = (K8S_APP / "NOTICE.md").read_text()
        self.assertIn("scripts/bypassv3/bypass.py", notice)
        self.assertIn("Apache-2.0", notice)

    def test_requirements_pin_matches_pyproject(self):
        req = (K8S_APP / "requirements.txt").read_text().strip().splitlines()
        self.assertIn("requests==2.34.2", req)


class ManifestShapeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with K8S_MANIFEST.open() as fh:
            cls.docs = [d for d in yaml.safe_load_all(fh) if d is not None]
        cls.kinds = {d.get("kind"): d for d in cls.docs}

    def test_has_deployment_and_service(self):
        self.assertIn("Deployment", self.kinds)
        self.assertIn("Service", self.kinds)

    def test_service_is_cluster_ip_only(self):
        svc_doc = self.kinds["Service"]
        self.assertEqual(svc_doc["spec"].get("type", "ClusterIP"), "ClusterIP")
        ports = svc_doc["spec"]["ports"]
        self.assertEqual(ports[0]["port"], 8080)
        self.assertEqual(ports[0]["targetPort"], 8080)

    def test_deployment_image_is_pinned_by_digest(self):
        container = self.kinds["Deployment"]["spec"]["template"]["spec"][
            "containers"
        ][0]
        image = container["image"]
        self.assertTrue(
            image.startswith("docker.io/library/python:3.12-slim@sha256:"),
            f"expected sha256-pinned python:3.12-slim, got {image!r}",
        )

    def test_deployment_mounts_configmap_at_app(self):
        tpl = self.kinds["Deployment"]["spec"]["template"]
        container = tpl["spec"]["containers"][0]
        mounts = {m["name"]: m for m in container["volumeMounts"]}
        self.assertIn("app", mounts)
        self.assertEqual(mounts["app"]["mountPath"], "/app")
        volumes = {v["name"]: v for v in tpl["spec"]["volumes"]}
        self.assertEqual(volumes["app"]["configMap"]["name"], "zoer-bypassv3-app")

    def test_deployment_has_both_probes(self):
        container = self.kinds["Deployment"]["spec"]["template"]["spec"][
            "containers"
        ][0]
        self.assertEqual(container["readinessProbe"]["httpGet"]["path"], "/healthz")
        self.assertEqual(container["livenessProbe"]["httpGet"]["path"], "/healthz")

    def test_no_ingress_exposed(self):
        """ClusterIP-only: no Ingress ships in the base manifest."""
        self.assertNotIn("Ingress", self.kinds)


class KustomizationWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with KUSTOMIZATION.open() as fh:
            cls.kustomization = yaml.safe_load(fh)

    def test_bypassv3_yaml_is_registered_as_a_resource(self):
        self.assertIn("bypassv3.yaml", self.kustomization["resources"])

    def test_configmap_generator_lists_the_three_source_files(self):
        gens = self.kustomization["configMapGenerator"]
        matches = [g for g in gens if g["name"] == "zoer-bypassv3-app"]
        self.assertEqual(len(matches), 1)
        files = set(matches[0]["files"])
        self.assertEqual(
            files,
            {
                "bypassv3/bypass.py",
                "bypassv3/server.py",
                "bypassv3/requirements.txt",
            },
        )


class ServerHelperTests(unittest.TestCase):
    """Direct unit tests for build_bypass's request-body translation."""

    def test_rejects_both_site_key_and_anchor_url(self):
        with self.assertRaises(ValueError):
            svc.build_bypass({"site_key": "k", "anchor_url": "https://x",
                              "origin": "https://y"})

    def test_rejects_neither(self):
        with self.assertRaises(ValueError):
            svc.build_bypass({})

    def test_site_key_without_origin_rejected(self):
        with self.assertRaises(ValueError):
            svc.build_bypass({"site_key": "k"})

    def test_site_key_routes_to_from_site_key_with_action_and_enterprise(self):
        with mock.patch.object(
            svc.ReCaptchaV3Bypass, "from_site_key"
        ) as fsk:
            fsk.return_value = mock.sentinel.instance
            got = svc.build_bypass({
                "site_key": "k",
                "origin": "https://app.k8s.ote",
                "action": "login",
                "enterprise": True,
                "max_retries": 5,
            })
        self.assertIs(got, mock.sentinel.instance)
        kwargs = fsk.call_args.kwargs
        self.assertEqual(kwargs["action"], "login")
        self.assertTrue(kwargs["enterprise"])
        self.assertEqual(kwargs["max_retries"], 5)

    def test_anchor_url_routes_to_constructor(self):
        with mock.patch.object(
            svc, "ReCaptchaV3Bypass", side_effect=lambda *a, **kw: mock.sentinel.inst
        ) as ctor:
            got = svc.build_bypass({
                "anchor_url": "https://www.google.com/recaptcha/api2/anchor?k=x",
                "action": "submit",
            })
        self.assertIs(got, mock.sentinel.inst)
        self.assertEqual(ctor.call_args.kwargs["action"], "submit")


class HttpServerTests(unittest.TestCase):
    """Boots the real server on 127.0.0.1:<ephemeral>, drives it with urllib."""

    @classmethod
    def setUpClass(cls):
        cls.server = svc.ThreadingHTTPServer(("127.0.0.1", 0), svc.Handler)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(
            target=cls.server.serve_forever, name="zoer-bypassv3-test", daemon=True
        )
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    def _url(self, path):
        return f"http://127.0.0.1:{self.port}{path}"

    def _request(self, method, path, body=None, timeout=5):
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(
            self._url(path), data=data, method=method,
            headers={"Content-Type": "application/json"} if data else {},
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.getcode(), json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read().decode("utf-8"))

    def test_healthz(self):
        code, body = self._request("GET", "/healthz")
        self.assertEqual(code, 200)
        self.assertTrue(body["ok"])

    def test_unknown_get_is_404_json(self):
        code, body = self._request("GET", "/nope")
        self.assertEqual(code, 404)
        self.assertIn("error", body)

    def test_token_site_key_success(self):
        fake = mock.MagicMock()
        fake.bypass.return_value = "fake-token-xyz"
        with mock.patch.object(svc.ReCaptchaV3Bypass, "from_site_key",
                               return_value=fake):
            code, body = self._request("POST", "/token", {
                "site_key": "k", "origin": "https://app.k8s.ote",
                "action": "login",
            })
        self.assertEqual(code, 200)
        self.assertEqual(body["token"], "fake-token-xyz")

    def test_token_anchor_url_success(self):
        fake = mock.MagicMock()
        fake.bypass.return_value = "anchor-fake"
        with mock.patch.object(svc, "ReCaptchaV3Bypass",
                               side_effect=lambda *a, **kw: fake):
            code, body = self._request("POST", "/token", {
                "anchor_url":
                    "https://www.google.com/recaptcha/api2/anchor?k=x&co=y&v=z",
            })
        self.assertEqual(code, 200)
        self.assertEqual(body["token"], "anchor-fake")

    def test_token_bad_body_is_400(self):
        req = urllib.request.Request(
            self._url("/token"),
            data=b"this is not json",
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        try:
            urllib.request.urlopen(req, timeout=5)
            self.fail("expected HTTPError")
        except urllib.error.HTTPError as exc:
            self.assertEqual(exc.code, 400)
            body = json.loads(exc.read().decode("utf-8"))
            self.assertIn("bad request body", body["error"])

    def test_token_missing_fields_is_400(self):
        code, body = self._request("POST", "/token", {})
        self.assertEqual(code, 400)
        self.assertIn("required", body["error"])

    def test_token_bypass_returns_none_is_502(self):
        fake = mock.MagicMock()
        fake.bypass.return_value = None
        with mock.patch.object(svc.ReCaptchaV3Bypass, "from_site_key",
                               return_value=fake):
            code, body = self._request("POST", "/token", {
                "site_key": "k", "origin": "https://app.k8s.ote",
            })
        self.assertEqual(code, 502)
        self.assertIn("no token", body["error"])

    def test_token_bypass_raises_is_502(self):
        fake = mock.MagicMock()
        fake.bypass.side_effect = RuntimeError("boom")
        with mock.patch.object(svc.ReCaptchaV3Bypass, "from_site_key",
                               return_value=fake):
            code, body = self._request("POST", "/token", {
                "site_key": "k", "origin": "https://app.k8s.ote",
            })
        self.assertEqual(code, 502)
        self.assertIn("bypass failed", body["error"])

    def test_unknown_post_is_404_json(self):
        code, body = self._request("POST", "/nope", {"x": 1})
        self.assertEqual(code, 404)
        self.assertIn("error", body)


if __name__ == "__main__":
    unittest.main()
