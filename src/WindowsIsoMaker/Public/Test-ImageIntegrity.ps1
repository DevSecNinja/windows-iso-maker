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
    .EXAMPLE
        Test-ImageIntegrity -IsoPath C:\out\win11.iso -Architecture amd64
    .OUTPUTS
        PSCustomObject with Passed, Structural (per-check results), and optional Boot result.
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
        [switch] $BootTest
    )

    if (-not (Test-Path -LiteralPath $IsoPath)) {
        throw "ISO not found: '$IsoPath'."
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
        Write-BuildLog -Level Information -Component 'Test-ImageIntegrity' -Message 'Opt-in VM boot test requested.'
        $bootResult = Invoke-VmBootTest -IsoPath $IsoPath -Architecture $Architecture
    }

    $passed = $structuralPassed -and ($null -eq $bootResult -or $bootResult.Passed)

    return [pscustomobject]@{
        PSTypeName = 'WindowsIsoMaker.IntegrityResult'
        IsoPath    = (Resolve-Path -LiteralPath $IsoPath).Path
        Architecture = $Architecture
        Passed     = $passed
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
        not boot the media) or when the timeout elapses without either pass signal. This is a
        heavy, opt-in path (FR-023) requiring Hyper-V and is validated on a live host only; all
        Hyper-V access is behind mockable seams (Test-HyperVAvailable / Get-VmBootStatus) and the
        single wait is Start-Sleep, so the polling logic is exercised in the unit suite.
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
    .OUTPUTS
        PSCustomObject with Passed, Detail, Method, State, and ElapsedSeconds.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string] $IsoPath,
        [Parameter(Mandatory = $true)][string] $Architecture,
        [Parameter()][int] $TimeoutSeconds = 300,
        [Parameter()][int] $PollIntervalSeconds = 10,
        [Parameter()][int] $MinRunningSeconds = 90
    )

    # Runtime-only: requires Hyper-V (and an ARM64 host for arm64 media).
    if (-not (Test-HyperVAvailable)) {
        return [pscustomobject]@{ Passed = $false; Detail = 'Hyper-V (New-VM) not available; VM boot test could not run.'; Method = 'None'; State = $null; ElapsedSeconds = 0 }
    }

    $vmName = "wim-boottest-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $vhd = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "$vmName.vhdx"
    try {
        New-BootTestVm -VmName $vmName -IsoPath $IsoPath -VhdPath $vhd

        # Logical clock: $elapsed advances by a >=1s step each poll so the timeout is always
        # reached even if PollIntervalSeconds is 0; Start-Sleep is the only real wait (mocked
        # in tests). $runningSince tracks CONTINUOUS Running time and resets if the VM leaves it.
        $step = [math]::Max(1, $PollIntervalSeconds)
        $elapsed = 0
        $runningSince = $null
        $lastState = $null
        while ($elapsed -lt $TimeoutSeconds) {
            $status = Get-VmBootStatus -VmName $vmName
            $lastState = $status.State

            if ($status.State -eq 'Running') {
                if ($null -eq $runningSince) { $runningSince = $elapsed }

                if ($status.HeartbeatHealthy) {
                    return [pscustomobject]@{ Passed = $true; Detail = "Guest heartbeat healthy ('$($status.Heartbeat)') after ${elapsed}s; Windows booted."; Method = 'Heartbeat'; State = $status.State; ElapsedSeconds = $elapsed }
                }
                if (($elapsed - $runningSince) -ge $MinRunningSeconds) {
                    return [pscustomobject]@{ Passed = $true; Detail = "VM stayed Running continuously for >= ${MinRunningSeconds}s (past firmware/boot, no reset); reached ${elapsed}s."; Method = 'StayedRunning'; State = $status.State; ElapsedSeconds = $elapsed }
                }
            }
            else {
                # Left the Running state after having started => boot failed or firmware reset the
                # machine (e.g. no bootable device on the media).
                if ($null -ne $runningSince -and $status.State -in @('Off', 'CriticalPause', 'FastSavedCritical', 'SavedCritical')) {
                    return [pscustomobject]@{ Passed = $false; Detail = "VM left the Running state (now '$($status.State)') after ${elapsed}s; boot did not sustain."; Method = 'BootReset'; State = $status.State; ElapsedSeconds = $elapsed }
                }
                $runningSince = $null
            }

            Start-Sleep -Seconds $PollIntervalSeconds
            $elapsed += $step
        }

        return [pscustomobject]@{ Passed = $false; Detail = "VM boot test timed out after ${TimeoutSeconds}s (last state '$lastState', no guest heartbeat)."; Method = 'Timeout'; State = $lastState; ElapsedSeconds = $elapsed }
    }
    catch {
        return [pscustomobject]@{ Passed = $false; Detail = "VM boot test error: $($_.Exception.Message)"; Method = 'Error'; State = $null; ElapsedSeconds = 0 }
    }
    finally {
        Remove-BootTestVm -VmName $vmName -VhdPath $vhd
    }
}

function New-BootTestVm {
    <#
    .SYNOPSIS
        Create and start a throwaway Gen2 VM booted from an ISO (runtime-only Hyper-V seam).
    .DESCRIPTION
        Private helper for Invoke-VmBootTest. Isolates every Hyper-V provisioning cmdlet
        (New-VM/Add-VMDvdDrive/Set-VMFirmware/Start-VM) behind one function so the boot-test
        orchestration can be unit-tested by mocking this seam on hosts without the Hyper-V module.
        Secure Boot is disabled so unsigned/dev media boots; the DVD is the first boot device.
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
        [Parameter(Mandatory = $true)][string] $VhdPath
    )

    New-VM -Name $VmName -Generation 2 -MemoryStartupBytes 2GB -NewVHDPath $VhdPath -NewVHDSizeBytes 20GB -ErrorAction Stop | Out-Null
    Add-VMDvdDrive -VMName $VmName -Path $IsoPath -ErrorAction Stop
    $dvd = Get-VMDvdDrive -VMName $VmName
    Set-VMFirmware -VMName $VmName -FirstBootDevice $dvd -EnableSecureBoot Off -ErrorAction Stop
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
