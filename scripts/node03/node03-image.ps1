# Library only. Caller owns the approved one-shot run, source pins and checkpoints.
# No vendor conversion module, external executable download or host boot rewrite.
function New-LabGuestOsImage {
    param(
        [string]$VmName, [string]$OsDiskPath, [string]$ImagePath,
        [int]$ImageIndex, [string]$UnattendXml, [scriptblock]$Checkpoint
    )
    $sizes = @{ 'LB-NODE03' = 128GB }
    if (-not $sizes.ContainsKey($VmName)) { throw 'Unapproved image guest' }
    $expectedPath = 'W:\AzureLocalBox\Guests\three-node-20261029-01\' + $VmName + '\OS.vhdx'
    if ($OsDiskPath -cne $expectedPath -or (Test-Path -LiteralPath $OsDiskPath) -or $ImageIndex -lt 1 -or -not $Checkpoint) { throw 'Unapproved image path/index or existing disk' }
    if ($ImagePath -notmatch '^[A-Z]:\\sources\\install\.wim$') { throw 'Mounted ISO install.wim required' }
    [xml]$answer = $UnattendXml
    $namespaces = [Xml.XmlNamespaceManager]::new($answer.NameTable)
    $namespaces.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
    if ($answer.SelectSingleNode('//u:ComputerName', $namespaces).InnerText -cne $VmName -or $UnattendXml -notmatch 'AzureLocalBox node03-20261029-01') { throw 'Answer-file ownership differs' }
    $letters = @('W', 'X', 'Y', 'Z' | Where-Object { -not (Get-Volume -DriveLetter $_ -ErrorAction SilentlyContinue) -and -not (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue) })
    if ($letters.Count -lt 2) { throw 'Two unused temporary volume letters required' }
    $efiLetter = $letters[0]; $osLetter = $letters[1]
    $mounted = $false
    try {
        & $Checkpoint ($VmName + '-new-os-vhd')
        $vhd = New-VHD -Path $OsDiskPath -SizeBytes $sizes[$VmName] -Dynamic
        if ($vhd.VhdFormat.ToString() -ne 'VHDX' -or $vhd.VhdType.ToString() -ne 'Dynamic' -or $vhd.Path -ine $OsDiskPath -or $vhd.Size -ne $sizes[$VmName]) { throw 'Created OS VHD identity differs' }
        & $Checkpoint ($VmName + '-mount-new-os-vhd')
        $attachment = Mount-VHD -Path $OsDiskPath -NoDriveLetter -Passthru
        $mounted = $true
        $disks = @($attachment | Get-Disk)
        if ($disks.Count -ne 1 -or $disks[0].IsBoot -or $disks[0].IsSystem -or $disks[0].PartitionStyle.ToString() -ne 'RAW' -or $disks[0].Size -ne $sizes[$VmName] -or $disks[0].Number -eq 0) { throw 'Returned OS image disk is not the exact new blank non-boot disk' }
        $disk = $disks[0]
        # Only the disk returned by this invocation's new VHD attachment is eligible.
        & $Checkpoint ($VmName + '-partition-new-os-vhd')
        $null = Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru
        $efi = New-Partition -DiskNumber $disk.Number -Size 260MB -DriveLetter $efiLetter -GptType '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
        $null = Format-Volume -Partition $efi -FileSystem FAT32 -NewFileSystemLabel 'LB-EFI' -Confirm:$false -Force
        $null = New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}'
        $windows = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $osLetter -GptType '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'
        $null = Format-Volume -Partition $windows -FileSystem NTFS -NewFileSystemLabel $VmName -Confirm:$false -Force
        $applyPath = $osLetter + ':\'
        & $Checkpoint ($VmName + '-expand-windows-image')
        $null = Expand-WindowsImage -ImagePath $ImagePath -Index $ImageIndex -ApplyPath $applyPath -CheckIntegrity -Verify -LogPath (Join-Path (Split-Path $OsDiskPath) 'apply-image.log')
        & $Checkpoint ($VmName + '-write-offline-uefi-boot')
        # /s explicitly targets this new VHD's EFI volume, never the outer boot disk.
        & "$env:SystemRoot\System32\bcdboot.exe" (Join-Path $applyPath 'Windows') /s ($efiLetter + ':') /f UEFI 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Offline UEFI boot creation failed' }
        & $Checkpoint ($VmName + '-write-owned-answer-file')
        $panther = Join-Path $applyPath 'Windows\Panther'
        $answerPath = Join-Path $panther 'Unattend.xml'
        if (Test-Path -LiteralPath $answerPath) { throw 'Image already has an answer file. Inspect, never overwrite.' }
        if (-not (Test-Path -LiteralPath $panther)) { $null = New-Item -Path $panther -ItemType Directory }
        [IO.File]::WriteAllText($answerPath, $UnattendXml, [Text.UTF8Encoding]::new($false))
        & $Checkpoint ($VmName + '-dismount-owned-os-vhd')
        Dismount-VHD -Path $OsDiskPath
        $mounted = $false
        return @{ vmName = $VmName; path = $OsDiskPath; virtualSizeBytes = $vhd.Size; vhdId = $vhd.DiskIdentifier.ToString(); imageIndex = $ImageIndex; temporaryBootstrapSecretPresent = $true; cleanupAndRotationRequired = $true }
    } finally { if ($mounted) { Dismount-VHD -Path $OsDiskPath } }
}
