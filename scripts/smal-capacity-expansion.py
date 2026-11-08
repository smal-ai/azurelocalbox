"""Bounded human-approved additive Standard_LRS expansion. No pooled disk resize.

Stages are individually journalled and never automatically replayed. Only the new
blank host disk is formatted. S2D claims new matching VHDs by its normal mechanism.
"""
import argparse
import base64
import contextlib
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import runpy
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
D = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'),run_name='capacity_existing_helpers')
OUT = ROOT / 'docs/deployment-2026-10-30'
PLAN_PATH = 'docs/deployment-2026-10-30/capacity-expansion-plan.json'
APPROVAL_PATH = 'docs/deployment-2026-10-30/capacity-expansion-approval.json'
TEMPLATE = 'infra/bicep/localbox-capacity-disk.bicep'
ACTION = 'localbox-capacity-disk-20261030'
RG, HOST = 'rg-localbox-nodes-san-1','LocalBox-Client'
STAGES = ['prepare','create','attach','format','add-vhds','verify']
SCRIPTS = {'prepare':'scripts/prepare-smal-capacity-expansion.ps1','format':'scripts/format-smal-capacity-disk.ps1','add-vhds':'scripts/add-smal-capacity-vhds.ps1'}


def load_plan():
    raw = (ROOT / PLAN_PATH).read_bytes(); plan = json.loads(raw); approval = json.loads((ROOT / APPROVAL_PATH).read_text())
    if approval.get('approved') is not True or approval.get('humanAnswer') != 'Approve supported addition' or approval.get('activeStorageTier') != 'Standard_LRS' or approval.get('planSha256') != hashlib.sha256(raw).hexdigest():
        raise RuntimeError('Exact human additive-expansion approval differs')
    disk = plan['newDisk']
    if disk['name'] != 'LocalBox-Client-Capacity-20261030' or disk['sizeGiB'] != 4096 or disk['sku'] != 'Standard_LRS' or disk['lun'] != 9 or disk['driveLetter'] != 'X' or disk['joinOuterPool'] is not False:
        raise RuntimeError('Exact new disk effect differs')
    return plan


def source_guard():
    paths = [PLAN_PATH,APPROVAL_PATH,TEMPLATE,'scripts/smal-capacity-expansion.py','scripts/plan-smal-capacity-expansion.py',
             'scripts/smal-capacity-prelude.ps1','scripts/smal-private-powershell.py','scripts/inspect-smal-three-node-final.ps1','scripts/inspect-smal-capacity-interruption.ps1',*SCRIPTS.values()]
    head = D['A']['source_guard'](paths); load_plan(); return head


def public_context(disk_unique_id=None,resume_binding_fix=False):
    if disk_unique_id is not None: uuid.UUID(disk_unique_id)
    result = {'planBase64':base64.b64encode((ROOT / PLAN_PATH).read_bytes()).decode(),
              'approvalBase64':base64.b64encode((ROOT / APPROVAL_PATH).read_bytes()).decode(),'azureDiskUniqueId':disk_unique_id}
    if resume_binding_fix: result['resumeBindingFix'] = True
    return result


def vm_projection():
    return D['az'](['vm','show','--subscription',D['SUB'],'-g',RG,'-n',HOST,
        '--query','{id:id,size:hardwareProfile.vmSize,osId:storageProfile.osDisk.managedDisk.id,data:storageProfile.dataDisks[].{id:managedDisk.id,lun:lun,caching:caching,deleteOption:deleteOption}}'])


def disk_projection():
    return D['az'](['disk','list','--subscription',D['SUB'],'-g',RG,
        '--query','[].{id:id,name:name,sizeGiB:diskSizeGB,sku:sku.name,uniqueId:uniqueId,managedBy:managedBy,state:diskState}'])


