"""Test setup control flow with isolated command doubles; no real host/cluster writes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = r'''#!/usr/bin/env python3
import base64,json,os,pathlib,shlex,sys
root=pathlib.Path(os.environ['TEST_ROOT']); name=pathlib.Path(sys.argv[0]).name; args=sys.argv[1:]
with root.joinpath('calls').open('a') as f:f.write(json.dumps([name,args])+'\n')
state=json.loads(root.joinpath('state').read_text())
def out(value):print(json.dumps(value))
if name=='rsync':sys.exit(0)
if name=='ssh':
 command=args[-1]
 if command.startswith('mktemp'):print('/tmp/zoer-ddev-setup.test123')
 elif command.startswith('sudo -n bash'):
  root.joinpath('seed').write_text(sys.stdin.read())
  operation=shlex.split(command)[4];root.joinpath('operation').write_text(operation)
  if os.environ.get('FAIL_HOST')=='1':sys.exit(9)
 elif command.startswith('sudo -n sed'):print('DDEV_BRIDGE_TOKEN='+state.get('token','test-token-'+'a'*54))
 sys.exit(0)
if name=='kubectl':
 if 'get' in args:
  kind=args[args.index('get')+1]
  if kind=='configmap':
   if 'mode' in state:
    value=state['mode']
    if 'DDEV_BRIDGE_URL' in args[-1]:value+=':'+state.get('url','')
    print(value,end='')
  elif kind=='secret':
   if 'token' in state:out({'data':{'DDEV_BRIDGE_TOKEN':base64.b64encode(state['token'].encode()).decode()}})
  elif kind=='deployment':print('deployment.apps/zoer-backend')
 elif 'create' in args:
  if 'configmap' in args:
   data=dict(a.split('=',1)[1].split('=',1) for a in args if a.startswith('--from-literal='))
   out({'kind':'ConfigMap','data':data})
  elif 'secret' in args:
   file=next(a.split('=',1)[1] for a in args if a.startswith('--from-env-file='))
   out({'kind':'Secret','token':pathlib.Path(file).read_text().strip().split('=',1)[1]})
 elif 'apply' in args:
  value=json.load(sys.stdin)
  if value['kind']=='ConfigMap':state.update(mode=value['data']['DDEV_ENABLED'],url=value['data']['DDEV_BRIDGE_URL'])
  else:state['token']=value['token']
  root.joinpath('state').write_text(json.dumps(state))
 elif 'exec' in args:sys.stdin.read()
 sys.exit(0)
sys.exit(1)
'''

class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root.joinpath('state').write_text('{}')
        tools = self.root/'bin'; tools.mkdir()
        for name in ['kubectl', 'ssh', 'rsync']:
            path=tools/name; path.write_text(TOOL); path.chmod(0o755)
        repo=self.root/'repo'; (repo/'ddev-bridge/src').mkdir(parents=True)
        (repo/'ddev-bridge/src/index.ts').write_text('// test only')
        self.env={**os.environ, 'TEST_ROOT':str(self.root), 'PATH':str(tools)+os.pathsep+os.environ['PATH'], 'ZOER_REPO_ROOT':str(repo), 'ZOER_DDEV_DEFER_ROLLOUT':'0'}
        self.env.pop('ZOER_DDEV_ENABLED',None)
    def state(self): return json.loads((self.root/'state').read_text())
    def calls(self): return [json.loads(line) for line in (self.root/'calls').read_text().splitlines()]
    def run_setup(self,*args):
        return subprocess.run(['bash',str(ROOT/'scripts/zoer-setup-ddev.sh'),*args],env=self.env,capture_output=True,text=True)
    def test_opt_out_does_not_upload_bridge_or_create_secret(self):
        result=self.run_setup('--disable');self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.root/'operation').read_text(),'disable')
        self.assertEqual(self.state(),{'mode':'0','url':''})
        self.assertEqual(sum(name=='rsync' for name,args in self.calls()),1)
        self.assertFalse(any('secret' in args and 'create' in args for name,args in self.calls()))
    def test_saved_opt_out_is_preserved_on_normal_deploy(self):
        (self.root/'state').write_text(json.dumps({'mode':'0','url':'','token':'keep-me'}))
        result=self.run_setup();self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.state()['token'],'keep-me')
        self.assertEqual((self.root/'operation').read_text(),'disable')
        self.assertFalse(any('restart' in args for name,args in self.calls()))
    def test_enabled_setup_preserves_token_and_does_not_restart_on_unchanged_rerun(self):
        token='test-token-'+'a'*54
        (self.root/'state').write_text(json.dumps({'mode':'1','url':'http://10.70.20.50:4085','token':token}))
        result=self.run_setup('--enable');self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.root/'seed').read_text(),token)
        self.assertEqual(self.state()['token'],token)
        self.assertNotIn(token,result.stdout+result.stderr)
        self.assertFalse(any('restart' in args for name,args in self.calls()))
    def test_failed_host_setup_never_advertises_enabled(self):
        self.env['FAIL_HOST']='1'
        result=self.run_setup('--enable');self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.state(),{})
        self.assertFalse(any('apply' in args for name,args in self.calls()))
    def test_invalid_flag_does_not_touch_host_or_cluster(self):
        self.env['ZOER_DDEV_ENABLED']='yes'
        result=self.run_setup();self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.root/'calls').exists())

if __name__=='__main__':unittest.main()
