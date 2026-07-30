#Requires -Version 5.1
<#
.SYNOPSIS
    Generators for the self-contained post-install bootstrap staged onto a USB stick by
    New-PostInstallUsb.
.DESCRIPTION
    The bootstrap is what actually runs on the freshly installed machine - either automatically
    (first logon, via the minimal Autounattend.xml) or manually (double-clicking the .cmd). It is
    generated rather than shipped verbatim so the chosen profile / catalog ids / scope are baked
    in as readable, editable settings.

    Generated code follows the same rules as committed code: no aliases, full parameter names,
    strict mode, and $ErrorActionPreference = 'Stop'.
#>

function ConvertTo-PowerShellLiteral {
    <#
    .SYNOPSIS
        Render a string, boolean or string array as PowerShell source text.
    .DESCRIPTION
        Used to bake resolved settings into the generated bootstrap script. Strings are emitted
        single-quoted with embedded quotes doubled, so no injected value can break out of the
        literal.
    .PARAMETER Value
        The value to render ([string], [bool] or [string[]]).
    .EXAMPLE
        ConvertTo-PowerShellLiteral -Value @('gaming','opinionated')   # -> @('gaming', 'opinionated')
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { if ($Value) { return '$true' } else { return '$false' } }

    if ($Value -is [array]) {
        $items = @($Value | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" })
        return '@(' + ($items -join ', ') + ')'
    }

    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function New-PostInstallBootstrapScript {
    <#
    .SYNOPSIS
        Generate the PowerShell bootstrap that applies the catalog on the freshly installed PC.
    .DESCRIPTION
        The generated script self-elevates when needed, copies the staged toolkit from the USB
        stick to %ProgramData%\windows-iso-maker (so the run survives the stick being unplugged and
        can be repeated after a reboot), starts a transcript, and then invokes the staged
        post-install.ps1 with the settings baked in here.
    .PARAMETER Profile
        Catalog profile baseline(s) to bake in.
    .PARAMETER EnableCatalogId
        Catalog ids to force-enable.
    .PARAMETER DisableCatalogId
        Catalog ids to force-disable.
    .PARAMETER Scope
        Per-user scope ('CurrentUser' | 'FutureUsers' | 'Both').
    .PARAMETER Architecture
        Target architecture ('amd64' | 'arm64').
    .PARAMETER InstallWsl
        $true/$false to force the WSL install on or off; $null to leave it to the profile default.
    .PARAMETER WslDistribution
        Distribution to install when WSL is included.
    .EXAMPLE
        New-PostInstallBootstrapScript -Profile @('opinionated') -Scope Both -Architecture amd64
    .OUTPUTS
        System.String - the generated script text.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure generator: returns the script text as a string and writes nothing. The caller (New-PostInstallUsb) owns ShouldProcess for the actual file write.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', 'Profile',
        Justification = "'Profile' is the documented, user-facing catalog concept. The parameter is locally scoped and never writes the global profile path.")]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Profile,

        [Parameter()]
        [string[]] $EnableCatalogId = @(),

        [Parameter()]
        [string[]] $DisableCatalogId = @(),

        [Parameter(Mandatory = $true)]
        [ValidateSet('CurrentUser', 'FutureUsers', 'Both')]
        [string] $Scope,

        [Parameter(Mandatory = $true)]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter()]
        [AllowNull()]
        [object] $InstallWsl = $null,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $WslDistribution = 'Debian'
    )

    $settings = [System.Collections.Generic.List[string]]::new()
    $settings.Add("    Profile          = $(ConvertTo-PowerShellLiteral -Value @($Profile))")
    $settings.Add("    Scope            = $(ConvertTo-PowerShellLiteral -Value $Scope)")
    $settings.Add("    Architecture     = $(ConvertTo-PowerShellLiteral -Value $Architecture)")
    if (@($EnableCatalogId).Count -gt 0) {
        $settings.Add("    EnableCatalogId  = $(ConvertTo-PowerShellLiteral -Value @($EnableCatalogId))")
    }
    if (@($DisableCatalogId).Count -gt 0) {
        $settings.Add("    DisableCatalogId = $(ConvertTo-PowerShellLiteral -Value @($DisableCatalogId))")
    }
    if ($null -ne $InstallWsl) {
        $settings.Add("    InstallWsl       = $(ConvertTo-PowerShellLiteral -Value ([bool]$InstallWsl))")
        $settings.Add("    WslDistribution  = $(ConvertTo-PowerShellLiteral -Value $WslDistribution)")
    }

    $settingsBlock = $settings -join [Environment]::NewLine

    # Single-quoted here-strings: nothing inside is expanded, so the generated script keeps its own
    # $variables. The settings block is spliced in afterwards.
    $header = @'