def verify_existing_disks(rows,plan,with_new=False):
    expected = {r['id'].lower():r for r in plan['existingDisks']}; ids = set(expected)
    if with_new: ids.add(plan['newDisk']['id'].lower())
    if len(rows) != len(ids) or {r['id'].lower() for r in rows} != ids: raise RuntimeError('Unexpected managed disk identity set')
    for row in rows:
        if row['id'].lower() not in expected: continue
        old = expected[row['id'].lower()]
        if row.get('sku') != 'Standard_LRS' or row.get('sizeGiB') != old['sizeGiB'] or row.get('uniqueId') != old['uniqueId'] or row.get('managedBy','').lower() != plan['hostId'].lower() or row.get('state') != 'Attached':
            raise RuntimeError('Existing disk SKU/size/identity/owner changed')


def verify_vm(vm,plan,attached=False):
    old = plan['vmBefore']
    if vm['id'].lower() != old['id'].lower() or vm['osId'].lower() != old['osId'].lower() or vm['size'] != old['size']:
        raise RuntimeError('Original VM/OS/profile changed')
    before = {r['lun']:{**r,'id':r['id'].lower()} for r in old['data']}
    current = {r['lun']:{**r,'id':r['id'].lower()} for r in vm['data'] if r['lun'] != 9}
    if before != current or len(vm['data']) != 9 + int(attached): raise RuntimeError('Existing data-disk LUN/caching/retention changed')
    if attached:
        new = [r for r in vm['data'] if r['lun'] == 9]
        if len(new) != 1 or new[0]['id'].lower() != plan['newDisk']['id'].lower() or new[0]['caching'] != 'None' or new[0].get('deleteOption') not in [None,'Detach']:
            raise RuntimeError('Exact new attachment/retention differs')


def verify_new_disk(disk,plan,attached=False):
    if (disk.get('id','').lower() != plan['newDisk']['id'].lower() or disk.get('diskSizeGB') != 4096
            or disk.get('sku',{}).get('name') != 'Standard_LRS' or disk.get('networkAccessPolicy') != 'DenyAll'
            or disk.get('publicNetworkAccess') != 'Disabled' or disk.get('burstingEnabled') is True):
        raise RuntimeError('Exact new private Standard_LRS disk differs')
    uuid.UUID(disk['uniqueId'])
    if (attached and disk.get('managedBy','').lower() != plan['hostId'].lower()) or (not attached and disk.get('managedBy')):
        raise RuntimeError('New disk attachment owner differs')


def validate_preview(data,owned,plan):
    if data.get('status') != 'Succeeded': raise RuntimeError('Capacity disk preview failed')
    seen = []
    for row in data.get('changes',[]):
        rid = row.get('resourceId','').lower(); kind = row.get('changeType')
        if kind in ['Ignore','NoChange'] and rid in owned and row.get('before') == row.get('after'): continue
        after = row.get('after') or {}; props = after.get('properties') or {}
        if (rid != plan['newDisk']['id'].lower() or kind != 'Create' or after.get('type','').lower() != 'microsoft.compute/disks'
                or after.get('location') != 'southafricanorth' or after.get('sku',{}).get('name') != 'Standard_LRS'
                or props.get('diskSizeGB') != 4096 or props.get('creationData',{}).get('createOption') != 'Empty'
                or props.get('networkAccessPolicy') != 'DenyAll' or props.get('publicNetworkAccess') != 'Disabled'):
            raise RuntimeError('Unlisted resource/capacity/security effect in disk preview')
        seen.append({'id':row['resourceId'],'changeType':kind})
    if len(seen) != 1: raise RuntimeError('Exactly one new approved capacity disk required')
    return seen


def previous(stage):
    path = OUT / ('capacity-expansion-' + stage + '-receipt.json')
    reconciled = OUT / 'capacity-expansion-add-vhds-after-id-binding-reconciliation-receipt.json'
    if stage == 'add-vhds' and reconciled.exists(): path = reconciled
    row = json.loads(path.read_text())
    if row.get('status') != 'complete': raise RuntimeError('Earlier capacity stage incomplete: ' + stage)
    return row


