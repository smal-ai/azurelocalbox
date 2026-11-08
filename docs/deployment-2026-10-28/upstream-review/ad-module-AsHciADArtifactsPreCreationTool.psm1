<#############################################################
 #                                                           #
 # Copyright (C) Microsoft Corporation. All rights reserved. #
 #                                                           #
 #############################################################>

# Script to create AD objects prior to azurestack hci deployment driver execution.
#
#
# Objects to be created if not available:
#  - Hci Organizational Unit with group policy inheritance blocked.
#  - Hci LCM user account (it not available).
#
# This script should be run by a user that has privileges to create OU and LCM user.
#
# Parameter Ex:
#  -AsHciOUName "OU=Hci001,OU=HciDeployments,DC=v,DC=masd,DC=stbtest,DC=microsoft,DC=com" [Hci001 OU will be created under OU=HciDeployments,DC=v,DC=masd,DC=stbtest,DC=microsoft,DC=com]
#
# Usage Ex:
#
#
# New-HciAdObjectsPreCreation -AzureStackLCMUserCredential (get-credential) -AsHciOUName "OU=Hci001,DC=v,DC=masd,DC=stbtest,DC=microsoft,DC=com"


$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

<#
 .Synopsis
  Tests hci organization unit.

 .Parameter AsHciOUPath
  The hci ou path.
#>

function Test-AsHciOU
{
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $AsHciOUPath
    )

    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

    try
    {
        if (-not [adsi]::Exists("LDAP://$AsHciOUPath"))
        {
            Write-Error "'$AsHciOUPath' does not exist. Exception ::  $_"
        }
        Write-Verbose "Successfully verified $AsHciOUPath"
    }
    catch
    {
        Write-Error "Unable to verify organization unit '$AsHciOUPath'. Exception ::  $_"
    }
}


<#
 .Synopsis
  Creates HCI organization unit in a given AD domain.

 .Parameter DomainOUPath
  The AD domain organization unit path

 .Parameter HciOUName
  The HCI organizational unit name.
#>

function New-AsHciOrganizationalUnit
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $DomainOUPath,

        [Parameter(Mandatory = $true)]
        [String]
        $OUName
    )

    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

    $ouPath = Get-ADOrganizationalUnit -SearchBase $DomainOUPath -Filter { Name -eq $OUName } | Select-Object DistinguishedName
    if ($ouPath)
    {
        Write-verbose "Hci organizational unit '$OUName' exists within the '$DomainOUPath'."
    }
    else
    {
        try
        {
            New-ADOrganizationalUnit -Name $OUName -Path $DomainOUPath
            Write-Verbose "Successfully created $OUName organization unit within the '$DomainOUPath' "
        }
        catch
        {
            Write-Error "Failed to create organization unit. Exception :: $_"
        }
    }
}


<#
 .Synopsis
  Remove hci organization unit.

 .Parameter AsHciOUPath
  The hci ou path.
#>

function Remove-AsHciOU
{
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $AsHciOUPath
    )

    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

    try
    {
        if ([adsi]::Exists("LDAP://$AsHciOUPath"))
        {
            Get-ADOrganizationalUnit -Identity $AsHciOUPath |
                Set-ADObject -ProtectedFromAccidentalDeletion:$false -PassThru |
                Remove-ADOrganizationalUnit -Recursive -Confirm:$false
            Write-Verbose "Successfully deleted $AsHciOUPath"
        }
        else
        {
            Write-Verbose "OU $AsHciOUPath not found, skipping the remove operation."
        }
    }
    catch
    {
        Write-Error "Unable to delete '$AsHciOUPath'. Exception ::  $_"
    }
}

<#
 .Synopsis
  Creates hci lifecycle management users under hci users organization unit path.

 .Parameter AsHciLCMUserName
  The azure stack hci lifecycle management user names

 .Parameter AsHciLCMUserPassword
  The azure stack hci user password.

 .Parameter HciUsersOUPath
  The hci users organization unit path object.

#>

