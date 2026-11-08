import json
from pathlib import Path
import runpy
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
H = runpy.run_path(str(ROOT / 'scripts/check-smal-bootstrap-readiness.py'), run_name='async_test')
OUT = ROOT / 'docs/deployment-2026-10-27'


class AsyncTests(unittest.TestCase):
    def test_existing_evidence_is_not_cluster_execution(self):
        result = H['evaluate'](OUT)
        self.assertEqual(result['status'], 'blocked')
        self.assertTrue(all(result['checks'].values()))
        self.assertIn('safe-cluster-bootstrap-implementation-not-ready', result['blockers'])
        self.assertFalse(result['clusterDeploymentStarted'])
        self.assertIsNone(result['activeGuestBootstrapJob'])
        self.assertFalse(result['automaticApplyOrRetryPermitted'])

    def test_missing_contract_decisions_fail_closed(self):
        names = ['bootstrap-execution-contract.json', 'current-2610-image-approval.json',
                 'private-ssh-stage-2610-image.json', 'current-os-image-2610-pin.json',
                 'private-ssh-post-reboot-hyperv-check.json', 'private-ssh-os-volume-expansion.json']
        with tempfile.TemporaryDirectory(dir='/tmp/opencode') as directory:
            out = Path(directory)
            for name in names:
                (out / name).write_bytes((OUT / name).read_bytes())
            contract = json.loads((out / names[0]).read_text())
            contract['requiredApplyDecisions'] = {}
            (out / names[0]).write_text(json.dumps(contract))
            self.assertIn('apply-decision-contract-missing', H['evaluate'](out)['blockers'])

    def test_checkpoints_are_atomic_and_observer_never_executes(self):
        with tempfile.TemporaryDirectory(dir='/tmp/opencode') as directory:
            path = Path(directory) / 'state.json'
            H['atomic_json'](path, {'status': 'blocked'})
            H['atomic_json'](path, {'status': 'ready-for-human-scope-review'})
            self.assertEqual(json.loads(path.read_text())['status'], 'ready-for-human-scope-review')
            self.assertEqual(len(list(Path(directory).glob('*.tmp'))), 0)
        source = (ROOT / 'scripts/check-smal-bootstrap-readiness.py').read_text()
        for forbidden in ['subprocess', 'os.system', 'shell=True', 'Start-VM', 'Format-Volume', 'Invoke-Expression']:
            self.assertNotIn(forbidden, source)


if __name__ == '__main__':
    unittest.main()
