<#
    windows-iso-maker registry "tattoo": a small, persistent footprint under
    HKLM\SOFTWARE\WindowsIsoMaker recording provenance (what/when/how the tool configured a
    machine) plus per-entry idempotency markers under HKLM\SOFTWARE\WindowsIsoMaker\State.

    Why the State markers exist: RunOnce/RunOnceEx command entries (e.g. the timezone/region/
    keyboard/mouse-scroll first-boot commands) are DELETED by Windows the moment they execute at
    logon. So on a second post-install run the value is gone and would be re-armed, reporting
    'Applied' every time even though nothing effectively changed. Recording the armed command in
    the State marker lets the online applier detect "already armed with this exact command" and
    report AlreadyApplied without re-arming — a re-run over an unchanged machine shows 0 changes
    (idempotency, Constitution Principle VI).

    Why writes use the .NET Registry API (not the provider, not reg.exe): creating a brand-new
    top-level HKLM\SOFTWARE\WindowsIsoMaker key with New-Item -Force / New-ItemProperty raises a
    SecurityException ("Requested registry access is not allowed") even in an elevated session,
    because the provider does not reliably open the freshly created key for writing. Writes to
    pre-existing subtrees (where the catalog entries live) work, which is why only this new key is
    affected. Microsoft.Win32.Registry.LocalMachine.CreateSubKey opens (or creates) the key WITH
    write access atomically, so it succeeds under an Administrator token without shelling out to
    reg.exe. It is a mockable seam (Set-LiveMachineRegistryValue) so the suite runs on any
    platform. Marker READS still go through the Get-OfflineRegistryValue provider seam (reading
    needs no write access and works offline too).
#>

# .NET subkey paths (relative to HKEY_LOCAL_MACHINE).
$script:WimTattooSubKey = 'SOFTWARE\WindowsIsoMaker'
$script:WimTattooStateSubKey = 'SOFTWARE\WindowsIsoMaker\State'
# Provider-style path (relative to the SOFTWARE hive root) used for READING markers via the
# Get-OfflineRegistryValue seam.
$script:WimTattooStateReadPath = 'WindowsIsoMaker\State'
# WSL staged-install state (see Install-WslDistribution): written via the .NET seam, read via the
# provider seam against the live HKLM\SOFTWARE root.
$script:WimWslStateSubKey = 'SOFTWARE\WindowsIsoMaker\Wsl'
$script:WimWslStateReadPath = 'WindowsIsoMaker\Wsl'

function Set-LiveMachineRegistryValue {
    <#
    .SYNOPSIS
        Write a single String value to a live HKLM subkey via the .NET registry API (mockable
        seam), creating the key with write access if needed.
    .DESCRIPTION
        Uses [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey, which opens or creates the key
        WITH write access — unlike the PowerShell registry provider, which can raise
        "Requested registry access is not allowed" when creating a new top-level HKLM\SOFTWARE key
        even under an elevated token. Only String (REG_SZ) data is written.
    .PARAMETER SubKey
        Subkey path relative to HKLM, e.g. 'SOFTWARE\WindowsIsoMaker'.
    .PARAMETER Name
        Value name.
    .PARAMETER Data
        String data.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $SubKey,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Data
    )
    $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($SubKey)
    if ($null -eq $key) {
        throw "Could not open or create HKLM\$SubKey for writing."
    }
    try {
        $key.SetValue($Name, [string]$Data, [Microsoft.Win32.RegistryValueKind]::String)
    }
    finally {
        $key.Dispose()
    }
}

