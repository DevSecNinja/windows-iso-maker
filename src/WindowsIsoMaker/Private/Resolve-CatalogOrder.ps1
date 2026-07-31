function Get-CatalogEntryRunAfter {
    <#
    .SYNOPSIS
        Return a catalog entry's declared RunAfter prerequisite ids as a string array (empty when
        it declares none), handling both hashtable and pscustomobject entry shapes.
    .DESCRIPTION
        `RunAfter` is the optional, data-driven ordering declaration: it lists the ids of catalog
        entries that MUST be applied before this one. It is a pure ORDERING constraint — it never
        enables the referenced entry and never fails when that entry is filtered out of the run by
        the architecture/profile selection.
    .PARAMETER Entry
        A single catalog entry (hashtable from the psd1, or the pscustomobject Import-ChangeCatalog
        produces).
    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)] [object] $Entry
    )

    $value = $null
    if ($Entry -is [System.Collections.IDictionary]) {
        if ($Entry.Contains('RunAfter')) { $value = $Entry['RunAfter'] }
    }
    elseif ($Entry.PSObject.Properties.Name -contains 'RunAfter') {
        $value = $Entry.RunAfter
    }
    return [string[]]@($value | ForEach-Object { [string]$_ } | Where-Object { $_ })
}

function Resolve-CatalogOrder {
    <#
    .SYNOPSIS
        Order change-catalog entries so that every entry is applied AFTER the entries listed in its
        RunAfter field (stable topological sort).
    .DESCRIPTION
        Some changes are only correct in a particular sequence — most importantly first-logon
        RunOnce commands, which Windows executes in registry enumeration order (i.e. the order the
        values were written, NOT alphabetically). Rather than relying on the implicit order entries
        happen to be authored in, an entry declares its prerequisites explicitly:

            RunAfter = @('reg-region-format-nl')

        This function turns those declarations into a concrete apply order using a STABLE
        topological sort: among the entries whose prerequisites are all satisfied it always picks
        the one that appears earliest in the input, so the catalog's authoring order is preserved
        everywhere ordering is not constrained. The result is used by every consumer (offline
        build, online post-install, manifest/BOM export) because Import-ChangeCatalog applies it at
        load time.

        RunAfter ids that are not present in the supplied set impose no constraint. That is
        deliberate: this function is also safe to run on a filtered subset, and an ordering
        prerequisite that was never selected cannot be violated. Import-ChangeCatalog separately
        validates, against the FULL catalog, that every RunAfter id actually exists.
    .PARAMETER Catalog
        The catalog entries to order.
    .EXAMPLE
        $ordered = Resolve-CatalogOrder -Catalog (Import-ChangeCatalog)
    .OUTPUTS
        System.Object[] — the same entries, reordered.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Catalog
    )

    $entries = @($Catalog)
    if ($entries.Count -le 1) {
        return $entries
    }

    $indexById = @{}
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $id = [string]$entries[$i].Id
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw "Catalog entry at position $i has no Id; ordering requires a unique Id on every entry."
        }
        if ($indexById.ContainsKey($id)) {
            throw "Duplicate catalog id '$id'; ordering requires globally unique ids."
        }
        $indexById[$id] = $i
    }

    # Per-entry prerequisite positions, restricted to ids present in this set.
    $prerequisites = @{}
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $needs = [System.Collections.Generic.List[int]]::new()
        foreach ($dep in (Get-CatalogEntryRunAfter -Entry $entries[$i])) {
            if ($dep -eq [string]$entries[$i].Id) {
                throw "Catalog entry '$dep' lists itself in RunAfter."
            }
            if ($indexById.ContainsKey($dep)) {
                [void]$needs.Add($indexById[$dep])
            }
        }
        $prerequisites[$i] = $needs
    }

    $emitted = [bool[]]::new($entries.Count)
    $ordered = [System.Collections.Generic.List[object]]::new()
    while ($ordered.Count -lt $entries.Count) {
        $picked = -1
        for ($i = 0; $i -lt $entries.Count; $i++) {
            if ($emitted[$i]) { continue }
            $ready = $true
            foreach ($need in $prerequisites[$i]) {
                if (-not $emitted[$need]) { $ready = $false; break }
            }
            if ($ready) { $picked = $i; break }
        }

        if ($picked -lt 0) {
            $stuck = for ($i = 0; $i -lt $entries.Count; $i++) {
                if (-not $emitted[$i]) { [string]$entries[$i].Id }
            }
            throw "Circular RunAfter dependency in the change catalog involving: $(@($stuck) -join ', ')."
        }

        $emitted[$picked] = $true
        [void]$ordered.Add($entries[$picked])
    }

    return $ordered.ToArray()
}
