#Requires -Version 5.1
<#
    VMware Workstation provider for the opt-in VM boot test.

    Mirrors the Hyper-V seams in Test-ImageIntegrity.ps1 so Invoke-VmBootTest can drive either
    hypervisor from one orchestrator. VMware Workstation has no PowerShell module or guest
    heartbeat like Hyper-V, so every external call goes through vmrun.exe / vmware-vdiskmanager.exe
    / vmware.exe behind mockable seams (Get-VMwareInstallPath / Invoke-Vmrun / Invoke-Winget /
    Read-VMwareInstallConsent) and the polling/orchestration is exercised by the unit suite the
    same way the Hyper-V path is.

    Unlike Hyper-V (which boots the test VM OFFLINE by default to dodge the flaky WinPE Default
    Switch DNS proxy), the VMware provider defaults to a NAT connection: VMware Workstation's NAT
    gives WinPE working DNS, which is exactly what a 24H2+ "ConX" Setup online product-key/edition
    validation needs (see issue #5). Pass -ConnectNetwork:$false semantics via the orchestrator to
    force it offline.
#>

# The winget package id VMware historically shipped. Broadcom has since delisted it (the installer
# now sits behind an authenticated Broadcom download), so a winget install almost always fails with
# "No package found". The install helper still SHOWS this command (as requested) but leads with the
# login-gated Broadcom portal download below, which is the only reliable way to get it today.
$script:VMwareWingetId = 'VMware.WorkstationPro'

# Free-for-personal-use VMware Workstation Pro download. Broadcom requires a (free) account login,
# so this cannot be scripted/automated - the user must sign in and download the installer manually.
$script:VMwareDownloadUrl = 'https://support.broadcom.com/group/ecx/productdownloads?subfamily=VMware%20Workstation%20Pro&freeDownloads=true'

function Get-VMwareInstallPath {
    <#
    .SYNOPSIS
        Locate the VMware Workstation executables (vmrun, vmware-vdiskmanager, vmware) - mockable seam.
    .DESCRIPTION
        Private helper for the VMware boot-test provider. Resolves the VMware Workstation install
        directory and the three tools the provider drives, probing (in order): the
        HKLM InstallPath registry value written by the installer, the standard Program Files
        locations, and finally PATH. Isolated behind one function so readiness/creation logic is
        unit-testable on hosts without VMware installed.
    .OUTPUTS
        PSCustomObject: Installed (bool), InstallDirectory, VmrunPath, VdiskManagerPath, VmwarePath.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $candidateDirs = [System.Collections.Generic.List[string]]::new()

    foreach ($regPath in @(
            'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation',
            'HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation')) {
        try {
            $item = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
            if ($item -and $item.PSObject.Properties.Match('InstallPath').Count -and $item.InstallPath) {
                $candidateDirs.Add(([string]$item.InstallPath).TrimEnd('\'))
            }
        }
        catch {
            # Registry key absent or unreadable; fall through to the well-known Program Files paths.
            Write-Verbose "VMware registry probe of '$regPath' failed: $($_.Exception.Message)"
        }
    }

    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($pf) { $candidateDirs.Add((Join-Path $pf 'VMware\VMware Workstation')) }
    }

    $vmrun = $null
    $installDir = $null
    foreach ($dir in $candidateDirs) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $candidate = Join-Path $dir 'vmrun.exe'
        if (Test-Path -LiteralPath $candidate) {
            $vmrun = $candidate
            $installDir = $dir
            break
        }
    }

    # Fall back to PATH (covers custom installs and VMware Player where vmrun is on PATH).
    if (-not $vmrun) {
        $onPath = Get-Command -Name 'vmrun.exe', 'vmrun' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($onPath) {
            $vmrun = $onPath.Source
            $installDir = Split-Path -Parent $onPath.Source
        }
    }

    $vdisk = $null
    $vmware = $null
    if ($installDir) {
        foreach ($name in @('vmware-vdiskmanager.exe')) {
            $p = Join-Path $installDir $name
            if (Test-Path -LiteralPath $p) { $vdisk = $p; break }
        }
        $vmwareExe = Join-Path $installDir 'vmware.exe'
        if (Test-Path -LiteralPath $vmwareExe) { $vmware = $vmwareExe }
    }

    return [pscustomobject]@{
        Installed        = [bool]$vmrun
        InstallDirectory = $installDir
        VmrunPath        = $vmrun
        VdiskManagerPath = $vdisk
        VmwarePath       = $vmware
    }
}

function Get-VMwareReadiness {
    <#
    .SYNOPSIS
        Probe whether this host can run the VMware boot test, with an actionable reason.
    .DESCRIPTION
        VMware counterpart of Get-HyperVReadiness. The only hard requirement is that VMware
        Workstation (specifically vmrun.exe) is installed; unlike Hyper-V the boot test does not
        need an elevated token or a special local group. When VMware is missing the reason spells
        out both the winget command (offered interactively by Install-VMwareWorkstation) and the
        manual Broadcom download fallback, because the winget package is currently delisted.
    .OUTPUTS
        PSCustomObject with the same shape as Get-HyperVReadiness (Ready, Reason, CmdletsAvailable,
        ...) so the shared orchestrator can consume either provider interchangeably.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $paths = Get-VMwareInstallPath
    $installed = [bool]$paths.Installed

    $reason = if ($installed) {
        "VMware Workstation is available for the VM boot test (vmrun: '$($paths.VmrunPath)')."
    }
    else {
        "VM boot test cannot run because VMware Workstation is not installed (vmrun.exe not found). " +
        "Download the free-for-personal-use 'VMware Workstation Pro' from the Broadcom portal (a free " +
        "login is required, so it cannot be automated): $script:VMwareDownloadUrl - install it, then re-run. " +
        "(winget's '$script:VMwareWingetId' package is delisted and will usually not find it.)"
    }

    return [pscustomobject]@{
        Ready            = $installed
        Reason           = $reason
        CmdletsAvailable = $installed
        ServiceInstalled = $installed
        ServiceState     = if ($installed) { 'Installed' } else { 'NotInstalled' }
        Elevated         = $true
        InHyperVAdmins   = $false
        PendingReboot    = $false
        InstallPaths     = $paths
    }
}

function Read-VMwareInstallConsent {
    <#
    .SYNOPSIS
        Ask the user whether to install VMware Workstation via winget (mockable Read-Host seam).
    .DESCRIPTION
        Isolated behind one function so Install-VMwareWorkstation's interactive prompt can be
        mocked to a fixed answer in the unit suite (Read-Host would otherwise block tests).
    .PARAMETER Prompt
        The yes/no question to show.
    .OUTPUTS
        System.Boolean - $true when the user answered yes.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Interactive prompt seam; performs no state change.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string] $Prompt)

    $answer = Read-Host -Prompt $Prompt
    return ([string]$answer).Trim() -match '^(y|yes)$'
}

