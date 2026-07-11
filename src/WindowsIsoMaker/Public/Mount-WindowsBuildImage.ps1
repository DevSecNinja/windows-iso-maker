function Mount-WindowsBuildImage {
    <#
    .SYNOPSIS
        Mount a specific edition/index of a Windows image for offline servicing.
    .DESCRIPTION
        Resolves the correct image index for the requested edition (unless an explicit Index
        is given), mounts the .wim/.esd at a scoped mount directory via DISM, and returns a
        MountedImage object used to guard cleanup (Principle VI). The caller MUST dismount in
        a finally block so the image is never left mounted on failure (FR-005).
    .PARAMETER ImagePath
        Path to sources\install.wim or install.esd.
    .PARAMETER MountPath
        Empty, writable directory to mount the image at.
    .PARAMETER Edition
        Windows edition whose index should be resolved (e.g. 'Pro'). Ignored when Index is set.
    .PARAMETER Index
        Explicit image index to mount (> 0). Takes precedence over Edition.
    .EXAMPLE
        Mount-WindowsBuildImage -ImagePath C:\media\sources\install.wim -MountPath C:\mount -Edition Pro
    .OUTPUTS
        PSCustomObject (MountedImage).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $ImagePath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $MountPath,

        [Parameter()]
        [string] $Edition = 'Pro',

        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $Index
    )

    if (-not (Test-Path -LiteralPath $ImagePath)) {
        throw "Windows image not found: '$ImagePath'."
    }
    if (-not (Test-Path -LiteralPath $MountPath)) {
        New-Item -ItemType Directory -Path $MountPath -Force | Out-Null
    }

    # Resolve the index from the edition when not explicitly provided.
    $resolvedIndex = $Index
    if (-not $PSBoundParameters.ContainsKey('Index') -or $Index -le 0) {
        $images = Get-BuildImageInfo -ImagePath $ImagePath
        if (-not $images) {
            throw "No images found in '$ImagePath'."
        }
        $match = $images | Where-Object {
            $name = if ($_.PSObject.Properties['ImageName']) { $_.ImageName } else { $null }
            $name -and ($name -like "*$Edition*")
        } | Select-Object -First 1

        if (-not $match) {
            $available = ($images | ForEach-Object { $_.ImageName }) -join ', '
            throw "Edition '$Edition' not found in image. Available: $available."
        }
        $resolvedIndex = [int]$match.ImageIndex
        Write-BuildLog -Level Information -Component 'Mount-WindowsBuildImage' -Message "Resolved edition '$Edition' to index $resolvedIndex."
    }

    if ($PSCmdlet.ShouldProcess($MountPath, "Mount image index $resolvedIndex from '$ImagePath'")) {
        try {
            Mount-BuildImage -ImagePath $ImagePath -Index $resolvedIndex -Path $MountPath
        }
        catch {
            throw "Failed to mount image index $resolvedIndex from '$ImagePath' at '$MountPath': $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        PSTypeName  = 'WindowsIsoMaker.MountedImage'
        ImagePath   = (Resolve-Path -LiteralPath $ImagePath).Path
        Index       = $resolvedIndex
        MountPath   = (Resolve-Path -LiteralPath $MountPath).Path
        LoadedHives = @{}
        IsMounted   = -not $WhatIfPreference
    }
}
