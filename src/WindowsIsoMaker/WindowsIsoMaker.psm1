#Requires -Version 5.1

<#
.SYNOPSIS
    Module loader for WindowsIsoMaker.
.DESCRIPTION
    Dot-sources every Private helper first, then every Public function, and exports
    only the public functions declared in the manifest. Enforces strict mode for the
    whole module surface (Constitution Principle I).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleRoot = $PSScriptRoot

# Dot-source Private helpers first (they are dependencies of the Public functions),
# then the Public functions. Sorted for deterministic load order (Principle V).
$privatePath = Join-Path -Path $PSScriptRoot -ChildPath 'Private'
$publicPath = Join-Path -Path $PSScriptRoot -ChildPath 'Public'

$privateScripts = @()
if (Test-Path -LiteralPath $privatePath) {
    $privateScripts = Get-ChildItem -LiteralPath $privatePath -Filter '*.ps1' -File |
        Sort-Object -Property Name
}

$publicScripts = @()
if (Test-Path -LiteralPath $publicPath) {
    $publicScripts = Get-ChildItem -LiteralPath $publicPath -Filter '*.ps1' -File |
        Sort-Object -Property Name
}

foreach ($script in @($privateScripts) + @($publicScripts)) {
    try {
        . $script.FullName
    }
    catch {
        throw "Failed to import '$($script.FullName)': $($_.Exception.Message)"
    }
}

# Export only the public functions (never the Private helpers) — Principle I.
$functionsToExport = $publicScripts | ForEach-Object { $_.BaseName }
if ($functionsToExport) {
    Export-ModuleMember -Function $functionsToExport
}
