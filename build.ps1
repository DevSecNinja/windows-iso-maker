#Requires -Version 5.1
<#
.SYNOPSIS
    Thin local entry point for the Windows 11 ISO Builder & Debloater.

.DESCRIPTION
    build.ps1 is a dispatcher only (Constitution Principle I & V): it enables strict mode,
    imports the WindowsIsoMaker module, performs the admin/elevation precondition check,
    and forwards a configuration file (the PRIMARY interface) plus any optional last-mile
    override parameters to the shipped Invoke-IsoBuild orchestrator. No build logic lives
    here; local and CI runs share exactly one build path.

    The configuration file is the primary way to drive a build. Point -ConfigPath (alias
    -Path) at any saved profile, or set the WIM_CONFIG_PATH environment variable, to keep
    multiple configurations (e.g. config/build.pro.psd1, config/build.arm64.psd1).
    Precedence: config-file defaults -> WIM_* environment variables -> explicit parameters.

.PARAMETER ConfigPath
    Path to the build configuration .psd1 file. Defaults to config/build.config.psd1.
    Alias: -Path. May also be supplied via the WIM_CONFIG_PATH environment variable.

.PARAMETER Architecture
    Optional last-mile override for the target architecture ('amd64' or 'arm64').

.PARAMETER Edition
    Optional last-mile override for the Windows edition (e.g. 'Pro').

.PARAMETER Language
    Optional last-mile override for the display language (e.g. 'en-US').

.PARAMETER Release
    Optional last-mile override for the Windows release (e.g. 'latest').

.PARAMETER Profile
    Optional last-mile override for the catalog profile ('minimal' | 'default' | 'aggressive' | 'gaming').

.PARAMETER EnableCatalogId
    Opt-in catalog ids to enable (data-driven; e.g. 'remove-edge','remove-onedrive','feature-wsl').

.PARAMETER DisableCatalogId
    Catalog ids to force-disable (explicit ids win).

.PARAMETER ProductKey
    Optional override for the Autounattend product key. Required for a hands-off non-Home 24H2
    install (only Home installs without a key; the generic KMS keys fail 24H2 validation).

.PARAMETER AccountMode
    Optional override for OOBE account provisioning: 'local' (create a local admin, hands-off) or
    'entra' (present the work/school sign-in to join Entra ID and auto-enroll into Intune).

.PARAMETER SkipHeavyBuild
    Run the preview/light path only (no download/mount/build); still emits a RunReport.

.PARAMETER BootTest
    Opt-in VM boot validation in addition to the default structural integrity checks.

.PARAMETER KeepBootTestVm
    With -BootTest, keep the throwaway VM running and pause for manual testing (attach with
    vmconnect) until you press Enter, then power it off and clean up.

.EXAMPLE
    ./build.ps1
    Builds using config/build.config.psd1 (Windows 11 Pro, en-US, latest, amd64).

.EXAMPLE
    ./build.ps1 -ConfigPath config/build.arm64.psd1
    Builds using a saved arm64 profile.

.EXAMPLE
    ./build.ps1 -Architecture amd64 -EnableCatalogId remove-edge,remove-onedrive,feature-wsl
    Uses the default config but overrides the architecture and opts into Edge/OneDrive/WSL.

.EXAMPLE
    ./build.ps1 -WhatIf
    Previews every change that would be made without touching any media.

.NOTES
    Requires administrative rights and the Windows image-servicing stack (DISM) plus the
    Windows ADK Deployment Tools (oscdimg). See docs/usage.md.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', 'Profile',
    Justification = "'Profile' is the documented, user-facing configuration concept (minimal/default/aggressive). The parameter is locally scoped and never writes the global profile path.")]
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [Alias('Path')]
    [string] $ConfigPath,

    [Parameter()]
    [ValidateSet('amd64', 'arm64')]
    [string] $Architecture,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Edition,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Language,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Release,

    [Parameter()]
    [ValidateSet('minimal', 'default', 'aggressive', 'gaming', 'opinionated')]
    [string] $Profile,

    [Parameter()]
    [string[]] $EnableCatalogId,

    [Parameter()]
    [string[]] $DisableCatalogId,

    [Parameter()]
    [AllowEmptyString()]
    [string] $ProductKey,

    [Parameter()]
    [ValidateSet('local', 'entra', 'entraid', 'azuread')]
    [string] $AccountMode,

    [Parameter()]
    [switch] $SkipHeavyBuild,

    [Parameter()]
    [switch] $BootTest,

    [Parameter()]
    [switch] $KeepBootTestVm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve the config path precedence for the DISPATCHER only: explicit param wins, else the
# WIM_CONFIG_PATH env var, else the shipped default. Get-BuildConfiguration re-applies the
# full precedence chain for every field.
if (-not $PSBoundParameters.ContainsKey('ConfigPath') -or [string]::IsNullOrWhiteSpace($ConfigPath)) {
    if ($env:WIM_CONFIG_PATH) {
        $ConfigPath = $env:WIM_CONFIG_PATH
    }
    else {
        $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath 'config/build.config.psd1'
    }
}

# Import the shipped module (single source of build logic — Principle V).
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'src/WindowsIsoMaker'
Import-Module -Name $modulePath -Force -ErrorAction Stop

# Fail fast on missing elevation before doing anything expensive (Principle VI / FR-019).
# Test-IsAdministrator is a private helper, so probe via the module's script scope.
$isAdmin = & (Get-Module WindowsIsoMaker) { Test-IsAdministrator }
if (-not $isAdmin -and -not $WhatIfPreference -and -not $SkipHeavyBuild) {
    throw 'Administrative privileges are required to service a Windows image. ' +
        'Re-run this script from an elevated PowerShell session, or use -WhatIf / -SkipHeavyBuild to preview.'
}

# Assemble the optional last-mile overrides. Only forward parameters the user actually set,
# so the config file remains authoritative for everything else.
$buildParams = @{
    ConfigPath = $ConfigPath
}
foreach ($name in 'Architecture', 'Edition', 'Language', 'Release', 'Profile', 'EnableCatalogId', 'DisableCatalogId', 'ProductKey', 'AccountMode') {
    if ($PSBoundParameters.ContainsKey($name)) {
        $buildParams[$name] = $PSBoundParameters[$name]
    }
}
foreach ($switchName in 'SkipHeavyBuild', 'BootTest', 'KeepBootTestVm') {
    if ($PSBoundParameters.ContainsKey($switchName)) {
        $buildParams[$switchName] = [switch]$PSBoundParameters[$switchName]
    }
}

# Honor -WhatIf from the dispatcher through to the orchestrator (preview path, FR-016).
if ($WhatIfPreference) {
    $buildParams['WhatIf'] = $true
}

Invoke-IsoBuild @buildParams
