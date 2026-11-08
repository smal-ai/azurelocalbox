"""Offline R2 tests: mocked controller, real local file races, pure PowerShell guards.

No Azure, SSH, credentials, deployment, worker or canonical startup is invoked.
"""
import copy
from datetime import datetime, timezone, timedelta
import hashlib
import json
import multiprocessing
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
R = runpy.run_path(str(ROOT / 'scripts/smal-capacity-r2.py'), run_name='r2_test')
RG = R['dispatch'].__globals__
I = R['I']; IG = I['begin'].__globals__
M = R['M']
F = runpy.run_path(str(ROOT / 'scripts/test_smal_compute_capacity_20261108.py'), run_name='r2_fixture')


def fixture():
    p, s = F['fixture']()
    p['executionApproval'] = None
    p['baseline']['clusterStatic']['nestedVms'][0]['adapters'] = [{'mac': '02EC000B0000'}]
    for d, size in zip(p['baseline']['cloud']['disks'], [1024] + [256] * 8 + [2048, 4096]):
        d['diskSizeGB'] = size
    owners = {str(i): R['C']['NODES'][i // 8] for i in range(24)}
    p['transitionContract'] = R['contract'](p, owners)
    p['independentReview'] = {'decision': 'accept-exact-r2-source-and-plan', 'reviewer': 'test-only-independent-review', 'sourceFileMapSha256': 'a' * 64}
    p['disruptionHoldReleased'] = True
    p['runtimeReadiness'] = {'trustReferencesVerified': True, 'catalogueContinuationSettled': True}
    p['executionApproval'] = {'parentGo': True, 'unsignedPlanSha256': R['sha'](p),
                              'approvedEffects': ['graceful-shutdown', 'outer-size-only', 'serial-three-guest-profiles', 'canonical-startup']}
    s['clusterStatic'] = copy.deepcopy(p['baseline']['clusterStatic'])
    s['sourceCommit'] = 'b' * 40
    s['clusterHealth'].update(
        nodeStates=[{'name': n, 'state': 'Up'} for n in R['C']['NODES']],
        poolHealth='Healthy', poolOperational=['OK'], unrelatedFailures=[],
        devices=[dict(id=i, owner=n, health='Healthy', operational=['OK'], maintenance=False) for i, n in owners.items()],
        csvStates=[dict(id=str(i), state='Online', accessible=True) for i in range(4)],
        virtualDiskStates=[dict(id=str(i), copies=3, health='Healthy', operational=['OK']) for i in range(5)])
    return p, s


def planned_fixture():
    p, s = fixture(); n = 'LB-NODE01'
    h = s['clusterHealth']
    h['nodeStates'][0]['state'] = 'Down'
    h['poolHealth'] = 'Warning'; h['poolOperational'] = ['Degraded']
    for d in h['devices']:
        if d['owner'] == n:
            d.update(health='Warning', operational=['Lost Communication'], maintenance=False)
    for v in h['virtualDiskStates']:
        v.update(health='Warning', operational=['Degraded', 'Incomplete'])
    proof = dict(selectedNode=n, deviceIds=[str(i) for i in range(8)], rpcReturned=True,
                 eightDevicesMaintenanceVerified=True, planSha256=R['sha'](p), sourceCommit='b' * 40)
    return p, s, proof


def contender(queue, key):
    try:
        I['claim'](key, key, 'remote-worker', 'a' * 64, 'b' * 40, [], 'c' * 64)
        queue.put('claimed')
    except RuntimeError:
        queue.put('blocked')


class InterlockTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/tmp/opencode')
        root = Path(self.temp.name); out = root / 'out'; old = root / 'old'; out.mkdir(); old.mkdir()
        self.out = out
        self.scope = patch.dict(IG, OUT=out, LEGACY=old, ROOT=root, LOCK=root / 'lock')
        self.scope.start()

    def tearDown(self):
        self.scope.stop(); self.temp.cleanup()

    def begin(self):
        I['begin']('a' * 64, 'b' * 40)

    def claim(self):
        self.begin()
        return I['claim']('first', 'first', 'remote-worker', 'a' * 64, 'b' * 40, [], 'c' * 64)

    def proof(self):
        o = {'pid': 123, 'sequence': 3}
        return dict(atUtc=datetime.now(timezone.utc).isoformat(), operationId=I['OPERATION'], planSha256='a' * 64,
                    sourceCommit='b' * 40, stage='first', key='first', identityAndSettingsVerified=True,
                    effectObserved=True, outcome='applied', workerAlive=False, dispatcherAlive=False,
                    rpcPhase='returned', workerIdentityVerified=True, workerSourceVerified=True,
                    observation=o, observationSha256=I['sha'](o))

    def test_timeout_and_new_process_do_not_release_operation(self):
        self.claim()
        for key in ('second', 'different-key'):
            with self.assertRaisesRegex(RuntimeError, 'unresolved'):
                I['claim'](key, key, 'remote-worker', 'a' * 64, 'b' * 40, [], 'c' * 64)
        with self.assertRaisesRegex(RuntimeError, 'unresolved'):
            I['authorise_startup']()

    def test_real_concurrent_keys_only_one_intent(self):
        self.begin(); ctx = multiprocessing.get_context('fork'); q = ctx.Queue()
        workers = [ctx.Process(target=contender, args=(q, key)) for key in ('one', 'two')]
        for w in workers: w.start()
        for w in workers: w.join(10); self.assertEqual(w.exitcode, 0)
        self.assertEqual(sorted(q.get(timeout=2) for _ in workers), ['blocked', 'claimed'])
        self.assertEqual(len(list(self.out.glob('intent-r2-*.json'))), 1)

    def test_crash_after_fsync_intent_is_visible_without_index(self):
        intent = self.claim()
        self.assertTrue((self.out / 'intent-r2-first.json').exists())
        self.assertEqual(I['history']()[1]['first'], intent)
        self.assertFalse((self.out / 'interlock-r2.json').exists())

    def test_dead_pid_and_closed_ssh_are_not_settlement(self):
        self.claim()
        for field, value in [('rpcPhase', 'rpc-pending'), ('workerAlive', True), ('dispatcherAlive', True),
                             ('workerIdentityVerified', False), ('workerSourceVerified', False), ('outcome', 'unknown')]:
            proof = self.proof(); proof[field] = value
            with self.subTest(field=field), self.assertRaises(RuntimeError): I['resolve']('first', proof)
        self.assertFalse((self.out / 'settlement-r2-first.json').exists())

    def test_only_exact_explicit_settlement_releases_then_key_stays_consumed(self):
        self.claim(); I['resolve']('first', self.proof())
        with self.assertRaisesRegex(RuntimeError, 'already'):
            I['claim']('first', 'first', 'remote-worker', 'a' * 64, 'b' * 40, [], 'c' * 64)
        I['claim']('second', 'second', 'remote-worker', 'a' * 64, 'b' * 40, ['first'], 'd' * 64)

    def test_original_intent_and_observation_tampering_rejected(self):
        self.claim(); proof = self.proof(); proof['observation']['pid'] = 999
        with self.assertRaisesRegex(RuntimeError, 'changed'): I['resolve']('first', proof)
        I['resolve']('first', self.proof())
        path = self.out / 'intent-r2-first.json'; row = json.loads(path.read_text()); row['requestSha256'] = 'f' * 64
        path.write_text(json.dumps(row))
        with self.assertRaisesRegex(RuntimeError, 'changed'): I['idle']()

    def test_missing_old_history_never_becomes_empty_history(self):
        with patch.dict(IG, LEGACY=self.out / 'missing'):
            with self.assertRaisesRegex(RuntimeError, 'missing'): I['authorise_startup']()

    def test_original_legacy_uncertainty_and_partial_index_block(self):
        old = IG['LEGACY']; (old / 'operation-old.json').write_text(json.dumps({'mutationRequested': True, 'status': 'uncertain'}))
        with self.assertRaisesRegex(RuntimeError, 'Unresolved original'): self.begin()

    def test_source_writer_root_and_age_fenced(self):
        self.claim()
        p = self.proof(); p['atUtc'] = (datetime.now(timezone.utc) - timedelta(seconds=601)).isoformat()
        with self.assertRaisesRegex(RuntimeError, 'Expired'): I['resolve']('first', p)
        p = self.proof(); p['sourceCommit'] = 'd' * 40
        with self.assertRaisesRegex(RuntimeError, 'binding'): I['resolve']('first', p)


class ControllerHealthTests(unittest.TestCase):
    def test_sealed_contract_and_old_approval_rejection(self):
        p, _ = fixture(); R['validate'](p, True)
        p['transitionContract']['stages']['memory-lb-node01']['effect'] = 'cpu'
        with self.assertRaises(ValueError): R['validate'](p, True)

    def test_held_disruption_and_missing_review_fail_closed(self):
        for field, value in [('disruptionHoldReleased', False), ('independentReview', None)]:
            p, _ = fixture(); p[field] = value
            with self.assertRaises((ValueError, TypeError)): R['validate'](p, True)

    def test_expected_selected_off_degradation_is_admitted_not_strict(self):
        p, s, proof = planned_fixture()
        self.assertEqual(R['health'](s, p, 'LB-NODE01', proof), 'selected-node-maintenance-admitted')
        with self.assertRaises(ValueError): R['health'](s, p)

    def test_unknown_or_surviving_node_failure_never_admitted(self):
        for device, field, value in [(8, 'health', 'Warning'), (0, 'operational', ['IO Error']),
                                      (0, 'health', 'Unhealthy'), (0, 'owner', 'LB-NODE03')]:
            p, s, proof = planned_fixture(); s['clusterHealth']['devices'][device][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): R['health'](s, p, 'LB-NODE01', proof, True)

    def test_exact_associated_native_repair_allows_resume_not_next_outage(self):
        p, s, proof = planned_fixture()
        s['clusterHealth']['activeStorageJobs'] = [dict(name='Repair', state='4', percentComplete=21,
            poolId=p['baseline']['clusterStatic']['poolId'], affectedVirtualDiskIds=['0'], affectedDeviceIds=['0'])]
        self.assertEqual(R['health'](s, p, 'LB-NODE01', proof, True), 'selected-node-maintenance-admitted')
        with self.assertRaises(ValueError): R['health'](s, p, 'LB-NODE01', proof)
        native = copy.deepcopy(s); native['clusterHealth']['activeStorageJobs'][0]['affectedDeviceIds'] = []
        with self.assertRaises(ValueError): R['health'](native, p, 'LB-NODE01', proof, True)
        for field, value in [('affectedVirtualDiskIds', []), ('poolId', 'other'), ('affectedDeviceIds', ['8'])]:
            bad = copy.deepcopy(s); bad['clusterHealth']['activeStorageJobs'][0][field] = value
            with self.assertRaises(ValueError): R['health'](bad, p, 'LB-NODE01', proof, True)

    def test_csv_access_and_healthy_no_jobs_required(self):
        p, s = fixture(); R['health'](s, p)
        s['clusterHealth']['csvStates'][0]['accessible'] = False
        with self.assertRaisesRegex(ValueError, 'CSV'): R['health'](s, p)

    def test_infrastructure_migration_is_global_not_old_owner_pinned(self):
        p, s = fixture()
        s['nodeCapacity']['LB-NODE01']['bridgePlacement'] = []
        s['nodeCapacity']['LB-NODE03']['bridgePlacement'] = [{'id': p['infrastructureVmId'], 'hciNode': 'LB-NODE03'}]
        R['health'](s, p)
        s['clusterStatic']['nestedVms'][0]['adapters'][0]['mac'] = 'bad'
        with self.assertRaisesRegex(ValueError, 'identity'): R['health'](s, p)

    def test_explicit_compensation_preserves_each_settled_profile(self):
        p, _ = fixture(); stages = p['transitionContract']['stages']
        for boundary in ('drain', 'stop', 'memory', 'cpu'):
            original = stages[boundary + '-lb-node01']
            resume = stages['comp-resume-' + boundary + '-lb-node01']
            self.assertEqual(resume['beforeProfiles'], original['afterProfiles'])
            self.assertEqual(resume['beforeStates']['LB-NODE01'], 'Running')
            self.assertEqual(resume['effect'], 'resume')
        self.assertEqual(stages['drain-lb-node02']['predecessors'], ['converge-lb-node01'])

    def test_renderer_deterministic_bound_and_no_legacy_effects(self):
        p, _ = fixture(); ctx = R['context'](p, 'memory-lb-node01', 'dispatch')
        data = R['render_context'](ctx, 'b' * 40)
        self.assertEqual(data, R['render_context'](ctx, 'b' * 40))
        self.assertLess(len(data), 2 * 1024**2)
        self.assertIn(b'$workerSha256=', data)
        for forbidden in (b'-TurnOff', b'Remove-VM ', b'Resize-VHD', b'Move-VMStorage'):
            self.assertNotIn(forbidden, data)

    def test_transport_timeout_keeps_durable_intent_and_blocks_new_key(self):
        p, s = fixture(); e = p['transitionContract']['stages']['cluster-stop']
        s['hostCapacity'].update(logicalProcessors=32, physicalCores=16, memoryBytes=256 * 1024**3, numa=[{'logicalProcessors': 32}])
        for n, cap in s['nodeCapacity'].items():
            cap.update(logicalProcessors=8, memoryBytes=64 * 1024**3, numa=[{'logicalProcessors': 8}],
                       bridgePlacement=[{'id': p['infrastructureVmId'], 'state': 'Running'}] if n == 'LB-NODE03' else [])
        s['clusterHealth']['vmResources'] = [{'vmIds': [p['infrastructureVmId']], 'ownerNode': 'LB-NODE03', 'state': 'Online'}]
        cloud = dict(atUtc=R['C']['now'](), projection=p['baseline']['cloud'], size=p['beforeSize'], power='PowerState/running')
        admission = dict(atUtc=R['C']['now'](), mutationPerformed=False, sourceCommit='b' * 40,
                         planSha256=R['sha'](p), stage='cluster-stop', quotaPolicyAndScheduleChecked=True,
                         exclusiveParentWriter=True, snapshot=s, cloud=cloud)
        with tempfile.TemporaryDirectory(dir='/tmp/opencode') as d:
            root = Path(d); out = root / 'out'; old = root / 'old'; out.mkdir(); old.mkdir()
            t = Mock(side_effect=subprocess.TimeoutExpired('mock-ssh', 90))
            with patch.dict(IG, OUT=out, LEGACY=old, ROOT=root, LOCK=root / 'lock'), patch.dict(RG, source_guard=Mock(return_value='b' * 40), transport=t):
                with self.assertRaises(subprocess.TimeoutExpired): R['dispatch'](p, 'cluster-stop', admission)
                with self.assertRaisesRegex(RuntimeError, 'unresolved'): I['authorise_startup']()
                with self.assertRaisesRegex(RuntimeError, 'unresolved'): R['dispatch'](p, 'cluster-stop', admission)
                self.assertEqual(t.call_count, 1)
                self.assertTrue((out / 'intent-r2-cluster-stop.json').exists())

    def test_powershell_parser_and_native_storage_guard(self):
        files = ['smal-compute-capacity-20261108-common.ps1', 'smal-compute-capacity-20261108-worker.ps1',
                 'smal-capacity-dispatch-r2.ps1', 'smal-capacity-startup-interlock.ps1', 'start-smal-existing-guests.ps1']
        command = "foreach($f in @(" + ','.join("'" + str(ROOT / 'scripts' / f) + "'" for f in files) + ")){$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$t,[ref]$e);if($e.Count){$e|Out-String|Write-Error;exit 2}}"
        p, s, proof = planned_fixture()
        command += "$ComputeCapacityLibraryOnly=$true;. '" + str(ROOT / 'scripts/smal-compute-capacity-20261108-common.ps1') + "';"
        for name, value in [('plan', p), ('snapshot', s), ('proof', proof)]:
            command += '$' + name + "='" + json.dumps(value).replace("'", "''") + "'|ConvertFrom-Json;"
        command += "$planSha='" + R['sha'](p) + "';$sourceCommit='" + 'b' * 40 + "';Assert-ComputeMaintenanceHealth $snapshot 'LB-NODE01' $proof $true;"
        command += "$snapshot.clusterHealth.devices[8].health='Warning';$rejected=$false;try{Assert-ComputeMaintenanceHealth $snapshot 'LB-NODE01' $proof $true}catch{$rejected=$true};if(-not $rejected){exit 3}"
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', command], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
