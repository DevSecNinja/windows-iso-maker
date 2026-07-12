function Resolve-CatalogSelection {
    <#
    .SYNOPSIS
        Compute the effective set of enabled change-catalog entries for a build (FR-024).
    .DESCRIPTION
        Resolves which catalog entries apply to a build in a purely DATA-DRIVEN way (no
        per-feature switches). The resolution order is:

            1. Architecture filter (Principle IV) — entries not listing the target arch are dropped.
            2. Profile baseline — 'minimal' | 'default' | 'aggressive' selects an initial enabled set.
            3. Toggles map — per-id boolean overrides from the config (Id -> $true/$false).
            4. EnableCatalogId — force-enable specific ids (opt-in, e.g. 'remove-edge','feature-wsl').
            5. DisableCatalogId — force-disable specific ids (explicit ids win, applied last).

        Profile baselines (data-driven, derived from each entry's Action/EvidenceGrade/DefaultEnabled):
            * minimal    — only the DefaultEnabled registry policy tweaks (no app/capability removals).
            * default    — every entry whose DefaultEnabled is $true.
            * aggressive — the default set PLUS opt-in removal entries graded 1-2 (never grade-3,
                           never additive features such as WSL, which stay strictly opt-in).

        Any id referenced by Toggles/EnableCatalogId/DisableCatalogId that does not exist in the
        catalog raises a terminating error.
    .PARAMETER Catalog
        The full flattened catalog (from Import-ChangeCatalog).
    .PARAMETER Architecture
        Target architecture ('amd64' or 'arm64'); entries not listing it are excluded.
    .PARAMETER Profile
        Baseline profile: 'minimal' | 'default' | 'aggressive'.
    .PARAMETER Toggles
        Hashtable of per-id boolean overrides (Id -> $true/$false).
    .PARAMETER EnableCatalogId
        Ids to force-enable even if the profile/toggles leave them off.
    .PARAMETER DisableCatalogId
        Ids to force-disable even if the profile/toggles enable them (applied last).
    .EXAMPLE
        $enabled = Resolve-CatalogSelection -Catalog $all -Architecture amd64 -Profile default -EnableCatalogId 'feature-wsl'
    .OUTPUTS
        System.Object[] of enabled catalog entries (stable order).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', 'Profile',
        Justification = "'Profile' is the documented, user-facing configuration concept (minimal/default/aggressive). The parameter is locally scoped and never writes the global profile path.")]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Catalog,

        [Parameter(Mandatory = $true)]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter()]
        [ValidateSet('minimal', 'default', 'aggressive')]
        [string] $Profile = 'default',

        [Parameter()]
        [hashtable] $Toggles = @{},

        [Parameter()]
        [string[]] $EnableCatalogId = @(),

        [Parameter()]
        [string[]] $DisableCatalogId = @()
    )

    # --- Validate that every referenced id exists (terminating error on unknown). ---
    $knownIds = @($Catalog | ForEach-Object { $_.Id })
    $referenced = @()
    if ($Toggles) { $referenced += @($Toggles.Keys) }
    $referenced += @($EnableCatalogId)
    $referenced += @($DisableCatalogId)
    foreach ($id in $referenced) {
        if (-not [string]::IsNullOrWhiteSpace($id) -and ($knownIds -notcontains $id)) {
            throw "Unknown catalog id '$id' referenced in Toggles/EnableCatalogId/DisableCatalogId. Known ids: $($knownIds -join ', ')."
        }
    }

    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $Catalog) {
        # 1. Architecture filter first (Principle IV).
        if (@($entry.Arch) -notcontains $Architecture) {
            continue
        }

        # 2. Profile baseline.
        $enabled = Test-CatalogEntryInProfile -Entry $entry -Profile $Profile

        # 3. Toggles per-id override.
        if ($Toggles -and $Toggles.ContainsKey($entry.Id)) {
            $enabled = [bool]$Toggles[$entry.Id]
        }

        # 4. EnableCatalogId force-on.
        if ($EnableCatalogId -contains $entry.Id) {
            $enabled = $true
        }

        # 5. DisableCatalogId force-off (explicit ids win, applied last).
        if ($DisableCatalogId -contains $entry.Id) {
            $enabled = $false
        }

        if ($enabled) {
            $selected.Add($entry)
        }
    }

    return $selected.ToArray()
}

function Test-CatalogEntryInProfile {
    <#
    .SYNOPSIS
        Return whether a catalog entry is in a profile's baseline (private helper for
        Resolve-CatalogSelection).
    .DESCRIPTION
        Encapsulates the data-driven profile baseline rules so they live in exactly one place.
    .PARAMETER Entry
        A single catalog entry.
    .PARAMETER Profile
        'minimal' | 'default' | 'aggressive'.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)] [object] $Entry,
        [Parameter(Mandatory = $true)] [ValidateSet('minimal', 'default', 'aggressive')] [string] $Profile
    )

    $isDefault = [bool]$Entry.DefaultEnabled
    $grade = [int]$Entry.EvidenceGrade
    $action = [string]$Entry.Action

    switch ($Profile) {
        'minimal' {
            # Only the DefaultEnabled registry policy tweaks; no app/capability removals.
            return ($isDefault -and $action -eq 'SetRegistry')
        }
        'aggressive' {
            # Default set plus opt-in grade 1-2 REMOVAL entries (never grade-3, never additive
            # optional features such as WSL — those stay strictly opt-in).
            if ($isDefault) { return $true }
            return ($grade -le 2 -and $action -in @('RemoveAppx', 'RemoveCapability'))
        }
        default {
            # 'default'
            return $isDefault
        }
    }
}
