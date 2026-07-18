<#
    Private, mockable seams around wsl.exe and WSL readiness detection, used by the public
    Install-WslDistribution installer. Like the DISM/registry seams, these exist so the Pester
    suite can exercise the logic on ANY platform (wsl.exe only exists on Windows) by mocking these
    wrappers. State-changing / -WhatIf gating lives in the public function.

    Note on the WSL "corrupted" state: after the optional features are enabled but before the WSL
    app + kernel are installed, `wsl.exe` reports Wsl/CallMsi/Install/REGDB_E_CLASSNOTREG and, for
    some verbs, interactively prompts to repair AND can take a long time (tens of seconds) to
    respond. So the DETECTION calls (--status / --list) run with a short timeout: if wsl.exe does
    not answer within $script:WslDetectTimeoutSeconds it is assumed broken/not-functional and the
    process is killed, rather than blocking the whole run on the repair prompt. WSL_UTF8=1 is set so
    list/status output is clean UTF-8 (wsl.exe otherwise emits UTF-16LE), and detection relies on
    exit codes rather than parsing localized text.
#>

# How long the read-only DETECTION calls (--status / --list) wait for wsl.exe before assuming it is
# not functional. The long-running install/update calls pass no timeout (unbounded).
$script:WslDetectTimeoutSeconds = 5

function Invoke-WslExe {
    <#
    .SYNOPSIS
        Run wsl.exe with the given arguments and capture output + exit code (mockable seam), with
        an optional timeout for the read-only detection calls.
    .DESCRIPTION
        WSL_UTF8=1 forces clean UTF-8 output. When -TimeoutSeconds is greater than 0, wsl.exe is
        run with redirected streams (stdin from an empty file so a "press any key to repair" prompt
        gets EOF instead of hanging) and killed if it does not exit within the timeout — the result
        is then reported as a non-zero exit with TimedOut = $true, so callers treat WSL as broken.
        -TimeoutSeconds = 0 (default) waits indefinitely, for the legitimately long-running
        `wsl --install` / `wsl --update`.
    .PARAMETER Arguments
        wsl.exe arguments as an array.
    .PARAMETER TimeoutSeconds
        Maximum seconds to wait before killing wsl.exe and reporting a timeout. 0 = no timeout.
    .OUTPUTS
        PSCustomObject with ExitCode (int), Output (string[]) and TimedOut (bool).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter()][int] $TimeoutSeconds = 0
    )

    $previous = $env:WSL_UTF8
    $env:WSL_UTF8 = '1'
    try {
        if ($TimeoutSeconds -le 0) {
            $output = @(& wsl.exe @Arguments 2>&1 | ForEach-Object { $_.ToString() })
            return [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output   = $output
                TimedOut = $false
            }
        }

        # Bounded detection call: redirect streams and kill wsl.exe if it hangs (e.g. on the
        # REGDB repair prompt) so a single slow query cannot stall the whole run.
        $outFile = [System.IO.Path]::GetTempFileName()
        $errFile = [System.IO.Path]::GetTempFileName()
        $inFile = [System.IO.Path]::GetTempFileName()
        try {
            $proc = Start-Process -FilePath 'wsl.exe' -ArgumentList $Arguments -NoNewWindow -PassThru `
                -RedirectStandardOutput $outFile -RedirectStandardError $errFile -RedirectStandardInput $inFile
            if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
                try { $proc.Kill() } catch { Write-Verbose "wsl.exe already exited before Kill: $($_.Exception.Message)" }
                return [pscustomobject]@{
                    ExitCode = 258  # WAIT_TIMEOUT
                    Output   = @("wsl.exe did not respond within $TimeoutSeconds second(s); assuming WSL is not functional.")
                    TimedOut = $true
                }
            }
            $lines = @()
            $bom = [string][char]0xFEFF
            foreach ($file in @($outFile, $errFile)) {
                if (Test-Path -LiteralPath $file) {
                    # Decode explicitly as UTF-8 (WSL_UTF8=1) via .NET so a leading BOM is stripped
                    # at the file level and distribution names parse cleanly (Get-Content's encoding
                    # guess can mangle them, breaking the `wsl --list` idempotency check).
                    $text = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
                    if ($text) {
                        $lines += @(
                            ($text -split "`r?`n") |
                                ForEach-Object { (($_ -replace "`0", '').Replace($bom, '')).TrimEnd() }
                        )
                    }
                }
            }
            return [pscustomobject]@{
                ExitCode = $proc.ExitCode
                Output   = $lines
                TimedOut = $false
            }
        }
        finally {
            Remove-Item -LiteralPath $outFile, $errFile, $inFile -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        $env:WSL_UTF8 = $previous
    }
}

