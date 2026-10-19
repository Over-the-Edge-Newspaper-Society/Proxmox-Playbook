import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("zoer_computer_ssh", Path(__file__).resolve().parents[1] / "scripts/zoer-computer-ssh.py")
ssh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ssh)


class SshAccessInputs(unittest.TestCase):
    def test_source_cidr_cannot_inject_configuration_or_allow_everyone(self):
        for source in ["0.0.0.0/0", "10.70.30.0/24\nPermitRootLogin yes", "10.70.30.1/24", "::/0", "192.168.3.0/24 extra"]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                ssh.sshd_config([source])

    def test_key_options_and_private_keys_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / "device"
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
            for contents in [key.read_text(), 'command="touch /tmp/injected" ' + key.with_suffix(".pub").read_text(), "ssh-ed25519 not-base64"]:
                supplied = Path(directory) / "supplied.pub"
                supplied.write_text(contents)
                with self.subTest(contents=contents[:20]), self.assertRaises(ValueError):
                    ssh.public_keys([str(supplied)])

    def test_valid_device_key_is_deduplicated_and_comment_is_inert(self):
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / "device"
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key), "-C", "$(touch /tmp/injected)"], check=True)
            result = ssh.public_keys([str(key.with_suffix(".pub")), str(key.with_suffix(".pub"))])
            self.assertEqual(len(result.splitlines()), 1)
            self.assertNotIn("touch", result)

    def sandbox_operator(self, security=None, extra_spec=None):
        args = SimpleNamespace(computer="zoer-sandbox-test", kubeconfig="/unused", namespace="zoer",
                               sandbox_profile="zoer-codex-computer", public_key=[], allowed_source=["10.70.30.0/24"],
                               port=30022, node_address="10.70.20.50")
        operator = ssh.Operator(args)
        container = {"name": "computer", "image": "test", "securityContext": security or {}}
        spec = {"containers": [container], "volumes": [{"name": "private-runtime", "persistentVolumeClaim": {"claimName": "existing"}}], **(extra_spec or {})}
        deployment = {"metadata": {"annotations": {ssh.MARKER: "v1"}}, "spec": {"template": {"spec": spec}}}
        operator.inspect = lambda: (deployment, container)
        operator.get = lambda *_: {"spec": {"ports": [{"nodePort": 30022}]}}
        operator.apply = Mock()
        operator.kube = Mock(side_effect=AssertionError("No cluster mutation is allowed in a rejected plan"))
        return operator

    def test_sandbox_plan_rejects_privileged_capabilities_and_foreign_profiles(self):
        cases = [{"privileged": True}, *[{"capabilities": {"add": [c]}} for c in ["SYS_ADMIN", "CAP_SYS_ADMIN", "ALL"]],
                 {"appArmorProfile": {"type": "Unconfined"}}, {"appArmorProfile": {"type": "Localhost", "localhostProfile": "unrelated"}}]
        for security in cases:
            operator = self.sandbox_operator(security)
            with self.subTest(security=security), patch.object(ssh, "public_keys", return_value="test-public-key\n"), self.assertRaises(ValueError):
                operator.enable(dry_run=True)
            operator.apply.assert_not_called()

    def test_sandbox_plan_rejects_host_namespace_and_host_path_access(self):
        cases = [{k: True} for k in ("hostPID", "hostIPC", "hostNetwork")]
        cases.append({"volumes": [{"name": "private-runtime", "persistentVolumeClaim": {"claimName": "existing"}},
                                  {"name": "host-root", "hostPath": {"path": "/"}}]})
        for extra in cases:
            operator = self.sandbox_operator(extra_spec=extra)
            with self.subTest(spec=extra), patch.object(ssh, "public_keys", return_value="test-public-key\n"), self.assertRaises(ValueError):
                operator.enable(dry_run=True)
            operator.apply.assert_not_called()


if __name__ == "__main__":
    unittest.main()
