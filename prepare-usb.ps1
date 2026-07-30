#Requires -Version 5.1
<#
.SYNOPSIS
    Prepare a Windows 11 USB installation stick so the post-install catalog travels with it.

.DESCRIPTION
    prepare-usb.ps1 is a thin dispatcher (Constitution Principle I & V): it enables strict mode,
    imports the WindowsIsoMaker module, and forwards to the shipped New-PostInstallUsb command.

    Use it when you flash a STOCK Windows 11 ISO (for example one from your Visual Studio
    subscription) to a USB stick and want this tool's documented changes applied afterwards
    WITHOUT building a custom ISO. It validates the stick, stages the toolkit onto it and - in the
    default 'FirstLogon' mode - writes a MINIMAL Autounattend.xml that applies the catalog once,
    elevated, at the first logon.

    Windows Setup itself stays completely stock: edition, partitioning and OOBE (including an
    Entra ID sign-in) remain interactive. Nothing on the media is modified and no disk is wiped by
    this script. See docs/usb.md.

.PARAMETER Path
    The USB stick to prepare: a drive specification ('E:' or 'E:\') or a directory.

.PARAMETER Mode
    'FirstLogon' (default) stages the toolkit AND hooks it into the first logon; 'Toolkit' only
    stages it for you to run by hand.

.PARAMETER Profile
    Catalog profile baseline(s) the staged run applies: one or more of 'minimal' | 'default' |
    'aggressive' | 'gaming' | 'opinionated' (UNIONed). Defaults to 'default'.

.PARAMETER EnableCatalogId
    Opt-in catalog ids to force-enable (e.g. 'remove-edge','feature-wsl').

.PARAMETER DisableCatalogId
    Catalog ids to force-disable (explicit ids win).

.PARAMETER Scope
    Which per-user targets the staged run touches: 'CurrentUser', 'FutureUsers' or 'Both'.

.PARAMETER Architecture
    Override the target architecture ('amd64' | 'arm64'). Auto-detected from the media otherwise.

.PARAMETER InstallWsl
    Have the staged run also install WSL and a distribution (implied by the opinionated profile).

.PARAMETER WslDistribution
    The Linux distribution the staged run installs when WSL is included (default 'Debian').

.PARAMETER ToolkitFolder
    Folder created at the stick's root to hold the toolkit (default 'windows-iso-maker').

.PARAMETER Force
    Proceed on a non-removable target or non-Setup media, and overwrite an existing
    Autounattend.xml / staged toolkit.

.EXAMPLE
    ./prepare-usb.ps1 -Path E: -Profile opinionated
    Stages the toolkit on E: and applies the opinionated profile at the first logon.

.EXAMPLE
    ./prepare-usb.ps1 -Path E: -Profile opinionated -WhatIf
    Validates the stick and shows what would be staged, writing nothing.

.EXAMPLE
    ./prepare-usb.ps1 -Path E: -Mode Toolkit
    Only carries the toolkit on the stick; run it yourself after signing in.

.NOTES
    Does not require elevation - it only writes to the USB stick. See docs/usb.md.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', 'Profile',
    Justification = "'Profile' is the documented, user-facing catalog concept (minimal/default/aggressive/gaming/opinionated). The parameter is locally scoped and never writes the global profile path.")]
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $Path,

    [Parameter()]
    [ValidateSet('FirstLogon', 'Toolkit')]
    [string] $Mode,

    [Parameter()]
    [ValidateSet('minimal', 'default', 'aggressive', 'gaming', 'opinionated')]
    [string[]] $Profile,

    [Parameter()]
    [string[]] $EnableCatalogId,

    [Parameter()]
    [string[]] $DisableCatalogId,

    [Parameter()]
    [ValidateSet('CurrentUser', 'FutureUsers', 'Both')]
    [string] $Scope,

    [Parameter()]
    [ValidateSet('amd64', 'arm64')]
    [string] $Architecture,

    [Parameter()]
    [switch] $InstallWsl,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $WslDistribution,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $ToolkitFolder,

    [Parameter()]
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import the shipped module (single source of change logic - Principle V).
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'src/WindowsIsoMaker'
Import-Module -Name $modulePath -Force -ErrorAction Stop

# Forward only the parameters the user actually set, so command defaults stay authoritative.
$usbParams = @{ Path = $Path }
foreach ($name in 'Mode', 'Profile', 'EnableCatalogId', 'DisableCatalogId', 'Scope', 'Architecture', 'WslDistribution', 'ToolkitFolder') {
    if ($PSBoundParameters.ContainsKey($name)) {
        $usbParams[$name] = $PSBoundParameters[$name]
    }
}
foreach ($switchName in 'InstallWsl', 'Force') {
    if ($PSBoundParameters.ContainsKey($switchName)) {
        $usbParams[$switchName] = [switch]$PSBoundParameters[$switchName]
    }
}

# Honor -WhatIf from the dispatcher through to the command (preview path, FR-016).
if ($WhatIfPreference) {
    $usbParams['WhatIf'] = $true
}

New-PostInstallUsb @usbParams
