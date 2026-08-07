function New-PostInstallUsb {
    <#
    .SYNOPSIS
        Prepare a Windows 11 USB installation stick so the post-install change catalog is carried
        with it - and, optionally, applied automatically at the first logon.
    .DESCRIPTION
        Point this at a USB stick you already flashed with a STOCK Windows 11 ISO (for example one
        downloaded from your Visual Studio subscription, written with Rufus or the Media Creation
        Tool). It validates the stick, stages this toolkit onto it, and - in the default
        'FirstLogon' mode - writes a MINIMAL Autounattend.xml to the stick's root that runs
        post-install once, elevated, at the first logon of the freshly installed machine.

        What it checks before touching anything:
          * the target exists and (on Windows, for a drive letter) is a REMOVABLE volume,
          * it really carries Windows Setup media (setup.exe, sources\install.wim|esd, boot loader),
          * the media architecture, derived from the UEFI boot loader (bootx64.efi / bootaa64.efi),
          * that the requested Profile / catalog ids resolve to a valid selection,
          * that there is enough free space for the staged toolkit.

        What it does NOT do: it never modifies the Windows Setup media itself, and it never writes
        the full build answer file. The rendered Autounattend.xml contains ONLY an oobeSystem
        FirstLogonCommands block, so Windows Setup stays exactly as it is on stock media -
        interactive edition and partition selection, normal OOBE, including an Entra ID sign-in.
        Nothing is repartitioned or wiped by this tool. (The unattended-install answer file, with
        disk layout and edition selection, belongs to the ISO build path - see New-AutounattendXml.)

        IMPORTANT - when the automatic run does NOT fire. Microsoft documents that
        FirstLogonCommands only run elevated if the first user to sign in is a local administrator;
        a standard user gets a consent prompt (and nothing runs if it is declined or if UAC is
        disabled). With an Entra ID sign-in, whether that account is a local administrator depends
        on your Entra/Intune device settings, so the automatic run is NOT guaranteed there.
        FirstLogonCommands also do not run in Autopilot pre-provisioning / self-deploying flows.
        The generated bootstrap therefore records what happened to
        %ProgramData%\windows-iso-maker\logs\bootstrap.log and warns loudly rather than failing
        silently; you can always re-run it by hand. Use -Mode Toolkit if you would rather not rely
        on the first-logon hook at all.

        The generated bootstrap copies the toolkit from the stick to
        %ProgramData%\windows-iso-maker before running it, so the changes survive the stick being
        removed and can be re-run after a reboot (WSL installs span reboots). Every run writes a
        transcript and the usual auditable run-report JSON.

        Use -Mode Toolkit to skip the answer file entirely and just carry the toolkit on the stick,
        which you then run by hand after signing in.
    .PARAMETER Path
        The USB stick to prepare: a drive specification ('E:' or 'E:\') or a directory.
    .PARAMETER Mode
        'FirstLogon' (default) stages the toolkit AND writes the minimal Autounattend.xml that runs
        it at the first logon. 'Toolkit' only stages the toolkit; you run it manually after signing
        in. Setup itself is interactive in both modes.
    .PARAMETER Profile
        Catalog profile baseline(s) the staged run will apply: one or more of 'minimal' |
        'default' | 'aggressive' | 'gaming' | 'opinionated' (UNIONed). Defaults to 'default'.
    .PARAMETER EnableCatalogId
        Opt-in catalog ids to force-enable in the staged run (e.g. 'remove-edge','feature-wsl').
    .PARAMETER DisableCatalogId
        Catalog ids to force-disable in the staged run (explicit ids win).
    .PARAMETER Scope
        Which per-user targets the staged run touches: 'CurrentUser', 'FutureUsers' or 'Both'
        (default).
    .PARAMETER Architecture
        Override the target architecture ('amd64' | 'arm64'). Auto-detected from the media's UEFI
        boot loader when omitted, falling back to the running host.
    .PARAMETER InstallWsl
        Have the staged run also install WSL and a distribution. Implied by the 'opinionated'
        profile; pass -InstallWsl:$false to suppress it there.
    .PARAMETER WslDistribution
        The Linux distribution the staged run installs when WSL is included (default 'Debian').
    .PARAMETER WslServicing
        How the staged run obtains WSL: 'Store' (default), 'WebDownload' or 'Inbox'.
    .PARAMETER WslAutoReboot
        Let the staged run reboot the machine automatically when the WSL install needs it.
    .PARAMETER ToolkitFolder
        Folder name created at the stick's root to hold the toolkit. Defaults to
        'windows-iso-maker'.
    .PARAMETER Force
        Proceed even when the target is the root of a non-removable drive or does not look like
        Windows Setup media, and overwrite an existing Autounattend.xml or staged toolkit folder.
    .EXAMPLE
        New-PostInstallUsb -Path E: -Profile opinionated
        Stages the toolkit on E: and hooks the opinionated profile into the first logon.
    .EXAMPLE
        New-PostInstallUsb -Path E: -Profile opinionated -WhatIf
        Validates the stick and shows exactly what would be staged, writing nothing.
    .EXAMPLE
        New-PostInstallUsb -Path E: -Mode Toolkit -Profile gaming,opinionated
        Only carries the toolkit on the stick; run it yourself after signing in.
    .OUTPUTS
        PSCustomObject (WindowsIsoMaker.PostInstallUsbResult).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', 'Profile',
        Justification = "'Profile' is the documented, user-facing catalog concept (minimal/default/aggressive/gaming/opinionated). The parameter is locally scoped and never writes the global profile path.")]
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [ValidateSet('FirstLogon', 'Toolkit')]
        [string] $Mode = 'FirstLogon',

        [Parameter()]
        [ValidateSet('minimal', 'default', 'aggressive', 'gaming', 'opinionated')]
        [string[]] $Profile = @('default'),

        [Parameter()]
        [string[]] $EnableCatalogId = @(),

        [Parameter()]
        [string[]] $DisableCatalogId = @(),

        [Parameter()]
        [ValidateSet('CurrentUser', 'FutureUsers', 'Both')]
        [string] $Scope = 'Both',

        [Parameter()]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter()]
        [switch] $InstallWsl,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $WslDistribution = 'Debian',

        [Parameter()]
        [ValidateSet('Store', 'WebDownload', 'Inbox')]
        [string] $WslServicing = 'Store',

        [Parameter()]
        [switch] $WslAutoReboot,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ToolkitFolder = 'windows-iso-maker',

        [Parameter()]
        [switch] $Force
    )

    $isPreview = $WhatIfPreference
    $repoRoot = Split-Path -Parent (Split-Path -Parent $script:ModuleRoot)

    # --- 1. Probe the target volume. ---
    $target = Get-UsbTargetInfo -Path $Path
    if (-not $target.Exists) {
        throw "USB target '$($target.Path)' was not found. Plug the stick in (or pass an existing directory) and retry."
    }

    # Guard the dangerous case: writing to the root of a FIXED volume (e.g. C:\) because a drive
    # letter was mistyped. A folder target is an explicit choice and is always allowed.
    if ($target.IsVolumeRoot -and $target.IsRemovable -eq $false -and -not $Force.IsPresent) {
        throw ("Target '$($target.Path)' is the root of a FIXED drive (DriveType=$($target.DriveType)), not a removable USB stick. " +
            'Refusing to write to it by accident - re-run with -Force if this really is your target.')
    }
    if ($target.IsVolumeRoot -and $null -eq $target.IsRemovable) {
        Write-BuildLog -Level Verbose -Component 'New-PostInstallUsb' -Message "Could not determine whether '$($target.Path)' is removable; continuing."
    }

    # --- 2. Validate that the stick actually carries Windows Setup media. ---
    $media = Test-WindowsSetupMedia -Path $target.Path
    if (-not $media.IsSetupMedia) {
        $detail = "Missing: $($media.Missing -join ', ')."
        if (-not $Force.IsPresent) {
            throw ("'$($target.Path)' does not look like Windows 11 installation media. $detail " +
                'Write your Windows 11 ISO to the stick first (e.g. with Rufus or the Media Creation Tool), then re-run. ' +
                'Use -Force to stage the toolkit anyway.')
        }
        Write-BuildLog -Level Warning -Component 'New-PostInstallUsb' -Message "'$($target.Path)' does not look like Windows installation media ($detail) - continuing because -Force was supplied."
    }

    # --- 3. Resolve the architecture: media boot loader > explicit override > running host. ---
    $mediaArch = Get-SetupMediaArchitecture -Path $target.Path
    $arch = if ($PSBoundParameters.ContainsKey('Architecture') -and $Architecture) {
        if ($mediaArch -and $mediaArch -ne $Architecture) {
            Write-BuildLog -Level Warning -Component 'New-PostInstallUsb' -Message "Media looks like '$mediaArch' but -Architecture '$Architecture' was supplied; using '$Architecture'."
        }
        $Architecture
    }
    elseif ($mediaArch) { $mediaArch }
    else { Get-OnlineArchitecture }

    # --- 4. Validate the requested selection now, so a bad id fails here and not on the new PC. ---
    $catalog = Import-ChangeCatalog
    $selected = @(Resolve-CatalogSelection -Catalog $catalog -Architecture $arch `
            -Profile $Profile -Toggles @{} `
            -EnableCatalogId @($EnableCatalogId) -DisableCatalogId @($DisableCatalogId))

    $toolkitPath = Join-Path -Path $target.Path -ChildPath $ToolkitFolder
    $bootstrapPath = Join-Path -Path $toolkitPath -ChildPath 'Invoke-PostInstall.ps1'
    $launcherPath = Join-Path -Path $toolkitPath -ChildPath 'Invoke-PostInstall.cmd'
    $autounattendPath = Join-Path -Path $target.Path -ChildPath 'Autounattend.xml'

    Write-BuildLog -Level Information -Component 'New-PostInstallUsb' -Message "Preparing '$($target.Path)' (Mode=$Mode, Arch=$arch, Profile=$($Profile -join ','), Entries=$($selected.Count), Preview=$isPreview)."

    # --- 5. Work out what to stage and whether it fits. ---
    $sourceItems = @('src', 'config', 'post-install.ps1', 'docs', 'LICENSE') |
        ForEach-Object { Join-Path -Path $repoRoot -ChildPath $_ } |
        Where-Object { Test-Path -LiteralPath $_ }

    $stagedBytes = 0L
    foreach ($item in $sourceItems) {
        if (Test-Path -LiteralPath $item -PathType Container) {
            $stagedBytes += (Get-ChildItem -LiteralPath $item -Recurse -File |
                    Measure-Object -Property Length -Sum).Sum
        }
        else {
            $stagedBytes += (Get-Item -LiteralPath $item).Length
        }
    }

    if ($null -ne $target.FreeSpaceByte -and $target.FreeSpaceByte -lt ($stagedBytes * 2)) {
        throw ("Not enough free space on '$($target.Path)': need about $([math]::Round(($stagedBytes * 2) / 1MB, 1)) MB, " +
            "but only $([math]::Round($target.FreeSpaceByte / 1MB, 1)) MB is free.")
    }

    # --- 6. Refuse to silently clobber an answer file the user put there. ---
    if ($Mode -eq 'FirstLogon' -and (Test-Path -LiteralPath $autounattendPath) -and -not $Force.IsPresent) {
        throw "'$autounattendPath' already exists. Re-run with -Force to overwrite it, or use -Mode Toolkit to leave it alone."
    }

    # --- 7. Stage the toolkit onto the stick (idempotent: the folder is replaced wholesale). ---
    $stagedFileCount = 0
    if ($PSCmdlet.ShouldProcess($toolkitPath, "Stage the windows-iso-maker toolkit ($([math]::Round($stagedBytes / 1MB, 1)) MB)")) {
        if (Test-Path -LiteralPath $toolkitPath) {
            Remove-Item -LiteralPath $toolkitPath -Recurse -Force
        }
        New-Item -ItemType Directory -Path $toolkitPath -Force | Out-Null
        foreach ($item in $sourceItems) {
            Copy-Item -LiteralPath $item -Destination $toolkitPath -Recurse -Force
        }
        $stagedFileCount = @(Get-ChildItem -LiteralPath $toolkitPath -Recurse -File).Count
        Write-BuildLog -Level Information -Component 'New-PostInstallUsb' -Message "Staged $stagedFileCount file(s) -> '$toolkitPath'."
    }

    # --- 8. Generate the self-contained bootstrap that the first logon (or you) runs. ---
    $installWslArgument = $null
    if ($PSBoundParameters.ContainsKey('InstallWsl')) { $installWslArgument = [bool]$InstallWsl }

    $bootstrapScript = New-PostInstallBootstrapScript -Profile $Profile -EnableCatalogId @($EnableCatalogId) `
        -DisableCatalogId @($DisableCatalogId) -Scope $Scope -Architecture $arch `
        -InstallWsl $installWslArgument -WslDistribution $WslDistribution `
        -WslServicing $WslServicing -WslAutoReboot:$WslAutoReboot

    if ($PSCmdlet.ShouldProcess($bootstrapPath, 'Write the post-install bootstrap')) {
        Set-Content -LiteralPath $bootstrapPath -Value $bootstrapScript -Encoding UTF8
        Set-Content -LiteralPath $launcherPath -Value (New-PostInstallLauncherCmd) -Encoding Ascii
    }

    # --- 9. Hook it into the first logon via the MINIMAL answer file (never the build one). ---
    $writtenAutounattend = $null
    if ($Mode -eq 'FirstLogon') {
        $command = New-PostInstallDiscoveryCommand -ToolkitFolder $ToolkitFolder

        $description = "Runs the windows-iso-maker '$($Profile -join ',')' profile ($($selected.Count) catalog entries) once at first logon."
        $xml = New-FirstLogonUnattendXml -Command $command -Architecture $arch -Description $description

        if ($PSCmdlet.ShouldProcess($autounattendPath, 'Write the first-logon Autounattend.xml')) {
            # UTF-8 WITHOUT a BOM: Set-Content -Encoding UTF8 emits a BOM under Windows PowerShell
            # 5.1, which contradicts the repository's encoding rule.
            [System.IO.File]::WriteAllText($autounattendPath, $xml, (New-Object System.Text.UTF8Encoding($false)))
            Write-BuildLog -Level Information -Component 'New-PostInstallUsb' -Message "Wrote first-logon Autounattend.xml -> '$autounattendPath'."
        }
        $writtenAutounattend = $autounattendPath
    }

    $nextSteps = if ($Mode -eq 'FirstLogon') {
        @(
            "Boot the target PC from '$($target.Path)' and install Windows normally (edition, disk and OOBE stay interactive).",
            "Sign in for the first time - the catalog is applied automatically IF that account is a local administrator (see docs/usb.md).",
            "Check C:\ProgramData\windows-iso-maker\logs\bootstrap.log to confirm it ran; the run report lands in ...\out\.",
            'Re-run the same bootstrap after a reboot if WSL asked for one.'
        )
    }
    else {
        @(
            "Boot the target PC from '$($target.Path)' and install Windows normally.",
            'Sign in, then run the staged toolkit elevated:',
            "    $ToolkitFolder\Invoke-PostInstall.cmd   (from the stick; it self-elevates)"
        )
    }

    return [pscustomobject]@{
        PSTypeName         = 'WindowsIsoMaker.PostInstallUsbResult'
        Path               = $target.Path
        DriveLetter        = $target.DriveLetter
        Label              = $target.Label
        FileSystem         = $target.FileSystem
        IsRemovable        = $target.IsRemovable
        MediaValidated     = $media.IsSetupMedia
        MediaImageFormat   = $media.ImageFormat
        MediaArchitecture  = $mediaArch
        Architecture       = $arch
        Mode               = $Mode
        Profile            = @($Profile)
        SelectedEntryCount = $selected.Count
        ToolkitPath        = $toolkitPath
        BootstrapPath      = $bootstrapPath
        LauncherPath       = $launcherPath
        AutounattendPath   = $writtenAutounattend
        StagedFileCount    = $stagedFileCount
        Preview            = $isPreview
        NextSteps          = $nextSteps
    }
}