function Test-IsRunOnceRegistryEntry {
    <#
    .SYNOPSIS
        Return whether a SetRegistry entry arms a Windows RunOnce/RunOnceEx command (whose value
        Windows deletes after it runs, requiring an idempotency marker).
    .PARAMETER Entry
        A single catalog entry.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][object] $Entry)

    if ($null -eq $Entry) { return $false }
    $target = $Entry.Target
    if ($null -eq $target) { return $false }

    $path = if ($target -is [System.Collections.IDictionary]) {
        if ($target.Contains('Path')) { $target['Path'] } else { $null }
    }
    elseif ($target.PSObject.Properties.Name -contains 'Path') { $target.Path } else { $null }

    $operation = if ($target -is [System.Collections.IDictionary]) {
        if ($target.Contains('Operation')) { $target['Operation'] } else { $null }
    }
    elseif ($target.PSObject.Properties.Name -contains 'Operation') { $target.Operation } else { $null }

    if ($operation -eq 'Delete') { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$path)) { return $false }
    return ([string]$path -match '(?i)(^|\\)RunOnce(Ex)?$')
}

function Set-WimRunOnceMarker {
    <#
    .SYNOPSIS
        Record (best-effort) the idempotency marker for a just-armed RunOnce catalog entry under
        HKLM\SOFTWARE\WindowsIsoMaker\State.
    .DESCRIPTION
        Stores the armed command string so a later run recognises the entry as AlreadyApplied even
        after Windows has consumed the RunOnce value at logon. Non-fatal by contract: callers wrap
        this and continue on error (the real change already succeeded).
    .PARAMETER Id
        The catalog entry id (used as the marker value name).
    .PARAMETER CommandValue
        The armed command string.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $Id,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $CommandValue
    )
    Set-LiveMachineRegistryValue -SubKey $script:WimTattooStateSubKey -Name $Id -Data $CommandValue
}

function Test-WimRunOnceMarker {
    <#
    .SYNOPSIS
        Return whether the persisted idempotency marker for a RunOnce entry already matches the
        current command (so it need not be re-armed).
    .PARAMETER Root
        The registry root/mount key the entry targets (e.g. 'HKLM\SOFTWARE').
    .PARAMETER Id
        The catalog entry id.
    .PARAMETER CommandValue
        The current command string.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Id,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $CommandValue
    )
    $marker = Get-OfflineRegistryValue -MountKey $Root -Path $script:WimTattooStateReadPath -Name $Id
    if ($null -eq $marker) { return $false }
    return ("$marker" -eq "$CommandValue")
}

function Write-WimRegistryTattoo {
    <#
    .SYNOPSIS
        Write windows-iso-maker provenance values under HKLM\SOFTWARE\WindowsIsoMaker (the
        registry tattoo).
    .DESCRIPTION
        Uses the mockable Set-LiveMachineRegistryValue (.NET) seam so it reliably creates the
        top-level key under an elevated token and is unit-testable on any platform. Every value is
        a String for a stable, human-readable footprint.
    .PARAMETER Values
        Name -> value map of provenance fields to record.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory = $true)][hashtable] $Values)

    foreach ($name in $Values.Keys) {
        Set-LiveMachineRegistryValue -SubKey $script:WimTattooSubKey -Name ([string]$name) -Data "$($Values[$name])"
    }
}

function Set-WimWslState {
    <#
    .SYNOPSIS
        Persist a WSL staged-install state value under HKLM\SOFTWARE\WindowsIsoMaker\Wsl.
    .PARAMETER Name
        The state value name (e.g. 'Stage', 'Distribution').
    .PARAMETER Value
        The string value to record.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Value
    )
    Set-LiveMachineRegistryValue -SubKey $script:WimWslStateSubKey -Name $Name -Data $Value
}

function Get-WimWslState {
    <#
    .SYNOPSIS
        Read a WSL staged-install state value from HKLM\SOFTWARE\WindowsIsoMaker\Wsl (or $null).
    .PARAMETER Name
        The state value name (e.g. 'Stage', 'Distribution').
    .OUTPUTS
        System.String or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string] $Name)
    $value = Get-OfflineRegistryValue -MountKey 'HKLM\SOFTWARE' -Path $script:WimWslStateReadPath -Name $Name
    if ($null -eq $value) { return $null }
    return [string]$value
}
