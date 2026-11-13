param(
    [ValidateSet('Inspect', 'InspectMoc', 'InspectAks', 'InspectAksNode', 'InspectAccess', 'InspectPerformance', 'InspectBridge', 'StopNodeInspection', 'RepairMoc', 'InspectAksRecovery')][string]$Action = 'Inspect',
    [Parameter(Mandatory = $true)][string]$ConfigurationBase64,
    [string]$DiagnosticEndpointsBase64 = 'W10=',
    [string]$AksVmId,
    [string]$AksVmIp,
    [string]$AksApiIp,
    [string]$AksClusterName,
    [string]$SshPrivateKeyBase64,
    [string]$BridgeKubeconfigBase64,
    [string]$RecoveryPlanBase64,
    [ValidateSet('Basic', 'Bootstrap', 'Performance', 'ControlPlane', 'Kubernetes', 'Console')][string]$NodeInspection = 'Basic',
    [int]$ExpectedSshProcessId,
    [string]$ExpectedSshStartedAt
)
$ErrorActionPreference = 'Stop'
$config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ConfigurationBase64)) | ConvertFrom-Json
if ($env:COMPUTERNAME -cne $config.hostName) { throw 'Wrong outer host' }
$nodes = @($config.guestIds.PSObject.Properties.Name | Where-Object { $_ -like 'LB-NODE*' } | Sort-Object)
$mutex = [Threading.Mutex]::new($false, 'Global\AzureLocalBoxComputeCapacityR2')
$held = $false

function Open-NodeSession([string]$name) {
    $vm = Get-VM -Id $config.guestIds.PSObject.Properties[$name].Value
    if ($vm.Name -cne $name -or $vm.State.ToString() -cne 'Running') { throw 'Expected existing running HCI guest' }
    $bundle = Get-Content (Join-Path $config.guestHelperDirectory 'bundle.json') -Raw | ConvertFrom-Json
    $entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1')
    $helper = Join-Path $config.guestHelperDirectory 'smal-guest-secret-functions.ps1'
    if ($entry.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $entry[0].sha256) { throw 'Protected guest helper differs' }
    . $helper
    $store = Join-Path $config.credentialDirectory 'secrets'
    $bindings = Get-Content (Join-Path $config.credentialDirectory 'credential-bindings.json') -Raw | ConvertFrom-Json
    $binding = $bindings.nodes.PSObject.Properties[$name].Value
    if ($binding.vmId -ine $vm.Id.ToString() -or $binding.role -cne 'cluster-node-admin' -or $binding.secretDirectory -cne $store -or $binding.loginVerified -ne $true) {
        throw 'Existing guest credential binding differs'
    }
    $secure = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'
    try { New-PSSession -VMId $vm.Id -Credential ([pscredential]::new(($name + '\ASBuiltInAdmin'), $secure)) }
    finally { $secure.Dispose() }
}

function Read-Membership($session) {
    $value = Invoke-Command -Session $session -ArgumentList $config.mocLocation -ScriptBlock {
        param($location)
        Import-Module Moc -ErrorAction Stop
        $rows = Get-MocNode -location $location -timeoutSeconds 30
        function Read-Names($value) {
            if ($value -is [Collections.IList]) {
                foreach ($item in $value) { Read-Names $item }
            } else {
                if (-not $value.name -or $value.location -cne $location) { throw 'Incomplete MOC node identity' }
                $value.name.ToUpperInvariant()
            }
        }
        @{ members = @(Read-Names $rows | Sort-Object -Unique) }
    }
    @($value.members)
}

