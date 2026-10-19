#!/usr/bin/env python3
"""Opt-in SSH access to one existing Kubernetes Zoer computer on the OTE LAN."""
import argparse
import base64
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "k8s/zoer-local/optional/computer-ssh/start.sh"
MARKER = "zoer.ssh-managed"
MOUNT = "zoer-managed-ssh"
SANDBOX_NODE_LABEL = "zoer.codex-sandbox"


def run(args, data=None):
    result = subprocess.run(args, input=data, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"Command failed: {args[0]}")
    return result.stdout


def public_keys(paths):
    keys = []
    for path in paths:
        lines = Path(path).expanduser().read_text().splitlines()
        for line in lines:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            words = line.split()
            # Accept plain public keys only; never interpret supplied SSH options.
            if len(words) < 2 or words[0] not in ("ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "sk-ssh-ed25519@openssh.com"):
                raise ValueError("Supply a plain OpenSSH public-key file, without key options or private keys.")
            base64.b64decode(words[1], validate=True)
            with tempfile.NamedTemporaryFile(mode="w") as tmp:
                tmp.write(" ".join(words[:2]) + "\n")
                tmp.flush()
                run(["ssh-keygen", "-lf", tmp.name])
            key = " ".join(words[:2])
            if key not in keys:
                keys.append(key)
    if not keys:
        raise ValueError("At least one public key is required.")
    return "\n".join(keys) + "\n"


def sshd_config(sources):
    networks = [str(ipaddress.ip_network(s, strict=True)) for s in sources]
    if not networks or any(ipaddress.ip_network(s).prefixlen == 0 for s in networks):
        raise ValueError("Specify explicit LAN/VPN source CIDRs; unrestricted /0 sources are rejected.")
    if any(ipaddress.ip_network(s).version != 4 for s in networks):
        raise ValueError("This pilot listens on IPv4; supply IPv4 source networks.")
    return "\n".join([
        "Port 2222", "ListenAddress 0.0.0.0", "AddressFamily inet",
        "HostKey /var/lib/zoer-runtime/ssh/ssh_host_ed25519_key",
        "PidFile /run/zoer-ssh/sshd.pid",
        "AuthorizedKeysFile /home/kasm-user/.ssh/zoer-managed-authorized_keys",
        "AllowUsers " + " ".join("kasm-user@" + s for s in networks),
        "PermitRootLogin no", "PubkeyAuthentication yes", "AuthenticationMethods publickey",
        "PasswordAuthentication no", "KbdInteractiveAuthentication no",
        "ChallengeResponseAuthentication no", "PermitEmptyPasswords no", "UsePAM yes", "StrictModes yes",
        "AllowAgentForwarding no", "AllowTcpForwarding local", "AllowStreamLocalForwarding local",
        "PermitOpen localhost:* 127.0.0.1:* [::1]:*", "GatewayPorts no",
        "X11Forwarding no", "PermitTunnel no", "PermitUserRC no",
        "PrintMotd no", "PrintLastLog no", "ClientAliveInterval 60", "ClientAliveCountMax 3",
        "SetEnv CODEX_SQLITE_HOME=/tmp/zoer-codex-runtime/sqlite DISPLAY=:99 PATH=/var/lib/zoer-runtime/cli/bin:/usr/local/bin:/usr/bin:/bin",
        "Subsystem sftp internal-sftp", "LogLevel VERBOSE", "",
    ])


class Operator:
    def __init__(self, args):
        self.args = args
        self.prefix = ["kubectl", "--kubeconfig", str(Path(args.kubeconfig).expanduser()), "-n", args.namespace]
        self.name = "zoer-ssh-" + hashlib.sha256(args.computer.encode()).hexdigest()[:12]

    def kube(self, *args, data=None):
        return run(self.prefix + list(args), data)

    def get(self, kind, name):
        raw = self.kube("get", kind, name, "--ignore-not-found", "-o", "json")
        return json.loads(raw) if raw.strip() else None

    def apply(self, manifest):
        return self.kube("apply", "-f", "-", data=json.dumps(manifest))

    def inspect(self):
        deployment = self.get("deployment", self.args.computer)
        if not deployment or deployment["metadata"].get("labels", {}).get("zoer.managed") != "true":
            raise ValueError("Select an existing Zoer-managed Kubernetes computer deployment.")
        container = next((c for c in deployment["spec"]["template"]["spec"]["containers"] if c["name"] == "computer"), None)
        if container is None:
            raise ValueError("The selected deployment has no computer container.")
        return deployment, container

    def require_idle(self):
        with urllib.request.urlopen(self.args.zoer_url.rstrip("/") + "/api/computers/" + self.args.computer, timeout=15) as response:
            computer = json.load(response)
        if computer.get("workflowOwner"):
            raise ValueError("The computer has an active workflow; wait for it to finish.")

    def wait_for_projection(self, data):
        expected = {name: hashlib.sha256(value.encode()).hexdigest() for name, value in data.items()}
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            raw = self.kube("exec", "deploy/" + self.args.computer, "-c", "computer", "--", "sha256sum",
                            *["/opt/zoer-ssh/" + name for name in expected])
            actual = {Path(line.split()[1]).name: line.split()[0] for line in raw.splitlines()}
            if actual == expected:
                return
            time.sleep(2)
        raise RuntimeError("New SSH configuration has not projected into the computer; key changes are not yet active.")

    def available_port(self, existing):
        if existing:
            port = existing["spec"]["ports"][0]["nodePort"]
            if self.args.port and self.args.port != port:
                raise ValueError("Keep the existing SSH port, or disable access before assigning another.")
            return port
        raw = run(self.prefix[:3] + ["get", "services", "-A", "-o", "json"])
        used = {p["nodePort"] for s in json.loads(raw)["items"] for p in s["spec"].get("ports", []) if "nodePort" in p}
        if self.args.port:
            if not 30000 <= self.args.port <= 32767 or self.args.port in used:
                raise ValueError("The requested NodePort is out of range or already assigned.")
            return self.args.port
        return next(p for p in range(30022, 32768) if p not in used)

    def enable(self, dry_run=False):
        deployment, container = self.inspect()
        annotations = deployment["metadata"].get("annotations", {})
        managed = annotations.get(MARKER) == "v1"
        lifecycle = container.get("lifecycle", {})
        if lifecycle.get("postStart") and not managed:
            raise ValueError("An existing postStart hook must be reconciled before enabling SSH.")
        spec = deployment["spec"]["template"]["spec"]
        if not any(v.get("persistentVolumeClaim") and v["name"] == "private-runtime" for v in spec.get("volumes", [])):
            raise ValueError("The computer must already have its private runtime PVC; no storage is created by this helper.")
        if not self.args.allowed_source:
            raise ValueError("Supply the explicit allowed LAN/VPN CIDRs.")
        keys = public_keys(self.args.public_key)
        config = sshd_config(self.args.allowed_source)
        service = self.get("service", self.name)
        port = self.available_port(service)
        profile_change = bool(self.args.sandbox_profile and (
            container.get("securityContext", {}).get("appArmorProfile") != {"type": "Localhost", "localhostProfile": self.args.sandbox_profile}
            or spec.get("nodeSelector", {}).get(SANDBOX_NODE_LABEL) != "apparmor-v1"
        ))
        sandbox_container = {}
        sandbox_spec = {}
        sandbox_annotations = {}
        if self.args.sandbox_profile:
            security = container.get("securityContext", {})
            if security.get("privileged") or {"SYS_ADMIN", "CAP_SYS_ADMIN", "ALL"}.intersection(security.get("capabilities", {}).get("add", [])):
                raise ValueError("The Codex profile must not be combined with privileged mode or CAP_SYS_ADMIN.")
            if any(spec.get(k) for k in ("hostPID", "hostIPC", "hostNetwork")) or any(v.get("hostPath") for v in spec.get("volumes", [])):
                raise ValueError("The Codex profile requires an ordinary isolated computer without host namespace/path mounts.")
            current_profile = security.get("appArmorProfile")
            if current_profile and current_profile not in ({"type": "RuntimeDefault"}, {"type": "Localhost", "localhostProfile": self.args.sandbox_profile}):
                raise ValueError("Reconcile the existing custom AppArmor profile first.")
            nodes = json.loads(run(self.prefix[:3] + ["get", "nodes", "-l", SANDBOX_NODE_LABEL + "=apparmor-v1", "-o", "json"]))
            if not nodes["items"]:
                raise ValueError("Install the Codex sandbox profile on the node before selecting it.")
            sandbox_annotations = {
                "zoer.ssh-original-apparmor": annotations.get("zoer.ssh-original-apparmor", json.dumps(current_profile)),
                "zoer.ssh-original-sandbox-node-selector": annotations.get("zoer.ssh-original-sandbox-node-selector", json.dumps(spec.get("nodeSelector", {}).get(SANDBOX_NODE_LABEL))),
            }
            sandbox_container = {"securityContext": {"appArmorProfile": {"type": "Localhost", "localhostProfile": self.args.sandbox_profile}}}
            sandbox_spec = {"nodeSelector": {SANDBOX_NODE_LABEL: "apparmor-v1"}}
        print(json.dumps({"computer": self.args.computer, "image": container["image"], "nodeAddress": self.args.node_address,
                          "nodePort": port, "allowedSources": self.args.allowed_source,
                          "publicKeyCount": len(keys.splitlines()), "restartsComputer": not managed or profile_change,
                          "requestedSandboxProfile": self.args.sandbox_profile,
                          "storage": "existing private-runtime PVC", "mode": "plan" if dry_run else "enable"}, indent=2), flush=True)
        if dry_run:
            return
        # Do not restart a computer reserved by an active Zoer workflow.
        self.require_idle()
        if self.kube("exec", "deploy/" + self.args.computer, "-c", "computer", "--", "id", "-u").strip() != "0":
            raise ValueError("This runtime requires a root startup hook in the existing computer container.")
        labels = {"zoer.ssh-computer-id": self.args.computer, "app.kubernetes.io/managed-by": "zoer-computer-ssh"}
        data = {"start.sh": RUNTIME.read_text(), "authorized_keys": keys, "sshd_config": config}
        self.apply({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": self.name, "labels": labels}, "data": data})
        original = annotations.get("zoer.ssh-original-lifecycle", json.dumps(lifecycle))
        strategy = annotations.get("zoer.ssh-original-strategy", json.dumps(deployment["spec"].get("strategy", {})))
        self.kube("patch", "deployment", self.args.computer, "--type", "strategic", "-p", json.dumps({
            "metadata": {"annotations": {MARKER: "v1", "zoer.ssh-original-lifecycle": original, "zoer.ssh-original-strategy": strategy, **sandbox_annotations}},
            "spec": {"strategy": {"type": "Recreate", "rollingUpdate": None}, "template": {"spec": {
                **sandbox_spec,
                "volumes": [{"name": MOUNT, "configMap": {"name": self.name, "defaultMode": 420}}],
                "containers": [{"name": "computer", **sandbox_container, "volumeMounts": [{"name": MOUNT, "mountPath": "/opt/zoer-ssh", "readOnly": True}],
                    "lifecycle": {"postStart": {"exec": {"command": ["/bin/bash", "/opt/zoer-ssh/start.sh"]}}}}],
            }}}}))
        self.kube("rollout", "status", "deployment/" + self.args.computer, "--timeout=300s")
        # For an already managed computer, apply key/config changes immediately.
        if managed:
            self.wait_for_projection(data)
            self.kube("exec", "deploy/" + self.args.computer, "-c", "computer", "--", "bash", "-ec",
                      'if test -s /run/zoer-ssh/supervisor.pid; then kill -TERM -- -$(cat /run/zoer-ssh/supervisor.pid); fi; sleep 1')
            self.kube("exec", "deploy/" + self.args.computer, "-c", "computer", "--", "bash", "/opt/zoer-ssh/start.sh")
        self.apply({"apiVersion": "v1", "kind": "Service", "metadata": {"name": self.name, "labels": labels},
                    "spec": {"type": "NodePort", "externalTrafficPolicy": "Local", "selector": {"zoer.computer-id": self.args.computer},
                             "ports": [{"name": "ssh", "protocol": "TCP", "port": 2222, "targetPort": 2222, "nodePort": port}]}})
        self.status()

    def disable(self):
        deployment, container = self.inspect()
        annotations = deployment["metadata"].get("annotations", {})
        if annotations.get(MARKER) != "v1":
            raise ValueError("This computer is not managed by this SSH helper.")
        self.require_idle()
        original = json.loads(annotations.get("zoer.ssh-original-lifecycle", "{}"))
        strategy = json.loads(annotations.get("zoer.ssh-original-strategy", '{"type":"RollingUpdate"}'))
        sandbox_container = {}
        sandbox_spec = {}
        if "zoer.ssh-original-apparmor" in annotations:
            sandbox_container = {"securityContext": {"appArmorProfile": json.loads(annotations["zoer.ssh-original-apparmor"])}}
            sandbox_spec = {"nodeSelector": {SANDBOX_NODE_LABEL: json.loads(annotations["zoer.ssh-original-sandbox-node-selector"])}}
        # A dedicated Service is removed first. Other computer ports are untouched.
        self.kube("delete", "service", self.name, "--ignore-not-found")
        self.kube("patch", "deployment", self.args.computer, "--type", "strategic", "-p", json.dumps({
            "metadata": {"annotations": {MARKER: None, "zoer.ssh-original-lifecycle": None, "zoer.ssh-original-strategy": None,
                                          "zoer.ssh-original-apparmor": None, "zoer.ssh-original-sandbox-node-selector": None}},
            "spec": {"strategy": {"$patch": "replace", **strategy}, "template": {"spec": {
                **sandbox_spec,
                "volumes": [{"name": MOUNT, "$patch": "delete"}],
                "containers": [{"name": "computer", **sandbox_container, "volumeMounts": [{"mountPath": "/opt/zoer-ssh", "$patch": "delete"}],
                                "lifecycle": {"$patch": "replace", **original} if original else None}],
            }}}}))
        self.kube("rollout", "status", "deployment/" + self.args.computer, "--timeout=300s")
        self.kube("delete", "configmap", self.name, "--ignore-not-found")
        print("SSH disabled. Private host identity and package cache retained for recovery.")

    def status(self):
        deployment, container = self.inspect()
        service = self.get("service", self.name)
        print(json.dumps({"computer": self.args.computer, "managed": deployment["metadata"].get("annotations", {}).get(MARKER) == "v1",
                          "service": self.name if service else None, "nodeAddress": self.args.node_address,
                          "nodePort": service["spec"]["ports"][0]["nodePort"] if service else None,
                          "appArmorProfile": container.get("securityContext", {}).get("appArmorProfile")}, indent=2))
        if service:
            print(self.kube("exec", "deploy/" + self.args.computer, "-c", "computer", "--", "ssh-keygen", "-lf", "/var/lib/zoer-runtime/ssh/ssh_host_ed25519_key.pub").strip())

    def client(self):
        """Pin the Kubernetes-read host key and register a dedicated SSH alias."""
        if not self.args.alias or not re.fullmatch(r"zoer-[a-z0-9-]{1,100}", self.args.alias):
            raise ValueError("Supply an explicit --alias beginning with zoer-.")
        identity = Path(self.args.identity_file).expanduser()
        if not identity.is_file() or any(c in str(identity) for c in '\n\r"'):
            raise ValueError("The local --identity-file must exist and have a safe filename.")
        ipaddress.IPv4Address(self.args.node_address)
        service = self.get("service", self.name)
        if not service:
            raise ValueError("Enable SSH on the selected computer first.")
        port = service["spec"]["ports"][0]["nodePort"]
        # Initial trust comes from the existing authenticated Kubernetes channel.
        hostkey = self.kube("exec", "deploy/" + self.args.computer, "-c", "computer", "--", "cat",
                           "/var/lib/zoer-runtime/ssh/ssh_host_ed25519_key.pub").split()
        if len(hostkey) < 2 or hostkey[0] != "ssh-ed25519":
            raise ValueError("Unexpected SSH host key.")
        base64.b64decode(hostkey[1], validate=True)
        directory = Path.home() / ".ssh"
        directory.mkdir(mode=0o700, exist_ok=True)
        known = directory / "known_hosts_zoer_ote"
        old_known = known.read_text() if known.exists() else ""
        line = self.args.alias + " " + " ".join(hostkey[:2])
        matches = [l for l in old_known.splitlines() if l.split() and l.split()[0] == self.args.alias]
        if any(l.strip() != line for l in matches):
            raise ValueError("The pinned host key differs. Investigate identity replacement before changing trust.")
        if not matches:
            old_known = old_known.rstrip("\n") + ("\n" if old_known else "") + line + "\n"
        include_dir = directory / "config.d"
        include_dir.mkdir(mode=0o700, exist_ok=True)
        include = include_dir / "zoer-ote.conf"
        config = directory / "config"
        if any(p.is_symlink() for p in (known, include, config)):
            raise ValueError("Symlinked client files require manual configuration; no link is replaced.")
        begin, end = "# BEGIN " + self.args.alias, "# END " + self.args.alias
        old = include.read_text() if include.exists() else "# OTE Zoer computer SSH connections\n"
        block = "\n".join([begin, "Host " + self.args.alias,
                          "  HostName " + self.args.node_address, "  Port " + str(port), "  User kasm-user",
                          '  IdentityFile "' + str(identity) + '"', "  IdentitiesOnly yes",
                          "  HostKeyAlias " + self.args.alias, '  UserKnownHostsFile "' + str(known) + '"',
                          "  StrictHostKeyChecking yes", "  ServerAliveInterval 30", end, ""])
        pattern = re.compile(re.escape(begin) + r"\n.*?\n" + re.escape(end) + r"\n?", re.S)
        updated = pattern.sub(lambda _: block, old) if begin in old else old.rstrip("\n") + "\n\n" + block
        directive = 'Include "' + str(include) + '"'
        old_config = config.read_text() if config.exists() else ""
        updated_config = old_config if directive in old_config.splitlines() else directive + "\n" + old_config
        # Atomic, mode-600 writes preserve unrelated aliases and configuration.
        for path, contents in ((known, old_known), (include, updated), (config, updated_config)):
            with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as tmp:
                tmp.write(contents)
                temporary = Path(tmp.name)
            temporary.chmod(0o600)
            os.replace(temporary, path)
        print("SSH alias ready: " + self.args.alias)
        print("Pinned host identity from Kubernetes; private device key remains on this laptop.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "enable", "disable", "status", "client"))
    parser.add_argument("--computer", required=True)
    parser.add_argument("--kubeconfig", default="~/.kube/ote-k3s.yaml")
    parser.add_argument("--namespace", default="zoer")
    parser.add_argument("--zoer-url", default="https://zoer.k8s.overtheedgepaper.ca")
    parser.add_argument("--node-address", default="10.70.20.50")
    parser.add_argument("--port", type=int)
    parser.add_argument("--public-key", action="append", default=[])
    parser.add_argument("--allowed-source", action="append", default=[])
    parser.add_argument("--alias")
    parser.add_argument("--identity-file", default="~/.ssh/zoer-ote-codex")
    parser.add_argument("--sandbox-profile", choices=("zoer-codex-computer",), help="Opt into the node-installed, enforcing Codex Bubblewrap profile.")
    args = parser.parse_args()
    if not re.fullmatch(r"zoer-[a-z0-9-]{1,58}", args.computer):
        parser.error("Invalid Zoer computer deployment name.")
    try:
        operator = Operator(args)
        if args.action in ("plan", "enable"):
            operator.enable(dry_run=args.action == "plan")
        else:
            getattr(operator, args.action)()
    except (ValueError, RuntimeError, OSError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