function Test-PendingReboot {
    <#
    .SYNOPSIS
        Return whether Windows has a pending reboot (mockable seam).
    .DESCRIPTION
        Checks the well-known servicing "reboot pending" signals: the Component Based Servicing
        RebootPending key and the Windows Update Auto Update RebootRequired key. Used by
        Install-WslDistribution so that, right after the WSL optional features are enabled (which
        marks a pending reboot), it stops and asks for a reboot BEFORE attempting `wsl --update`
        (which needs the virtualization platform actually active, not just flagged Enabled).
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($key in $keys) {
        if (Test-Path -LiteralPath $key -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Test-WslCommandFunctional {
    <#
    .SYNOPSIS
        Return whether wsl.exe is installed and functional (the WSL app/kernel are registered).
    .DESCRIPTION
        Runs `wsl.exe --status` with a short timeout ($script:WslDetectTimeoutSeconds): exit code 0
        means WSL is registered and usable. A non-zero exit or a timeout (e.g. the
        REGDB_E_CLASSNOTREG "corrupted"/not-installed state, which can also hang for tens of seconds
        on the repair prompt) means not-functional.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        $result = Invoke-WslExe -Arguments @('--status') -TimeoutSeconds $script:WslDetectTimeoutSeconds
        return ($result.ExitCode -eq 0)
    }
    catch {
        return $false
    }
}

function Get-WslInstalledDistribution {
    <#
    .SYNOPSIS
        Return the names of the currently installed WSL distributions (empty when none/not ready).
    .DESCRIPTION
        Parses `wsl.exe --list --quiet` (WSL_UTF8=1 -> clean UTF-8) with a short timeout. Returns an
        empty array when WSL is not functional, times out, or has no distribution installed, so
        callers can treat it as advisory.
    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    try {
        $result = Invoke-WslExe -Arguments @('--list', '--quiet') -TimeoutSeconds $script:WslDetectTimeoutSeconds
        if ($result.ExitCode -ne 0) { return [string[]]@() }
        return [string[]]@(
            @($result.Output) |
                ForEach-Object { ($_ -replace "`0", '').Trim() } |
                Where-Object { $_ }
        )
    }
    catch {
        return [string[]]@()
    }
}

function Update-WslKernel {
    <#
    .SYNOPSIS
        Install/repair the WSL app and update the WSL 2 kernel (`wsl.exe --update`).
    .DESCRIPTION
        This resolves the REGDB_E_CLASSNOTREG "corrupted" state once the platform features are
        enabled: it installs the modern WSL app + kernel. -Servicing selects the download source:
        'Store' (default, `wsl --update`) or 'WebDownload' (`wsl --update --web-download`, from
        GitHub instead of the Microsoft Store — more reliable in automation / when the Store is
        blocked). Exit code 0 (and 3010, reboot-required) are treated as success by the caller.

        Not used for 'Inbox' servicing: the inbox component is serviced by Windows Update, not by
        `wsl --update`, so the caller skips this step for Inbox.
    .PARAMETER Servicing
        'Store' (default) or 'WebDownload'.
    .OUTPUTS
        PSCustomObject (ExitCode, Output) from Invoke-WslExe.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][ValidateSet('Store', 'WebDownload')][string] $Servicing = 'Store'
    )
    $arguments = @('--update')
    if ($Servicing -eq 'WebDownload') { $arguments += '--web-download' }
    return Invoke-WslExe -Arguments $arguments
}

function Install-WslDistributionPackage {
    <#
    .SYNOPSIS
        Install WSL and a named distribution without launching its first-run setup
        (`wsl.exe --install -d <name> --no-launch`), selecting the servicing source.
    .DESCRIPTION
        --no-launch installs the distribution without starting the interactive account-creation
        experience, so the install is non-interactive and idempotent; the user creates their Linux
        account the first time they run `wsl -d <name>`. -Servicing selects how WSL itself is
        obtained:
          * Store       — the Microsoft Store package (default modern engine).
          * WebDownload — the modern engine from GitHub (`--web-download`), no Store dependency.
          * Inbox       — the in-Windows optional component (`--inbox`), serviced by Windows Update
                          (older engine, but hermetic/offline-friendly and consistent with an image
                          that baked the WSL optional features).
    .PARAMETER Distribution
        The distribution name (e.g. 'Debian').
    .PARAMETER Servicing
        'Store' (default), 'WebDownload', or 'Inbox'.
    .OUTPUTS
        PSCustomObject (ExitCode, Output) from Invoke-WslExe.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string] $Distribution,
        [Parameter()][ValidateSet('Store', 'WebDownload', 'Inbox')][string] $Servicing = 'Store'
    )
    $arguments = @('--install', '-d', $Distribution, '--no-launch')
    switch ($Servicing) {
        'WebDownload' { $arguments += '--web-download' }
        'Inbox' { $arguments += '--inbox' }
    }
    return Invoke-WslExe -Arguments $arguments
}

function Restart-WindowsComputer {
    <#
    .SYNOPSIS
        Restart the computer (mockable seam so -AutoReboot is testable without rebooting the host).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param()
    Restart-Computer -Force
}

function Invoke-WslRebootIfRequested {
    <#
    .SYNOPSIS
        Restart the computer when -AutoReboot was requested (private helper for
        Install-WslDistribution).
    .DESCRIPTION
        Declares SupportsShouldProcess so -WhatIf (inherited via $WhatIfPreference from the calling
        Install-WslDistribution) still gates the restart; the actual reboot runs through the
        mockable Restart-WindowsComputer seam.
    .PARAMETER AutoReboot
        Whether the caller asked for an automatic reboot.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    param(
        [Parameter()][switch] $AutoReboot
    )
    if (-not $AutoReboot) { return }
    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Restart-Computer (WSL install)')) {
        Write-BuildLog -Level Warning -Component 'Install-WslDistribution' -Message 'Rebooting now (-AutoReboot); re-run Install-WslDistribution after the machine is back to continue.'
        Restart-WindowsComputer
    }
}