def run_private(stage,context):
    name = 'capacity-' + stage + '-after-id-binding-20261030' if context.get('resumeBindingFix') else 'capacity-' + stage + '-20261030'
    with contextlib.redirect_stdout(io.StringIO()): code = D['T']['main'](SCRIPTS[stage],name,capacity_context=context)
    path = D['T']['OUT'] / ('private-ssh-' + name + '.json'); proof = json.loads(path.read_text())
    expected = {'prepare':'complete-pre-attachment-baseline','format':'complete-new-only-4tib-x-volume','add-vhds':'complete-twelve-new-vhds-attached-await-pool-observation'}[stage]
    if code != 0 or proof.get('status') != 'complete' or proof.get('result',{}).get('status') != expected: raise RuntimeError('Capacity private stage incomplete. Inspect marker/receipt before any continuation.')
    return str(path.relative_to(ROOT)),proof['result']


def verify_growth(plan,baseline,added,proof):
    data = proof.get('result',{})
    if proof.get('status') != 'complete' or data.get('observationStatus') != 'complete-read-only' or data.get('mutationPerformed') is not False: raise RuntimeError('Complete read-only post-expansion observation required')
    old = {d['guestUniqueId']:d['sizeBytes'] for n in plan['nodes'].values() for d in n['originalDisks'] if d['eligibleForS2D']}
    new = {d['guestUniqueId']:d['sizeBytes'] for d in added['disks']}
    if len(old) != 12 or len(new) != 12 or set(old) & set(new) or any(not r['attached'] for r in added['disks']): raise RuntimeError('Exact distinct old/new device bindings required')
    expected = {**old,**new}; rows = data.get('nodes',[])
    if len(rows) != 3 or {r['name']:r['vmId'] for r in rows} != {name:n['vmId'] for name,n in plan['nodes'].items()}: raise RuntimeError('Exact three-node identity set changed')
    jobs = []; sizes = []
    for row in rows:
        guest = row['guest']; pools = guest.get('storagePools',[])
        if guest.get('clusterName') != 'smal-localbox01' or guest.get('storageSpacesDirectState') != 'Enabled' or guest.get('domain') != 'ad.localbox.test' or guest.get('domainRole') != 3 or row.get('state') != 'Running': raise RuntimeError('Cluster/S2D/domain identity differs after addition')
        if {r['name']:r['state'] for r in guest.get('clusterNodes',[])} != {name:'Up' for name in plan['nodes']} or len(guest.get('clusterNodes',[])) != 3: raise RuntimeError('All three exact nodes must remain Up')
        if guest.get('quorumResourceName') is not None or guest.get('quorumType') != 'Majority': raise RuntimeError('No Witness quorum changed')
        if guest.get('defenderEnabled') is not True or guest.get('firewallEnabled') is not True: raise RuntimeError('Guest protections changed')
        os_expected = [d for d in plan['nodes'][row['name']]['originalDisks'] if not d['eligibleForS2D']]
        boot = [d for d in guest.get('localDisks',[]) if d.get('isBoot') or d.get('isSystem')]
        if len(boot) != 1 or len(os_expected) != 1 or boot[0]['uniqueId'] != os_expected[0]['guestUniqueId'] or boot[0]['size'] != os_expected[0]['sizeBytes']:
            raise RuntimeError('Existing guest OS disk identity/size changed')
        if len(pools) != 1 or pools[0]['uniqueId'].lower() != plan['expectedS2dPoolId'].lower() or pools[0]['health'] != 'Healthy' or pools[0]['operationalStatus'] != ['OK']: raise RuntimeError('Original pool identity/health changed')
        pool = pools[0]
        if len(pool['members']) != 24 or {r['uniqueId']:r['size'] for r in pool['members']} != expected or any(r['health'] != 'Healthy' for r in pool['members']): raise RuntimeError('Exact twenty-four approved healthy pool members not yet observed; no automatic repair')
        prior = next(r for r in baseline['cluster'] if r['name'] == row['name'])
        if not prior['poolSize']*1.99 <= pool['size'] <= prior['poolSize']*2.01: raise RuntimeError('Pool capacity did not approximately double')
        old_vd = {r['name']:(r['uniqueId'],r['size']) for r in prior['virtualDisks']}
        if {r['name']:(r.get('uniqueId'),r['size']) for r in guest['virtualDisks']} != old_vd or any(r['health'] != 'Healthy' or r['dataCopies'] != 3 for r in guest['virtualDisks']): raise RuntimeError('Existing mirror identity/size/health changed')
        if len(guest.get('csv',[])) != 4 or any(r['state'] != 'Online' for r in guest['csv']): raise RuntimeError('Original CSVs are not all Online')
        jobs.extend(guest.get('storageJobs',[])); sizes.append(pool['size'])
    if len(set(sizes)) != 1: raise RuntimeError('Nodes disagree on pool capacity')
    return {'oldMembersPreserved':12,'newMembersVerified':12,'totalMembers':24,'poolSizeGiB':round(sizes[0]/1024**3,2),
            'poolIdentityPreserved':True,'existingVirtualDiskSizesAndIdsPreserved':True,'activeStorageJobs':[r for r in jobs if r.get('state') != 'Completed'],
            'completedJobRecordsObserved':sum(r.get('state') == 'Completed' for r in jobs),
            'optimizationFullyCompletedProven':False,'platformReadinessVerified':False}


