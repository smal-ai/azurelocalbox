"""Offline direct full-outage tests. Providers, transport and publication are mocked.

Synthetic authority/plans/history exist only in temporary test roots. No live CLI,
SSH, VM, cluster, worker, authentication or Relay operation is executed.
"""
import copy
import json
from pathlib import Path
import re
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
D = runpy.run_path(str(ROOT / 'scripts/smal-capacity-direct.py'), run_name='direct_test')
G = D['dispatch'].__globals__; I = D['I']; IG = I['begin'].__globals__
F = runpy.run_path(str(ROOT / 'scripts/test_smal_capacity_r2_flow.py'), run_name='direct_native_fixture')
HEAD = 'b' * 40
RESOURCE_ID = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'


def fixture():
    p, _ = F['T']['fixture']()
    owners = p['transitionContract']['deviceOwners']
    p.update(route=D['ROUTE'], executionApproval=None, deviceOwners={}, directHumanApproval=None,
             technicalReview=dict(decision='accept-direct-full-outage-source-and-plan', reviewer='independent-test-only', sourceFileMapSha256='a' * 64),
             quiescence=dict(catalogueState='Pending', catalogueRefreshReplay=False, interruptibleControlPlaneOperationDisclosed=True,
                             exclusiveHardwareWriter=True, nightlyScheduleConflictChecked=True, clusterLifecycleResourceQuiescenceConfirmed=True))
    p['transitionContract'] = D['contract'](p)
    for guest in p['baseline']['guestsStatic']: guest.update(automaticStart='Nothing', automaticStop='ShutDown')
    p['baseline']['clusterStatic']['vmLifecyclePolicies'] = [dict(resourceId=RESOURCE_ID, vmIds=[p['infrastructureVmId']], offlineAction=1)]
    p['baseline']['clusterStatic']['nestedVms'][0]['shutdownIntegrationEnabled'] = True
    p['directHumanApproval'] = dict(quotedRequest="make the changes, I'm the boss here", unsignedPlanSha256=D['sha'](p),
                                   approvedEffects=D['EFFECTS'], authorityProfile='direct-human-full-outage')
    return p


def snapshot(plan, stage, after=False):
    s = F['snapshot'](plan, stage, after)
    for guest in s['guestsStatic']: guest.update(automaticStart='Nothing', automaticStop='ShutDown')
    if s['clusterStatic'] is not None:
        s['clusterStatic'] = copy.deepcopy(plan['baseline']['clusterStatic'])
        s['clusterHealth']['vmResources'][0]['id'] = plan['baseline']['clusterStatic']['vmLifecyclePolicies'][0]['resourceId']
    return s


class DirectTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/tmp/opencode'); root = Path(self.temp.name)
        self.out = root / 'out'; old = root / 'old'; self.out.mkdir(); old.mkdir()
        self.plan = fixture(); self.sealed = self.out / 'plan.direct.sealed.json'; self.sealed.write_text(json.dumps(self.plan))
        self.scopes = [patch.dict(IG, ROOT=root, OUT=self.out, LEGACY=old, LOCK=root / 'lock'),
                       patch.dict(G, source_guard=Mock(return_value=HEAD), SEALED=self.sealed, transport=Mock(return_value={'status': 'complete'}))]
        for s in self.scopes: s.start()

    def tearDown(self):
        for s in reversed(self.scopes): s.stop()
        self.temp.cleanup()

    def cloud(self, stage, after=False):
        e = self.plan['transitionContract']['stages'][stage]
        size = self.plan['beforeSize'] if e['hostCpu'] == 32 else self.plan['targetSize']; power = 'PowerState/running'
        if stage == 'direct-host-size' or stage == 'direct-deallocate' and after: power = 'PowerState/deallocated'
        if stage == 'direct-host-size' and after: size = self.plan['targetSize']
        return dict(atUtc=D['C']['now'](), projection=copy.deepcopy(self.plan['baseline']['cloud']), size=size, power=power, etag='synthetic-etag')

    def evidence(self, stage):
        return dict(atUtc=D['C']['now'](), mutationPerformed=False, sourceCommit=HEAD, stage=stage,
                    planSha256=D['sha'](self.plan), exclusiveHardwareWriter=True, quotaPolicyAndScheduleChecked=True, snapshot=snapshot(self.plan, stage), cloud=self.cloud(stage))

    def observed(self, stage, applied=True):
        e = self.plan['transitionContract']['stages'][stage]; s = snapshot(self.plan, stage, applied)
        o = dict(operationId=I['OPERATION'], atUtc=D['C']['now'](), sourceCommit=HEAD, planSha256=D['sha'](self.plan),
                 stage=stage, key=stage, mutationPerformed=False, outcome='applied' if applied else 'not-applied',
                 snapshot=s, cloud=self.cloud(stage, True), workerAlive=False, dispatcherAlive=False,
                 rpcPhase='returned', workerIdentityVerified=True, workerSourceVerified=True)
        if e['effect'].startswith('azure-'):
            o.update(azureProvisioningState='Succeeded', azureTransitionSettled=True); return o
        text = D['render_context'](D['context'](self.plan, stage, 'observe'), HEAD).decode()
        w = dict(operationId=I['OPERATION'], sourceCommit=HEAD, planSha256=D['sha'](self.plan), stage=stage, key=stage,
                 phase='returned', sequence=3, pid=99999999, processStartedUtc='2026-11-08T00:00:00Z',
                 sourceSha256=re.search(r"\$workerSha256='([A-F0-9]{64})'", text)[1], rpcInvoked=applied, rpcSucceeded=applied)
        o.update(worker=w, request={f: w[f] for f in ('operationId','sourceCommit','planSha256','stage','key','pid','processStartedUtc')})
        if e['effect'] == 'cluster-stop':
            _, expected_state, enabled = D['infrastructure_policy'](self.plan['baseline']['clusterStatic'], self.plan['infrastructureVmId'])
            o.update(clusterServices={n: 'Stopped' for n in D['C']['NODES']},
                     clusterLifecycleVms=[dict(id=self.plan['infrastructureVmId'], state=expected_state, cpu=4, memory=8 * 1024**3, shutdownIntegrationEnabled=enabled)])
        if e['effect'] == 'startup-grant':
            w['remoteGrant'] = dict(operationId=I['OPERATION'], planSha256=D['sha'](self.plan), sourceCommit=HEAD,
                key='direct-startup', stage='direct-startup', grantStage=stage, atUtc=D['C']['now'](),
                profiles=e['beforeProfiles'], states=e['beforeStates'], guests=s['guestsStatic'], hostCpu=64,
                hostStatic=s['hostStatic'], volumesStatic=s['volumesStatic'], startupEntry=self.plan['transitionContract']['stages']['direct-startup'],
                maintenanceContext=None, capacityGuard=dict(hostCpu=64, physicalCores=32, minimumMemoryBytes=500 * 1024**3, minimumFreeMemoryBytes=64 * 1024**3))
        if e['effect'] == 'canonical-startup':
            o['remoteStartup'] = dict(w, helperSha256=re.search(r"\$startupHelperSha256='([A-F0-9]{64})'", text)[1], guestRpcInvoked=applied)
            if not applied:
                o['remoteStartup']['refusal'] = 'capacity-refused-before-guests'
                o['snapshot']['hostCapacity'].update(logicalProcessors=32, physicalCores=16, memoryBytes=256 * 1024**3, numa=[{'logicalProcessors': 32}])
        if e['effect'] == 'complete':
            w['completionSnapshot'] = s
            o['remoteCompletion'] = dict(operationId=I['OPERATION'], sourceCommit=HEAD, planSha256=D['sha'](self.plan), key=stage, stage=stage, snapshot=s)
        return o

    def run_stage(self, stage, applied=True, directive=None):
        e = self.plan['transitionContract']['stages'][stage]
        if e['effect'] == 'converge': return D['converge'](self.plan, self.observed(stage))
        if e['effect'] == 'canonical-startup':
            evidence = self.evidence(stage); evidence['cloud']['power'] = 'PowerState/deallocated'
            path = D['handover'](self.plan, evidence); I['authorise_startup'](path, HEAD)
        else:
            with patch.dict(D['C'], get_cloud=Mock(return_value=self.cloud(stage)), az=Mock()):
                D['dispatch'](self.plan, stage, self.evidence(stage), directive)
        with self.assertRaises(RuntimeError): I['idle']()
        return D['settle'](self.plan, stage, self.observed(stage, applied))

    def reach(self, stage):
        for key, e in self.plan['transitionContract']['stages'].items():
            if e['recovery']: break
            self.run_stage(key)
            if key == stage: return

    def test_distinct_direct_authority_no_parent_or_catalogue_success_inference(self):
        D['validate'](self.plan, True)
        for key, value in [('directHumanApproval', None), ('executionApproval', {'parentGo': True}), ('quiescence', None)]:
            p = copy.deepcopy(self.plan); p[key] = value
            with self.assertRaises((ValueError,TypeError)): D['validate'](p, True)
        self.assertFalse(D['R']['EFFECTS_ENABLED'])

    def test_no_serial_outage_or_storage_maintenance_phase_in_contract(self):
        stages = self.plan['transitionContract']['stages']; effects = {e['effect'] for e in stages.values()}
        self.assertNotIn('drain', effects); self.assertNotIn('resume', effects)
        profiles = stages['direct-grant']['beforeProfiles']
        self.assertEqual(sum(p['memory'] for p in profiles.values()), 388 * 1024**3)
        for e in stages.values():
            if e['effect'] in ('memory','cpu','startup-grant'): self.assertEqual(set(e['beforeStates'].values()), {'Off'})

    def test_whole_cluster_health_checks_ids_without_serial_owner_scan(self):
        s = snapshot(self.plan, 'direct-cluster-stop')
        for device in s['clusterHealth']['devices']: device['owner'] = None
        D['verify_snapshot'](s, self.plan, self.plan['transitionContract']['stages']['direct-cluster-stop'], HEAD)
        s['clusterHealth']['devices'][0]['id'] = 'unexpected-device'
        with self.assertRaisesRegex(ValueError, '24 Healthy'):
            D['verify_snapshot'](s, self.plan, self.plan['transitionContract']['stages']['direct-cluster-stop'], HEAD)

    def test_entire_mocked_full_outage_and_final_certificate(self):
        self.reach('complete'); o = self.observed('complete')
        self.assertEqual(I['idle']()[2]['direct-cluster-stop']['proof']['observation']['clusterLifecycleVms'][0]['state'], 'Saved')
        self.assertEqual(o['snapshot']['clusterHealth']['vmResources'][0]['state'], 'Online')
        self.assertEqual(o['snapshot']['clusterHealth']['vmResources'][0]['id'], RESOURCE_ID)
        o['remoteCompletion'] = I['idle']()[2]['complete']['proof']['observation']['remoteCompletion']
        D['finish'](self.plan, o); self.assertIsNone(I['authorise_startup']())

    def test_missing_unknown_and_forced_policy_rejected_before_any_stop_intent(self):
        original = copy.deepcopy(self.plan)
        for action in (None, 0, 3, 4, '1', True):
            self.plan = copy.deepcopy(original)
            self.plan['baseline']['clusterStatic']['vmLifecyclePolicies'][0]['offlineAction'] = action
            with self.subTest(action=action), self.assertRaisesRegex(ValueError, 'OfflineAction'):
                D['validate'](self.plan, False)
            with self.assertRaises(ValueError): D['dispatch'](self.plan, 'direct-cluster-stop', self.evidence('direct-cluster-stop'))
            self.assertFalse((self.out / 'operation-r2.json').exists())
            self.assertFalse(list(self.out.glob('intent-r2-*.json')))
        self.plan = copy.deepcopy(original); missing = snapshot(self.plan,'direct-cluster-stop'); missing['clusterStatic'].pop('vmLifecyclePolicies')
        with self.assertRaises(ValueError): D['prepare'](dict(atUtc=D['C']['now'](), sourceCommit=HEAD, mutationPerformed=False,
                                                           snapshot=missing, cloud=self.cloud('direct-cluster-stop')))

    def test_save_allows_preserved_disabled_shutdown_but_shutdown_requires_enabled(self):
        cluster = copy.deepcopy(self.plan['baseline']['clusterStatic'])
        cluster['nestedVms'][0]['shutdownIntegrationEnabled'] = False
        self.assertEqual(D['infrastructure_policy'](cluster,self.plan['infrastructureVmId'])[1:], ('Saved',False))
        cluster['vmLifecyclePolicies'][0]['offlineAction'] = 2
        with self.assertRaises(ValueError): D['infrastructure_policy'](cluster,self.plan['infrastructureVmId'])
        cluster['nestedVms'][0]['shutdownIntegrationEnabled'] = None
        with self.assertRaises(ValueError): D['infrastructure_policy'](cluster,self.plan['infrastructureVmId'])
        cluster['nestedVms'][0]['shutdownIntegrationEnabled'] = True
        self.assertEqual(D['infrastructure_policy'](cluster,self.plan['infrastructureVmId'])[1:], ('Off',True))

    def test_graceful_shutdown_policy_exact_off_settlement_and_final_resource_binding(self):
        self.plan['baseline']['clusterStatic']['vmLifecyclePolicies'][0]['offlineAction'] = 2
        self.plan['directHumanApproval'] = None
        self.plan['directHumanApproval'] = dict(quotedRequest="make the changes, I'm the boss here", unsignedPlanSha256=D['sha'](self.plan),
                                               approvedEffects=D['EFFECTS'], authorityProfile='direct-human-full-outage')
        self.sealed.write_text(json.dumps(self.plan))
        D['dispatch'](self.plan,'direct-cluster-stop',self.evidence('direct-cluster-stop'))
        for change, value in [('state','Saved'),('state','Running'),('state','Paused'),('id','unknown'),('memory',4 * 1024**3),('shutdownIntegrationEnabled',False)]:
            o=self.observed('direct-cluster-stop');o['clusterLifecycleVms'][0][change]=value
            with self.subTest(change=change,value=value),self.assertRaises(ValueError):D['settle'](self.plan,'direct-cluster-stop',o)
        D['settle'](self.plan,'direct-cluster-stop',self.observed('direct-cluster-stop'))
        final=snapshot(self.plan,'complete',True)
        D['verify_snapshot'](final,self.plan,self.plan['transitionContract']['stages']['complete'],HEAD,after=True)
        final['clusterStatic']['vmLifecyclePolicies'][0]['resourceId']='bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee'
        with self.assertRaises(ValueError):D['verify_snapshot'](final,self.plan,self.plan['transitionContract']['stages']['complete'],HEAD,after=True)

    def test_outer_guests_must_be_off_even_when_nested_vm_is_validly_saved(self):
        stage='direct-memory-lb-node01';s=snapshot(self.plan,stage)
        self.assertIsNone(s['clusterStatic'])  # no fabricated cluster/storage state while stopped
        s['states']['LB-NODE02']='Saved'
        with self.assertRaises(ValueError):D['verify_snapshot'](s,self.plan,self.plan['transitionContract']['stages'][stage],HEAD)

    def test_policy_requires_exact_vm_and_stable_resource_identity(self):
        original=self.plan['baseline']['clusterStatic']
        for field,value in [('vmIds',[]),('vmIds',['unknown']),('resourceId',None),('resourceId','not-a-guid')]:
            cluster=copy.deepcopy(original);cluster['vmLifecyclePolicies'][0][field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):D['infrastructure_policy'](cluster,self.plan['infrastructureVmId'])
        final=snapshot(self.plan,'complete',True);final['clusterStatic']['nestedVms'][0]['shutdownIntegrationEnabled']=False
        with self.assertRaises(ValueError):D['verify_snapshot'](final,self.plan,self.plan['transitionContract']['stages']['complete'],HEAD,after=True)

    def test_actual_readonly_policy_capture_exposes_forced_and_missing_values(self):
        common=ROOT/'scripts/smal-compute-capacity-20261108-common.ps1'
        command="$ErrorActionPreference='Stop';$ComputeCapacityLibraryOnly=$true;. '"+str(common)+"';$t=$null;$e=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile('"+str(common)+"',[ref]$t,[ref]$e);"
        command+="function Get-ClusterResource{param($Cluster)[pscustomobject]@{Id=[guid]'"+RESOURCE_ID+"';ResourceType='Virtual Machine'}};"
        command+="function Get-ClusterParameter{[CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject,[string]$Name)process{if($Name -ceq 'VmId'){[pscustomobject]@{Value='"+self.plan['infrastructureVmId']+"'}}elseif($null -ne $testOffline){[pscustomobject]@{Value=$testOffline}}}};"
        command+="function Get-VMIntegrationService{[CmdletBinding()]param($VM)[pscustomobject]@{Name='Shutdown';Enabled=$false};[pscustomobject]@{Name='Heartbeat';Enabled=$true}};"
        command+="function Assignment($name){$n=$ast.Find({param($x)$x -is [System.Management.Automation.Language.AssignmentStatementAst] -and $x.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $x.Left.VariablePath.UserPath -ceq $name},$true);[ScriptBlock]::Create($n.Extent.Text)};"
        command+="$results=@();foreach($testOffline in @(1,2,0,3,$null)){. (Assignment 'vmResources');. (Assignment 'vmPolicies');$results+=@($vmPolicies)[0]};. (Assignment 'shutdown');if($shutdown.Count -ne 1 -or $shutdown[0].Enabled -ne $false){exit 3};ConvertTo-ComputeJson $results"
        result=subprocess.run(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-Command',command],capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stderr)
        rows=json.loads(result.stdout)
        self.assertEqual([row['offlineAction'] for row in rows],[1,2,0,3,None])
        self.assertTrue(all(row['resourceId']==RESOURCE_ID and row['vmIds']==[self.plan['infrastructureVmId']] for row in rows))

    def test_not_applied_memory_does_not_admit_normal_cpu(self):
        self.reach('direct-off-lb-dc01'); self.run_stage('direct-memory-lb-node01', False)
        with self.assertRaises(RuntimeError): D['dispatch'](self.plan, 'direct-cpu-lb-node01', self.evidence('direct-cpu-lb-node01'))

    def test_unknown_timeout_blocks_other_key_and_startup(self):
        e = self.evidence('direct-cluster-stop')
        with patch.dict(G, transport=Mock(side_effect=TimeoutError('synthetic timeout'))):
            with self.assertRaises(TimeoutError): D['dispatch'](self.plan, 'direct-cluster-stop', e)
        with self.assertRaises(RuntimeError): I['authorise_startup']()
        with self.assertRaises(RuntimeError): D['dispatch'](self.plan, 'direct-cluster-stop', e)

    def test_infrastructure_state_missing_or_mismatched_save_policy_blocks_settlement(self):
        D['dispatch'](self.plan, 'direct-cluster-stop', self.evidence('direct-cluster-stop'))
        for vms in ([], [dict(id=self.plan['infrastructureVmId'],state='Off',cpu=4,memory=8 * 1024**3,shutdownIntegrationEnabled=True)]):
            o = self.observed('direct-cluster-stop'); o['clusterLifecycleVms'] = vms
            with self.assertRaises(ValueError): D['settle'](self.plan, 'direct-cluster-stop', o)

    def test_explicit_offline_restoration_directive_required(self):
        self.reach('direct-cpu-lb-node01'); key = 'restore-2-1-memory'; e = self.plan['transitionContract']['stages'][key]
        with self.assertRaises(ValueError): D['dispatch'](self.plan, key, self.evidence(key))
        directive = dict(atUtc=D['C']['now'](), authorityProfile='direct-human-offline-original-profile-restoration',
                         quotedRequest='synthetic test-only restore original profiles', planSha256=D['sha'](self.plan), sourceCommit=HEAD,
                         stage=key, approvedEffects=['restore-original-profile-while-all-four-guests-off'])
        self.run_stage(key, directive=directive)
        directive['stage'] = 'restore-2-1-cpu'; self.run_stage('restore-2-1-cpu', directive=directive)
        self.assertEqual(self.plan['transitionContract']['stages']['restore-2-1-cpu']['afterProfiles']['LB-NODE01'], dict(cpu=8,memory=64 * 1024**3))

    def test_capacity_refusal_is_observed_all_off_not_falsely_complete(self):
        self.reach('direct-host-size'); stage='direct-startup'; evidence=self.evidence(stage); evidence['cloud']['power']='PowerState/deallocated'
        path=D['handover'](self.plan,evidence); I['authorise_startup'](path,HEAD)
        D['settle'](self.plan,stage,self.observed(stage,False))
        with self.assertRaises(RuntimeError): D['converge'](self.plan,self.observed('direct-converge'))

    def test_actual_powershell_runtime_guard_blocks_e32_and_insufficient_ram(self):
        s=snapshot(self.plan,'direct-startup',True); s['states']={n:'Off' for n in D['C']['GUESTS']}; s['hostCapacity']['freeMemoryBytes']=480 * 1024**3
        grant=self.observed('direct-grant')['worker']['remoteGrant']
        command="$ErrorActionPreference='Stop';$ComputeCapacityLibraryOnly=$true;. '"+str(ROOT/'scripts/smal-compute-capacity-20261108-common.ps1')+"';. '"+str(ROOT/'scripts/smal-capacity-startup-interlock.ps1')+"';"
        for name,value in [('snapshot',s),('grant',grant)]: command+='$'+name+"='"+json.dumps(value).replace("'","''")+"'|ConvertFrom-Json;"
        command+="Assert-CapacityRuntime $snapshot $grant;$snapshot.hostCapacity.memoryBytes=256GB;$rejected=$false;try{Assert-CapacityRuntime $snapshot $grant}catch{$rejected=$true};if(-not $rejected){exit 3};$snapshot.hostCapacity.memoryBytes=512GB;$snapshot.hostCapacity.freeMemoryBytes=400GB;$rejected=$false;try{Assert-CapacityRuntime $snapshot $grant}catch{$rejected=$true};if(-not $rejected){exit 4}"
        result=subprocess.run(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-Command',command],capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stderr)

    def test_worker_hash_independent_of_read_mode_and_restoration_directive(self):
        key='restore-2-1-memory'; hashes=[]
        for mode,directive in [('dispatch',{'quotedRequest':'one'}),('observe',None)]:
            text=D['render_context'](D['context'](self.plan,key,mode,directive=directive),HEAD).decode()
            hashes.append(re.search(r"\$workerSha256='([A-F0-9]{64})'",text)[1])
        self.assertEqual(hashes[0],hashes[1])

    def test_stopped_snapshot_must_not_invent_cluster_visibility(self):
        e=self.plan['transitionContract']['stages']['direct-memory-lb-node01']; s=snapshot(self.plan,e['key'])
        D['verify_snapshot'](s,self.plan,e,HEAD)
        s['clusterStatic']=self.plan['baseline']['clusterStatic']
        with self.assertRaises(ValueError): D['verify_snapshot'](s,self.plan,e,HEAD)

    def test_azure_observer_is_get_only_and_never_expects_a_remote_worker(self):
        self.reach('direct-grant'); stage='direct-deallocate'
        with patch.dict(D['C'],get_cloud=Mock(return_value=self.cloud(stage)),az=Mock()):
            D['dispatch'](self.plan,stage,self.evidence(stage))
        G['transport'].reset_mock()
        terminal=dict(self.cloud(stage,True),provisioningState='Succeeded')
        with patch.dict(D['C'],get_cloud=Mock(return_value=terminal)):
            o=D['observe'](self.plan,stage,'synthetic-cloud-get')
        self.assertTrue(o['azureTransitionSettled']);G['transport'].assert_not_called()
        D['settle'](self.plan,stage,o)

    def test_unsigned_preview_does_not_generate_authority_or_enable_effects(self):
        p=copy.deepcopy(self.plan);p['directHumanApproval']=None;p['technicalReview']=None
        data=D['preview'](p,'direct-memory-lb-node01')
        self.assertIn(b'$CapacityEffectsEnabled=$false',data)
        self.assertIsNone(p['directHumanApproval']);self.assertIsNone(p['executionApproval'])

    def test_snapshot_does_not_ship_mutation_workers_or_unused_contracts(self):
        pending = json.loads(D['PENDING'].read_text())
        data = D['render_context'](D['context'](pending, 'direct-cluster-stop', 'snapshot'), HEAD)
        self.assertLess(len(data), 64 * 1024)
        self.assertNotIn(b'$workerBase64=', data)
        self.assertNotIn(b'Start-Process', data)
        self.assertIn(b'snapshot=(Read-ComputeSnapshot)', data)

    def test_no_autostart_policy_is_a_precondition_not_a_configuration_change(self):
        p=copy.deepcopy(self.plan);p['baseline']['guestsStatic'][1]['automaticStart']='Start'
        with self.assertRaisesRegex(ValueError,'no-autostart'):D['validate'](p,False)

    def test_prepare_remains_unsigned_and_does_not_infer_quiescence(self):
        p=self.plan;s=snapshot(p,'direct-cluster-stop')
        o=dict(atUtc=D['C']['now'](),sourceCommit=HEAD,mutationPerformed=False,snapshot=s,cloud=self.cloud('direct-cluster-stop'))
        candidate=D['prepare'](o)
        self.assertIsNone(candidate['directHumanApproval']);self.assertIsNone(candidate['technicalReview']);self.assertIsNone(candidate['quiescence'])
        self.assertFalse(candidate['admission']['maintenanceConflictChecked'])


if __name__ == '__main__': unittest.main()