function Save-Operation([string]$path, $value) {
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, ($value | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    if (Test-Path $path) { [IO.File]::Replace($temporary, $path, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $path) }
}

try {
    if ($Action -ceq 'InspectBridge') {
        if ($AksClusterName -notmatch '^[a-z][a-z0-9-]{2,62}$') { throw 'Exact AKS cluster name required' }
        $binary = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) $config.bridgeKubectlRelativePath
        if ((Get-FileHash $binary).Hash.ToLowerInvariant() -cne $config.bridgeKubectlSha256) { throw 'Existing bridge kubectl binary differs' }
        $directory = 'C:\ProgramData\AzureLocalBox\Operations\bridge'
        if (-not (Test-Path $directory)) {
            $null = New-Item $directory -ItemType Directory
            Set-Acl $directory (Get-Acl $config.credentialDirectory)
        }
        $kubeconfig = Join-Path $directory ([guid]::NewGuid().ToString('N') + '.kubeconfig')
        try {
            [IO.File]::WriteAllBytes($kubeconfig, [Convert]::FromBase64String($BridgeKubeconfigBase64))
            function Read-Bridge([string]$arguments) {
                $info = [Diagnostics.ProcessStartInfo]::new()
                $info.FileName = $binary
                $info.Arguments = '--kubeconfig "' + $kubeconfig + '" --request-timeout=20s ' + $arguments
                $info.UseShellExecute = $false
                $info.CreateNoWindow = $true
                $info.RedirectStandardOutput = $true
                $info.RedirectStandardError = $true
                $process = [Diagnostics.Process]::new()
                $process.StartInfo = $info
                try {
                    $null = $process.Start()
                    $stdout = $process.StandardOutput.ReadToEndAsync()
                    $stderr = $process.StandardError.ReadToEndAsync()
                    if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Bridge read timed out' }
                    $text = $stdout.GetAwaiter().GetResult()
                    if ($process.ExitCode -ne 0) { throw ('Bridge read failed: ' + $stderr.GetAwaiter().GetResult()) }
                    $text | ConvertFrom-Json
                } finally { $process.Dispose() }
            }
            $selected = Read-Bridge 'config view --minify --output=json'
            if ($selected.clusters.Count -ne 1 -or $selected.clusters[0].cluster.server -cne 'https://10.64.0.21:6443' -or
                $selected.clusters[0].cluster.'insecure-skip-tls-verify' -or -not $selected.clusters[0].cluster.'certificate-authority-data') {
                throw 'Expected the existing trusted private resource-bridge API'
            }
            $results = @{}
            foreach ($kind in @('machines', 'machinedeployments', 'clusters')) {
                $list = Read-Bridge ('get --raw=/apis/cluster.x-k8s.io/v1beta1/namespaces/default/' + $kind)
                $results[$kind] = @($list.items | Where-Object { $_.metadata.name.StartsWith($AksClusterName + '-') } | ForEach-Object {
                    @{ name = $_.metadata.name; namespace = $_.metadata.namespace; createdAt = $_.metadata.creationTimestamp; status = $_.status;
                       infrastructureRef = $_.spec.infrastructureRef; bootstrapRef = $_.spec.bootstrap.configRef }
                })
            }
            @{ action = $Action; resources = $results; observedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 20 -Compress
        } finally { if (Test-Path $kubeconfig) { Remove-Item $kubeconfig -Force } }
        return
    }
    if ($Action -ceq 'StopNodeInspection') {
        $process = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $ExpectedSshProcessId)
        if (-not $process -or $process.Name -cne 'ssh.exe' -or
            $process.CreationDate.ToUniversalTime().ToString('o') -cne $ExpectedSshStartedAt -or
            $process.CommandLine -notmatch 'HostKeyAlias=aks-node-' -or
            $process.CommandLine -notmatch '(C:\\ProgramData\\AzureLocalBox\\Operations\\aks-node-[a-f0-9-]+\\[a-f0-9]{32}\.key)') {
            throw 'Original diagnostic SSH process identity differs'
        }
        $key = $Matches[1]
        $parent = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $process.ParentProcessId)
        if (-not $parent -or $parent.Name -cne 'powershell.exe') { throw 'Original diagnostic parent differs' }
        Stop-Process -Id $parent.ProcessId -Force
        if (Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue) { Stop-Process -Id $process.ProcessId -Force }
        if (Test-Path $key) { Remove-Item $key -Force }
        @{ action = $Action; stoppedSshProcessId = $process.ProcessId; stoppedParentId = $parent.ProcessId;
           protectedKeyRemoved = -not (Test-Path $key); observedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress
        return
    }
    if ($Action -ceq 'InspectAccess') {
        $processes = @(Get-CimInstance Win32_Process -Filter "Name='ssh.exe' OR Name='powershell.exe'" | ForEach-Object {
            @{ name = $_.Name; id = $_.ProcessId; parentId = $_.ParentProcessId; createdAt = $_.CreationDate.ToUniversalTime().ToString('o') }
        })
        $files = @(Get-ChildItem 'C:\ProgramData\AzureLocalBox\Operations' -Directory -Filter 'aks-node-*' -ErrorAction SilentlyContinue |
            Get-ChildItem -File | ForEach-Object { @{ path = $_.FullName; sizeBytes = $_.Length; modifiedAt = $_.LastWriteTimeUtc.ToString('o') } })
        $connections = @(Get-NetTCPConnection -RemotePort 22 -ErrorAction SilentlyContinue | ForEach-Object {
            @{ localAddress = $_.LocalAddress; remoteAddress = $_.RemoteAddress; state = $_.State.ToString(); processId = $_.OwningProcess }
        })
        @{ action = $Action; processes = $processes; nodeAccessFiles = $files; sshConnections = $connections;
           observedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 10 -Compress
        return
    }
    if ($Action -ceq 'RepairMoc') {
        try { $held = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Another platform operation is currently running' }
    }
    $guests = @(foreach ($property in $config.guestIds.PSObject.Properties) {
        $vm = Get-VM -Id $property.Value
        if ($vm.Name -cne $property.Name) { throw 'Guest identity differs' }
        @{ name = $vm.Name; id = $vm.Id.ToString(); state = $vm.State.ToString(); cpu = $vm.ProcessorCount;
           memoryBytes = $vm.MemoryStartup; assignedMemoryBytes = $vm.MemoryAssigned; heartbeat = $vm.Heartbeat.ToString() }
    })
    $peer = Open-NodeSession $nodes[0]
    try {
        if ($Action -ceq 'InspectAksRecovery') {
            $rawPlan = [Convert]::FromBase64String($RecoveryPlanBase64)
            $plan = [Text.Encoding]::UTF8.GetString($rawPlan) | ConvertFrom-Json
            if ($plan.hciNode -cnotin $nodes -or $plan.operationId -notmatch '^aks-os-recovery-[a-f0-9]{32}$') { throw 'Exact recovery operation/node required' }
            $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($rawPlan)).Replace('-', '').ToLowerInvariant()
            $session = Open-NodeSession $plan.hciNode
            try {
                $recovery = Invoke-Command -Session $session -ArgumentList $RecoveryPlanBase64, $hash, $config.clusterName -ScriptBlock {
                    param($encodedPlan, $planHash, $clusterName)
                    $ErrorActionPreference = 'Stop'
                    $p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedPlan)) | ConvertFrom-Json
                    if ($p.hciNode -cne $env:COMPUTERNAME -or (Get-Cluster).Name -ine $clusterName -or
                        $p.operationId -notmatch '^aks-os-recovery-[a-f0-9]{32}$') { throw 'Wrong recovery host/operation' }
                    $root = Join-Path 'C:\ClusterStorage\UserStorage_1\SMAL-Recovery' $p.operationId
                    $statePath = Join-Path $root 'operation.json'
                    $copyPath = Join-Path $root 'original-os.vhdx'
                    $state = if (Test-Path $statePath) { Get-Content $statePath -Raw | ConvertFrom-Json } else { $null }
                    if ($state -and $state.planSha256 -cne $planHash) { throw 'Original recovery plan cannot be replaced' }
                    $currentVm = Get-VM -Id ([guid]$p.vmId) -ErrorAction SilentlyContinue
                    return @{ vmId = $p.vmId; registeredHere = [bool]$currentVm;
                              vmState = $(if ($currentVm) { $currentVm.State.ToString() } else { 'NotRegistered' });
                              operation = $state; directory = $root; originalDiskExists = Test-Path $p.osDiskPath;
                              clusterGroups = @(Get-ClusterGroup -VMId ([guid]$p.vmId) -ErrorAction SilentlyContinue | ForEach-Object {
                                  @{ name = $_.Name; state = $_.State.ToString(); owner = $_.OwnerNode.Name }
                              }); originalCopyExists = Test-Path $copyPath; observedAt = [datetime]::UtcNow.ToString('o') }
                }
                @{ action = $Action; result = $recovery; observedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 15 -Compress
            } finally { Remove-PSSession $session }
            return
        }
        if ($Action -ceq 'InspectPerformance') {
            $samples = @(foreach ($node in $nodes) {
                $session = Open-NodeSession $node
                try {
                    Invoke-Command -Session $session -ScriptBlock {
                        $processors = @(Get-CimInstance Win32_Processor -OperationTimeoutSec 10 | ForEach-Object {
                            @{ logicalProcessors = $_.NumberOfLogicalProcessors; loadPercent = $_.LoadPercentage }
                        })
                        @{ node = $env:COMPUTERNAME; processors = $processors;
                           vms = @(Get-VM | ForEach-Object { @{ name = $_.Name; id = $_.Id.ToString(); cpuCount = $_.ProcessorCount;
                               cpuUsagePercent = $_.CPUUsage; state = $_.State.ToString(); uptimeSeconds = $_.Uptime.TotalSeconds;
                               heartbeat = $_.Heartbeat.ToString();
                               integrationServices = @($_ | Get-VMIntegrationService | ForEach-Object {
                                   @{ name = $_.Name; enabled = $_.Enabled; primaryStatus = $_.PrimaryStatusDescription; secondaryStatus = $_.SecondaryStatusDescription }
                               });
                               adapters = @($_ | Get-VMNetworkAdapter | ForEach-Object {
                                   @{ name = $_.Name; status = @($_.Status | ForEach-Object { $_.ToString() }); switch = $_.SwitchName;
                                      connected = $_.Connected; macAddress = $_.MacAddress; ipAddresses = @($_.IPAddresses);
                                      vlan = @($_ | Get-VMNetworkAdapterVlan | ForEach-Object {
                                          @{ mode = $_.OperationMode.ToString(); accessVlanId = $_.AccessVlanId; nativeVlanId = $_.NativeVlanId }
                                      }) }
                               }) } }) }
                    }
                } finally { Remove-PSSession $session }
            })
            @{ action = $Action; nodes = $samples; observedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 15 -Compress
            return
        }
        if ($Action -ceq 'InspectAksNode') {
            if ($AksClusterName -notmatch '^[a-z][a-z0-9-]{2,62}$' -or
                ($NodeInspection -cne 'Console' -and $AksVmIp -notmatch '^10\.64\.0\.\d{1,3}$')) { throw 'Exact nested AKS cluster and node address required' }
            $placements = @(foreach ($node in $nodes) {
                $session = Open-NodeSession $node
                try {
                    Invoke-Command -Session $session -ArgumentList $AksVmId, $AksVmIp, $AksClusterName, ($NodeInspection -cne 'Console') -ScriptBlock {
                        param($id, $address, $clusterName, $networkRequired)
                        $vm = Get-VM -Id ([guid]$id) -ErrorAction SilentlyContinue
                        if (-not $vm) { return }
                        $addresses = @($vm | Get-VMNetworkAdapter | ForEach-Object IPAddresses)
                        if ($vm.State.ToString() -cne 'Running' -or -not $vm.Name.StartsWith($clusterName + '-') -or ($networkRequired -and $address -notin $addresses)) {
                            throw 'Current VM identity/address differs from the requested AKS node'
                        }
                        @{ id = $vm.Id.ToString(); name = $vm.Name; address = $address; hostNode = $env:COMPUTERNAME }
                    }
                } finally { Remove-PSSession $session }
            })
            if ($placements.Count -ne 1) { throw 'Expected the exact AKS VM on one configured HCI node' }
            $identity = $placements[0]
            if ($NodeInspection -ceq 'Console') {
                $session = Open-NodeSession $identity.hostNode
                try {
                    $console = Invoke-Command -Session $session -ArgumentList $identity.id, $identity.name -ScriptBlock {
                        param($id, $name)
                        $vm = Get-VM -Id ([guid]$id)
                        if ($vm.Name -cne $name -or $vm.State.ToString() -cne 'Running') { throw 'Console VM identity/state changed' }
                        $settings = @(Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_VirtualSystemSettingData |
                            Where-Object { $_.VirtualSystemIdentifier -eq $id -and $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' })
                        if ($settings.Count -ne 1) { throw 'Expected one realised VM, never a snapshot' }
                        $firmware = Get-VMFirmware -VM $vm
                        $disks = @($vm | Get-VMHardDiskDrive | ForEach-Object {
                            $drive = $_
                            $vhd = Get-VHD -Path $drive.Path
                            @{ path = $drive.Path; controllerType = $drive.ControllerType.ToString(); controllerNumber = $drive.ControllerNumber;
                               controllerLocation = $drive.ControllerLocation; type = $vhd.VhdType.ToString(); virtualBytes = $vhd.Size;
                               fileBytes = $vhd.FileSize; parentPath = $vhd.ParentPath; diskIdentifier = $vhd.DiskIdentifier.ToString() }
                        })
                        $recoveryVolume = Get-Volume -FilePath 'C:\ClusterStorage\UserStorage_1\'
                        $service = Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_VirtualSystemManagementService
                        # Documented read-only Hyper-V API. Its output is raw RGB 565.
                        # https://learn.microsoft.com/windows/win32/hyperv_v2/getvirtualsystemthumbnailimage-msvm-virtualsystemmanagementservice
                        $image = Invoke-CimMethod -InputObject $service -MethodName GetVirtualSystemThumbnailImage -Arguments @{
                            TargetSystem = $settings[0]; WidthPixels = [uint16]800; HeightPixels = [uint16]600
                        }
                        if ($image.ReturnValue -ne 0 -or $image.ImageData.Length -notin @(960000, 960004)) {
                            throw ('Console capture failed: returnCode=' + $image.ReturnValue + ', bytes=' + $image.ImageData.Length)
                        }
                        # This installed Hyper-V provider can return four additional bytes.
                        # Preserve its complete original buffer in the private receipt.
                        @{ width = 800; height = 600; format = 'RGB565'; nativeByteLength = $image.ImageData.Length;
                           biosGuid = $settings[0].BIOSGUID; disks = $disks;
                           bootOrder = @($firmware.BootOrder | ForEach-Object { @{ type = $_.BootType.ToString(); path = $_.Device.Path; description = $_.Description } });
                           recoveryVolume = @{ path = 'C:\ClusterStorage\UserStorage_1\'; freeBytes = $recoveryVolume.SizeRemaining; health = $recoveryVolume.HealthStatus.ToString() };
                           imageBase64 = [Convert]::ToBase64String($image.ImageData) }
                    }
                    @{ action = $Action; inspection = $NodeInspection; node = $identity; console = $console;
                       observedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 10 -Compress
                } finally { Remove-PSSession $session }
                return
            }
            $directory = Join-Path 'C:\ProgramData\AzureLocalBox\Operations' ('aks-node-' + $identity.id)
            if (-not (Test-Path $directory)) {
                $null = New-Item $directory -ItemType Directory
                Set-Acl $directory (Get-Acl $config.credentialDirectory)
            }
            $key = Join-Path $directory ([guid]::NewGuid().ToString('N') + '.key')
            $known = Join-Path $directory 'known_hosts'
            try {
                [IO.File]::WriteAllBytes($key, [Convert]::FromBase64String($SshPrivateKeyBase64))
                $acl = [Security.AccessControl.FileSecurity]::new()
                $acl.SetAccessRuleProtection($true, $false)
                $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
                $acl.SetOwner($owner)
                foreach ($sid in @($owner, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
                    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
                }
                Set-Acl $key $acl
                $arguments = @('-F', 'NUL', '-T', '-n', '-i', $key, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                    '-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no', '-o', 'ForwardAgent=no',
                    '-o', 'StrictHostKeyChecking=accept-new', '-o', ('UserKnownHostsFile=' + $known),
                    '-o', ('HostKeyAlias=aks-node-' + $identity.id), '-o', 'ConnectTimeout=10',
                    '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2', ('clouduser@' + $AksVmIp))
                $checks = @(
                    @{ name = 'services'; command = 'sudo -n systemctl status containerd kubelet --no-pager --lines=12' },
                    @{ name = 'cloud-init'; command = 'sudo -n cloud-init status --long' },
                    @{ name = 'containers'; command = 'sudo -n crictl ps -a' },
                    @{ name = 'kubelet-journal'; command = 'sudo -n journalctl -u kubelet -n 50 --no-pager' },
                    @{ name = 'network'; command = 'ip route' },
                    @{ name = 'storage'; command = 'df -h /' }
                )
                if ($NodeInspection -ceq 'Bootstrap') {
                    $checks = @(
                        @{ name = 'bootstrap-log'; command = 'sudo -n tail -n 100 /var/log/cloud-init-output.log' },
                        @{ name = 'bootstrap-processes'; command = 'ps -eo pid,ppid,stat,etimes,comm,wchan:25' }
                    )
                }
                if ($NodeInspection -ceq 'Performance') {
                    $checks = @(
                        @{ name = 'pressure'; command = 'cat /proc/pressure/io /proc/pressure/memory /proc/pressure/cpu' },
                        @{ name = 'vmstat'; command = 'vmstat 1 4' },
                        @{ name = 'runtime-state'; command = 'sudo -n systemctl show containerd kubelet --property=Id,ActiveState,SubState,MainPID' },
                        @{ name = 'kubelet-journal'; command = 'sudo -n journalctl -u kubelet -n 35 --no-pager' }
                    )
                }
                if ($NodeInspection -ceq 'ControlPlane') {
                    $checks = @(
                        @{ name = 'vip-containers'; command = 'sudo -n crictl ps -a --name kube-vip -o json' },
                        @{ name = 'api-containers'; command = 'sudo -n crictl ps -a --name kube-apiserver -o json' },
                        @{ name = 'vip-manifest'; command = 'sudo -n cat /etc/kubernetes/manifests/kube-vip.yaml' },
                        @{ name = 'addresses'; command = 'ip -j address show dev eth0' },
                        @{ name = 'listeners'; command = 'sudo -n ss -lntp' },
                        @{ name = 'memory'; command = 'free -m' }
                    )
                }
                if ($NodeInspection -ceq 'Kubernetes') {
                    if ($AksApiIp -notmatch '^10\.64\.0\.\d{1,3}$') { throw 'Exact current AKS API address required' }
                    $kube = 'sudo -n kubectl --kubeconfig=/etc/kubernetes/super-admin.conf --server=https://' + $AksVmIp + ':6443 --tls-server-name=' + $AksApiIp + ' --request-timeout=10s '
                    $checks = @(
                        @{ name = 'api-ready'; command = $kube + 'get --raw=/readyz' },
                        @{ name = 'nodes'; command = $kube + 'get nodes -o json' },
                        @{ name = 'pods'; command = $kube + 'get pods -A -o wide' },
                        @{ name = 'storage-classes'; command = $kube + 'get storageclasses -o json' }
                    )
                }
                $results = @(foreach ($check in $checks) {
                    $command = 'timeout -k 5s 20s ' + $check.command
                    $start = [Diagnostics.ProcessStartInfo]::new()
                    $start.FileName = 'C:\Windows\System32\OpenSSH\ssh.exe'
                    $start.Arguments = ((@($arguments) + @($command)) | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
                    $start.UseShellExecute = $false
                    $start.CreateNoWindow = $true
                    $start.RedirectStandardOutput = $true
                    $start.RedirectStandardError = $true
                    $process = [Diagnostics.Process]::new()
                    $process.StartInfo = $start
                    try {
                        $null = $process.Start()
                        $stdout = $process.StandardOutput.ReadToEndAsync()
                        $stderr = $process.StandardError.ReadToEndAsync()
                        $timedOut = -not $process.WaitForExit(45000)
                        if ($timedOut) {
                            $process.Kill()
                            if (-not $process.WaitForExit(5000)) { throw 'Diagnostic SSH process did not terminate' }
                        }
                        $code = $process.ExitCode
                        if (-not $stdout.Wait(5000) -or -not $stderr.Wait(5000)) { throw 'Diagnostic output capture did not complete' }
                        $output = @($stdout.Result, $stderr.Result)
                        if ($NodeInspection -ceq 'Bootstrap') {
                            $output = @($output | ForEach-Object {
                                (($_ -split "`n") | ForEach-Object {
                                    if ($_ -match '(?i)-----BEGIN|\b(?:token|password|authorization|client.?secret|private.?key)\b|\beyJ[A-Za-z0-9_-]{15,}\.|\b[a-z0-9]{6}\.[a-z0-9]{16}\b|[A-Za-z0-9+/]{80,}={0,2}') { '[sensitive line withheld]' }
                                    else { $_ }
                                }) -join "`n"
                            })
                        }
                    } finally { $process.Dispose() }
                    $row = @{ name = $check.name; exitCode = $code; timedOut = $timedOut; output = $output }
                    Save-Operation (Join-Path $directory ($check.name + '-last.json')) $row
                    $row
                    if ($code -eq 255) { break }
                })
                @{ action = $Action; node = $identity; checks = $results; observedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 15 -Compress
            } finally {
                if (Test-Path $key) { Remove-Item $key -Force }
            }
            return
        }
        if ($Action -ceq 'InspectAks') {
            $diagnostics = Invoke-Command -Session $peer -ArgumentList $DiagnosticEndpointsBase64 -ScriptBlock {
                param($encodedEndpoints)
                $endpoints = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedEndpoints)) | ConvertFrom-Json
                if ($endpoints.Count -gt 8) { throw 'At most eight explicit diagnostic endpoints' }
                $configuration = Get-ArcHciConfig
                $tools = @(Get-Command kubectl, kubectl.exe, Get-ArcHciConfig -ErrorAction SilentlyContinue |
                    ForEach-Object { @{ name = $_.Name; source = $_.Source; path = $_.Path } })
                $files = @(Get-ChildItem 'C:\ClusterStorage\Infrastructure_1' -Filter '*kubeconfig*' -File -Recurse -ErrorAction SilentlyContinue |
                    ForEach-Object { @{ path = $_.FullName; sizeBytes = $_.Length } })
                $binaries = @(Get-ChildItem (Get-Module ArcHci).ModuleBase -Filter 'kubectl.exe' -File -Recurse -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.FullName })
                $ports = @(foreach ($endpoint in $endpoints) {
                    if ($endpoint.address -notmatch '^10\.64\.0\.\d{1,3}$' -or $endpoint.port -notin @(22, 6443)) { throw 'Only nested lab SSH/API endpoints are admitted' }
                    $client = [Net.Sockets.TcpClient]::new()
                    try {
                        $pending = $client.BeginConnect($endpoint.address, $endpoint.port, $null, $null)
                        $ready = $pending.AsyncWaitHandle.WaitOne(5000, $false)
                        if ($ready) { try { $client.EndConnect($pending) } catch { $ready = $false } }
                        @{ address = $endpoint.address; port = $endpoint.port; reachable = ($ready -and $client.Connected) }
                    } finally { $client.Dispose() }
                })
                @{ tools = $tools; kubectlBinaries = $binaries; arcHciConfigurationKeys = @($configuration.Keys); kubeconfigFiles = $files; ports = $ports }
            }
            @{ action = $Action; diagnostics = $diagnostics; observedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 15 -Compress
            return
        }
        if ($Action -ceq 'InspectMoc') {
            $details = @(foreach ($node in $nodes) {
                $session = Open-NodeSession $node
                try {
                    Invoke-Command -Session $session -ArgumentList $config.mocLocation -ScriptBlock {
                        param($location)
                        Import-Module Moc -ErrorAction Stop
                        $command = Get-Command New-MocPhysicalNode -ErrorAction Stop
                        @{ node = $env:COMPUTERNAME; modulePath = $command.Module.Path; moduleVersion = $command.Module.Version.ToString();
                           implementation = $(if ($env:COMPUTERNAME -ceq 'LB-NODE01') { $command.Definition } else { $null });
                           services = @(Get-Service | Where-Object Name -Match 'moc' | ForEach-Object { @{ name = $_.Name; status = $_.Status.ToString() } });
                           processes = @(Get-Process | Where-Object ProcessName -Match 'moc|powershell' | ForEach-Object { @{ id = $_.Id; name = $_.ProcessName; startedAt = $_.StartTime.ToUniversalTime().ToString('o'); cpuSeconds = $_.CPU } }) }
                    }
                } finally { Remove-PSSession $session }
            })
            $operations = @(Get-ChildItem 'C:\ProgramData\AzureLocalBox\Operations' -Filter '*.json' -ErrorAction SilentlyContinue |
                ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
            @{ action = $Action; nodes = $details; operations = $operations; mocMembers = @(Read-Membership $peer) } | ConvertTo-Json -Depth 15 -Compress
            return
        }
        $cluster = Invoke-Command -Session $peer -ArgumentList $config.clusterName -ScriptBlock {
            param($expected)
            if ((Get-Cluster).Name -ine $expected) { throw 'Wrong cluster' }
            $pool = @(Get-StoragePool -IsPrimordial $false)
            if ($pool.Count -ne 1) { throw 'Expected one S2D pool' }
            @{
                nodes = @(Get-ClusterNode | Sort-Object Name | ForEach-Object { @{ name = $_.Name; state = $_.State.ToString() } })
                pool = @{ id = $pool[0].UniqueId; health = $pool[0].HealthStatus.ToString(); sizeBytes = $pool[0].Size; allocatedBytes = $pool[0].AllocatedSize }
                disks = @($pool[0] | Get-PhysicalDisk | ForEach-Object { @{ id = $_.UniqueId; health = $_.HealthStatus.ToString(); operational = @($_.OperationalStatus | ForEach-Object { $_.ToString() }) } })
                csvs = @(Get-ClusterSharedVolume | ForEach-Object { @{ name = $_.Name; state = $_.State.ToString(); owner = $_.OwnerNode.Name;
                    paths = @($_.SharedVolumeInfo | ForEach-Object { @{ path = $_.FriendlyVolumeName; sizeBytes = $_.Partition.Size; freeBytes = $_.Partition.FreeSpace } }) } })
                storageJobs = @(Get-StorageJob | Where-Object JobState -NotIn @('Completed', 'Terminated') | ForEach-Object { @{ name = $_.Name; state = $_.JobState.ToString() } })
            }
        }
        $members = @(Read-Membership $peer)
        if (@($members | Where-Object { $_ -cnotin $nodes }).Count) { throw 'Unexpected MOC member' }
        $effects = @()
        if ($Action -ceq 'RepairMoc') {
            if (@($cluster.nodes | Where-Object state -CNE 'Up').Count -or $cluster.pool.health -cne 'Healthy' -or
                @($cluster.csvs | Where-Object state -CNE 'Online').Count) { throw 'MOC repair requires the current healthy, online cluster' }
            $root = 'C:\ProgramData\AzureLocalBox\Operations'
            if (-not (Test-Path $root)) {
                $null = New-Item $root -ItemType Directory
                Set-Acl $root (Get-Acl $config.credentialDirectory)
            }
            foreach ($node in $nodes) {
                $statePath = Join-Path $root ('moc-member-' + $node + '.json')
                if ($node -cin $members) {
                    if (Test-Path $statePath) {
                        $state = Get-Content $statePath -Raw | ConvertFrom-Json
                        $state.status = 'observed-present'
                        Save-Operation $statePath $state
                    }
                    continue
                }
                if (Test-Path $statePath) { throw 'Previous MOC add is unresolved. Inspect its result before another request' }
                $state = @{ node = $node; action = 'New-MocPhysicalNode'; status = 'pending'; startedAt = [datetime]::UtcNow.ToString('o');
                            processId = $PID; processStartedAt = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') }
                Save-Operation $statePath $state
                # The installed MOC implementation runs on a surviving peer, not the absent node.
                Invoke-Command -Session $peer -ArgumentList $node -ScriptBlock {
                    param($target)
                    Import-Module Moc -ErrorAction Stop
                    if ($env:COMPUTERNAME -ieq $target) { throw 'MOC add must execute on a different node' }
                    New-MocPhysicalNode -NodeName $target | Out-Null
                }
                $state.status = 'returned'
                Save-Operation $statePath $state
                $members = @(Read-Membership $peer)
                if ($node -cnotin $members) { throw 'MOC add returned but membership has not converged' }
                $state.status = 'observed-present'
                Save-Operation $statePath $state
                $effects += $node
            }
        }
        $capacity = @(foreach ($node in $nodes) {
            $session = Open-NodeSession $node
            try {
                Invoke-Command -Session $session -ScriptBlock {
                    $system = Get-CimInstance Win32_ComputerSystem
                    $os = Get-CimInstance Win32_OperatingSystem
                    @{ name = $env:COMPUTERNAME; cpu = $system.NumberOfLogicalProcessors; memoryBytes = $system.TotalPhysicalMemory;
                       freeMemoryBytes = [long]$os.FreePhysicalMemory * 1KB;
                       vms = @(Get-VM | ForEach-Object { @{ id = $_.Id.ToString(); name = $_.Name; state = $_.State.ToString(); cpu = $_.ProcessorCount;
                           memoryBytes = $_.MemoryStartup; heartbeat = $_.Heartbeat.ToString();
                           adapters = @($_ | Get-VMNetworkAdapter | ForEach-Object { @{ name = $_.Name; switch = $_.SwitchName;
                               macAddress = $_.MacAddress; ipAddresses = @($_.IPAddresses) } }) } }) }
                }
            } finally { Remove-PSSession $session }
        })
        @{ action = $Action; guests = $guests; cluster = $cluster; capacity = $capacity; mocMembers = $members;
           restoredMocMembers = $effects; observedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 15 -Compress
    } finally { Remove-PSSession $peer }
} finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
