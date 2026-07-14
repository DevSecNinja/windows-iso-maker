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
    Optional last-mile override for the Windows edition (e.g. 'Pro'). Only Home ships on the
    downloadable consumer ISO; every other edition needs a business ISO via -IsoPath.

.PARAMETER Language
    Optional last-mile override for the display language (e.g. 'en-US').

.PARAMETER Release
    Optional last-mile override for the Windows release (e.g. 'latest').

.PARAMETER Profile
    Optional last-mile override for the catalog profile(s): one or more of 'minimal' | 'default' |
    'aggressive' | 'gaming' | 'opinionated' (e.g. -Profile gaming,opinionated). Multiple values are
    UNIONed; 'gaming' preserves the gaming stack.

.PARAMETER EnableCatalogId
    Opt-in catalog ids to enable (data-driven; e.g. 'remove-edge','remove-onedrive','feature-wsl').

.PARAMETER DisableCatalogId
    Catalog ids to force-disable (explicit ids win).

.PARAMETER IsoPath
    Path to a pre-downloaded base ISO (skips the Fido download). Required for every non-Home
    edition (Pro / Education / Enterprise / ...), which only ship on the business/volume ISO —
    supply the matching business ISO (e.g. from a Visual Studio / volume-licensing subscription).

.PARAMETER ProductKey
    Optional override for the Autounattend product key. Applied in the specialize pass (not
    windowsPE), so it is never subject to 24H2's windowsPE key-validation hard-stop. '' / 'none'
    install the metadata-selected edition unlicensed; a genuine key activates when valid.

.PARAMETER AccountMode
    Optional override for OOBE account provisioning: 'local' (create a local admin, hands-off) or
    'entra' (present the work/school sign-in to join Entra ID and auto-enroll into Intune).

.PARAMETER UseGenericProductKey
    Bake the edition's generic/default retail key, applied in the specialize pass (non-activating) -
    the easy way to make a fully hands-off Home build. Mutually exclusive with -ProductKey.

.PARAMETER SkipHeavyBuild
    Run the preview/light path only (no download/mount/build); still emits a RunReport.

.PARAMETER BootTest
    Opt-in VM boot validation in addition to the default structural integrity checks.

.PARAMETER Hypervisor
    Which hypervisor runs the -BootTest VM: 'HyperV' (default) or 'VMware' (VMware Workstation).
    VMware's NAT gives WinPE real DNS for a 24H2+ ConX online product-key/edition check. VMware
    Workstation Pro must be downloaded manually (Broadcom login-gated, not on winget); if it is
    selected but missing, the boot test prints the Broadcom download link + guided setup steps and
    stops rather than failing hard.

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
    [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            @('Home', 'HomeN', 'Pro', 'ProN', 'ProForWorkstations', 'ProEducation', 'Education',
                'EducationN', 'Enterprise', 'EnterpriseN', 'EnterpriseLTSC2024', 'IoTEnterpriseLTSC2024') |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
        })]
    [string] $Edition,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            @('en-US', 'en-GB', 'nl-NL', 'de-DE', 'fr-FR', 'es-ES', 'it-IT', 'pt-BR', 'pt-PT', 'pl-PL',
                'sv-SE', 'da-DK', 'nb-NO', 'fi-FI', 'cs-CZ', 'ja-JP', 'ko-KR', 'zh-CN', 'zh-TW') |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
        })]
    [string] $Language,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            @('latest', '24H2', '23H2') |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
        })]
    [string] $Release,

    [Parameter()]
    [ValidateSet('minimal', 'default', 'aggressive', 'gaming', 'opinionated')]
    [string[]] $Profile,

    [Parameter()]
    [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            try {
                $configDir = Join-Path -Path $PSScriptRoot -ChildPath 'config'
                Get-ChildItem -LiteralPath $configDir -Filter 'catalog.*.psd1' -File -ErrorAction Stop |
                    ForEach-Object { (Import-PowerShellDataFile -LiteralPath $_.FullName).Entries } |
                    Where-Object { $_.Id -and $_.Id -like "$wordToComplete*" } |
                    Sort-Object -Property Id -Unique |
                    ForEach-Object {
                        [System.Management.Automation.CompletionResult]::new(
                            $_.Id, $_.Id, 'ParameterValue', ('[{0}] {1}' -f $_.Category, $_.Description))
                    }
            } catch { Write-Verbose "Catalog-id completion skipped: $_" }
        })]
    [string[]] $EnableCatalogId,

    [Parameter()]
    [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            try {
                $configDir = Join-Path -Path $PSScriptRoot -ChildPath 'config'
                Get-ChildItem -LiteralPath $configDir -Filter 'catalog.*.psd1' -File -ErrorAction Stop |
                    ForEach-Object { (Import-PowerShellDataFile -LiteralPath $_.FullName).Entries } |
                    Where-Object { $_.Id -and $_.Id -like "$wordToComplete*" } |
                    Sort-Object -Property Id -Unique |
                    ForEach-Object {
                        [System.Management.Automation.CompletionResult]::new(
                            $_.Id, $_.Id, 'ParameterValue', ('[{0}] {1}' -f $_.Category, $_.Description))
                    }
            } catch { Write-Verbose "Catalog-id completion skipped: $_" }
        })]
    [string[]] $DisableCatalogId,

    [Parameter()]
    [string] $IsoPath,

    [Parameter()]
    [AllowEmptyString()]
    [string] $ProductKey,

    [Parameter()]
    [ValidateSet('local', 'entra', 'entraid', 'azuread')]
    [string] $AccountMode,

    [Parameter()]
    [switch] $UseGenericProductKey,

    [Parameter()]
    [switch] $SkipHeavyBuild,

    [Parameter()]
    [switch] $BootTest,

    [Parameter()]
    [ValidateSet('HyperV', 'VMware')]
    [string] $Hypervisor,

    [Parameter()]
    [switch] $KeepBootTestVm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Fail fast on mutually exclusive product-key inputs before importing the module or checking
# elevation: -ProductKey bakes a specific key, -UseGenericProductKey bakes the edition's generic
# key; supplying both is contradictory.
if ($UseGenericProductKey.IsPresent -and $PSBoundParameters.ContainsKey('ProductKey')) {
    throw '-ProductKey and -UseGenericProductKey are mutually exclusive. Pass -ProductKey ' +
        "'<key>' to bake a specific key, or -UseGenericProductKey for the edition's generic key - not both."
}

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
foreach ($name in 'Architecture', 'Edition', 'Language', 'Release', 'Profile', 'EnableCatalogId', 'DisableCatalogId', 'IsoPath', 'ProductKey', 'AccountMode', 'Hypervisor') {
    if ($PSBoundParameters.ContainsKey($name)) {
        $buildParams[$name] = $PSBoundParameters[$name]
    }
}
foreach ($switchName in 'SkipHeavyBuild', 'BootTest', 'KeepBootTestVm', 'UseGenericProductKey') {
    if ($PSBoundParameters.ContainsKey($switchName)) {
        $buildParams[$switchName] = [switch]$PSBoundParameters[$switchName]
    }
}

# Honor -WhatIf from the dispatcher through to the orchestrator (preview path, FR-016).
if ($WhatIfPreference) {
    $buildParams['WhatIf'] = $true
}

Invoke-IsoBuild @buildParams
