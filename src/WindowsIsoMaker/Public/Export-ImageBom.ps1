function Export-ImageBom {
    <#
    .SYNOPSIS
        Derive an Image BOM (CycloneDX JSON + human-readable Markdown) from a RunReport (FR-029).
    .DESCRIPTION
        Reads SOLELY from the supplied RunReport (the single source of truth) so the BOM lists
        100% of the changes actually applied (SC-012). Emits:

            * A CycloneDX 1.5 JSON document enumerating the base image (name/version/hash) and
              every applied change as a component carrying its Citation (externalReference) and
              EvidenceGrade (property), plus the pinned tool versions as BOM tools.
            * A human-readable Markdown BOM with the same information in a review-friendly table.

        The repository/tooling SBOM (also CycloneDX) is produced separately in CI by
        anchore/sbom-action; this function produces the per-IMAGE BOM from the build.
    .PARAMETER RunReport
        The RunReport object produced by New-RunReport.
    .PARAMETER OutputDirectory
        Directory to write the BOM file(s) into.
    .PARAMETER Format
        One or both of 'cyclonedx','markdown' (default: both).
    .EXAMPLE
        Export-ImageBom -RunReport $report -OutputDirectory ./out
    .OUTPUTS
        PSCustomObject describing the written BOM (paths + summary).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $RunReport,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputDirectory,

        [Parameter()]
        [ValidateSet('cyclonedx', 'markdown')]
        [string[]] $Format = @('cyclonedx', 'markdown')
    )

    # Anchor outputs to the absolute path New-Item -Force actually resolved so the returned
    # WrittenFiles are unambiguous regardless of $PWD vs process/module location differences.
    $outputDirInfo = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $OutputDirectory = $outputDirInfo.FullName

    # Build an Id -> catalog-entry lookup from the resolved config (grade/description/citation).
    $catalogById = @{}
    if ($RunReport.ResolvedConfig -and $RunReport.ResolvedConfig.SelectedCatalog) {
        foreach ($entry in @($RunReport.ResolvedConfig.SelectedCatalog)) {
            if ($entry.Id) { $catalogById[[string]$entry.Id] = $entry }
        }
    }

    # The changes that were actually put into the image.
    $appliedStatuses = @('Applied', 'AlreadyApplied')
    $changes = @($RunReport.Applied | Where-Object { $appliedStatuses -contains $_.Status })

    $baseImage = $RunReport.BaseImage
    $baseVersion = if ($baseImage -and $baseImage.Release) { [string]$baseImage.Release } else { 'unknown' }
    $baseHash = if ($baseImage -and $baseImage.Sha256) { [string]$baseImage.Sha256 } else { '' }
    $toolVersions = if ($RunReport.ToolVersions) { $RunReport.ToolVersions } else { @{} }
    $timestamp = (Get-Date).ToUniversalTime().ToString('o')

    $written = [System.Collections.Generic.List[string]]::new()

    # --- CycloneDX JSON ---
    if ($Format -contains 'cyclonedx') {
        $tools = foreach ($k in $toolVersions.Keys) {
            [ordered]@{ vendor = 'WindowsIsoMaker'; name = [string]$k; version = [string]$toolVersions[$k] }
        }

        $components = foreach ($c in $changes) {
            $entry = $catalogById[[string]$c.Id]
            $grade = if ($entry) { [string]$entry.EvidenceGrade } else { 'n/a' }
            $desc = if ($entry -and $entry.Description) { [string]$entry.Description } else { [string]$c.Reason }
            $citation = if ($c.Citation) { [string]$c.Citation } elseif ($entry) { [string]$entry.Citation } else { '' }
            $comp = [ordered]@{
                type        = 'data'
                'bom-ref'   = [string]$c.Id
                name        = [string]$c.Id
                description = $desc
                properties  = @(
                    [ordered]@{ name = 'wim:evidenceGrade'; value = $grade }
                    [ordered]@{ name = 'wim:status'; value = [string]$c.Status }
                )
            }
            if ($citation -and $citation -match '^https?://') {
                $comp['externalReferences'] = @([ordered]@{ type = 'documentation'; url = $citation })
            }
            $comp
        }

        $bom = [ordered]@{
            bomFormat    = 'CycloneDX'
            specVersion  = '1.5'
            version      = 1
            metadata     = [ordered]@{
                timestamp = $timestamp
                tools     = @($tools)
                component = [ordered]@{
                    type    = 'operating-system'
                    name    = "Windows 11 $($RunReport.ResolvedConfig.Edition)"
                    version = $baseVersion
                    hashes  = @(if ($baseHash) { [ordered]@{ alg = 'SHA-256'; content = $baseHash } })
                }
            }
            components   = @($components)
        }

        $jsonPath = Join-Path -Path $OutputDirectory -ChildPath 'image-bom.cdx.json'
        if ($PSCmdlet.ShouldProcess($jsonPath, 'Write CycloneDX Image BOM')) {
            $bom | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
            Write-BuildLog -Level Information -Component 'Export-ImageBom' -Message "CycloneDX Image BOM written to '$jsonPath'."
        }
        $written.Add($jsonPath)
    }

    # --- Markdown ---
    if ($Format -contains 'markdown') {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('# Image Bill of Materials')
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("Generated: $timestamp")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('## Base image')
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("- Edition: $($RunReport.ResolvedConfig.Edition)")
        [void]$sb.AppendLine("- Architecture: $($RunReport.ResolvedConfig.Architecture)")
        [void]$sb.AppendLine("- Release: $baseVersion")
        [void]$sb.AppendLine("- SHA256: $baseHash")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('## Pinned tool versions')
        [void]$sb.AppendLine()
        foreach ($k in ($toolVersions.Keys | Sort-Object)) {
            [void]$sb.AppendLine("- ${k}: $($toolVersions[$k])")
        }
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('## Applied changes')
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('| Id | Status | Grade | Description | Citation |')
        [void]$sb.AppendLine('|----|--------|-------|-------------|----------|')
        foreach ($c in $changes) {
            $entry = $catalogById[[string]$c.Id]
            $grade = if ($entry) { [string]$entry.EvidenceGrade } else { 'n/a' }
            $desc = if ($entry -and $entry.Description) { [string]$entry.Description } else { [string]$c.Reason }
            $citation = if ($c.Citation) { [string]$c.Citation } elseif ($entry) { [string]$entry.Citation } else { '' }
            $descCell = ($desc -replace '\|', '\|')
            [void]$sb.AppendLine("| $($c.Id) | $($c.Status) | $grade | $descCell | $citation |")
        }

        $mdPath = Join-Path -Path $OutputDirectory -ChildPath 'image-bom.md'
        if ($PSCmdlet.ShouldProcess($mdPath, 'Write Markdown Image BOM')) {
            Set-Content -LiteralPath $mdPath -Value $sb.ToString() -Encoding UTF8
            Write-BuildLog -Level Information -Component 'Export-ImageBom' -Message "Markdown Image BOM written to '$mdPath'."
        }
        $written.Add($mdPath)
    }

    return [pscustomobject]@{
        PSTypeName   = 'WindowsIsoMaker.ImageBom'
        Paths        = $written.ToArray()
        ChangeCount  = $changes.Count
        BaseVersion  = $baseVersion
        BaseSha256   = $baseHash
    }
}
