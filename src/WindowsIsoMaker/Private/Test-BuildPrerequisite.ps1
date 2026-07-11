function Test-BuildPrerequisite {
    <#
    .SYNOPSIS
        Verify all preconditions before any destructive image-servicing work (fail fast).
    .DESCRIPTION
        Gate function (FR-019) that throws an actionable terminating error if the environment
        cannot support a build: missing administrative rights, missing servicing tooling
        (dism.exe / oscdimg.exe), or insufficient free disk space on the working volume.
        Called first by Invoke-IsoBuild so failures happen before any download/mount. In
        preview mode (-SkipHeavyBuild / -WhatIf) tooling and disk checks are relaxed.
    .PARAMETER WorkingDirectory
        The directory where the (large) intermediate media will be written; its volume's
        free space is checked.
    .PARAMETER RequiredFreeGb
        Minimum free space (in GB) required on the working volume. Default 25 GB.
    .PARAMETER OscdimgPath
        Explicit path to oscdimg.exe, or empty to auto-detect from a Windows ADK install.
    .PARAMETER RequireAdmin
        When $true (default), missing elevation is a hard failure.
    .PARAMETER PreviewOnly
        When $true, tooling/disk are checked leniently (warn, not throw) because no real
        servicing will occur (skip-heavy-build / -WhatIf path).
    .EXAMPLE
        Test-BuildPrerequisite -WorkingDirectory $cfg.WorkingDirectory -OscdimgPath $cfg.OscdimgPath
    .OUTPUTS
        PSCustomObject describing the resolved tooling paths and free space.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkingDirectory,

        [Parameter()]
        [ValidateRange(1, 1024)]
        [int] $RequiredFreeGb = 25,

        [Parameter()]
        [string] $OscdimgPath = '',

        [Parameter()]
        [bool] $RequireAdmin = $true,

        [Parameter()]
        [switch] $PreviewOnly
    )

    $problems = [System.Collections.Generic.List[string]]::new()

    # 1. Elevation (FR-019). Preview still needs admin off by design; skip when previewing.
    if ($RequireAdmin -and -not $PreviewOnly) {
        if (-not (Test-IsAdministrator)) {
            $problems.Add('Administrative privileges are required to service a Windows image. Re-run from an elevated session.')
        }
    }

    # 2. dism.exe availability.
    $dismCmd = Get-Command -Name 'dism.exe' -CommandType Application -ErrorAction SilentlyContinue
    $dismResolved = if ($dismCmd) { $dismCmd.Source } else { $null }
    if (-not $dismResolved) {
        $systemDism = Join-Path -Path ([Environment]::GetFolderPath('System')) -ChildPath 'dism.exe'
        if (Test-Path -LiteralPath $systemDism) { $dismResolved = $systemDism }
    }
    if (-not $dismResolved -and -not $PreviewOnly) {
        $problems.Add('dism.exe (Windows image-servicing tools) was not found. This build requires Windows with DISM available.')
    }

    # 3. oscdimg.exe availability (from Windows ADK Deployment Tools).
    $oscdimgResolved = Resolve-OscdimgPath -OscdimgPath $OscdimgPath
    if (-not $oscdimgResolved -and -not $PreviewOnly) {
        $problems.Add('oscdimg.exe was not found. Install the Windows ADK "Deployment Tools" feature (see docs/ci.md) or set OscdimgPath in the config.')
    }

    # 4. Free disk space on the working volume.
    $freeGb = $null
    try {
        $parent = Split-Path -Path $WorkingDirectory -Qualifier -ErrorAction SilentlyContinue
        $probeRoot = if ($parent) { "$parent\" } else { $WorkingDirectory }
        if (Test-Path -LiteralPath $probeRoot) {
            $item = Get-Item -LiteralPath $probeRoot -ErrorAction SilentlyContinue
            $driveInfo = [System.IO.DriveInfo]::new($item.FullName)
            if ($driveInfo.IsReady) {
                $freeGb = [math]::Round($driveInfo.AvailableFreeSpace / 1GB, 1)
            }
        }
    }
    catch {
        Write-BuildLog -Level Warning -Component 'Test-BuildPrerequisite' -Message "Could not determine free disk space: $($_.Exception.Message)"
    }

    if ($null -ne $freeGb -and $freeGb -lt $RequiredFreeGb -and -not $PreviewOnly) {
        $problems.Add("Insufficient free disk space on the working volume: ${freeGb} GB free, ${RequiredFreeGb} GB required.")
    }

    if ($problems.Count -gt 0) {
        throw ("Build preconditions not met:`n - " + ($problems -join "`n - "))
    }

    Write-BuildLog -Level Information -Component 'Test-BuildPrerequisite' -Message 'All build preconditions satisfied.'

    return [pscustomobject]@{
        DismPath    = $dismResolved
        OscdimgPath = $oscdimgResolved
        FreeGb      = $freeGb
        PreviewOnly = [bool]$PreviewOnly
        IsAdmin     = (Test-IsAdministrator)
    }
}

function Resolve-OscdimgPath {
    <#
    .SYNOPSIS
        Resolve the path to oscdimg.exe, auto-detecting a Windows ADK install if needed.
    .DESCRIPTION
        Private helper. Returns the explicit path if provided and valid, otherwise probes
        the standard Windows ADK Deployment Tools install locations for both amd64 and arm64
        host layouts, and finally falls back to PATH. Returns $null when not found.
    .PARAMETER OscdimgPath
        Explicit oscdimg.exe path, or empty to auto-detect.
    .OUTPUTS
        System.String or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string] $OscdimgPath = ''
    )

    if ($OscdimgPath -and (Test-Path -LiteralPath $OscdimgPath)) {
        return (Resolve-Path -LiteralPath $OscdimgPath).Path
    }

    $programFilesX86 = ${env:ProgramFiles(x86)}
    $programFiles = $env:ProgramFiles
    $candidateRoots = @()
    foreach ($root in @($programFilesX86, $programFiles)) {
        if ($root) {
            $candidateRoots += (Join-Path -Path $root -ChildPath 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools')
        }
    }

    # Host-arch sub-directories used by the ADK (amd64, arm64, x86).
    foreach ($root in $candidateRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($arch in @('amd64', 'arm64', 'x86')) {
            $candidate = Join-Path -Path $root -ChildPath "$arch\Oscdimg\oscdimg.exe"
            if (Test-Path -LiteralPath $candidate) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }

    $onPath = Get-Command -Name 'oscdimg.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($onPath) {
        return $onPath.Source
    }

    return $null
}
