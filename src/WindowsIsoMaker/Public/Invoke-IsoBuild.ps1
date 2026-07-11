function Invoke-IsoBuild {
    <#
    .SYNOPSIS
        Orchestrate the full Windows 11 debloat/build pipeline — the single shared entry for
        local and CI runs (Principle V, FR-010).
    .DESCRIPTION
        Resolves configuration (the config file is the primary interface), verifies
        preconditions (fail fast — FR-019), then runs the pipeline: download the base ISO ->
        verify integrity (FR-020) -> extract media -> mount the image -> remove bloatware ->
        apply registry tweaks -> commit (dismount -Save) -> author a bootable ISO ->
        compress the artifact -> validate integrity -> emit an auditable RunReport (FR-022).

        Safety (Principle VI): every mutating step supports -WhatIf and is idempotent
        (FR-016/FR-017). -WhatIf or -SkipHeavyBuild produces a preview RunReport
        (Outcome=Preview) with NO media changes (FR-014/FR-016). On any failure the image is
        dismounted with -Discard and hives are unloaded, and a terminating error is raised so
        corrupt output is never presented as success (FR-005).
    .PARAMETER Config
        A pre-resolved BuildConfiguration. If omitted, one is built from -ConfigPath + overrides.
    .PARAMETER ConfigPath
        Path to a build config file (primary interface). Alias: -Path.
    .PARAMETER Architecture
        Optional override: 'amd64' | 'arm64'.
    .PARAMETER Edition
        Optional edition override.
    .PARAMETER Language
        Optional language override.
    .PARAMETER Release
        Optional release override.
    .PARAMETER RemoveEdge
        Opt-in: enable the Edge removal catalog entry.
    .PARAMETER RemoveOneDrive
        Opt-in: enable the OneDrive removal catalog entry.
    .PARAMETER SkipHeavyBuild
        Preview/light path: no download/mount/build; still emits a RunReport (FR-014).
    .PARAMETER BootTest
        Opt-in VM boot validation in addition to structural checks (FR-023).
    .EXAMPLE
        Invoke-IsoBuild -ConfigPath config/build.config.psd1 -Architecture amd64
    .EXAMPLE
        Invoke-IsoBuild -WhatIf
        Previews all intended changes without touching any media.
    .OUTPUTS
        PSCustomObject (RunReport).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [object] $Config,

        [Parameter()]
        [Alias('Path')]
        [string] $ConfigPath,

        [Parameter()]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter()]
        [string] $Edition,

        [Parameter()]
        [string] $Language,

        [Parameter()]
        [string] $Release,

        [Parameter()]
        [switch] $RemoveEdge,

        [Parameter()]
        [switch] $RemoveOneDrive,

        [Parameter()]
        [switch] $SkipHeavyBuild,

        [Parameter()]
        [switch] $BootTest
    )

    # --- 1. Resolve configuration (config file is primary; params are last-mile overrides). ---
    if (-not $Config) {
        $cfgParams = @{}
        if ($PSBoundParameters.ContainsKey('ConfigPath')) { $cfgParams['Path'] = $ConfigPath }
        foreach ($n in 'Architecture', 'Edition', 'Language', 'Release') {
            if ($PSBoundParameters.ContainsKey($n)) { $cfgParams[$n] = $PSBoundParameters[$n] }
        }
        if ($PSBoundParameters.ContainsKey('RemoveEdge')) { $cfgParams['RemoveEdge'] = $RemoveEdge }
        if ($PSBoundParameters.ContainsKey('RemoveOneDrive')) { $cfgParams['RemoveOneDrive'] = $RemoveOneDrive }
        $Config = Get-BuildConfiguration @cfgParams
    }

    $isPreview = $WhatIfPreference -or $SkipHeavyBuild.IsPresent
    $wantBootTest = $BootTest.IsPresent -or [bool]$Config.BootTest
    $toolVersions = Get-BuildToolVersion -Config $Config

    Write-BuildLog -Level Information -Component 'Invoke-IsoBuild' -Message "Starting build (Arch=$($Config.Architecture), Edition=$($Config.Edition), Preview=$isPreview)."

    # --- 2. Preconditions gate (fail fast; relaxed in preview). ---
    $prereq = Test-BuildPrerequisite -WorkingDirectory $Config.WorkingDirectory `
        -OscdimgPath $Config.OscdimgPath -PreviewOnly:$isPreview

    # --- 3. Preview path: report intended changes, touch no media (FR-014/FR-016). ---
    if ($isPreview) {
        $previewResults = foreach ($entry in $Config.SelectedCatalog) {
            [pscustomobject]@{
                PSTypeName = 'WindowsIsoMaker.ChangeResult'
                Id         = $entry.Id
                Type       = $entry.Type
                Status     = 'Skipped'
                Reason     = 'Preview: would be applied in a real build.'
                Citation   = $entry.Citation
            }
        }
        Write-BuildLog -Level Information -Component 'Invoke-IsoBuild' -Message 'Preview complete; no media modified.'
        return New-RunReport -ResolvedConfig $Config -Applied @($previewResults) -Skipped @() `
            -ToolVersions $toolVersions -Outcome 'Preview' `
            -OutputPath (Join-Path $Config.OutputDirectory 'run-report.preview.json')
    }

    # --- 4. Full build pipeline with guaranteed cleanup on failure (FR-005). ---
    $mounted = $null
    $applied = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $baseImage = $null
    $artifact = $null
    $integrity = $null

    try {
        foreach ($dir in @($Config.WorkingDirectory, $Config.OutputDirectory)) {
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        }
        $mediaDir = Join-Path $Config.WorkingDirectory 'media'
        $mountDir = Join-Path $Config.WorkingDirectory 'mount'

        # 4a. Download / provide base ISO.
        $isoParams = @{
            Edition      = $Config.Edition
            Language     = $Config.Language
            Release      = $Config.Release
            Architecture = $Config.Architecture
            OutputPath   = $Config.WorkingDirectory
            FidoPath     = $Config.FidoPath
        }
        if (-not [string]::IsNullOrWhiteSpace($Config.IsoPath)) { $isoParams['IsoPath'] = $Config.IsoPath }
        $baseImage = Get-Windows11Iso @isoParams

        # 4b. Verify base image integrity BEFORE servicing (FR-020).
        if (-not $baseImage.Verified) {
            throw "Base image failed integrity verification; refusing to service it (FR-020)."
        }

        # 4c. Extract media and mount the requested edition.
        $media = Expand-WindowsImage -IsoPath $baseImage.Path -Destination $mediaDir
        $mounted = Mount-WindowsBuildImage -ImagePath $media.ImagePath -MountPath $mountDir -Edition $Config.Edition

        # 4d. Apply the documented changes.
        $applied.AddRange(@(Remove-Bloatware -MountPath $mounted.MountPath -Catalog $Config.SelectedCatalog -Architecture $Config.Architecture -Config $Config))
        $applied.AddRange(@(Set-RegistryTweaks -MountPath $mounted.MountPath -Catalog $Config.SelectedCatalog -Architecture $Config.Architecture -Config $Config))

        # 4e. Commit changes back to the image.
        Dismount-BuildImage -Path $mounted.MountPath -Save
        $mounted.IsMounted = $false

        # 4f. Author a bootable ISO and compress it.
        $outIso = Join-Path $Config.WorkingDirectory ("Windows11-$($Config.Edition)-$($Config.Architecture)-$($Config.Release).iso" -replace '\s', '')
        $null = New-BootableIso -MediaRoot $media.MediaRoot -Architecture $Config.Architecture -OutputIsoPath $outIso -OscdimgPath $Config.OscdimgPath
        $artifact = Compress-BuildArtifact -IsoPath $outIso -OutputDirectory $Config.OutputDirectory `
            -Format $Config.CompressionFormat -Edition $Config.Edition -Architecture $Config.Architecture -Release $Config.Release

        # 4g. Validate the produced ISO.
        $integrity = Test-ImageIntegrity -IsoPath $outIso -Architecture $Config.Architecture -BootTest:$wantBootTest
        $artifact | Add-Member -NotePropertyName 'IntegrityResult' -NotePropertyValue $integrity -Force
        if (-not $integrity.Passed) {
            throw "Produced image failed integrity validation; not presenting it as a successful build (FR-005/FR-023)."
        }

        # 4h. Emit the success RunReport.
        $report = New-RunReport -ResolvedConfig $Config -BaseImage $baseImage `
            -Applied $applied.ToArray() -Skipped $skipped.ToArray() -Artifact $artifact -Integrity $integrity `
            -ToolVersions $toolVersions -Outcome 'Succeeded' `
            -OutputPath (Join-Path $Config.OutputDirectory 'run-report.json')

        Write-BuildLog -Level Information -Component 'Invoke-IsoBuild' -Message "Build succeeded: $($artifact.ArchivePath)."
        return $report
    }
    catch {
        # Failure cleanup: never leave a mounted image / hive behind; never claim success.
        Write-BuildLog -Level Error -Component 'Invoke-IsoBuild' -Message "Build failed: $($_.Exception.Message)"
        if ($mounted -and $mounted.IsMounted) {
            try {
                Dismount-BuildImage -Path $mounted.MountPath -Discard
                Write-BuildLog -Level Warning -Component 'Invoke-IsoBuild' -Message 'Discarded mounted image after failure.'
            }
            catch {
                Write-BuildLog -Level Warning -Component 'Invoke-IsoBuild' -Message "Cleanup dismount failed: $($_.Exception.Message)"
            }
        }
        # Best-effort failure report for the audit trail.
        try {
            New-RunReport -ResolvedConfig $Config -BaseImage $baseImage -Applied $applied.ToArray() `
                -Skipped $skipped.ToArray() -Artifact $artifact -Integrity $integrity `
                -ToolVersions $toolVersions -Outcome 'Failed' `
                -OutputPath (Join-Path $Config.OutputDirectory 'run-report.failed.json') | Out-Null
        }
        catch {
            Write-BuildLog -Level Warning -Component 'Invoke-IsoBuild' -Message "Could not write failure report: $($_.Exception.Message)"
        }
        throw
    }
}

