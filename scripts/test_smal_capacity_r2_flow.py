"""Synthetic full-route tests. Every provider/transport/release gate is mocked.

Only temporary local receipts are materialised. Never calls operational CLI main,
canonical startup, Azure, SSH, detached workers or protected credential functions.
"""
import copy
import contextlib
import io
import json
from pathlib import Path
import re
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
T = runpy.run_path(str(ROOT / 'scripts/test_smal_capacity_r2.py'), run_name='r2_flow_fixture')
R, I = T['R'], T['I']
RG, IG = R['dispatch'].__globals__, I['begin'].__globals__
COMMIT = 'b' * 40


def snapshot(plan, stage, after=False):
    _, s = T['fixture']()
    e = plan['transitionContract']['stages'][stage]
    profiles = e['afterProfiles' if after else 'beforeProfiles']
    states = e['afterStates' if after else 'beforeStates']
    s['states'] = dict(states)
    for g in s['guestsStatic']:
        g.update(profiles[g['name']])
    s['hostCapacity'].update(logicalProcessors=e['hostCpu'], physicalCores=e['hostCpu'] // 2,
                            memoryBytes=(256 if e['hostCpu'] == 32 else 512) * 1024**3,
                            numa=[{'logicalProcessors': e['hostCpu']}])
    profile = e['observeHealth'] if after else e['health']
    if profile == 'stopped':
        # Unseen bridge/cluster is explicit, not a preservation assertion.
        s.update(clusterStatic=None, clusterHealth=None, nodeCapacity={})
        return s
    selected = e['node']
    if selected:
        state = e['afterClusterState' if after else 'beforeClusterState']
        next(n for n in s['clusterHealth']['nodeStates'] if n['name'] == selected)['state'] = state
        if state != 'Up':
            for d in s['clusterHealth']['devices']:
                if d['owner'] == selected:
                    d.update(health='Warning', maintenance=state == 'Paused', operational=['In Maintenance Mode'] if state == 'Paused' else ['Lost Communication'])
            s['clusterHealth'].update(allNodesUp=False, poolHealthy=False, allMirrorsHealthy=False,
                                     poolHealth='Warning', poolOperational=['Degraded'])
            for v in s['clusterHealth']['virtualDiskStates']:
                v.update(health='Warning', operational=['Degraded'])
    s['nodeCapacity'] = {n: dict(logicalProcessors=profiles[n]['cpu'], memoryBytes=profiles[n]['memory'],
        freeMemoryBytes=40 * 1024**3, numa=[{'logicalProcessors': profiles[n]['cpu']}], bridgePlacement=[])
        for n in R['C']['NODES'] if states[n] == 'Running'}
    # The bridge legitimately migrates to whichever survivor remains available.
    owner = sorted(s['nodeCapacity'])[-1]
    s['nodeCapacity'][owner]['bridgePlacement'] = [{'id': plan['infrastructureVmId'], 'state': 'Running'}]
    s['clusterHealth']['vmResources'] = [{'vmIds': [plan['infrastructureVmId']], 'ownerNode': owner, 'state': 'Online'}]
    return s


class FullRouteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/tmp/opencode')
        root = Path(self.temp.name); self.out = root / 'out'; old = root / 'old'; self.out.mkdir(); old.mkdir()
        self.plan, _ = T['fixture']()
        self.plan_path = self.out / 'plan.sealed.json'
        self.plan_path.write_text(json.dumps(self.plan))  # Synthetic fixture, temporary root only.
        self.scopes = [patch.dict(IG, OUT=self.out, LEGACY=old, ROOT=root, LOCK=root / 'lock'),
                       patch.dict(RG, source_guard=Mock(return_value=COMMIT), transport=Mock(return_value={'launchReturned': True}))]
        for scope in self.scopes: scope.start()

    def tearDown(self):
        for scope in reversed(self.scopes): scope.stop()
        self.temp.cleanup()

    def pure_powershell(self, body, variables=None):
        command = "$ErrorActionPreference='Stop';$ComputeCapacityLibraryOnly=$true;. '" + str(ROOT / 'scripts/smal-compute-capacity-20261108-common.ps1') + "';"
        values = dict(plan=self.plan, stage='complete', effectKey='complete', sourceCommit=COMMIT, planSha=R['sha'](self.plan))
        values.update(variables or {})
        for name, value in values.items():
            command += '$' + name + "='" + json.dumps(value).replace("'", "''") + "'|ConvertFrom-Json;"
        command += "$ComputeCapacityWorkerLibraryOnly=$true;. '" + str(ROOT / 'scripts/smal-compute-capacity-20261108-worker.ps1') + "';"
        command += ". '" + str(ROOT / 'scripts/smal-capacity-startup-interlock.ps1') + "';"
        command += body
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', command], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def cloud(self, stage, after=False):
        e = self.plan['transitionContract']['stages'][stage]
        size = self.plan['beforeSize'] if e['hostCpu'] == 32 else self.plan['targetSize']
        power = 'PowerState/running'
        if stage == 'deallocate' and after or stage == 'host-size': power = 'PowerState/deallocated'
        if stage == 'host-size' and after: size = self.plan['targetSize']
        return dict(atUtc=R['C']['now'](), projection=copy.deepcopy(self.plan['baseline']['cloud']), size=size, power=power, etag='synthetic-etag')

    def admission(self, stage):
        return dict(atUtc=R['C']['now'](), mutationPerformed=False, sourceCommit=COMMIT,
                    planSha256=R['sha'](self.plan), stage=stage, quotaPolicyAndScheduleChecked=True,
                    exclusiveParentWriter=True, snapshot=self.sample_snapshot(stage), cloud=self.cloud(stage),
                    allExactGuestsOff=True, clusterStopped=True)

    def observation(self, stage, outcome='applied'):
        e = self.plan['transitionContract']['stages'][stage]
        s = self.sample_snapshot(stage, after=outcome == 'applied')
        o = dict(atUtc=R['C']['now'](), operationId=I['OPERATION'], mutationPerformed=False, sourceCommit=COMMIT,
                 planSha256=R['sha'](self.plan), key=stage, stage=stage, outcome=outcome, snapshot=s,
                 dispatcherAlive=False, workerAlive=False, rpcPhase='returned', workerIdentityVerified=True, workerSourceVerified=True)
        o['cloud'] = self.cloud(stage, True)
        if e['effect'].startswith('azure-'):
            o.update(cloud=self.cloud(stage, True), azureProvisioningState='Succeeded', azureTransitionSettled=True)
            return o
        rendered = R['render_context'](R['context'](self.plan, stage, 'observe'), COMMIT).decode()
        source_hash = re.search(r"\$workerSha256='([A-F0-9]{64})'", rendered)[1]
        worker = dict(operationId=I['OPERATION'], key=stage, stage=stage, sourceCommit=COMMIT,
                      planSha256=R['sha'](self.plan), sourceSha256=source_hash, sequence=3,
                      pid=99999999, processStartedUtc='2026-11-08T00:00:00Z', phase='returned',
                      rpcSucceeded=outcome == 'applied', rpcInvoked=outcome == 'applied')
        o['worker'] = worker
        o['request'] = {f: worker[f] for f in ('operationId', 'key', 'stage', 'sourceCommit', 'planSha256', 'pid', 'processStartedUtc')}
        if e['effect'] == 'drain' and outcome == 'applied':
            worker['drainProof'] = dict(selectedNode=e['node'], deviceIds=[i for i, n in self.plan['transitionContract']['deviceOwners'].items() if n == e['node']],
                                       rpcReturned=True, eightDevicesMaintenanceVerified=True, planSha256=R['sha'](self.plan), sourceCommit=COMMIT)
        if e['effect'] == 'cluster-stop': o['clusterServices'] = {n: 'Stopped' if outcome == 'applied' else 'Running' for n in R['C']['NODES']}
        if e['effect'] == 'startup-grant':
            worker['remoteGrant'] = dict(operationId=I['OPERATION'], key=e['startupKey'], stage=e['startupKey'], grantStage=stage,
                atUtc=R['C']['now'](), planSha256=R['sha'](self.plan), sourceCommit=COMMIT,
                states=e['beforeStates'], profiles=e['beforeProfiles'], hostCpu=e.get('startupHostCpu', e['hostCpu']),
                guests=s['guestsStatic'], hostStatic=s['hostStatic'], volumesStatic=s['volumesStatic'])
            worker['remoteGrant']['startupEntry'] = self.plan['transitionContract']['stages'][e['startupKey']]
            worker['remoteGrant']['maintenanceContext'] = dict(baseline={'clusterStatic': self.plan['baseline']['clusterStatic']},
                admission={f: self.plan['admission'][f] for f in ('requiredPhysicalFreeBytes', 'repairReserveBytes')},
                deviceOwners=self.plan['transitionContract']['deviceOwners']) if e['node'] else None
        if e['effect'] == 'canonical-startup':
            o['remoteStartup'] = dict(worker, helperSha256=re.search(r"\$startupHelperSha256='([A-F0-9]{64})'", rendered)[1])
        if e['effect'] == 'complete':
            worker['completionSnapshot'] = copy.deepcopy(s)
            o['remoteCompletion'] = dict(operationId=I['OPERATION'], key=stage, stage=stage, sourceCommit=COMMIT,
                                        planSha256=R['sha'](self.plan), atUtc=R['C']['now'](), snapshot=copy.deepcopy(s))
        return o

    def sample_snapshot(self, stage, after=False):
        s = snapshot(self.plan, stage, after)
        e = self.plan['transitionContract']['stages'][stage]
        if getattr(self, 'active_repair', False) and ((e['observeHealth'] if after else e['health']) == 'maintenance' or e['effect'] == 'converge'):
            s['clusterHealth']['activeStorageJobs'] = [dict(name='Repair', poolId=self.plan['baseline']['clusterStatic']['poolId'],
                                                          affectedVirtualDiskIds=['0'], affectedDeviceIds=['0'])]
        return s

    def run_stage(self, stage, outcome='applied'):
        e = self.plan['transitionContract']['stages'][stage]
        if e['effect'] == 'converge':
            return R['converge'](self.plan, stage, self.observation(stage))
        if e['effect'] == 'canonical-startup':
            evidence = self.admission(stage)
            if stage == 'startup-outer': evidence['cloud']['power'] = 'PowerState/deallocated'
            path = R['handover'](self.plan, stage, evidence, self.plan_path)
            I['authorise_startup'](path, COMMIT)
        else:
            with patch.dict(R['C']['get_cloud'].__globals__, get_cloud=Mock(return_value=self.cloud(stage)), az=Mock()):
                # C is a runpy namespace, so patch entries as well as function globals.
                with patch.dict(R['C'], get_cloud=Mock(return_value=self.cloud(stage)), az=Mock()):
                    R['dispatch'](self.plan, stage, self.admission(stage))
        with self.assertRaisesRegex(RuntimeError, 'unresolved'): I['idle']()
        return R['settle'](self.plan, stage, self.observation(stage, outcome))

    def reach(self, last):
        for stage in self.plan['transitionContract']['stages']:
            if stage.startswith('comp-'): break
            self.run_stage(stage)
            if stage == last: return

    def test_full_mocked_route_requires_every_settlement_and_final_certificate(self):
        self.reach('complete')
        observed = self.observation('complete')
        observed['remoteCompletion'] = I['idle']()[2]['complete']['proof']['observation']['remoteCompletion']
        R['finish'](self.plan, observed)
        self.assertIsNone(I['authorise_startup'](expected_source=COMMIT))
        with self.assertRaises((RuntimeError, FileExistsError)): R['finish'](self.plan, observed)

    def test_not_applied_memory_cannot_admit_normal_cpu(self):
        self.reach('stop-lb-node01'); self.run_stage('memory-lb-node01', 'not-applied')
        with self.assertRaisesRegex(RuntimeError, 'Applied prerequisite'):
            R['dispatch'](self.plan, 'cpu-lb-node01', self.admission('cpu-lb-node01'))
        self.run_stage('comp-grant-stop-lb-node01')
        self.run_stage('comp-start-stop-lb-node01')
        self.run_stage('comp-resume-stop-lb-node01')
        self.run_stage('comp-converge-stop-lb-node01')
        with self.assertRaises(RuntimeError): R['dispatch'](self.plan, 'drain-lb-node02', self.admission('drain-lb-node02'))

    def test_compensation_after_applied_memory_preserves_8cpu_128gib(self):
        self.reach('memory-lb-node01')
        for stage in ('comp-grant-memory-lb-node01', 'comp-start-memory-lb-node01', 'comp-resume-memory-lb-node01', 'comp-converge-memory-lb-node01'):
            self.run_stage(stage)
        e = self.plan['transitionContract']['stages']['comp-converge-memory-lb-node01']
        self.assertEqual(e['afterProfiles']['LB-NODE01'], dict(cpu=8, memory=128 * 1024**3))

    def test_compensation_repair_before_grant_start_and_resume_then_strict_convergence(self):
        self.reach('stop-lb-node01'); self.active_repair = True
        with self.assertRaisesRegex(ValueError, 'storage job'):
            R['dispatch'](self.plan, 'memory-lb-node01', self.admission('memory-lb-node01'))
        for stage in ('comp-grant-stop-lb-node01', 'comp-start-stop-lb-node01', 'comp-resume-stop-lb-node01'):
            self.run_stage(stage)
            self.assertTrue(I['idle']()[2][stage]['proof']['observation']['snapshot']['clusterHealth']['activeStorageJobs'])
        stage = 'comp-converge-stop-lb-node01'
        with self.assertRaisesRegex(ValueError, 'converged'): R['converge'](self.plan, stage, self.observation(stage))
        self.active_repair = False
        self.run_stage(stage)
        with self.assertRaises(RuntimeError): R['dispatch'](self.plan, 'drain-lb-node02', self.admission('drain-lb-node02'))

    def test_actual_powershell_compensation_grant_and_prestart_health_with_repair(self):
        self.reach('stop-lb-node01'); self.active_repair = True
        stage = 'comp-grant-stop-lb-node01'; s = self.sample_snapshot(stage)
        grant = self.observation(stage)['worker']['remoteGrant']
        proof = R['drain_proof'](self.plan, stage, I['idle']()[2])
        body = "Assert-R2Snapshot $snapshot $entry.beforeProfiles $entry.beforeStates $proof;Assert-CapacityStartupSnapshot $snapshot $grant $proof;"
        body += "$snapshot.clusterHealth.activeStorageJobs[0].affectedDeviceIds=@();$rejected=$false;try{Assert-CapacityStartupSnapshot $snapshot $grant $proof}catch{$rejected=$true};if(-not $rejected){exit 3}"
        self.pure_powershell(body, dict(stage=stage, effectKey=stage, snapshot=s, grant=grant, proof=proof))

    def test_actual_powershell_after_drain_uses_observe_health_not_preflight_strict(self):
        stage = 'drain-lb-node01'; s = snapshot(self.plan, stage, after=True)
        proof = self.observation(stage)['worker']['drainProof']
        R['verify_snapshot'](s, self.plan, self.plan['transitionContract']['stages'][stage], after=True, drain=proof, expected_source=COMMIT)
        body = "Assert-R2Snapshot $snapshot $entry.afterProfiles $entry.afterStates $proof $true;$rejected=$false;try{Assert-R2Snapshot $snapshot $entry.beforeProfiles $entry.beforeStates $proof}catch{$rejected=$true};if(-not $rejected){exit 3}"
        self.pure_powershell(body, dict(stage=stage, effectKey=stage, snapshot=s, proof=proof))

    def test_snapshot_source_is_checked_for_strict_and_stopped_cloud_stages(self):
        for stage in ('cluster-stop', 'shutdown-lb-node01', 'deallocate', 'host-size'):
            s = snapshot(self.plan, stage); s['sourceCommit'] = 'a' * 40
            with self.subTest(stage=stage), self.assertRaisesRegex(ValueError, 'execution source'):
                R['verify_snapshot'](s, self.plan, self.plan['transitionContract']['stages'][stage], expected_source=COMMIT)
        body = "$rejected=$false;try{Assert-R2Snapshot $snapshot $entry.beforeProfiles $entry.beforeStates}catch{$rejected=$true};if(-not $rejected){exit 3};"
        request = dict(operationId=I['OPERATION'], key='complete', stage='complete', sourceCommit=COMMIT, planSha256=R['sha'](self.plan))
        operation = {f: request[f] for f in ('operationId', 'sourceCommit', 'planSha256')}
        body += "Assert-R2Context $request $operation;$request.operationId='wrong';$rejected=$false;try{Assert-R2Context $request $operation}catch{$rejected=$true};if(-not $rejected){exit 4};$request.operationId=$plan.operationId;$operation.operationId='wrong';$rejected=$false;try{Assert-R2Context $request $operation}catch{$rejected=$true};if(-not $rejected){exit 5}"
        s = snapshot(self.plan, 'complete', True); s['sourceCommit'] = 'a' * 40
        self.pure_powershell(body, dict(snapshot=s, request=request, operation=operation))

    def test_actual_completion_and_event_writers_roundtrip_nested_hashtables(self):
        s = snapshot(self.plan, 'complete', True)
        # Extra nested fields reproduce real VHD/controller/settings and operational arrays.
        s['guestsStatic'][1]['disks'][0]['nativeDetails'] = {'attachment': {'identity': {'id': 'retained-vhd', 'path': 'V:\\original.vhdx'}}}
        s['clusterHealth']['devices'][0]['operational'] = ['OK']
        body = "$snapshot.atUtc='" + s['atUtc'] + "';function To-TestHashtable($v){if($null -eq $v){return $null};if($v.GetType() -eq [System.Management.Automation.PSCustomObject]){$h=@{};foreach($p in $v.PSObject.Properties){$h[$p.Name]=To-TestHashtable $p.Value};return $h};if($v -is [array]){$a=@(foreach($i in $v){To-TestHashtable $i});return ,$a};return $v};$snapshot=To-TestHashtable $snapshot;"
        body += "$capacityRoot='" + str(self.out) + "';Write-R2Completion $snapshot (Join-Path $capacityRoot 'completion-native.json');$state.completionSnapshot=$snapshot;Save-R2Worker 'returned';Write-CapacityStartupEvent @{snapshot=$snapshot;sequence=1;phase='returned'} (Join-Path $capacityRoot 'startup-native.json');"
        # Load the actual dispatcher writer definition, never its operational body.
        body += "$t=$null;$e=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile('" + str(ROOT / 'scripts/smal-capacity-dispatch-r2.ps1') + "',[ref]$t,[ref]$e);$f=$ast.Find({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Write-R2Json'},$true);. ([ScriptBlock]::Create($f.Extent.Text));Write-R2Json (Join-Path $capacityRoot 'request-native.json') @{snapshot=$snapshot;phase='request'};"
        body += "$round=Get-Content (Join-Path $capacityRoot 'completion-native.json') -Raw|ConvertFrom-Json;Assert-ComputeEqual $round.snapshot.guestsStatic $snapshot.guestsStatic 'completion guest roundtrip';Assert-ComputeEqual $round.snapshot.clusterHealth $snapshot.clusterHealth 'completion storage roundtrip';$rejected=$false;try{Write-R2Completion $snapshot (Join-Path $capacityRoot 'completion-native.json')}catch{$rejected=$true};if(-not $rejected){exit 3}"
        self.pure_powershell(body, dict(snapshot=s))
        for name in ('completion-native.json', 'worker-complete-event-1.json', 'startup-native.json', 'request-native.json'):
            row = json.loads((self.out / name).read_text())
            actual = row.get('snapshot', row.get('completionSnapshot'))
            self.assertEqual(actual, s)
            self.assertEqual(len(actual['clusterHealth']['devices']), 24)
            self.assertEqual(len(actual['guestsStatic'][1]['disks']), 9)
            self.assertNotIn('System.Collections.Hashtable', (self.out / name).read_text())

    def test_actual_json_writer_fails_before_creating_truncated_or_oversized_file(self):
        body = "$deep=@{leaf='value'};1..45|ForEach-Object{$deep=@{nested=$deep}};$path='" + str(self.out / 'must-not-exist.json') + "';$rejected=$false;try{Write-ComputeNewJson $path $deep}catch{$rejected=$true};if(-not $rejected -or (Test-Path $path)){exit 3};"
        body += "$rejected=$false;try{Write-ComputeNewJson $path @{oversize=('x' * (2MB + 1))}}catch{$rejected=$true};if(-not $rejected -or (Test-Path $path)){exit 4}"
        body += ";$rejected=$false;try{Write-ComputeNewJson $path @{unsupported=[version]::new(1,2)}}catch{$rejected=$true};if(-not $rejected -or (Test-Path $path)){exit 5}"
        self.pure_powershell(body)
        self.assertFalse((self.out / 'must-not-exist.json').exists())

    def test_actual_process_probe_preserves_live_identity_after_json_datetime_conversion(self):
        body = "$t=$null;$e=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile('" + str(ROOT / 'scripts/smal-capacity-dispatch-r2.ps1') + "',[ref]$t,[ref]$e);$f=$ast.Find({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Test-R2Alive'},$true);. ([ScriptBlock]::Create($f.Extent.Text));"
        body += "$row=@{pid=$PID;processStartedUtc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')};$round=(ConvertTo-ComputeJson $row)|ConvertFrom-Json;if((Test-R2Alive $round) -ne $true){exit 3};$round.processStartedUtc=([datetimeoffset](Get-ComputeUtcStamp $row.processStartedUtc)).AddSeconds(-1).UtcDateTime;if((Test-R2Alive $round) -ne $false){exit 4};$rejected=$false;try{Get-ComputeUtcStamp '2026-11-08T10:00:00'}catch{$rejected=$true};if(-not $rejected){exit 5}"
        self.pure_powershell(body)

    def test_not_applied_drain_cannot_stop_guest(self):
        self.reach('startup-outer'); self.run_stage('drain-lb-node01', 'not-applied')
        with self.assertRaises((RuntimeError, ValueError)):
            R['dispatch'](self.plan, 'stop-lb-node01', self.admission('stop-lb-node01'))

    def test_unconsumed_startup_handover_blocks_capacity_and_is_one_use(self):
        self.reach('grant-lb-node01')
        stage = 'startup-lb-node01'
        path = R['handover'](self.plan, stage, self.admission(stage), self.plan_path)
        with self.assertRaisesRegex(RuntimeError, 'handover'):
            I['claim']('collision', 'collision', 'remote-worker', R['sha'](self.plan), COMMIT, [], 'c' * 64)
        I['authorise_startup'](path, COMMIT)
        with self.assertRaisesRegex(RuntimeError, 'unresolved'): I['authorise_startup'](path, COMMIT)

    def test_startup_cannot_settle_bare_booleans_or_changed_event(self):
        self.reach('grant-lb-node01'); stage = 'startup-lb-node01'
        path = R['handover'](self.plan, stage, self.admission(stage), self.plan_path); I['authorise_startup'](path, COMMIT)
        for field, value in [('helperSha256', 'A' * 64), ('key', 'wrong'), ('phase', 'rpc-pending')]:
            observed = self.observation(stage); observed['remoteStartup'][field] = value
            with self.assertRaises(ValueError): R['settle'](self.plan, stage, observed)

    def test_finish_rejects_bare_flags_and_unbound_completion_snapshot(self):
        self.reach('complete')
        with self.assertRaises((KeyError, ValueError)): R['finish'](self.plan, {'atUtc': R['C']['now'](), 'allHealthyAndOk': True})
        observed = self.observation('complete'); observed['remoteCompletion']['snapshot']['states']['LB-DC01'] = 'Off'
        with self.assertRaises(ValueError): R['finish'](self.plan, observed)

    def test_worker_hash_independent_of_dispatch_observe_and_settlement_payload(self):
        stage = 'memory-lb-node01'; hashes = []
        projected_fixture = {'synthetic': {'intentSha256': 'c' * 64, 'proof': {'outcome': 'applied', 'observation': {'unused': 'different'}}}}
        for mode, settled in [('dispatch', {}), ('observe', {}), ('dispatch', projected_fixture)]:
            text = R['render_context'](R['context'](self.plan, stage, mode, settled), COMMIT).decode()
            hashes.append(re.search(r"\$workerSha256='([A-F0-9]{64})'", text)[1])
        self.assertEqual(len(set(hashes)), 1)

    def test_direct_transport_cannot_bypass_durable_intent(self):
        I['begin'](R['sha'](self.plan), COMMIT)
        ctx = R['context'](self.plan, 'cluster-stop', 'dispatch')
        with self.assertRaisesRegex(ValueError, 'intent'): R['authorise_transport'](ctx, COMMIT)
        I['claim']('cluster-stop', 'cluster-stop', 'remote-worker', R['sha'](self.plan), COMMIT, [], R['sha'](self.plan['transitionContract']['stages']['cluster-stop']))
        R['authorise_transport'](ctx, COMMIT)
        with self.assertRaises(ValueError): R['authorise_transport'](ctx, 'a' * 40)

    def test_remote_settlement_projection_does_not_repeat_full_inventory(self):
        self.reach('startup-outer')
        settled = I['idle']()[2]; projected = R['settlement_projection'](settled)
        for key, row in projected.items():
            self.assertNotIn('snapshot', row['proof']['observation'])
            self.assertNotIn('cloud', row['proof']['observation'])
            self.assertEqual(row['originalSettlementSha256'], R['sha'](settled[key]))
        self.assertEqual(I['idle']()[2], settled)

    def test_canonical_main_mocked_host_and_guests_still_requires_independent_settlement(self):
        self.reach('host-size'); stage = 'startup-outer'
        evidence = self.admission(stage); evidence['cloud']['power'] = 'PowerState/deallocated'
        handover = R['handover'](self.plan, stage, evidence, self.plan_path)
        startup = runpy.run_path(str(ROOT / 'scripts/start-smal-localbox.py'), run_name='canonical_mocked_main')
        sg = startup['main'].__globals__; local_root = self.out.parent
        output = local_root / 'docs/deployment-2026-10-29'; output.mkdir(parents=True)
        private_out = local_root / 'docs/deployment-2026-10-27'; private_out.mkdir(parents=True)

        def private(script, key, startup_context=None):
            self.assertEqual(script, 'scripts/start-smal-existing-guests.ps1')
            self.assertEqual(startup_context['key'], stage)
            receipt = dict(status='complete', result=dict(registrationInvoked=False, registrationMarkersChanged=False,
                guests=[dict(name=n, id=i, after='Running', heartbeatReady=True) for n, i in R['C']['GUESTS'].items()]))
            (private_out / ('private-ssh-' + key + '.json')).write_text(json.dumps(receipt))
            return 0

        controller = dict(R, OUT=self.out, source_guard=Mock(return_value=COMMIT), C=dict(R['C'], get_cloud=Mock(return_value=evidence['cloud'])))
        modules = {'smal-capacity-interlock.py': I, 'smal-capacity-r2.py': controller, 'smal-private-powershell.py': {'main': private}}
        loader = Mock(run_path=lambda path, **kwargs: modules[Path(path).name])
        account = dict(id=R['C']['SUB'], tenantId=R['C']['TENANT'], state='Enabled')
        provider = Mock(return_value=account)
        initial = dict(power='PowerState/deallocated', agentReady=False); ready = dict(power='PowerState/running', agentReady=True)
        with patch.dict(sg, ROOT=local_root, OUT=output, START_LOCK=local_root / 'canonical-test.lock', verify_source=Mock(return_value=COMMIT),
                        ensure_private_vpn=Mock(), az=provider, host_state=Mock(side_effect=[initial, ready]), runpy=loader):
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(startup['main'](60, handover), 0)
        self.assertEqual(provider.call_count, 2)  # account GET and one mocked host start.
        with self.assertRaisesRegex(RuntimeError, 'unresolved'): I['idle']()
        R['settle'](self.plan, stage, self.observation(stage))
        I['idle']()

    def test_proven_not_applied_and_missing_process_identity_remain_distinct(self):
        self.reach('stop-lb-node01')
        stage = 'memory-lb-node01'
        R['dispatch'](self.plan, stage, self.admission(stage))
        for field, value in [('pid', 0), ('sourceSha256', 'A' * 64), ('rpcInvoked', True)]:
            observed = self.observation(stage, 'not-applied'); observed['worker'][field] = value
            with self.assertRaises(ValueError): R['settle'](self.plan, stage, observed)

    def test_completion_marker_without_settlement_never_releases_startup(self):
        I['begin'](R['sha'](self.plan), COMMIT)
        (self.out / 'completion-r2.json').write_text(json.dumps({'planSha256': R['sha'](self.plan), 'settlementHashes': {}}))
        with self.assertRaises((KeyError, RuntimeError)): I['authorise_startup'](expected_source=COMMIT)

    def test_origin_guard_rejects_another_repository_with_the_same_sha(self):
        references = runpy.run_path(str(ROOT / 'scripts/smal-localbox-references.py'))
        with patch.dict(references['verify_origin'].__globals__, subprocess=Mock(check_output=Mock(return_value='https://github.com/other/azurelocalbox\n'))):
            with self.assertRaisesRegex(RuntimeError, 'origin'): references['verify_origin']()

    def test_historical_binding_verifier_has_no_patch_executor_and_checks_unknowns(self):
        h = runpy.run_path(str(ROOT / 'scripts/smal-aks-binding-history.py'))
        self.assertNotIn('apply', h); self.assertNotIn('az', h)
        cl = dict(id=h['CL'], properties=dict(clusterExtensionIds=[h['VM_EXT']], hostResourceId=h['BRIDGE'], namespace='default', authentication={}, provisioningState='Succeeded', unknown='preserve'))
        baseline = dict(customLocation=cl, extensions={'frozen': 'versions'}, resourceBindings=[{'id': str(i)} for i in range(4)], enabled={h['VM_EXT']: {'allTypesCount': 240, 'allTypesSha256': 'all-versions', 'propertiesSha256': 'all-properties'}})
        current = copy.deepcopy(baseline); current['customLocation']['properties']['clusterExtensionIds'].append(h['AKS_EXT'])
        current['enabled'][h['AKS_EXT']] = {'types': [['microsoft.hybridcontainerservice', t, '2024-01-01'] for t in ('skus', 'kubernetesversions', 'provisionedclusterinstances')]}
        h['verify_retained'](baseline, current)
        for mutation in ('unknown', 'old-types', 'binding'):
            bad = copy.deepcopy(current)
            if mutation == 'unknown': bad['customLocation']['properties']['unknown'] = 'changed'
            if mutation == 'old-types': bad['enabled'][h['VM_EXT']]['allTypesSha256'] = 'selected-versions-only'
            if mutation == 'binding': bad['resourceBindings'].pop()
            with self.assertRaises(ValueError): h['verify_retained'](baseline, bad)

    def test_preparation_release_gate_cannot_be_overridden_by_plan_go(self):
        with patch.dict(RG, source_guard=R['source_guard']):
            with self.assertRaisesRegex(ValueError, 'disabled'): R['source_guard'](self.plan)

    def test_convergence_pending_then_healthy_is_read_only(self):
        self.reach('resume-lb-node01'); stage = 'converge-lb-node01'
        pending = self.observation(stage)
        pending['snapshot']['clusterHealth']['virtualDiskStates'][0].update(health='Warning', operational=['Degraded'])
        pending['snapshot']['clusterHealth']['activeStorageJobs'] = [dict(name='Repair', poolId=self.plan['baseline']['clusterStatic']['poolId'], affectedVirtualDiskIds=['0'], affectedDeviceIds=['0'])]
        reader = Mock(side_effect=[pending, self.observation(stage)]); clock = Mock(monotonic=Mock(side_effect=[0, 0, 1, 1]), sleep=Mock())
        before = list(self.out.glob('intent-r2-*.json'))
        with patch.dict(RG, transport=reader, time=clock): result = R['observe_convergence'](self.plan, stage, 'synthetic-resync')
        self.assertEqual(reader.call_count, 2); self.assertEqual(before, list(self.out.glob('intent-r2-*.json')))
        R['converge'](self.plan, stage, result)

    def test_convergence_unknown_identity_fails_immediately_and_timeout_does_not_admit_next(self):
        self.reach('resume-lb-node01'); stage = 'converge-lb-node01'
        bad = self.observation(stage); bad['snapshot']['guestsStatic'][1]['disks'][0]['id'] = 'replacement'
        reader = Mock(return_value=bad)
        with patch.dict(RG, transport=reader):
            with self.assertRaisesRegex(ValueError, 'non-profile'): R['observe_convergence'](self.plan, stage, 'synthetic-bad')
        self.assertEqual(reader.call_count, 1)
        with patch.dict(RG, time=Mock(monotonic=Mock(side_effect=[0, 601]))):
            with self.assertRaises(TimeoutError): R['observe_convergence'](self.plan, stage, 'synthetic-timeout')
        with self.assertRaises(RuntimeError): R['dispatch'](self.plan, 'drain-lb-node02', self.admission('drain-lb-node02'))

    def test_python_and_powershell_worker_profile_capacity_guards_agree(self):
        stage = 'memory-lb-node01'; self.reach('stop-lb-node01')
        s = snapshot(self.plan, stage); e = self.plan['transitionContract']['stages'][stage]
        proof = R['drain_proof'](self.plan, stage, I['idle']()[2])
        R['verify_snapshot'](s, self.plan, e, drain=proof, expected_source=COMMIT)
        command = "$ComputeCapacityLibraryOnly=$true;. '" + str(ROOT / 'scripts/smal-compute-capacity-20261108-common.ps1') + "';"
        for name, value in [('plan', self.plan), ('snapshot', s), ('entry', e), ('proof', proof)]:
            command += '$' + name + "='" + json.dumps(value).replace("'", "''") + "'|ConvertFrom-Json;"
        command += "$stage='" + stage + "';$planSha='" + R['sha'](self.plan) + "';$sourceCommit='" + COMMIT + "';$ComputeCapacityWorkerLibraryOnly=$true;. '" + str(ROOT / 'scripts/smal-compute-capacity-20261108-worker.ps1') + "';"
        # Pure helper accepts an explicit proof rather than reading protected remote state.
        command += "Assert-R2Snapshot $snapshot $entry.beforeProfiles $entry.beforeStates $proof;"
        command += "$snapshot.nodeCapacity.'LB-NODE02'.logicalProcessors=7;$rejected=$false;try{Assert-R2Snapshot $snapshot $entry.beforeProfiles $entry.beforeStates $proof}catch{$rejected=$true};if(-not $rejected){exit 3}"
        result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', command], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__': unittest.main()
