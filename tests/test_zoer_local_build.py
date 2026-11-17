"""zoer-local-build.sh guard tests with command doubles; never connect to a host."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BACKEND = 'docker.io/zoer-local/backend:dev-base'
FRONTEND = 'docker.io/zoer-local/frontend:dev-base'
RUNTIME = 'docker.io/zoer-local/browser-runtime:live'
SSH = r'''#!/usr/bin/env python3
import os,sys
cmd=sys.argv[-1]
with open(os.environ['CALL_LOG'],'a') as f:f.write(cmd+'\n')
held=os.environ.get('CONTAINERD_IMAGES','').split()
docker=os.environ.get('DOCKER_IMAGES','').split()
if 'images ls -q' in cmd:
 raise SystemExit(0 if any(i in cmd for i in held) else 1)
if 'docker image inspect' in cmd:
 raise SystemExit(0 if any(i in cmd for i in docker) else 1)
if 'images export' in cmd:
 os.environ.get('LOADED') and open(os.environ['LOADED'],'a').close()
 raise SystemExit(0)
if 'cut -c1-16' in cmd: print('newruntimehash00')
elif "--entrypoint sha256sum" in cmd: print(os.environ.get('BASE_HASHES','same'))
elif 'sha256sum' in cmd: print('same')
'''


class BuildGuards(unittest.TestCase):
    def run_build(self, **extra):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            bindir = root/'bin'; bindir.mkdir()
            (root/'scripts').mkdir()
            shutil.copy(ROOT/'scripts/zoer-local-build.sh', root/'scripts')
            ssh = bindir/'ssh'; ssh.write_text(SSH); ssh.chmod(0o755)
            rsync = bindir/'rsync'; rsync.write_text('#!/bin/sh\nexit 0\n'); rsync.chmod(0o755)
            repo = root/'zoer'; repo.mkdir()
            subprocess.run(['git', 'init', '-q'], cwd=repo, check=True)
            subprocess.run(['git', '-c', 'user.email=t@example.test', '-c', 'user.name=t', 'commit', '-q',
                            '--allow-empty', '-m', 'x'], cwd=repo, check=True)
            env = {**os.environ, 'PATH': f'{bindir}:{os.environ["PATH"]}', 'CALL_LOG': str(root/'calls'),
                   'ZOER_REPO_ROOT': str(repo), 'TMPDIR': folder,
                   'ZOER_K8S_DEV_SSH_KEY': '/dev/null', 'ZOER_BUILD_PREFLIGHT_ONLY': '1', **extra}
            run = subprocess.run(['bash', str(root/'scripts/zoer-local-build.sh')], env=env, text=True, capture_output=True)
            return run, (root/'calls').read_text()

    def source_only(self, **extra):
        return self.run_build(ZOER_BACKEND_SOURCE_BASE_IMAGE=BACKEND, ZOER_FRONTEND_REUSE_IMAGE=FRONTEND,
                              ZOER_BROWSER_RUNTIME_REUSE_IMAGE=RUNTIME, CONTAINERD_IMAGES=f'{RUNTIME} {BACKEND} {FRONTEND}',
                              DOCKER_IMAGES=f'{BACKEND} {FRONTEND}', **extra)

    def test_valid_source_only_update_passes_without_building(self):
        run, calls = self.source_only()
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn('PREFLIGHT ONLY', run.stdout)
        self.assertNotIn('buildx build', calls)
        self.assertNotIn('buildx create', calls)

    def test_inputs_are_read_from_the_workspace_root(self):
        _, calls = self.source_only()
        self.assertIn('--workdir /app', calls)
        self.assertIn("cd '/srv/zoer-local-build/source' && sha256sum package.json bun.lock bunfig.toml", calls)
        self.assertIn('sdk/packages/plugin-contracts/package.json', calls)

    def test_differing_inputs_stop_before_any_build(self):
        run, calls = self.source_only(BASE_HASHES='different', ZOER_BUILD_PREFLIGHT_ONLY='0')
        self.assertNotEqual(run.returncode, 0)
        self.assertIn('inputs differ', run.stderr)
        self.assertNotIn('buildx build', calls)
        self.assertNotIn('docker save', calls)

    def test_source_only_refuses_to_build_a_new_runtime(self):
        run, calls = self.run_build(ZOER_BACKEND_SOURCE_BASE_IMAGE=BACKEND, ZOER_FRONTEND_REUSE_IMAGE=FRONTEND,
                                    CONTAINERD_IMAGES=f'{BACKEND} {FRONTEND}', DOCKER_IMAGES=f'{BACKEND} {FRONTEND}',
                                    ZOER_BUILD_PREFLIGHT_ONLY='0')
        self.assertNotEqual(run.returncode, 0)
        self.assertIn('ZOER_BROWSER_RUNTIME_REUSE_IMAGE', run.stderr)
        self.assertNotIn('buildx build', calls)

    def test_runtime_rebuild_can_be_accepted_explicitly(self):
        run, _ = self.run_build(ZOER_BACKEND_SOURCE_BASE_IMAGE=BACKEND, ZOER_FRONTEND_REUSE_IMAGE=FRONTEND,
                                CONTAINERD_IMAGES=f'{BACKEND} {FRONTEND}', DOCKER_IMAGES=f'{BACKEND} {FRONTEND}',
                                ZOER_ALLOW_RUNTIME_BUILD='1')
        self.assertEqual(run.returncode, 0, run.stderr)

    def test_base_image_missing_from_docker_is_loaded_from_containerd(self):
        run, calls = self.run_build(ZOER_BACKEND_SOURCE_BASE_IMAGE=BACKEND, ZOER_FRONTEND_REUSE_IMAGE=FRONTEND,
                                    ZOER_BROWSER_RUNTIME_REUSE_IMAGE=RUNTIME,
                                    CONTAINERD_IMAGES=f'{RUNTIME} {BACKEND} {FRONTEND}', DOCKER_IMAGES=FRONTEND)
        self.assertNotEqual(run.returncode, 0)  # the double never gains the image, so the recheck fails
        self.assertIn(f"images export - '{BACKEND}' | sudo -n docker load", calls)
        self.assertIn('Could not load', run.stderr)

    def test_full_build_has_no_source_only_checks(self):
        run, calls = self.run_build(CONTAINERD_IMAGES='', DOCKER_IMAGES='')
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotIn('--entrypoint sha256sum', calls)

    def test_source_dockerfile_uses_workspace_paths(self):
        text = (ROOT/'k8s/zoer-local/optional/backend-source-update.Dockerfile').read_text()
        self.assertIn('COPY sdk/packages/api-types/src', text)
        self.assertIn('COPY sdk/packages/plugin-contracts/src', text)
        self.assertNotIn('COPY packages/', text)


if __name__ == '__main__':
    unittest.main()
