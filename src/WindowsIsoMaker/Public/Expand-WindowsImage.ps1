function Expand-WindowsImage {
    <#
    .SYNOPSIS
        Extract the contents of a Windows 11 ISO to a working directory for servicing.
    .DESCRIPTION
        Mounts the ISO (or otherwise copies its contents) into a scoped working directory
        (Principle VI) and locates the Windows image file (sources\install.wim or
        sources\install.esd) used for offline servicing. Returns the media root and the
        located image path. Fails if the media does not contain a sources\install.* image.
    .PARAMETER IsoPath
        Path to the .iso file.
    .PARAMETER Destination
        Writable directory to extract the media tree into.
    .EXAMPLE
        Expand-WindowsImage -IsoPath C:\work\win11.iso -Destination C:\work\media
    .OUTPUTS
        PSCustomObject with MediaRoot and ImagePath.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $IsoPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Destination
    )

    if (-not (Test-Path -LiteralPath $IsoPath)) {
        throw "ISO not found: '$IsoPath'."
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    if ($PSCmdlet.ShouldProcess($Destination, "Extract ISO media from '$IsoPath'")) {
        Copy-IsoContent -IsoPath $IsoPath -Destination $Destination
    }

    # Locate the Windows image file. .wim is preferred (servicing-friendly); .esd is accepted.
    $sourcesDir = Join-Path -Path $Destination -ChildPath 'sources'
    $wim = Join-Path -Path $sourcesDir -ChildPath 'install.wim'
    $esd = Join-Path -Path $sourcesDir -ChildPath 'install.esd'

    $imagePath = $null
    if (Test-Path -LiteralPath $wim) { $imagePath = $wim }
    elseif (Test-Path -LiteralPath $esd) { $imagePath = $esd }

    if (-not $imagePath -and -not $WhatIfPreference) {
        throw "Could not locate sources\install.wim or sources\install.esd under '$Destination'. The media may be invalid."
    }

    Write-BuildLog -Level Information -Component 'Expand-WindowsImage' -Message "Media extracted to '$Destination'; image = '$imagePath'."

    return [pscustomobject]@{
        PSTypeName = 'WindowsIsoMaker.ExpandedMedia'
        MediaRoot  = (Resolve-Path -LiteralPath $Destination).Path
        ImagePath  = $imagePath
    }
}

function Copy-IsoContent {
    <#
    .SYNOPSIS
        Mount an ISO and copy its full contents to a destination directory.
    .DESCRIPTION
        Private helper (mockable seam). On Windows, mounts the ISO with Mount-DiskImage,
        copies every file/folder to the destination, then dismounts the ISO in a finally
        block so it is never left mounted. This is the Windows-runtime path.
    .PARAMETER IsoPath
        Path to the .iso file.
    .PARAMETER Destination
        Directory to copy the media into.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $IsoPath,
        [Parameter(Mandatory = $true)][string] $Destination
    )

    $diskImage = $null
    try {
        $diskImage = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
        $volume = $diskImage | Get-Volume
        $driveLetter = $volume.DriveLetter
        if (-not $driveLetter) {
            throw "Mounted ISO '$IsoPath' did not expose a drive letter."
        }
        $sourceRoot = "$driveLetter`:\"
        Write-BuildLog -Level Verbose -Component 'Expand-WindowsImage' -Message "Copying media from '$sourceRoot' to '$Destination'."
        Copy-Item -Path (Join-Path -Path $sourceRoot -ChildPath '*') -Destination $Destination -Recurse -Force -ErrorAction Stop

        # Files copied off a read-only ISO volume inherit the ReadOnly attribute. DISM then
        # refuses to mount install.wim for modification ("You do not have permissions to mount
        # and modify this image"), and re-packaging cannot rewrite boot.wim. Clear it across the
        # extracted media so servicing and repackaging can write.
        Get-ChildItem -LiteralPath $Destination -Recurse -File -Force |
            Where-Object { $_.IsReadOnly } |
            ForEach-Object { $_.IsReadOnly = $false }
    }
    finally {
        if ($diskImage) {
            Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
        }
    }
}
