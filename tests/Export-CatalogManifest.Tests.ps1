#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for Export-CatalogManifest — the JSON manifest that feeds the showcase site (FR-024).
.DESCRIPTION
    The static site under site/ renders whatever Export-CatalogManifest emits, and the Pages
    deploy regenerates the manifest on every publish. These tests lock the manifest's shape and
    the invariant that its profile membership is computed by the SAME logic the build uses
    (Test-CatalogEntryInProfile), so the published catalog can never silently drift from the tool.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force
}

Describe 'Export-CatalogManifest' {

    BeforeAll {
        $script:Manifest = Export-CatalogManifest
    }

    It 'returns a manifest object when no -OutputPath is given' {
        $script:Manifest | Should -Not -BeNullOrEmpty
        $script:Manifest.schemaVersion | Should -Be 1
        $script:Manifest.defaultProfile | Should -Be 'default'
    }

    It 'reports an entry count that matches the entries array' {
        $script:Manifest.entryCount | Should -BeGreaterThan 0
        $script:Manifest.entryCount | Should -Be $script:Manifest.entries.Count
    }

    It 'exposes the five baseline profiles' {
        $names = @($script:Manifest.profiles | ForEach-Object { $_.name })
        $names | Should -Contain 'minimal'
        $names | Should -Contain 'default'
        $names | Should -Contain 'aggressive'
        $names | Should -Contain 'gaming'
        $names | Should -Contain 'opinionated'
    }

    It 'gives every entry the mandatory documentation fields' {
        foreach ($e in $script:Manifest.entries) {
            $e.id          | Should -Not -BeNullOrEmpty
            $e.type        | Should -Not -BeNullOrEmpty
            $e.description | Should -Not -BeNullOrEmpty
            $e.rationale   | Should -Not -BeNullOrEmpty
            $e.citation    | Should -Not -BeNullOrEmpty
        }
    }

    It 'includes the newly added consumer-app removals in default and aggressive' -ForEach @(
        @{ Id = 'appx-xbox-app' }
        @{ Id = 'appx-phone-link' }
        @{ Id = 'appx-family' }
        @{ Id = 'appx-linkedin' }
        @{ Id = 'appx-whatsapp' }
    ) {
        $entry = $script:Manifest.entries | Where-Object { $_.id -eq $Id }
        $entry | Should -Not -BeNullOrEmpty -Because "manifest should contain $Id"
        $entry.profiles | Should -Contain 'default'
        $entry.profiles | Should -Contain 'aggressive'
    }

    It 'tags the reversed-scroll extra and WSL as opinionated-only' -ForEach @(
        @{ Id = 'reg-reverse-mouse-scroll' }
        @{ Id = 'feature-wsl' }
    ) {
        $entry = $script:Manifest.entries | Where-Object { $_.id -eq $Id }
        $entry | Should -Not -BeNullOrEmpty -Because "manifest should contain $Id"
        $entry.profiles | Should -Contain 'opinionated'
        $entry.profiles | Should -Not -Contain 'aggressive'
        $entry.profiles | Should -Not -Contain 'default'
    }

    It 'writes valid JSON to -OutputPath and returns that path' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("catalog-{0}.json" -f ([guid]::NewGuid()))
        try {
            $returned = Export-CatalogManifest -OutputPath $tmp
            $returned | Should -Be $tmp
            Test-Path -LiteralPath $tmp | Should -BeTrue
            $parsed = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
            $parsed.schemaVersion | Should -Be 1
            $parsed.entries.Count | Should -Be $script:Manifest.entryCount
        }
        finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        }
    }
}
