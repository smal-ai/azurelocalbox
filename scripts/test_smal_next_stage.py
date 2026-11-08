from pathlib import Path
import json
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NextStageTests(unittest.TestCase):
    def test_expansion_parses(self):
        path = ROOT / 'scripts/expand-smal-os-volume.ps1'
        code = "$t=$null; $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e); if($e.Count){$e | ForEach-Object Message; exit 1}"
        subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True)

    def test_only_existing_os_partition_can_expand(self):
        source = (ROOT / 'scripts/expand-smal-os-volume.ps1').read_text()
        self.assertIn("$disk.Size -ne 1TB", source)
        self.assertIn("-not $disk.IsBoot", source)
        self.assertIn('Resize-Partition -DriveLetter C -Size $supported.SizeMax', source)
        self.assertIn('Prior expansion exists. Inspect rather than repeat.', source)
        self.assertIn('$dataBefore -ne $dataAfter', source)
        for forbidden in ['Format-Volume', 'Initialize-Disk', 'Remove-Partition', 'New-Partition',
                          'New-StoragePool', 'New-VM', 'New-VMSwitch', 'Restart-Computer']:
            self.assertNotIn(forbidden, source)

    def test_vendor_module_is_not_treated_as_execution_approval(self):
        audit = json.loads((ROOT / 'docs/deployment-2026-10-27/module-execution-review.json').read_text())
        self.assertEqual(audit['version'], '1.0.8')
        self.assertFalse(audit['installedOrImportedOnNewHost'])
        self.assertTrue(audit['noSecurityWaiverInferred'])
        self.assertEqual(len(audit['findings']), 6)

    def test_image_staging_parses_and_never_executes(self):
        path = ROOT / 'scripts/stage-smal-2610-image.ps1'
        code = "$t=$null; $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile('" + str(path) + "',[ref]$t,[ref]$e); if($e.Count){$e | ForEach-Object Message; exit 1}"
        subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], check=True, capture_output=True, text=True)
        source = path.read_text()
        for forbidden in ['Mount-DiskImage', 'Mount-VHD', 'Start-VM', 'New-VM', 'Invoke-Expression',
                          'Start-Process', 'Install-Module', 'Format-Volume', 'Remove-Item',
                          'ServerCertificateValidationCallback', 'SkipCertificateCheck']:
            self.assertNotIn(forbidden, source)
        self.assertIn('$request.AllowAutoRedirect = $false', source)
        self.assertIn('[IO.FileMode]::CreateNew', source)
        self.assertIn('Previous image operation is incomplete', source)

    def test_iso_pin_matches_catalogue_not_filename_guess(self):
        out = ROOT / 'docs/deployment-2026-10-27'
        pin = json.loads((out / 'current-os-image-2610-pin.json').read_text())
        catalogue = json.loads((out / 'current-os-image-catalogue-hci.json').read_text())
        image, = [x for x in catalogue['images'] if x['validatedSolutionRecipeVersion'] == pin['solutionVersion']]
        self.assertEqual(image['composedImageIsoHash'], pin['publisherSha256'])
        self.assertEqual(image['publicDownloadUrl'], pin['url'])
        source = (ROOT / 'scripts/stage-smal-2610-image.ps1').read_text()
        for value in [pin['publisherSha256'], pin['url'], str(pin['contentLength']), pin['etag']]:
            self.assertIn(value, source)


if __name__ == '__main__':
    unittest.main()
