#Requires -Version 5.1
<#
.SYNOPSIS
    Schema/gate tests for the documentation-backed change catalog (Constitution Principle II).
.DESCRIPTION
    Enforces that EVERY catalog entry across config/catalog.*.psd1 carries the mandatory
    What (Description), Why (Rationale), and Citation, plus the structural rules mirrored from
    contracts/change-catalog.schema.json. A missing Description/Rationale/Citation MUST fail
    the suite — this is the merge-blocking gate that keeps undocumented tweaks out (FR-009,
    SC-004). Runs on every push/PR via ci.yml.
#>

BeforeDiscovery {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $configDir = Join-Path -Path $script:RepoRoot -ChildPath 'config'

    $script:CatalogFiles = Get-ChildItem -Path $configDir -Filter 'catalog.*.psd1' -File -ErrorAction SilentlyContinue

    # Flatten every entry across every catalog file into a test-case list for -ForEach.
    # Each catalog file returns a hashtable with an 'Entries' array of ChangeCatalogEntry.
    $script:AllEntries = @()
    foreach ($file in $script:CatalogFiles) {
        $data = Import-PowerShellDataFile -LiteralPath $file.FullName
        $entries = if ($data -is [hashtable] -and $data.ContainsKey('Entries')) { $data.Entries } else { $data }
        foreach ($entry in @($entries)) {
            $script:AllEntries += @{
                File  = $file.Name
                Id    = if ($entry.ContainsKey('Id')) { $entry.Id } else { '<missing-id>' }
                Entry = $entry
            }
        }
    }
}

