function New-BootableIso {
    <#
    .SYNOPSIS
        Repackage serviced media into a bootable ISO using oscdimg, with arch-correct boot data.
    .DESCRIPTION
        Invokes oscdimg (Windows ADK Deployment Tools) to author a bootable ISO from the
        extracted, serviced media tree. Selects boot data by architecture (Principle IV):
        amd64 gets BIOS + UEFI boot (etfsboot.com + efisys.bin); arm64 is UEFI-only
        (efisys.bin, matching the ARM64 EFI boot layout). Fails fast with an actionable error
        if oscdimg cannot be found.
    .PARAMETER MediaRoot
        Root directory of the serviced media (contains boot\ and efi\ and sources\).
    .PARAMETER Architecture
        Target architecture: 'amd64' or 'arm64'.
    .PARAMETER OutputIsoPath
        Path to write the bootable .iso.
    .PARAMETER OscdimgPath
        Explicit path to oscdimg.exe, or empty to auto-detect from a Windows ADK install.
    .PARAMETER VolumeLabel
        Optional ISO volume label.
    .EXAMPLE
        New-BootableIso -MediaRoot C:\media -Architecture amd64 -OutputIsoPath C:\out\win11.iso
    .OUTPUTS
        System.String — the path to the built ISO.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $MediaRoot,

        [Parameter(Mandatory = $true)]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputIsoPath,

        [Parameter()]
        [string] $OscdimgPath = '',

        [Parameter()]
        [string] $VolumeLabel = 'WIN11'
    )

    if (-not $WhatIfPreference -and -not (Test-Path -LiteralPath $MediaRoot)) {
        throw "Media root not found: '$MediaRoot'."
    }

    $oscdimg = Resolve-OscdimgPath -OscdimgPath $OscdimgPath
    if (-not $oscdimg) {
        throw "oscdimg.exe was not found. Install the Windows ADK 'Deployment Tools' feature (see docs/ci.md) or pass -OscdimgPath."
    }

    # Boot files live inside the media tree, so no separate ADK boot data is required.
    $etfsboot = Join-Path -Path $MediaRoot -ChildPath 'boot\etfsboot.com'
    $efisys = Join-Path -Path $MediaRoot -ChildPath 'efi\microsoft\boot\efisys.bin'

    # Arch-specific boot data selection (Principle IV / FR-004).
    if ($Architecture -eq 'amd64') {
        if (-not $WhatIfPreference -and -not (Test-Path -LiteralPath $etfsboot)) {
            throw "amd64 build requires BIOS boot file '$etfsboot' but it is missing."
        }
        if (-not $WhatIfPreference -and -not (Test-Path -LiteralPath $efisys)) {
            throw "amd64 build requires UEFI boot file '$efisys' but it is missing."
        }
        # 2 = dual boot catalog: p0 (BIOS/El Torito) + pEF (UEFI).
        $bootData = "2#p0,e,b$etfsboot#pEF,e,b$efisys"
    }
    else {
        # arm64: UEFI-only boot (no BIOS/etfsboot on ARM media).
        if (-not $WhatIfPreference -and -not (Test-Path -LiteralPath $efisys)) {
            throw "arm64 build requires UEFI boot file '$efisys' but it is missing."
        }
        $bootData = "1#pEF,e,b$efisys"
    }

    $outputDir = Split-Path -Parent $OutputIsoPath
    if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    # oscdimg args as an ARRAY (no shell string building; Principle VII).
    #   -m         : ignore max image size
    #   -o         : optimize storage (dedupe)
    #   -u2        : produce a pure UDF file system
    #   -udfver102 : UDF revision 1.02
    #   -l<label>  : volume label
    #   -bootdata  : arch-specific boot catalog
    $oscdimgArgs = @(
        '-m',
        '-o',
        '-u2',
        '-udfver102',
        "-l$VolumeLabel",
        "-bootdata:$bootData",
        $MediaRoot,
        $OutputIsoPath
    )

    if ($PSCmdlet.ShouldProcess($OutputIsoPath, "Author bootable $Architecture ISO with oscdimg")) {
        Write-BuildLog -Level Information -Component 'New-BootableIso' -Message "Building $Architecture ISO -> '$OutputIsoPath'."
        Invoke-OscdimgTool -OscdimgPath $oscdimg -Arguments $oscdimgArgs
        if (-not (Test-Path -LiteralPath $OutputIsoPath)) {
            throw "oscdimg reported success but the ISO is missing: '$OutputIsoPath'."
        }
    }

    return $OutputIsoPath
}

function Invoke-OscdimgTool {
    <#
    .SYNOPSIS
        Invoke oscdimg.exe with validated array arguments (mockable seam).
    .DESCRIPTION
        Private helper. Runs oscdimg with the given argument array and throws on a non-zero
        exit code. Kept separate so the Pester suite can mock the actual tool invocation.
    .PARAMETER OscdimgPath
        Resolved path to oscdimg.exe.
    .PARAMETER Arguments
        The oscdimg argument array.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $OscdimgPath,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )
    $output = & $OscdimgPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "oscdimg failed with exit code $LASTEXITCODE. Output: $(($output | Out-String).Trim())"
    }
}
