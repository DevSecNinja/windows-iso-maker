function Import-ChangeCatalog {
    <#
    .SYNOPSIS
        Load and flatten all change-catalog entries from the config directory.
    .DESCRIPTION
        Reads every config/catalog.*.psd1 file (each returns a hashtable with an 'Entries'
        array) and returns a single flat array of catalog entry objects. The catalog is the
        data-driven source of every documented system change (Constitution Principle II).

        Entries are returned in APPLY order: the authoring order of the files, adjusted by a stable
        topological sort so every entry follows the ids it declares in `RunAfter` (see
        Resolve-CatalogOrder). Ordering therefore happens once, at load, for every consumer —
        offline build, online post-install, and the manifest/BOM exports alike.
    .PARAMETER CatalogDirectory
        Directory containing the catalog.*.psd1 files. Defaults to the repository config/ dir.
    .EXAMPLE
        $entries = Import-ChangeCatalog
    .OUTPUTS
        System.Object[] of catalog entry hashtables.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()]
        [string] $CatalogDirectory
    )

    if (-not $CatalogDirectory) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $script:ModuleRoot)
        $CatalogDirectory = Join-Path -Path $repoRoot -ChildPath 'config'
    }

    if (-not (Test-Path -LiteralPath $CatalogDirectory)) {
        throw "Catalog directory not found: '$CatalogDirectory'."
    }

    $files = Get-ChildItem -LiteralPath $CatalogDirectory -Filter 'catalog.*.psd1' -File |
        Sort-Object -Property Name
    if (-not $files) {
        throw "No catalog.*.psd1 files found in '$CatalogDirectory'."
    }

    $all = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        $data = Import-PowerShellDataFile -LiteralPath $file.FullName
        $entries = if ($data -is [hashtable] -and $data.ContainsKey('Entries')) { $data.Entries } else { $data }
        foreach ($entry in @($entries)) {
            $obj = [pscustomobject]$entry
            $obj | Add-Member -NotePropertyName 'SourceFile' -NotePropertyValue $file.Name -Force
            $all.Add($obj)
        }
    }

    # A RunAfter id that does not exist anywhere in the catalog is always an authoring mistake
    # (typo, or an entry that was renamed/removed): fail loudly here rather than silently dropping
    # the ordering constraint and shipping an image whose changes ran in the wrong sequence.
    $knownIds = @($all | ForEach-Object { [string]$_.Id })
    foreach ($entry in $all) {
        foreach ($dep in (Get-CatalogEntryRunAfter -Entry $entry)) {
            if ($knownIds -notcontains $dep) {
                throw "Catalog entry '$($entry.Id)' declares RunAfter = '$dep', which is not a known catalog id."
            }
        }
    }

    return Resolve-CatalogOrder -Catalog $all.ToArray()
}
