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
    .PARAMETER WslServicing
        How WSL itself is obtained: 'Store', 'WebDownload' or 'Inbox'.
    .PARAMETER WslAutoReboot
        Let the staged run reboot automatically when the WSL install needs it.
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
        [string] $WslDistribution = 'Debian',

        [Parameter()]
        [ValidateSet('Store', 'WebDownload', 'Inbox')]
        [string] $WslServicing = 'Store',

        [Parameter()]
        [switch] $WslAutoReboot
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
    }
    # WSL servicing settings only matter when the staged run installs WSL, which the 'opinionated'
    # profile implies even without an explicit -InstallWsl.
    if ($null -ne $InstallWsl -or @($Profile) -contains 'opinionated') {
        $settings.Add("    WslDistribution  = $(ConvertTo-PowerShellLiteral -Value $WslDistribution)")
        $settings.Add("    WslServicing     = $(ConvertTo-PowerShellLiteral -Value $WslServicing)")
        if ($WslAutoReboot.IsPresent) {
            $settings.Add("    WslAutoReboot    = `$true")
        }
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

# --- Breadcrumb log. Written FIRST and independently of the transcript, because the most
#     confusing failures (first logon not elevated, UAC cancelled, stick already unplugged)
#     happen before any real work starts. Without this they would be completely silent on a
#     machine that has no other diagnostics. ---
$BreadcrumbLog = Join-Path -Path $LogDirectory -ChildPath 'bootstrap.log'
function Write-Breadcrumb {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message
    )
    $line = '{0} {1}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $Message
    Write-Host $line
    try {
        if (-not (Test-Path -LiteralPath $LogDirectory)) {
            New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
        }
        Add-Content -LiteralPath $BreadcrumbLog -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # A breadcrumb must never be the thing that breaks the run.
    }
}

Write-Breadcrumb "Bootstrap started from '$PSScriptRoot' (Preview=$($Preview.IsPresent), User='$env:USERNAME')."

# --- Elevation: machine-wide (HKLM / DISM) changes need it; a preview does not.
#     At first logon this script inherits the signed-in user's token. Microsoft documents that
#     FirstLogonCommands only run elevated when that user is a local administrator; a standard
#     user gets a consent prompt, or nothing runs at all. That case is reported loudly here
#     instead of silently doing nothing. ---
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $identity
$isElevated = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isElevated -and -not $Preview) {
    Write-Breadcrumb 'Not elevated - relaunching as administrator...'
    try {
        $relaunchArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
        $child = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $relaunchArguments -Wait -PassThru -ErrorAction Stop
        # Start-Process succeeding only means the process STARTED. Check that it actually did the
        # work: a child that dies immediately (for example because the script path is not reachable
        # from the elevated session) would otherwise be reported as a success.
        if ($null -ne $child -and $child.ExitCode -ne 0) {
            Write-Breadcrumb "ELEVATED RUN FAILED with exit code $($child.ExitCode). NOTHING MAY HAVE BEEN APPLIED - check the entries above and re-run '$PSCommandPath' from an elevated prompt."
            Write-Warning "windows-iso-maker: the elevated run exited with code $($child.ExitCode). See '$BreadcrumbLog'."
        }
        else {
            Write-Breadcrumb 'Elevated run finished.'
        }
    }
    catch {
        Write-Breadcrumb "ELEVATION FAILED: $($_.Exception.Message)"
        Write-Breadcrumb ("NOTHING WAS APPLIED. The signed-in account is not a local administrator, or the " +
            "consent prompt was declined. Sign in with an administrator account and run " +
            "'$PSCommandPath' again (or the copy under $LocalRoot).")
        Write-Warning "windows-iso-maker: no changes were applied. See '$BreadcrumbLog'."
    }
    return
}

# --- Copy the toolkit off the removable stick so the run survives unplugging and reboots. ---
try {
    if ($PSScriptRoot -ne $LocalRoot) {
        New-Item -ItemType Directory -Path $LocalRoot -Force | Out-Null
        Get-ChildItem -LiteralPath $PSScriptRoot -Force |
            Where-Object { $_.Name -ne 'logs' -and $_.Name -ne 'out' } |
            ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $LocalRoot -Recurse -Force }
        Write-Breadcrumb "Toolkit copied to '$LocalRoot'."
    }
}
catch {
    Write-Breadcrumb "TOOLKIT COPY FAILED: $($_.Exception.Message)"
    throw
}

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
    Write-Breadcrumb 'Post-install completed.'
}
catch {
    Write-Breadcrumb "POST-INSTALL FAILED: $($_.Exception.Message)"
    throw
}
finally {
    Stop-Transcript | Out-Null
}
'@

    return ($header, $settingsBlock, $footer) -join [Environment]::NewLine
}

function New-PostInstallDiscoveryCommand {
    <#
    .SYNOPSIS
        Generate the single command line that the first-logon answer file runs.
    .DESCRIPTION
        The USB stick's drive letter on the installed machine is not knowable when the stick is
        prepared, so the command scans the file-system drives for the staged bootstrap and runs the
        first one it finds. (The toolkit copy under %ProgramData% lives in a different folder, so it
        cannot be matched by accident.)

        Crucially, it writes a breadcrumb either way. A first logon that finds nothing - because the
        stick was unplugged, or the answer file outlived the toolkit - would otherwise fail
        completely silently on a machine with no other diagnostics.

        The result is embedded in XML inside a `powershell.exe -Command "..."` argument, so the
        generated code uses single quotes exclusively; it must contain no double quote.
    .PARAMETER ToolkitFolder
        Name of the folder holding the staged toolkit at the stick's root.
    .EXAMPLE
        New-PostInstallDiscoveryCommand -ToolkitFolder 'windows-iso-maker'
    .OUTPUTS
        System.String - the full command line.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure generator: returns the command line as a string and writes nothing. The caller (New-PostInstallUsb) owns ShouldProcess for the actual file write.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $ToolkitFolder
    )

    if ($ToolkitFolder.Contains("'") -or $ToolkitFolder.Contains('"')) {
        throw "ToolkitFolder must not contain quote characters: '$ToolkitFolder'."
    }

    $statements = @(
        "`$ErrorActionPreference='SilentlyContinue'"
        "`$logDirectory=Join-Path `$env:ProgramData 'windows-iso-maker\logs'"
        "New-Item -ItemType Directory -Path `$logDirectory -Force | Out-Null"
        "`$log=Join-Path `$logDirectory 'bootstrap.log'"
        "Add-Content -LiteralPath `$log -Value ((Get-Date).ToUniversalTime().ToString('o')+' First-logon discovery started.')"
        "`$found=`$null"
        "foreach (`$drive in (Get-PSDrive -PSProvider FileSystem)) { `$candidate=Join-Path `$drive.Root '$ToolkitFolder\Invoke-PostInstall.ps1'; if (Test-Path -LiteralPath `$candidate) { `$found=`$candidate; break } }"
        "if (`$found) { Add-Content -LiteralPath `$log -Value ((Get-Date).ToUniversalTime().ToString('o')+' Found toolkit at '+`$found); & `$found } else { Add-Content -LiteralPath `$log -Value ((Get-Date).ToUniversalTime().ToString('o')+' NO TOOLKIT FOUND - nothing was applied. Re-attach the prepared USB stick and run $ToolkitFolder\Invoke-PostInstall.ps1 manually.') }"
    )

    $script = $statements -join '; '
    return "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"$script`""
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
