"""Offline exact three-node/no-witness platform effects and verified identities."""
import copy
import base64
import json
from pathlib import Path
import runpy
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ThreeNodeDeploymentTests(unittest.TestCase):
    def test_change_history_preserves_real_premium_to_standard_drift_without_mutation(self):
        record = json.loads((ROOT / 'docs/deployment-2026-10-29/three-node-disk-tier-resource-changes-20261030.json').read_text())
        self.assertEqual(record['status'],'observed')
        self.assertFalse(record['azureMutationPerformed'])
        rows = record['changes']; self.assertEqual(len({row['resourceId'].lower() for row in rows}),10)
        self.assertTrue(all(row['previousSku'] == 'Premium_LRS' and row['newSku'] == 'Standard_LRS' for row in rows))
        self.assertEqual(record['truncated'],'false')

    def test_boot_agent_and_tpm_metadata_do_not_hide_unencrypted_os_volumes(self):
        proof = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-boot-encryption-recovery-metadata-20261030.json').read_text())
        data = proof['result']; self.assertEqual(data['observationStatus'],'complete-read-only')
        self.assertFalse(data['recoveryKeysExported']); self.assertFalse(data['mutationPerformed'])
        self.assertEqual(len(data['nodes']),3)
        for node in data['nodes']:
            self.assertTrue(all(node['tpm'][key] for key in ['present','ready','enabled','activated']))
            self.assertEqual(node['bootVolume']['protectionStatus'],'Off')
            self.assertEqual(node['bootVolume']['protectorCount'],0)
            self.assertTrue(node['bitLockerAgent']['observationSucceeded'])
        self.assertEqual(len(data['adRecoveryMetadata']),4)

    def test_independent_acceptance_checks_exact_storage_and_keeps_real_encryption_gap_visible(self):
        h = runpy.run_path(str(ROOT / 'scripts/assess-smal-three-node-acceptance.py'),run_name='independent_acceptance_test')
        proof = json.loads((ROOT / h['WINDOWS']).read_text()); bindings = json.loads((ROOT / h['BINDINGS']).read_text())
        result = h['verify_storage'](proof,bindings)
        self.assertEqual(result['approvedPoolMemberCount'],12)
        self.assertTrue(result['osDisksExcluded'])
        self.assertEqual(len(h['boot_encryption_issues'](proof)),3)
        bad = copy.deepcopy(proof); bad['result']['nodes'][0]['guest']['storagePools'][0]['members'][0]['uniqueId'] = 'foreign-or-os-disk'
        with self.assertRaises(RuntimeError): h['verify_storage'](bad,bindings)
        bad = copy.deepcopy(proof); bad['result']['nodes'][0]['guest']['quorumResourceName'] = 'Cloud Witness'
        with self.assertRaises(RuntimeError): h['verify_storage'](bad,bindings)
        cloud = json.loads((ROOT / h['CLOUD']).read_text()); h['verify_cloud'](cloud)
        cloud['customLocationResources'][0]['hostResourceId'] = 'other-bridge'
        with self.assertRaises(RuntimeError): h['verify_cloud'](cloud)

    def test_bitlocker_gap_diagnostic_parses_without_enable_disable_or_key_export(self):
        path = ROOT / 'scripts/inspect-smal-bitlocker-gap.ps1'; source = path.read_text()
        for forbidden in ['Enable-ASBitLocker','Disable-ASBitLocker','Enable-BitLocker','Get-AsRecoveryKeyInfo','msFVE-RecoveryPassword','Set-LocalUser','Set-TPM']:
            self.assertNotIn(forbidden,source)
        self.assertIn('Get-ASBitLocker -VolumeType BootVolume -Local',source)
        self.assertIn('recoveryKeysExported = $false',source)
        code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
        subprocess.run(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-Command',code],check=True,capture_output=True,timeout=30)

    def test_postdeploy_observer_uses_documented_renamed_rid500_without_fallback_or_reset(self):
        source = (ROOT / 'scripts/inspect-smal-three-node-final.ps1').read_text()
        self.assertIn("$vm.Name + '\\ASBuiltInAdmin'",source)
        self.assertIn("$admin.SID.Value.EndsWith('-500')",source)
        self.assertNotIn("$vm.Name + '\\Administrator'",source)
        self.assertEqual(source.count('New-PSSession -VMId'),1)
        for forbidden in ['Rename-LocalUser','Set-LocalUser','Enable-LocalUser','Reset-','Set-ADAccountPassword']:
            self.assertNotIn(forbidden,source)

    def test_completed_service_deploy_is_positive_but_not_final_acceptance(self):
        h = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'),run_name='service_deploy_success_test')
        receipt = json.loads((ROOT / 'docs/deployment-2026-10-29/three-node-cluster-deploy-observation-follow-up-20261030.json').read_text())
        self.assertEqual(receipt['status'],'complete')
        self.assertEqual(receipt['deploymentState'],'Succeeded')
        self.assertTrue(h['service_passed'](receipt['serviceResult']))
        self.assertFalse(receipt['platformReadinessVerified'])
        self.assertFalse(receipt['azureMutationPerformed'])
        self.assertTrue(receipt['originalTimeoutRetained'])

    def test_final_observer_uses_documented_node_parameter_and_cloud_audit_handles_cli_shape(self):
        source = (ROOT / 'scripts/inspect-smal-three-node-final.ps1').read_text()
        self.assertIn('Get-ClusterStorageSpacesDirect -Node $ExpectedName',source)
        self.assertNotIn('Get-ClusterStorageSpacesDirect -Cluster',source)
        self.assertIn("observationStatus = 'failed-safe-diagnostic'",source)
        h = runpy.run_path(str(ROOT / 'scripts/inspect-smal-three-node-cloud-health.py'),run_name='audit_shape_test')
        data = [{'name':'audit','storageAccountId':'synthetic','logs':[{'category':'AuditEvent','enabled':True}],'unwanted':'not-exported'}]
        self.assertEqual(h['audit_metadata'](data),h['audit_metadata']({'value':data}))
        self.assertNotIn('unwanted',h['audit_metadata'](data)[0])
        with self.assertRaises(RuntimeError): h['audit_metadata'](None)

    def test_deploy_follow_up_preserves_exact_pending_observation_and_never_replays(self):
        h = runpy.run_path(str(ROOT / 'scripts/observe-smal-existing-deploy.py'),run_name='deploy_follow_up_test')
        prior = json.loads((ROOT / 'docs/deployment-2026-10-29/three-node-cluster-deploy-observation-20261030.json').read_text())
        h['verify_follow_up'](prior,prior['templateSha256'])
        for field,value in [('deploymentState','Failed'),('deploySubmitted',True),('azureMutationPerformed',True),('deploymentId','other'),('stage','validate')]:
            bad = copy.deepcopy(prior); bad[field] = value
            with self.assertRaises(RuntimeError): h['verify_follow_up'](bad,prior['templateSha256'])
        with self.assertRaises(RuntimeError): h['verify_follow_up'](prior,'changed-template')

    def test_existing_deploy_observer_requires_exact_retained_request_and_cannot_submit(self):
        h = runpy.run_path(str(ROOT / 'scripts/observe-smal-existing-deploy.py'),run_name='deploy_observer_test')
        prior = json.loads((ROOT / h['ORIGINAL']).read_text())
        self.assertEqual(h['verify_original'](prior),prior['templateSha256'])
        for field,value in [('stage','validate'),('deploymentState','Succeeded'),('explicitRequestedMode','Validate'),('templateSha256','changed'),('deploymentId','other')]:
            bad = copy.deepcopy(prior); bad[field] = value
            with self.assertRaises(RuntimeError): h['verify_original'](bad)
        source = (ROOT / 'scripts/observe-smal-existing-deploy.py').read_text()
        for forbidden in ["'create'","'put'","'update'","'start'","'delete'"]:
            self.assertNotIn(forbidden,source)
        self.assertIn("'azureMutationPerformed':False",source)

    def test_deploy_configuration_only_normalises_exact_observed_empty_defaults(self):
        h = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'),run_name='deploy_defaults_test')
        live = {'scaleUnits':[{'deploymentData':{'cluster':{'name':'smal-localbox01','witnessType':'','witnessPath':'','cloudAccountName':'','azureServiceEndpoint':'','hardwareClass':'Medium'},
                'assemblyInfo':{'payload':[{'identifier':'SolutionVersion','fileName':'12.2610.1004.41','hash':'','url':''}]}}}]}
        preview = copy.deepcopy(live)
        cluster = preview['scaleUnits'][0]['deploymentData']['cluster']
        for key in ['witnessType','witnessPath','cloudAccountName','azureServiceEndpoint','hardwareClass']: del cluster[key]
        item = preview['scaleUnits'][0]['deploymentData']['assemblyInfo']['payload'][0]; del item['hash']; del item['url']
        self.assertEqual(h['canonical_deploy_configuration'](live),h['canonical_deploy_configuration'](preview))
        for key,value in [('witnessType','Cloud'),('hardwareClass','Large'),('cloudAccountName','unapproved')]:
            bad = copy.deepcopy(live); bad['scaleUnits'][0]['deploymentData']['cluster'][key] = value
            with self.assertRaises(RuntimeError): h['canonical_deploy_configuration'](bad)
        bad = copy.deepcopy(live); bad['scaleUnits'][0]['deploymentData']['assemblyInfo']['payload'][0]['url'] = 'unexpected'
        with self.assertRaises(RuntimeError): h['canonical_deploy_configuration'](bad)

    def test_deploy_preview_allows_exact_existing_nochange_but_not_config_or_resource_changes(self):
        h = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'),run_name='nochange_deploy_guard_test')
        ids = [h['SCOPE'] + '/providers/Microsoft.HybridCompute/machines/' + name for name in h['P']['NODES']]
        props = {'deploymentMode':'Validate','arcNodeResourceIds':ids,'deploymentConfiguration':{'synthetic':'unchanged'}}
        live = {'id':h['SETTINGS'],'properties':{**props,'provisioningState':'Succeeded'}}
        data = {'status':'Succeeded','changes':[{'resourceId':h['SETTINGS'],'changeType':'NoChange','before':{'properties':copy.deepcopy(props)},'after':{'properties':copy.deepcopy(props)},'delta':[]}]}
        self.assertEqual(h['check_deploy_preview'](data,set(),live)[0]['changeType'],'NoChange')
        for kind in ['Create','Delete','Ignore']:
            bad = copy.deepcopy(data); bad['changes'][0]['changeType'] = kind
            with self.assertRaises(RuntimeError): h['check_deploy_preview'](bad,set(),live)
        for key,value in [('deploymentConfiguration',{'changed':True}),('arcNodeResourceIds',ids[:2]),('deploymentMode','Deploy')]:
            bad = copy.deepcopy(data); bad['changes'][0]['after']['properties'][key] = value
            with self.assertRaises(RuntimeError): h['check_deploy_preview'](bad,set(),live)
        modified = copy.deepcopy(data); modified['changes'][0]['changeType'] = 'Modify'; modified['changes'][0]['after']['properties']['deploymentMode'] = 'Deploy'
        h['check_deploy_preview'](modified,set(),live)
        modified['changes'][0]['after']['properties']['unlisted'] = True
        with self.assertRaises(RuntimeError): h['check_deploy_preview'](modified,set(),live)
        bad = copy.deepcopy(data); bad['changes'].append({'resourceId':h['VAULT'],'changeType':'Modify'})
        with self.assertRaises(RuntimeError): h['check_deploy_preview'](bad,{h['VAULT'].lower()},live)

    def test_unsubmitted_deploy_reconciliation_cannot_replay_a_submitted_operation(self):
        h = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'),run_name='unsubmitted_deploy_guard_test')
        out = ROOT / 'docs/deployment-2026-10-29'
        prior = json.loads((out / 'three-node-cluster-deploy-receipt.json').read_text())
        diagnostic = json.loads((out / 'three-node-deploy-preview-reconciliation-20261030.json').read_text())
        h['verify_unsubmitted_deploy'](prior,diagnostic)
        for field,value in [('previewChanges',[]),('deploymentId','submitted'),('deploymentState','Running')]:
            bad = copy.deepcopy(prior); bad[field] = value
            with self.assertRaises(RuntimeError): h['verify_unsubmitted_deploy'](bad,diagnostic)
        bad = copy.deepcopy(diagnostic); bad['deployArmRecords'] = ['exists']
        with self.assertRaises(RuntimeError): h['verify_unsubmitted_deploy'](prior,bad)

    def test_reconciled_validation_success_and_current_domain_storage_proof_are_positive(self):
        h = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'),run_name='positive_validation_receipt_test')
        receipt = json.loads((ROOT / 'docs/deployment-2026-10-29/three-node-cluster-validation-success-reconciliation-20261030.json').read_text())
        self.assertEqual(receipt['status'],'complete')
        self.assertEqual(receipt['clusterStatus'],'ValidationSuccess')
        self.assertTrue(h['service_passed'](receipt['serviceResult']))
        self.assertFalse(receipt['azureMutationPerformed'])
        self.assertFalse(receipt['deploySubmitted'])
        self.assertTrue(receipt['originalObserverTimeoutRetained'])
        proof = json.loads((ROOT / receipt['privateInputsReceipt']).read_text())
        h['P']['verify_local'](proof,require_ad=True,validated_ad_members=True)
        with self.assertRaises(RuntimeError):
            h['check_preview']('deploy',{'status':'Succeeded','changes':[{'resourceId':h['SETTINGS'],'changeType':'Create'}]},set())

    def test_only_exact_inapplicable_local_identity_validation_may_be_skipped_for_ad(self):
        h = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'),run_name='ad_skip_gate_test')
        prior = json.loads((ROOT / 'docs/deployment-2026-10-29/three-node-cluster-validate-gateway-after-auth-reconciliation-receipt.json').read_text())
        result = copy.deepcopy(prior['serviceResult'])
        self.assertFalse(h['service_passed'](result))
        result['adConfigurationVerified'] = True
        self.assertTrue(h['service_passed'](result))
        for field,value in [('mode','Deploy'),('adConfigurationVerified',False),('provisioningState','Failed')]:
            bad = copy.deepcopy(result); bad[field] = value
            self.assertFalse(h['service_passed'](bad))
        for field,value in [('index','121'),('name','Azure Local Storage Validation'),('exceptionCount',1),('children',[{'status':'Success'}])]:
            bad = copy.deepcopy(result); skipped = next(step for step in bad['action']['steps'] if step['status'] == 'Skipped'); skipped[field] = value
            self.assertFalse(h['service_passed'](bad))
        bad = copy.deepcopy(result); bad['action']['steps'][0]['status'] = 'Skipped'
        self.assertFalse(h['service_passed'](bad))
        bad = copy.deepcopy(result); bad['action']['steps'] = []
        self.assertFalse(h['service_passed'](bad))

    def test_postvalidation_predeploy_checks_require_exact_ad_membership_not_standalone(self):
        h = self.helpers()
        proof = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-three-node-live-after-arc-20261029.json').read_text())
        for node in proof['result']['nodes']:
            node['guest'].update(domainRole=3,domain='ad.localbox.test',partOfDomain=True)
        h['verify_local'](proof,validated_ad_members=True)
        with self.assertRaises(RuntimeError): h['verify_local'](proof)
        for field,value in [('domainRole',2),('domain','other.test'),('partOfDomain',False)]:
            bad = copy.deepcopy(proof); bad['result']['nodes'][0]['guest'][field] = value
            with self.assertRaises(RuntimeError): h['verify_local'](bad,validated_ad_members=True)

    def test_gateway_auth_resumption_refuses_any_possible_prior_submission_or_changed_settings(self):
        h = runpy.run_path(str(ROOT / 'scripts/retry-smal-initial-validation.py'),run_name='gateway_auth_resume_test')
        out = ROOT / 'docs/deployment-2026-10-29'
        prior = json.loads((out / 'three-node-cluster-validate-after-gateway-echo-receipt.json').read_text())
        reconciled = json.loads((out / 'gateway-validation-unsubmitted-auth-reconciliation.json').read_text())
        h['verify_unsubmitted_gateway'](prior,reconciled)
        for field,value in [('deploymentId','submitted'),('deploymentState','Running'),('previewChanges',[]),('templateSha256','changed'),('deploySubmitted',True)]:
            bad = copy.deepcopy(prior); bad[field] = value
            with self.assertRaises(RuntimeError): h['verify_unsubmitted_gateway'](bad,reconciled)
        for field,value in [('gatewayRetryOrDeployArmRecords',['exists']),('azureMutationPerformed',True),('deniedAction','different')]:
            bad = copy.deepcopy(reconciled); bad[field] = value
            with self.assertRaises(RuntimeError): h['verify_unsubmitted_gateway'](prior,bad)

    def test_gateway_retry_authorization_refusal_is_retained_and_unsubmitted(self):
        out = ROOT / 'docs/deployment-2026-10-29'
        refused = json.loads((out / 'three-node-cluster-validate-after-gateway-echo-receipt.json').read_text())
        self.assertEqual(refused['status'],'failed-inspect-before-resume')
        self.assertNotIn('deploymentId',refused)
        self.assertNotIn('previewChanges',refused)
        self.assertFalse(refused['deploySubmitted'])
        actual = json.loads((out / 'gateway-validation-unsubmitted-auth-reconciliation.json').read_text())
        self.assertEqual(actual['gatewayRetryOrDeployArmRecords'],[])
        self.assertEqual(actual['errorCode'],'AuthorizationFailed')
        self.assertEqual(actual['deniedAction'],'Microsoft.Resources/deployments/whatIf/action')
        self.assertFalse(actual['azureMutationPerformed'])
        self.assertFalse(actual['privilegeActivationAttempted'])
    def test_gateway_retry_requires_successful_probes_and_exact_effective_rule(self):
        h = runpy.run_path(str(ROOT / 'scripts/retry-smal-initial-validation.py'),run_name='gateway_retry_guard_test')
        fix = json.loads((ROOT / 'docs/deployment-2026-10-29/gateway-echo-rule-receipt.json').read_text())
        proof = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-infra-network-after-echo-rule-20261029.json').read_text())
        h['verify_echo_recovery'](fix,proof)
        bad = copy.deepcopy(proof); bad['result']['nodes'][0]['guest']['probes'][0]['echoReplyReceived'] = False
        with self.assertRaises(RuntimeError): h['verify_echo_recovery'](fix,bad)
        for field,value in [('remoteAddress',['Any']),('localAddress',['Any']),('interfaceAlias',['Any']),('icmpType',['Any'])]:
            bad = copy.deepcopy(proof)
            rule = next(row for row in bad['result']['hostIcmpInboundRules'] if row['name'] == 'AzureLocalBox-InternalGateway-Echo-v4')
            rule[field] = value
            with self.assertRaises(RuntimeError): h['verify_echo_recovery'](fix,bad)
        recovery = runpy.run_path(str(ROOT / 'scripts/smal-validation-recovery.py'),run_name='network_error_guard_test')
        cluster = {'id':recovery['D']['CLUSTER'],'identity':{'principalId':'8c44672b-b729-4d3f-ad38-a0ac815ea265'},'properties':{'status':'ValidationFailed','provisioningState':'Succeeded'}}
        settings = {'id':recovery['D']['SETTINGS'],'properties':{'deploymentMode':'Validate','provisioningState':'Failed','reportedProperties':{'validationStatus':{'status':'Error','steps':[{'exception':[recovery['NETWORK_ERROR']]}]}}}}
        recovery['verify_initial_validation'](cluster,settings,[],recovery['NETWORK_ERROR'])
        with self.assertRaises(RuntimeError): recovery['verify_initial_validation'](cluster,settings,[])
        cluster['properties']['status'] = 'DeploymentFailed'
        with self.assertRaises(RuntimeError): recovery['verify_initial_validation'](cluster,settings,[],recovery['NETWORK_ERROR'])

    def test_gateway_echo_rule_has_exact_human_scope_and_no_existing_rule_changes(self):
        approval = json.loads((ROOT / 'docs/deployment-2026-10-29/gateway-echo-rule-approval.json').read_text())
        self.assertTrue(approval['approved'])
        self.assertEqual(approval['humanAnswer'],'Approve scoped echo rule')
        self.assertEqual(approval['localAddress'],'10.64.0.1')
        self.assertEqual(approval['remoteAddress'],['10.64.0.11-10.64.0.13','10.64.0.20-10.64.0.30'])
        path = ROOT / 'scripts/allow-smal-internal-gateway-echo.ps1'
        source = path.read_text()
        self.assertEqual(source.count('New-NetFirewallRule'),1)
        for forbidden in ['Set-NetFirewall','Enable-NetFirewallRule','Disable-NetFirewallRule','Remove-NetFirewallRule','Set-VMNetwork','Set-NetIPAddress','New-NetIPAddress']:
            self.assertNotIn(forbidden,source)
        self.assertIn("-LocalAddress '10.64.0.1' -RemoteAddress $sources",source)
        self.assertIn('-InterfaceAlias $interface',source)
        self.assertIn('-Protocol ICMPv4 -IcmpType 8',source)
        self.assertIn('Read-ExactEchoRule -PolicyStore ActiveStore',source)
        code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
        subprocess.run(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-Command',code],check=True,capture_output=True,timeout=30)

    def test_gateway_failure_proof_distinguishes_echo_from_layer_two_connectivity(self):
        proof = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-infra-network-failure-20261029.json').read_text())
        self.assertEqual(proof['status'],'complete')
        data = proof['result']; self.assertFalse(data['mutationPerformed'])
        self.assertEqual(len(data['nodes']),3)
        for node in data['nodes']:
            probes = {row['destination']:row['echoReplyReceived'] for row in node['guest']['probes']}
            self.assertEqual(probes,{'10.64.0.1':False,'10.64.0.10':True})
            gateway = [row for row in node['guest']['neighbors'] if row['IPAddress'] == '10.64.0.1']
            self.assertEqual(len(gateway),1)
            self.assertEqual(gateway[0]['LinkLayerAddress'],'00-15-5D-10-04-00')
        echo = [rule for rule in data['hostIcmpInboundRules'] if '8' in rule['icmpType']]
        self.assertTrue(echo)
        self.assertTrue(all(rule['enabled'] == 'False' for rule in echo))
    def test_infrastructure_network_diagnostic_is_read_only_and_parses(self):
        path = ROOT / 'scripts/inspect-smal-infra-network-failure.ps1'
        source = path.read_text()
        for forbidden in ['New-NetIPAddress','New-NetFirewallRule','Set-NetFirewall','Set-VMNetwork','Remove-Net','Restart-','Clear-Disk']:
            self.assertNotIn(forbidden,source)
        self.assertIn('Get-NetFirewallPortFilter -PolicyStore ActiveStore',source)
        self.assertIn('mutationPerformed = $false',source)
        code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
        subprocess.run(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-Command',code],check=True,capture_output=True,timeout=30)
    def test_corrected_validation_observer_requires_exact_retained_pending_request(self):
        h = runpy.run_path(str(ROOT / 'scripts/observe-smal-corrected-validation.py'),run_name='validation_observer_test')
        prior = json.loads((ROOT / h['ORIGINAL']).read_text())
        self.assertEqual(h['verify_original'](prior),prior['templateSha256'])
        for field,value in [('deploymentName','different'),('deploymentState','Succeeded'),('deploySubmitted',True),('templateSha256','changed')]:
            bad = copy.deepcopy(prior); bad[field] = value
            with self.assertRaises(RuntimeError): h['verify_original'](bad)
        source = (ROOT / 'scripts/observe-smal-corrected-validation.py').read_text()
        self.assertNotIn("'create'",source)
        self.assertNotIn("'put'",source)
        self.assertNotIn("'update'",source)
        self.assertIn("'azureMutationPerformed':False",source)

    def test_completed_lcm_correction_retains_original_and_changes_no_password_or_account(self):
        receipt = json.loads((ROOT / 'docs/deployment-2026-10-29/lcm-credential-format-correction-receipt.json').read_text())
        self.assertEqual(receipt['status'],'complete-one-lcm-username-format-version-only')
        self.assertTrue(receipt['originalQualifiedValueMatchedHostCredential'])
        self.assertTrue(receipt['unqualifiedCredentialReadbackMatched'])
        self.assertEqual({row['id'] for row in receipt['versionsRetained']},{receipt['originalVersionId'],receipt['newVersionId']})
        self.assertTrue(all(row['enabled'] for row in receipt['versionsRetained']))
        for field in ['passwordRotated','adAccountChanged','localAdminSecretChanged','clusterRecreated','validateInvoked','ownerArmTokenForwarded','publicAccessChanged']:
            self.assertFalse(receipt[field])
        self.assertEqual(receipt['vaultPublicAccessAfter'],'Disabled')

    def test_validation_diagnostics_redact_credential_encodings_tokens_and_queries(self):
        h = runpy.run_path(str(ROOT / 'scripts/diagnose-smal-three-node-validation.py'),run_name='diagnostic_redaction_test')
        credential = 'A1!b' * 10
        encoded = base64.b64encode(('LOCALBOX\\lboxdeploy:' + credential).encode()).decode()
        text = 'Error Invoking Environment Checker. password="' + credential + '" encoded=' + encoded + ' access_token="short-sensitive-token" https://example.test/a?sig=shortSensitiveSignature enter code: ABC123XYZ'
        safe = h['redact'](text)
        for value in [credential,encoded,'short-sensitive-token','shortSensitiveSignature','ABC123XYZ']:
            self.assertNotIn(value,safe)
        self.assertIn('Environment Checker',safe)
        self.assertIn('[REDACTED',safe)

    def test_published_secret_and_prerequisite_receipts_preserve_private_no_witness_boundary(self):
        out = ROOT / 'docs/deployment-2026-10-29'
        secrets = json.loads((out / 'three-node-cluster-secrets-after-private-transport-reconciliation.json').read_text())
        self.assertEqual(secrets['status'],'complete')
        self.assertEqual(secrets['deploymentState'],'Succeeded')
        self.assertEqual(len(secrets['secretMetadata']),2)
        self.assertTrue(all(row['enabled'] for row in secrets['secretMetadata']))
        self.assertEqual(secrets['vaultPublicAccessAfter'],'Disabled')
        self.assertFalse(secrets['witnessKeyReadOrUpload'])
        self.assertTrue(secrets['originalPreSubmitRefusalRetained'])
        proof = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-sealed-platform-credentials-20261029.json').read_text())
        self.assertEqual(proof['status'],'complete')
        self.assertEqual(proof['result']['scheme'],'RSA4096-OAEP-SHA256')
        self.assertFalse(proof['result']['clearValuesExported'])
        prereq = json.loads((out / 'three-node-cluster-prerequisites-receipt.json').read_text())
        role = json.loads((out / 'three-node-cluster-cluster-role-receipt.json').read_text())
        self.assertEqual(prereq['status'],'complete')
        self.assertEqual(len(prereq['previewChanges']),4)
        self.assertEqual(len(prereq['edgeDevices']),3)
        self.assertTrue(all(row['provisioningState'] == 'Succeeded' for row in prereq['edgeDevices']))
        self.assertEqual(prereq['clusterReadback']['identity']['principalId'],role['inspectedClusterIdentity']['principalId'])
        self.assertEqual(role['status'],'complete')
        self.assertEqual(role['clusterVaultRole']['principalId'],prereq['clusterReadback']['identity']['principalId'])
        self.assertTrue(role['clusterVaultRole']['scope'].lower().endswith('/providers/microsoft.keyvault/vaults/kv-lbox-weu-4766ea'))
        self.assertFalse(role['platformReadinessVerified'])

    def test_final_windows_observer_parses_and_cannot_repair_or_reset_anything(self):
        path = ROOT / 'scripts/inspect-smal-three-node-final.ps1'
        code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
        subprocess.run(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-Command',code],check=True,capture_output=True,timeout=30)
        source = path.read_text()
        for forbidden in ['Format-Volume','Clear-Disk','Set-LocalUser','Set-Cluster','Start-VM','Restart-Service','Get-AzAccessToken','Invoke-AzStackHciArcInitialization']:
            self.assertNotIn(forbidden,source)
        self.assertIn('credentialsReset = $false',source)
        self.assertIn('Get-ClusterQuorum',source)

    def test_secret_transport_resume_requires_proven_before_sealing_and_no_submission(self):
        h = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'),run_name='pre_submit_resume_test')
        prior = json.loads((ROOT / 'docs/deployment-2026-10-29/three-node-cluster-secrets-receipt.json').read_text())
        h['verify_unsubmitted_secret_resume'](prior,False,prior['templateSha256'])
        with self.assertRaises(RuntimeError): h['verify_unsubmitted_secret_resume'](prior,True,prior['templateSha256'])
        with self.assertRaises(RuntimeError): h['verify_unsubmitted_secret_resume'](prior,False,'changed-template')
        bad = copy.deepcopy(prior); bad['deploymentId'] = 'submitted'
        with self.assertRaises(RuntimeError): h['verify_unsubmitted_secret_resume'](bad,False,prior['templateSha256'])

    def test_no_witness_stage_previews_are_exact_and_do_not_retain_secret_payloads(self):
        h = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'), run_name='three_cluster_stage_test')
        self.assertEqual(len(h['SECRET_NAMES']),2)
        self.assertEqual(h['NAME'],'smal-localbox01')
        self.assertLessEqual(len(h['NAME']),15)
        self.assertEqual(len(h['effects']('prerequisites')),4)
        for stage in ['secrets','prerequisites','validate']:
            rows = [{'resourceId':rid,'changeType':'Modify' if stage == 'deploy' else 'Create','after':{'properties':{'value':'SYNTHETIC-SECRET'}}} for rid in h['effects'](stage)]
            good = {'status':'Succeeded','changes':rows}
            safe = h['check_preview'](stage,good,set())
            self.assertNotIn('SYNTHETIC-SECRET',json.dumps(safe))
            bad = copy.deepcopy(good); bad['changes'][0]['resourceId'] = h['VAULT']
            with self.assertRaises(RuntimeError): h['check_preview'](stage,bad,set())
        source = (ROOT / 'scripts/deploy-smal-three-node-cluster.py').read_text()
        self.assertNotIn("'storage','account','update'",source)
        self.assertNotIn("'storage', 'account', 'update'",source)
        self.assertIn("parameters = normalise_lcm_parameters(L['secret_parameters']())",source)

    def test_lcm_normalisation_preserves_exact_password_and_local_admin_value(self):
        h = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'),run_name='lcm_username_format_test')
        synthetic = b'A1!b' * 10
        parameters = {'localCredential':{'value':'untouched-synthetic-local-value'},'domainCredential':{'value':base64.b64encode(b'LOCALBOX\\lboxdeploy:' + synthetic).decode()}}
        normalised = h['normalise_lcm_parameters'](parameters)
        self.assertEqual(normalised['localCredential'],parameters['localCredential'])
        self.assertEqual(base64.b64decode(normalised['domainCredential']['value']),b'lboxdeploy:' + synthetic)
        self.assertEqual(h['normalise_lcm_parameters'](normalised),normalised)
        bad = copy.deepcopy(parameters); bad['domainCredential']['value'] = base64.b64encode(b'other-user:' + synthetic).decode()
        with self.assertRaises(RuntimeError): h['normalise_lcm_parameters'](bad)
        path = ROOT / 'scripts/seal-smal-lcm-format-fix.ps1'
        source = path.read_text()
        self.assertIn("-Role 'deployment-user'",source)
        self.assertNotIn("-Role 'cluster-node-admin'",source)
        self.assertNotIn('Set-ADAccountPassword',source)
        self.assertNotIn('WriteAllText',source)
        code = "$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1}"
        subprocess.run(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-Command',code],check=True,capture_output=True,timeout=30)

    def test_only_exact_terminal_initial_validation_error_can_be_retried(self):
        h = runpy.run_path(str(ROOT / 'scripts/smal-validation-recovery.py'),run_name='validation_state_gate_test')
        cluster = {'id':h['D']['CLUSTER'],'identity':{'principalId':'8c44672b-b729-4d3f-ad38-a0ac815ea265'},'properties':{'status':'ValidationFailed','provisioningState':'Succeeded'}}
        settings = {'id':h['D']['SETTINGS'],'properties':{'deploymentMode':'Validate','provisioningState':'Failed','reportedProperties':{'validationStatus':{'status':'Error','steps':[{'exception':[h['ERROR']]}]},'deploymentStatus':{'status':None,'steps':[]}}}}
        h['verify_initial_validation'](cluster,settings,[])
        bad = copy.deepcopy(cluster); bad['properties']['status'] = 'DeploymentFailed'
        with self.assertRaises(RuntimeError): h['verify_initial_validation'](bad,settings,[])
        bad = copy.deepcopy(settings); bad['properties']['reportedProperties']['deploymentStatus']['status'] = 'InProgress'
        with self.assertRaises(RuntimeError): h['verify_initial_validation'](cluster,bad,[])
        with self.assertRaises(RuntimeError): h['verify_initial_validation'](cluster,settings,['deploy-exists'])

    def test_initial_validation_retry_cannot_recreate_or_change_settings(self):
        h = runpy.run_path(str(ROOT / 'scripts/retry-smal-initial-validation.py'),run_name='initial_validation_retry_preview_test')
        properties = {'deploymentMode':'Validate','arcNodeResourceIds':['one','two','three'],'deploymentConfiguration':{'synthetic':'unchanged'}}
        good = {'status':'Succeeded','changes':[{'resourceId':h['D']['SETTINGS'],'changeType':'NoChange','before':{'properties':properties},'after':{'properties':copy.deepcopy(properties)}}]}
        h['validate_retry_preview'](good,set())
        for kind in ['Create','Delete']:
            bad = copy.deepcopy(good); bad['changes'][0]['changeType'] = kind
            with self.assertRaises(RuntimeError): h['validate_retry_preview'](bad,set())
        bad = copy.deepcopy(good); bad['changes'][0]['after']['properties']['deploymentMode'] = 'Deploy'
        with self.assertRaises(RuntimeError): h['validate_retry_preview'](bad,set())

    def test_reported_service_success_is_required_not_just_arm_acceptance(self):
        h = runpy.run_path(str(ROOT / 'scripts/deploy-smal-three-node-cluster.py'), run_name='three_service_outcome_test')
        safe = h['safe_action']({'status':'Success','steps':[{'name':'check','status':'Success','exception':[],'description':'SYNTHETIC-SECRET'}]})
        self.assertNotIn('SYNTHETIC-SECRET',json.dumps(safe))
        self.assertTrue(h['service_passed']({'provisioningState':'Succeeded','action':safe}))
        for status in ['InProgress','Error',None]:
            bad = {'provisioningState':'Succeeded','action':{**safe,'status':status}}
            self.assertFalse(h['service_passed'](bad))
        bad = copy.deepcopy(safe); bad['steps'][0]['status'] = 'Error'
        self.assertFalse(h['service_passed']({'provisioningState':'Succeeded','action':bad}))
        safe = h['safe_action']({'status':'Success','steps':[{'name':'check','status':'Success','exception':['SYNTHETIC-SECRET']} ]})
        self.assertNotIn('SYNTHETIC-SECRET',json.dumps(safe))
        self.assertFalse(h['service_passed']({'provisioningState':'Succeeded','action':safe}))

    def test_live_node03_role_receipt_is_exact_and_preserves_original_seven(self):
        p = self.helpers()
        receipt = json.loads((ROOT / 'docs/deployment-2026-10-29/node03-platform-roles-receipt.json').read_text())
        self.assertEqual(receipt['status'],'complete-three-node03-scoped-roles')
        self.assertEqual(receipt['deploymentState'],'Succeeded')
        self.assertEqual({p['R']['binding'](row) for row in receipt['assignmentsReadback']},p['NODE03_EXPECTED'])
        self.assertTrue(p['R']['EXPECTED'] <= {p['R']['binding'](row) for row in receipt['assignmentsBefore']})
        self.assertFalse(receipt['subscriptionWideGrantRequested'])
        self.assertFalse(receipt['publicAccessChangeRequested'])

    def helpers(self):
        return runpy.run_path(str(ROOT / 'scripts/smal-three-node-platform.py'), run_name='three_platform_test')

    def test_cloud_and_private_proofs_require_all_three_exact_successful_nodes(self):
        p = self.helpers()
        cloud = json.loads((ROOT / 'docs/deployment-2026-10-29/three-node-arc-verified.json').read_text())
        local = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-three-node-live-after-arc-20261029.json').read_text())
        p['verify_cloud'](cloud['arcMachines']); p['verify_local'](local)
        bad = copy.deepcopy(cloud['arcMachines']); bad[2]['identity']['principalId'] = 'other'
        with self.assertRaises(RuntimeError): p['verify_cloud'](bad)
        bad = copy.deepcopy(local); bad['result']['nodes'][2]['guest']['bootstrapStatus'] = 'Failed'
        with self.assertRaises(RuntimeError): p['verify_local'](bad)
        bad = copy.deepcopy(local); bad['result']['nodes'][2]['guest']['disks'][1]['style'] = 'GPT'
        with self.assertRaises(RuntimeError): p['verify_local'](bad)
        bad = copy.deepcopy(local); bad['result']['nodes'][0]['hostDisks'][4]['path'] = 'C:\\wrong.vhdx'
        with self.assertRaises(RuntimeError): p['verify_local'](bad)

    def test_current_ad_expiry_and_ou_proof_remain_required(self):
        p = self.helpers()
        local = json.loads((ROOT / 'docs/deployment-2026-10-27/private-ssh-three-node-live-after-arc-20261029.json').read_text())
        local['result']['ad'] = {'domain': 'ad.localbox.test', 'ou': 'OU=SMAL01,OU=AzureLocal,DC=ad,DC=localbox,DC=test', 'inheritanceBlocked': True,
                                 'lcm': {'user': 'lboxdeploy', 'enabled': True, 'expired': False, 'neverExpires': False, 'groupCount': 0}}
        p['verify_local'](local, require_ad=True)
        local['result']['ad']['lcm']['expired'] = True
        with self.assertRaises(RuntimeError): p['verify_local'](local, require_ad=True)

    def test_node03_role_preview_refuses_any_extra_principal_role_or_scope(self):
        p = self.helpers(); changes = []
        for index, (scope, principal, role) in enumerate(sorted(p['NODE03_EXPECTED'])):
            changes.append({'resourceId': scope + '/providers/Microsoft.Authorization/roleAssignments/synthetic-' + str(index), 'changeType': 'Create', 'after': {'type': 'Microsoft.Authorization/roleAssignments', 'properties': {'principalId': principal, 'scope': scope, 'roleDefinitionId': '/subscriptions/' + p['SUB'] + '/providers/Microsoft.Authorization/roleDefinitions/' + role}}})
        data = {'status': 'Succeeded', 'changes': changes}; p['validate_node03_preview'](data, set())
        for key, value in [('principalId','other'),('scope','/subscriptions/' + p['SUB']),('roleDefinitionId','/roles/Owner'),('principalType','User')]:
            bad = copy.deepcopy(data); bad['changes'][0]['after']['properties'][key] = value
            with self.assertRaises(RuntimeError): p['validate_node03_preview'](bad, set())
        bad = copy.deepcopy(data); bad['changes'].pop()
        with self.assertRaises(RuntimeError): p['validate_node03_preview'](bad, set())
        result = subprocess.run(['az','bicep','build','--file',str(ROOT / 'infra/bicep/localbox-node03-platform-roles.bicep'),'--stdout','--only-show-errors'], check=True, capture_output=True, text=True, timeout=90)
        self.assertTrue(all(row['type'] == 'Microsoft.Authorization/roleAssignments' for row in json.loads(result.stdout)['resources']))

    def test_three_node_derivation_has_no_witness_key_or_public_configuration(self):
        h = runpy.run_path(str(ROOT / 'scripts/derive-smal-three-node-cluster.py'), run_name='no_witness_derivation_test')
        built = h['build']()
        for name, value in built.items():
            self.assertEqual(value, json.loads((ROOT / 'infra/arm' / name).read_text()))
            text = json.dumps(value)
            self.assertNotIn('listKeys', text)
            self.assertNotIn('WitnessStorageKey', text)
            self.assertNotIn('stlboxwitweu4766ea', text)
            self.assertNotIn('publicNetworkAccess', text)
        settings = built['localbox-three-node-settings.json']
        self.assertEqual(len(settings['parameters']['arcNodeResourceIds']['defaultValue']), 3)
        self.assertEqual(settings['parameters']['witnessType']['allowedValues'], ['No Witness'])
        self.assertEqual(settings['parameters']['clusterWitnessStorageAccountName']['defaultValue'], '')
        self.assertEqual(settings['parameters']['clusterName']['defaultValue'],'smal-localbox01')
        for template in built.values():
            for parameter in template.get('parameters',{}).values():
                if isinstance(parameter.get('defaultValue'),str):
                    self.assertLessEqual(len(parameter['defaultValue']),parameter.get('maxLength',2**31))
        self.assertEqual(len(settings['variables']['deploymentSecretsList']), 2)
        self.assertEqual(len(built['localbox-three-node-secrets.json']['resources']), 2)
        for network in settings['parameters']['storageNetworkList']['defaultValue']:
            self.assertEqual(len(network['storageAdapterIPInfo']), 3)
            self.assertEqual(network['storageAdapterIPInfo'][2]['physicalNode'], 'LB-NODE03')


if __name__ == '__main__': unittest.main()
