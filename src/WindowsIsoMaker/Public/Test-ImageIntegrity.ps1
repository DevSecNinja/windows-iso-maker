function Test-ImageIntegrity {
    <#
    .SYNOPSIS
        Validate a produced ISO structurally (default) with an optional VM boot test.
    .DESCRIPTION
        Performs default structural checks (FR-023): the media is readable, it contains a
        sources\install.wim|.esd image with a valid DISM index, and the architecture-specific
        boot files are present (amd64: boot\etfsboot.com + efi\microsoft\boot\efisys.bin;
        arm64: efi\microsoft\boot\efisys.bin). The heavier VM boot test (-BootTest) is opt-in
        and OFF by default. Returns an integrity result object listing each check.
    .PARAMETER IsoPath
        Path to the built ISO to validate.
    .PARAMETER Architecture
        Target architecture: 'amd64' or 'arm64'.
    .PARAMETER BootTest
        Opt-in: boot the ISO in a VM and confirm Windows Setup is reached. OFF by default.
    .PARAMETER KeepBootTestVm
        Opt-in: after the boot test resolves, keep the throwaway VM alive and pause until you
        press Enter so you can attach with vmconnect and test interactively. The VM (and its
        VHDX) are still torn down afterwards. Only meaningful together with -BootTest.
    .PARAMETER ConnectVm
        Opt-in: launch the interactive VM console (vmconnect.exe) as soon as the boot-test VM
        starts, so you can watch Windows Setup and press Shift+F10 to capture logs on a stall.
        Best-effort (skipped on headless/CI hosts). Only meaningful together with -BootTest.
    .PARAMETER ConnectNetwork
        Opt-in: give the boot-test VM a network connection (External switch preferred). Off by
        default on Hyper-V so the VM boots fully offline and ConX (the redesigned Setup on 24H2+
        media) does not depend on a flaky WinPE-phase DNS/NAT proxy. On VMware the boot test is
        NETWORKED by default (VMware NAT gives WinPE working DNS for ConX online validation); pass
        -ConnectNetwork:$false to force it offline there. Only meaningful together with -BootTest.
        Test-ImageIntegrity -IsoPath C:\out\win11.iso -Architecture amd64
    .PARAMETER Hypervisor
        Which hypervisor runs the -BootTest VM: 'HyperV' (default) or 'VMware' (VMware Workstation).
        VMware is offered because its NAT gives WinPE real DNS, which a 24H2+ ConX Setup online
        product-key/edition check needs. When VMware is selected but not installed, the boot test
        surfaces the winget install command and manual-download guidance instead of failing hard.
    .OUTPUTS
        PSCustomObject with Passed, Structural (per-check results), an optional Boot result, and
        DiagnosticsPath (folder where the boot-test Windows Setup logs were harvested, if any).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $IsoPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter()]
        [switch] $BootTest,

        [Parameter()]
        [switch] $KeepBootTestVm,

        [Parameter()]
        [switch] $ConnectVm,

        [Parameter()]
        [switch] $ConnectNetwork,

        [Parameter()]
        [ValidateSet('HyperV', 'VMware')]
        [string] $Hypervisor = 'HyperV',

        [Parameter()]
        [string] $DiagnosticsPath
    )

    if (-not (Test-Path -LiteralPath $IsoPath)) {
        throw "ISO not found: '$IsoPath'."
    }

    # Where to drop harvested Windows Setup logs from the boot-test VM. Default next to the ISO so
    # the caller (and CI) can find and upload them. Only used when -BootTest is set.
    if ([string]::IsNullOrWhiteSpace($DiagnosticsPath)) {
        $DiagnosticsPath = Join-Path -Path (Split-Path -Parent (Resolve-Path -LiteralPath $IsoPath).Path) -ChildPath 'boottest-diagnostics'
    }

    # Required boot files by architecture (Principle IV).
    $requiredBootFiles = if ($Architecture -eq 'amd64') {
        @('boot/etfsboot.com', 'efi/microsoft/boot/efisys.bin')
    }
    else {
        @('efi/microsoft/boot/efisys.bin')
    }

    # Inspect the ISO structure via a mockable seam (mounts the ISO on Windows).
    $structure = Get-IsoStructuralInfo -IsoPath $IsoPath

    $checks = [System.Collections.Generic.List[object]]::new()

    $addCheck = {
        param($name, $passed, $detail)
        $checks.Add([pscustomobject]@{ Name = $name; Passed = [bool]$passed; Detail = $detail })
    }

    & $addCheck 'MediaReadable' $structure.MediaReadable 'Media tree is readable.'
    & $addCheck 'HasInstallImage' $structure.HasInstallImage 'sources\install.wim|.esd is present.'
    & $addCheck 'ImageIndexIntegrity' $structure.ImageIndexValid 'DISM reports at least one valid image index.'

    $presentBootFiles = @($structure.BootFiles | ForEach-Object { $_.ToLowerInvariant().Replace('\', '/') })
    foreach ($required in $requiredBootFiles) {
        $present = $presentBootFiles -contains $required.ToLowerInvariant()
        & $addCheck "BootFile:$required" $present "Required boot file for $Architecture."
    }

    $structuralPassed = -not ($checks | Where-Object { -not $_.Passed })

    $bootResult = $null
    if ($BootTest) {
        Write-BuildLog -Level Information -Component 'Test-ImageIntegrity' -Message "Opt-in VM boot test requested (Hypervisor=$Hypervisor)."
        $bootParams = @{
            IsoPath         = $IsoPath
            Architecture    = $Architecture
            KeepBootTestVm  = $KeepBootTestVm
            ConnectVm       = $ConnectVm
            Hypervisor      = $Hypervisor
            DiagnosticsPath = $DiagnosticsPath
        }
        # Only forward ConnectNetwork when the caller set it, so each hypervisor keeps its own
        # default (Hyper-V offline, VMware NAT) unless explicitly overridden.
        if ($PSBoundParameters.ContainsKey('ConnectNetwork')) { $bootParams['ConnectNetwork'] = $ConnectNetwork }
        $bootResult = Invoke-VmBootTest @bootParams
    }

    $passed = $structuralPassed -and ($null -eq $bootResult -or $bootResult.Passed)

    # Surface where the boot-test Setup logs were harvested at the top level so it sits alongside
    # IsoPath/Architecture/Passed and is obvious in the returned object (the exact per-VM folder
    # when something was captured, otherwise the base folder we looked in, or $null if no boot test).
    $diagnosticsResultPath = $null
    if ($bootResult -and $bootResult.PSObject.Properties.Match('Diagnostics').Count -and $bootResult.Diagnostics) {
        $diagnosticsResultPath = $bootResult.Diagnostics.Path
    }
    elseif ($BootTest) {
        $diagnosticsResultPath = $DiagnosticsPath
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsIsoMaker.IntegrityResult'
        IsoPath    = (Resolve-Path -LiteralPath $IsoPath).Path
        Architecture = $Architecture
        Passed     = $passed
        DiagnosticsPath = $diagnosticsResultPath
        Structural = $checks.ToArray()
        Boot       = $bootResult
    }
}

function Get-IsoStructuralInfo {
    <#
    .SYNOPSIS
        Inspect an ISO's media structure (mockable seam).
    .DESCRIPTION
        Private helper. On Windows, mounts the ISO, checks for sources\install.wim|.esd,
        validates the DISM image index, and enumerates the present boot files, then dismounts
        the ISO. Returns a structural-info object. Mocked in the test suite.
    .PARAMETER IsoPath
        Path to the ISO.
    .OUTPUTS
        PSCustomObject with MediaReadable, HasInstallImage, ImageIndexValid, BootFiles.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string] $IsoPath)

    $diskImage = $null
    try {
        $diskImage = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
        $driveLetter = ($diskImage | Get-Volume).DriveLetter
        if (-not $driveLetter) {
            return [pscustomobject]@{ MediaReadable = $false; HasInstallImage = $false; ImageIndexValid = $false; BootFiles = @() }
        }
        $root = "$driveLetter`:\"

        $wim = Join-Path $root 'sources\install.wim'
        $esd = Join-Path $root 'sources\install.esd'
        $imageFile = if (Test-Path -LiteralPath $wim) { $wim } elseif (Test-Path -LiteralPath $esd) { $esd } else { $null }

        $indexValid = $false
        if ($imageFile) {
            $info = @(Get-BuildImageInfo -ImagePath $imageFile)
            $indexValid = $info.Count -gt 0
        }

        $bootFiles = @()
        foreach ($candidate in @('boot\etfsboot.com', 'efi\microsoft\boot\efisys.bin', 'efi\boot\bootaa64.efi', 'efi\boot\bootx64.efi')) {
            if (Test-Path -LiteralPath (Join-Path $root $candidate)) {
                $bootFiles += $candidate
            }
        }

        return [pscustomobject]@{
            MediaReadable   = $true
            HasInstallImage = [bool]$imageFile
            ImageIndexValid = $indexValid
            BootFiles       = $bootFiles
        }
    }
    finally {
        if ($diskImage) {
            Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

function Invoke-VmBootTest {
    <#
    .SYNOPSIS
        Opt-in VM boot validation (runtime-only, Windows + Hyper-V).
    .DESCRIPTION
        Private helper. Creates a throwaway Gen2 VM from the ISO and validates that it actually
        boots, rather than merely powering on. It polls on a bounded timeout and passes on the
        strongest signal it can observe:

          * Heartbeat    - the Hyper-V guest heartbeat integration service reports healthy, which
                           only happens once Windows (Setup/WinPE) has booted far enough to load
                           integration services. This is the definitive "it booted" signal.
          * StayedRunning- no heartbeat yet, but the VM remained continuously Running (never reset
                           or powered off) for at least MinRunningSeconds, proving it got past
                           firmware and the boot loader without a "no bootable device" reset.

        It fails on a boot reset (the VM leaves Running after having started, e.g. firmware could
        not boot the media) or when the timeout elapses without either pass signal. As a final
        check, a StayedRunning pass is downgraded to a failure (Method 'NoInstallProgress') when
        the harvested VHDX shows Windows Setup wrote nothing to the target disk - i.e. the VM was
        powered on but the unattended install never progressed past windowsPE (typically stuck at
        an interactive page). This is a heavy, opt-in path (FR-023) requiring Hyper-V and is
        validated on a live host only; all Hyper-V access is behind mockable seams
        (Get-HyperVReadiness / Get-VmBootStatus) and the single wait is Start-Sleep, so the polling
        logic is exercised in the unit suite.
    .PARAMETER IsoPath
        Path to the ISO.
    .PARAMETER Architecture
        Target architecture.
    .PARAMETER TimeoutSeconds
        Maximum time to wait for a pass signal before failing (default 300).
    .PARAMETER PollIntervalSeconds
        Seconds between status polls (default 10; a minimum logical step of 1s is enforced so the
        loop always makes progress toward the timeout).
    .PARAMETER MinRunningSeconds
        Continuous Running time that counts as a successful boot when no heartbeat is seen
        (default 90).
    .PARAMETER KeepBootTestVm
        When set, after a pass/fail signal is resolved the VM is left in place and the function
        blocks (via the mockable Wait-BootTestInspection seam) until the user presses Enter, so
        they can attach with vmconnect and test manually before the finally block tears it down.
    .PARAMETER ConnectVm
        When set, launches vmconnect.exe against the VM as soon as it starts (via the mockable
        Start-BootTestVmConnect seam) so the operator can watch Setup interactively.
    .PARAMETER ConnectNetwork
        When set, attaches a virtual switch (External preferred) so the boot-test VM has network.
        On Hyper-V it is off by default: the VM boots fully offline so ConX (the redesigned Setup on
        24H2+ media) takes its offline path and does not depend on a flaky WinPE-phase DNS/NAT proxy.
        On VMware the boot test is NETWORKED by default (NAT gives WinPE real DNS for ConX online
        validation); pass -ConnectNetwork:$false to force it offline there.
    .PARAMETER Hypervisor
        'HyperV' (default) or 'VMware'. Selects which provider seams create/poll/tear-down the VM.
    .PARAMETER DiagnosticsPath
        Directory to harvest Windows Setup logs into. After the VM is stopped (and before it is
        removed) the throwaway VHDX is mounted offline and any Windows Setup logs (Panther
        setupact.log / setuperr.log from \$WINDOWS.~BT\Sources\Panther and \Windows\Panther, the ConX
        \Windows\Logs\MoSetup\BlueBox.log, setupapi.dev.log, plus any pe-logs the operator copied off
        the WinPE RAM disk) are copied here so an unattended-install failure can be diagnosed - in
        CI too, where there is no interactive VM. When empty, harvesting is skipped. On VMware the
        offline disk harvest is best-effort (it needs vmware-mount, dropped from modern Workstation).
    .OUTPUTS
        PSCustomObject with Passed, Detail, Method, State, ElapsedSeconds, and (when a diagnostics
        harvest runs) InstallProgressed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string] $IsoPath,
        [Parameter(Mandatory = $true)][string] $Architecture,
        [Parameter()][int] $TimeoutSeconds = 300,
        [Parameter()][int] $PollIntervalSeconds = 10,
        [Parameter()][int] $MinRunningSeconds = 90,
        [Parameter()][switch] $KeepBootTestVm,
        [Parameter()][switch] $ConnectVm,
        [Parameter()][switch] $ConnectNetwork,
        [Parameter()][ValidateSet('HyperV', 'VMware')][string] $Hypervisor = 'HyperV',
        [Parameter()][string] $DiagnosticsPath
    )

    $isVMware = ($Hypervisor -eq 'VMware')

    # Effective network decision: Hyper-V stays offline unless -ConnectNetwork is passed; VMware is
    # NAT-connected by default (real WinPE DNS for ConX) unless the caller explicitly opts out.
    $connectNetwork = if ($isVMware) {
        if ($PSBoundParameters.ContainsKey('ConnectNetwork')) { [bool]$ConnectNetwork } else { $true }
    }
    else {
        [bool]$ConnectNetwork
    }

    # Runtime-only: probe all prerequisites up front so an environmental miss yields an actionable
    # reason (e.g. the winget install command for VMware) rather than a cryptic provisioning
    # failure. This is a 'None' (environmental) result, not a boot fail.
    $readiness = if ($isVMware) { Get-VMwareReadiness } else { Get-HyperVReadiness }
    if (-not $readiness.Ready) {
        Write-BuildLog -Level Warning -Component 'Invoke-VmBootTest' -Message $readiness.Reason
        # VMware-specific: offer the interactive winget install + manual-download guidance so the
        # user can get set up, then re-run. Non-fatal (returns a 'None' environmental result).
        if ($isVMware) { $null = Install-VMwareWorkstation }
        return [pscustomobject]@{ Passed = $false; Detail = $readiness.Reason; Method = 'None'; State = $null; ElapsedSeconds = 0 }
    }

    $vmName = "wim-boottest-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    # Hyper-V uses a bare <name>.vhdx; VMware needs a VM folder holding <name>.vmx + <name>.vmdk.
    if ($isVMware) {
        $vmDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath $vmName
        $vmxPath = Join-Path -Path $vmDir -ChildPath "$vmName.vmx"
        $vhd = Join-Path -Path $vmDir -ChildPath "$vmName.vmdk"
    }
    else {
        $vmDir = $null
        $vmxPath = $null
        $vhd = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "$vmName.vhdx"
    }
    try {
        if ($isVMware) {
            New-VMwareBootTestVm -VmName $vmName -IsoPath $IsoPath -VmxPath $vmxPath -VhdPath $vhd -ConnectNetwork:$connectNetwork
        }
        else {
            New-BootTestVm -VmName $vmName -IsoPath $IsoPath -VhdPath $vhd -ConnectNetwork:$connectNetwork
        }

        # Opt-in: open the interactive VM console so the operator can watch Setup and, on a
        # windowsPE stall, press Shift+F10 to capture logs. Behind a mockable seam so the unit
        # suite never launches a UI. Failure to launch is non-fatal (headless/CI hosts have no UI).
        if ($ConnectVm) {
            if ($isVMware) { Start-VMwareVmConnect -VmxPath $vmxPath } else { Start-BootTestVmConnect -VmName $vmName }
        }

        # Logical clock: $elapsed advances by a >=1s step each poll so the timeout is always
        # reached even if PollIntervalSeconds is 0; Start-Sleep is the only real wait (mocked
        # in tests). $runningSince tracks CONTINUOUS Running time and resets if the VM leaves it.
        $step = [math]::Max(1, $PollIntervalSeconds)
        $elapsed = 0
        $runningSince = $null
        $lastState = $null
        $result = $null
        while ($elapsed -lt $TimeoutSeconds) {
            $status = if ($isVMware) { Get-VMwareVmBootStatus -VmName $vmName -VmxPath $vmxPath } else { Get-VmBootStatus -VmName $vmName }
            $lastState = $status.State

            if ($status.State -eq 'Running') {
                if ($null -eq $runningSince) { $runningSince = $elapsed }

                if ($status.HeartbeatHealthy) {
                    $result = [pscustomobject]@{ Passed = $true; Detail = "Guest heartbeat healthy ('$($status.Heartbeat)') after ${elapsed}s; Windows booted."; Method = 'Heartbeat'; State = $status.State; ElapsedSeconds = $elapsed }
                    break
                }
                if (($elapsed - $runningSince) -ge $MinRunningSeconds) {
                    $result = [pscustomobject]@{ Passed = $true; Detail = "VM stayed Running continuously for >= ${MinRunningSeconds}s (past firmware/boot, no reset); reached ${elapsed}s."; Method = 'StayedRunning'; State = $status.State; ElapsedSeconds = $elapsed }
                    break
                }
            }
            else {
                # Left the Running state after having started => boot failed or firmware reset the
                # machine (e.g. no bootable device on the media).
                if ($null -ne $runningSince -and $status.State -in @('Off', 'CriticalPause', 'FastSavedCritical', 'SavedCritical')) {
                    $result = [pscustomobject]@{ Passed = $false; Detail = "VM left the Running state (now '$($status.State)') after ${elapsed}s; boot did not sustain."; Method = 'BootReset'; State = $status.State; ElapsedSeconds = $elapsed }
                    break
                }
                $runningSince = $null
            }

            Start-Sleep -Seconds $PollIntervalSeconds
            $elapsed += $step
        }

        if ($null -eq $result) {
            $result = [pscustomobject]@{ Passed = $false; Detail = "VM boot test timed out after ${TimeoutSeconds}s (last state '$lastState', no guest heartbeat)."; Method = 'Timeout'; State = $lastState; ElapsedSeconds = $elapsed }
        }

        # Opt-in: hold the VM so the user can connect and test interactively before the finally
        # block tears it down. Behind a mockable seam so the unit suite never blocks.
        if ($KeepBootTestVm) {
            Wait-BootTestInspection -VmName $vmName -Result $result -Hypervisor $Hypervisor -VmIdentifier $vmxPath
        }

        return $result
    }
    catch {
        return [pscustomobject]@{ Passed = $false; Detail = "VM boot test error: $($_.Exception.Message)"; Method = 'Error'; State = $null; ElapsedSeconds = 0 }
    }
    finally {
        # Harvest Windows Setup logs before teardown so an unattended-install failure can be
        # diagnosed (interactively AND in CI). The VHDX can only be mounted offline, so stop the
        # VM first, mount+copy via the Save-BootTestSetupLog seam, then remove the VM+VHDX. The
        # harvested diagnostics are attached to the (already-computed) result object by reference.
        if (-not [string]::IsNullOrWhiteSpace($DiagnosticsPath)) {
            try {
                if ($isVMware) { Stop-VMwareBootTestVm -VmxPath $vmxPath } else { Stop-BootTestVm -VmName $vmName }
                # Nest per VM so it is obvious which boot-test VM each log set came from, and so a
                # fresh run never shows a previous run's logs (each VM name is unique per build).
                $safeVmName = ($vmName -replace '[\\/:*?"<>|]', '_')
                $vmDiagnosticsPath = Join-Path -Path $DiagnosticsPath -ChildPath $safeVmName
                $diag = if ($isVMware) {
                    Save-VMwareBootTestSetupLog -VhdPath $vhd -DestinationDirectory $vmDiagnosticsPath
                }
                else {
                    Save-BootTestSetupLog -VhdPath $vhd -DestinationDirectory $vmDiagnosticsPath
                }
                $installProgressed = $false
                # Whether the disk could actually be inspected. Hyper-V always can (a $null result
                # there means "mounted, nothing written" => disk untouched). VMware may be unable to
                # mount offline (no vmware-mount); it reports Inspected=$false so we do NOT misread an
                # un-inspectable disk as "install made no progress".
                $diskInspected = $true
                if ($diag) {
                    if ($diag.PSObject.Properties.Match('Inspected').Count) { $diskInspected = [bool]$diag.Inspected }
                    $installProgressed = @($diag.Files).Count -gt 0
                    if ($null -ne $result) {
                        $result | Add-Member -NotePropertyName 'Diagnostics' -NotePropertyValue $diag -Force
                    }
                    if ($diskInspected) {
                        Write-BuildLog -Level Information -Component 'Invoke-VmBootTest' -Message "Harvested $(@($diag.Files).Count) Windows Setup log file(s) to '$($diag.Path)'."
                    }
                    if ($diag.SetupErrorTail) {
                        Write-BuildLog -Level Warning -Component 'Invoke-VmBootTest' -Message "setuperr.log tail:`n$($diag.SetupErrorTail)"
                    }
                }
                else {
                    # Nothing on the VHDX to harvest. This is the tell-tale of a windowsPE-phase
                    # failure (answer file rejected / product-key error) or a boot that never wrote
                    # to disk: Setup logs to X:\Windows\Panther on the WinPE RAM disk instead, which
                    # this offline VHDX mount cannot see. Tell the user where we looked so the empty
                    # folder is not mistaken for a missing feature.
                    if ($null -ne $result) {
                        $result | Add-Member -NotePropertyName 'Diagnostics' -NotePropertyValue ([pscustomobject]@{ Path = $vmDiagnosticsPath; Files = @(); SetupErrorTail = $null }) -Force
                    }
                    Write-BuildLog -Level Warning -Component 'Invoke-VmBootTest' -Message "No Windows Setup logs were written to the VHDX (looked in '$vmDiagnosticsPath'). This usually means Setup failed in the windowsPE phase before writing to disk (e.g. answer-file/product-key rejection); those logs live on the WinPE RAM disk (X:). To capture them: at the failing screen press Shift+F10 and, once a C: partition exists, run 'robocopy X:\Windows\Logs C:\pe-logs /E' then 'copy X:\Windows\*.log C:\pe-logs\' (include ConX's X:\Windows\Logs\MoSetup\BlueBox.log); let this teardown re-harvest and the logs will land in '$vmDiagnosticsPath'."
                }

                # Extra check: a VM can "stay running" while stuck at an interactive Setup page (e.g.
                # the product-key screen) - it is powered on but the unattended install never made
                # progress, so reporting Passed via StayedRunning is misleading. When Setup DOES get
                # past windowsPE it writes $WINDOWS.~BT\...\Panther logs to the target VHDX; a stuck
                # install writes nothing there. So if the only pass signal was StayedRunning and the
                # disk stayed untouched, downgrade to a real failure. A healthy Heartbeat pass means
                # Windows actually booted, so it is never downgraded. Only downgrade when the disk was
                # actually inspected (VMware may not be able to, and must not produce a false negative).
                if ($null -ne $result) {
                    $result | Add-Member -NotePropertyName 'InstallProgressed' -NotePropertyValue $installProgressed -Force
                    if ($diskInspected -and $result.Passed -and $result.Method -eq 'StayedRunning' -and -not $installProgressed) {
                        $result.Passed = $false
                        $result.Method = 'NoInstallProgress'
                        $result.Detail = "VM stayed Running for $($result.ElapsedSeconds)s but Windows Setup wrote nothing to the target disk - the unattended install did not progress past windowsPE (it is likely stuck at an interactive page such as the product-key screen). Inspect '$vmDiagnosticsPath'. To capture the windowsPE logs, at the stuck screen press Shift+F10 and run 'robocopy X:\Windows\Logs C:\pe-logs /E' + 'copy X:\Windows\*.log C:\pe-logs\', then press Enter here to re-harvest."
                        Write-BuildLog -Level Warning -Component 'Invoke-VmBootTest' -Message $result.Detail
                    }
                }
            }
            catch {
                Write-BuildLog -Level Warning -Component 'Invoke-VmBootTest' -Message "Could not harvest Windows Setup logs: $($_.Exception.Message)"
            }
        }
        if ($isVMware) { Remove-VMwareBootTestVm -VmxPath $vmxPath -VmDirectory $vmDir } else { Remove-BootTestVm -VmName $vmName -VhdPath $vhd }
    }
}

function Wait-BootTestInspection {
    <#
    .SYNOPSIS
        Pause after the boot test so the user can connect to the VM and test it manually.
    .DESCRIPTION
        Private, runtime-only seam invoked by Invoke-VmBootTest when -KeepBootTestVm is set. It
        leaves the throwaway boot-test VM in place and holds until EITHER the user powers the VM off
        themselves (in the hypervisor console) OR presses Enter here - so stopping the VM proceeds
        straight to log harvest + cleanup without the operator having to switch back to this
        terminal. Isolated behind one function so it can be mocked to a no-op in the unit suite
        (the interactive wait would otherwise block the tests).
    .PARAMETER VmName
        Name of the throwaway boot-test VM the user can connect to.
    .PARAMETER Result
        The resolved boot-test result object (for context in the prompt).
    .PARAMETER Hypervisor
        'HyperV' or 'VMware' - selects the connect hint shown to the user and the VM-state probe.
    .PARAMETER VmIdentifier
        Provider-specific handle (the .vmx path for VMware) used in the connect hint and state probe.
    .OUTPUTS
        None.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Interactive pause seam for the opt-in boot test; performs no state change.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive keep-alive prompt is written to the host on purpose so the operator sees it.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $VmName,
        [Parameter()][object] $Result,
        [Parameter()][ValidateSet('HyperV', 'VMware')][string] $Hypervisor = 'HyperV',
        [Parameter()][string] $VmIdentifier
    )

    $state = if ($Result) { $Result.State } else { 'unknown' }
    $connectHint = if ($Hypervisor -eq 'VMware') { "vmware -t `"$VmIdentifier`"" } else { "vmconnect localhost $VmName" }
    Write-BuildLog -Level Information -Component 'Invoke-VmBootTest' -Message "KeepBootTestVm: holding VM '$VmName' (state '$state') for manual testing. Connect with: $connectHint"
    Write-Host "Boot-test VM '$VmName' is kept for manual testing. Power it OFF in the hypervisor, or press Enter here, to harvest the Windows Setup logs and clean up..."

    $keyboardAvailable = $true
    while ($true) {
        # 1) Did the user power the VM off themselves? Then stop waiting and clean up immediately.
        $running = $true
        try {
            $status = if ($Hypervisor -eq 'VMware') {
                Get-VMwareVmBootStatus -VmName $VmName -VmxPath $VmIdentifier
            }
            else {
                Get-VmBootStatus -VmName $VmName
            }
            $running = ("$($status.State)" -eq 'Running')
        }
        catch {
            $running = $true  # transient state-probe failure: keep holding rather than tear down early
        }
        if (-not $running) {
            Write-BuildLog -Level Information -Component 'Invoke-VmBootTest' -Message "KeepBootTestVm: VM '$VmName' was powered off; harvesting the Windows Setup logs and cleaning up."
            return
        }

        # 2) Did the user press Enter here instead?
        if ($keyboardAvailable) {
            try {
                while ([System.Console]::KeyAvailable) {
                    if ([System.Console]::ReadKey($true).Key -eq [System.ConsoleKey]::Enter) { return }
                }
            }
            catch {
                # No interactive console (redirected stdin / non-console host): fall back to a single
                # blocking read so we neither busy-loop nor spin forever on the keyboard branch.
                $null = Read-Host -Prompt "Press Enter to power off VM '$VmName' and clean up"
                return
            }
        }

        Start-Sleep -Milliseconds 1000
    }
}

function Start-BootTestVmConnect {
    <#
    .SYNOPSIS
        Open the Hyper-V VM console (vmconnect) for a boot-test VM (runtime-only UI seam).
    .DESCRIPTION
        Private helper for Invoke-VmBootTest, invoked only when -ConnectVm is set. Launches
        Windows' built-in Virtual Machine Connection (vmconnect.exe) against the local host so the
        operator can watch Windows Setup and, on a windowsPE stall, press Shift+F10 to capture the
        RAM-disk logs. Non-blocking (Start-Process) and best-effort: a missing vmconnect.exe or a
        headless/CI host (no UI) is logged as a warning, never a failure. Behind this one seam so
        the unit suite can mock it and never launch a UI.
    .PARAMETER VmName
        Name of the boot-test VM to connect to on localhost.
    .OUTPUTS
        None.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Best-effort UI seam that only launches the vmconnect viewer; it changes no system or VM state.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $VmName
    )

    $vmconnect = Join-Path -Path $env:SystemRoot -ChildPath 'System32\vmconnect.exe'
    if (-not (Test-Path -LiteralPath $vmconnect)) {
        Write-BuildLog -Level Warning -Component 'Invoke-VmBootTest' -Message "ConnectVm: vmconnect.exe not found at '$vmconnect'; cannot open the VM console. Connect manually with: vmconnect localhost $VmName"
        return
    }
    try {
        Start-Process -FilePath $vmconnect -ArgumentList @('localhost', $VmName) -ErrorAction Stop | Out-Null
        Write-BuildLog -Level Information -Component 'Invoke-VmBootTest' -Message "ConnectVm: opened the VM console for '$VmName'. On a Setup stall, press Shift+F10 and run 'robocopy X:\Windows\Logs C:\pe-logs /E' + 'copy X:\Windows\*.log C:\pe-logs\' to capture the windowsPE/ConX logs (incl. MoSetup\BlueBox.log)."
    }
    catch {
        Write-BuildLog -Level Warning -Component 'Invoke-VmBootTest' -Message "ConnectVm: could not launch vmconnect for '$VmName' ($($_.Exception.Message)). Connect manually with: vmconnect localhost $VmName"
    }
}

function New-BootTestVm {
    <#
    .SYNOPSIS
        Create and start a throwaway Gen2 VM booted from an ISO (runtime-only Hyper-V seam).
    .DESCRIPTION
        Private helper for Invoke-VmBootTest. Isolates every Hyper-V provisioning cmdlet
        (New-VM/Set-VMProcessor/Set-VMMemory/Add-VMDvdDrive/Set-VMFirmware/Set-VMKeyProtector/
        Enable-VMTPM/Start-VM) behind one function so the boot-test orchestration can be
        unit-tested by mocking this seam on hosts without the Hyper-V module.

        The VM is provisioned to satisfy Windows 11 Setup's hardware checks so real Windows 11
        media proceeds past the "processor needs two or more cores / TPM 2.0 / 4 GB memory" gate:
        2 virtual processors, 4 GB startup memory, a virtual TPM 2.0 (backed by a local key
        protector), and Secure Boot enabled with the default Microsoft Windows template (official
        Windows boot media is Microsoft-signed, so it still boots). The DVD is the first boot
        device.
    .PARAMETER VmName
        Name for the throwaway VM.
    .PARAMETER IsoPath
        ISO to attach and boot from.
    .PARAMETER VhdPath
        Path for the throwaway system VHDX.
    .OUTPUTS
        None.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal runtime-only Hyper-V seam for the opt-in boot test; not a user-facing cmdlet.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $VmName,
        [Parameter(Mandatory = $true)][string] $IsoPath,
        [Parameter(Mandatory = $true)][string] $VhdPath,
        [Parameter()][switch] $ConnectNetwork
    )

    # 4 GB startup memory (Windows 11 minimum). Static memory so the guest always sees >= 4 GB.
    New-VM -Name $VmName -Generation 2 -MemoryStartupBytes 4GB -NewVHDPath $VhdPath -NewVHDSizeBytes 64GB -ErrorAction Stop | Out-Null
    # Disable automatic checkpoints. Client Hyper-V enables them by default, which snapshots the VM
    # on start into an .avhdx and leaves Hyper-V busy merging/creating it - that race made the
    # post-teardown VHDX log harvest fail (the base .vhdx was locked while the snapshot was created).
    # A throwaway boot-test VM never needs checkpoints, so turn them off up front.
    Set-VM -Name $VmName -AutomaticCheckpointsEnabled $false -CheckpointType Disabled -ErrorAction SilentlyContinue
    Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false -StartupBytes 4GB -ErrorAction Stop
    # >= 2 processors (Windows 11 minimum).
    Set-VMProcessor -VMName $VmName -Count 2 -ErrorAction Stop
    Add-VMDvdDrive -VMName $VmName -Path $IsoPath -ErrorAction Stop
    $dvd = Get-VMDvdDrive -VMName $VmName
    # Secure Boot on with the default Microsoft Windows template; boot from the DVD first.
    Set-VMFirmware -VMName $VmName -FirstBootDevice $dvd -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows' -ErrorAction Stop
    # Virtual TPM 2.0: a local key protector satisfies Enable-VMTPM without Host Guardian Service.
    Set-VMKeyProtector -VMName $VmName -NewLocalKeyProtector -ErrorAction Stop
    Enable-VMTPM -VMName $VmName -ErrorAction Stop
    # Network: keep the VM OFFLINE by default. Windows 11's redesigned "ConX" (Connected Experience)
    # Setup - used by 24H2/25H2/26H1 media (setupact.log: "Will launch ConX setup experience") - is
    # sensitive to a half-connected network: a boot-test VM on client Hyper-V's 'Default Switch' (NAT)
    # routes IP but its ICS DNS proxy is unreliable in WinPE (can ping 8.8.8.8 yet fail name
    # resolution), and that flaky state can trip an online genuine/product-key check. Leaving the NIC
    # disconnected removes that variable so a boot test only exercises the offline install path, which
    # is all it needs to verify structural bootability. NOTE: offline is NOT a cure-all - 26H1
    # business media has been observed to hard-stop at "Setup has failed to validate the product key"
    # even fully offline; that ConX-specific failure is tracked separately and is not caused by the
    # switch state here. New-VM adds a NIC but leaves it disconnected, so "offline" is just not
    # connecting it.
    #
    # -ConnectNetwork opts back in for testing ONLINE activation, but only makes sense with real DNS
    # (an External switch bridged to a physical NIC); on the Default Switch it reproduces the flaky
    # WinPE DNS.
    if ($ConnectNetwork) {
        try {
            $switch = Get-VMSwitch -ErrorAction Stop |
                Sort-Object -Property @{ Expression = { $_.SwitchType -eq 'External' }; Descending = $true },
                                      @{ Expression = { $_.Name -eq 'Default Switch' }; Descending = $true } |
                Select-Object -First 1
            if ($switch) {
                Connect-VMNetworkAdapter -VMName $VmName -SwitchName $switch.Name -ErrorAction Stop
                Write-BuildLog -Level Information -Component 'New-BootTestVm' -Message "ConnectNetwork: wired boot-test VM '$VmName' to switch '$($switch.Name)' ($($switch.SwitchType)). Online activation needs working DNS - the Default Switch's WinPE DNS is unreliable and can make ConX Setup hard-stop at 'Setup has failed to validate the product key'; use an External switch (real DNS) for online tests."
            }
            else {
                Write-BuildLog -Level Warning -Component 'New-BootTestVm' -Message "ConnectNetwork requested but no Hyper-V switch was found; boot-test VM '$VmName' will run offline."
            }
        }
        catch {
            Write-BuildLog -Level Warning -Component 'New-BootTestVm' -Message "ConnectNetwork requested but connecting boot-test VM '$VmName' to a switch failed ($($_.Exception.Message)); it will run offline."
        }
    }
    else {
        Write-BuildLog -Level Information -Component 'New-BootTestVm' -Message "Boot-test VM '$VmName' runs OFFLINE (NIC left disconnected) so Windows 11 'ConX' Setup takes the offline/legacy path and installs hands-off. Pass -ConnectNetwork (with an External switch for real DNS) only to test online activation."
    }
    Start-VM -Name $VmName -ErrorAction Stop
}

function Remove-BootTestVm {
    <#
    .SYNOPSIS
        Tear down the throwaway boot-test VM and its VHDX (runtime-only Hyper-V seam).
    .DESCRIPTION
        Private helper for Invoke-VmBootTest's finally block. Stops and removes the VM (if it
        exists) and deletes the throwaway VHDX, guaranteeing no test artifacts are left on the
        host. Isolated behind one function so cleanup is safe to invoke and mockable on hosts
        without the Hyper-V module.
    .PARAMETER VmName
        Name of the throwaway VM to remove.
    .PARAMETER VhdPath
        Path of the throwaway VHDX to delete.
    .OUTPUTS
        None.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal runtime-only Hyper-V cleanup seam for the opt-in boot test; not a user-facing cmdlet.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $VmName,
        [Parameter(Mandatory = $true)][string] $VhdPath
    )

    if (Test-HyperVAvailable) {
        $existing = Get-VM -Name $VmName -ErrorAction SilentlyContinue
        if ($existing) {
            Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
            Remove-VM -Name $VmName -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $VhdPath) { Remove-Item -LiteralPath $VhdPath -Force -ErrorAction SilentlyContinue }
}

function Stop-BootTestVm {
    <#
    .SYNOPSIS
        Stop (power off) the throwaway boot-test VM without deleting it (runtime-only Hyper-V seam).
    .DESCRIPTION
        Private helper for Invoke-VmBootTest. A running VM's VHDX cannot be mounted offline, so the
        VM must be powered off before Save-BootTestSetupLog can harvest its Windows Setup logs.
        Isolated behind one function so it is mockable on hosts without the Hyper-V module.
    .PARAMETER VmName
        Name of the throwaway VM to power off.
    .OUTPUTS
        None.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal runtime-only Hyper-V seam for the opt-in boot test; not a user-facing cmdlet.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $VmName
    )

    if (Test-HyperVAvailable) {
        $existing = Get-VM -Name $VmName -ErrorAction SilentlyContinue
        if ($existing -and "$($existing.State)" -ne 'Off') {
            Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-BootTestSetupLogRelativePath {
    <#
    .SYNOPSIS
        The Windows Setup log locations to harvest from a boot-test disk (shared, pure helper).
    .DESCRIPTION
        Returns the list of Setup/ConX/WinPE log file paths (relative to each partition root) that
        both the Hyper-V (Save-BootTestSetupLog) and VMware (Save-VMwareBootTestSetupLog) harvesters
        copy off a stopped VM's system disk. Factored out so the two providers stay in lock-step and
        the list is unit-testable directly. '$WINDOWS.~BT' is a literal folder name (single-quoted).
    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return [string[]]@(
        '$WINDOWS.~BT\Sources\Panther\setupact.log'
        '$WINDOWS.~BT\Sources\Panther\setuperr.log'
        '$WINDOWS.~BT\Sources\Panther\miglog.xml'
        '$WINDOWS.~BT\Sources\Panther\diagerr.xml'
        '$WINDOWS.~BT\Sources\Panther\diagwrn.xml'
        '$WINDOWS.~BT\Sources\Panther\UnattendGC\setupact.log'
        '$WINDOWS.~BT\Sources\Panther\setupapi.dev.log'
        '$WINDOWS.~BT\Sources\Panther\setupapi.offline.log'
        'Windows\Panther\setupact.log'
        'Windows\Panther\setuperr.log'
        'Windows\Panther\UnattendGC\setupact.log'
        'Windows\INF\setupapi.dev.log'
        # ConX (the redesigned "Connected Experience" Setup used by 24H2/25H2/26H1 media) logs to
        # MoSetup\BlueBox.log; a "Setup has failed to validate the product key" from ConX records
        # its real reason there rather than in Panther\setuperr.log.
        'Windows\Logs\MoSetup\BlueBox.log'
        'Windows\Logs\DISM\dism.log'
        'Windows\debug\NetSetup.LOG'
        # windowsPE-phase logs live on the WinPE RAM disk (X:) and never reach the target disk, so a
        # product-key/answer-file rejection writes nothing above. To capture them, Shift+F10 at the
        # failing screen and copy the WinPE logs to the target disk root (C:\) - either the individual
        # well-known names below, or (best) the whole tree via 'robocopy X:\Windows\Logs C:\pe-logs
        # /E' plus 'copy X:\Windows\*.log C:\pe-logs\', which the recursive pe-logs harvest picks up.
        'pe-setupact.log'
        'pe-setuperr.log'
        'setupact.log'
        'setuperr.log'
        'BlueBox.log'
        'pe-BlueBox.log'
        'winpeshl.log'
        'setupapi.offline.log'
        'NetSetup.LOG'
    )
}

function Save-BootTestSetupLog {
    <#
    .SYNOPSIS
        Harvest Windows Setup logs from a stopped boot-test VM's VHDX (runtime-only seam).
    .DESCRIPTION
        Private helper for Invoke-VmBootTest. Mounts the throwaway system VHDX offline (read-only)
        and copies any Windows Setup Panther logs it can find into DestinationDirectory so an
        unattended-install failure can be diagnosed - including in CI, where there is no
        interactive VM to attach to. Windows writes these during Setup:

          * \$WINDOWS.~BT\Sources\Panther\setupact.log / setuperr.log  (down-level/offline phase;
            this is where a failed install before first boot records its error)
          * \Windows\Panther\setupact.log / setuperr.log               (specialize/oobe phase)
          * \Windows\Logs\MoSetup\BlueBox.log                          (ConX "Connected Experience"
            Setup engine log on 24H2/25H2/26H1 media - where a ConX product-key rejection is recorded)
          * \Windows\INF\setupapi.dev.log                              (driver install)
          * pe-setupact.log / pe-setuperr.log / setupact.log / setuperr.log / BlueBox.log at the disk
            root, or a whole pe-logs\ tree (windowsPE-phase logs the operator copied from the WinPE
            RAM disk X: via Shift+F10, e.g. 'robocopy X:\Windows\Logs C:\pe-logs /E')
          * the matching diagerr.xml / diagwrn.xml / miglog.xml diagnostics

        Every Hyper-V/storage cmdlet (Mount-VHD/Get-Disk/Get-Partition/Get-Volume/Dismount-VHD) is
        behind this one function so the orchestration is unit-testable by mocking it. The VHDX is
        always dismounted, even on error. Returns a diagnostics object (Path, Files, and the tail
        of setuperr.log for at-a-glance visibility), or $null when nothing could be harvested.
    .PARAMETER VhdPath
        Path to the stopped VM's system VHDX to mount and read.
    .PARAMETER DestinationDirectory
        Directory to copy harvested log files into (created if missing).
    .OUTPUTS
        PSCustomObject (Path, Files, SetupErrorTail) or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string] $VhdPath,
        [Parameter(Mandatory = $true)][string] $DestinationDirectory
    )

    if (-not (Test-Path -LiteralPath $VhdPath)) { return $null }
    if (-not (Get-Command -Name 'Mount-VHD' -ErrorAction SilentlyContinue)) { return $null }

    # Clear any files harvested by a previous run first. A failure in the windowsPE phase (e.g. the
    # answer file being rejected, or a product-key validation error) happens on the WinPE RAM disk
    # and writes NOTHING to this target VHDX - so without clearing, we would resurface stale logs
    # from an earlier attempt and misdiagnose the current one. An empty folder correctly signals
    # "nothing was written to disk this run".
    if (Test-Path -LiteralPath $DestinationDirectory) {
        Get-ChildItem -LiteralPath $DestinationDirectory -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # Setup log locations, relative to each partition root (shared with the VMware harvester).
    $relativePaths = Get-BootTestSetupLogRelativePath

    $mounted = $null
    $collected = [System.Collections.Generic.List[string]]::new()
    try {
        $mounted = Mount-VHD -Path $VhdPath -ReadOnly -Passthru -ErrorAction Stop
        $driveRoots = @(
            Get-Disk -Number $mounted.DiskNumber -ErrorAction SilentlyContinue |
                Get-Partition -ErrorAction SilentlyContinue |
                Get-Volume -ErrorAction SilentlyContinue |
                Where-Object { $_.DriveLetter } |
                ForEach-Object { "$($_.DriveLetter):" }
        )

        if ($driveRoots.Count -gt 0) {
            if (-not (Test-Path -LiteralPath $DestinationDirectory)) {
                New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
            }
            foreach ($root in $driveRoots) {
                foreach ($rel in $relativePaths) {
                    $src = Join-Path -Path $root -ChildPath $rel
                    if (Test-Path -LiteralPath $src) {
                        # Flatten to a unique, filesystem-safe name: <drive>_<path with _/no $>.
                        $flat = ($rel -replace '[\\/]', '_') -replace '\$', ''
                        $dest = Join-Path -Path $DestinationDirectory -ChildPath "$($root.TrimEnd(':'))_$flat"
                        Copy-Item -LiteralPath $src -Destination $dest -Force -ErrorAction SilentlyContinue
                        if (Test-Path -LiteralPath $dest) { $collected.Add($dest) }
                    }
                }

                # Operator convenience: if the whole WinPE log tree was dropped at <root>\pe-logs
                # (e.g. 'robocopy X:\Windows\Logs C:\pe-logs /E' + 'copy X:\Windows\*.log C:\pe-logs\'
                # from Shift+F10), harvest it recursively so the ConX/MoSetup BlueBox.log and every
                # X:\Windows\*.log come across even though the RAM disk X: itself is gone by teardown.
                $peLogsDir = Join-Path -Path $root -ChildPath 'pe-logs'
                if (Test-Path -LiteralPath $peLogsDir) {
                    Get-ChildItem -LiteralPath $peLogsDir -Recurse -File -ErrorAction SilentlyContinue |
                        ForEach-Object {
                            $rel = $_.FullName.Substring($peLogsDir.Length).TrimStart('\', '/')
                            $flat = ($rel -replace '[\\/]', '_') -replace '\$', ''
                            $dest = Join-Path -Path $DestinationDirectory -ChildPath "$($root.TrimEnd(':'))_pe-logs_$flat"
                            Copy-Item -LiteralPath $_.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
                            if (Test-Path -LiteralPath $dest) { $collected.Add($dest) }
                        }
                }
            }
        }
    }
    finally {
        if ($mounted) { Dismount-VHD -Path $VhdPath -ErrorAction SilentlyContinue }
    }

    if ($collected.Count -eq 0) { return $null }

    # Surface the tail of setuperr.log (the concise "why it failed") on the result object.
    $errTail = ''
    $errFile = $collected | Where-Object { $_ -match 'setuperr' } | Select-Object -First 1
    if ($errFile) {
        $errTail = (Get-Content -LiteralPath $errFile -Tail 25 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
    }

    return [pscustomobject]@{
        Path           = (Resolve-Path -LiteralPath $DestinationDirectory).Path
        Files          = $collected.ToArray()
        SetupErrorTail = $errTail
    }
}

function Get-HyperVReadiness {
    <#
    .SYNOPSIS
        Probe whether this host can actually run the opt-in VM boot test, with an actionable reason.
    .DESCRIPTION
        Private helper for Invoke-VmBootTest. Running a boot-test VM needs three things, any of which
        can be missing even when the Hyper-V boxes look ticked in "Turn Windows features on or off":
          1. The Hyper-V PowerShell module (New-VM/Get-VM come from the
             Microsoft-Hyper-V-Management-PowerShell optional feature).
          2. The Hyper-V Virtual Machine Management service ('vmms'), installed by the Hyper-V
             platform (Microsoft-Hyper-V) — absent until servicing actually applies (a checkbox that
             is only staged/EnablePending, i.e. awaiting a reboot, does not install it yet).
          3. The caller to be elevated OR a member of the built-in "Hyper-V Administrators" group
             (SID S-1-5-32-578).
        Each signal is reported individually plus a single Ready flag and a human-readable Reason so
        the boot test can tell the user exactly what to fix instead of a bare "not available".
    .OUTPUTS
        PSCustomObject: Ready, Reason, CmdletsAvailable, ServiceInstalled, ServiceState, Elevated,
        InHyperVAdmins.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $cmdletsAvailable = [bool](Test-HyperVAvailable)

    $svc = Get-HyperVServiceInfo
    $serviceInstalled = [bool]$svc.Installed
    $serviceState = [string]$svc.State

    $priv = Test-HyperVPrivilege
    $elevated = [bool]$priv.Elevated
    $inHyperVAdmins = [bool]$priv.InHyperVAdmins

    $problems = [System.Collections.Generic.List[string]]::new()
    if (-not $cmdletsAvailable) {
        $problems.Add("the Hyper-V PowerShell module is missing (New-VM/Get-VM not found) - enable it (elevated) with 'Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All' and reboot")
    }
    if (-not $serviceInstalled) {
        if (Test-PendingReboot) {
            $problems.Add("the Hyper-V platform is staged but not active yet (the 'vmms' service is absent and a reboot is pending) - reboot to finish enabling Hyper-V, then retry")
        }
        else {
            $problems.Add("the Hyper-V platform is not active (the 'vmms' service is absent) - enable Microsoft-Hyper-V and reboot")
        }
    }
    if (-not ($elevated -or $inHyperVAdmins)) {
        $problems.Add("this session is not elevated and the user is not in the 'Hyper-V Administrators' group - run elevated, or add the user with 'Add-LocalGroupMember -Group ''Hyper-V Administrators'' -Member <user>' and sign out/in")
    }

    $ready = ($problems.Count -eq 0)
    $reason = if ($ready) {
        'Hyper-V is available for the VM boot test.'
    }
    else {
        'VM boot test cannot run because ' + ($problems -join '; ') + '.'
    }

    return [pscustomobject]@{
        Ready            = $ready
        Reason           = $reason
        CmdletsAvailable = $cmdletsAvailable
        ServiceInstalled = $serviceInstalled
        ServiceState     = $serviceState
        Elevated         = $elevated
        InHyperVAdmins   = $inHyperVAdmins
        PendingReboot    = [bool](Test-PendingReboot)
    }
}

function Test-PendingReboot {
    <#
    .SYNOPSIS
        Report whether a servicing reboot is pending (mockable seam).
    .DESCRIPTION
        Private helper for Get-HyperVReadiness. When an optional feature such as Hyper-V is enabled,
        DISM marks it 'Enabled' immediately but stages the runtime bits (the 'vmms' service, the
        Hyper-V PowerShell module) to be installed on the next boot; the Component Based Servicing
        'RebootPending' key signals that. Detecting it lets the readiness check tell the user to
        reboot rather than reporting a misleading "not installed".
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
}

function Test-HyperVAvailable {
    <#
    .SYNOPSIS
        Return whether Hyper-V VM cmdlets are available on this host (mockable seam).
    .DESCRIPTION
        Private helper. The VM boot test needs the Hyper-V PowerShell module; this isolates the
        availability probe so it can be mocked in the unit suite.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool](Get-Command -Name 'New-VM' -ErrorAction SilentlyContinue)
}

function Get-HyperVServiceInfo {
    <#
    .SYNOPSIS
        Report whether the Hyper-V Virtual Machine Management service (vmms) is installed and its
        state (mockable seam).
    .DESCRIPTION
        Private helper for Get-HyperVReadiness. The 'vmms' service is installed by the Hyper-V
        platform feature; its absence means the platform is not actually active (e.g. the feature is
        only staged awaiting a reboot). Isolated so the readiness composition is unit-testable.
    .OUTPUTS
        PSCustomObject with Installed (bool) and State (string; 'NotInstalled' when absent).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $vmms = Get-Service -Name 'vmms' -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Installed = [bool]$vmms
        State     = if ($vmms) { [string]$vmms.Status } else { 'NotInstalled' }
    }
}

function Test-HyperVPrivilege {
    <#
    .SYNOPSIS
        Report whether the caller may drive Hyper-V: elevated and/or in "Hyper-V Administrators"
        (mockable seam).
    .DESCRIPTION
        Private helper for Get-HyperVReadiness. Hyper-V cmdlets require either an elevated token or
        membership in the built-in "Hyper-V Administrators" group (SID S-1-5-32-578). Isolated so
        the readiness composition is unit-testable without depending on the runner's privileges.
    .OUTPUTS
        PSCustomObject with Elevated (bool) and InHyperVAdmins (bool).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    return [pscustomobject]@{
        Elevated       = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        InHyperVAdmins = $principal.IsInRole([System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-578'))
    }
}

function Get-VmBootStatus {
    <#
    .SYNOPSIS
        Snapshot a VM's power state and guest heartbeat health (mockable seam).
    .DESCRIPTION
        Private helper for Invoke-VmBootTest's polling loop. Reads the VM State and the Hyper-V
        'Heartbeat' integration service; the heartbeat only turns healthy once the guest has
        booted far enough to run integration services, so it is the definitive boot signal.
        Isolated behind this function so the polling logic can be unit-tested without Hyper-V.
    .PARAMETER VmName
        Name of the VM to inspect.
    .OUTPUTS
        PSCustomObject with State, Heartbeat, and HeartbeatHealthy.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string] $VmName)

    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    $state = if ($vm) { "$($vm.State)" } else { 'Unknown' }

    $heartbeat = $null
    $heartbeatHealthy = $false
    $hb = Get-VMIntegrationService -VMName $VmName -Name 'Heartbeat' -ErrorAction SilentlyContinue
    if ($hb) {
        $heartbeat = "$($hb.PrimaryStatusDescription)"
        $heartbeatHealthy = Test-HeartbeatHealthy -Status $heartbeat
    }
    return [pscustomobject]@{ State = $state; Heartbeat = $heartbeat; HeartbeatHealthy = [bool]$heartbeatHealthy }
}

function Test-HeartbeatHealthy {
    <#
    .SYNOPSIS
        Return whether a Hyper-V heartbeat status string indicates the guest has booted.
    .DESCRIPTION
        Private, pure helper (no Hyper-V dependency, unit-tested directly). Hyper-V's heartbeat
        OperationalStatus/PrimaryStatusDescription reads 'OK' (optionally with an application
        health qualifier) once the guest is up and running integration services; every other
        value (No Contact, Lost Communication, Error, Degraded, empty) means it is not yet up.
    .PARAMETER Status
        The heartbeat PrimaryStatusDescription string (may be null/empty).
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string] $Status)

    if ([string]::IsNullOrWhiteSpace($Status)) { return $false }
    return [bool]($Status -match '^\s*ok')
}