function Get-BuildToolVersion {
    <#
    .SYNOPSIS
        Collect tool/module versions for the RunReport (Principle V reproducibility).
    .DESCRIPTION
        Private helper. Gathers the PowerShell version, pinned Fido tag/commit (from the
        vendored VERSION file), and Pester/PSScriptAnalyzer versions if present.
    .PARAMETER Config
        The resolved BuildConfiguration (for the Fido path).
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()] $Config)

    $versions = @{
        PowerShell = $PSVersionTable.PSVersion.ToString()
    }

    $manifestPath = Join-Path $script:ModuleRoot 'WindowsIsoMaker.psd1'
    if (Test-Path -LiteralPath $manifestPath) {
        $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
        if ($manifest.PrivateData -and $manifest.PrivateData.PSData -and $manifest.PrivateData.PSData.RequiredToolingMinimums) {
            $mins = $manifest.PrivateData.PSData.RequiredToolingMinimums
            $versions['FidoTag'] = $mins.FidoTag
            $versions['FidoCommit'] = $mins.FidoCommit
            $versions['WindowsAdkMinimum'] = $mins.WindowsAdk
        }
    }

    foreach ($mod in 'Pester', 'PSScriptAnalyzer') {
        $m = Get-Module -ListAvailable -Name $mod | Sort-Object Version -Descending | Select-Object -First 1
        if ($m) { $versions[$mod] = $m.Version.ToString() }
    }

    return $versions
}