function Invoke-Winget {
    <#
    .SYNOPSIS
        Run a winget command (mockable seam).
    .DESCRIPTION
        Isolated behind one function so Install-VMwareWorkstation can be unit-tested without
        actually invoking Windows Package Manager. Returns the exit code and captured output.
    .PARAMETER Arguments
        The winget argument array (e.g. @('install','--id','VMware.WorkstationPro','--exact')).
    .OUTPUTS
        PSCustomObject with ExitCode (int) and Output (string).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string[]] $Arguments)

    $winget = Get-Command -Name 'winget.exe', 'winget' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) {
        return [pscustomobject]@{ ExitCode = -1; Output = 'winget was not found on PATH.' }
    }
    $output = & $winget.Source @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Install-VMwareWorkstation {
    <#
    .SYNOPSIS
        Guide the user to install VMware Workstation, leading with the login-gated Broadcom download.
    .DESCRIPTION
        Interactive helper invoked when a VMware boot test is requested but VMware Workstation is
        not installed. Broadcom delisted the winget package and now puts the installer behind an
        authenticated (free-account) download that CANNOT be automated, so this helper leads with
        step-by-step manual-download guidance (the exact Broadcom portal URL, personal-use licence,
        and the Hyper-V/VMware co-existence caveat). It still SHOWS the winget command (as requested)
        and, if the user opts in, best-effort runs it in case a winget package ever returns - but a
        failure is expected and non-fatal. Returns whether VMware is installed afterwards so the
        caller can proceed or bail cleanly.
    .PARAMETER NonInteractive
        Skip the consent prompt and only print the manual guidance + winget command (used by CI /
        automated callers). No install is attempted.
    .OUTPUTS
        System.Boolean - $true when VMware Workstation is installed after this runs.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Interactive install helper; the actual state change is delegated to the mockable Invoke-Winget seam.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][switch] $NonInteractive)

    if ((Get-VMwareInstallPath).Installed) { return $true }

    $wingetArgs = @('install', '--id', $script:VMwareWingetId, '--exact', '--accept-source-agreements', '--accept-package-agreements')
    $wingetCommand = "winget $($wingetArgs -join ' ')"

    $manualGuidance = @(
        'VMware Workstation Pro must be downloaded and installed manually - Broadcom gates it behind a',
        'free account login, so it cannot be installed unattended (winget no longer carries it):',
        '  1. Open the Broadcom portal (sign in / create a free account when prompted) and download',
        '     "VMware Workstation Pro":',
        "       $script:VMwareDownloadUrl",
        '  2. Run the installer - VMware Workstation Pro is free for personal, non-commercial use.',
        '  3. First-run setup: accept the EULA, select "Use VMware Workstation Pro for Personal Use", and let it finish.',
        '  4. Co-existence note: recent VMware Workstation (17.5+) runs alongside Windows Hyper-V/WSL2; on older versions you may',
        '     need to keep Hyper-V enabled OR disabled consistently - if VMs fail to power on, that is the usual cause.',
        '  5. Re-run your build/boot test with -Hypervisor VMware once vmrun.exe exists under the VMware Workstation folder.'
    ) -join [Environment]::NewLine

    Write-BuildLog -Level Warning -Component 'Install-VMwareWorkstation' -Message "VMware Workstation is not installed. To use -Hypervisor VMware it must be installed first."
    Write-BuildLog -Level Information -Component 'Install-VMwareWorkstation' -Message $manualGuidance
    Write-BuildLog -Level Information -Component 'Install-VMwareWorkstation' -Message "(winget generally cannot fetch it, but for reference the command would be: $wingetCommand)"

    if ($NonInteractive) {
        return $false
    }

    $consent = Read-VMwareInstallConsent -Prompt "Try 'winget install' anyway? It usually fails because the package is delisted - prefer the manual download above. [$wingetCommand] (y/N)"
    if (-not $consent) {
        Write-BuildLog -Level Information -Component 'Install-VMwareWorkstation' -Message "Skipped winget; download VMware Workstation Pro from the Broadcom portal above, then re-run with -Hypervisor VMware."
        return (Get-VMwareInstallPath).Installed
    }

    Write-BuildLog -Level Information -Component 'Install-VMwareWorkstation' -Message "Running: $wingetCommand"
    $result = Invoke-Winget -Arguments $wingetArgs
    if ($result.ExitCode -eq 0 -and (Get-VMwareInstallPath).Installed) {
        Write-BuildLog -Level Information -Component 'Install-VMwareWorkstation' -Message 'VMware Workstation installed successfully via winget.'
        return $true
    }

    Write-BuildLog -Level Warning -Component 'Install-VMwareWorkstation' -Message "winget could not install VMware Workstation (exit $($result.ExitCode)). $($result.Output)`nUse the manual Broadcom download above instead:`n$manualGuidance"
    return (Get-VMwareInstallPath).Installed
}

