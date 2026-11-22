"""Tests for the vendored BypassV3 helper and its CLI wrapper.

These tests never reach the real Google endpoints: the inner ReCaptchaV3Bypass
class is patched to return a deterministic token, and the CLI is exercised in
process so argparse and the --site-key / --anchor-url / --origin wiring are
covered without a network stub for the real bypass() flow.
"""
import io
import os
import subprocess
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "scripts/bypassv3"
CLI_ENTRY = ROOT / "scripts/zoer-bypassv3-token.py"

sys.path.insert(0, str(ROOT / "scripts"))
from bypassv3 import cli as bv3cli  # noqa: E402


class VendoredLayoutTests(unittest.TestCase):
    def test_required_files_present(self):
        for name in ("__init__.py", "bypass.py", "cli.py", "LICENSE", "NOTICE.md"):
            self.assertTrue((VENDOR / name).exists(), f"missing {name}")
        self.assertTrue(CLI_ENTRY.exists(), "missing scripts/zoer-bypassv3-token.py")

    def test_notice_pins_upstream_commit_and_license(self):
        notice = (VENDOR / "NOTICE.md").read_text()
        # If the vendored copy is refreshed, update NOTICE.md to the new SHA.
        self.assertIn("f470220d3e8d75302d4384b6487de7696b35372c", notice)
        self.assertIn("Apache License 2.0", notice)
        self.assertIn("EvickaStudio/BypassV3", notice)

    def test_license_is_apache_2(self):
        text = (VENDOR / "LICENSE").read_text()
        self.assertIn("Apache License", text)
        self.assertIn("Version 2.0", text)

    def test_init_restates_authorized_testing_scope(self):
        init_text = (VENDOR / "__init__.py").read_text()
        self.assertIn("authorized", init_text.lower())
        self.assertIn("Zoer", init_text)

    def test_bypass_py_is_untouched(self):
        """The vendored library is not modified; the CLI is a sibling file, not
        a wrapper patch. If this ever has to change, record the modification in
        NOTICE.md per Apache-2.0 Section 4(b)."""
        text = (VENDOR / "bypass.py").read_text()
        self.assertIn("class ReCaptchaV3Bypass", text)
        self.assertNotIn("# zoer-modified", text)
        # Upstream's bypass.py starts with its imports, not with a Zoer header.
        first_nonblank = next(line for line in text.splitlines() if line.strip())
        self.assertEqual(first_nonblank, "import base64")


class CliParserTests(unittest.TestCase):
    def test_help_lists_both_input_modes(self):
        parser = bv3cli.build_parser()
        help_text = parser.format_help()
        self.assertIn("--site-key", help_text)
        self.assertIn("--anchor-url", help_text)
        self.assertIn("--origin", help_text)
        self.assertIn("--action", help_text)
        self.assertIn("--enterprise", help_text)

    def test_site_key_and_anchor_url_are_mutually_exclusive(self):
        with self.assertRaises(SystemExit):
            with redirect_stderr(io.StringIO()):
                bv3cli.main(["--site-key", "k", "--anchor-url", "https://x"])

    def test_requires_one_of_site_key_or_anchor_url(self):
        with self.assertRaises(SystemExit):
            with redirect_stderr(io.StringIO()):
                bv3cli.main([])

    def test_site_key_requires_origin(self):
        err = io.StringIO()
        with self.assertRaises(SystemExit):
            with redirect_stderr(err):
                bv3cli.main(["--site-key", "abc"])
        self.assertIn("--origin is required", err.getvalue())


class CliBypassFlowTests(unittest.TestCase):
    def test_site_key_flow_prints_token_from_from_site_key(self):
        fake = mock.MagicMock()
        fake.bypass.return_value = "fake-token-sitekey"
        with mock.patch.object(
            bv3cli.ReCaptchaV3Bypass, "from_site_key", return_value=fake
        ) as fsk:
            out = io.StringIO()
            with redirect_stdout(out):
                rc = bv3cli.main([
                    "--site-key", "key123",
                    "--origin", "https://app.k8s.ote",
                    "--action", "login",
                ])
            self.assertEqual(rc, 0)
            self.assertEqual(out.getvalue().strip(), "fake-token-sitekey")
            fsk.assert_called_once()
            kwargs = fsk.call_args.kwargs
            self.assertEqual(kwargs["action"], "login")
            self.assertFalse(kwargs["enterprise"])

    def test_enterprise_flag_is_forwarded(self):
        fake = mock.MagicMock()
        fake.bypass.return_value = "ent-token"
        with mock.patch.object(
            bv3cli.ReCaptchaV3Bypass, "from_site_key", return_value=fake
        ) as fsk:
            with redirect_stdout(io.StringIO()):
                rc = bv3cli.main([
                    "--site-key", "k",
                    "--origin", "https://app.k8s.ote",
                    "--enterprise",
                ])
            self.assertEqual(rc, 0)
            self.assertTrue(fsk.call_args.kwargs["enterprise"])

    def test_anchor_url_flow_bypasses_from_site_key(self):
        fake_instance = mock.MagicMock()
        fake_instance.bypass.return_value = "fake-token-anchor"
        with mock.patch.object(
            bv3cli, "ReCaptchaV3Bypass",
            side_effect=lambda *a, **kw: fake_instance,
        ) as ctor:
            out = io.StringIO()
            with redirect_stdout(out):
                rc = bv3cli.main([
                    "--anchor-url",
                    "https://www.google.com/recaptcha/api2/anchor?k=x&co=y&v=z",
                ])
            self.assertEqual(rc, 0)
            self.assertEqual(out.getvalue().strip(), "fake-token-anchor")
            ctor.assert_called_once()

    def test_returns_1_and_stderr_when_bypass_yields_no_token(self):
        fake = mock.MagicMock()
        fake.bypass.return_value = None
        err = io.StringIO()
        with mock.patch.object(
            bv3cli.ReCaptchaV3Bypass, "from_site_key", return_value=fake
        ):
            with redirect_stderr(err), redirect_stdout(io.StringIO()):
                rc = bv3cli.main([
                    "--site-key", "k", "--origin", "https://app.k8s.ote",
                ])
        self.assertEqual(rc, 1)
        self.assertIn("no token", err.getvalue())


class CliEntrypointTests(unittest.TestCase):
    def test_entrypoint_is_executable_and_shows_help(self):
        self.assertTrue(os.access(CLI_ENTRY, os.X_OK), "entrypoint must be executable")
        result = subprocess.run(
            [sys.executable, str(CLI_ENTRY), "--help"],
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--site-key", result.stdout)
        self.assertIn("--anchor-url", result.stdout)
        self.assertIn("zoer-bypassv3-token", result.stdout)


if __name__ == "__main__":
    unittest.main()
