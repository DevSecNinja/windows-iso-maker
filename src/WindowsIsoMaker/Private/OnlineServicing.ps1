<#
    Thin, private wrapper functions around the ONLINE (running-system) servicing surface:
    dism.exe /online for provisioned-appx / capability / optional-feature operations, plus the
    Appx module cmdlets (Get-/Remove-AppxPackage) for the CURRENT user's installed packages.

    These mirror the offline Image* wrappers in ImageServicing.ps1 but target the live OS
    (post-install path — Invoke-PostInstallSetup). They exist for the same reason: a single,
    mockable seam for every external servicing call so the Pester suite can run on ANY platform
    (the real dism/Appx cmdlets only exist on Windows). The DISM output parsers
    (ConvertFrom-Dism*) are shared with ImageServicing.ps1 — they parse dism output regardless of
    whether it came from /Image: or /online.

    ShouldProcess/-WhatIf gating and change accounting live in the online appliers
    (Set-OnlineRegistryTweaks / Remove-OnlineBloatware / Enable-OnlineWindowsFeature), so the
    state-changing analyzer rule is suppressed here deliberately.
#>

function Get-OnlineProvisionedAppx {
    <#
    .SYNOPSIS
        Return the provisioned Appx packages on the running system (dism /online).
    .DESCRIPTION
        Provisioned packages are the per-image staged apps that get installed for every NEW
        user profile. Removing them stops future profiles from receiving the app; it does not
        uninstall the app for a user who already has it (that is Remove-OnlineInstalledAppxPackage).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    # Uses dism.exe (not Get-AppxProvisionedPackage) — see Invoke-DismExe for why.
    $dism = Invoke-DismExe -Arguments @('/English', '/online', '/Get-ProvisionedAppxPackages')
    if ($dism.ExitCode -ne 0) {
        $tail = (@($dism.Output) | Select-Object -Last 5) -join ' '
        throw "dism.exe failed to list provisioned Appx packages on the running system (exit $($dism.ExitCode)): $tail"
    }
    return ConvertFrom-DismProvisionedAppx -Output @($dism.Output)
}

function Remove-OnlineProvisionedAppx {
    <#
    .SYNOPSIS
        De-provision an Appx package on the running system so future user profiles do not get it.
    .PARAMETER PackageName
        The exact provisioned PackageName to remove.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory = $true)][string] $PackageName)
    # Uses dism.exe (not Remove-AppxProvisionedPackage) — see Invoke-DismExe for why.
    $dism = Invoke-DismExe -Arguments @('/English', '/online', '/Remove-ProvisionedAppxPackage', "/PackageName:$PackageName")
    if ($dism.ExitCode -ne 0) {
        $tail = (@($dism.Output) | Select-Object -Last 5) -join ' '
        throw "dism.exe failed to remove provisioned Appx package '$PackageName' (exit $($dism.ExitCode)): $tail"
    }
}

function Get-OnlineInstalledAppxPackage {
    <#
    .SYNOPSIS
        Return the Appx packages installed for the CURRENT user (Get-AppxPackage).
    .PARAMETER Name
        A package Name filter (supports wildcards), matched against the catalog Target.
    .OUTPUTS
        Objects exposing at least Name and PackageFullName.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory = $true)][string] $Name)
    return @(Get-AppxPackage -Name $Name -ErrorAction SilentlyContinue)
}

function Remove-OnlineInstalledAppxPackage {
    <#
    .SYNOPSIS
        Uninstall an Appx package for the CURRENT user (Remove-AppxPackage).
    .PARAMETER PackageFullName
        The exact PackageFullName to remove.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory = $true)][string] $PackageFullName)
    Remove-AppxPackage -Package $PackageFullName -ErrorAction Stop
}