def verify_outer_volumes(proof,baseline,formatted,plan):
    data = proof['result']; volumes = data.get('volumes',[])
    if len(volumes) != 4 or {v['letter'] for v in volumes} != {'C','V','W','X'} or any(v['health'] != 'Healthy' for v in volumes):
        raise RuntimeError('Exact four healthy outer volumes not observed')
    actual = {v['letter']:v for v in volumes}
    for old in baseline['volumes']:
        now = actual[old['letter']]
        if now['uniqueId'] != old['uniqueId'] or now['size'] != old['size']: raise RuntimeError('Original outer volume identity/size changed')
    if actual['X']['uniqueId'] != formatted['volumeId'] or actual['X']['size'] != formatted['volumeSize'] or actual['X']['free'] < 200*1024**3:
        raise RuntimeError('Exact new X identity/size/free-space reserve differs')
    pools = data.get('outerPool',[])
    if len(pools) != 1 or pools[0]['uniqueId'] != plan['originalOuterPoolId'] or pools[0]['memberCount'] != 8 or pools[0]['health'] != 'Healthy':
        raise RuntimeError('Original eight-member outer pool changed')
    return {'originalCvwPreserved':True,'newXHealthyAndIdentityVerified':True,'newXFreeGiB':round(actual['X']['free']/1024**3,2),'outerPoolPreserved':True}


def verify_first_file_resume(failed,admission,plan):
    first = plan['nodes']['LB-NODE01']['newDisks'][0]['path']
    result = failed.get('result',{}); proof = admission.get('result',{}); vhd = proof.get('firstVhd',{})
    plan_sha = json.loads((ROOT / APPROVAL_PATH).read_text())['planSha256']
    if (failed.get('status') != 'complete' or result.get('status') != 'failed-or-uncertain-inspect-do-not-repeat'
            or result.get('errorType') != 'RuntimeException' or result.get('errorLine') != 106 or result.get('disks') != [] or result.get('pendingPath') != first or result.get('planSha256') != plan_sha):
        raise RuntimeError('Not the exact retained first-file GUID-encoding interruption')
    if (admission.get('status') != 'complete' or proof.get('status') != 'verified-one-owned-unattached-first-vhd-and-unchanged-cluster'
            or proof.get('mutationPerformed') is not False or proof.get('originalVhdCount') != 15 or proof.get('originalPoolDeviceCount') != 12
            or vhd.get('path') != first or vhd.get('sizeBytes') != 170*1024**3 or vhd.get('attached') is not False
            or vhd.get('fileSize',2**64) > 32*1024**2 or len(vhd.get('sha256','')) != 64
            or proof.get('planSha256') != plan_sha or proof.get('azureDiskUniqueId') != result.get('azureDiskUniqueId')):
        raise RuntimeError('Exact read-only unused-file admission proof missing')
    uuid.UUID(vhd['vhdId'])