function New-AsHciUser
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    Param
    (
        [Parameter(Mandatory = $true)]
        [String]
        $AsHciLCMUserName,

        [Parameter(Mandatory = $true)]
        [SecureString]
        $AsHciUserPassword,

        [Parameter(Mandatory = $true)]
        [Microsoft.ActiveDirectory.Management.ADOrganizationalUnit]
        $AsHciUsersOUPath
    )

    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

    try
    {
        $user = Get-ADUser -SearchBase $AsHciUsersOUPath -Filter { Name -eq $AsHciLCMUserName }
        if ($user)
        {
            Write-verbose "$AsHciLCMUserName exists under $AsHciUsersOUPath, skipping."
        }
        else
        {
            New-ADUser -Name $AsHciLCMUserName -AccountPassword $AsHciUserPassword -UserPrincipalName "$AsHciLCMUserName" -Enabled $true -PasswordNeverExpires $true -path $AsHciUsersOUPath.DistinguishedName
            Write-Verbose "Successfully created '$AsHciLCMUserName' within the '$AsHciUsersOUPath'"
        }
    }
    catch
    {
        if ($_ -match 'The operation failed because UPN value provided for addition/modification is not unique forest-wide')
        {
            Write-verbose "UserPrincipalName '$AsHciLCMUserName' already exists, skipping."
        }
        elseif ($_ -match 'The specified account already exists')
        {
            Write-verbose "$AsHciLCMUserName already exists, skipping."
        }
        else
        {
            Write-Error "Unable to create $AsHciLCMUserName. Exception :: $_ "
        }
    }
}

<#
 .Synopsis
  Grants full access permissions of hci organization unit to hci lifecycle management user.

 .Parameter AsHciLCMUserName
  The hci lifecycle management user name.

 .Parameter AsHciOUPath
  The hci organization unit path.
#>
function Grant-HciOuPermissionsToHciLCMUser
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]
        $AsHciLCMUserName,

        [Parameter(Mandatory = $true)]
        [Microsoft.ActiveDirectory.Management.ADOrganizationalUnit]
        $AsHciOUPath

    )

    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
    try
    {
        $ouPath = "AD:\$($AsHciOUPath.DistinguishedName)"

        $userSecurityIdentifier = Get-ADuser -Identity $AsHciLCMUserName
        $userSID = [System.Security.Principal.SecurityIdentifier] $userSecurityIdentifier.SID
        $acl = Get-Acl -Path $ouPath
        $userIdentityReference = [System.Security.Principal.IdentityReference] $userSID
        $adRight = [System.DirectoryServices.ActiveDirectoryRights]::CreateChild -bor [System.DirectoryServices.ActiveDirectoryRights]::DeleteChild
        $genericAllRight = [System.DirectoryServices.ActiveDirectoryRights]::GenericAll
        $readPropertyRight = [System.DirectoryServices.ActiveDirectoryRights]::ReadProperty
        $type = [System.Security.AccessControl.AccessControlType]::Allow 
        $inheritanceType = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All 
        $allObjectType = [System.Guid]::Empty
        #Computers object guid
        $computersObjectType = [System.Guid]::New('bf967a86-0de6-11d0-a285-00aa003049e2')
        #msFVE-RecoveryInformation guid
        $msfveRecoveryGuid = [System.Guid]::New('ea715d30-8f53-40d0-bd1e-6109186d782c')

        $rule1 = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($userIdentityReference, $adRight, $type, $computersObjectType, $inheritanceType)
        $rule2 = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($userIdentityReference, $readPropertyRight, $type, $allObjectType , $inheritanceType)
        $rule3 = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($userIdentityReference, $genericAllRight, $type, $inheritanceType, $msfveRecoveryGuid)
        $acl.AddAccessRule($rule1)
        $acl.AddAccessRule($rule2)
        $acl.AddAccessRule($rule3)

        Set-Acl -Path $ouPath -AclObject $acl
        Write-Verbose "Access permissions to '$($AsHciOUPath.DistinguishedName)' have been successfully granted to '$AsHciLCMUserName'"
    }
    catch
    {
        Write-Error "Failed to grant access permissions '$($AsHciOUPath.DistinguishedName)' to '$AsHciLCMUserName'. Error :: $_"
    }
}


<#
 .Synopsis
  Blocks gpo inheritance to Hci ou

 .Parameter HciOUs
  List of hci ou
#>

