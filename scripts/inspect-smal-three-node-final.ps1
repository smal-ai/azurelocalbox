# Read-only post-deployment inspection. Never resets credentials, storage or services.
$ErrorActionPreference = 'Stop'
$foundationV3Definitions = @'
function ConvertTo-SmalPublicField([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return @{ status = 'unavailable' } }
    if ($Value.Length -gt 2048 -or $Value -cmatch '-----BEGIN|\beyJ[A-Za-z0-9_-]{15,}\.|(?i:password|access_token|refresh_token)') {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $digest = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        return @{ status = 'withheld'; sha256 = $digest }
    }
    return @{ status = 'available'; value = $Value }
}

function Invoke-SmalOptionalRead([string]$Phase, [scriptblock]$Read) {
    try { return @{ status = 'complete'; phase = $Phase; value = (& $Read) } }
    catch { return @{ status = 'failed'; phase = $Phase;
        errorType = (ConvertTo-SmalPublicField $_.Exception.GetType().FullName);
        errorCategory = [string]$_.CategoryInfo.Category; sourceLine = [int]$_.InvocationInfo.ScriptLineNumber } }
}

function Get-SmalImportedSignature($Command) {
    $functionAst = $null
    if ($Command -is [Management.Automation.FunctionInfo]) {
        $functionAst = $Command.ScriptBlock.Ast
        if ($functionAst -is [Management.Automation.Language.FunctionDefinitionAst]) { $functionAst = $functionAst.Body }
    }
    if (($null -ne $functionAst -and $null -ne $functionAst.DynamicParamBlock) -or
        ($Command -is [Management.Automation.CmdletInfo] -and @($Command.ImplementingType.GetInterfaces() | Where-Object FullName -EQ 'System.Management.Automation.IDynamicParameters').Count)) {
        return @{ status = 'unavailable-dynamic-not-evaluated'; complete = $false }
    }
    $sets = @($Command.ParameterSets | ForEach-Object {
            @{ name = (ConvertTo-SmalPublicField $_.Name); parameters = @($_.Parameters | ForEach-Object {
                @{ name = (ConvertTo-SmalPublicField $_.Name); type = (ConvertTo-SmalPublicField $_.ParameterType.FullName);
                   mandatory = [bool]$_.IsMandatory }
            }) }
        })
    $unavailable = 0
    foreach ($set in $sets) {
        if ($set.name.status -cne 'available') { $unavailable++ }
        foreach ($parameter in $set.parameters) {
            if ($parameter.name.status -cne 'available' -or $parameter.type.status -cne 'available') { $unavailable++ }
        }
    }
    return @{ status = 'public-static-metadata'; complete = ($unavailable -eq 0);
        unavailableFieldCount = $unavailable; parameterSets = $sets }
}
# Source proposal only. No MOC import, evaluation, getter or configuration-file read.
function Get-SmalV3Hash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-SmalV3Literal($Ast, [int]$Depth = 0) {
    if ($Ast -is [Management.Automation.Language.VariableExpressionAst] -and $Ast.VariablePath.UserPath -cin @('true','false')) { return @{status='literal-boolean';complete=$true;value=($Ast.VariablePath.UserPath -ceq 'true')} }
    if ($Depth -gt 16) { return @{ status = 'unavailable-depth'; complete = $false } }
    if ($Ast -is [Management.Automation.Language.StatementBlockAst] -and $Ast.Statements.Count -eq 1) { return Get-SmalV3Literal $Ast.Statements[0] ($Depth + 1) }
    if ($Ast -is [Management.Automation.Language.PipelineAst] -and $Ast.PipelineElements.Count -eq 1) { return Get-SmalV3Literal $Ast.PipelineElements[0] ($Depth + 1) }
    if ($Ast -is [Management.Automation.Language.CommandExpressionAst]) { return Get-SmalV3Literal $Ast.Expression ($Depth + 1) }
    if ($Ast -is [Management.Automation.Language.StringConstantExpressionAst]) {
        return @{ status = 'literal'; value = (ConvertTo-SmalPublicField $Ast.Value); complete = $true }
    }
    if ($Ast -is [Management.Automation.Language.ConstantExpressionAst] -and $Ast.Value -is [ValueType]) { return @{ status = 'literal'; value = $Ast.Value; complete = $true } }
    if ($Ast -is [Management.Automation.Language.ArrayLiteralAst] -and $Ast.Elements.Count -le 32) {
        return @{ status = 'literal-array'; values = @($Ast.Elements | ForEach-Object { Get-SmalV3Literal $_ ($Depth + 1) }); complete = $false }
    }
    if ($Ast -is [Management.Automation.Language.ArrayExpressionAst] -and $Ast.SubExpression.Statements.Count -le 32) {
        return @{ status = 'literal-array-declarations'; complete = $false; values = @($Ast.SubExpression.Statements | ForEach-Object { Get-SmalV3Literal $_ ($Depth + 1) }) }
    }
    if ($Ast -is [Management.Automation.Language.HashtableAst] -and $Ast.KeyValuePairs.Count -le 32) {
        $allowed = @('ModuleName','ModuleVersion','RequiredVersion','GUID','MaximumVersion')
        return @{ status = 'dependency-specification'; complete = $false; fields = @($Ast.KeyValuePairs | ForEach-Object {
            if ($_.Item1 -is [Management.Automation.Language.StringConstantExpressionAst] -and $allowed -contains $_.Item1.Value) {
                @{ name = $_.Item1.Value; declaration = (Get-SmalV3Literal $_.Item2 ($Depth + 1)) }
            }
        }) }
    }
    return @{ status = 'unavailable-not-evaluated'; complete = $false; astType = $Ast.GetType().Name }
}
function Get-SmalV3Argument($Element) {
    $allowedTokens = @('get','list','show','image','gallery','galleryimage','virtualharddisk','virtualmachine','networkinterface','virtualnetwork','vippool','container','location','group','node','compute','network','storage','availabilityset','placementgroup','zone','json','--help','--name','--group','--location','--container','--output','--query','-o','-n','-g','mocctl.exe','moc.exe')
    if ($Element -is [Management.Automation.Language.CommandParameterAst]) { return @{ kind = 'parameter-name'; name = (ConvertTo-SmalPublicField $Element.ParameterName); attachedArgument = ($null -ne $Element.Argument) } }
    if ($Element -is [Management.Automation.Language.VariableExpressionAst]) { return @{ kind = 'variable-not-resolved'; name = (ConvertTo-SmalPublicField $Element.VariablePath.UserPath); splatted = [bool]$Element.Splatted } }
    if ($Element -is [Management.Automation.Language.StringConstantExpressionAst] -and $allowedTokens -contains $Element.Value) { return @{ kind = 'allowlisted-public-token'; value = $Element.Value } }
    return @{ kind = 'unavailable-not-exported'; astType = $Element.GetType().Name; sourceSha256 = (Get-SmalV3Hash ([Text.Encoding]::UTF8.GetBytes($Element.Extent.Text))) }
}
function Get-SmalV3Calls($Scope) {
    $candidates = @($Scope.FindAll({ param($x) $x -is [Management.Automation.Language.CommandAst] -or $x -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true))
    $calls = @(foreach ($call in $candidates) {
        $skip = $false; $parent = $call.Parent
        while ($null -ne $parent -and $parent -ne $Scope) {
            if ($parent -is [Management.Automation.Language.ParameterAst] -or $parent -is [Management.Automation.Language.FunctionDefinitionAst]) { $skip = $true; break }
            $parent = $parent.Parent
        }
        if (-not $skip) { $call }
    })
    if ($calls.Count -gt 256) { return @{ status = 'unavailable-call-count-bound'; complete = $false } }
    $rows = @(foreach ($call in $calls) {
        if ($call -is [Management.Automation.Language.InvokeMemberExpressionAst]) {
            @{ kind = 'member-call-not-invoked'; line = $call.Extent.StartLineNumber;
               member = $(if ($call.Member -is [Management.Automation.Language.StringConstantExpressionAst]) { ConvertTo-SmalPublicField $call.Member.Value } else { @{ status = 'dynamic-unavailable' } });
               target = $(if ($call.Expression -is [Management.Automation.Language.TypeExpressionAst]) { @{ kind = 'declared-type-not-resolved'; name = (ConvertTo-SmalPublicField $call.Expression.TypeName.FullName) } } else { Get-SmalV3Argument $call.Expression });
               arguments = @($call.Arguments | ForEach-Object { if ($null -ne $_) { Get-SmalV3Argument $_ } }); complete = $false }
            continue
        }
        $command = $call.GetCommandName()
        @{ kind = 'command-not-invoked'; line = $call.Extent.StartLineNumber; invocationOperator = [string]$call.InvocationOperator;
           name = (ConvertTo-SmalPublicField $command); complete = $false;
           target = (Get-SmalV3Argument $call.CommandElements[0]);
           arguments = @($call.CommandElements | Select-Object -Skip 1 | ForEach-Object { Get-SmalV3Argument $_ }) }
    })
    return @{ status = 'static-call-projection'; complete = $false; calls = $rows }
}
function Assert-SmalV4PublicPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    # Build the lexical chain without reading descendants through an unchecked ancestor.
    $chain = [Collections.Generic.List[string]]::new()
    $directory = [IO.DirectoryInfo]::new([IO.Path]::GetDirectoryName($full))
    while ($null -ne $directory) {
        if ($chain.Count -ge 128) { throw 'Public module ancestor depth outside read bounds' }
        $chain.Add($directory.FullName)
        $directory = $directory.Parent
    }
    for ($index = $chain.Count - 1; $index -ge 0; $index--) {
        $ancestor = [IO.DirectoryInfo]::new($chain[$index]); $ancestor.Refresh()
        if (-not $ancestor.Exists -or ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Public module ancestor unavailable or redirected'
        }
    }
    $leaf = [IO.FileInfo]::new($full); $leaf.Refresh()
    if (-not $leaf.Exists -or ($leaf.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $leaf.Length -gt 2097152) {
        throw 'Public module file unavailable, redirected or outside read bounds'
    }
    return $full
}
function Read-SmalV4PublicBytes([string]$Path) {
    $full = Assert-SmalV4PublicPath $Path
    $stream = [IO.FileStream]::new($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $null = Assert-SmalV4PublicPath $full
        if ($stream.Length -gt 2097152) { throw 'Public module file size outside read bounds' }
        # Hard read cap, not only a pre-open FileInfo length check.
        $buffer = [byte[]]::new(2097153); $count = 0
        while ($count -lt $buffer.Length) {
            $read = $stream.Read($buffer, $count, $buffer.Length - $count)
            if ($read -eq 0) { break }
            $count += $read
        }
        if ($count -gt 2097152) { throw 'Public module file grew beyond read bounds' }
        $null = Assert-SmalV4PublicPath $full
        $bytes = [byte[]]::new($count); [Array]::Copy($buffer, $bytes, $count)
        return ,$bytes
    } finally { $stream.Dispose() }
}
function Get-SmalV3FileContract([string]$Path) {
    $Path = Assert-SmalV4PublicPath $Path
    $bytes = Read-SmalV4PublicBytes $Path
    $tokens = $null; $issues = $null
    $reader = [IO.StreamReader]::new([IO.MemoryStream]::new($bytes), [Text.UTF8Encoding]::new($false, $true), $true)
    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$issues)
    $signature = Invoke-SmalOptionalRead 'public-file-authenticode' {
        $null = Assert-SmalV4PublicPath $Path
        $read = Invoke-SmalV3KnownRead 'Get-AuthenticodeSignature' @{ FilePath = $Path }
        $null = Assert-SmalV4PublicPath $Path
        if ($read.status -cne 'complete') { return $read }
        if (@($read.value).Count -ne 1) { return @{ status = 'unavailable-signature-result-shape' } }
        $signed = @($read.value)[0]
        @{ status = [string]$signed.Status; signatureType = [string]$signed.SignatureType;
           signer = $(if ($null -ne $signed.SignerCertificate) {
               @{ subject = (ConvertTo-SmalPublicField $signed.SignerCertificate.Subject); issuer = (ConvertTo-SmalPublicField $signed.SignerCertificate.Issuer);
                  thumbprint = [string]$signed.SignerCertificate.Thumbprint; notBefore = $signed.SignerCertificate.NotBefore.ToUniversalTime().ToString('o'); notAfter = $signed.SignerCertificate.NotAfter.ToUniversalTime().ToString('o') }
           } else { @{ status = 'no-signer-reported' } }); statusMessage = 'not-exported'; moduleTrustAdmitted = $false }
    }
    return @{ path = (ConvertTo-SmalPublicField $Path); sha256 = (Get-SmalV3Hash $bytes); bytes = $bytes.Length;
        parseStatus = $(if (@($issues).Count) { 'unavailable-static-parse' } else { 'parsed-not-executed' }); parseIssueCount = @($issues).Count;
        signature = $signature; ast = $ast }
}
function Get-SmalV3MocContract {
    $base = 'C:\Program Files\WindowsPowerShell\Modules\Moc\1.2.161'
    $manifest = Get-SmalV3FileContract ($base + '\Moc.psd1')
    $root = Get-SmalV3FileContract ($base + '\Moc.psm1')
    if ($manifest.sha256 -cne 'b4c171acdf6bdaf86a6751396e27b52714af2d1410505d1f3412103cf5435c3f' -or $root.sha256 -cne 'b9dbda4ab8c0ce6c77d8fa219a153983114afc859f5bb10689f6f3cf71025b7f') { throw 'Observed Moc public bytes drifted' }
    $manifestFields = @('RootModule','ModuleToProcess','ModuleVersion','GUID','RequiredModules','NestedModules','RequiredAssemblies','ScriptsToProcess','TypesToProcess','FormatsToProcess','FunctionsToExport','CmdletsToExport','AliasesToExport','PowerShellVersion','CLRVersion','DotNetFrameworkVersion','ProcessorArchitecture')
    $declarations = @()
    if ($manifest.parseIssueCount -eq 0) {
        $tables = @($manifest.ast.FindAll({ param($x) $x -is [Management.Automation.Language.HashtableAst] }, $true))
        if ($tables.Count) {
            $declarations = @($tables[0].KeyValuePairs | ForEach-Object {
                if ($_.Item1 -is [Management.Automation.Language.StringConstantExpressionAst] -and $manifestFields -contains $_.Item1.Value) {
                    @{ name = $_.Item1.Value; declaration = (Get-SmalV3Literal $_.Item2) }
                }
            })
        }
    }
    $selected = @('Get-MocLocation','Get-MocGroup','Get-MocContainer','Get-MocGalleryImage','Get-MocVirtualHardDisk','Get-MocVirtualMachine','Get-MocNetworkInterface','Get-MocVirtualNetwork','Get-MocVipPool','Get-MocNode','Get-MocAvailabilitySet','Get-MocPlacementGroup','Initialize-MocConfiguration','Initialize-MocEnvironment','Uninitialize-MocEnvironment','Repair-MocLogin','Get-CloudFqdn','ConvertTo-ArgString','Invoke-CommandLine')
    $wrappers = @(); $helpers = @(); $initialisation = @{ status = 'unavailable-static-parse'; complete = $false }
    if ($root.parseIssueCount -eq 0) {
        $definitions = @($root.ast.FindAll({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
        $wrappers = @($definitions | Where-Object { $selected -contains $_.Name } | ForEach-Object {
            $f = $_
            @{ name = (ConvertTo-SmalPublicField $f.Name); startLine = $f.Extent.StartLineNumber; endLine = $f.Extent.EndLineNumber;
               declarationSha256 = (Get-SmalV3Hash ([Text.Encoding]::UTF8.GetBytes($f.Extent.Text)));
               parameters = @(Get-SmalV5ParameterDeclarations $f); defaultExpressions = 'not-evaluated-or-exported'; dispatch = (Get-SmalV3Calls $f.Body) }
        })
        $seen = @($selected); $frontier = @($wrappers)
        for ($depth = 1; $depth -le 2; $depth++) {
            $names = @($frontier | ForEach-Object { $_.dispatch.calls | ForEach-Object { if ($_.name.status -ceq 'available') { $_.name.value } } })
            $next = @()
            foreach ($definition in $definitions) {
                if ($names -notcontains $definition.Name -or $seen -contains $definition.Name) { continue }
                if ($helpers.Count -ge 24) { break }
                $row = @{ name = (ConvertTo-SmalPublicField $definition.Name); helperDepth = $depth;
                    startLine = $definition.Extent.StartLineNumber; endLine = $definition.Extent.EndLineNumber;
                    declarationSha256 = (Get-SmalV3Hash ([Text.Encoding]::UTF8.GetBytes($definition.Extent.Text)));
                    dispatch = (Get-SmalV3Calls $definition.Body) }
                $helpers += $row; $next += $row; $seen += $definition.Name
            }
            $frontier = $next
        }
        $initialisation = Get-SmalV3Calls $root.ast
    }
    $versions = @($declarations | Where-Object name -EQ 'ModuleVersion')
    $roots = @($declarations | Where-Object name -EQ 'RootModule')
    $identity = $versions.Count -eq 1 -and $roots.Count -eq 1 -and $versions[0].declaration.value.value -ceq '1.2.161' -and $roots[0].declaration.value.value -ieq 'Moc.psm1'
    $manifest.Remove('ast'); $root.Remove('ast')
    return @{ status = 'static-public-contract-only'; module = 'Moc'; expectedVersion = '1.2.161'; manifest = $manifest; root = $root;
        manifestIdentityStatus = $(if ($identity) { 'declared-name-version-path-match-hash-review-required' } else { 'unavailable-or-identity-drift' });
        manifestDeclarations = $declarations; initialisation = $initialisation; selectedWrappers = $wrappers; referencedRootHelpers = $helpers;
        dependenciesRead = 'declarations-only-no-recursive-file-read'; dynamicOrNestedDependencies = 'not-evaluated';
        moduleImportPerformed = $false; initialisersExecuted = $false; getterInvocationPerformed = $false;
        contractCompleteForInvocation = $false; imageState = 'not-observed'; allocationOwnershipState = 'not-observed' }
}
function Invoke-SmalV3KnownRead([string]$Name, [hashtable]$Bindings) {
    $allow = @{
        'Get-AuthenticodeSignature' = @('Microsoft.PowerShell.Security'); 'Get-VMHost' = @('Hyper-V'); 'Get-VMHostNumaNode' = @('Hyper-V');
        'Get-VM' = @('Hyper-V'); 'Get-VMProcessor' = @('Hyper-V'); 'Get-VMMemory' = @('Hyper-V'); 'Get-VMHostSupportedVersion' = @('Hyper-V');
        'Get-VMNetworkAdapter' = @('Hyper-V'); 'Get-VMNetworkAdapterVlan' = @('Hyper-V');
        'Get-CimInstance' = @('CimCmdlets'); 'Get-CimClass' = @('CimCmdlets'); 'Find-NetRoute' = @('NetTCPIP'); 'Get-NetRoute' = @('NetTCPIP');
        'Get-NetIPAddress' = @('NetTCPIP'); 'Get-NetNat' = @('NetNat'); 'Get-NetNatStaticMapping' = @('NetNat')
    }
    if (-not $allow.ContainsKey($Name)) { return @{ status = 'unavailable-reader-not-allowlisted'; complete = $false } }
    # Exact standard Windows readers only. Discovery may autoload their OS module, never Moc.
    $commands = @(Get-Command -Name $Name -Module $allow[$Name] -ErrorAction Stop)
    if ($commands.Count -ne 1 -or $allow[$Name] -notcontains $commands[0].ModuleName) { return @{ status = 'unavailable-reader-identity'; complete = $false } }
    $command = $commands[0]
    if ($Name -cin @('Find-NetRoute','Get-NetRoute','Get-NetIPAddress','Get-NetNat','Get-NetNatStaticMapping')) { return Invoke-SmalV5LiteralNetworkRead $command $Name $Bindings }
    $metadata = Get-SmalImportedSignature $command
    if (-not $metadata.complete) { return @{ status = 'unavailable-reader-signature'; metadata = $metadata; complete = $false } }
    foreach ($key in $Bindings.Keys) {
        if (-not $command.Parameters.ContainsKey($key)) { return @{ status = 'unavailable-native-parameter'; reader = $Name; complete = $false } }
    }
    $eligible = @($command.ParameterSets | Where-Object {
        @($_.Parameters | Where-Object { $_.IsMandatory -and -not $Bindings.ContainsKey($_.Name) }).Count -eq 0
    })
    if (-not $eligible.Count) { return @{ status = 'unavailable-required-parameter-set'; reader = $Name; complete = $false } }
    $Bindings.ErrorAction = 'Stop'
    $value = @(& $command @Bindings)
    if ($value.Count -gt 64) { return @{ status = 'unavailable-result-count-bound'; reader = $Name; observedCount = $value.Count; complete = $false } }
    return @{ status = 'complete'; reader = $Name; module = [string]$command.ModuleName;
        moduleVersion = [string]$command.Module.Version; metadata = $metadata; value = $value }
}
function ConvertTo-SmalV3Properties($Object, $Schema = $null) {
    $strings = @('Name','VMName','Id','VMId','State','Version','Path','ConfigurationLocation','SnapshotFileLocation','SmartPagingFilePath','CheckpointType','AutomaticStartAction','AutomaticStopAction','InterfaceAlias','IPAddress','DestinationPrefix','NextHop','SwitchName','SwitchId','MacAddress','OperationMode','AllowedVlanIdList','InternalIPInterfaceAddressPrefix','ExternalIPAddress','InternalIPAddress','Protocol','UniqueId','FriendlyName')
    return @($Object.PSObject.Properties | Select-Object -First 200 | ForEach-Object {
        $property = $_; $type = [string]$property.TypeNameOfValue
        $row = @{ name = (ConvertTo-SmalPublicField $property.Name); nativeType = (ConvertTo-SmalPublicField $type); units = 'not-inferred'; valueStatus = 'not-exported' }
        if ($null -ne $Object.PSObject.Properties['CimClass']) {
            try {
                $units = @($Object.CimClass.CimClassProperties[$property.Name].Qualifiers | Where-Object Name -EQ 'Units')
                if ($units.Count -eq 1) { $row.nativeUnits = ConvertTo-SmalPublicField ([string]$units[0].Value) }
                elseif ($null -ne $Schema -and $Schema.status -ceq 'complete' -and $Schema.value.status -ceq 'complete') {
                    $native=@($Schema.value.value)[0].CimClassProperties[$property.Name]
                    $schemaUnits=@($native.Qualifiers | Where-Object Name -EQ 'Units')
                    if ($schemaUnits.Count -eq 1) { $row.nativeUnits=ConvertTo-SmalPublicField ([string]$schemaUnits[0].Value) }
                }
            } catch { $row.units = 'schema-unit-read-unavailable' }
        }
        $scalar=Get-SmalV5NativeScalar $property
        if ($scalar.status -ceq 'native-scalar') { $row.value=$scalar.value; $row.valueStatus='native-scalar'; $row.runtimeType=$scalar.runtimeType }
        elseif ($strings -contains $property.Name) { $row.value = ConvertTo-SmalPublicField ([string]$property.Value); $row.valueStatus = 'public-string-projection' }
        elseif ($type -match '^System\.(Int16|UInt16|Int32|UInt32|Int64|UInt64)\[\]$') { $row.value = @($property.Value | Select-Object -First 256); $row.valueStatus = 'native-numeric-array-bounded'; $row.arrayComplete = (@($property.Value).Count -le 256) }
        $row
    })
}
function Get-SmalV3ReadProperties([string]$Name, [hashtable]$Bindings) {
    $read = Invoke-SmalV3KnownRead $Name $Bindings
    if ($read.status -cne 'complete') { return $read }
    $schema=$null
    if ($Name -ceq 'Get-CimInstance' -and $Bindings.ClassName -cin @('Win32_OperatingSystem','Win32_Processor')) {
        $schema=Invoke-SmalOptionalRead 'exact-cim-schema-units' { Invoke-SmalV3KnownRead 'Get-CimClass' @{ClassName=$Bindings.ClassName} }
    }
    return @{ status = 'complete'; reader = $read.reader; module = $read.module; moduleVersion = $read.moduleVersion; metadata = $read.metadata;
        objects = @($read.value | ForEach-Object { @{ nativeObjectType = (ConvertTo-SmalPublicField $_.GetType().FullName);
            nativePropertyCount = @($_.PSObject.Properties).Count; propertyDiscoveryComplete = (@($_.PSObject.Properties).Count -le 200);
            properties = @(ConvertTo-SmalV3Properties $_ $schema) } });
        schemaUnitsRead = $(if ($null -eq $schema) { @{status='not-applicable'} } else { @{status=[string]$schema.status; readerStatus=[string]$schema.value.status; phase=[string]$schema.phase; errorCategory=[string]$schema.errorCategory; errorType=$schema.errorType} });
        numericUnitsAndProfileSupportAdmitted = $false }
}
function Get-SmalV3Compute {
    $hostRead = Invoke-SmalOptionalRead 'host-hyperv-properties' { Get-SmalV3ReadProperties 'Get-VMHost' @{} }
    $numa = Invoke-SmalOptionalRead 'host-numa-properties' { Get-SmalV3ReadProperties 'Get-VMHostNumaNode' @{} }
    $versions = Invoke-SmalOptionalRead 'host-supported-vm-version-properties' { Get-SmalV3ReadProperties 'Get-VMHostSupportedVersion' @{} }
    $osMemory = Invoke-SmalOptionalRead 'os-memory-properties' { Get-SmalV3ReadProperties 'Get-CimInstance' @{ ClassName = 'Win32_OperatingSystem' } }
    $cpu = Invoke-SmalOptionalRead 'processor-properties' { Get-SmalV3ReadProperties 'Get-CimInstance' @{ ClassName = 'Win32_Processor' } }
    $vms = Invoke-SmalOptionalRead 'vm-compute-properties' {
        $read = Invoke-SmalV3KnownRead 'Get-VM' @{}
        if ($read.status -cne 'complete') { return $read }
        @($read.value | ForEach-Object {
            $vm = $_
            @{ vmId = [string][guid]$vm.Id; state = [string]$vm.State;
               nativePropertyCount = @($vm.PSObject.Properties).Count; propertyDiscoveryComplete = (@($vm.PSObject.Properties).Count -le 200);
               vmProperties = @(ConvertTo-SmalV3Properties $vm);
               processor = (Invoke-SmalOptionalRead 'vm-processor-properties' { Get-SmalV3ReadProperties 'Get-VMProcessor' @{ VM = $vm } });
               memory = (Invoke-SmalOptionalRead 'vm-memory-properties' { Get-SmalV3ReadProperties 'Get-VMMemory' @{ VM = $vm } });
               adapters = (Invoke-SmalOptionalRead 'vm-adapter-properties' {
                   $adapters = Invoke-SmalV3KnownRead 'Get-VMNetworkAdapter' @{ VM = $vm }
                   if ($adapters.status -cne 'complete') { return $adapters }
                   @($adapters.value | ForEach-Object {
                       $adapter = $_
                       @{ nativePropertyCount = @($adapter.PSObject.Properties).Count; propertyDiscoveryComplete = (@($adapter.PSObject.Properties).Count -le 200);
                          properties = @(ConvertTo-SmalV3Properties $adapter);
                          vlan = (Invoke-SmalOptionalRead 'vm-vlan-properties' { Get-SmalV3ReadProperties 'Get-VMNetworkAdapterVlan' @{ VMNetworkAdapter = $adapter } }) }
                   })
               }) }
        })
    }
    return @{ status = 'independent-read-projections'; host = $hostRead; numa = $numa; supportedVmVersions = $versions; osMemory = $osMemory; processor = $cpu; vms = $vms;
        profileChangeAdmitted = $false; platformReservationsMeasured = $false }
}
function Get-SmalV3Constraints($Command) {
    @($Command.Parameters.Values | ForEach-Object {
        $parameter = $_
        foreach ($attribute in $parameter.Attributes) {
            if ($attribute -is [Management.Automation.ValidateRangeAttribute] -and $attribute.MinRange -is [ValueType] -and $attribute.MaxRange -is [ValueType]) {
                @{ parameter = (ConvertTo-SmalPublicField $parameter.Name); constraint = 'declared-validation-range'; minimum = $attribute.MinRange; maximum = $attribute.MaxRange }
            }
            elseif ($attribute -is [Management.Automation.ValidateSetAttribute]) {
                @{ parameter = (ConvertTo-SmalPublicField $parameter.Name); constraint = 'declared-validation-set'; complete = (@($attribute.ValidValues).Count -le 32);
                   values = @($attribute.ValidValues | Select-Object -First 32 | ForEach-Object { ConvertTo-SmalPublicField ([string]$_) }) }
            }
        }
    })
}
function Get-SmalV3LifecycleMetadata {
    # Metadata discovery only. No lifecycle/storage-changing command is called.
    $names = @('Set-VMProcessor','Set-VMMemory','Get-VMHostSupportedVersion','Suspend-ClusterNode','Resume-ClusterNode','Move-ClusterVirtualMachineRole','Enable-StorageMaintenanceMode','Disable-StorageMaintenanceMode','Resize-VirtualDisk','Resize-Partition','Get-PartitionSupportedSize','Get-Partition','Get-Disk','Get-VirtualDisk')
    @($names | ForEach-Object {
        $name = $_
        Invoke-SmalOptionalRead 'lifecycle-command-public-metadata-only' {
            $c = @(Get-Command -Name $name -Module Hyper-V,Storage,FailoverClusters -ErrorAction Stop)
            if ($c.Count -ne 1 -or @('Hyper-V','Storage','FailoverClusters') -notcontains $c[0].ModuleName) { return @{ name = $name; status = 'unavailable-command-identity' } }
            @{ name = $name; module = [string]$c[0].ModuleName; moduleVersion = [string]$c[0].Module.Version;
               signature = (Get-SmalImportedSignature $c[0]); validationMetadata = @(Get-SmalV3Constraints $c[0]); commandInvoked = $false }
        }
    })
}
function Get-SmalV3OuterRoutes {
    @{ status = 'independent-read-projections'; routes = @(foreach ($ip in @('10.64.0.100','10.64.0.180')) {
        @{ destination = $ip; read = (Invoke-SmalOptionalRead 'outer-selected-route-properties' { Get-SmalV3ReadProperties 'Find-NetRoute' @{ RemoteIPAddress = $ip } }) }
    });
       defaultRoutes = (Invoke-SmalOptionalRead 'outer-default-route-properties' { Get-SmalV3ReadProperties 'Get-NetRoute' @{ AddressFamily = 'IPv4'; DestinationPrefix = '0.0.0.0/0' } });
       ipv4 = (Invoke-SmalOptionalRead 'outer-ipv4-properties' { Get-SmalV3ReadProperties 'Get-NetIPAddress' @{ AddressFamily = 'IPv4' } });
       nat = (Invoke-SmalOptionalRead 'outer-nat-properties' { Get-SmalV3ReadProperties 'Get-NetNat' @{} });
       mappings = (Invoke-SmalOptionalRead 'outer-nat-mapping-properties' { Get-SmalV3ReadProperties 'Get-NetNatStaticMapping' @{} });
       sshCallerCoverageAdmitted = $false }
}

# Exact compatibility changes and public dependency qualification. No Moc import/getter.
function Invoke-SmalV5LiteralNetworkRead($Command, [string]$Name, [hashtable]$Bindings) {
    $rules = @{
        'Find-NetRoute' = @{ module='NetTCPIP'; required=@('RemoteIPAddress') }
        'Get-NetRoute' = @{ module='NetTCPIP'; required=@('AddressFamily','DestinationPrefix') }
        'Get-NetIPAddress' = @{ module='NetTCPIP'; required=@('AddressFamily') }
        'Get-NetNat' = @{ module='NetNat'; required=@() }
        'Get-NetNatStaticMapping' = @{ module='NetNat'; required=@() }
    }
    if (-not $rules.ContainsKey($Name)) { throw 'Reader not in exact network policy' }
    $rule=$rules[$Name]
    if ($Command.Name -cne $Name -or $Command.ModuleName -cne $rule.module -or [string]$Command.CommandType -cnotin @('Function','Cmdlet')) { throw 'Standard reader identity differs' }
    if ($Bindings.Count -ne $rule.required.Count -or @($Bindings.Keys | Where-Object { $rule.required -notcontains $_ }).Count) { throw 'Nonliteral standard reader binding' }
    foreach ($key in $Bindings.Keys) { if ($Bindings[$key] -isnot [string]) { throw 'Standard reader requires literal string arguments' } }
    if ($Name -ceq 'Find-NetRoute' -and $Bindings.RemoteIPAddress -cnotin @('10.64.0.100','10.64.0.180')) { throw 'Unapproved route target' }
    if ($Bindings.ContainsKey('AddressFamily') -and $Bindings.AddressFamily -cne 'IPv4') { throw 'Unapproved address family' }
    if ($Bindings.ContainsKey('DestinationPrefix') -and $Bindings.DestinationPrefix -cne '0.0.0.0/0') { throw 'Unapproved route prefix' }
    # Trusted standard CDXML function: let normal PowerShell binding obtain its dynamic
    # parameters. This exception is unavailable to Moc or arbitrary modules/arguments.
    $value=@(& $Command @Bindings -ErrorAction Stop)
    if ($value.Count -gt 64) { throw 'Standard reader result count exceeded' }
    @{ status='complete'; reader=$Name; module=[string]$Command.ModuleName; moduleVersion=[string]$Command.Module.Version;
       bindingPolicy='exact-literal-standard-reader-normal-binding'; value=$value; networkWritePerformed=$false }
}
function Get-SmalV5NativeScalar($Property) {
    $native=[string]$Property.TypeNameOfValue
    if ($native -notmatch '^(System\.)?(Boolean|Bool|Byte|SByte|U?Int(8|16|32|64)|SInt(8|16|32|64)|Single|Double|Decimal|Real32|Real64)$') { return @{status='not-numeric'} }
    $value=$Property.Value
    if ($null -eq $value) { return @{status='native-null'} }
    $runtime=$value.GetType().FullName
    if ($runtime -notmatch '^System\.(Boolean|Byte|SByte|Int16|UInt16|Int32|UInt32|Int64|UInt64|Single|Double|Decimal)$') { return @{status='not-native-numeric';runtimeType=(ConvertTo-SmalPublicField $runtime)} }
    if (($value -is [double] -and ([double]::IsNaN($value) -or [double]::IsInfinity($value))) -or ($value -is [single] -and ([single]::IsNaN($value) -or [single]::IsInfinity($value)))) { return @{status='unavailable-nonfinite-native-number'} }
    @{status='native-scalar';value=$value;runtimeType=(ConvertTo-SmalPublicField $runtime)}
}
function Get-SmalV5ParameterDeclarations($Function) {
    $parameters=@($Function.Parameters | Where-Object { $null -ne $_ })
    if (-not $parameters.Count -and $null -ne $Function.Body.ParamBlock) { $parameters=@($Function.Body.ParamBlock.Parameters | Where-Object { $null -ne $_ }) }
    @($parameters | ForEach-Object {
        @{name=(ConvertTo-SmalPublicField $_.Name.VariablePath.UserPath);
          types=@($_.Attributes | Where-Object {$_ -is [Management.Automation.Language.TypeConstraintAst]} | ForEach-Object {ConvertTo-SmalPublicField $_.TypeName.FullName});
          hasDefault=($null -ne $_.DefaultValue); defaultValue='not-evaluated-or-exported';
          attributes=@($_.Attributes | Where-Object {$_ -is [Management.Automation.Language.AttributeAst]} | ForEach-Object {
              @{type=(ConvertTo-SmalPublicField $_.TypeName.FullName); namedArguments=@($_.NamedArguments | ForEach-Object {
                  @{name=(ConvertTo-SmalPublicField $_.ArgumentName); declaration=(Get-SmalV3Literal $_.Argument)}
              })}
          })}
    })
}
function Get-SmalV5PublicUnit([string]$Path) {
    if ([IO.Path]::GetExtension($Path) -ieq '.dll') {
        # Exact declared public module root only. No Assembly.Load or binary execution.
        $Path=Assert-SmalV4PublicPath $Path;$bytes=Read-SmalV4PublicBytes $Path
        $signature=Invoke-SmalOptionalRead 'exact-public-binary-authenticode' {
            $null=Assert-SmalV4PublicPath $Path
            $read=Invoke-SmalV3KnownRead 'Get-AuthenticodeSignature' @{FilePath=$Path}
            $null=Assert-SmalV4PublicPath $Path
            if ($read.status -cne 'complete' -or @($read.value).Count -ne 1) {return @{status='unavailable-signature'}}
            $signed=@($read.value)[0]
            @{status=[string]$signed.Status;signer=$(if($null -ne $signed.SignerCertificate){@{subject=(ConvertTo-SmalPublicField $signed.SignerCertificate.Subject);issuer=(ConvertTo-SmalPublicField $signed.SignerCertificate.Issuer);thumbprint=[string]$signed.SignerCertificate.Thumbprint}}else{@{status='no-signer-reported'}});moduleTrustAdmitted=$false}
        }
        return @{file=@{path=(ConvertTo-SmalPublicField $Path);sha256=(Get-SmalV3Hash $bytes);bytes=$bytes.Length;signature=$signature};status='public-binary-metadata-only';binaryExecuted=$false;initialisation='not-executed-or-inspected';dependencyClosureQualified=$false}
    }
    if ([IO.Path]::GetExtension($Path) -cnotin @('.psd1','.psm1','.ps1')) { throw 'Only exact public PowerShell source files allowed' }
    $file=Get-SmalV3FileContract $Path
    $ast=$file.ast
    $functions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
    $selected=@('Initialize-MocConfiguration','Initialize-MocEnvironment','Uninitialize-MocEnvironment','Repair-MocLogin','Get-CloudFqdn','ConvertTo-ArgString','Invoke-CommandLine','New-ModuleEventLog','Write-Status','Write-StatusWithProgress','Trace-Cmdlet','Trace-CmdletError','Get-TraceConfigDetails')
    $rows=@($functions | Where-Object {$selected -contains $_.Name -or $_.Name -like 'Get-Moc*'} | Select-Object -First 64 | ForEach-Object {
        @{name=(ConvertTo-SmalPublicField $_.Name); startLine=$_.Extent.StartLineNumber; endLine=$_.Extent.EndLineNumber;
          declarationSha256=(Get-SmalV3Hash ([Text.Encoding]::UTF8.GetBytes($_.Extent.Text)));
          parameters=@(Get-SmalV5ParameterDeclarations $_); dispatch=(Get-SmalV3Calls $_.Body)}
    })
    $tables=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.HashtableAst]},$true))
    $declarations=@()
    if ([IO.Path]::GetExtension($Path) -ceq '.psd1' -and $tables.Count) {
        $allowed=@('RootModule','ModuleToProcess','ModuleVersion','GUID','RequiredModules','NestedModules','RequiredAssemblies','ScriptsToProcess','TypesToProcess','FormatsToProcess')
        $declarations=@($tables[0].KeyValuePairs | ForEach-Object {
            if ($_.Item1 -is [Management.Automation.Language.StringConstantExpressionAst] -and $allowed -contains $_.Item1.Value) {
                @{name=$_.Item1.Value;declaration=(Get-SmalV3Literal $_.Item2)}
            }
        })
    }
    $initialisation=Get-SmalV3Calls $ast; $file.Remove('ast')
    @{file=$file;declarations=$declarations;initialisation=$initialisation;selectedDefinitions=$rows;
      definitionInventoryComplete=($functions.Count -le 64); dependencyClosureQualified=$false; effectsClassification='human-code-review-required-not-classified-by-verb'}
}
# Lexical candidates only. Never use native module analysis before bounded manifest reads.
function Get-SmalV5Dependencies {
    $base='C:\Program Files\WindowsPowerShell\Modules\Moc\1.2.161'
    $common=Invoke-SmalOptionalRead 'exact-moc-common-public-source' {Get-SmalV5PublicUnit ($base+'\Common.psm1')}
    $roots=@($env:PSModulePath.Split([IO.Path]::PathSeparator) | Where-Object {-not [string]::IsNullOrWhiteSpace($_)} | Select-Object -Unique)
    if ($roots.Count -gt 8) {return @{status='unavailable-public-path-root-bound';observedRootCount=$roots.Count;importAdmitted=$false;getterAdmitted=$false}}
    $dependencies=@(foreach($expected in @(
        @{name='DownloadSdk';version='1.1.149';guid='1cc49c8b-6e57-4594-8e07-649656b32d85'},
        @{name='TraceProvider';version='1.0.156';guid='09b2e7fc-61dd-41da-af90-2bee7506fb70'})) {
        $expectedModule=$expected
        Invoke-SmalOptionalRead 'exact-declared-public-dependency' {
            $candidates=@();$seen=@{}
            foreach($modulePath in $roots) {
                if (-not [IO.Path]::IsPathRooted($modulePath)) {continue}
                # Construct two conventional exact paths. No directory recursion/content analysis.
                $moduleBase=[IO.Path]::Combine($modulePath,$expectedModule.name)
                foreach($directory in @([IO.Path]::Combine($moduleBase,$expectedModule.version),$moduleBase)) {
                    $candidate=[IO.Path]::GetFullPath([IO.Path]::Combine($directory,$expectedModule.name+'.psd1'))
                    if ($seen.ContainsKey($candidate)) {continue};$seen[$candidate]=$true
                    $probe=Invoke-SmalOptionalRead 'guarded-exact-dependency-manifest' {
                        # Guard at the dependency entry, before the public reader can open content.
                        $checked=Assert-SmalV4PublicPath $candidate
                        Get-SmalV5PublicUnit $checked
                    }
                    $candidates+=@{path=(ConvertTo-SmalPublicField $candidate);read=$probe}
                }
            }
            $matches=@(foreach($candidate in $candidates) {
                if ($candidate.read.status -cne 'complete') {continue}
                $unit=$candidate.read.value;$fields=@{}
                if ($unit.file.parseStatus -cne 'parsed-not-executed') {continue}
                foreach($declaration in @($unit.declarations)) {
                    if ($declaration.declaration.status -ceq 'literal' -and $declaration.declaration.value.status -ceq 'available') {$fields[$declaration.name]=$declaration.declaration.value.value}
                }
                if ($fields.ModuleVersion -ceq $expectedModule.version -and $fields.GUID -ieq $expectedModule.guid -and -not [string]::IsNullOrEmpty($fields.RootModule)) {
                    @{manifest=$unit;path=$candidate.path.value;rootDeclaration=$fields.RootModule}
                }
            })
            if ($matches.Count -ne 1) {return @{status='unavailable-exact-dependency-identity';name=$expectedModule.name;matches=$matches.Count;candidates=$candidates}}
            $selected=$matches[0];$directory=[IO.Path]::GetDirectoryName($selected.path)
            $root=[IO.Path]::GetFullPath([IO.Path]::Combine($directory,$selected.rootDeclaration))
            $prefix=$directory.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
            if (-not $root.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'Dependency root escapes guarded public module directory'}
            $root=Assert-SmalV4PublicPath $root
            @{status='static-public-dependency-only';name=$expectedModule.name;version=$expectedModule.version;guid=$expectedModule.guid;
              manifest=$selected.manifest;root=(Get-SmalV5PublicUnit $root);moduleImported=$false;candidates=$candidates}
        }
    })
    @{status='public-dependency-qualification-input';mocRootContract='separate hash-pinned mocPublicContract field';common=$common;dependencies=$dependencies;
      discoveryPolicy='lexical-path-then-guarded-same-parse-identity';maximumRoots=8;maximumCandidateManifestsPerDependency=16;
      importAdmitted=$false;getterAdmitted=$false;accountResetPerformed=$false;clientAuthSetupPerformed=$false;infrastructureMutationPerformed=$false}
}

