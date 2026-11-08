"""Derive NODE3-only helpers from the reviewed local bootstrap libraries. No execution."""
from pathlib import Path
import hashlib

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'scripts/node03'


def replace_once(text, old, new):
    if text.count(old) != 1: raise RuntimeError('Pinned helper replacement boundary differs')
    return text.replace(old, new)


def build():
    secret = (ROOT / 'scripts/smal-guest-secret-functions.ps1').read_text()
    secret = replace_once(secret, "$ComputerName -notin @('LB-DC01', 'LB-NODE01', 'LB-NODE02')", "$ComputerName -cne 'LB-NODE03'")
    secret = secret.replace('AzureLocalBox local-guests-20261028-01', 'AzureLocalBox node03-20261029-01')
    image = (ROOT / 'scripts/smal-guest-image-functions.ps1').read_text()
    image = replace_once(image, "$sizes = @{ 'LB-DC01' = 80GB; 'LB-NODE01' = 128GB; 'LB-NODE02' = 128GB }", "$sizes = @{ 'LB-NODE03' = 128GB }")
    image = image.replace('V:\\AzureLocalBox\\Guests\\local-guests-20261028-01\\', 'W:\\AzureLocalBox\\Guests\\three-node-20261029-01\\').replace('AzureLocalBox local-guests-20261028-01', 'AzureLocalBox node03-20261029-01')
    vm = (ROOT / 'scripts/smal-guest-vm-functions.ps1').read_text()
    start = vm.index('    $profiles = @{'); end = vm.index("    if (-not $profiles.ContainsKey", start)
    vm = vm[:start] + "    $profiles = @{ 'LB-NODE03' = @{ memory = 64GB; processors = 8; nested = $true } }\n" + vm[end:]
    vm = vm.replace('V:\\AzureLocalBox\\Guests\\local-guests-20261028-01\\', 'W:\\AzureLocalBox\\Guests\\three-node-20261029-01\\')
    direct = (ROOT / 'scripts/smal-guest-direct-functions.ps1').read_text()
    # Omit the forest-creation function altogether. Only the already established
    # network, session, cleanup and observation routines are needed for NODE3.
    direct = direct[:direct.index('function Install-LabDomainForest')] + direct[direct.index('function Complete-LabGuestBootstrapSecret'):]
    direct = direct.replace("@('LB-DC01', 'LB-NODE01', 'LB-NODE02')", "@('LB-NODE03')")
    direct = replace_once(direct, "$addresses = @{ 'LB-DC01' = '10.64.0.10'; 'LB-NODE01' = '10.64.0.11'; 'LB-NODE02' = '10.64.0.12' }", "$addresses = @{ 'LB-NODE03' = '10.64.0.13' }")
    direct = direct.replace('AzureLocalBox local-guests-20261028-01', 'AzureLocalBox node03-20261029-01')
    ad_start = direct.index("            if ($ExpectedName -eq 'LB-DC01') {")
    ad_end = direct.index("            return @{ computer = $env:COMPUTERNAME; ownedAnswerFilesRemoved", ad_start)
    direct = direct[:ad_start] + '            Set-LocalUser -Name Administrator -Password $NewValue\n' + direct[ad_end:]
    return {'node03-secrets.ps1': secret, 'node03-image.ps1': image, 'node03-vm.ps1': vm, 'node03-direct.ps1': direct}


if __name__ == '__main__':
    DEST.mkdir(exist_ok=True)
    for name, text in build().items():
        (DEST / name).write_text(text)
        print(str((DEST / name).relative_to(ROOT)), hashlib.sha256(text.encode()).hexdigest())