function Block-GPInheritance
{
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [Microsoft.ActiveDirectory.Management.ADOrganizationalUnit[]]
        $AsHciOUs
    )

    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
    foreach ($asHciOu in $AsHciOUs)
    {
        try
        {
            $gpInheritance = Get-GPInheritance -Target $($asHciOu.DistinguishedName)
            if (-not $gpInheritance.GpoInheritanceBlocked)
            {
                $gpInheritance = Set-GPInheritance -Target $($asHciOu.DistinguishedName) -IsBlocked Yes
            }
            Write-Verbose "Gpo inheritance blocked for '$($asHciOu.DistinguishedName)', inheritance blocked state is : $($gpInheritance.GpoInheritanceBlocked)"
        }
        catch
        {
            Write-Error "Failed to block gpo inheritance for '$($asHciOu.DistinguishedName)'. Error :: $_"
        }
    }
}


<#
 .Synopsis
  Cmdlet to Create required active directory objects.

 .Parameter AzureStackLCMUserCredential
  Lifecycle management credentials.

 .Parameter AsHciOUName
  Organizational unit.

#>

function New-HciAdObjectsPreCreation
{
    [CmdletBinding(
        DefaultParameterSetName= 'Deploy'
    )]
    Param(
        [Parameter(ParameterSetName = 'Deploy', Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [PSCredential] $AzureStackLCMUserCredential,

        [Parameter(ParameterSetName = 'Deploy', Mandatory=$true)]
        [validatePattern('^(OU=[^,]+,)+(DC=[^,]+,)*DC=[^,]+$')]
        [ValidateNotNullOrEmpty()]
        [string] $AsHciOUName
    )

    # import required modules
    $modules = @('ActiveDirectory','GroupPolicy','Kds')
    foreach ($module in $modules)
    {
        Import-Module -Name $module -Verbose:$false -ErrorAction Stop | Out-Null
    }

    $hciParentOUPath = $AsHciOUName.Split(",",2)[1]
    # Test hci parent ou path exists or not."
    Test-AsHciOU -AsHciOUPath $hciParentOUPath -Verbose

    $hciOUName = ($AsHciOUName.Split(",",2)[0]).split("=")[1]
    # Create Hci organization unit
    New-AsHciOrganizationalUnit -DomainOUPath $hciParentOUPath -OUName $hciOUName -Verbose
    $asHciOUPath = Get-ADOrganizationalUnit -SearchBase $hciParentOUPath -Filter { Name -eq $hciOUName }

    # Create Hci lifecycle management user under Hci users OU path
    $asHciLCMUserName = $AzureStackLCMUserCredential.UserName
    $asHciLCMUserPassword = $AzureStackLCMUserCredential.Password
    New-AsHciUser -AsHciLCMUserName $asHciLCMUserName -AsHciUserPassword $asHciLCMUserPassword -AsHciUsersOUPath $asHciOUPath -Verbose

    # Grant permissions to hci lifecycle management user
    Grant-HciOuPermissionsToHciLCMUser -AsHciLCMUserName $asHciLCMUserName -AsHciOUPath $asHciOUPath -Verbose

    # Block gpo inheritance to hci ou
    Block-GPInheritance -AsHciOUs @($asHciOUPath) -Verbose
}

Export-ModuleMember -Function New-HciAdObjectsPreCreation
Export-ModuleMember -Function Remove-AsHciOU
# SIG # Begin signature block
# MIIoKgYJKoZIhvcNAQcCoIIoGzCCKBcCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCHQe529ZPl+Uw6
# kVuo1OHaEsxZxQyHp0bfbMWq9RW1MqCCDXYwggX0MIID3KADAgECAhMzAAADrzBA
# DkyjTQVBAAAAAAOvMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjMxMTE2MTkwOTAwWhcNMjQxMTE0MTkwOTAwWjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQDOS8s1ra6f0YGtg0OhEaQa/t3Q+q1MEHhWJhqQVuO5amYXQpy8MDPNoJYk+FWA
# hePP5LxwcSge5aen+f5Q6WNPd6EDxGzotvVpNi5ve0H97S3F7C/axDfKxyNh21MG
# 0W8Sb0vxi/vorcLHOL9i+t2D6yvvDzLlEefUCbQV/zGCBjXGlYJcUj6RAzXyeNAN
# xSpKXAGd7Fh+ocGHPPphcD9LQTOJgG7Y7aYztHqBLJiQQ4eAgZNU4ac6+8LnEGAL
# go1ydC5BJEuJQjYKbNTy959HrKSu7LO3Ws0w8jw6pYdC1IMpdTkk2puTgY2PDNzB
# tLM4evG7FYer3WX+8t1UMYNTAgMBAAGjggFzMIIBbzAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQURxxxNPIEPGSO8kqz+bgCAQWGXsEw
# RQYDVR0RBD4wPKQ6MDgxHjAcBgNVBAsTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEW
# MBQGA1UEBRMNMjMwMDEyKzUwMTgyNjAfBgNVHSMEGDAWgBRIbmTlUAXTgqoXNzci
# tW2oynUClTBUBgNVHR8ETTBLMEmgR6BFhkNodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NybC9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3JsMGEG
# CCsGAQUFBwEBBFUwUzBRBggrBgEFBQcwAoZFaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9jZXJ0cy9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3J0
# MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggIBAISxFt/zR2frTFPB45Yd
# mhZpB2nNJoOoi+qlgcTlnO4QwlYN1w/vYwbDy/oFJolD5r6FMJd0RGcgEM8q9TgQ
# 2OC7gQEmhweVJ7yuKJlQBH7P7Pg5RiqgV3cSonJ+OM4kFHbP3gPLiyzssSQdRuPY
# 1mIWoGg9i7Y4ZC8ST7WhpSyc0pns2XsUe1XsIjaUcGu7zd7gg97eCUiLRdVklPmp
# XobH9CEAWakRUGNICYN2AgjhRTC4j3KJfqMkU04R6Toyh4/Toswm1uoDcGr5laYn
# TfcX3u5WnJqJLhuPe8Uj9kGAOcyo0O1mNwDa+LhFEzB6CB32+wfJMumfr6degvLT
# e8x55urQLeTjimBQgS49BSUkhFN7ois3cZyNpnrMca5AZaC7pLI72vuqSsSlLalG
# OcZmPHZGYJqZ0BacN274OZ80Q8B11iNokns9Od348bMb5Z4fihxaBWebl8kWEi2O
# PvQImOAeq3nt7UWJBzJYLAGEpfasaA3ZQgIcEXdD+uwo6ymMzDY6UamFOfYqYWXk
# ntxDGu7ngD2ugKUuccYKJJRiiz+LAUcj90BVcSHRLQop9N8zoALr/1sJuwPrVAtx
# HNEgSW+AKBqIxYWM4Ev32l6agSUAezLMbq5f3d8x9qzT031jMDT+sUAoCw0M5wVt
# CUQcqINPuYjbS1WgJyZIiEkBMIIHejCCBWKgAwIBAgIKYQ6Q0gAAAAAAAzANBgkq
# hkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
# EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5
# IDIwMTEwHhcNMTEwNzA4MjA1OTA5WhcNMjYwNzA4MjEwOTA5WjB+MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSgwJgYDVQQDEx9NaWNyb3NvZnQg
# Q29kZSBTaWduaW5nIFBDQSAyMDExMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAq/D6chAcLq3YbqqCEE00uvK2WCGfQhsqa+laUKq4BjgaBEm6f8MMHt03
# a8YS2AvwOMKZBrDIOdUBFDFC04kNeWSHfpRgJGyvnkmc6Whe0t+bU7IKLMOv2akr
# rnoJr9eWWcpgGgXpZnboMlImEi/nqwhQz7NEt13YxC4Ddato88tt8zpcoRb0Rrrg
# OGSsbmQ1eKagYw8t00CT+OPeBw3VXHmlSSnnDb6gE3e+lD3v++MrWhAfTVYoonpy
# 4BI6t0le2O3tQ5GD2Xuye4Yb2T6xjF3oiU+EGvKhL1nkkDstrjNYxbc+/jLTswM9
# sbKvkjh+0p2ALPVOVpEhNSXDOW5kf1O6nA+tGSOEy/S6A4aN91/w0FK/jJSHvMAh
# dCVfGCi2zCcoOCWYOUo2z3yxkq4cI6epZuxhH2rhKEmdX4jiJV3TIUs+UsS1Vz8k
# A/DRelsv1SPjcF0PUUZ3s/gA4bysAoJf28AVs70b1FVL5zmhD+kjSbwYuER8ReTB
# w3J64HLnJN+/RpnF78IcV9uDjexNSTCnq47f7Fufr/zdsGbiwZeBe+3W7UvnSSmn
# Eyimp31ngOaKYnhfsi+E11ecXL93KCjx7W3DKI8sj0A3T8HhhUSJxAlMxdSlQy90
# lfdu+HggWCwTXWCVmj5PM4TasIgX3p5O9JawvEagbJjS4NaIjAsCAwEAAaOCAe0w
# ggHpMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRIbmTlUAXTgqoXNzcitW2o
# ynUClTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYD
# VR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBRyLToCMZBDuRQFTuHqp8cx0SOJNDBa
# BgNVHR8EUzBRME+gTaBLhklodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2Ny
# bC9wcm9kdWN0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3JsMF4GCCsG
# AQUFBwEBBFIwUDBOBggrBgEFBQcwAoZCaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3J0MIGfBgNV
# HSAEgZcwgZQwgZEGCSsGAQQBgjcuAzCBgzA/BggrBgEFBQcCARYzaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9kb2NzL3ByaW1hcnljcHMuaHRtMEAGCCsG
# AQUFBwICMDQeMiAdAEwAZQBnAGEAbABfAHAAbwBsAGkAYwB5AF8AcwB0AGEAdABl
# AG0AZQBuAHQALiAdMA0GCSqGSIb3DQEBCwUAA4ICAQBn8oalmOBUeRou09h0ZyKb
# C5YR4WOSmUKWfdJ5DJDBZV8uLD74w3LRbYP+vj/oCso7v0epo/Np22O/IjWll11l
# hJB9i0ZQVdgMknzSGksc8zxCi1LQsP1r4z4HLimb5j0bpdS1HXeUOeLpZMlEPXh6
# I/MTfaaQdION9MsmAkYqwooQu6SpBQyb7Wj6aC6VoCo/KmtYSWMfCWluWpiW5IP0
# wI/zRive/DvQvTXvbiWu5a8n7dDd8w6vmSiXmE0OPQvyCInWH8MyGOLwxS3OW560
# STkKxgrCxq2u5bLZ2xWIUUVYODJxJxp/sfQn+N4sOiBpmLJZiWhub6e3dMNABQam
# ASooPoI/E01mC8CzTfXhj38cbxV9Rad25UAqZaPDXVJihsMdYzaXht/a8/jyFqGa
# J+HNpZfQ7l1jQeNbB5yHPgZ3BtEGsXUfFL5hYbXw3MYbBL7fQccOKO7eZS/sl/ah
# XJbYANahRr1Z85elCUtIEJmAH9AAKcWxm6U/RXceNcbSoqKfenoi+kiVH6v7RyOA
# 9Z74v2u3S5fi63V4GuzqN5l5GEv/1rMjaHXmr/r8i+sLgOppO6/8MO0ETI7f33Vt
# Y5E90Z1WTk+/gFcioXgRMiF670EKsT/7qMykXcGhiJtXcVZOSEXAQsmbdlsKgEhr
# /Xmfwb1tbWrJUnMTDXpQzTGCGgowghoGAgEBMIGVMH4xCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNp
# Z25pbmcgUENBIDIwMTECEzMAAAOvMEAOTKNNBUEAAAAAA68wDQYJYIZIAWUDBAIB
# BQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEO
# MAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIB+z/lHQdWdrUwftTwwd8JuW
# g8ZnKtfJSTBL3JGIjOheMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8A
# cwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEB
# BQAEggEAmSSAebUirKlIdpw5Zo2XLJQP1ZrwgPe2Dqf4kRAy5+RoLrpn0vtabfWW
# kq6Rfv9ZXDTDhPpPcBVsRiPb0F6zlMsMxGq/PUjX/c3hhwOfpM/VwTCyCo6eYTM9
# wP1GJgVv5cJV+dnlZdk2pzxBUNlDc47gk9vsVl/RvfnUXJeJdWY0zAXNKBZbJ66O
# +VMYQPsm7nr2KdS0xBlxp5xZRZFfpniC3/sDuiPT225aK49/30A5rLESl5BmnLqN
# nXxS7oe/TnJEoaO0v23ZhweLGyKnnp+PUgAk5ROxoy02TNnc7/VLZttiidTROXyH
# IwNJsb+qG7k/E37EUjZvL1faFOu6daGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCC
# F3wGCSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsq
# hkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFl
# AwQCAQUABCDALcWY4Vw5x43iTDdetk8dDCer508j7WKtz+6lLR8LIwIGZc4cKHUO
# GBMyMDI0MDIyODIzNTkwNS44MzJaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1l
# cmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046REMwMC0w
# NUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2Wg
# ghHqMIIHIDCCBQigAwIBAgITMwAAAehQsIDPK3KZTQABAAAB6DANBgkqhkiG9w0B
# AQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYD
# VQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yMzEyMDYxODQ1
# MjJaFw0yNTAzMDUxODQ1MjJaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25z
# MScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046REMwMC0wNUUwLUQ5NDcxJTAjBgNV
# BAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQDhQXdE0WzXG7wzeC9SGdH6eVwdGlF6YgpU7weOFBkp
# W9yuEmJSDE1ADBx/0DTuRBaplSD8CR1QqyQmxRDD/CdvDyeZFAcZ6l2+nlMssmZy
# C8TPt1GTWAUt3GXUU6g0F0tIrFNLgofCjOvm3G0j482VutKS4wZT6bNVnBVsChr2
# AjmVbGDN/6Qs/EqakL5cwpGel1te7UO13dUwaPjOy0Wi1qYNmR8i7T1luj2JdFdf
# ZhMPyqyq/NDnZuONSbj8FM5xKBoar12ragC8/1CXaL1OMXBwGaRoJTYtksi9njuq
# 4wDkcAwitCZ5BtQ2NqPZ0lLiQB7O10Bm9zpHWn9x1/HmdAn4koMWKUDwH5sd/zDu
# 4vi887FWxm54kkWNvk8FeQ7ZZ0Q5gqGKW4g6revV2IdAxBobWdorqwvzqL70Wdsg
# DU/P5c0L8vYIskUJZedCGHM2hHIsNRyw9EFoSolDM+yCedkz69787s8nIp55icLf
# DoKw5hak5G6MWF6d71tcNzV9+v9RQKMa6Uwfyquredd5sqXWCXv++hek4A15WybI
# c6ufT0ilazKYZvDvoaswgjP0SeLW7mvmcw0FELzF1/uWaXElLHOXIlieKF2i/YzQ
# 6U50K9dbhnMaDcJSsG0hXLRTy/LQbsOD0hw7FuK0nmzotSx/5fo9g7fCzoFjk3tD
# EwIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFPo5W8o980kMfRVQba6T34HwelLaMB8G
# A1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCG
# Tmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUy
# MFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4w
# XAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2Vy
# dHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwG
# A1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQD
# AgeAMA0GCSqGSIb3DQEBCwUAA4ICAQCWfcJm2rwXtPi74km6PKAkni9+BWotq+Qt
# DGgeT5F3ro7PsIUNKRkUytuGqI8thL3Jcrb03x6DOppYJEA+pb6o2qPjFddO1TLq
# vSXrYm+OgCLL+7+3FmRmfkRu8rHvprab0O19wDbukgO8I5Oi1RegMJl8t5k/UtE0
# Wb3zAlOHnCjLGSzP/Do3ptwhXokk02IvD7SZEBbPboGbtw4LCHsT2pFakpGOBh+I
# SUMXBf835CuVNfddwxmyGvNSzyEyEk5h1Vh7tpwP7z7rJ+HsiP4sdqBjj6Avopuf
# 4rxUAfrEbV6aj8twFs7WVHNiIgrHNna/55kyrAG9Yt19CPvkUwxYK0uZvPl2WC39
# nfc0jOTjivC7s/IUozE4tfy3JNkyQ1cNtvZftiX3j5Dt+eLOeuGDjvhJvYMIEkpk
# V68XLNH7+ZBfYa+PmfRYaoFFHCJKEoRSZ3PbDJPBiEhZ9yuxMddoMMQ19Tkyftot
# 6Ez0XhSmwjYBq39DvBFWhlyDGBhrU3GteDWiVd9YGSB2WnxuFMy5fbAK6o8PWz8Q
# RMiptXHK3HDBr2wWWEcrrgcTuHZIJTqepNoYlx9VRFvj/vCXaAFcmkW1nk7VE+ow
# aXr5RJjryDq9ubkyDq1mdrF/geaRALXcNZbfNXIkhXzXA6a8CiamcQW/DgmLJpiV
# QNriZYCHIDCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZI
# hvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# MjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAy
# MDEwMB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoIC
# AQDk4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25Phdg
# M/9cT8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPF
# dvWGUNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6
# GnszrYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBp
# Dco2LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50Zu
# yjLVwIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3E
# XzTdEonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0
# lBw0gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1q
# GFphAXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ
# +QuJYfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PA
# PBXbGjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkw
# EgYJKwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxG
# NSnPEP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARV
# MFMwUQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWlj
# cm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAK
# BggrBgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMC
# AYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvX
# zpoYxDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20v
# cGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYI
# KwYBBQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG
# 9w0BAQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0x
# M7U518JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmC
# VgADsAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449
# xvNo32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wM
# nosZiefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDS
# PeZKPmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2d
# Y3RILLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxn
# GSgkujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+Crvs
# QWY9af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokL
# jzbaukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL
# 6Xu/OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNN
# MIICNQIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkRDMDAtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQCM
# JG4vg0juMOVn2BuKACUvP80FuqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA6Ym9yTAiGA8yMDI0MDIyODE0MTIy
# NVoYDzIwMjQwMjI5MTQxMjI1WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDpib3J
# AgEAMAcCAQACAgGBMAcCAQACAhKzMAoCBQDpiw9JAgEAMDYGCisGAQQBhFkKBAIx
# KDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZI
# hvcNAQELBQADggEBAGXv4vlLO8gzWrOxDmbfTaiLQdoUzc54XV1m12w3DdLflfXI
# UQ/ipLh6j0CPVroo2rQAUJM/zt+UoYMna6gA53YAth/8qwSODwNMVbDBvLo5Ausv
# 8YqOdAVby4zB3f9gCyl1FO3BWeAH8jvOhoQI2hZ7+MtstJLPSLlMEsUAcYnaDUcR
# GAzhDpv8h3xjwjY0sdnL/mR9bfXbGvYHipfodCqYFH2vLz1xFysAGnb3thuOxv4M
# gynG96bXn9+SAthPn+iDad7DyHb+D/QfpRfi6Ry7+GLWS6AVvwFAvKms8WuIzWF2
# Yxk0tmoFAHDHuB225n8j/nQ8x6vK9Xeot5Dsb8ExggQNMIIECQIBATCBkzB8MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNy
# b3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAehQsIDPK3KZTQABAAAB6DAN
# BglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8G
# CSqGSIb3DQEJBDEiBCCA/xROuTRnhE5YWPa/PEPPjR+Vud4A2nrcIScyTxFkPDCB
# +gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EICrS2sTVAoQggkHR59pNqige0xfJ
# T2J3U8W1Sc8H+OsdMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIw
# MTACEzMAAAHoULCAzytymU0AAQAAAegwIgQgI/4QSxpcLlAnZ/i2tkiLuo2UWAAO
# NNtqaQGv/b8JbO4wDQYJKoZIhvcNAQELBQAEggIALd0UxkPXLSajNZpere0f8kAt
# LpVBQd5FZSo77aMAko5Gp4tgIwPhXkiu4gejXKpkuaNBYQttMdLvrlOZ5eMn3OE9
# thAEt3Igmtq2E9ppXG/NqWA4uAAXirf4+MEOg4BHEVKBb4px74VezTVibYxp4mmC
# xBZOPHM4ok/OZOZGQc7gfkx9CHs0LvMDXrhlW67KzqmRP4xgq8k3GjQ1fD24gEZS
# N0Jz68zySGDyFaz6DKRGA9kQOi4mjPqJDapB2vwvJc5cPXT4u8AzqnoRKQo7fmbR
# XJ1Hb737FF9crS6m+ns6deszF9CwNNiV/glyvOcqPQYpPkDy0pdHqxBLoWJ3eLhL
# 1Ald6+6UxCLAQHLy1ANXrm8ud1FXNpLQkSJLLKxyFjAb5Aewg5+AOZhnI80wi17A
# Cnr0KmFmq7N3N52EiXnQZOFvjXj5EQMt2w6Fw8RxbUlSNTHEhFejdfRrCBSiW7KJ
# v4GB23f6wuRyuXcUcsriBgbS66XO4X5DHfyQEHaFKnHTAVdN/QSm68i8zRIQ/sfx
# NQZMkUHg6ZPn9xiNNt1pKiqzvpwroJHY+qfsKmgZ68GWQ5O9HIJoggvJGDKeTgBY
# OMXNIaIiAXO5GJH9TP5pWnHO6CGYyG1SBzd4Pp2t2ES0mRzAR0535zpymFFt+fwZ
# WX/A8I7yklj22sh/fxo=
# SIG # End signature block
