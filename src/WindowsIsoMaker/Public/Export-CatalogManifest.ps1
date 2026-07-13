function Export-CatalogManifest {
    <#
    .SYNOPSIS
        Export the change catalog + profile membership to a JSON manifest for the website (FR-024).
    .DESCRIPTION
        Flattens every config/catalog.*.psd1 entry (via Import-ChangeCatalog) and, for each
        entry, records which baseline Profiles (minimal / default / aggressive / gaming) enable
        it — reusing the exact same profile logic the build uses (Test-CatalogEntryInProfile) so
        the published site can never drift from the tool's real behaviour.

        The emitted JSON is consumed by the static showcase/configurator site under site/. It is a
        pure read of the catalog data: no image is downloaded, mounted, or modified.
    .PARAMETER OutputPath
        Path of the JSON file to write (its parent directory is created if missing). When omitted,
        the manifest object is returned on the pipeline instead of being written.
    .PARAMETER CatalogDirectory
        Directory containing the catalog.*.psd1 files. Defaults to the repository config/ dir.
    .EXAMPLE
        Export-CatalogManifest -OutputPath ./site/data/catalog.json
    .OUTPUTS
        System.String (the OutputPath) when -OutputPath is supplied; otherwise the manifest object.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [string] $OutputPath,

        [Parameter()]
        [string] $CatalogDirectory
    )

    $importArgs = @{}
    if ($PSBoundParameters.ContainsKey('CatalogDirectory')) {
        $importArgs['CatalogDirectory'] = $CatalogDirectory
    }
    $entries = Import-ChangeCatalog @importArgs

    $profiles = @(
        [ordered]@{ Name = 'minimal';    Description = 'Only the default-enabled registry policy tweaks — no app or capability removals.' }
        [ordered]@{ Name = 'default';    Description = 'Every catalog entry marked DefaultEnabled — the balanced baseline.' }
        [ordered]@{ Name = 'aggressive'; Description = 'The default set plus opt-in grade 1-2 app/capability removals (never community-graded).' }
        [ordered]@{ Name = 'gaming';     Description = 'The default set, but Xbox / Game Bar (Category = Gaming) entries are preserved.' }
    )
    $profileNames = @($profiles | ForEach-Object { $_.Name })

    $manifestEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $entries) {
        $inProfiles = [System.Collections.Generic.List[string]]::new()
        foreach ($p in $profileNames) {
            if (Test-CatalogEntryInProfile -Entry $entry -Profile $p) {
                $inProfiles.Add($p)
            }
        }

        $prop = { param($name, $default)
            if ($entry.PSObject.Properties.Name -contains $name -and $null -ne $entry.$name) { return $entry.$name }
            return $default
        }

        $target = & $prop 'Target' $null
        if ($target -is [System.Collections.IDictionary]) {
            # Registry target -> a readable "Hive\Path!Name" string.
            $target = ('{0}\{1}!{2}' -f $target['Hive'], $target['Path'], $target['Name'])
        }

        $manifestEntries.Add([ordered]@{
            id             = [string](& $prop 'Id' '')
            type           = [string](& $prop 'Type' '')
            action         = [string](& $prop 'Action' '')
            category       = [string](& $prop 'Category' '')
            target         = [string]$target
            description    = [string](& $prop 'Description' '')
            rationale      = [string](& $prop 'Rationale' '')
            citation       = [string](& $prop 'Citation' '')
            evidenceGrade  = [int](& $prop 'EvidenceGrade' 0)
            reversible     = [bool](& $prop 'Reversible' $false)
            reversal       = [string](& $prop 'Reversal' '')
            defaultEnabled = [bool](& $prop 'DefaultEnabled' $false)
            arch           = @(& $prop 'Arch' @('amd64', 'arm64'))
            sourceFile     = [string](& $prop 'SourceFile' '')
            profiles       = @($inProfiles)
        })
    }

    $moduleVersion = ''
    try { $moduleVersion = [string](Get-Module WindowsIsoMaker | Select-Object -First 1).Version } catch { $moduleVersion = '' }

    $manifest = [ordered]@{
        schemaVersion  = 1
        generatedUtc   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        moduleVersion  = $moduleVersion
        defaultProfile = 'default'
        profiles       = @($profiles | ForEach-Object { [ordered]@{ name = $_.Name; description = $_.Description } })
        categories     = @($manifestEntries | ForEach-Object { $_.category } | Where-Object { $_ } | Sort-Object -Unique)
        types          = @($manifestEntries | ForEach-Object { $_.type } | Where-Object { $_ } | Sort-Object -Unique)
        entryCount     = $manifestEntries.Count
        entries        = @($manifestEntries)
    }

    if (-not $PSBoundParameters.ContainsKey('OutputPath') -or [string]::IsNullOrWhiteSpace($OutputPath)) {
        return [pscustomobject]$manifest
    }

    $outputDir = Split-Path -Parent $OutputPath
    if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    if ($PSCmdlet.ShouldProcess($OutputPath, 'Write catalog manifest JSON')) {
        $json = $manifest | ConvertTo-Json -Depth 8
        Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8
        Write-BuildLog -Level Information -Component 'Export-CatalogManifest' -Message "Wrote catalog manifest ($($manifestEntries.Count) entries) -> '$OutputPath'."
    }

    return $OutputPath
}
