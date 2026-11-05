"""Run with python3 scripts/tests/test_secrets_bootstrap.py; uses only a fake kubectl."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'secrets-bootstrap.sh'
if not SCRIPT.exists():
    SCRIPT = Path(__file__).with_name('secrets-bootstrap.sh')

MOCK = r'''#!/usr/bin/env python3
import base64,json,os,sys
from pathlib import Path
p=Path(os.environ['BOOTSTRAP_MOCK_STATE']);state=json.loads(p.read_text());a=sys.argv[1:]
def fail():sys.exit(1)
def namespace():return a[a.index('--namespace')+1] if '--namespace' in a else 'default'
if a[:2]==['config','current-context']:
 print('unit-testnet');sys.exit()
if a[:2]==['get','namespace']:
 sys.exit(0 if a[2] in state['namespaces'] else 1)
if a[:2]==['get','secret']:
 obj=state['secrets'].get(namespace()+'/'+a[2])
 if obj is None:fail()
 fmt=a[a.index('-o')+1] if '-o' in a else ''
 if 'base64decode' in fmt:print(base64.b64decode(obj['data']['password']).decode())
 elif 'bnb-rpc-url' in fmt:
  if obj['data'].get('bnb-rpc-url') and obj['data'].get('bnb-rpc-ws-url'):print('complete')
 else:print(json.dumps(obj))
 sys.exit()
if a[:2]==['create','secret']:
 data={}
 for arg in a:
  if arg.startswith('--from-literal='):
   key,_,value=arg[len('--from-literal='):].partition('=');data[key]=base64.b64encode(value.encode()).decode()
 if a[2]=='docker-registry':data['.dockerconfigjson']=base64.b64encode(b'{"auths":{}}').decode()
 print(json.dumps({'apiVersion':'v1','kind':'Secret','metadata':{'name':a[3],'namespace':namespace()},'data':data}));sys.exit()
if a[0]=='apply':
 obj=json.load(sys.stdin);key=obj['metadata']['namespace']+'/'+obj['metadata']['name']
 prior=state['secrets'].get(key,{'data':{}});prior['data'].update(obj['data']);obj['data']=prior['data'];state['secrets'][key]=obj;state['applied'].append(key)
 p.write_text(json.dumps(state));sys.exit()
raise SystemExit('Unexpected mock kubectl arguments: '+repr(a))
'''

NAMESPACES = ['coproc', 'coproc-admin', 'monitoring', 'gw-blockchain', 'eth-blockchain',
              'polygon-blockchain', 'kube-system', 'karpenter']

def encoded(value):
    return base64.b64encode(value.encode()).decode()


class BootstrapTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        kubectl = root / 'kubectl'
        kubectl.write_text(MOCK)
        kubectl.chmod(0o755)
        self.state_file = root / 'state.json'
        secrets = {}
        for ns in NAMESPACES:
            for name in ['coprocessor-user-rds-credentials', 'registry-credentials', 'rpc-credentials',
                         'postgres-exporter-rds-credentials', 'postgres-exporter-config',
                         'sql-exporter-rds-credentials', 'sql-exporter-config',
                         'grafana-cloud-credentials', 'conduit-credentials']:
                secrets[ns+'/'+name] = {'data': {'password': encoded('existing-db-password')}}
        self.state = {'namespaces': NAMESPACES+['bnb-blockchain'], 'secrets': secrets, 'applied': []}
        self.env = dict(os.environ, PATH=str(root)+os.pathsep+os.environ['PATH'],
                        BOOTSTRAP_MOCK_STATE=str(self.state_file))
        self.env.update({k: 'fixture' for k in ['REGISTRY_USER', 'REGISTRY_PASS', 'PROMETHEUS_USER',
                         'PROMETHEUS_PASS', 'LOKI_USER', 'LOKI_PASS', 'OTLP_USER', 'OTLP_PASS']})
        for chain in ['ETHEREUM', 'POLYGON', 'BNB', 'CONDUIT']:
            self.env[chain+'_RPC_URL'] = 'https://rpc.example.invalid'
            self.env[chain+'_RPC_WS_URL'] = 'wss://rpc.example.invalid'

    def run_script(self, *args):
        self.state_file.write_text(json.dumps(self.state))
        result = subprocess.run(['bash', str(SCRIPT), *args], input='yes\n', text=True,
                                capture_output=True, env=self.env)
        self.state = json.loads(self.state_file.read_text())
        return result

    def test_bnb_provisions_shared_credentials_and_exact_rpc_keys(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        secrets = self.state['secrets']
        self.assertEqual(secrets['bnb-blockchain/coprocessor-user-rds-credentials']['data']['password'],
                         encoded('existing-db-password'))
        self.assertIn('bnb-blockchain/registry-credentials', secrets)
        self.assertEqual(secrets['bnb-blockchain/rpc-credentials']['data'], {
            'bnb-rpc-url': encoded(self.env['BNB_RPC_URL']),
            'bnb-rpc-ws-url': encoded(self.env['BNB_RPC_WS_URL'])})
        self.assertEqual(len(self.state['applied']), 3)

    def test_rerun_skips_complete_secrets_without_prompting_for_credentials(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.state['applied'] = []
        for key in list(self.env):
            if key.endswith(('_RPC_URL', '_RPC_WS_URL')) or key in ['REGISTRY_USER', 'REGISTRY_PASS']:
                del self.env[key]
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertEqual(self.state['applied'], [])

    def test_missing_bnb_namespace_fails_before_any_write(self):
        self.state['namespaces'] = NAMESPACES
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing namespaces: bnb-blockchain', result.stdout)
        self.assertEqual(self.state['applied'], [])

    def test_existing_rpc_secret_is_skipped_like_polygon(self):
        existing = {'data': {'bnb-rpc-url': encoded('https://existing.example.invalid')}}
        self.state['secrets']['bnb-blockchain/rpc-credentials'] = existing
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertEqual(self.state['secrets']['bnb-blockchain/rpc-credentials'], existing)
        self.assertNotIn('bnb-blockchain/rpc-credentials', self.state['applied'])

    def test_dry_run_includes_bnb_without_writes(self):
        result = self.run_script('--dry-run')
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn('bnb-rpc-ws-url', result.stdout)
        self.assertEqual(self.state['applied'], [])

    def test_invalid_rpc_schemes_do_not_provision_rpc_secret(self):
        for variable, value in [('BNB_RPC_URL', 'http://rpc.example.invalid'),
                                ('BNB_RPC_WS_URL', 'ws://rpc.example.invalid')]:
            with self.subTest(variable=variable):
                saved = self.env[variable]
                self.env[variable] = value
                result = self.run_script()
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('bnb-blockchain/rpc-credentials', self.state['secrets'])
                self.env[variable] = saved


if __name__ == '__main__':
    unittest.main()