Describe 'Change catalog: documentation-backed changes (Principle II)' {

    BeforeAll {
        # Re-load the catalog at run-time (BeforeDiscovery variables are not in scope here).
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $configDir = Join-Path -Path $repoRoot -ChildPath 'config'
        $script:RuntimeEntries = @()
        foreach ($file in (Get-ChildItem -Path $configDir -Filter 'catalog.*.psd1' -File)) {
            $data = Import-PowerShellDataFile -LiteralPath $file.FullName
            $entries = if ($data -is [hashtable] -and $data.ContainsKey('Entries')) { $data.Entries } else { $data }
            foreach ($entry in @($entries)) {
                $script:RuntimeEntries += [pscustomobject]@{ File = $file.Name; Id = $entry.Id; Entry = $entry }
            }
        }
    }

    Context 'Catalog files exist and load' {
        It 'has at least one catalog file under config/' {
            $files = Get-ChildItem -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'config') -Filter 'catalog.*.psd1' -File
            $files.Count | Should -BeGreaterThan 0
        }
    }

    Context 'Every entry <Id> in <File>' -ForEach $script:AllEntries {

        It 'has a non-empty Description (WHAT)' {
            $Entry.Description | Should -Not -BeNullOrEmpty -Because 'Principle II requires WHAT for every change'
        }

        It 'has a non-empty Rationale (WHY)' {
            $Entry.Rationale | Should -Not -BeNullOrEmpty -Because 'Principle II requires WHY for every change'
        }

        It 'has a Citation (authoritative URL or the literal Unverified)' {
            $Entry.Citation | Should -Not -BeNullOrEmpty -Because 'Principle II requires a citation for every change'
            ($Entry.Citation -match '^https?://' -or $Entry.Citation -eq 'Unverified') |
                Should -BeTrue -Because "Citation must be an http(s) URL or 'Unverified', got '$($Entry.Citation)'"
        }

        It 'has a valid Type (optional, derived category)' {
            if ($Entry.ContainsKey('Type') -and $null -ne $Entry.Type) {
                $Entry.Type | Should -BeIn @('Appx', 'Capability', 'Registry', 'OptionalFeature')
            }
        }

        It 'has a Category from the semantic taxonomy' {
            $allowedCategories = @(
                'Browser', 'Bundled apps', 'Cloud storage', 'Development',
                'Gaming', 'Legacy components', 'Personalization', 'Privacy & telemetry',
                'System & recovery'
            )
            $Entry.Category | Should -Not -BeNullOrEmpty -Because 'every entry must declare a semantic Category for grouping/display'
            $Entry.Category | Should -BeIn $allowedCategories -Because "Category must be one of the agreed taxonomy values, got '$($Entry.Category)'"
        }

        It 'has valid Profiles membership tags when present (subset of gaming/opinionated)' {
            if ($Entry.ContainsKey('Profiles') -and $null -ne $Entry.Profiles) {
                @($Entry.Profiles).Count | Should -BeGreaterThan 0 -Because 'a present Profiles tag must be a non-empty list'
                foreach ($tag in @($Entry.Profiles)) {
                    $tag | Should -BeIn @('gaming', 'opinionated') -Because "Profiles is the curated profile-membership tag, got '$tag'"
                }
            }
        }

        It 'has a valid Action (dispatch key)' {
            $Entry.Action | Should -BeIn @('RemoveAppx', 'RemoveCapability', 'SetRegistry', 'EnableOptionalFeature', 'AddCapability', 'DisableOptionalFeature') -Because 'Action is the Invoke-CatalogEntry dispatch key (schema v2 / FR-024)'
        }

        It 'has an EvidenceGrade of 1, 2, or 3' {
            $Entry.EvidenceGrade | Should -BeIn @(1, 2, 3) -Because 'Principle II v1.1.0 requires an evidence grade for every change (FR-026)'
        }

        It 'is opt-in (DefaultEnabled=false) when EvidenceGrade is 3 (community/forum)' {
            if ($Entry.EvidenceGrade -eq 3) {
                $Entry.DefaultEnabled | Should -BeFalse -Because 'grade-3 (community/forum) changes must not be enabled by default (FR-026)'
            }
        }

        It 'has a non-empty Target' {
            $Entry.Target | Should -Not -BeNullOrEmpty
        }

        It 'declares Reversible and DefaultEnabled booleans' {
            $Entry.Reversible | Should -BeOfType [bool]
            $Entry.DefaultEnabled | Should -BeOfType [bool]
        }

        It 'has an Arch that is a non-empty subset of {amd64,arm64}' {
            @($Entry.Arch).Count | Should -BeGreaterThan 0
            foreach ($a in $Entry.Arch) { $a | Should -BeIn @('amd64', 'arm64') }
        }

        It 'is opt-in (DefaultEnabled=false) when Unverified or Citation=Unverified' {
            $isUnverified = ($Entry.Citation -eq 'Unverified') -or
                ($Entry.ContainsKey('Unverified') -and $Entry.Unverified)
            if ($isUnverified) {
                $Entry.DefaultEnabled | Should -BeFalse -Because 'unverified entries must be opt-in only (Principle II)'
            }
        }

        It 'has a well-formed registry Target when Action=SetRegistry' {
            if ($Entry.Action -eq 'SetRegistry') {
                $Entry.Target | Should -BeOfType [hashtable]
                $Entry.Target.Hive | Should -BeIn @('SOFTWARE', 'SYSTEM', 'DEFAULT')
                $Entry.Target.Path | Should -Not -BeNullOrEmpty
                $Entry.Target.Name | Should -Not -BeNullOrEmpty
                $Entry.Target.Kind | Should -BeIn @('DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary')
            }
        }
    }

    Context 'Cross-file invariants' {
        It 'has globally unique Ids' {
            $ids = $script:RuntimeEntries | ForEach-Object { $_.Id }
            $duplicates = $ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }
            $duplicates | Should -BeNullOrEmpty -Because "duplicate catalog Ids found: $($duplicates -join ', ')"
        }

        It 'includes the mandated default-ON Recall disable entry' {
            $recall = $script:RuntimeEntries | Where-Object { $_.Id -eq 'reg-disable-recall' }
            $recall | Should -Not -BeNullOrEmpty
            $recall.Entry.DefaultEnabled | Should -BeTrue -Because 'FR-007 mandates Recall disabled by default'
        }

        It 'includes the mandated default-ON Widgets disable entry' {
            $widgets = $script:RuntimeEntries | Where-Object { $_.Id -eq 'reg-disable-widgets' }
            $widgets | Should -Not -BeNullOrEmpty
            $widgets.Entry.DefaultEnabled | Should -BeTrue -Because 'FR-007 mandates Widgets disabled by default'
        }

        It 'keeps Edge and OneDrive removal opt-in (DefaultEnabled=false)' {
            $optIn = $script:RuntimeEntries | Where-Object { $_.Id -in @('remove-edge', 'remove-onedrive') }
            $optIn | Should -Not -BeNullOrEmpty
            foreach ($e in $optIn) {
                $e.Entry.DefaultEnabled | Should -BeFalse -Because 'FR-008 keeps Edge/OneDrive removal opt-in'
            }
        }
    }

    Context 'Merge-blocking gate proves undocumented entries fail (FR-009, SC-004)' {
        # Reusable predicate mirroring the mandatory-field gate used above, so we can prove
        # the gate REJECTS a non-compliant entry (negative path). If this ever passes a bad
        # entry, the CI gate would be silently broken.
        BeforeAll {
            $script:TestEntry = {
                param($Entry)
                $okDescription = -not [string]::IsNullOrWhiteSpace($Entry.Description)
                $okRationale = -not [string]::IsNullOrWhiteSpace($Entry.Rationale)
                $okCitation = (-not [string]::IsNullOrWhiteSpace($Entry.Citation)) -and
                    (($Entry.Citation -match '^https?://') -or ($Entry.Citation -eq 'Unverified'))
                return ($okDescription -and $okRationale -and $okCitation)
            }
        }

        It 'accepts a fully documented entry' {
            $good = @{ Description = 'x'; Rationale = 'y'; Citation = 'https://learn.microsoft.com/' }
            (& $script:TestEntry $good) | Should -BeTrue
        }

        It 'rejects an entry missing a Citation' {
            $bad = @{ Description = 'x'; Rationale = 'y'; Citation = '' }
            (& $script:TestEntry $bad) | Should -BeFalse
        }

        It 'rejects an entry missing a Description (WHAT)' {
            $bad = @{ Description = ''; Rationale = 'y'; Citation = 'https://learn.microsoft.com/' }
            (& $script:TestEntry $bad) | Should -BeFalse
        }

        It 'rejects an entry missing a Rationale (WHY)' {
            $bad = @{ Description = 'x'; Rationale = ''; Citation = 'https://learn.microsoft.com/' }
            (& $script:TestEntry $bad) | Should -BeFalse
        }

        It 'rejects a non-URL, non-Unverified Citation' {
            $bad = @{ Description = 'x'; Rationale = 'y'; Citation = 'see the wiki' }
            (& $script:TestEntry $bad) | Should -BeFalse
        }

        It 'rejects a grade-3 (community/forum) entry that is DefaultEnabled (FR-026)' {
            # Evidence-grade gate: a grade-3 citation must be opt-in. This proves the gate
            # would REJECT a default-on grade-3 entry rather than silently allow it.
            $gradeGate = {
                param($Entry)
                if ($Entry.EvidenceGrade -eq 3) { return (-not $Entry.DefaultEnabled) }
                return $true
            }
            (& $gradeGate @{ EvidenceGrade = 3; DefaultEnabled = $true }) | Should -BeFalse
            (& $gradeGate @{ EvidenceGrade = 3; DefaultEnabled = $false }) | Should -BeTrue
            (& $gradeGate @{ EvidenceGrade = 1; DefaultEnabled = $true }) | Should -BeTrue
        }
    }
}