function Invoke-Vmrun {
    <#
    .SYNOPSIS
        Run vmrun.exe with the given arguments (central mockable VMware seam).
    .DESCRIPTION
        Every VMware VM operation (start/stop/list/checkToolsState/deleteVM) goes through this one
        function so the whole provider is unit-testable by mocking it. Resolves vmrun via
        Get-VMwareInstallPath and always targets the Workstation host type (-T ws).
    .PARAMETER Arguments
        vmrun arguments AFTER the '-T ws' host-type selector (e.g. @('start', $vmx, 'nogui')).
    .OUTPUTS
        PSCustomObject with ExitCode (int) and Output (string).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string[]] $Arguments)

    $vmrun = (Get-VMwareInstallPath).VmrunPath
    if (-not $vmrun) {
        return [pscustomobject]@{ ExitCode = -1; Output = 'vmrun.exe not found (VMware Workstation is not installed).' }
    }
    $full = @('-T', 'ws') + $Arguments
    $output = & $vmrun @full 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function New-VMwareVmxConfiguration {
    <#
    .SYNOPSIS
        Build the .vmx configuration text for a throwaway Windows 11 boot-test VM (pure function).
    .DESCRIPTION
        Returns the full contents of a VMware .vmx file provisioned to boot real Windows 11 media:
        EFI firmware with Secure Boot on, 2 vCPUs, 4 GB RAM, an NVMe system disk, and a SATA CD-ROM
        holding the ISO as the first boot device. No VMware/Hyper-V calls, so it is unit-tested
        directly.

        Note: unlike the Hyper-V path (which adds a real vTPM 2.0 via a local key protector), this
        VM has NO virtual TPM. VMware Workstation cannot provision a vTPM headlessly - vmrun/vmcli
        expose no encryption or TPM command, and a vTPM requires an encrypted VM, so the only way to
        add one is interactively in the Workstation GUI. This is acceptable for the boot test: our
        generated media drives a fully scripted windowsPE ImageInstall apply, which does not invoke
        the Windows 11 hardware appraiser (the CPU/TPM/RAM "This PC can't run Windows 11" gate only
        runs in interactive Setup), so the unattended install proceeds without a TPM.
    .PARAMETER VmName
        Display name for the VM.
    .PARAMETER IsoPath
        Absolute path to the ISO to boot from.
    .PARAMETER VmdkFileName
        File name (relative to the .vmx directory) of the system disk.
    .PARAMETER ConnectNetwork
        When set, wire ethernet0 as a connected NAT adapter (WinPE gets working DNS for ConX online
        checks). Otherwise the NIC is present but left disconnected (fully offline).
    .OUTPUTS
        System.String - the .vmx file contents.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure function that only builds the .vmx text; it creates nothing and changes no system state.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string] $VmName,
        [Parameter(Mandatory = $true)][string] $IsoPath,
        [Parameter(Mandatory = $true)][string] $VmdkFileName,
        [Parameter()][switch] $ConnectNetwork
    )

    $ethConnected = if ($ConnectNetwork) { 'TRUE' } else { 'FALSE' }
    $lines = @(
        '.encoding = "windows-1252"'
        'config.version = "8"'
        'virtualHW.version = "21"'
        "displayName = `"$VmName`""
        'guestOS = "windows11-64"'
        'firmware = "efi"'
        'uefi.secureBoot.enabled = "TRUE"'
        # No virtual TPM: VMware Workstation cannot add one headlessly (vmrun/vmcli have no TPM or
        # encryption command, and a vTPM requires an encrypted VM). Our scripted windowsPE apply
        # doesn't run the Windows 11 hardware appraiser, so Setup proceeds without a TPM anyway.
        'numvcpus = "2"'
        'cpuid.coresPerSocket = "2"'
        'memsize = "4096"'
        # Standard VMware PCI bridge / PCIe root-port block. Workstation adds this to every modern
        # VM; without it there are not enough secondary PCIe slots for the NVMe + SATA + NIC devices
        # below, and device registration fails ("No PCIe slot available") - which crashes vmware-vmx
        # on power-on. pciBridge4-7 each expose 8 functions (slots) via a pcieRootPort.
        'pciBridge0.present = "TRUE"'
        'pciBridge4.present = "TRUE"'
        'pciBridge4.virtualDev = "pcieRootPort"'
        'pciBridge4.functions = "8"'
        'pciBridge5.present = "TRUE"'
        'pciBridge5.virtualDev = "pcieRootPort"'
        'pciBridge5.functions = "8"'
        'pciBridge6.present = "TRUE"'
        'pciBridge6.virtualDev = "pcieRootPort"'
        'pciBridge6.functions = "8"'
        'pciBridge7.present = "TRUE"'
        'pciBridge7.virtualDev = "pcieRootPort"'
        'pciBridge7.functions = "8"'
        # NVMe system disk (inbox Windows PE driver, no extra storage driver needed).
        'nvme0.present = "TRUE"'
        'nvme0:0.present = "TRUE"'
        "nvme0:0.fileName = `"$VmdkFileName`""
        # SATA CD-ROM holding the install ISO.
        'sata0.present = "TRUE"'
        'sata0:0.present = "TRUE"'
        'sata0:0.deviceType = "cdrom-image"'
        "sata0:0.fileName = `"$IsoPath`""
        'sata0:0.startConnected = "TRUE"'
        # Boot the CD-ROM first so Windows Setup runs, then fall through to the disk.
        'bios.bootOrder = "cdrom,hdd"'
        # NIC: NAT when networked (WinPE DNS for ConX), else present-but-disconnected (offline).
        'ethernet0.present = "TRUE"'
        'ethernet0.connectionType = "nat"'
        'ethernet0.virtualDev = "e1000e"'
        "ethernet0.startConnected = `"$ethConnected`""
        'tools.syncTime = "FALSE"'
        'mks.enable3d = "FALSE"'
    )
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function New-VMwareBootTestVm {
    <#
    .SYNOPSIS
        Create and start a throwaway VMware Workstation VM booted from an ISO (runtime-only seam).
    .DESCRIPTION
        VMware counterpart of New-BootTestVm. Writes a .vmx (New-VMwareVmxConfiguration), creates
        the system disk with vmware-vdiskmanager, and powers the VM on with vmrun. All external
        calls go through Get-VMwareInstallPath / Invoke-Vmrun so it is mockable in the unit suite.
    .PARAMETER VmName
        Name for the throwaway VM.
    .PARAMETER IsoPath
        ISO to attach and boot from.
    .PARAMETER VmxPath
        Path to write the .vmx file to (its parent directory is the VM folder).
    .PARAMETER VhdPath
        Path for the throwaway system disk (.vmdk) - kept parameter-compatible with New-BootTestVm.
    .PARAMETER ConnectNetwork
        Attach a connected NAT NIC (default of the VMware provider). Off => NIC left disconnected.
    .OUTPUTS
        None.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal runtime-only VMware seam for the opt-in boot test; not a user-facing cmdlet.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $VmName,
        [Parameter(Mandatory = $true)][string] $IsoPath,
        [Parameter(Mandatory = $true)][string] $VmxPath,
        [Parameter(Mandatory = $true)][string] $VhdPath,
        [Parameter()][switch] $ConnectNetwork
    )

    $paths = Get-VMwareInstallPath
    if (-not $paths.Installed) {
        throw "VMware Workstation is not installed (vmrun.exe not found); cannot create the boot-test VM."
    }

    $vmDir = Split-Path -Parent $VmxPath
    if (-not (Test-Path -LiteralPath $vmDir)) { New-Item -ItemType Directory -Path $vmDir -Force | Out-Null }

    $vmdkFileName = Split-Path -Leaf $VhdPath
    $vmx = New-VMwareVmxConfiguration -VmName $VmName -IsoPath $IsoPath -VmdkFileName $vmdkFileName -ConnectNetwork:$ConnectNetwork
    Set-Content -LiteralPath $VmxPath -Value $vmx -Encoding Ascii

    # Create the growable system disk. vmware-vdiskmanager's -a takes ide|buslogic|lsilogic; the
    # descriptor adapter hint is informational (the VM attaches it as NVMe via the .vmx), and -t 0
    # is a single growable file.
    if ($paths.VdiskManagerPath) {
        & $paths.VdiskManagerPath '-c' '-s' '64GB' '-a' 'lsilogic' '-t' '0' $VhdPath 2>&1 | Out-String | Write-Verbose
        if (-not (Test-Path -LiteralPath $VhdPath)) {
            throw "vmware-vdiskmanager did not create the system disk '$VhdPath'."
        }
    }
    else {
        Write-BuildLog -Level Warning -Component 'New-VMwareBootTestVm' -Message "vmware-vdiskmanager.exe not found; relying on VMware to create the disk on power-on."
    }

    if ($ConnectNetwork) {
        Write-BuildLog -Level Information -Component 'New-VMwareBootTestVm' -Message "Boot-test VM '$VmName' uses a connected NAT NIC so WinPE has working DNS for ConX online product-key/edition validation."
    }
    else {
        Write-BuildLog -Level Information -Component 'New-VMwareBootTestVm' -Message "Boot-test VM '$VmName' runs OFFLINE (NIC disconnected)."
    }

    # ALWAYS start headless. `vmrun start <vmx> gui` blocks until the Workstation UI reports the VM
    # powered on, and a first-run/modal UI dialog can stall that for many minutes - hanging the whole
    # boot test. The interactive console (when -ConnectVm is set) is opened separately and
    # non-blocking by Start-VMwareVmConnect (vmware.exe -t), which simply attaches to this already
    # running VM.
    $start = Invoke-Vmrun -Arguments @('start', $VmxPath, 'nogui')
    if ($start.ExitCode -ne 0) {
        throw "vmrun failed to start the boot-test VM '$VmName' (exit $($start.ExitCode)): $($start.Output)"
    }
}

