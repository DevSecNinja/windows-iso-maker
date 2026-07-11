<#
    Private helpers for reading/writing/deleting values in a loaded OFFLINE registry hive.
    These are the mockable seam for registry mutations (the Registry provider is Windows-only),
    so the Pester suite can exercise Set-RegistryTweaks on any platform.
#>

function Get-OfflineRegistryValue {
    <#
    .SYNOPSIS
        Read a value from a loaded offline hive, or $null if absent.
    .PARAMETER MountKey
        The HKLM mount key the hive was loaded into (e.g. 'HKLM\WIM_Offline_SOFTWARE_1a2b').
    .PARAMETER Path
        Sub-path within the hive (e.g. 'Policies\Microsoft\Windows\WindowsAI').
    .PARAMETER Name
        Value name.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][string] $MountKey,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Name
    )
    $fullPath = "Registry::$MountKey\$Path"
    if (-not (Test-Path -LiteralPath $fullPath)) {
        return $null
    }
    $item = Get-ItemProperty -LiteralPath $fullPath -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $null
    }
    return $item.$Name
}

function Set-OfflineRegistryValue {
    <#
    .SYNOPSIS
        Create/overwrite a value in a loaded offline hive, creating the key path if needed.
    .PARAMETER MountKey
        The HKLM mount key.
    .PARAMETER Path
        Sub-path within the hive.
    .PARAMETER Name
        Value name.
    .PARAMETER Kind
        Registry value kind (DWord, String, etc.).
    .PARAMETER Value
        The value to write.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $MountKey,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Kind,
        [Parameter(Mandatory = $true)]$Value
    )
    $fullPath = "Registry::$MountKey\$Path"
    if (-not (Test-Path -LiteralPath $fullPath)) {
        New-Item -Path $fullPath -Force -ErrorAction Stop | Out-Null
    }
    New-ItemProperty -LiteralPath $fullPath -Name $Name -PropertyType $Kind -Value $Value -Force -ErrorAction Stop | Out-Null
}

function Remove-OfflineRegistryValue {
    <#
    .SYNOPSIS
        Delete a value from a loaded offline hive if it exists.
    .PARAMETER MountKey
        The HKLM mount key.
    .PARAMETER Path
        Sub-path within the hive.
    .PARAMETER Name
        Value name to delete.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $MountKey,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Name
    )
    $fullPath = "Registry::$MountKey\$Path"
    if (Test-Path -LiteralPath $fullPath) {
        Remove-ItemProperty -LiteralPath $fullPath -Name $Name -Force -ErrorAction SilentlyContinue
    }
}
