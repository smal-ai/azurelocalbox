# Projection/capture helpers only. No module load, credentials, configuration or effects.
function Read-InitialField($value, [string]$name) {
    if ($null -eq $value) { return $null }
    if ($value -is [Collections.IDictionary]) { return $value[$name] }
    $property = $value.PSObject.Properties[$name]
    if ($null -ne $property) { return $property.Value }
    return $null
}
function Select-InitialFields($value, [string[]]$names) {
    $row = @{}
    foreach ($name in $names) { $row[$name] = Read-InitialField $value $name }
    return $row
}
function Read-InitialQuery([string]$name, [scriptblock]$query) {
    $row = @{ name = $name; beganAtUtc = [datetime]::UtcNow.ToString('o'); complete = $false; count = $null; pages = 1; data = @(); errorType = $null }
    try {
        if ([datetime]::UtcNow.AddSeconds(15) -ge [datetime]::Parse('2026-11-08T22:00:00Z').ToUniversalTime()) { throw 'Initial read deadline reached' }
        $row.data = @(& $query)
        $row.count = $row.data.Count
        $row.complete = $true
    } catch { $row.errorType = $_.Exception.GetType().FullName }
    $row.finishedAtUtc = [datetime]::UtcNow.ToString('o')
    return $row
}
function Read-InitialCommand($command) {
    if ($null -eq $command) { return $null }
    return @{ name = $command.Name; module = $command.ModuleName; version = $(if ($command.Module) { $command.Module.Version.ToString() } else { $null })
        outputTypes = @($command.OutputType | ForEach-Object { $_.Name })
        parameterSets = @($command.ParameterSets | ForEach-Object {
            $safe = @($_.Parameters | Where-Object { $_.Name -notmatch '(?i)password|credential|token|secret|certificate|kube|config|key' -or $_.Name -match '^(ContinuationToken|NextPageToken|PageToken|SkipToken)$' })
            $omitted = @($_.Parameters | Where-Object { $_.Name -notin @($safe.Name) })
            @{ name = $_.Name; isDefault = $_.IsDefault; signatureComplete = $omitted.Count -eq 0; parametersOmittedCount = $omitted.Count; mandatoryParametersOmittedCount = @($omitted | Where-Object IsMandatory).Count; parameters = @($safe | ForEach-Object {
                @{ name = $_.Name; type = $_.ParameterType.FullName; mandatory = $_.IsMandatory; position = $_.Position; valueFromPipeline = $_.ValueFromPipeline; valueFromPipelineByPropertyName = $_.ValueFromPipelineByPropertyName }
            }) }
        }) }
}
function Assert-InitialNode([string]$expected) {
    $admin = Get-LocalUser -Name ASBuiltInAdmin
    if ($env:COMPUTERNAME -cne $expected -or -not $admin.Enabled -or -not $admin.SID.Value.EndsWith('-500') -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $admin.SID.Value) {
        throw 'Exact node/RID 500 identity differs'
    }
}