#Requires -Version 5.1
<#
.SYNOPSIS
    Apply the windows-iso-maker change catalog to THIS machine.
.DESCRIPTION
    Generated by New-PostInstallUsb and staged on the Windows 11 installation USB stick. It
    self-elevates, copies the toolkit from the stick to %ProgramData%\windows-iso-maker so the run
    survives the stick being unplugged (and can be repeated after a reboot), and then runs
    post-install.ps1 with the settings below.

    Safe to re-run: every catalog change is idempotent.
.PARAMETER Preview
    Preview every change without applying anything (forwards -WhatIf). Needs no elevation.
.EXAMPLE
    .\Invoke-PostInstall.ps1 -Preview
.NOTES
    Edit the $PostInstallSettings block below to change what is applied.
#>
[CmdletBinding()]
param(
    [switch] $Preview
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Settings baked in when the USB stick was prepared. Edit freely. ---
$PostInstallSettings = @{
'@

    $footer = @'
}

$LocalRoot = Join-Path -Path $env:ProgramData -ChildPath 'windows-iso-maker'
$LogDirectory = Join-Path -Path $LocalRoot -ChildPath 'logs'

# --- Elevation: machine-wide (HKLM / DISM) changes need it; a preview does not. ---
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $identity
$isElevated = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isElevated -and -not $Preview) {
    Write-Host 'Elevation required - relaunching as administrator...'
    $relaunchArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $relaunchArguments -Wait
    return
}

# --- Copy the toolkit off the removable stick so the run survives unplugging and reboots. ---
if ($PSScriptRoot -ne $LocalRoot) {
    New-Item -ItemType Directory -Path $LocalRoot -Force | Out-Null
    Get-ChildItem -LiteralPath $PSScriptRoot -Force |
        Where-Object { $_.Name -ne 'logs' -and $_.Name -ne 'out' } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $LocalRoot -Recurse -Force }
}

New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
$transcriptPath = Join-Path -Path $LogDirectory -ChildPath ('post-install-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -LiteralPath $transcriptPath | Out-Null

try {
    $postInstallScript = Join-Path -Path $LocalRoot -ChildPath 'post-install.ps1'
    if (-not (Test-Path -LiteralPath $postInstallScript)) {
        throw "post-install.ps1 was not found at '$postInstallScript'. Re-stage the USB stick with New-PostInstallUsb."
    }

    $parameters = @{}
    foreach ($key in $PostInstallSettings.Keys) { $parameters[$key] = $PostInstallSettings[$key] }
    $parameters['OutputDirectory'] = Join-Path -Path $LocalRoot -ChildPath 'out'
    if ($Preview) { $parameters['WhatIf'] = $true }

    & $postInstallScript @parameters
}
finally {
    Stop-Transcript | Out-Null
}
'@

    return ($header, $settingsBlock, $footer) -join [Environment]::NewLine
}

function New-PostInstallLauncherCmd {
    <#
    .SYNOPSIS
        Generate the .cmd launcher that runs the bootstrap from Explorer.
    .DESCRIPTION
        A one-line batch wrapper so the staged toolkit can be started by double-clicking it on the
        stick. The bootstrap it launches self-elevates, so no "run as administrator" is needed.
    .EXAMPLE
        New-PostInstallLauncherCmd
    .OUTPUTS
        System.String - the generated .cmd text.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure generator: returns the .cmd text as a string and writes nothing. The caller (New-PostInstallUsb) owns ShouldProcess for the actual file write.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return @'
@echo off
REM Generated by windows-iso-maker (New-PostInstallUsb).
REM Runs the staged post-install bootstrap; it self-elevates when needed.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-PostInstall.ps1" %*
'@
}