function Get-VMwareVmBootStatus {
    <#
    .SYNOPSIS
        Snapshot a VMware VM's power state and VMware Tools health (mockable seam).
    .DESCRIPTION
        VMware counterpart of Get-VmBootStatus. Reports State ('Running' when vmrun list shows the
        VM, else 'Off') and a HeartbeatHealthy flag from vmrun checkToolsState. VMware Tools are not
        present during WinPE/Setup, so HeartbeatHealthy is usually $false and the boot test relies on
        the shared StayedRunning signal (plus the install-progress disk check) - which is why the
        VMware path defaults to a NAT connection so Setup can actually progress.
    .PARAMETER VmName
        Name of the VM (for logging/parity with the Hyper-V seam).
    .PARAMETER VmxPath
        Path to the VM's .vmx file (what vmrun keys on).
    .OUTPUTS
        PSCustomObject with State, Heartbeat, and HeartbeatHealthy.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string] $VmName,
        [Parameter(Mandatory = $true)][string] $VmxPath
    )

    $list = Invoke-Vmrun -Arguments @('list')
    $normalizedVmx = try { [System.IO.Path]::GetFullPath($VmxPath) } catch { $VmxPath }
    $running = $false
    if ($list.ExitCode -eq 0 -and $list.Output) {
        foreach ($line in ($list.Output -split "`r?`n")) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
            if ($trimmed -like 'Total running VMs:*') { continue }
            $candidate = try { [System.IO.Path]::GetFullPath($trimmed) } catch { $trimmed }
            if ($candidate -eq $normalizedVmx) { $running = $true; break }
        }
    }

    $heartbeat = $null
    $heartbeatHealthy = $false
    if ($running) {
        $tools = Invoke-Vmrun -Arguments @('checkToolsState', $VmxPath)
        if ($tools.ExitCode -eq 0 -and $tools.Output) {
            $heartbeat = ($tools.Output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
            if ($heartbeat) { $heartbeat = $heartbeat.Trim() }
            # 'running' means VMware Tools are up => the guest booted into an OS running tools.
            $heartbeatHealthy = [bool]($heartbeat -match '^\s*running\s*$')
        }
    }

    $state = if ($running) { 'Running' } else { 'Off' }
    return [pscustomobject]@{ State = $state; Heartbeat = $heartbeat; HeartbeatHealthy = [bool]$heartbeatHealthy }
}

