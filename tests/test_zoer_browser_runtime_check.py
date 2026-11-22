"""zoer-browser-runtime-check.sh against a stub kubectl; no cluster access."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/zoer-browser-runtime-check.sh'
CURRENT = 'docker.io/zoer-local/browser-runtime:9e97583688a630aa'


def run(runtime_env: str, pods: list[tuple[str, str]], fail_pods: bool = False) -> subprocess.CompletedProcess:
    with tempfile.TemporaryDirectory() as tmp:
        stub = Path(tmp) / 'kubectl'
        pod_lines = ''.join(f'{name} {image}\\n' for name, image in pods)
        stub.write_text(f'''#!/usr/bin/env bash
case "$*" in
  *"get deploy zoer-backend"*) printf '%s' '{runtime_env}' ;;
  *"get pods -l zoer.browser-worker=true"*) {'exit 1' if fail_pods else f"printf '{pod_lines}'"} ;;
  *) echo "unexpected kubectl call: $*" >&2; exit 2 ;;
esac
''')
        stub.chmod(0o755)
        env = {**os.environ, 'PATH': f'{tmp}:{os.environ["PATH"]}'}
        return subprocess.run(['bash', str(SCRIPT)], env=env, capture_output=True, text=True, timeout=30)


class BrowserRuntimeCheckTests(unittest.TestCase):
    def test_reports_workers_left_on_an_older_runtime(self):
        # As on OTE on 2026-11-21: the download browser's worker kept 10a86077 after newer runtimes shipped.
        result = run(CURRENT, [('zoer-bw-old', 'docker.io/zoer-local/browser-runtime:10a860773c45915e'),
                               ('zoer-bw-new', CURRENT)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('older runtime: zoer-bw-old runs 10a860773c45915e (current 9e97583688a630aa)', result.stdout)
        self.assertNotIn('zoer-bw-new runs', result.stdout)
        self.assertIn('1 of 2 browser worker(s) on an older runtime', result.stdout)
        self.assertIn('next time they start', result.stdout)

    def test_all_current(self):
        result = run(CURRENT, [('zoer-bw-a', CURRENT)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('all 1 browser worker(s) run 9e97583688a630aa.', result.stdout)

    def test_never_fails_a_deploy_when_it_cannot_tell(self):
        missing = run('', [])
        self.assertEqual(missing.returncode, 0, missing.stderr)
        self.assertIn('no BROWSER_RUNTIME_IMAGE', missing.stdout)
        unreachable = run(CURRENT, [], fail_pods=True)
        self.assertEqual(unreachable.returncode, 0, unreachable.stderr)
        self.assertIn('all 0 browser worker(s)', unreachable.stdout)

    def test_deploy_runs_it_without_letting_it_fail_the_deploy(self):
        deploy = (ROOT / 'scripts/zoer-deploy.sh').read_text()
        self.assertIn('"$HERE/zoer-browser-runtime-check.sh" || true', deploy)


if __name__ == '__main__':
    unittest.main()
