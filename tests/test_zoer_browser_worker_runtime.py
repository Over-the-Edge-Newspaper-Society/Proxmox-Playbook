"""Runtime distribution guard tests; never connect to a host or cluster."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IMAGE = 'docker.io/zoer-local/browser-runtime:fixture'
SSH = '''#!/usr/bin/env python3
import gzip,json,os,sys
cmd=sys.argv[-1]
with open(os.environ['CALL_LOG'],'a') as f:f.write(json.dumps(sys.argv[1:])+'\\n')
mode=os.environ['FIXTURE_MODE']
if 'network-get-interfaces' in cmd:
 print(json.dumps([{'ip-addresses':[{'ip-address':'10.70.20.163' if mode=='mismatch' else '10.70.20.162'}]}]))
elif 'qm guest exec' in cmd: print(json.dumps({'exitcode':0,'out-data':'ssh-ed25519 fixture-key\\n'}))
elif 'images ls -q' in cmd: print(os.environ['FIXTURE_IMAGE'] if mode=='cached' else '')
elif 'df -Pk /' in cmd: print('1 30000000' if mode=='full' else '25000000 30000000')
elif 'docker image inspect' in cmd: print('3000000000')
elif 'docker save' in cmd: sys.stdout.buffer.write(gzip.compress(b'fixture-archive'))
elif 'gzip -d' in cmd:
 assert gzip.decompress(sys.stdin.buffer.read())==b'fixture-archive'
 print('imported')
elif 'images label' not in cmd: raise SystemExit('Unexpected remote command: '+cmd)
'''


class RuntimeDistributionTests(unittest.TestCase):
    def run_helper(self, mode, image=IMAGE):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); bindir=root/'bin';bindir.mkdir()
            ssh=bindir/'ssh';ssh.write_text(SSH);ssh.chmod(0o755)
            kube=bindir/'kubectl';kube.write_text('#!/bin/sh\necho 10.70.20.162\n');kube.chmod(0o755)
            env={**os.environ,'PATH':str(bindir)+':'+os.environ['PATH'],
                 'PLAYWRIGHT_WORKER_NODE':'zoer-browser-worker-1',
                 'CALL_LOG':str(root/'calls'),'FIXTURE_MODE':mode,'FIXTURE_IMAGE':IMAGE}
            run=subprocess.run(['bash',str(ROOT/'scripts/zoer-browser-worker-runtime.sh'),image],env=env,text=True,capture_output=True)
            calls=(root/'calls').read_text() if (root/'calls').exists() else ''
            return run,calls

    def test_cached_runtime_is_pinned_without_reimporting(self):
        run,calls=self.run_helper('cached')
        self.assertEqual(run.returncode,0,run.stderr)
        self.assertIn('images label',calls)
        self.assertNotIn('docker save',calls)
        self.assertIn('StrictHostKeyChecking=yes',calls)

    def test_uncached_runtime_streams_then_pins(self):
        run,calls=self.run_helper('import')
        self.assertEqual(run.returncode,0,run.stderr)
        self.assertIn('docker save',calls)
        self.assertIn('images import --no-unpack',calls)
        self.assertLess(calls.index('images import'),calls.index('images label'))

    def test_disk_reserve_and_vm_identity_fail_before_import(self):
        for mode in ['full','mismatch']:
            run,calls=self.run_helper(mode)
            self.assertNotEqual(run.returncode,0)
            self.assertNotIn('docker save',calls)
            self.assertNotIn('images label',calls)

    def test_invalid_image_cannot_be_interpolated_into_a_remote_command(self):
        run,calls=self.run_helper('cached',IMAGE+'; false')
        self.assertNotEqual(run.returncode,0)
        self.assertEqual(calls,'')


if __name__=='__main__':
    unittest.main()