function Get-OnlineCapability {
    <#
    .SYNOPSIS
        Return the Windows capabilities (and state) on the running system (dism /online).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    # Uses dism.exe (not Get-WindowsCapability) — see Invoke-DismExe for why.
    $dism = Invoke-DismExe -Arguments @('/English', '/online', '/Get-Capabilities')
    if ($dism.ExitCode -ne 0) {
        $tail = (@($dism.Output) | Select-Object -Last 5) -join ' '
        throw "dism.exe failed to list capabilities on the running system (exit $($dism.ExitCode)): $tail"
    }
    return ConvertFrom-DismCapabilities -Output @($dism.Output)
}

function Remove-OnlineCapability {
    <#
    .SYNOPSIS
        Remove a Windows capability from the running system (dism /online).
    .PARAMETER Name
        The capability Name to remove.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory = $true)][string] $Name)
    # Uses dism.exe (not Remove-WindowsCapability) — see Invoke-DismExe for why.
    $dism = Invoke-DismExe -Arguments @('/English', '/online', '/Remove-Capability', "/CapabilityName:$Name")
    if ($dism.ExitCode -ne 0) {
        $tail = (@($dism.Output) | Select-Object -Last 5) -join ' '
        throw "dism.exe failed to remove capability '$Name' (exit $($dism.ExitCode)): $tail"
    }
}

function Add-OnlineCapability {
    <#
    .SYNOPSIS
        Add a Windows capability to the running system (dism /online).
    .PARAMETER Name
        The capability Name to add.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory = $true)][string] $Name)
    # Uses dism.exe (not Add-WindowsCapability) — see Invoke-DismExe for why.
    $dism = Invoke-DismExe -Arguments @('/English', '/online', '/Add-Capability', "/CapabilityName:$Name")
    if ($dism.ExitCode -ne 0) {
        $tail = (@($dism.Output) | Select-Object -Last 5) -join ' '
        throw "dism.exe failed to add capability '$Name' (exit $($dism.ExitCode)): $tail"
    }
}

function Get-OnlineOptionalFeature {
    <#
    .SYNOPSIS
        Return the optional features (and state) on the running system (dism /online).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    # Uses dism.exe (not Get-WindowsOptionalFeature) — see Invoke-DismExe for why.
    $dism = Invoke-DismExe -Arguments @('/English', '/online', '/Get-Features')
    if ($dism.ExitCode -ne 0) {
        $tail = (@($dism.Output) | Select-Object -Last 5) -join ' '
        throw "dism.exe failed to list optional features on the running system (exit $($dism.ExitCode)): $tail"
    }
    return ConvertFrom-DismFeatures -Output @($dism.Output)
}

function Enable-OnlineOptionalFeature {
    <#
    .SYNOPSIS
        Enable a Windows optional feature on the running system (dism /online).
    .PARAMETER FeatureName
        The optional feature to enable (e.g. 'Microsoft-Windows-Subsystem-Linux').
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory = $true)][string] $FeatureName)
    # Uses dism.exe (not Enable-WindowsOptionalFeature) — see Invoke-DismExe for why.
    $dism = Invoke-DismExe -Arguments @('/English', '/online', '/Enable-Feature', "/FeatureName:$FeatureName", '/All', '/NoRestart')
    # 3010 = success, restart required; treat as success (the caller surfaces a reboot note).
    if ($dism.ExitCode -ne 0 -and $dism.ExitCode -ne 3010) {
        $tail = (@($dism.Output) | Select-Object -Last 5) -join ' '
        throw "dism.exe failed to enable optional feature '$FeatureName' (exit $($dism.ExitCode)): $tail"
    }
}

function Get-OnlineArchitecture {
    <#
    .SYNOPSIS
        Detect the running OS architecture as the catalog's 'amd64' | 'arm64' token.
    .DESCRIPTION
        Reads PROCESSOR_ARCHITECTURE (and the WoW64 fallback) so a 32-bit host process still
        reports the true OS architecture. Anything unrecognized defaults to 'amd64'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $raw = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $env:PROCESSOR_ARCHITECTURE }
    switch (([string]$raw).ToUpperInvariant()) {
        'ARM64' { return 'arm64' }
        'AMD64' { return 'amd64' }
        default { return 'amd64' }
    }
}
