#Requires -Version 5.1
<#
.SYNOPSIS
    Apply the debloat change-catalog (any profile) to the machine you are running on.

.DESCRIPTION
    post-install.ps1 is a thin dispatcher (Constitution Principle I & V): it enables strict mode,
    imports the WindowsIsoMaker module, performs the admin/elevation precondition check, and
    forwards to the shipped Invoke-PostInstallSetup command.

    Use this when you start from a STOCK Windows 11 you did NOT build with this tool — e.g. a
    cloud/OS reset ("Reset this PC" -> download), or an ISO from your Visual Studio subscription —
    and you still want the same documented, data-driven changes (e.g. the 'opinionated' profile)
    applied directly to the live machine, without building a custom ISO.

    The change selection is IDENTICAL to build.ps1 (same catalog, same profiles), only it is
    applied online to the running system instead of baked into an image. Every change is
    idempotent and honours -WhatIf (a full preview that touches nothing).

.PARAMETER Profile
    Catalog profile baseline(s): one or more of 'minimal' | 'default' | 'aggressive' | 'gaming' |
    'opinionated' (e.g. -Profile gaming,opinionated). Multiple values are UNIONed. Defaults to
    'default'.

.PARAMETER EnableCatalogId
    Opt-in catalog ids to force-enable (e.g. 'remove-edge','remove-onedrive','feature-wsl').

.PARAMETER DisableCatalogId
    Catalog ids to force-disable (explicit ids win).

.PARAMETER Architecture
    Optional override for the target architecture ('amd64' | 'arm64'). Auto-detected from the
    running OS when omitted.

.PARAMETER Scope
    Which per-user targets receive per-user tweaks and Appx removals: 'CurrentUser' (only the
    profile you are logged in as), 'FutureUsers' (only new profiles), or 'Both' (default).

.PARAMETER OutputDirectory
    Directory to write the run-report JSON into. Defaults to ./out.

.PARAMETER NoReport
    Do not write the run-report JSON to disk (the object is still returned).

.PARAMETER InstallWsl
    After applying the catalog, also install WSL and a Linux distribution. ON BY DEFAULT when the
    'opinionated' profile is selected; pass -InstallWsl to force it for other profiles, or
    -InstallWsl:$false to skip it under 'opinionated'.

.PARAMETER WslDistribution
    The Linux distribution to install when -InstallWsl is set (default 'Debian').

.PARAMETER WslServicing
    How WSL is obtained when -InstallWsl is set: 'Store' (default, auto-updating), 'WebDownload'
    (modern engine from GitHub, no Store dependency), or 'Inbox' (in-Windows component, Windows
    Update-serviced).

.PARAMETER WslAutoReboot
    When -InstallWsl needs a reboot, restart the computer automatically instead of only
    instructing you to reboot and re-run.

.EXAMPLE
    ./post-install.ps1 -Profile opinionated
    Applies the opinionated profile to the running machine.

.EXAMPLE
    ./post-install.ps1 -Profile opinionated -InstallWsl -WslDistribution Debian
    Applies the opinionated profile, then advances the staged WSL + Debian install (re-run after
    each requested reboot until it is done).

.EXAMPLE
    ./post-install.ps1 -Profile aggressive -WhatIf
    Previews every change the aggressive profile would make, touching nothing.

.EXAMPLE
    ./post-install.ps1 -Profile default -EnableCatalogId remove-edge,feature-wsl
    Runs the default profile and additionally opts into removing Edge and enabling the WSL platform.

.NOTES
    Requires an elevated (Administrator) PowerShell session for machine-wide (HKLM / DISM) changes.
    See docs/post-install.md.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', 'Profile',
    Justification = "'Profile' is the documented, user-facing catalog concept (minimal/default/aggressive/gaming/opinionated). The parameter is locally scoped and never writes the global profile path.")]
[CmdletBinding(SupportsShouldProcess = $true)]
param(
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
    [ValidateSet('amd64', 'arm64')]
    [string] $Architecture,

    [Parameter()]
    [ValidateSet('CurrentUser', 'FutureUsers', 'Both')]
    [string] $Scope,

    [Parameter()]
    [string] $OutputDirectory,

    [Parameter()]
    [switch] $NoReport,

    [Parameter()]
    [switch] $InstallWsl,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $WslDistribution,

    [Parameter()]
    [ValidateSet('Store', 'WebDownload', 'Inbox')]
    [string] $WslServicing,

    [Parameter()]
    [switch] $WslAutoReboot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import the shipped module (single source of change logic — Principle V).
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'src/WindowsIsoMaker'
Import-Module -Name $modulePath -Force -ErrorAction Stop

# Fail fast on missing elevation before doing anything (Principle VI / FR-019).
# Test-IsAdministrator is a private helper, so probe via the module's script scope.
$isAdmin = & (Get-Module WindowsIsoMaker) { Test-IsAdministrator }
if (-not $isAdmin -and -not $WhatIfPreference) {
    throw 'Administrative privileges are required to apply machine-wide changes. ' +
        'Re-run this script from an elevated PowerShell session, or use -WhatIf to preview.'
}

# Forward only the parameters the user actually set, so command defaults stay authoritative.
$setupParams = @{}
foreach ($name in 'Profile', 'EnableCatalogId', 'DisableCatalogId', 'Architecture', 'Scope', 'OutputDirectory', 'WslDistribution', 'WslServicing') {
    if ($PSBoundParameters.ContainsKey($name)) {
        $setupParams[$name] = $PSBoundParameters[$name]
    }
}
foreach ($switchName in 'NoReport', 'InstallWsl', 'WslAutoReboot') {
    if ($PSBoundParameters.ContainsKey($switchName)) {
        $setupParams[$switchName] = [switch]$PSBoundParameters[$switchName]
    }
}

# Honor -WhatIf from the dispatcher through to the command (preview path, FR-016).
if ($WhatIfPreference) {
    $setupParams['WhatIf'] = $true
}

Invoke-PostInstallSetup @setupParams