function Stop-VMwareBootTestVm {
    <#
    .SYNOPSIS
        Power off a VMware boot-test VM without deleting it (runtime-only seam).
    .DESCRIPTION
        VMware counterpart of Stop-BootTestVm. A running VM's disk cannot be inspected offline, so
        the VM is hard-stopped before Save-VMwareBootTestSetupLog attempts a best-effort harvest.
    .PARAMETER VmxPath
        Path to the VM's .vmx file.
    .OUTPUTS
        None.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal runtime-only VMware seam for the opt-in boot test; not a user-facing cmdlet.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory = $true)][string] $VmxPath)

    if (-not (Get-VMwareInstallPath).Installed) { return }
    $null = Invoke-Vmrun -Arguments @('stop', $VmxPath, 'hard')
}

function Remove-VMwareBootTestVm {
    <#
    .SYNOPSIS
        Tear down a VMware boot-test VM and its folder (runtime-only seam).
    .DESCRIPTION
        VMware counterpart of Remove-BootTestVm. Hard-stops then deletes the VM via vmrun and
        removes the VM folder so no artifacts are left on the host.
    .PARAMETER VmxPath
        Path to the VM's .vmx file.
    .PARAMETER VmDirectory
        The VM folder to delete after the VM is removed.
    .OUTPUTS
        None.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal runtime-only VMware cleanup seam for the opt-in boot test; not a user-facing cmdlet.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $VmxPath,
        [Parameter(Mandatory = $true)][string] $VmDirectory
    )

    if ((Get-VMwareInstallPath).Installed -and (Test-Path -LiteralPath $VmxPath)) {
        $null = Invoke-Vmrun -Arguments @('stop', $VmxPath, 'hard')
        $null = Invoke-Vmrun -Arguments @('deleteVM', $VmxPath)
    }
    if (Test-Path -LiteralPath $VmDirectory) {
        Remove-Item -LiteralPath $VmDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Start-VMwareVmConnect {
    <#
    .SYNOPSIS
        Open the VMware Workstation GUI for a boot-test VM (runtime-only UI seam).
    .DESCRIPTION
        VMware counterpart of Start-BootTestVmConnect. Launches vmware.exe against the VM so the
        operator can watch Windows Setup and, on a stall, press Shift+F10 to capture logs. Best-
        effort: a missing vmware.exe or a headless host is logged as a warning, never a failure.
    .PARAMETER VmxPath
        Path to the VM's .vmx file to open.
    .OUTPUTS
        None.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Best-effort UI seam that only launches the VMware viewer; it changes no system or VM state.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory = $true)][string] $VmxPath)

    $vmware = (Get-VMwareInstallPath).VmwarePath
    if (-not $vmware) {
        Write-BuildLog -Level Warning -Component 'Invoke-VmBootTest' -Message "ConnectVm: vmware.exe not found; cannot open the VMware console. Open the VM manually: '$VmxPath'."
        return
    }
    try {
        Start-Process -FilePath $vmware -ArgumentList @('-t', $VmxPath) -ErrorAction Stop | Out-Null
        Write-BuildLog -Level Information -Component 'Invoke-VmBootTest' -Message "ConnectVm: opened the VMware console for '$VmxPath'. On a Setup stall, press Shift+F10 and copy the WinPE logs (e.g. 'robocopy X:\Windows\Logs C:\pe-logs /E')."
    }
    catch {
        Write-BuildLog -Level Warning -Component 'Invoke-VmBootTest' -Message "ConnectVm: could not launch the VMware console for '$VmxPath' ($($_.Exception.Message))."
    }
}

