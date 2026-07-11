function Import-ChangeCatalog {
    <#
    .SYNOPSIS
        Load and flatten all change-catalog entries from the config directory.
    .DESCRIPTION
        Reads every config/catalog.*.psd1 file (each returns a hashtable with an 'Entries'
        array) and returns a single flat array of catalog entry objects. The catalog is the
        data-driven source of every documented system change (Constitution Principle II).
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

    return $all.ToArray()
}
