#!/usr/bin/env python3
"""Install the opt-in Codex AppArmor profile on one explicitly selected node."""
import argparse
import hashlib
import ipaddress
import json
from pathlib import Path
import re
import shlex
import subprocess

PROFILE = Path(__file__).resolve().parents[1] / "k8s/zoer-local/optional/computer-ssh/zoer-codex-computer.apparmor"


def run(argv, data=None):
    result = subprocess.run(argv, input=data, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="ubuntu@10.70.20.50")
    parser.add_argument("--ssh-key", default="~/.ssh/personalprox_pve_ed25519")
    parser.add_argument("--kubeconfig", default="~/.kube/ote-k3s.yaml")
    parser.add_argument("--node", default="k3s-node-1")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z_][a-z0-9_-]*@[0-9.]+", args.host):
        parser.error("Specify the operator SSH user and node IPv4 address.")
    address = str(ipaddress.IPv4Address(args.host.split("@")[1]))
    kube = ["kubectl", "--kubeconfig", str(Path(args.kubeconfig).expanduser())]
    node = json.loads(run(kube + ["get", "node", args.node, "-o", "json"]))
    if address not in [a["address"] for a in node["status"]["addresses"] if a["type"] == "InternalIP"]:
        raise ValueError("The SSH address must match the selected Kubernetes node's InternalIP.")
    profile = PROFILE.read_text()
    digest = hashlib.sha256(profile.encode()).hexdigest()
    ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-i", str(Path(args.ssh_key).expanduser()), args.host]
    # Validate syntax before installing or loading anything in the kernel.
    run(ssh + ["sudo apparmor_parser --skip-kernel-load --skip-read-cache"], profile)
    install = r'''
import os, pathlib, subprocess, sys, tempfile
target=pathlib.Path("/etc/apparmor.d/zoer-codex-computer")
previous=target.read_bytes() if target.exists() else None
if target.is_symlink(): raise SystemExit("Refusing a symlinked profile")
if previous and b"Opt-in container profile for nested" not in previous:
 raise SystemExit("Refusing to replace an unrelated profile")
contents=sys.stdin.buffer.read()
with tempfile.NamedTemporaryFile(dir=target.parent,prefix=".zoer-codex-",delete=False) as f:
 f.write(contents); temporary=pathlib.Path(f.name)
temporary.chmod(0o644)
try:
 subprocess.run(["apparmor_parser","--replace","--skip-read-cache",str(temporary)],check=True)
 os.replace(temporary,target)
except BaseException:
 temporary.unlink(missing_ok=True)
 if previous:
  subprocess.run(["apparmor_parser","--replace","--skip-read-cache"],input=previous,check=True)
 raise
print("Installed enforcing zoer-codex-computer profile")
'''
    print(run(ssh + ["sudo python3 -c " + shlex.quote(install)], profile).strip())
    loaded = run(ssh + ["sudo cat /sys/kernel/security/apparmor/profiles"])
    if "zoer-codex-computer (enforce)" not in loaded.splitlines():
        raise RuntimeError("The enforcing profile was not read back; no node label is applied.")
    run(kube + ["label", "node", args.node, "zoer.codex-sandbox=apparmor-v1", "--overwrite"])
    print(f"Node {args.node} labeled for opt-in computers; profile SHA256 {digest}")


if __name__ == "__main__":
    main()
