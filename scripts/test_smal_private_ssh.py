from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SETUP = (ROOT / 'scripts/enable-smal-private-ssh.ps1').read_text()
H = runpy.run_path(str(ROOT / 'scripts/enable-smal-private-ssh.py'), run_name='ssh_setup_test')
TRANSPORT = runpy.run_path(str(ROOT / 'scripts/smal-private-powershell.py'), run_name='ssh_transport_test')


class PrivateSshTests(unittest.TestCase):
    def test_powershell_scripts_parse(self):
        for file in ['enable-smal-private-ssh.ps1', 'verify-smal-private-powershell.ps1', 'inspect-smal-ssh-config.ps1', 'repair-smal-ssh-firewall.ps1', 'prepare-smal-host-hyperv.ps1']:
            code = "$t=$null; $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile('" + str(ROOT / 'scripts' / file) + "',[ref]$t,[ref]$e); if($e.Count){$e | ForEach-Object Message; exit 1}"
            subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True)

    def test_guest_authentication_scope(self):
        for required in ['AuthenticationMethods publickey', 'PasswordAuthentication no', 'PubkeyAuthentication yes',
                         'AllowAgentForwarding no', 'AllowTcpForwarding no', 'ListenAddress 10.200.16.4',
                         "-RemoteAddress '10.202.0.0/26'", 'AllowUsers $admin']:
            self.assertIn(required, SETUP)
        for forbidden in ['Enable-PSRemoting', 'Enable-WSManCredSSP', 'TrustedHosts', 'Restart-Computer',
                          'Add-MpPreference', 'Install-Module', 'Format-Volume']:
            self.assertNotIn(forbidden, SETUP)

    def test_existing_work_and_incomplete_operations_preserved(self):
        self.assertIn('Active non-default SSH configuration found', SETUP)
        self.assertIn('SSH configuration changed after read-only reconciliation', SETUP)
        self.assertIn('Copy-Item $config $backup', SETUP)
        self.assertIn('Prior SSH setup differs or is incomplete', SETUP)
        self.assertIn('Service remains stopped', SETUP)
        self.assertIn("$acl.SetAccessRuleProtection($true, $false)", SETUP)
        self.assertIn("@('S-1-5-18', 'S-1-5-32-544')", SETUP)

    def test_only_public_host_key_read(self):
        self.assertIn("Get-Content (Join-Path $dir 'ssh_host_ed25519_key.pub')", SETUP)
        self.assertNotIn("Get-Content (Join-Path $dir 'ssh_host_ed25519_key')", SETUP)

    def test_firewall_mask_and_recovery_are_exact(self):
        self.assertIn("@('10.202.0.0/26', '10.202.0.0/255.255.255.192')", SETUP)
        self.assertIn("$Operation -eq 'ResumeVerified'", SETUP)
        self.assertIn('Expected fail-closed service differs', SETUP)
        self.assertIn('Pending SSH configuration changed', SETUP)
        self.assertNotIn('Remove-Item $marker', SETUP)

    def test_ssh_arguments_are_strict_and_do_not_use_passwords(self):
        args = TRANSPORT['ssh_args'](12345, 'labadmin', 'encoded-script')
        for value in ['StrictHostKeyChecking=yes', 'IdentitiesOnly=yes', 'IdentityAgent=none', 'BatchMode=yes',
                      'PasswordAuthentication=no', 'GlobalKnownHostsFile=/dev/null', 'ClearAllForwardings=yes']:
            self.assertIn(value, args)
        self.assertNotIn('StrictHostKeyChecking=no', args)
        self.assertIn('labadmin@127.0.0.1', args)

    def test_host_key_change_is_rejected(self):
        function = H['pin_host_key']
        scope = function.__globals__
        original = scope['KNOWN']
        with tempfile.TemporaryDirectory(dir='/tmp/opencode') as temporary:
            scope['KNOWN'] = Path(temporary) / 'known_hosts'
            try:
                function('ssh-ed25519 AAAATEST comment')
                function('ssh-ed25519 AAAATEST other-comment')
                with self.assertRaises(RuntimeError):
                    function('ssh-ed25519 AAAACHANGED comment')
            finally:
                scope['KNOWN'] = original

    def test_hyperv_stage_is_minimal_and_never_reboots(self):
        source = (ROOT / 'scripts/prepare-smal-host-hyperv.ps1').read_text()
        self.assertIn('Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart:$false', source)
        self.assertIn('Prior Hyper-V operation exists. Inspect rather than repeat.', source)
        for forbidden in ['Restart-Computer', 'New-VMSwitch', 'New-NetNat', 'Format-Volume',
                          'Initialize-Disk', 'Install-Module', 'Add-MpPreference', 'Enable-WSManCredSSP']:
            self.assertNotIn(forbidden, source)


if __name__ == '__main__':
    unittest.main()
