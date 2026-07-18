function Install-WslDistribution {
    <#
    .SYNOPSIS
        Install WSL and a Linux distribution on the running machine using the modern single
        `wsl --install` command, with detection so it is idempotent and resumable across the
        reboots Windows requires.
    .DESCRIPTION
        On current Windows 11 builds `wsl --install -d <Distro> --no-launch` does everything in one
        command: it enables the required optional components, installs the WSL 2 kernel, and
        installs the distribution (new installs default to WSL 2). The only complication is that
        this spans one or more REBOOTS, so this command wraps it in a simple detect -> act ->
        reboot-and-re-run loop rather than a hand-rolled multi-stage machine:

            1. If <Distribution> is already installed        -> Done (idempotent).
            2. If a reboot is pending                        -> ask to reboot and re-run.
            3. Otherwise run `wsl --install -d <Distribution> --no-launch`.
            4. If wsl is still not functional afterwards (the REGDB_E_CLASSNOTREG half-provisioned
               state that occurs when the platform features were enabled offline in the image but
               the WSL app is not installed yet) -> run `wsl --update` once to install/repair the
               app + kernel.
            5. Re-check: distribution present -> Done; otherwise a reboot is needed -> ask to
               reboot and re-run.

        --no-launch installs the distribution without the interactive first-run account setup, so
        the whole flow is non-interactive; you create your Linux user the first time you run
        `wsl -d <Distribution>`. The target distribution is remembered (registry tattoo) so a
        resume after reboot can omit -Distribution.

        Requires an elevated session. Honours -WhatIf (previews the next action without changing
        anything).
    .PARAMETER Distribution
        The WSL distribution to install (default 'Debian'). Persisted so a resume after reboot
        continues installing the same distribution. Use `wsl --list --online` to see the choices.
    .PARAMETER WslServicing
        How WSL itself is obtained/serviced:
          * Store       — the Microsoft Store package (default modern WSL 2 engine).
          * WebDownload — the modern engine from GitHub (`--web-download`); no Store dependency, the
                          most reliable choice for automation / Store-blocked machines.
          * Inbox       — the in-Windows optional component (`--inbox`), serviced by Windows Update;
                          an older engine but hermetic/offline-friendly and consistent with an image
                          that baked the WSL optional features. For Inbox the `wsl --update` repair
                          step is skipped (the component is serviced by Windows Update, so a reboot,
                          not `wsl --update`, finishes it).
    .PARAMETER AutoReboot
        When a reboot is required, restart the computer automatically instead of only instructing
        the user to reboot and re-run.
    .EXAMPLE
        Install-WslDistribution -Distribution Debian
        Installs WSL + Debian via the Store engine; reboot and re-run until it reports Done.
    .EXAMPLE
        Install-WslDistribution -Distribution Debian -WslServicing WebDownload
        Installs the modern engine from GitHub (no Store dependency) + Debian.
    .EXAMPLE
        Install-WslDistribution -WhatIf
        Shows the next action without changing anything.
    .OUTPUTS
        PSCustomObject describing Distribution, Servicing, Stage, RebootRequired,
        DistributionInstalled and a Message.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Distribution = 'Debian',

        [Parameter()]
        [ValidateSet('Store', 'WebDownload', 'Inbox')]
        [string] $WslServicing = 'Store',

        [Parameter()]
        [switch] $AutoReboot
    )

    $isPreview = $WhatIfPreference

    if (-not $isPreview -and -not (Test-IsAdministrator)) {
        throw 'Install-WslDistribution must run in an elevated (Administrator) session to install WSL. Re-run as administrator, or use -WhatIf to preview.'
    }

    # The explicit parameter wins; otherwise resume with the persisted distribution.
    if (-not $PSBoundParameters.ContainsKey('Distribution')) {
        $persisted = Get-WimWslState -Name 'Distribution'
        if (-not [string]::IsNullOrWhiteSpace($persisted)) { $Distribution = $persisted }
    }

    $result = [pscustomobject]@{
        PSTypeName            = 'WindowsIsoMaker.WslInstallResult'
        Distribution          = $Distribution
        Servicing             = $WslServicing
        Stage                 = 'Unknown'
        RebootRequired        = $false
        DistributionInstalled = $false
        Message               = $null
    }

    if ($isPreview) {
        $result.Stage = 'Preview'
        $wouldSource = switch ($WslServicing) {
            'WebDownload' { " --web-download" }
            'Inbox' { " --inbox" }
            default { '' }
        }
        $result.Message = "Preview (-WhatIf): would run 'wsl --install -d $Distribution --no-launch$wouldSource' (installing the WSL platform, kernel and '$Distribution' via the $WslServicing servicing model) and, across the required reboot(s), verify the distribution is installed."
        return $result
    }

    Set-WimWslState -Name 'Distribution' -Value $Distribution
    Set-WimWslState -Name 'Servicing' -Value $WslServicing

    # 1. Idempotent: already installed? If the distribution is registered (appears in `wsl --list`)
    #    it is installed and we are done — do not attempt a reinstall (which would fail with
    #    ERROR_ALREADY_EXISTS). We check the list alone; being listed already implies WSL works.
    if (@(Get-WslInstalledDistribution) -icontains $Distribution) {
        $result.Stage = 'Done'
        $result.DistributionInstalled = $true
        $result.Message = "WSL is ready and '$Distribution' is installed. Launch it with 'wsl -d $Distribution' (the first launch creates your Linux user account)."
        Write-BuildLog -Level Information -Component 'Install-WslDistribution' -Message $result.Message
        return $result
    }

    # 2. A pending reboot must clear before wsl can make progress (e.g. features were just enabled).
    if (Test-PendingReboot) {
        $result.Stage = 'RebootRequired'
        $result.RebootRequired = $true
        $result.Message = "A REBOOT is pending before WSL can continue installing. Reboot, then re-run Install-WslDistribution to finish installing '$Distribution'."
        Write-BuildLog -Level Information -Component 'Install-WslDistribution' -Message $result.Message
        Invoke-WslRebootIfRequested -AutoReboot:$AutoReboot
        return $result
    }

    # 3. The single workhorse command: enables features + installs the WSL engine + the distro,
    #    from the selected servicing source (Store / GitHub web-download / inbox component).
    $rebootSignaled = $false
    $alreadyExists = $false
    if ($PSCmdlet.ShouldProcess("$Distribution ($WslServicing)", 'wsl --install -d <distro> --no-launch')) {
        $install = Install-WslDistributionPackage -Distribution $Distribution -Servicing $WslServicing
        $rebootSignaled = ($install.ExitCode -eq 3010)
        # A distribution that is already installed is not a failure — it is the idempotent case
        # (e.g. the pre-check list query was slow/empty, or the distro was installed but not yet
        # detected). wsl reports this as ERROR_ALREADY_EXISTS ("...file already exists") or, in some
        # builds, "already installed". Treat any of those as success.
        $joined = (@($install.Output) -join "`n")
        $alreadyExists = $joined -match '(?i)already installed|already exists|ERROR_ALREADY_EXISTS'
        # 0 = success, 3010 = success/reboot-required; already-exists = idempotent success.
        if ($install.ExitCode -ne 0 -and $install.ExitCode -ne 3010 -and -not $alreadyExists) {
            $tail = (@($install.Output) | Select-Object -Last 3) -join ' '
            throw "wsl --install -d $Distribution failed (exit $($install.ExitCode)): $tail"
        }
    }

    # 4. Self-heal the REGDB_E_CLASSNOTREG state (features enabled offline, engine not installed
    #    yet): `wsl --update` installs/repairs the modern WSL app + kernel. Only for the Store /
    #    WebDownload engines — the Inbox component is serviced by Windows Update (a reboot finishes
    #    it), not by `wsl --update`. Skipped when the distro already exists (WSL is clearly working).
    if ($WslServicing -ne 'Inbox' -and -not $alreadyExists -and -not (Test-WslCommandFunctional)) {
        if ($PSCmdlet.ShouldProcess('wsl --update', 'Install/repair the WSL app + kernel')) {
            $update = Update-WslKernel -Servicing $WslServicing
            if ($update.ExitCode -ne 0 -and $update.ExitCode -ne 3010) {
                $tail = (@($update.Output) | Select-Object -Last 3) -join ' '
                throw "wsl --update failed (exit $($update.ExitCode)): $tail"
            }
        }
    }

    # 5. Detect the outcome. NOTE: with `--no-launch` the distribution is installed (it appears in
    #    the Start menu) but is NOT registered in `wsl --list` until its first launch extracts the
    #    rootfs — so we must NOT require it to appear in `wsl --list` to call the install done.
    #    Done when the distro already exists, or WSL is functional and no reboot was signalled;
    #    otherwise a reboot is needed to bring the engine up.
    $functional = Test-WslCommandFunctional
    $listed = $functional -and (@(Get-WslInstalledDistribution) -icontains $Distribution)
    if (-not $rebootSignaled -and ($alreadyExists -or $functional)) {
        $result.Stage = 'Done'
        $result.DistributionInstalled = $true
        $result.Message = if ($listed -or $alreadyExists) {
            "Installed and registered '$Distribution'. Launch it with 'wsl -d $Distribution' (the first launch creates your Linux user account)."
        }
        else {
            "Installed WSL and '$Distribution'. Launch it once with 'wsl -d $Distribution' to finish first-time setup (extract the rootfs) and create your Linux user account; until then it will not appear in 'wsl --list'."
        }
    }
    else {
        $result.Stage = 'RebootRequired'
        $result.RebootRequired = $true
        $result.Message = "Started installing WSL and '$Distribution'. A REBOOT is required to finish. Reboot, then re-run Install-WslDistribution until it reports Done."
        Invoke-WslRebootIfRequested -AutoReboot:$AutoReboot
    }
    Write-BuildLog -Level Information -Component 'Install-WslDistribution' -Message $result.Message
    return $result
}
