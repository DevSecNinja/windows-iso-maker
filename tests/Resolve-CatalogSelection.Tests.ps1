#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for Resolve-CatalogSelection / Test-CatalogEntryInProfile, focused on the profile
    baselines (minimal | default | aggressive | gaming). The 'gaming' profile keeps gaming
    components (entries tagged Category='Gaming', e.g. the Xbox provisioned apps).
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force
}

Describe 'Resolve-CatalogSelection profile baselines' {

    It "gaming profile keeps the Xbox components while default removes them" {
        InModuleScope WindowsIsoMaker {
            $catalog = Import-ChangeCatalog
            $xboxIds = @('appx-xbox-gaming-overlay', 'appx-xbox-game-overlay', 'appx-xbox-tcui', 'appx-xbox-speech-to-text')

            $defaultSel = Resolve-CatalogSelection -Catalog $catalog -Architecture amd64 -Profile default
            $gamingSel = Resolve-CatalogSelection -Catalog $catalog -Architecture amd64 -Profile gaming

            $defaultIds = @($defaultSel | ForEach-Object { $_.Id })
            $gamingIds = @($gamingSel | ForEach-Object { $_.Id })

            # default removes every Xbox app; gaming removes none of them.
            foreach ($id in $xboxIds) {
                $defaultIds | Should -Contain $id -Because 'default profile removes Xbox provisioned apps'
                $gamingIds | Should -Not -Contain $id -Because 'gaming profile preserves Xbox provisioned apps'
            }
        }
    }

    It 'gaming profile still applies the non-gaming default debloat (e.g. Clipchamp, Recall)' {
        InModuleScope WindowsIsoMaker {
            $catalog = Import-ChangeCatalog
            $gamingIds = @(Resolve-CatalogSelection -Catalog $catalog -Architecture amd64 -Profile gaming | ForEach-Object { $_.Id })
            $gamingIds | Should -Contain 'appx-clipchamp'
            $gamingIds | Should -Contain 'reg-disable-recall'
        }
    }

    It 'gaming and default differ only by the Category=Gaming entries' {
        InModuleScope WindowsIsoMaker {
            $catalog = Import-ChangeCatalog
            $defaultIds = @(Resolve-CatalogSelection -Catalog $catalog -Architecture amd64 -Profile default | ForEach-Object { $_.Id })
            $gamingIds = @(Resolve-CatalogSelection -Catalog $catalog -Architecture amd64 -Profile gaming | ForEach-Object { $_.Id })

            $removed = @($defaultIds | Where-Object { $gamingIds -notcontains $_ })
            $gamingCategoryIds = @($catalog | Where-Object {
                    ($_.PSObject.Properties.Name -contains 'Category') -and $_.Category -eq 'Gaming'
                } | ForEach-Object { $_.Id })

            ($removed | Sort-Object) | Should -Be ($gamingCategoryIds | Sort-Object)
        }
    }

    It 'DisableCatalogId can still force a gaming entry off under the gaming profile' {
        InModuleScope WindowsIsoMaker {
            $catalog = Import-ChangeCatalog
            # Even in gaming mode a user may explicitly re-enable removal of a specific Xbox app.
            $ids = @(Resolve-CatalogSelection -Catalog $catalog -Architecture amd64 -Profile gaming -EnableCatalogId 'appx-xbox-tcui' | ForEach-Object { $_.Id })
            $ids | Should -Contain 'appx-xbox-tcui'
        }
    }
}

Describe 'Test-CatalogEntryInProfile Category handling' {
    It 'excludes a Category=Gaming entry from the gaming profile (hashtable entry)' {
        InModuleScope WindowsIsoMaker {
            $entry = @{ Id = 'x'; Action = 'RemoveAppx'; EvidenceGrade = 1; DefaultEnabled = $true; Category = 'Gaming' }
            Test-CatalogEntryInProfile -Entry $entry -Profile gaming | Should -BeFalse
            Test-CatalogEntryInProfile -Entry $entry -Profile default | Should -BeTrue
        }
    }

    It 'keeps a non-gaming default entry in the gaming profile (pscustomobject without Category)' {
        InModuleScope WindowsIsoMaker {
            $entry = [pscustomobject]@{ Id = 'y'; Action = 'RemoveAppx'; EvidenceGrade = 1; DefaultEnabled = $true }
            Test-CatalogEntryInProfile -Entry $entry -Profile gaming | Should -BeTrue
        }
    }
}