def main(stage,resume_binding_fix=False):
    head = source_guard(); plan = load_plan(); path = OUT / ('capacity-expansion-' + stage + '-receipt.json')
    record = {'beganAtUtc':datetime.now(timezone.utc).isoformat(),'sourceCommit':head,'stage':stage,'status':'pending',
              'planSha256':hashlib.sha256((ROOT / PLAN_PATH).read_bytes()).hexdigest(),'existingDiskResizeRequested':False,
              'osOrCsvResizeRequested':False,'policyOrAutomationChanged':False,'platformReadinessVerified':False}
    if resume_binding_fix:
        if stage != 'add-vhds': raise RuntimeError('The exact first-file correction applies only to add-vhds')
        failed_name = 'docs/deployment-2026-10-27/private-ssh-capacity-add-vhds-20261030.json'
        admission_name = 'docs/deployment-2026-10-27/private-ssh-capacity-first-vhd-interruption-20261030.json'
        D['A']['source_guard']([failed_name,admission_name,'docs/deployment-2026-10-30/capacity-expansion-add-vhds-receipt.json'])
        verify_first_file_resume(json.loads((ROOT / failed_name).read_text()),json.loads((ROOT / admission_name).read_text()),plan)
        path = OUT / 'capacity-expansion-add-vhds-after-id-binding-reconciliation-receipt.json'
        record['originalFailureRetained'] = True
        record['readOnlyAdmissionSha256'] = hashlib.sha256((ROOT / admission_name).read_bytes()).hexdigest()
    with path.open('x') as stream: stream.write(json.dumps(record,indent=2) + '\n')
    def save(): path.write_text(json.dumps(record,indent=2) + '\n')
    try:
        D['preflight']()
        if stage != 'prepare': previous(STAGES[STAGES.index(stage)-1])
        verify_existing_disks(disk_projection(),plan,with_new=stage in ['attach','format','add-vhds','verify'])
        verify_vm(vm_projection(),plan,attached=stage in ['format','add-vhds','verify'])
        if stage == 'prepare':
            skus = D['az'](['vm','list-skus','--subscription',D['SUB'],'--location','southafricanorth','--resource-type','virtualMachines','--size','Standard_E32s_v6',
                           '--query',"[?name=='Standard_E32s_v6'].{name:name,capabilities:capabilities}"],timeout=180)
            limits = [int(cap['value']) for row in skus for cap in row['capabilities'] if cap['name'] == 'MaxDataDiskCount']
            if len(limits) != 1 or limits[0] < 10: raise RuntimeError('Existing VM SKU does not admit ten data disks')
            record['maxDataDiskCountVerified'] = limits[0]
            record['privateReceipt'],record['result'] = run_private(stage,public_context())
        elif stage == 'create':
            owned = {rid.lower() for rid in D['az'](['resource','list','--subscription',D['SUB'],'-g',RG,'--query','[].id'])}
            if plan['newDisk']['id'].lower() in owned or D['az'](['deployment','group','list','--subscription',D['SUB'],'-g',RG,'--query',"[?name=='"+ACTION+"'].name"]): raise RuntimeError('New disk/deployment identity exists. Reconcile rather than repeat.')
            args = ['--subscription',D['SUB'],'-g',RG,'-n',ACTION,'--template-file',str(ROOT / TEMPLATE)]
            preview = D['az'](['deployment','group','what-if',*args,'--result-format','FullResourcePayloads','--no-pretty-print'],timeout=300)
            record['previewChanges'] = validate_preview(preview,owned,plan); record['phase'] = 'one-approved-disk-create-pending'; save()
            result = D['az'](['deployment','group','create',*args],timeout=600)
            if result['properties']['provisioningState'] != 'Succeeded': raise RuntimeError('Capacity disk deployment not successful')
            disk = D['az'](['disk','show','--subscription',D['SUB'],'--ids',plan['newDisk']['id']]); verify_new_disk(disk,plan)
            record['deploymentId'] = result['id']; record['newDisk'] = {key:disk.get(key) for key in ['id','uniqueId','diskSizeGB','sku','networkAccessPolicy','publicNetworkAccess']}
        elif stage == 'attach':
            created = previous('create')['newDisk']; disk = D['az'](['disk','show','--subscription',D['SUB'],'--ids',plan['newDisk']['id']]); verify_new_disk(disk,plan)
            if disk['uniqueId'] != created['uniqueId']: raise RuntimeError('New disk immutable identity changed')
            record['requestedFieldDiff'] = {'addDataDiskId':disk['id'],'lun':9,'caching':'None','otherVmOrExistingDiskChanges':False}
            record['previewKind'] = 'local-exact-attachment-field-diff-not-ARM-policy-what-if'; record['phase'] = 'one-lun9-attachment-pending'; save()
            D['az'](['vm','disk','attach','--subscription',D['SUB'],'-g',RG,'--vm-name',HOST,'--name',disk['id'],'--lun','9','--caching','None'],timeout=600)
            actual = vm_projection(); verify_vm(actual,plan,attached=True)
            attached = D['az'](['disk','show','--subscription',D['SUB'],'--ids',disk['id']]); verify_new_disk(attached,plan,attached=True)
            if attached['uniqueId'] != created['uniqueId']: raise RuntimeError('Attached disk immutable identity differs')
            verify_existing_disks(disk_projection(),plan,with_new=True); record['vmAfter'] = actual
        elif stage in ['format','add-vhds']:
            created = previous('create')['newDisk']; live = D['az'](['disk','show','--subscription',D['SUB'],'--ids',plan['newDisk']['id']]); verify_new_disk(live,plan,attached=True)
            if live['uniqueId'] != created['uniqueId']: raise RuntimeError('New backing disk immutable identity changed')
            record['privateReceipt'],record['result'] = run_private(stage,public_context(created['uniqueId'],resume_binding_fix=resume_binding_fix))
        else:
            created = previous('create')['newDisk']; disk = D['az'](['disk','show','--subscription',D['SUB'],'--ids',plan['newDisk']['id']]); verify_new_disk(disk,plan,attached=True)
            if disk['uniqueId'] != created['uniqueId']: raise RuntimeError('Final new disk immutable identity differs')
            with contextlib.redirect_stdout(io.StringIO()): code = D['T']['main']('scripts/inspect-smal-three-node-final.ps1','capacity-final-observation-20261030')
            private = D['T']['OUT'] / 'private-ssh-capacity-final-observation-20261030.json'; proof = json.loads(private.read_text())
            if code != 0: raise RuntimeError('Post-addition inspection incomplete')
            record['privateReceipt'] = str(private.relative_to(ROOT)); record['result'] = verify_growth(plan,previous('prepare')['result'],previous('add-vhds')['result'],proof)
            record['azureDataCapacityGiB'] = sum(r['sizeGiB'] for r in disk_projection() if r['id'].lower() != plan['vmBefore']['osId'].lower())
            if record['azureDataCapacityGiB'] != 8192: raise RuntimeError('Exact doubled Azure data backing capacity not observed')
        record['status'] = 'complete'
    except (TimeoutError,subprocess.TimeoutExpired): record['status'] = 'uncertain-timeout-inspect-do-not-repeat'
    except (RuntimeError,ValueError,KeyError,OSError,subprocess.SubprocessError) as error:
        record['status'] = 'failed-inspect-before-resume'; record['errorType'] = type(error).__name__
        if isinstance(error,RuntimeError): record['error'] = str(error)
    record['finishedAtUtc'] = datetime.now(timezone.utc).isoformat(); save(); print(json.dumps(record,indent=2))
    return 0 if record['status'] == 'complete' else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('stage',choices=STAGES)
    parser.add_argument('--resume-first-vhd-binding',action='store_true'); args = parser.parse_args()
    if args.resume_first_vhd_binding and args.stage != 'add-vhds': parser.error('first-file binding correction applies only to add-vhds')
    raise SystemExit(main(args.stage,args.resume_first_vhd_binding))
