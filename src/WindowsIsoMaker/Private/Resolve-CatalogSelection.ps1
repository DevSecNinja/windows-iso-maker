function Resolve-CatalogSelection {
    <#
    .SYNOPSIS
        Compute the effective set of enabled change-catalog entries for a build (FR-024).
    .DESCRIPTION
        Resolves which catalog entries apply to a build in a purely DATA-DRIVEN way (no
        per-feature switches). The resolution order is:

            1. Architecture filter (Principle IV) — entries not listing the target arch are dropped.
            2. Profile baseline — one or more of 'minimal' | 'default' | 'aggressive' | 'gaming' |
               'opinionated' select an initial enabled set. When several profiles are given the
               baselines are UNIONed (an entry is enabled if ANY selected profile enables it), with
               one exception: if 'gaming' is among them, Category='Gaming' entries (Xbox / Game Bar)
               are kept (never removed) even though aggressive/opinionated otherwise remove them —
               so e.g. 'gaming','opinionated' = aggressive debloat + opinionated tweaks but a
               working gaming stack.
            3. Toggles map — per-id boolean overrides from the config (Id -> $true/$false).
            4. EnableCatalogId — force-enable specific ids (opt-in, e.g. 'remove-edge','feature-wsl').
            5. DisableCatalogId — force-disable specific ids (explicit ids win, applied last).

        Profile baselines (data-driven, derived from each entry's Action/EvidenceGrade/DefaultEnabled):
            * minimal    — only the DefaultEnabled registry policy tweaks (no app/capability removals).
            * default    — every entry whose DefaultEnabled is $true.
            * aggressive — the default set PLUS opt-in removal entries graded 1-2 (never grade-3,
                           never additive features such as WSL, which stay strictly opt-in).
            * gaming     — the default set MINUS entries tagged Category='Gaming' (Xbox Game Bar /
                           Xbox provisioned apps), so gaming functionality is preserved.
            * opinionated— the aggressive set PLUS personal-taste extras tagged Category='Opinionated'
                           (reversed mouse scroll, Start web-search off, lock-screen Spotlight off,
                           WSL + Virtual Machine Platform). These grade-3/additive opt-ins are in no
                           other profile, so this is the maintainer's "kitchen sink" preference set.

        Any id referenced by Toggles/EnableCatalogId/DisableCatalogId that does not exist in the
        catalog raises a terminating error.
    .PARAMETER Catalog
        The full flattened catalog (from Import-ChangeCatalog).
    .PARAMETER Architecture
        Target architecture ('amd64' or 'arm64'); entries not listing it are excluded.
    .PARAMETER Profile
        Baseline profile(s): one or more of 'minimal' | 'default' | 'aggressive' | 'gaming' |
        'opinionated'. Multiple values are UNIONed (with 'gaming' protecting the gaming stack).
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
        [ValidateSet('minimal', 'default', 'aggressive', 'gaming', 'opinionated')]
        [string[]] $Profile = @('default'),

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

        # 2. Profile baseline: an entry is enabled if ANY selected profile enables it (union of
        #    the chosen profiles).
        $enabled = $false
        foreach ($p in $Profile) {
            if (Test-CatalogEntryInProfile -Entry $entry -Profile $p) { $enabled = $true; break }
        }
        # 'gaming' protection wins over the other profiles in the union: when the combination
        # includes 'gaming', a Category='Gaming' entry (Xbox / Game Bar) is never removed by the
        # baseline, even though aggressive/opinionated otherwise would. An explicit EnableCatalogId
        # (step 4) can still force such a removal back on.
        if ($enabled -and ($Profile -contains 'gaming') -and ((Get-CatalogEntryCategory -Entry $entry) -eq 'Gaming')) {
            $enabled = $false
        }

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

function Get-CatalogEntryCategory {
    <#
    .SYNOPSIS
        Return a catalog entry's Category ('' when it has none), handling both hashtable and
        pscustomobject entry shapes (private helper for Resolve-CatalogSelection).
    .PARAMETER Entry
        A single catalog entry.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)] [object] $Entry
    )

    if ($Entry -is [System.Collections.IDictionary]) {
        if ($Entry.Contains('Category')) { return [string]$Entry['Category'] }
    }
    elseif (($Entry.PSObject.Properties.Name -contains 'Category')) {
        return [string]$Entry.Category
    }
    return ''
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
        'minimal' | 'default' | 'aggressive' | 'gaming'.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)] [object] $Entry,
        [Parameter(Mandatory = $true)] [ValidateSet('minimal', 'default', 'aggressive', 'gaming', 'opinionated')] [string] $Profile
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
        'gaming' {
            # Same debloat baseline as 'default', but preserve gaming components: entries tagged
            # Category='Gaming' (the Xbox Game Bar / Xbox provisioned apps) are never removed, so
            # gamers keep a working Xbox / Game Bar stack.
            if ((Get-CatalogEntryCategory -Entry $Entry) -eq 'Gaming') { return $false }
            return $isDefault
        }
        'opinionated' {
            # The 'aggressive' baseline PLUS personal-taste extras tagged Category='Opinionated'
            # (reversed mouse scroll, Start web-search off, lock-screen Spotlight off, WSL +
            # Virtual Machine Platform). Those grade-3/additive opt-ins appear in no other profile.
            if ((Get-CatalogEntryCategory -Entry $Entry) -eq 'Opinionated') { return $true }
            # Fall through to the aggressive baseline.
            if ($isDefault) { return $true }
            return ($grade -le 2 -and $action -in @('RemoveAppx', 'RemoveCapability'))
        }
        default {
            # 'default'
            return $isDefault
        }
    }
}
