function Compress-BuildArtifact {
    <#
    .SYNOPSIS
        Compress the final bootable ISO into a named archive artifact with a checksum.
    .DESCRIPTION
        Compresses the built ISO into a zip (built-in) or 7z (requires 7z on PATH) archive,
        names it Windows11-<edition>-<arch>-<release>.<ext>, computes a SHA-256 hash of the
        archive, and returns an OutputImageArtifact object for the RunReport (FR-015, FR-022).
    .PARAMETER IsoPath
        Path to the built .iso file.
    .PARAMETER OutputDirectory
        Directory to write the archive into.
    .PARAMETER Format
        Archive format: 'zip' (default) or '7z'.
    .PARAMETER Edition
        Edition, used in the artifact name.
    .PARAMETER Architecture
        Architecture, used in the artifact name.
    .PARAMETER Release
        Release, used in the artifact name.
    .EXAMPLE
        Compress-BuildArtifact -IsoPath C:\out\win11.iso -OutputDirectory C:\out -Format zip -Edition Pro -Architecture amd64 -Release 23H2
    .OUTPUTS
        PSCustomObject (OutputImageArtifact).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $IsoPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputDirectory,

        [Parameter()]
        [ValidateSet('zip', '7z')]
        [string] $Format = 'zip',

        [Parameter()]
        [string] $Edition = 'Pro',

        [Parameter(Mandatory = $true)]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter()]
        [string] $Release = 'latest'
    )

    if (-not (Test-Path -LiteralPath $IsoPath)) {
        throw "ISO not found: '$IsoPath'."
    }
    # New-Item -Force returns the DirectoryInfo for a newly created OR pre-existing directory; its
    # .FullName is the absolute path the cmdlet actually resolved. Anchor the archive to that path
    # so the .NET ZipFile API (which resolves relative paths against the module's session-state
    # location / process start directory, not $PWD) always writes next to where the build ran
    # instead of the home directory. See New-ZipArchiveFromFile for the underlying gotcha.
    $outputDirInfo = New-Item -ItemType Directory -Path $OutputDirectory -Force

    $baseName = ("Windows11-$Edition-$Architecture-$Release" -replace '\s', '')
    $archivePath = Join-Path -Path $outputDirInfo.FullName -ChildPath "$baseName.$Format"

    if ($PSCmdlet.ShouldProcess($archivePath, "Compress ISO ($Format)")) {
        if (Test-Path -LiteralPath $archivePath) {
            Remove-Item -LiteralPath $archivePath -Force
        }

        if ($Format -eq 'zip') {
            # Streaming ZipFile API — Compress-Archive throws "Stream was too long." on ISOs > ~2 GB.
            # Fastest: a Windows ISO's install.wim is already compressed, so Optimal costs minutes for ~no gain.
            New-ZipArchiveFromFile -SourceFile $IsoPath -DestinationArchive $archivePath -EntryName ([System.IO.Path]::GetFileName($IsoPath)) -CompressionLevel Fastest
        }
        else {
            $sevenZip = Get-Command -Name '7z', '7z.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $sevenZip) {
                throw "7z format requested but the 7z executable was not found on PATH. Install 7-Zip or use -Format zip."
            }
            $args7z = @('a', '-t7z', $archivePath, $IsoPath)
            $output = & $sevenZip.Source @args7z 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "7z compression failed (exit $LASTEXITCODE): $(($output | Out-String).Trim())"
            }
        }

        if (-not (Test-Path -LiteralPath $archivePath)) {
            throw "Compression completed but the archive is missing: '$archivePath'."
        }
    }

    $sha256 = if (Test-Path -LiteralPath $archivePath) { (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash } else { $null }
    $sizeBytes = if (Test-Path -LiteralPath $archivePath) { (Get-Item -LiteralPath $archivePath).Length } else { 0 }

    Write-BuildLog -Level Information -Component 'Compress-BuildArtifact' -Message "Artifact '$archivePath' (SHA256=$sha256, $sizeBytes bytes)."

    return [pscustomobject]@{
        PSTypeName    = 'WindowsIsoMaker.OutputImageArtifact'
        IsoPath       = (Resolve-Path -LiteralPath $IsoPath).Path
        ArchivePath   = $archivePath
        Architecture  = $Architecture
        Sha256        = $sha256
        SizeBytes     = $sizeBytes
    }
}
