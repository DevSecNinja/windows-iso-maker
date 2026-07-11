function Select-CatalogEntry {
    <#
    .SYNOPSIS
        Resolve which catalog entries are enabled for a given configuration.
    .DESCRIPTION
        Applies the selection rules for a build (FR-006/FR-007/FR-008): start from each
        entry's DefaultEnabled state for the active profile, force-enable opt-in Edge/OneDrive
        removals only when their flags are set, honor explicit include/exclude id lists, and
        filter to entries applicable to the target architecture (Principle IV). Returns the
        enabled entries in stable order.
    .PARAMETER Catalog
        The full flattened catalog (from Import-ChangeCatalog).
    .PARAMETER Architecture
        Target architecture ('amd64' or 'arm64'); entries not listing it are excluded.
    .PARAMETER IncludeCatalogId
        Ids to force-enable even if DefaultEnabled is $false.
    .PARAMETER ExcludeCatalogId
        Ids to force-disable even if DefaultEnabled is $true.
    .PARAMETER RemoveEdge
        When set, enables the 'remove-edge' opt-in entry.
    .PARAMETER RemoveOneDrive
        When set, enables the 'remove-onedrive' opt-in entry.
    .EXAMPLE
        $enabled = Select-CatalogEntry -Catalog $all -Architecture amd64 -RemoveEdge
    .OUTPUTS
        System.Object[] of enabled catalog entries.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Catalog,

        [Parameter(Mandatory = $true)]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter()]
        [string[]] $IncludeCatalogId = @(),

        [Parameter()]
        [string[]] $ExcludeCatalogId = @(),

        [Parameter()]
        [bool] $RemoveEdge = $false,

        [Parameter()]
        [bool] $RemoveOneDrive = $false
    )

    # Opt-in removal entries are only ever enabled via their dedicated flags.
    $optInFlagMap = @{
        'remove-edge'      = $RemoveEdge
        'remove-onedrive'  = $RemoveOneDrive
    }

    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $Catalog) {
        # Architecture filter first (Principle IV).
        if (@($entry.Arch) -notcontains $Architecture) {
            continue
        }

        $enabled = [bool]$entry.DefaultEnabled

        if ($optInFlagMap.ContainsKey($entry.Id)) {
            # Dedicated opt-in entries ignore DefaultEnabled and follow their flag.
            $enabled = [bool]$optInFlagMap[$entry.Id]
        }

        if ($IncludeCatalogId -contains $entry.Id) {
            $enabled = $true
        }
        if ($ExcludeCatalogId -contains $entry.Id) {
            $enabled = $false
        }

        if ($enabled) {
            $selected.Add($entry)
        }
    }

    return $selected.ToArray()
}
