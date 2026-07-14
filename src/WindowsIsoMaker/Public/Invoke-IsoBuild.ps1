function Invoke-IsoBuild {
    <#
    .SYNOPSIS
        Orchestrate the full Windows 11 debloat/build pipeline — the single shared entry for
        local and CI runs (Principle V, FR-010).
    .DESCRIPTION
        Resolves configuration (the config file is the primary interface), verifies
        preconditions (fail fast — FR-019), then runs the pipeline: download the base ISO ->
        verify integrity (FR-020) -> extract media -> mount the image -> apply every selected
        catalog entry through the Action dispatcher (Invoke-CatalogEntry) -> commit
        (dismount -Save) -> render a per-arch Autounattend.xml -> author a bootable ISO with
        the Autounattend at its root + a SHA256SUMS manifest (FR-027/FR-028) -> compress the
        artifact -> validate integrity -> emit an auditable RunReport (FR-022) -> derive the
        Image BOM (FR-029).

        Selection is DATA-DRIVEN (FR-024): there are NO per-feature switches. Edge/OneDrive/WSL
        are opt-in catalog entries chosen via Profile / Toggles / EnableCatalogId.

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
    .PARAMETER Profile
        Optional profile override: one or more of 'minimal' | 'default' | 'aggressive' | 'gaming' |
        'opinionated' (e.g. -Profile gaming,opinionated). Multiple values are UNIONed; 'gaming'
        preserves the gaming stack.
    .PARAMETER EnableCatalogId
        Optional opt-in catalog ids (e.g. 'remove-edge','feature-wsl').
    .PARAMETER DisableCatalogId
        Optional force-disable catalog ids.
    .PARAMETER IsoPath
        Optional pre-downloaded base ISO (skips Fido). Required for non-Home editions, which only
        ship on the business/volume ISO.
    .PARAMETER ProductKey
        Optional override for the Autounattend product key (config Autounattend.ProductKey). Applied
        in the windowsPE UserData pass so multi-edition 24H2 media does not stop at the interactive
        product-key page. '' / 'none' omit the key (Setup may prompt on multi-edition media); a
        genuine key activates when valid.
    .PARAMETER AccountMode
        Optional override for how the first OOBE account is provisioned (config
        Autounattend.AccountMode): 'local' (create a local admin, hands-off) or 'entra' (present
        the work/school sign-in so the device joins Entra ID / auto-enrolls into Intune).
    .PARAMETER UseGenericProductKey
        Bake the edition's generic/default retail product key, applied in the windowsPE UserData pass
        (non-activating). Handy for a fully hands-off Home build. Mutually exclusive with
        -ProductKey.
    .PARAMETER SkipHeavyBuild
        Preview/light path: no download/mount/build; still emits a RunReport (FR-014).
    .PARAMETER BootTest
        Opt-in VM boot validation in addition to structural checks (FR-023).
    .PARAMETER KeepBootTestVm
        With -BootTest, keep the throwaway VM alive and pause for manual testing (vmconnect)
        until you press Enter, then tear it down. No effect unless the boot test runs.
    .EXAMPLE
        Invoke-IsoBuild -ConfigPath config/build.config.psd1 -Architecture amd64
    .EXAMPLE
        Invoke-IsoBuild -WhatIf
        Previews all intended changes without touching any media.
    .OUTPUTS
        PSCustomObject (RunReport).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', 'Profile',
        Justification = "'Profile' is the documented, user-facing configuration concept (minimal/default/aggressive). The parameter is locally scoped and never writes the global profile path.")]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCmdletCorrectly', '',
        Justification = 'Known PSScriptAnalyzer false positive: the Expand-WindowsImage call below supplies both of its mandatory parameters (-IsoPath and -Destination); see PSScriptAnalyzerSettings.psd1 for related upstream analyzer issues.')]
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
        [ValidateSet('minimal', 'default', 'aggressive', 'gaming', 'opinionated')]
        [string[]] $Profile,

        [Parameter()]
        [string[]] $EnableCatalogId,

        [Parameter()]
        [string[]] $DisableCatalogId,

        [Parameter()]
        [string] $IsoPath,

        [Parameter()]
        [AllowEmptyString()]
        [string] $ProductKey,

        [Parameter()]
        [ValidateSet('local', 'entra', 'entraid', 'azuread')]
        [string] $AccountMode,

        [Parameter()]
        [switch] $UseGenericProductKey,

        [Parameter()]
        [switch] $SkipHeavyBuild,

        [Parameter()]
        [switch] $BootTest,

        [Parameter()]
        [switch] $KeepBootTestVm
    )

    # --- 0. Reject mutually exclusive product-key inputs (fail fast). ---
    # -UseGenericProductKey bakes the edition's generic key while -ProductKey bakes a specific one;
    # supplying both is contradictory, so error instead of silently letting -ProductKey win.
    if ($UseGenericProductKey.IsPresent -and $PSBoundParameters.ContainsKey('ProductKey')) {
        throw '-ProductKey and -UseGenericProductKey are mutually exclusive. Pass -ProductKey ' +
            "'<key>' to bake a specific key, or -UseGenericProductKey for the edition's generic key - not both."
    }

    # --- 1. Resolve configuration (config file is primary; params are last-mile overrides). ---
    if (-not $Config) {
        $cfgParams = @{}
        if ($PSBoundParameters.ContainsKey('ConfigPath')) { $cfgParams['Path'] = $ConfigPath }
        foreach ($n in 'Architecture', 'Edition', 'Language', 'Release', 'Profile', 'EnableCatalogId', 'DisableCatalogId', 'IsoPath') {
            if ($PSBoundParameters.ContainsKey($n)) { $cfgParams[$n] = $PSBoundParameters[$n] }
        }
        $Config = Get-BuildConfiguration @cfgParams
    }

    # Last-mile ProductKey / AccountMode overrides apply to the nested Autounattend sub-config (not
    # top-level fields, so Get-BuildConfiguration does not carry them). ProductKey (when set) is
    # applied in the windowsPE UserData pass; AccountMode selects local vs Entra-join OOBE provisioning.
    foreach ($ov in @(
            @{ Name = 'ProductKey';  Key = 'ProductKey' },
            @{ Name = 'AccountMode'; Key = 'AccountMode' })) {
        if ($PSBoundParameters.ContainsKey($ov.Name)) {
            $value = $PSBoundParameters[$ov.Name]
            $au = $Config.Autounattend
            if ($au -is [hashtable]) { $au[$ov.Key] = $value }
            elseif ($null -ne $au) { $au | Add-Member -NotePropertyName $ov.Key -NotePropertyValue $value -Force }
        }
    }

    # -UseGenericProductKey bakes the edition's generic/default retail key, applied in the windowsPE
    # UserData pass (non-activating). The two are mutually exclusive (rejected in step 0), so at this
    # point -ProductKey is guaranteed absent whenever the switch is present.
    if ($UseGenericProductKey.IsPresent) {
        $au = $Config.Autounattend
        if ($au -is [hashtable]) { $au['ProductKey'] = 'generic' }
        elseif ($null -ne $au) { $au | Add-Member -NotePropertyName 'ProductKey' -NotePropertyValue 'generic' -Force }
    }

    $isPreview = $WhatIfPreference -or $SkipHeavyBuild.IsPresent
    $wantBootTest = $BootTest.IsPresent -or [bool]$Config.BootTest
    # StrictMode-safe: a Config built by tests may not carry KeepBootTestVm.
    $configKeepVm = if ($Config.PSObject.Properties.Match('KeepBootTestVm').Count -gt 0) { [bool]$Config.KeepBootTestVm } else { $false }
    $wantKeepBootTestVm = $KeepBootTestVm.IsPresent -or $configKeepVm
    $toolVersions = Get-BuildToolVersion -Config $Config

    Write-BuildLog -Level Information -Component 'Invoke-IsoBuild' -Message "Starting build (Arch=$($Config.Architecture), Edition=$($Config.Edition), Profile=$($Config.Profile), Preview=$isPreview)."

    # --- 2. Preconditions gate (fail fast; relaxed in preview). ---
    $null = Test-BuildPrerequisite -WorkingDirectory $Config.WorkingDirectory `
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
            -ToolVersions $toolVersions -Autounattend $Config.Autounattend -Outcome 'Preview' `
            -OutputPath (Join-Path $Config.OutputDirectory 'run-report.preview.json')
    }

    # --- 4. Full build pipeline with guaranteed cleanup on failure (FR-005). ---
    $mounted = $null
    $applied = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $baseImage = $null
    $artifact = $null
    $integrity = $null
    $report = $null

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
        # Recover from a prior hard-killed run that may have stranded a mount here; a single
        # Ctrl+C is handled by the finally block below, but a hard kill/power loss is not.
        Clear-StaleImageMount -MountPath $mountDir
        $mounted = Mount-WindowsBuildImage -ImagePath $media.ImagePath -MountPath $mountDir -Edition $Config.Edition

        # 4d. Apply every selected catalog entry through the Action dispatcher (FR-024/FR-025).
        foreach ($entry in @($Config.SelectedCatalog)) {
            $applied.Add((Invoke-CatalogEntry -Entry $entry -MountPath $mounted.MountPath -Architecture $Config.Architecture -Config $Config))
        }

        # 4e. Commit changes back to the image.
        Dismount-BuildImage -Path $mounted.MountPath -Save
        $mounted.IsMounted = $false

        # 4f. Render a per-arch Autounattend.xml (FR-027).
        $unattendPath = $null
        if ($Config.Autounattend -and (& { $au = $Config.Autounattend; if ($au -is [hashtable]) { -not $au.ContainsKey('Enabled') -or $au['Enabled'] } else { $true } })) {
            $unattendPath = Join-Path $Config.WorkingDirectory 'Autounattend.xml'
            $null = New-AutounattendXml -Config $Config -Architecture $Config.Architecture -OutputPath $unattendPath
        }

        # 4g. Author a bootable ISO (Autounattend at root + SHA256SUMS) and compress it.
        $outIso = Join-Path $Config.WorkingDirectory ("Windows11-$($Config.Edition)-$($Config.Architecture)-$($Config.Release).iso" -replace '\s', '')
        $isoParams2 = @{
            MediaRoot     = $media.MediaRoot
            Architecture  = $Config.Architecture
            OutputIsoPath = $outIso
            OscdimgPath   = $Config.OscdimgPath
        }
        if ($unattendPath) { $isoParams2['AutounattendPath'] = $unattendPath }
        $null = New-BootableIso @isoParams2
        $artifact = Compress-BuildArtifact -IsoPath $outIso -OutputDirectory $Config.OutputDirectory `
            -Format $Config.CompressionFormat -Edition $Config.Edition -Architecture $Config.Architecture -Release $Config.Release

        # 4h. Validate the produced ISO. Harvest any boot-test Setup logs into the output dir so a
        # failed unattended install is diagnosable locally and in CI (uploaded with the artifacts).
        $diagPath = Join-Path $Config.OutputDirectory 'boottest-diagnostics'
        $integrity = Test-ImageIntegrity -IsoPath $outIso -Architecture $Config.Architecture -BootTest:$wantBootTest -KeepBootTestVm:$wantKeepBootTestVm -DiagnosticsPath $diagPath
        $artifact | Add-Member -NotePropertyName 'IntegrityResult' -NotePropertyValue $integrity -Force

        # Structural checks are authoritative: an image that fails them is bad media -> fatal.
        # StrictMode-safe access: some tests mock Test-ImageIntegrity with a minimal object.
        $structural = if ($integrity.PSObject.Properties.Match('Structural').Count) { @($integrity.Structural) } else { @() }
        $structuralFailed = @($structural | Where-Object { -not $_.Passed })
        if ($structuralFailed.Count -gt 0) {
            $failedNames = ($structuralFailed | ForEach-Object { $_.Name }) -join ', '
            throw "Produced image failed structural integrity validation ($failedNames); not presenting it as a successful build (FR-005/FR-023)."
        }

        # The opt-in VM boot test is a separate signal. Distinguish a REAL boot/install failure
        # (the image would not boot or the unattended install never progressed: BootReset/Timeout/
        # NoInstallProgress) from an ENVIRONMENTAL one (Hyper-V unavailable or the test errored:
        # None/Error). Only a real failure fails an otherwise-valid build; an environmental one is
        # a warning so a structurally-sound ISO is not discarded because the host could not run the
        # boot test.
        $boot = if ($integrity.PSObject.Properties.Match('Boot').Count) { $integrity.Boot } else { $null }
        if ($null -ne $boot -and -not $boot.Passed) {
            if ($boot.Method -in @('None', 'Error')) {
                Write-BuildLog -Level Warning -Component 'Invoke-IsoBuild' -Message "VM boot test could not run ($($boot.Method)): $($boot.Detail) Structural checks passed; continuing."
            }
            else {
                $diag = if ($boot.PSObject.Properties.Match('Diagnostics').Count -and $boot.Diagnostics) { " Windows Setup logs harvested to '$($boot.Diagnostics.Path)'." } else { '' }
                throw "Produced image failed the VM boot test ($($boot.Method)): $($boot.Detail)$diag (FR-023)."
            }
        }

        # 4i. Emit the success RunReport, then derive the Image BOM from it (FR-029).
        $report = New-RunReport -ResolvedConfig $Config -BaseImage $baseImage `
            -Applied $applied.ToArray() -Skipped $skipped.ToArray() -Artifact $artifact -Integrity $integrity `
            -ToolVersions $toolVersions -Autounattend $Config.Autounattend -Outcome 'Succeeded' `
            -OutputPath (Join-Path $Config.OutputDirectory 'run-report.json')

        $bom = Export-ImageBom -RunReport $report -OutputDirectory $Config.OutputDirectory
        $report | Add-Member -NotePropertyName 'Bom' -NotePropertyValue $bom -Force

        Write-BuildLog -Level Information -Component 'Invoke-IsoBuild' -Message "Build succeeded: $($artifact.ArchivePath)."
        return $report
    }
    catch {
        # Never claim success on failure; record an auditable failure report. The actual
        # dismount lives in the finally block so it also runs on Ctrl+C (see below).
        Write-BuildLog -Level Error -Component 'Invoke-IsoBuild' -Message "Build failed: $($_.Exception.Message)"
        # Best-effort failure report for the audit trail.
        try {
            New-RunReport -ResolvedConfig $Config -BaseImage $baseImage -Applied $applied.ToArray() `
                -Skipped $skipped.ToArray() -Artifact $artifact -Integrity $integrity `
                -ToolVersions $toolVersions -Autounattend $Config.Autounattend -Outcome 'Failed' `
                -OutputPath (Join-Path $Config.OutputDirectory 'run-report.failed.json') | Out-Null
        }
        catch {
            Write-BuildLog -Level Warning -Component 'Invoke-IsoBuild' -Message "Could not write failure report: $($_.Exception.Message)"
        }
        throw
    }
    finally {
        # Guaranteed cleanup: runs on success (a no-op after the commit at 4e set IsMounted=$false),
        # on error, AND on Ctrl+C. A plain catch does NOT execute on Ctrl+C / pipeline-stop, so the
        # dismount MUST live here to avoid stranding a mounted image (FR-005 / Principle VI).
        if ($mounted -and $mounted.IsMounted) {
            try {
                Dismount-BuildImage -Path $mounted.MountPath -Discard
                $mounted.IsMounted = $false
                Write-BuildLog -Level Warning -Component 'Invoke-IsoBuild' -Message 'Discarded mounted image during cleanup (uncommitted changes).'
            }
            catch {
                Write-BuildLog -Level Warning -Component 'Invoke-IsoBuild' -Message "Cleanup dismount failed: $($_.Exception.Message). If a stale mount remains, run 'dism /Cleanup-Mountpoints'."
            }
        }
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
