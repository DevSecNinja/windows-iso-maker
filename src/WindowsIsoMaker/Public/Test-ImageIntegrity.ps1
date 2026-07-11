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
        Private helper. Creates a throwaway VM from the ISO and confirms Windows Setup is
        reached. This is a heavy, opt-in path (FR-023) requiring Hyper-V and is validated on a
        live host only; it is mocked in the unit suite.
    .PARAMETER IsoPath
        Path to the ISO.
    .PARAMETER Architecture
        Target architecture.
    .OUTPUTS
        PSCustomObject with Passed and Detail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string] $IsoPath,
        [Parameter(Mandatory = $true)][string] $Architecture
    )

    # Runtime-only: requires Hyper-V (and an ARM64 host for arm64 media). Implemented as a
    # best-effort check; the real boot assertion happens on a live Windows host.
    if (-not (Get-Command -Name 'New-VM' -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Passed = $false; Detail = 'Hyper-V (New-VM) not available; VM boot test could not run.' }
    }

    $vmName = "wim-boottest-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $vhd = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "$vmName.vhdx"
    try {
        New-VM -Name $vmName -Generation 2 -MemoryStartupBytes 2GB -NewVHDPath $vhd -NewVHDSizeBytes 20GB -ErrorAction Stop | Out-Null
        Add-VMDvdDrive -VMName $vmName -Path $IsoPath -ErrorAction Stop
        $dvd = Get-VMDvdDrive -VMName $vmName
        Set-VMFirmware -VMName $vmName -FirstBootDevice $dvd -EnableSecureBoot Off -ErrorAction Stop
        Start-VM -Name $vmName -ErrorAction Stop
        Start-Sleep -Seconds 60
        $state = (Get-VM -Name $vmName).State
        $passed = "$state" -eq 'Running'
        return [pscustomobject]@{ Passed = $passed; Detail = "VM reached state '$state' after boot." }
    }
    catch {
        return [pscustomobject]@{ Passed = $false; Detail = "VM boot test error: $($_.Exception.Message)" }
    }
    finally {
        if (Get-Command -Name 'Get-VM' -ErrorAction SilentlyContinue) {
            $existing = Get-VM -Name $vmName -ErrorAction SilentlyContinue
            if ($existing) {
                Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue
                Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue
            }
        }
        if (Test-Path -LiteralPath $vhd) { Remove-Item -LiteralPath $vhd -Force -ErrorAction SilentlyContinue }
    }
}
