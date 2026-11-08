# Library only. No VM, key protector or data disk is created on import.
function New-LabGuestVm {
    param([string]$VmName, [string]$OsDiskPath, [string]$GuardianName, [scriptblock]$Checkpoint)
    $profiles = @{ 'LB-NODE03' = @{ memory = 64GB; processors = 8; nested = $true } }
    if (-not $profiles.ContainsKey($VmName) -or $GuardianName -cne 'LB-LocalGuardian' -or -not $Checkpoint) { throw 'Unapproved VM profile or guardian' }
    $profile = $profiles[$VmName]
    $directory = 'W:\AzureLocalBox\Guests\three-node-20261029-01\' + $VmName
    if ($OsDiskPath -cne ($directory + '\OS.vhdx') -or -not (Test-Path -LiteralPath $OsDiskPath) -or (Get-VM -Name $VmName -ErrorAction SilentlyContinue)) { throw 'VM identity conflict or missing owned image' }
    $vhd = Get-VHD -Path $OsDiskPath
    $expectedSize = if ($profile.nested) { 128GB } else { 80GB }
    if ($vhd.Attached -or $vhd.Size -ne $expectedSize -or $vhd.VhdFormat.ToString() -ne 'VHDX' -or $vhd.VhdType.ToString() -ne 'Dynamic') { throw 'Owned OS VHD differs' }
    $networkState = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\local-network-20261028-01\state.json' -Raw | ConvertFrom-Json
    $switch = Get-VMSwitch -Name 'LB-Fabric'
    if ($networkState.status -ne 'local-network-created' -or $switch.SwitchType.ToString() -ne 'Internal' -or $switch.Id.ToString() -cne $networkState.switchId) { throw 'Approved internal network identity differs' }
    $guardian = Get-HgsGuardian -Name $GuardianName
    & $Checkpoint ($VmName + '-create-generation2-vm')
    $vm = New-VM -Name $VmName -MemoryStartupBytes $profile.memory -VHDPath $OsDiskPath -Generation 2 -BootDevice VHD -Path $directory
    # From here all changes are bound to this newly returned VM, never a VM wildcard.
    Set-VM -VM $vm -CheckpointType Disabled -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
    Set-VMMemory -VM $vm -DynamicMemoryEnabled $false
    Set-VMProcessor -VM $vm -Count $profile.processors -ExposeVirtualizationExtensions $profile.nested
    Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
    & $Checkpoint ($VmName + '-configure-vtpm')
    $protector = New-HgsKeyProtector -Owner $guardian -AllowUntrustedRoot
    Set-VMKeyProtector -VM $vm -KeyProtector $protector.RawData
    Enable-VMTPM -VM $vm
    & $Checkpoint ($VmName + '-configure-owned-vnics')
    $defaultAdapters = @(Get-VMNetworkAdapter -VM $vm)
    if ($defaultAdapters.Count -ne 1 -or $defaultAdapters[0].SwitchName) { throw 'New VM default adapter differs' }
    Rename-VMNetworkAdapter -VMNetworkAdapter $defaultAdapters[0] -NewName 'MGMT1'
    Connect-VMNetworkAdapter -VMName $VmName -Name MGMT1 -SwitchName 'LB-Fabric'
    if ($profile.nested) {
        foreach ($name in @('MGMT2', 'STORAGEA', 'STORAGEB')) { Add-VMNetworkAdapter -VM $vm -Name $name -SwitchName 'LB-Fabric' }
        foreach ($adapter in @(Get-VMNetworkAdapter -VM $vm)) {
            Set-VMNetworkAdapter -VMNetworkAdapter $adapter -MacAddressSpoofing On -AllowTeaming On
            Set-VMNetworkAdapterVlan -VMNetworkAdapter $adapter -Trunk -NativeVlanId 0 -AllowedVlanIdList '0,711-712'
        }
        # Disable only the named time-synchronisation service by its stable ID.
        $timeService = @(Get-VMIntegrationService -VM $vm | Where-Object { $_.Id.ToString().EndsWith('2497f4de-e9fa-4204-80e4-4b75c46419c0', [StringComparison]::OrdinalIgnoreCase) })
        if ($timeService.Count -ne 1) { throw 'Time synchronisation integration identity differs' }
        $timeService[0] | Disable-VMIntegrationService
        foreach ($index in 1..4) {
            $path = Join-Path $directory ('S2D-' + $index + '.vhdx')
            if (Test-Path -LiteralPath $path) { throw 'Data image already exists. Never overwrite.' }
            & $Checkpoint ($VmName + '-create-data-vhd-' + $index)
            $data = New-VHD -Path $path -Dynamic -SizeBytes 170GB
            if ($data.Path -ine $path -or $data.Size -ne 170GB) { throw 'New data VHD identity differs' }
            Add-VMHardDiskDrive -VM $vm -Path $path
        }
    } else { Set-VMNetworkAdapterVlan -VMName $VmName -VMNetworkAdapterName MGMT1 -Untagged }
    $actual = Get-VM -Id $vm.Id
    $security = Get-VMSecurity -VM $actual
    $firmware = Get-VMFirmware -VM $actual
    $adapters = @(Get-VMNetworkAdapter -VM $actual)
    $expectedAdapterCount = if ($profile.nested) { 4 } else { 1 }
    $expectedDiskCount = if ($profile.nested) { 5 } else { 1 }
    if ($actual.Generation -ne 2 -or $actual.MemoryStartup -ne $profile.memory -or $actual.ProcessorCount -ne $profile.processors -or $actual.State.ToString() -ne 'Off' -or -not $security.TpmEnabled -or $firmware.SecureBoot.ToString() -ne 'On' -or $adapters.Count -ne $expectedAdapterCount -or @(Get-VMHardDiskDrive -VM $actual).Count -ne $expectedDiskCount) { throw 'Final VM shape/security differs. Do not boot.' }
    return @{ vmName = $VmName; vmId = $actual.Id.ToString(); memoryBytes = $actual.MemoryStartup; processors = $actual.ProcessorCount; adapters = @($adapters | Select-Object Name, Id, MacAddress, SwitchId); state = 'Off'; secureBoot = $true; vTpm = $true; bootstrapCleanupAndRotationRequired = $true }
}
