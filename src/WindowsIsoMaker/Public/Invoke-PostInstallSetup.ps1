function Invoke-PostInstallSetup {
    <#
    .SYNOPSIS
        Apply the debloat change-catalog (any profile) to the machine you are running on — the
        post-install path for a fresh Windows 11 you did NOT build with this tool.
    .DESCRIPTION
        This is the ONLINE sibling of Invoke-IsoBuild. Instead of servicing an offline image and
        producing an ISO, it applies the SAME data-driven change catalog to the RUNNING system, so
        you can take a stock Windows 11 (a cloud/OS reset, or an ISO downloaded from your Visual
        Studio subscription) and run e.g. the 'opinionated' profile on it directly — no custom ISO
        required.

        Selection is fully DATA-DRIVEN and identical to the build path (FR-024): the effective set
        of entries is resolved from the Profile baseline(s), the Toggles map, and
        EnableCatalogId/DisableCatalogId via Resolve-CatalogSelection, then applied through the
        online dispatcher (Invoke-OnlineCatalogEntry):

            SetRegistry                            -> live HKLM (machine) + HKCU / default-user hive
            RemoveAppx                             -> de-provision (future users) + uninstall (me)
            RemoveCapability                       -> dism /online /Remove-Capability
            EnableOptionalFeature / AddCapability  -> dism /online (additive; may need a reboot)

        The architecture is auto-detected from the running OS (override with -Architecture). Every
        step is idempotent (FR-017) and honours -WhatIf (FR-016), which previews the full plan
        without changing anything. A per-run RunReport (FR-022) is returned and, unless
        -NoReport is set, written to the output directory for the audit trail.

        Requires an elevated (Administrator) session for machine-wide (HKLM / dism) changes.
    .PARAMETER Profile
        Catalog profile baseline(s): one or more of 'minimal' | 'default' | 'aggressive' |
        'gaming' | 'opinionated' (e.g. -Profile gaming,opinionated). Multiple values are UNIONed.
        Defaults to 'default'.
    .PARAMETER EnableCatalogId
        Opt-in catalog ids to force-enable (e.g. 'remove-edge','feature-wsl').
    .PARAMETER DisableCatalogId
        Catalog ids to force-disable (explicit ids win).
    .PARAMETER Toggles
        Optional hashtable of per-id boolean overrides (Id -> $true/$false).
    .PARAMETER Architecture
        Optional override for the target architecture ('amd64' | 'arm64'). Auto-detected from the
        running OS when omitted.
    .PARAMETER Scope
        Which per-user targets receive per-user (DEFAULT-hive) tweaks and Appx removals:
        'CurrentUser' (only the profile you are logged in as), 'FutureUsers' (only new profiles),
        or 'Both' (default — the running user AND every new profile).
    .PARAMETER OutputDirectory
        Directory to write the run-report JSON into. Defaults to './out'.
    .PARAMETER NoReport
        Do not write the run-report JSON to disk (the object is still returned).
    .EXAMPLE
        Invoke-PostInstallSetup -Profile opinionated
        Applies the opinionated profile to the running machine.
    .EXAMPLE
        Invoke-PostInstallSetup -Profile aggressive -WhatIf
        Previews every change the aggressive profile would make, touching nothing.
    .OUTPUTS
        PSCustomObject (RunReport).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', 'Profile',
        Justification = "'Profile' is the documented, user-facing catalog concept (minimal/default/aggressive/gaming/opinionated). The parameter is locally scoped and never writes the global profile path.")]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'SupportsShouldProcess is declared only so -WhatIf is accepted and propagates ($WhatIfPreference) to the online appliers (Set-OnlineRegistryTweaks / Remove-OnlineBloatware / Enable-OnlineWindowsFeature), each of which implements ShouldProcess/-WhatIf. This orchestrator performs no direct state change of its own.')]
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateSet('minimal', 'default', 'aggressive', 'gaming', 'opinionated')]
        [string[]] $Profile = @('default'),

        [Parameter()]
        [string[]] $EnableCatalogId = @(),

        [Parameter()]
        [string[]] $DisableCatalogId = @(),

        [Parameter()]
        [hashtable] $Toggles = @{},

        [Parameter()]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter()]
        [ValidateSet('CurrentUser', 'FutureUsers', 'Both')]
        [string] $Scope = 'Both',

        [Parameter()]
        [string] $OutputDirectory = './out',

        [Parameter()]
        [switch] $NoReport
    )

    $isPreview = $WhatIfPreference

    # --- 1. Resolve architecture (auto-detect from the running OS unless overridden). ---
    $arch = if ($PSBoundParameters.ContainsKey('Architecture') -and $Architecture) {
        $Architecture
    }
    else {
        Get-OnlineArchitecture
    }

    # --- 2. Elevation gate (machine-wide HKLM/dism changes need admin). Relaxed in preview. ---
    if (-not $isPreview -and -not (Test-IsAdministrator)) {
        throw "Invoke-PostInstallSetup must run in an elevated (Administrator) PowerShell session to apply machine-wide changes. Re-run as administrator, or use -WhatIf to preview."
    }

    # --- 3. Resolve the effective catalog selection (data-driven; validates unknown ids). ---
    $toggleMap = @{}
    foreach ($k in $Toggles.Keys) { $toggleMap[[string]$k] = [bool]$Toggles[$k] }

    $catalog = Import-ChangeCatalog
    $selected = @(Resolve-CatalogSelection -Catalog $catalog -Architecture $arch `
            -Profile $Profile -Toggles $toggleMap `
            -EnableCatalogId @($EnableCatalogId) -DisableCatalogId @($DisableCatalogId))

    $resolvedConfig = [pscustomobject]@{
        PSTypeName       = 'WindowsIsoMaker.PostInstallConfiguration'
        Mode             = 'PostInstall'
        Architecture     = $arch
        Profile          = ($Profile -join ', ')
        Scope            = $Scope
        Toggles          = $toggleMap
        EnableCatalogId  = @($EnableCatalogId)
        DisableCatalogId = @($DisableCatalogId)
        OutputDirectory  = $OutputDirectory
        SelectedCatalog  = $selected
    }

    $toolVersions = @{
        PowerShell = $PSVersionTable.PSVersion.ToString()
    }

    Write-BuildLog -Level Information -Component 'Invoke-PostInstallSetup' -Message "Post-install setup (Arch=$arch, Profile=$($resolvedConfig.Profile), Scope=$Scope, Entries=$($selected.Count), Preview=$isPreview)."

    if ($selected.Count -eq 0) {
        Write-BuildLog -Level Warning -Component 'Invoke-PostInstallSetup' -Message 'No catalog entries selected for the requested profile/architecture; nothing to do.'
    }

    # --- 4. Apply (or preview) every selected entry through the online dispatcher. ---
    $applied = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $outcome = if ($isPreview) { 'Preview' } else { 'Succeeded' }

    foreach ($entry in $selected) {
        $result = Invoke-OnlineCatalogEntry -Entry $entry -Architecture $arch -Scope $Scope
        if ("$($result.Status)" -eq 'Skipped') {
            $skipped.Add($result)
        }
        else {
            $applied.Add($result)
        }
    }

    if (-not $isPreview) {
        $failed = @($applied | Where-Object { "$($_.Status)" -eq 'Failed' })
        if ($failed.Count -gt 0) {
            $outcome = 'Failed'
            Write-BuildLog -Level Warning -Component 'Invoke-PostInstallSetup' -Message "$($failed.Count) catalog entr(ies) failed to apply; see the run report for details."
        }
    }

    # --- 5. Emit (and optionally persist) the auditable RunReport (FR-022). ---
    $reportParams = @{
        ResolvedConfig = $resolvedConfig
        Applied        = @($applied)
        Skipped        = @($skipped)
        ToolVersions   = $toolVersions
        Outcome        = $outcome
    }
    if (-not $NoReport.IsPresent) {
        $reportName = if ($isPreview) { 'post-install-report.preview.json' } else { 'post-install-report.json' }
        $reportParams['OutputPath'] = Join-Path $OutputDirectory $reportName
    }

    $report = New-RunReport @reportParams
    Write-BuildLog -Level Information -Component 'Invoke-PostInstallSetup' -Message "Post-install setup complete (Outcome=$outcome, Applied=$($applied.Count), Skipped=$($skipped.Count))."
    return $report
}