'@
. ([scriptblock]::Create($foundationV3Definitions))
$phase = 'host-identity'
try {
if ($env:COMPUTERNAME -cne 'LocalBox-Client') { throw 'Unexpected host' }
$targets = @(@{ name = 'LB-NODE01'; id = '3adff629-2f67-449b-ab32-8a8748c46f34' }, @{ name = 'LB-NODE02'; id = '12a44e0c-cc08-4c4c-a812-fa0b56efdbc3' }, @{ name = 'LB-NODE03'; id = '5b6eba15-fa82-4e12-9e45-5ffbcd48c8a9' })
$boot = 'C:\ProgramData\AzureLocalBox\Bootstrap\guest-bootstrap-20261028-01'
$bundle = Get-Content (Join-Path $boot 'bundle.json') -Raw | ConvertFrom-Json
$entry = @($bundle.files | Where-Object name -CEQ 'smal-guest-secret-functions.ps1'); $helper = Join-Path $boot 'smal-guest-secret-functions.ps1'
if ($entry.Count -ne 1 -or (Get-FileHash $helper).Hash -cne $entry[0].sha256) { throw 'Secret helper differs' }
. $helper
$store = 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\secrets'
$bindings = Get-Content 'C:\ProgramData\AzureLocalBox\Bootstrap\cluster-prereqs-20261028-01\credential-bindings.json' -Raw | ConvertFrom-Json
$nodes = @(foreach ($target in $targets) {
    $vm = Get-VM -Id $target.id; $binding = $bindings.nodes.PSObject.Properties[$target.name].Value
    if ($vm.Name -cne $target.name -or $vm.State.ToString() -ne 'Running' -or $binding.vmId -ine $target.id -or $binding.role -cne 'cluster-node-admin' -or $binding.secretDirectory -cne $store -or $binding.loginVerified -ne $true) { throw 'Exact running guest/credential binding differs' }
    $secure = Read-LabGuestSecureSecret -SecretDirectory $store -Role 'cluster-node-admin'; $session = $null
    try {
        $phase = $target.name + '-credential-session'
        # Documented post-deployment name of RID 500. One attempt, no fallback or reset.
        $session = New-PSSession -VMId $vm.Id -Credential ([pscredential]::new(($vm.Name + '\ASBuiltInAdmin'), $secure)) -ErrorAction Stop
        $phase = $target.name + '-cluster-storage-inspection'
        $guest = Invoke-Command -Session $session -ArgumentList $target.name -ErrorAction Stop -ScriptBlock {
            param($ExpectedName)
            $ErrorActionPreference = 'Stop'
            if ($env:COMPUTERNAME -cne $ExpectedName) { throw 'Guest identity differs' }
            $admin = Get-LocalUser -Name ASBuiltInAdmin
            if (-not $admin.Enabled -or -not $admin.SID.Value.EndsWith('-500') -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $admin.SID.Value) { throw 'Expected existing RID 500 identity differs' }
            $cluster = Get-Cluster -Name smal-localbox01 -ErrorAction Stop
            $quorum = Get-ClusterQuorum -Cluster $cluster
            $s2d = Get-ClusterStorageSpacesDirect -Node $ExpectedName
            $pools = @(Get-StoragePool | Where-Object IsPrimordial -EQ $false | ForEach-Object {
                $pool = $_
                @{ name = $pool.FriendlyName; uniqueId = $pool.UniqueId; health = $pool.HealthStatus.ToString(); operationalStatus = @($pool.OperationalStatus | ForEach-Object ToString); size = $pool.Size; allocated = $pool.AllocatedSize;
                   members = @($pool | Get-PhysicalDisk | ForEach-Object { @{ uniqueId = $_.UniqueId; size = $_.Size; usage = $_.Usage.ToString(); health = $_.HealthStatus.ToString(); mediaType = $_.MediaType.ToString() } }) }
            })
            @{ name = $env:COMPUTERNAME; observedAdmin = @{ name = $admin.Name; sid = $admin.SID.Value; enabled = $admin.Enabled }; domain = (Get-CimInstance Win32_ComputerSystem).Domain; domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole;
               clusterName = $cluster.Name; clusterNodes = @(Get-ClusterNode -Cluster $cluster | ForEach-Object { @{ name = $_.Name; state = $_.State.ToString(); nodeWeight = $_.NodeWeight; dynamicWeight = $_.DynamicWeight } });
               quorumType = $quorum.QuorumType.ToString(); quorumResourceName = $(if ($quorum.QuorumResource) { [string]$quorum.QuorumResource.Name } else { $null });
               storageSpacesDirectState = [string]$s2d.State; storagePools = $pools;
               virtualDisks = @(Get-VirtualDisk | ForEach-Object { @{ name = $_.FriendlyName; uniqueId = $_.UniqueId; health = $_.HealthStatus.ToString(); size = $_.Size; footprint = $_.FootprintOnPool; resiliency = $_.ResiliencySettingName; dataCopies = $_.NumberOfDataCopies; provisioning = $_.ProvisioningType.ToString() } });
               csv = @(Get-ClusterSharedVolume -Cluster $cluster | ForEach-Object { @{ name = $_.Name; state = $_.State.ToString(); owner = [string]$_.OwnerNode.Name;
                   volumes = @($_.SharedVolumeInfo | ForEach-Object { @{ path = $_.FriendlyVolumeName; size = $_.Partition.Size; free = $_.Partition.FreeSpace } }) } });
               storageJobs = @(Get-StorageJob | ForEach-Object { @{ name = $_.Name; state = [string]$_.JobState; percentComplete = $_.PercentComplete } });
               localDisks = @(Get-Disk | ForEach-Object { @{ uniqueId = $_.UniqueId; size = $_.Size; isBoot = $_.IsBoot; isSystem = $_.IsSystem } });
               encryption = @(Get-BitLockerVolume | ForEach-Object { @{ mountPoint = $_.MountPoint; volumeType = [string]$_.VolumeType; protectionStatus = [string]$_.ProtectionStatus; encryptionPercentage = $_.EncryptionPercentage; volumeStatus = [string]$_.VolumeStatus } });
               clusterGroups = @(Get-ClusterGroup -Cluster $cluster | ForEach-Object { @{ name = $_.Name; state = $_.State.ToString(); owner = [string]$_.OwnerNode.Name } });
               nestedVms = @(Get-VM | ForEach-Object { @{ name = $_.Name; id = $_.Id.ToString(); state = $_.State.ToString(); memoryBytes = $_.MemoryAssigned } });
               defenderEnabled = (Get-MpComputerStatus).RealTimeProtectionEnabled; firewallEnabled = @(Get-NetFirewallProfile | Where-Object Enabled -NE $true).Count -eq 0;
               services = @(Get-Service -Name himds,GCArcService,ExtensionService,vmms,clussvc -ErrorAction SilentlyContinue | ForEach-Object { @{ name = $_.Name; state = $_.Status.ToString() } }) }
        }
        # Base observation completed above. Optional failures cannot replace it.
        $foundation = $null
        try {
            $foundation = Invoke-Command -Session $session -ArgumentList $target.name,$foundationV3Definitions -ErrorAction Stop -ScriptBlock {
                param($ExpectedName, $V3Definitions)
                . ([scriptblock]::Create($V3Definitions))
                $ErrorActionPreference = 'Stop'
                # Public metadata only. Definitions are embedded in the reviewed canonical observer.
                # No module import/install, getter invocation, default evaluation or source-body export.
                function ConvertTo-SmalPublicField([string]$Value) {
                    if ([string]::IsNullOrEmpty($Value)) { return @{ status = 'unavailable' } }
                    if ($Value.Length -gt 2048 -or $Value -cmatch '-----BEGIN|\beyJ[A-Za-z0-9_-]{15,}\.|(?i:password|access_token|refresh_token)') {
                        $sha = [Security.Cryptography.SHA256]::Create()
                        try { $digest = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))).Replace('-', '').ToLowerInvariant() }
                        finally { $sha.Dispose() }
                        return @{ status = 'withheld'; sha256 = $digest }
                    }
                    return @{ status = 'available'; value = $Value }
                }
                function Invoke-SmalOptionalRead([string]$Phase, [scriptblock]$Read) {
                    try { return @{ status = 'complete'; phase = $Phase; value = (& $Read) } }
                    catch { return @{ status = 'failed'; phase = $Phase;
                        errorType = (ConvertTo-SmalPublicField $_.Exception.GetType().FullName);
                        errorCategory = [string]$_.CategoryInfo.Category; sourceLine = [int]$_.InvocationInfo.ScriptLineNumber } }
                }
                function Get-SmalStaticPublicSignatures($Module, [string[]]$Exports) {
                    # Do not resolve types, attributes, defaults, dynamic parameters or nested-module code.
                    $path = [string]$Module.Path
                    if ([IO.Path]::GetExtension($path) -ine '.psm1') {
                        if (-not [string]::IsNullOrEmpty([string]$Module.RootModule)) {
                            $path = [IO.Path]::GetFullPath([IO.Path]::Combine([string]$Module.ModuleBase, [string]$Module.RootModule))
                        }
                    }
                    $base = [IO.Path]::GetFullPath([string]$Module.ModuleBase).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
                    if (-not $path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($path) -ine '.psm1') {
                        return @{ status = 'unavailable-non-script-or-outside-module-root'; complete = $false; signatures = @() }
                    }
                    if (([IO.FileInfo]::new($path)).Length -gt 2097152) {
                        return @{ status = 'unavailable-source-size-bound'; complete = $false; signatures = @() }
                    }
                    $tokens = $null; $parseErrors = $null
                    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
                    if (@($parseErrors).Count) {
                        return @{ status = 'unavailable-static-parse'; complete = $false; parseIssueCount = @($parseErrors).Count; signatures = @() }
                    }
                    $definitions = @($ast.FindAll({ param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -like 'Get-Moc*' }, $true))
                    $rows = @(foreach ($function in $definitions) {
                        if ($Exports -notcontains $function.Name) { continue }
                        $parameters = @($function.Parameters)
                        if (-not $parameters.Count -and $null -ne $function.Body.ParamBlock) { $parameters = @($function.Body.ParamBlock.Parameters) }
                        @{ name = (ConvertTo-SmalPublicField $function.Name); status = 'declared-static-only';
                           dynamicParameters = $(if ($null -ne $function.Body.DynamicParamBlock) { 'unavailable-not-evaluated' } else { 'not-declared-in-this-function' });
                           parameterSets = 'unavailable-not-resolved';
                           parameters = @(foreach ($parameter in $parameters) {
                               if ($null -eq $parameter) { continue }
                               @{ name = (ConvertTo-SmalPublicField $parameter.Name.VariablePath.UserPath);
                                  declaredTypes = @($parameter.Attributes | Where-Object { $_ -is [Management.Automation.Language.TypeConstraintAst] } | ForEach-Object { ConvertTo-SmalPublicField $_.TypeName.FullName }) }
                           }) }
                    })
                    return @{ status = 'static-metadata-only'; complete = $false; sourcePath = (ConvertTo-SmalPublicField $path);
                        matchedPublicCount = $rows.Count; signatures = $rows }
                }
                function Get-SmalImportedSignature($Command) {
                    $functionAst = $null
                    if ($Command -is [Management.Automation.FunctionInfo]) {
                        $functionAst = $Command.ScriptBlock.Ast
                        if ($functionAst -is [Management.Automation.Language.FunctionDefinitionAst]) { $functionAst = $functionAst.Body }
                    }
                    if (($null -ne $functionAst -and $null -ne $functionAst.DynamicParamBlock) -or
                        ($Command -is [Management.Automation.CmdletInfo] -and @($Command.ImplementingType.GetInterfaces() | Where-Object FullName -EQ 'System.Management.Automation.IDynamicParameters').Count)) {
                        return @{ status = 'unavailable-dynamic-not-evaluated'; complete = $false }
                    }
                    $sets = @($Command.ParameterSets | ForEach-Object {
                            @{ name = (ConvertTo-SmalPublicField $_.Name); parameters = @($_.Parameters | ForEach-Object {
                                @{ name = (ConvertTo-SmalPublicField $_.Name); type = (ConvertTo-SmalPublicField $_.ParameterType.FullName);
                                   mandatory = [bool]$_.IsMandatory }
                            }) }
                        })
                    $unavailable = 0
                    foreach ($set in $sets) {
                        if ($set.name.status -cne 'available') { $unavailable++ }
                        foreach ($parameter in $set.parameters) {
                            if ($parameter.name.status -cne 'available' -or $parameter.type.status -cne 'available') { $unavailable++ }
                        }
                    }
                    return @{ status = 'public-static-metadata'; complete = ($unavailable -eq 0);
                        unavailableFieldCount = $unavailable; parameterSets = $sets }
                }
                function Get-SmalMocPublicMetadata {
                    # Scope-local preference. Never change the existing session/global autoload setting.
                    $PSModuleAutoLoadingPreference = 'None'
                    $WarningPreference = 'SilentlyContinue'; $InformationPreference = 'SilentlyContinue'
                    $VerbosePreference = 'SilentlyContinue'; $DebugPreference = 'SilentlyContinue'; $ProgressPreference = 'SilentlyContinue'
                    $inventoryIssues = @(); $commandIssues = @()
                    $importedModules = @(Get-Module -ErrorAction Stop)
                    $available = @(Get-Module -ListAvailable -ErrorAction SilentlyContinue -ErrorVariable inventoryIssues)
                    $commands = @(Get-Command Get-Moc* -ListImported -CommandType Function,Cmdlet -ErrorAction SilentlyContinue -ErrorVariable commandIssues)
                    $modules = @(foreach ($module in $available) {
                        $exportsProbe = Invoke-SmalOptionalRead 'module-public-export-metadata' { @($module.ExportedCommands.Keys | Where-Object { $_ -like 'Get-Moc*' }) }
                        $exports = @(); if ($exportsProbe.status -eq 'complete') { $exports = @($exportsProbe.value) }
                        if ($module.Name -notlike '*Moc*' -and -not $exports.Count -and $exportsProbe.status -eq 'complete') { continue }
                        $loaded = @($importedModules | Where-Object { $_.Name -ceq $module.Name -and [string]$_.Version -ceq [string]$module.Version -and $_.ModuleBase -ieq $module.ModuleBase }).Count -gt 0
                        @{ name = (ConvertTo-SmalPublicField ([string]$module.Name)); version = (ConvertTo-SmalPublicField ([string]$module.Version));
                           path = (ConvertTo-SmalPublicField ([string]$module.Path)); moduleBase = (ConvertTo-SmalPublicField ([string]$module.ModuleBase));
                           rootModule = (ConvertTo-SmalPublicField ([string]$module.RootModule));
                           importState = $(if ($loaded) { 'imported-exact-name-version-base' } else { 'not-imported' });
                           publicExportsRead = @{ status = [string]$exportsProbe.status; phase = 'module-public-export-metadata';
                               publicGetterCount = $exports.Count; errorCategory = [string]$exportsProbe.errorCategory; sourceLine = [int]$exportsProbe.sourceLine };
                           publicGetters = @($exports | ForEach-Object { ConvertTo-SmalPublicField ([string]$_) });
                           staticSignatures = (Invoke-SmalOptionalRead 'module-static-public-signatures' { Get-SmalStaticPublicSignatures $module $exports }) }
                    })
                    $imported = @(foreach ($command in $commands) {
                        @{ name = (ConvertTo-SmalPublicField ([string]$command.Name)); commandType = [string]$command.CommandType;
                           moduleName = (ConvertTo-SmalPublicField ([string]$command.ModuleName));
                           moduleVersion = (ConvertTo-SmalPublicField ([string]$command.Module.Version));
                           modulePath = (ConvertTo-SmalPublicField ([string]$command.Module.Path));
                           signatures = (Invoke-SmalOptionalRead 'imported-command-public-signature' { Get-SmalImportedSignature $command }) }
                    })
                    return @{ status = 'metadata-only'; inventoryScope = 'PSModulePath-visible-list-available';
                        installedModuleReadStatus = $(if ($inventoryIssues.Count) { 'partial-read' } elseif ($modules.Count) { 'visible-public-candidates' } else { 'no-visible-public-match-not-absence' });
                        importedReadStatus = $(if ($commandIssues.Count) { 'partial-read' } elseif ($imported.Count) { 'imported-getters-observed' } else { 'no-imported-getters-not-absence' });
                        inventoryIssueCount = $inventoryIssues.Count; importedIssueCount = $commandIssues.Count;
                        inventoryIssues = @($inventoryIssues | ForEach-Object { @{ phase = 'installed-module-list-available'; errorType = (ConvertTo-SmalPublicField $_.Exception.GetType().FullName); errorCategory = [string]$_.CategoryInfo.Category } });
                        importedIssues = @($commandIssues | ForEach-Object { @{ phase = 'imported-getter-list'; errorType = (ConvertTo-SmalPublicField $_.Exception.GetType().FullName); errorCategory = [string]$_.CategoryInfo.Category } });
                        inventoryTraversalComplete = ($inventoryIssues.Count -eq 0); importedReadComplete = ($commandIssues.Count -eq 0);
                        publicExportReadsComplete = (@($modules | Where-Object { $_.publicExportsRead.status -cne 'complete' }).Count -eq 0);
                        modules = $modules; importedGetters = $imported;
                        getterInvocationPerformed = $false; moduleImportPerformed = $false;
                        signaturesCompleteForInvocation = $false; readinessFactsComplete = $false;
                        imageState = 'not-observed'; allocationOwnershipState = 'not-observed' }
                }
                function Get-SmalFoundationSupplement([string]$ExpectedName) {
                    if ($env:COMPUTERNAME -cne $ExpectedName) { throw 'Supplement identity differs' }
                    @{ status = 'optional-read-projections'; readinessFactsComplete = $false;
                       mocMetadata = @{ status = 'not-repeated-use-preserved-v2-receipt'; readinessFactsComplete = $false };
                       mocPublicContract = (Invoke-SmalOptionalRead 'exact-moc-public-contract' { Get-SmalV3MocContract });
                       dependencyQualification = (Invoke-SmalOptionalRead 'exact-moc-public-dependencies' { Get-SmalV5Dependencies });
                       computeProperties = (Invoke-SmalOptionalRead 'guest-compute-property-discovery' { Get-SmalV3Compute });
                       lifecycleCommandMetadata = (Invoke-SmalOptionalRead 'guest-lifecycle-metadata-only' { Get-SmalV3LifecycleMetadata });
                       nestedVmDisks = (Invoke-SmalOptionalRead 'nested-vm-disk-metadata' {
                           @(Get-VM | ForEach-Object {
                               $nested = $_
                               @{ name = (ConvertTo-SmalPublicField ([string]$nested.Name)); id = [string]$nested.Id;
                                  state = [string]$nested.State; cpu = [int]$nested.ProcessorCount;
                                  memoryBytes = [long]$nested.MemoryAssigned; startupMemoryBytes = [long]$nested.MemoryStartup;
                                  disks = (Invoke-SmalOptionalRead 'nested-vm-attached-vhd-metadata' {
                                      @(Get-VMHardDiskDrive -VM $nested | ForEach-Object {
                                          $disk = Get-VHD -Path $_.Path
                                          @{ path = (ConvertTo-SmalPublicField ([string]$_.Path)); id = [string]$disk.DiskIdentifier;
                                             maximumBytes = [long]$disk.Size; occupiedBytes = [long]$disk.FileSize; type = [string]$disk.VhdType }
                                      })
                                  }) }
                           })
                       });
                       routes = (Invoke-SmalOptionalRead 'guest-selected-route-metadata' {
                           @(foreach ($destination in @('10.64.0.100','10.64.0.180')) {
                               @{ destination = $destination; rows = @(Find-NetRoute -RemoteIPAddress $destination | ForEach-Object {
                                   @{ interfaceIndex = [int]$_.InterfaceIndex; interfaceAlias = (ConvertTo-SmalPublicField ([string]$_.InterfaceAlias));
                                      ipAddress = [string]$_.IPAddress; destinationPrefix = [string]$_.DestinationPrefix;
                                      nextHop = [string]$_.NextHop; routeMetric = [int]$_.RouteMetric }
                               }) }
                           })
                       }) }
                }
                Get-SmalFoundationSupplement $ExpectedName
            }
        } catch {
            $foundation = @{ status = 'failed'; phase = 'optional-guest-supplement'; readinessFactsComplete = $false;
                errorCategory = [string]$_.CategoryInfo.Category; sourceLine = [int]$_.InvocationInfo.ScriptLineNumber }
        }
        $profile = @{ status = 'unavailable' }
        try { $profile = @{ status = 'complete'; cpu = [int]$vm.ProcessorCount; startupMemoryBytes = [long]$vm.MemoryStartup;
                dynamicMemory = [bool](Get-VMMemory -VM $vm).DynamicMemoryEnabled } }
        catch { $profile = @{ status = 'failed'; phase = 'optional-host-guest-profile'; errorCategory = [string]$_.CategoryInfo.Category } }
        @{ name = $vm.Name; vmId = $vm.Id.ToString(); state = [string]$vm.State; guest = $guest;
           foundationSupplement = $foundation; foundationHostProfile = $profile }
    } finally { if ($session) { Remove-PSSession $session }; $secure.Dispose() }
})
$phase = 'outer-storage-inspection'
$base = @{ atUtc = [datetime]::UtcNow.ToString('o'); observationStatus = 'complete-read-only'; nodes = $nodes; outerPool = @(Get-StoragePool -FriendlyName LocalBoxPool | ForEach-Object { @{ uniqueId = $_.UniqueId; health = $_.HealthStatus.ToString(); memberCount = @($_ | Get-PhysicalDisk).Count } });
   volumes = @(Get-Volume | Where-Object DriveLetter -In @('C','V','W','X') | ForEach-Object { @{ letter = [string]$_.DriveLetter; uniqueId = $_.UniqueId; size = $_.Size; free = $_.SizeRemaining; health = $_.HealthStatus.ToString() } });
   credentialsReset = $false; mutationPerformed = $false; platformReadinessVerified = $false }
