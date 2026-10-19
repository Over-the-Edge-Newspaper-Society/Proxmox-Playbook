#!/usr/bin/env python3
"""Live SSH/Codex sandbox qualification; no model inference or credentials read.

Temporarily creates and removes its own workspace file. Run against an idle
operator-selected SSH computer, not as part of offline unit-test discovery.
"""
import argparse
import json
from pathlib import Path
import queue
import re
import shlex
import subprocess
import tempfile
import threading
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ssh_alias")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"zoer-[a-z0-9-]+", args.ssh_alias):
        parser.error("Use an explicitly configured zoer- SSH alias.")
    ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", args.ssh_alias]
    preflight = "n=int(next(x.split()[1] for x in open('/proc/self/status') if x.startswith('CapBnd:')),16); assert not (n & (1<<21)), 'Outer container has CAP_SYS_ADMIN'; print('NO_OUTER_CAP_SYS_ADMIN')"
    subprocess.run(ssh + ["python3 -c " + shlex.quote(preflight)], check=True)
    messages = queue.Queue()
    results = []
    sequence = 0
    # Starting in the project directory makes workspace-write's default root
    # match the project, rather than this SSH account's login directory.
    with tempfile.TemporaryFile(mode="w+") as errors:
        process = subprocess.Popen(ssh + ["cd /workspace && codex app-server --stdio"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=errors, text=True, bufsize=1)

        def reader():
            for line in process.stdout:
                try:
                    messages.put(json.loads(line))
                except json.JSONDecodeError:
                    pass
            messages.put(None)

        threading.Thread(target=reader, daemon=True).start()

        def send(message):
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()

        def request(method, params):
            nonlocal sequence
            sequence += 1
            send({"id": sequence, "method": method, "params": params})
            while True:
                message = messages.get(timeout=30)
                if message is None:
                    raise RuntimeError("SSH app-server disconnected")
                if "method" in message and "id" in message:
                    raise RuntimeError("Qualification unexpectedly requires interactive input")
                if message.get("id") == sequence:
                    if "error" in message:
                        raise RuntimeError(json.dumps(message["error"]))
                    return message["result"]

        def denied_write(path, marker):
            return ("import os,errno; p=" + repr(path) + ";\n"
                    "try: fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)\n"
                    "except OSError as e:\n"
                    " assert e.errno in (errno.EACCES,errno.EPERM,errno.EROFS),e; print(" + repr(marker) + ")\n"
                    "else: os.close(fd); os.unlink(p); raise SystemExit('UNEXPECTED_WRITE_ALLOWED')")

        suffix = uuid.uuid4().hex
        tests = [
            ("identity and enforcing profile", ["bash", "-ec", "pwd; id; uname -s; cat /proc/self/attr/current"], {"type": "readOnly"}),
            ("read-only denies workspace write", ["python3", "-c", denied_write("/workspace/.zoer-readonly-" + suffix, "READ_ONLY_WRITE_DENIED")], {"type": "readOnly"}),
            ("workspace write/read/cleanup", ["python3", "-c", "import tempfile,pathlib,os; fd,p=tempfile.mkstemp(prefix='.zoer-sandbox-qualification-',dir='/workspace'); os.close(fd); q=pathlib.Path(p); q.write_text('sandbox works'); assert q.read_text()=='sandbox works'; q.unlink(); print('WORKSPACE_WRITE_READ_CLEANUP_OK')"], {"type": "workspaceWrite", "writableRoots": ["/workspace"], "networkAccess": False}),
            ("workspace-write denies HOME write", ["python3", "-c", denied_write("/home/kasm-user/.zoer-outside-" + suffix, "OUTSIDE_WORKSPACE_WRITE_DENIED")], {"type": "workspaceWrite", "writableRoots": ["/workspace"], "networkAccess": False}),
        ]
        try:
            request("initialize", {"clientInfo": {"name": "zoer_sandbox_qualification", "version": "1.0.0"}, "capabilities": {}})
            send({"method": "initialized", "params": {}})
            for name, command, policy in tests:
                result = request("command/exec", {"command": command, "cwd": "/workspace", "sandboxPolicy": policy, "timeoutMs": 10000})
                record = {"test": name, **result}
                results.append(record)
                print(json.dumps(record), flush=True)
                if result.get("exitCode") != 0:
                    raise RuntimeError("Sandbox qualification failed: " + name)
                if name == "identity and enforcing profile":
                    output = result.get("stdout", "")
                    if not (output.startswith("/workspace\n") and re.search(r"uid=\d+\(kasm-user\)", output)
                            and "\nLinux\n" in output and "zoer-codex-computer (enforce)" in output):
                        raise RuntimeError("Unexpected user, working directory, platform or AppArmor enforcement")
            if args.output:
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(json.dumps({"host": args.ssh_alias, "outerCapSysAdmin": False, "results": results}, indent=2) + "\n")
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=5)


if __name__ == "__main__":
    main()