function Save-VMwareBootTestSetupLog {
    <#
    .SYNOPSIS
        Best-effort harvest of Windows Setup logs from a stopped VMware VM's disk (runtime-only seam).
    .DESCRIPTION
        VMware counterpart of Save-BootTestSetupLog. Recent VMware Workstation dropped the
        vmware-mount tool, so an offline VMDK mount is not always possible; this seam tries it when
        vmware-mount.exe exists and otherwise reports that the disk could not be inspected (so the
        orchestrator does NOT misread an un-inspectable disk as "install made no progress"). When it
        can mount, it copies the same Setup log set the Hyper-V harvester collects.
    .PARAMETER VhdPath
        Path to the stopped VM's .vmdk.
    .PARAMETER DestinationDirectory
        Directory to copy harvested log files into (created if missing).
    .OUTPUTS
        PSCustomObject (Path, Files, SetupErrorTail, Inspected) or $null when the disk is missing.
        Inspected=$false means the harvest could not read the disk (best-effort limitation), which
        the caller uses to avoid a false "no install progress" downgrade.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string] $VhdPath,
        [Parameter(Mandatory = $true)][string] $DestinationDirectory
    )

    if (-not (Test-Path -LiteralPath $VhdPath)) { return $null }

    if (Test-Path -LiteralPath $DestinationDirectory) {
        Get-ChildItem -LiteralPath $DestinationDirectory -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # vmware-mount was removed from modern Workstation; when absent we cannot inspect the VMDK
    # offline. Report Inspected=$false so the orchestrator does not downgrade a StayedRunning pass.
    $installDir = (Get-VMwareInstallPath).InstallDirectory
    $vmwareMount = if ($installDir) { Join-Path $installDir 'vmware-mount.exe' } else { $null }
    if (-not ($vmwareMount -and (Test-Path -LiteralPath $vmwareMount))) {
        if (-not (Test-Path -LiteralPath $DestinationDirectory)) {
            New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
        }
        Write-BuildLog -Level Warning -Component 'Invoke-VmBootTest' -Message "VMware: cannot harvest Setup logs offline (vmware-mount.exe is not available in this VMware Workstation version). To capture logs, open the VM (vmware.exe -t '$VhdPath') and, at the Setup screen, press Shift+F10 then copy the WinPE logs."
        return [pscustomobject]@{
            Path           = (Resolve-Path -LiteralPath $DestinationDirectory).Path
            Files          = @()
            SetupErrorTail = $null
            Inspected      = $false
        }
    }

    $relativePaths = Get-BootTestSetupLogRelativePath
    $mountPoint = Join-Path ([System.IO.Path]::GetTempPath()) ("vmw-mnt-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $collected = [System.Collections.Generic.List[string]]::new()
    $mounted = $false
    try {
        New-Item -ItemType Directory -Path $mountPoint -Force | Out-Null
        & $vmwareMount $VhdPath '1' $mountPoint 2>&1 | Out-String | Write-Verbose
        $mounted = Test-Path -LiteralPath $mountPoint
        if (-not (Test-Path -LiteralPath $DestinationDirectory)) {
            New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
        }
        foreach ($rel in $relativePaths) {
            $src = Join-Path -Path $mountPoint -ChildPath $rel
            if (Test-Path -LiteralPath $src) {
                $flat = ($rel -replace '[\\/]', '_') -replace '\$', ''
                $dest = Join-Path -Path $DestinationDirectory -ChildPath "vmdk_$flat"
                Copy-Item -LiteralPath $src -Destination $dest -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $dest) { $collected.Add($dest) }
            }
        }
    }
    catch {
        Write-BuildLog -Level Warning -Component 'Invoke-VmBootTest' -Message "VMware: offline VMDK harvest failed ($($_.Exception.Message))."
        return [pscustomobject]@{
            Path           = (Resolve-Path -LiteralPath $DestinationDirectory).Path
            Files          = @()
            SetupErrorTail = $null
            Inspected      = $false
        }
    }
    finally {
        if ($mounted) { & $vmwareMount '/d' $mountPoint 2>&1 | Out-String | Write-Verbose }
        if (Test-Path -LiteralPath $mountPoint) { Remove-Item -LiteralPath $mountPoint -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $errTail = ''
    $errFile = $collected | Where-Object { $_ -match 'setuperr' } | Select-Object -First 1
    if ($errFile) {
        $errTail = (Get-Content -LiteralPath $errFile -Tail 25 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
    }

    return [pscustomobject]@{
        Path           = (Resolve-Path -LiteralPath $DestinationDirectory).Path
        Files          = $collected.ToArray()
        SetupErrorTail = $errTail
        Inspected      = $true
    }
}