try {
    $base.foundationOuter = @{ status = 'complete'; cpu = [int](Get-VMHost).LogicalProcessorCount;
        memoryBytes = [long](Get-VMHost).MemoryCapacity;
        guests = @(Get-VM | ForEach-Object { @{ id = [string][guid]$_.Id;
            cpu = [int]$_.ProcessorCount; startupMemoryBytes = [long]$_.MemoryStartup; state = [string]$_.State } }) }
} catch { $base.foundationOuter = @{ status = 'failed'; phase = 'optional-outer-profile'; errorCategory = [string]$_.CategoryInfo.Category } }
$base.foundationV3OuterCompute = Invoke-SmalOptionalRead 'outer-compute-property-discovery' { Get-SmalV3Compute }
$base.foundationV3OuterRoutes = Invoke-SmalOptionalRead 'outer-source-route-discovery' { Get-SmalV3OuterRoutes }
$base.foundationV3LifecycleMetadata = Invoke-SmalOptionalRead 'outer-lifecycle-metadata-only' { Get-SmalV3LifecycleMetadata }
$base.foundationAdmission = @{ readinessFactsComplete = $false; imageState = 'not-observed'; allocationOwnershipState = 'not-observed' }
$base | ConvertTo-Json -Depth 32 -Compress
} catch {
    # Never emit raw exception messages, command arguments or credential objects.
    @{ observationStatus = 'failed-safe-diagnostic'; phase = $phase; errorType = $_.Exception.GetType().Name;
       errorCategory = [string]$_.CategoryInfo.Category; sourceLine = $_.InvocationInfo.ScriptLineNumber;
       credentialsReset = $false; mutationPerformed = $false; platformReadinessVerified = $false } | ConvertTo-Json -Compress
}
