"""Offline guard tests. Hyper-V/DISM application still requires host evidence."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / 'scripts/smal-guest-image-functions.ps1'


class GuestImageTests(unittest.TestCase):
    def test_library_parses_and_only_defines_function(self):
        code = "$t=$null;$e=$null;$a=[System.Management.Automation.Language.Parser]::ParseFile('" + str(LIBRARY) + "',[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object Message;exit 1};if(@($a.EndBlock.Statements).Count -ne 1 -or $a.EndBlock.Statements[0].GetType().Name -ne 'FunctionDefinitionAst'){exit 2}"
        subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)

    def test_unapproved_guest_or_path_stops_before_any_disk_cmdlet(self):
        cases = [('OtherGuest', '/tmp/unapproved.vhdx'), ('LB-DC01', 'C:\\OS.vhdx')]
        for vm, path in cases:
            code = "$ErrorActionPreference='Stop';. '" + str(LIBRARY) + "';function New-VHD {throw 'UNEXPECTED_MUTATION'};try{New-LabGuestOsImage -VmName '" + vm + "' -OsDiskPath '" + path + "' -ImagePath 'D:\\sources\\install.wim' -ImageIndex 1 -UnattendXml '<unattend/>' -Checkpoint {param($phase)}}catch{if($_.Exception.Message -like '*UNEXPECTED_MUTATION*'){exit 2};exit 0};exit 3"
            subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, timeout=30)

    def test_partitions_are_bound_to_new_vhd_and_outer_boot_is_untouched(self):
        source = LIBRARY.read_text()
        self.assertIn('$disks = @($attachment | Get-Disk)', source)
        self.assertIn('$disks[0].IsBoot', source)
        self.assertIn('$disks[0].IsSystem', source)
        self.assertIn('$disks[0].Number -eq 0', source)
        self.assertIn('Initialize-Disk -Number $disk.Number', source)
        self.assertIn('Format-Volume -Partition $efi', source)
        self.assertIn('Format-Volume -Partition $windows', source)
        self.assertIn("/s ($efiLetter + ':') /f UEFI", source)
        self.assertIn('finally { if ($mounted) { Dismount-VHD', source)
        for forbidden in ['Clear-Disk', 'Remove-Partition', 'Remove-Item', 'Set-Partition', 'Invoke-Expression', 'DownloadString']:
            self.assertNotIn(forbidden, source)

    def test_existing_answer_file_is_not_overwritten(self):
        source = LIBRARY.read_text()
        guard = source.index('Image already has an answer file')
        write = source.index('[IO.File]::WriteAllText($answerPath')
        self.assertLess(guard, write)
        self.assertIn('cleanupAndRotationRequired = $true', source)

    def test_returned_boot_system_nonblank_or_wrong_size_disk_is_never_formatted(self):
        variants = [('$true', '$false', 'RAW', '80GB', 9),
                    ('$false', '$true', 'RAW', '80GB', 9),
                    ('$false', '$false', 'GPT', '80GB', 9),
                    ('$false', '$false', 'RAW', '128GB', 9),
                    ('$false', '$false', 'RAW', '80GB', 0)]
        for boot, system, style, size, number in variants:
            code = "$ErrorActionPreference='Stop';. '" + str(LIBRARY) + "';$script:mutated=$false;$script:dismounted=$false;function Test-Path {param($LiteralPath)return $false};function Get-Volume {param($DriveLetter)};function Get-PSDrive {param($Name)};function New-VHD {param($Path,$SizeBytes,[switch]$Dynamic)[pscustomobject]@{VhdFormat='VHDX';VhdType='Dynamic';Path=$Path;Size=$SizeBytes}};function Mount-VHD {param($Path,[switch]$NoDriveLetter,[switch]$Passthru)[pscustomobject]@{Path=$Path}};function Get-Disk {process{[pscustomobject]@{IsBoot=" + boot + ';IsSystem=' + system + ";PartitionStyle='" + style + "';Size=" + size + ';Number=' + str(number) + "}}};function Initialize-Disk {$script:mutated=$true;throw 'UNEXPECTED_MUTATION'};function Format-Volume {$script:mutated=$true;throw 'UNEXPECTED_MUTATION'};function Dismount-VHD {param($Path)$script:dismounted=$true};$xml='<unattend xmlns=\"urn:schemas-microsoft-com:unattend\"><!-- AzureLocalBox local-guests-20261028-01 --><ComputerName>LB-DC01</ComputerName></unattend>';try{New-LabGuestOsImage -VmName 'LB-DC01' -OsDiskPath 'V:\\AzureLocalBox\\Guests\\local-guests-20261028-01\\LB-DC01\\OS.vhdx' -ImagePath 'D:\\sources\\install.wim' -ImageIndex 1 -UnattendXml $xml -Checkpoint {param($phase)}}catch{if($_.Exception.Message -notlike '*exact new blank non-boot disk*' -or $script:mutated -or -not $script:dismounted){exit 2};exit 0};exit 3"
            result = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
