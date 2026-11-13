# Exact attached-file metadata only. No credentials, file data, enumeration or effects.
# Microsoft Learn: FILE_STANDARD_INFO, FILE_ID_INFO, FILE_COMPRESSION_INFO,
# GetFileInformationByHandleEx and GetFinalPathNameByHandleW.
# https://learn.microsoft.com/windows/win32/api/winbase/ns-winbase-file_standard_info
# https://learn.microsoft.com/windows/win32/api/winbase/ns-winbase-file_id_info
# https://learn.microsoft.com/windows/win32/api/winbase/ns-winbase-file_compression_info
$ErrorActionPreference='Stop';$phase='preimage';$rows=@();$script:configurationMismatch=$null
$baselineSha256='435a0ee69c0388fbdb955db33ee6b12627eadd28afda7d685e133cd7b3960507'
$deadline=[DateTimeOffset]::Parse('2026-11-10T15:00:00+02:00')
$sealedSha256='587e5120ffb6242c2958567c72cb627bde45a93f6b35bb3e0fb5a7171b32f793'
$sealedGzip=@(
'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'
) -join ''
function Check-Window {if([DateTimeOffset]::UtcNow -ge $deadline){throw 'Fixed metadata read window closed'}}
function Guard-Value($Value) {
    if($null -eq $Value){return @{type='null';status='null';value=$null}}
    $result=@{type=$Value.GetType().FullName;status='type-only'}
    if($Value -is [array]){$result.count=$Value.Count;return $result}
    if($Value -is [Collections.IDictionary]){$result.count=$Value.Count;return $result}
    if($Value -is [bool] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or $Value -is [decimal] -or $Value -is [double] -or $Value -is [single]){$result.status='management-scalar';$result.value=$Value;return $result}
    if($Value -is [string] -or $Value -is [guid] -or $Value -is [version] -or $Value -is [enum]){
        $text=[string]$Value
        if($text.Length -le 512 -and $text -notmatch '-----BEGIN|\beyJ[A-Za-z0-9_-]{15,}\.|\b(?:ssh-rsa|ssh-ed25519|ecdsa-sha2-[A-Za-z0-9-]+)\s|[\r\n]|://|(?i:password|credential|secret|token|keyprotector)'){$result.status='management-scalar';$result.value=$text}else{$result.status='withheld'}
    }
    $result
}
function Fail-Field([string]$Path,[string]$Reason,$Actual,$Expected) {
    $script:configurationMismatch=@{fieldPath=$Path;reason=$Reason;actual=(Guard-Value $Actual);expected=(Guard-Value $Expected)}
    throw 'Sealed configuration differs; bounded field diagnostic retained'
}
function Assert-Fields($Actual,$Expected,[string]$Path='configuration') {
    if($null -eq $Expected){if($null -ne $Actual){Fail-Field $Path 'expected-null' $Actual $Expected};return}
    if($Expected -is [array]){
        if($Actual -isnot [array] -or $Actual.Count -ne $Expected.Count){Fail-Field $Path 'array-type-or-count-mismatch' $Actual $Expected}
        for($i=0;$i -lt $Expected.Count;$i++){Assert-Fields $Actual[$i] $Expected[$i] ($Path+'['+$i+']')};return
    }
    if($Expected -is [pscustomobject]){
        if($Actual -isnot [Collections.IDictionary]){Fail-Field $Path 'object-type-mismatch' $Actual $Expected}
        foreach($p in $Expected.PSObject.Properties){$field=$Path+'.'+$p.Name;if(-not $Actual.ContainsKey($p.Name)){Fail-Field $field 'missing-field' $null $p.Value};Assert-Fields $Actual[$p.Name] $p.Value $field};return
    }
    if([string]$Actual -cne [string]$Expected){Fail-Field $Path 'scalar-value-mismatch' $Actual $Expected}
}
function Assert-Guests {
    foreach($g in $sealed.guests){
        Check-Window
        $vm=Get-VM -Id $g.id -ErrorAction Stop
        Assert-Fields $vm.Name $g.name ('guests.'+$g.name+'.name')
        Assert-Fields ([string]$vm.State) 'Running' ('guests.'+$g.name+'.state')
        $m=Get-VMMemory -VM $vm;$p=Get-VMProcessor -VM $vm
        $a=@{name=$vm.Name;id=$vm.Id.ToString();cpu=$vm.ProcessorCount;memory=$vm.MemoryStartup;dynamicMemory=$m.DynamicMemoryEnabled;
            generation=$vm.Generation;version=$vm.Version.ToString();path=$vm.Path;configurationLocation=$vm.ConfigurationLocation;snapshotLocation=$vm.SnapshotFileLocation;
            smartPagingLocation=$vm.SmartPagingFilePath;checkpointType=$vm.CheckpointType.ToString();automaticStart=$vm.AutomaticStartAction.ToString();automaticStop=$vm.AutomaticStopAction.ToString();
            secureBoot=(Get-VMFirmware -VM $vm).SecureBoot.ToString();tpm=(Get-VMSecurity -VM $vm).TpmEnabled;
            memorySettings=@{minimum=$m.Minimum;maximum=$m.Maximum;buffer=$m.Buffer;priority=$m.Priority;maximumNumaMemory=$m.MaximumPerNumaNode};
            processorSettings=@{nested=$p.ExposeVirtualizationExtensions;reserve=$p.Reserve;maximum=$p.Maximum;weight=$p.RelativeWeight;
                compatibilityMigration=$p.CompatibilityForMigrationEnabled;compatibilityOlderOs=$p.CompatibilityForOlderOperatingSystemsEnabled;
                maximumNumaProcessors=$p.MaximumCountPerNumaNode;maximumNumaSockets=$p.MaximumCountPerNumaSocket;hardwareThreadsPerCore=$p.HwThreadCountPerCore};
            disks=@(Get-VMHardDiskDrive -VM $vm|Sort-Object ControllerNumber,ControllerLocation|ForEach-Object {
                @{path=$_.Path;controllerType=$_.ControllerType.ToString();controllerNumber=$_.ControllerNumber;controllerLocation=$_.ControllerLocation}});
            nics=@(Get-VMNetworkAdapter -VM $vm|Sort-Object Name|ForEach-Object {
                $vlan=$_|Get-VMNetworkAdapterVlan
                @{name=$_.Name;id=$_.Id;switchId=$_.SwitchId.ToString();mac=$_.MacAddress;dynamicMac=$_.DynamicMacAddressEnabled;
                  spoofing=$_.MacAddressSpoofing.ToString();teaming=$_.AllowTeaming.ToString();vlan=@{mode=$vlan.OperationMode.ToString();native=$vlan.NativeVlanId;allowed=@($vlan.AllowedVlanIdList)}}})}
        Assert-Fields $a $g ('guests.'+$g.name)
    }
}
function Read-Volumes {
    @(foreach($pin in $sealed.volumes){
        Check-Window
        $v=Get-Volume -DriveLetter $pin.letter -ErrorAction Stop
        if(@($v).Count -ne 1 -or $v.UniqueId -ine $pin.uniqueId -or $v.Size -ne $pin.size -or [string]$v.FileSystem -ine 'NTFS' -or [string]$v.HealthStatus -cne 'Healthy'){throw 'Sealed NTFS volume differs'}
        @{letter=$pin.letter;uniqueId=$v.UniqueId;sizeBytes=[long]$v.Size;freeBytes=[long]$v.SizeRemaining;usedBytes=([long]$v.Size-[long]$v.SizeRemaining);atUtc=[DateTime]::UtcNow.ToString('o')}
    })
}
$nativeSource=@'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class SmalVhdMetadata {
    public const uint ReadAttributes=0x80, ShareAll=7, OpenExisting=3, OpenReparse=0x00200000, BackupSemantics=0x02000000;
    [StructLayout(LayoutKind.Sequential)] public struct StandardInfo {
        public long AllocationSize, EndOfFile; public uint NumberOfLinks; public byte DeletePending, Directory;
    }
    [StructLayout(LayoutKind.Sequential)] public struct IdInfo {
        public ulong VolumeSerialNumber; [MarshalAs(UnmanagedType.ByValArray,SizeConst=16)] public byte[] FileId;
    }
    [StructLayout(LayoutKind.Sequential)] public struct AttributeInfo { public uint Attributes, ReparseTag; }
    [StructLayout(LayoutKind.Sequential)] public struct CompressionInfo {
        public long CompressedFileSize; public ushort CompressionFormat; public byte CompressionUnitShift, ChunkShift, ClusterShift;
        [MarshalAs(UnmanagedType.ByValArray,SizeConst=3)] public byte[] Reserved;
    }
    public sealed class Sample {
        public string Identity, VolumeSerial, FileId, FinalVolumePath, AllocationSource, AtUtc;
        public long LogicalLengthBytes, StandardAllocationBytes; public long? AllocatedBytes;
        public uint HardLinkCount, Attributes; public int AllocationErrorCode;
    }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
    [DllImport("kernel32.dll",EntryPoint="GetFileInformationByHandleEx",ExactSpelling=true,SetLastError=true)]
    static extern bool Standard(SafeFileHandle h,int cls,out StandardInfo info,uint size);
    [DllImport("kernel32.dll",EntryPoint="GetFileInformationByHandleEx",ExactSpelling=true,SetLastError=true)]
    static extern bool Identity(SafeFileHandle h,int cls,out IdInfo info,uint size);
    [DllImport("kernel32.dll",EntryPoint="GetFileInformationByHandleEx",ExactSpelling=true,SetLastError=true)]
    static extern bool Attributes(SafeFileHandle h,int cls,out AttributeInfo info,uint size);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle h,StringBuilder name,uint size,uint flags);
    [DllImport("kernel32.dll",EntryPoint="GetFileInformationByHandleEx",ExactSpelling=true,SetLastError=true)]
    static extern bool Compression(SafeFileHandle h,int cls,out CompressionInfo info,uint size);
    static SafeFileHandle Open(string path,bool directory) {
        var h=CreateFileW(path,ReadAttributes,ShareAll,IntPtr.Zero,OpenExisting,OpenReparse|(directory?BackupSemantics:0),IntPtr.Zero);
        if(h.IsInvalid){int error=Marshal.GetLastWin32Error();h.Dispose();throw new Win32Exception(error);}
        try {
            AttributeInfo a;
            if(!Attributes(h,9,out a,(uint)Marshal.SizeOf(typeof(AttributeInfo))))throw new Win32Exception(Marshal.GetLastWin32Error());
            if((a.Attributes&0x400)!=0 || ((a.Attributes&0x10)!=0)!=directory)throw new InvalidOperationException("Reparse/type mismatch");
            return h;
        } catch {h.Dispose();throw;}
    }
    public static Sample Read(string path,string expectedVolume) {
        var parents=new List<SafeFileHandle>();
        try {
            for(var d=Directory.GetParent(path);d!=null;d=d.Parent)parents.Add(Open(d.FullName,true));
            // Share existing read/write/delete use. All allocation and identity
            // queries use this same handle, never a second pathname-based lookup.
            using(var h=Open(path,false)) {
                StandardInfo s;IdInfo id;AttributeInfo a;
                if(!Standard(h,1,out s,(uint)Marshal.SizeOf(typeof(StandardInfo))))throw new Win32Exception(Marshal.GetLastWin32Error());
                if(!Identity(h,18,out id,(uint)Marshal.SizeOf(typeof(IdInfo))))throw new Win32Exception(Marshal.GetLastWin32Error());
                if(!Attributes(h,9,out a,(uint)Marshal.SizeOf(typeof(AttributeInfo))))throw new Win32Exception(Marshal.GetLastWin32Error());
                var name=new StringBuilder(32768);uint n=GetFinalPathNameByHandleW(h,name,(uint)name.Capacity,1);
                if(n==0)throw new Win32Exception(Marshal.GetLastWin32Error());
                if(n>=name.Capacity || !name.ToString().Equals(expectedVolume+path.Substring(3),StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Volume/path differs");
                if(s.Directory!=0 || s.DeletePending!=0 || s.EndOfFile<0 || s.AllocationSize<0 || s.NumberOfLinks==0)throw new InvalidOperationException("Invalid file metadata");
                var result=new Sample {VolumeSerial=id.VolumeSerialNumber.ToString("X16"),FileId=BitConverter.ToString(id.FileId).Replace("-",""),
                    FinalVolumePath=name.ToString(),LogicalLengthBytes=s.EndOfFile,StandardAllocationBytes=s.AllocationSize,HardLinkCount=s.NumberOfLinks,Attributes=a.Attributes,
                    AtUtc=DateTime.UtcNow.ToString("o"),AllocatedBytes=s.AllocationSize,AllocationSource="FileStandardInfo.AllocationSize"};
                result.Identity=result.VolumeSerial+":"+result.FileId;
                if((a.Attributes&(0x200|0x800))!=0) {
                    CompressionInfo compressed;result.AllocationSource="FileCompressionInfo.CompressedFileSize:sparse-or-compressed";
                    if(!Compression(h,8,out compressed,(uint)Marshal.SizeOf(typeof(CompressionInfo)))){result.AllocatedBytes=null;result.AllocationErrorCode=Marshal.GetLastWin32Error();}
                    else if(compressed.CompressedFileSize<0){result.AllocatedBytes=null;result.AllocationErrorCode=13;}
                    else result.AllocatedBytes=compressed.CompressedFileSize;
                }
                return result;
            }
        } finally {for(int i=parents.Count-1;i>=0;i--)parents[i].Dispose();}
    }
}
'@
function Read-FileSample($Pin) {
    try {Check-Window;@{status='read';metadata=[SmalVhdMetadata]::Read($Pin.path,$Pin.volumeId)}}
    catch {
        $e=$_.Exception;$code=$null
        for($i=0;$i -lt 4 -and $null -ne $e;$i++){if($e -is [ComponentModel.Win32Exception]){$code=$e.NativeErrorCode;break};$e=$e.InnerException}
        @{status='metadata-unavailable';allocatedBytes=$null;errorType=$_.Exception.GetType().FullName;win32ErrorCode=$code}
    }
}
function Measure-Allocation($Files,$Before,$After) {
    $unique=@{};$complete=@{};foreach($v in $Before){$complete[$v.letter]=$true}
    foreach($file in $Files){
        $a=$file.before;$b=$file.after
        if($a.status -cne 'read' -or $b.status -cne 'read' -or $a.metadata.Identity -cne $b.metadata.Identity -or $null -eq $a.metadata.AllocatedBytes -or $null -eq $b.metadata.AllocatedBytes){$file.status='allocation-unavailable-or-identity-changed';$complete[$file.volume]=$false;continue}
        $id=$file.volumeId+':'+$a.metadata.Identity;$allocated=[Math]::Min([long]$a.metadata.AllocatedBytes,[long]$b.metadata.AllocatedBytes)
        $file.status='measured';$file.identity=$id;$file.lowerObservedAllocatedBytes=$allocated
        if($unique.ContainsKey($id)){
            if($unique[$id].volume -cne $file.volume){throw 'Cross-volume identity inconsistency'}
            $unique[$id].allocatedBytes=[Math]::Min($unique[$id].allocatedBytes,$allocated);$unique[$id].paths+=@($file.path)
        }else{$unique[$id]=@{identity=$id;volume=$file.volume;volumeId=$file.volumeId;allocatedBytes=$allocated;paths=@($file.path)}}
    }
    $volumes=@(foreach($a in $Before){
        $b=@($After|Where-Object letter -CEQ $a.letter);if($b.Count -ne 1 -or $a.uniqueId -ine $b[0].uniqueId -or $a.sizeBytes -ne $b[0].sizeBytes){throw 'Volume changed during sample'}
        $used=[Math]::Max([long]$a.usedBytes,[long]$b[0].usedBytes);$subtotal=[long]0
        foreach($item in $unique.Values){if($item.volume -ceq $a.letter){$subtotal+=$item.allocatedBytes}}
        $other=$null;$remaining=$null
        if($subtotal -gt $used){$complete[$a.letter]=$false}else{
            $other=$used-$subtotal
            $remaining=[long]$a.sizeBytes-([long]$sealed.maximumByVolume.($a.letter)+$other+[long]$sealed.targetRuntimeByVolume.($a.letter)+[long]$sealed.metadataGrowthBytes+[long]$sealed.freeFloorBytes)
        }
        @{letter=$a.letter;volumeId=$a.uniqueId;before=$a;after=$b[0];physicalUsedUpperBytes=$used;uniqueVhdAllocatedSubtotalBytes=$subtotal;allocationComplete=$complete[$a.letter];
          attachedPathCount=@($Files|Where-Object volume -CEQ $a.letter).Count;uniqueMeasuredFileCount=@($unique.Values|Where-Object volume -CEQ $a.letter).Count;
          otherUsedBytes=$other;maximumAttachedVhdBytes=[long]$sealed.maximumByVolume.($a.letter);targetRuntimeBytes=[long]$sealed.targetRuntimeByVolume.($a.letter);
          metadataGrowthBytes=[long]$sealed.metadataGrowthBytes;freeFloorBytes=[long]$sealed.freeFloorBytes;budgetRemainingBytes=$remaining;
          fitsSampledBudget=($complete[$a.letter] -and $null -ne $remaining -and $remaining -ge 0);executionAdmitted=$false}
    })
    @{volumes=$volumes;uniqueFiles=@($unique.Values);complete=(@($volumes|Where-Object allocationComplete -NE $true).Count -eq 0)}
}
try {
    Check-Window
    if($env:COMPUTERNAME -cne 'LocalBox-Client'){throw 'Exact outer host required'}
    $input=[IO.MemoryStream]::new([Convert]::FromBase64String($sealedGzip));$decoded=[IO.MemoryStream]::new()
    $zip=[IO.Compression.GZipStream]::new($input,[IO.Compression.CompressionMode]::Decompress)
    try{$zip.CopyTo($decoded);$bytes=$decoded.ToArray()}finally{$zip.Dispose();$input.Dispose();$decoded.Dispose()}
    if($bytes.Length -gt 65536){throw 'Sealed metadata bound exceeded'}
    $h=[Security.Cryptography.SHA256]::Create();try{$digest=[BitConverter]::ToString($h.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}
    if($digest -cne $sealedSha256){throw 'Sealed metadata differs'}
    $sealed=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json
    if($sealed.baselineSha256 -cne $baselineSha256 -or $sealed.guests.Count -ne 4 -or $sealed.files.Count -gt 32){throw 'Sealed preimage scope differs'}
    $phase='configuration-before';Assert-Guests
    $phase='volumes-before';$before=Read-Volumes
    $paths=@{}
    foreach($file in $sealed.files){
        $path=[IO.Path]::GetFullPath($file.path)
        if($path -cne $file.path -or $path -notmatch '^[CVWX]:\\' -or $path -match '[*?\[\]]' -or $path.Substring(2).Contains(':') -or $paths.ContainsKey($path)){throw 'Non-exact attached file path'}
        $volume=@($before|Where-Object letter -CEQ $file.volume);if($volume.Count -ne 1){throw 'Attached path volume missing'}
        $paths[$path]=@{path=$path;volume=$file.volume;volumeId=$volume[0].uniqueId;baselineVhdMaximumBytes=$file.baselineVhdMaximumBytes}
    }
    $phase='metadata-api-load';Add-Type -TypeDefinition $nativeSource -ErrorAction Stop
    $phase='attached-file-samples'
    $rows=@(foreach($pin in $paths.Values){Check-Window;@{path=$pin.path;volume=$pin.volume;volumeId=$pin.volumeId;baselineVhdMaximumBytes=$pin.baselineVhdMaximumBytes;before=(Read-FileSample $pin)}})
    foreach($row in $rows){Check-Window;$row.after=Read-FileSample $paths[$row.path]}
    $phase='configuration-after';Assert-Guests
    $phase='volumes-after';$after=Read-Volumes
    $phase='accounting';$accounting=Measure-Allocation $rows $before $after;Check-Window
    @{status=$(if($accounting.complete){'complete'}else{'partial-allocation-unavailable'});baselineSha256=$baselineSha256;sealedMetadataSha256=$sealedSha256;atUtc=[DateTime]::UtcNow.ToString('o');
      configurationMatchedBeforeAndAfter=$true;configurationGuardExcludesKeyProtectorMaterial=$true;requestedAttachedFiles=$sealed.files.Count;maximumUniqueFiles=32;vhdMaximumSource='sealed-baseline-not-file-length';files=$rows;accounting=$accounting;
      arithmetic='otherUsedBytes = max(volume-used-before,volume-used-after) - unique lower-observed allocated bytes';
      sampleLimitations='Two metadata samples, not an atomic filesystem snapshot or reservation. Existing runtime remains in otherUsed and full future runtime is added conservatively.';
      mutationPerformed=$false;fileContentsRead=$false;credentialsRead=$false;executionAdmitted=$false}|ConvertTo-Json -Depth 20 -Compress
} catch {
    @{status='failed-read-only';phase=$phase;baselineSha256=$baselineSha256;configurationMismatch=$script:configurationMismatch;errorType=$_.Exception.GetType().FullName;errorCategory=[string]$_.CategoryInfo.Category;
      sampledFiles=$rows;accountingValid=$false;mutationPerformed=$false;fileContentsRead=$false;credentialsRead=$false;executionAdmitted=$false}|ConvertTo-Json -Depth 12 -Compress
}
