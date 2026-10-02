"""Maintenance drain in zoer-deploy.sh against a stub backend; no cluster or host writes.

Library tests call scripts/lib/zoer-maintenance.sh with ZOER_MAINTENANCE_URL (local
curl). Deploy tests run a copy of zoer-deploy.sh with stub kubectl/ssh/curl and
stub sibling scripts; the stub kubectl runs the real `bun -e` client from the
library against the stub server, as `kubectl exec` would inside the pod.
Needs bash, curl, jq and bun.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / 'scripts/lib/zoer-maintenance.sh'
PREFIX = '/api/internal/maintenance'


class Backend:
    """Scripted maintenance API. mode: ok | old | never | drain500."""

    def __init__(self, mode='ok'):
        self.mode, self.draining, self.polls, self.calls = mode, False, 0, []
        self.lock = threading.Lock()

    def status(self):
        s = {'draining': self.draining, 'drainId': 'd1' if self.draining else None,
             'requestedAt': None, 'expiresAt': None, 'active': [], 'paused': [],
             'blocking': [], 'safeToRestart': False}
        if not self.draining:
            s['active'] = [{'runId': 'r1', 'stepId': 's1', 'kind': 'plugin-action',
                            'label': 'Procurement: download bids', 'pausable': True, 'state': 'running'}]
            return s
        self.polls += 1
        if self.mode == 'never' or self.polls == 1:
            s['active'] = [{'runId': 'r1', 'stepId': 's1', 'kind': 'plugin-action',
                            'label': 'Procurement: download bids', 'pausable': True, 'state': 'running'}]
        elif self.polls == 2:
            s['active'] = [{'runId': 'r1', 'stepId': 's1', 'kind': 'plugin-action',
                            'label': 'Procurement: download bids', 'pausable': True, 'state': 'pausing'}]
            s['blocking'] = [{'kind': 'wordpress', 'label': 'Push example.com', 'reason': 'cannot pause'}]
        else:
            s['paused'] = [{'runId': 'r1', 'stepId': 's1', 'label': 'Procurement: download bids',
                            'pausedAt': '2026-10-02T00:00:00Z', 'hasCheckpoint': True}]
            s['safeToRestart'] = True
        return s

    def handle(self, method, path, body, auth):
        with self.lock:
            self.calls.append((method, path, body, auth))
            if self.mode == 'old' or not path.startswith(PREFIX):
                return 404, {'error': 'not found'}
            sub = path[len(PREFIX):]
            if method == 'GET' and sub == '':
                return 200, self.status()
            if method == 'POST' and sub == '/drain':
                if self.mode == 'drain500':
                    return 500, {'error': 'boom'}
                self.draining = True
                return 200, {'draining': True, 'drainId': 'd1', 'requestedAt': 'x', 'expiresAt': 'y'}
            if method == 'POST' and sub == '/resume':
                self.draining = False
                return 200, {'draining': False, 'resumed': 1}
            return 404, {'error': 'not found'}

    def kinds(self):
        return [f'{m} {p[len(PREFIX):] or "/"}' for m, p, _, _ in self.calls]


def serve(backend):
    class Handler(BaseHTTPRequestHandler):
        def _go(self):
            n = int(self.headers.get('content-length') or 0)
            body = self.rfile.read(n).decode() if n else ''
            code, data = backend.handle(self.command, self.path, body, self.headers.get('authorization'))
            raw = json.dumps(data).encode()
            self.send_response(code)
            self.send_header('content-type', 'application/json')
            self.send_header('content-length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
        do_GET = do_POST = _go

        def log_message(self, *_):
            pass
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


KUBECTL = r'''#!/usr/bin/env bash
pre=(); for a in "$@"; do [[ "$a" == "--" ]] && break; pre+=("$a"); done
echo "kubectl ${pre[*]}" >> "$TEST_ROOT/calls"
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--" ]]; then shift "$i"; PORT="$STUB_PORT" exec "$@"; fi
done
case " $* " in
  *" cluster-info "*) exit 0 ;;
  *" zoer.plugin-runner=true "*)
    left="$(cat "$TEST_ROOT/plugin-reads" 2>/dev/null || echo 999)"
    if (( left > 0 )); then cat "$TEST_ROOT/plugin-pods" 2>/dev/null; echo $(( left - 1 )) > "$TEST_ROOT/plugin-reads"; fi ;;
  *" app=zoer-backend "*) echo "2026-10-02T00:00:00Z zoer-backend-new " ;;
  *" rollout status "*) [[ -e "$TEST_ROOT/rollout-fail" ]] && exit 1 ;;
  *" set image "*) rm -f "$TEST_ROOT/rollout-fail" ;;
  *" get deploy "*) echo "docker.io/zoer-local/backend:old" ;;
esac
exit 0
'''
SSH = '#!/usr/bin/env bash\necho "ssh ${*: -1}" >> "$TEST_ROOT/calls"\n[[ "$*" == *"free -m"* ]] && echo 99999\nexit 0\n'
CURL = '#!/usr/bin/env bash\nprintf 200\n'


class Base(unittest.TestCase):
    mode = 'ok'

    def setUp(self):
        for tool in ('bash', 'curl', 'jq', 'bun'):
            if not shutil.which(tool):
                self.skipTest(f'{tool} not installed')
        self.backend = Backend(self.mode)
        self.server = serve(self.backend)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.url = f'http://127.0.0.1:{self.server.server_address[1]}'
        self.env = dict(os.environ, TEST_ROOT=str(self.root), ZOER_DRAIN_POLL_SECONDS='0.1',
                        ZOER_RESUME_TRAP_WAIT='2', STUB_PORT=str(self.server.server_address[1]))
        for key in ('ZOER_MAINTENANCE_URL', 'ZOER_MAINTENANCE_TOKEN', 'ZOER_NAMESPACE'):
            self.env.pop(key, None)

    def lib(self, body, **env):
        e = dict(self.env, ZOER_MAINTENANCE_URL=self.url, **env)
        return subprocess.run(['bash', '-c', f'set -Eeuo pipefail; source "{LIB}"\n{body}'],
                              env=e, capture_output=True, text=True, timeout=60)


class LibraryTests(Base):
    """Library over local curl (ZOER_MAINTENANCE_URL)."""

    def test_drain_wait_resume_with_token(self):
        r = self.lib('zm_drain "test" 2700; zm_wait_safe 20; zm_resume_new 5', ZOER_MAINTENANCE_TOKEN='tok')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.backend.kinds(), ['POST /drain', 'GET /', 'GET /', 'GET /', 'GET /', 'POST /resume', 'GET /'])
        self.assertTrue(all(auth == 'Bearer tok' for *_, auth in self.backend.calls))
        self.assertEqual(json.loads(self.backend.calls[0][2]), {'reason': 'test', 'ttlSeconds': 2700})
        self.assertEqual(json.loads(self.backend.calls[5][2]), {'drainId': 'd1'})
        self.assertIn('active    plugin-action  running', r.stdout)
        self.assertIn('blocking  wordpress', r.stdout)
        self.assertIn('safe to restart', r.stdout)
        self.assertIn('resumed 1 paused step(s)', r.stdout)

    def test_trap_resumes_and_keeps_exit_code(self):
        r = self.lib('trap zm_on_exit EXIT; zm_drain "test" 2700; exit 7')
        self.assertEqual(r.returncode, 7)
        self.assertEqual(self.backend.kinds()[-2:], ['POST /resume', 'GET /'])
        self.assertIn('resuming paused work', r.stderr)


class LibraryNeverSafe(Base):
    mode = 'never'

    def test_wait_times_out(self):
        start = time.time()
        r = self.lib('zm_drain "test" 2700; zm_wait_safe 2 && echo SAFE || echo TIMEOUT')
        self.assertIn('TIMEOUT', r.stdout)
        self.assertLess(time.time() - start, 10)


class LibraryOld(Base):
    mode = 'old'

    def test_old_backend_is_detected(self):
        r = self.lib('rc=0; zm_probe || rc=$?; echo "probe=$rc"; '
                     'rc=0; zm_drain t 2700 || rc=$?; echo "drain=$rc drained=$ZM_DRAINED"')
        self.assertIn('probe=1', r.stdout)
        self.assertIn('drain=1 drained=0', r.stdout)


class DeployTests(Base):
    """zoer-deploy.sh end to end with command doubles."""

    def setUp(self):
        super().setUp()
        scripts = self.root / 'repo/scripts'
        (scripts / 'lib').mkdir(parents=True)
        shutil.copy(ROOT / 'scripts/zoer-deploy.sh', scripts)
        shutil.copy(LIB, scripts / 'lib')
        for name, body in {'zoer-create-secrets.sh': '', 'zoer-setup-ddev.sh': '', 'zoer-prune-runtimes.sh': '',
                           'zoer-local-build.sh': 'echo "BUILD COMPLETE: dev-test"'}.items():
            (scripts / name).write_text(f'#!/usr/bin/env bash\n{body}\n')
            (scripts / name).chmod(0o755)
        overlay = self.root / 'repo/k8s/zoer-local/overlay'
        overlay.mkdir(parents=True)
        (overlay / 'kustomization.yaml').write_text('    newTag: old\n')
        bindir = self.root / 'bin'
        bindir.mkdir()
        for name, body in {'kubectl': KUBECTL, 'ssh': SSH, 'curl': CURL}.items():
            (bindir / name).write_text(body)
            (bindir / name).chmod(0o755)
        (self.root / 'kubeconfig').write_text('')
        self.env.update(PATH=f'{bindir}:{os.environ["PATH"]}', KUBECONFIG=str(self.root / 'kubeconfig'),
                        ZOER_K8S_DEV_SSH_KEY='/dev/null')

    def deploy(self, *args, interrupt_after=None):
        p = subprocess.Popen(['bash', str(self.root / 'repo/scripts/zoer-deploy.sh'), '--skip-convex', *args],
                             env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if interrupt_after:
            deadline = time.time() + 20
            while time.time() < deadline and self.backend.kinds().count('GET /') < interrupt_after:
                time.sleep(0.05)
            p.send_signal(signal.SIGINT)
        out, err = p.communicate(timeout=60)
        calls = (self.root / 'calls').read_text() if (self.root / 'calls').exists() else ''
        return p.returncode, out, err, calls

    def plugin_pods(self, reads=999):
        (self.root / 'plugin-pods').write_text('pod/zoer-plugin-abc\n')
        (self.root / 'plugin-reads').write_text(str(reads))


class DeployOk(DeployTests):
    def test_happy_path_order(self):
        rc, out, err, calls = self.deploy()
        self.assertEqual(rc, 0, out + err)
        k = self.backend.kinds()
        self.assertEqual(k[:2], ['GET /', 'POST /drain'])
        self.assertEqual(k[-2:], ['POST /resume', 'GET /'])
        self.assertIn('[   0s] draining=true safeToRestart=false active=1', out)
        self.assertIn('safe to restart', out)
        self.assertIn('resumed 1 paused step(s) on zoer-backend-new', out)
        self.assertLess(out.index('safe to restart'), out.index('waiting for rollouts'))
        self.assertIn('kubectl apply -k', calls)
        self.assertIn('ttlSeconds":2700', self.backend.calls[1][2])
        self.assertIn('zoer-deploy dev-test', self.backend.calls[1][2])

    def test_waits_for_plugin_runner_pods(self):
        self.plugin_pods(reads=6)
        rc, out, err, _ = self.deploy()
        self.assertEqual(rc, 0, out + err)
        self.assertIn('plugin workers running now', out)
        self.assertIn('worker-pods=1', out)
        self.assertIn('pod       plugin-runner', out)

    def test_force_drains_without_waiting(self):
        self.backend.mode = 'never'
        rc, out, err, calls = self.deploy('--force')
        self.assertEqual(rc, 0, out + err)
        self.assertIn('--force: not waiting', out)
        self.assertEqual(self.backend.kinds().count('POST /drain'), 1)
        self.assertEqual(self.backend.kinds()[-2:], ['POST /resume', 'GET /'])
        self.assertIn('kubectl apply -k', calls)

    def test_drain_timeout_resumes_and_does_not_deploy(self):
        self.backend.mode = 'never'
        rc, out, err, calls = self.deploy('--drain-timeout', '1')
        self.assertEqual(rc, 1)
        self.assertIn('did not drain within 1s - nothing was deployed', err)
        self.assertIn('resuming paused work', err)
        self.assertEqual(self.backend.kinds()[-2:], ['POST /resume', 'GET /'])
        self.assertNotIn('apply -k', calls)

    def test_rollout_failure_rolls_back_then_resumes(self):
        (self.root / 'rollout-fail').write_text('')
        rc, out, err, calls = self.deploy()
        self.assertEqual(rc, 1)
        self.assertIn('rollout failed - rolling back', err)
        self.assertIn('set image deploy/zoer-backend', calls)
        self.assertEqual(self.backend.kinds()[-2:], ['POST /resume', 'GET /'])
        self.assertIn('work resumed; the deploy itself did not complete (exit 1)', err)

    def test_ctrl_c_during_wait_resumes(self):
        self.backend.mode = 'never'
        rc, out, err, calls = self.deploy('--drain-timeout', '30', interrupt_after=4)
        self.assertEqual(rc, 130, out + err)
        self.assertEqual(self.backend.kinds()[-2:], ['POST /resume', 'GET /'])
        self.assertNotIn('apply -k', calls)

    def test_drain_error_aborts_without_force(self):
        self.backend.mode = 'drain500'
        rc, out, err, calls = self.deploy()
        self.assertEqual(rc, 1)
        self.assertIn('could not drain the backend', err)
        self.assertNotIn('apply -k', calls)
        self.assertIn('POST /resume', self.backend.kinds())

    def test_no_drain_is_legacy(self):
        rc, out, err, calls = self.deploy('--no-drain')
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.backend.calls, [])
        self.plugin_pods()
        rc, out, err, _ = self.deploy('--no-drain')
        self.assertEqual(rc, 1)
        self.assertIn('Plugin workers are still running', err)


class DeployOld(DeployTests):
    mode = 'old'

    def test_old_backend_falls_back_to_legacy_guard(self):
        rc, out, err, calls = self.deploy()
        self.assertEqual(rc, 0, out + err)
        self.assertIn('expected on the first deploy', err)
        self.assertIn('falling back to the legacy plugin-worker guard', err)
        self.assertNotIn('POST /resume', self.backend.kinds())
        self.assertIn('apply -k', calls)

    def test_old_backend_with_workers_refuses(self):
        self.plugin_pods()
        rc, out, err, calls = self.deploy()
        self.assertEqual(rc, 1)
        self.assertIn('Plugin workers are still running', err)
        self.assertNotIn('apply -k', calls)


if __name__ == '__main__':
    unittest.main()
