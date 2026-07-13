#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for Resolve-CatalogSelection / Test-CatalogEntryInProfile, focused on the profile
    baselines (minimal | default | aggressive | gaming | opinionated). The 'gaming' profile keeps
    gaming components (Category='Gaming'); 'opinionated' adds the maintainer's personal-taste extras
    (Category='Opinionated', e.g. reversed mouse scroll + WSL) on top of the aggressive baseline.
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

Describe 'Opinionated profile baseline' {
    It 'includes every Category=Opinionated extra that lower profiles leave off' {
        InModuleScope WindowsIsoMaker {
            $catalog = Import-ChangeCatalog
            $opinionatedIds = @(Resolve-CatalogSelection -Catalog $catalog -Architecture amd64 -Profile opinionated | ForEach-Object { $_.Id })
            $aggressiveIds = @(Resolve-CatalogSelection -Catalog $catalog -Architecture amd64 -Profile aggressive | ForEach-Object { $_.Id })

            foreach ($id in @('reg-reverse-mouse-scroll', 'reg-disable-start-web-search', 'reg-disable-lockscreen-spotlight', 'feature-wsl', 'feature-vmplatform')) {
                $opinionatedIds | Should -Contain $id -Because 'the opinionated profile enables the personal-taste extras'
                $aggressiveIds | Should -Not -Contain $id -Because 'those extras are only in the opinionated profile'
            }
        }
    }

    It 'is a strict superset of the aggressive baseline' {
        InModuleScope WindowsIsoMaker {
            $catalog = Import-ChangeCatalog
            $opinionatedIds = @(Resolve-CatalogSelection -Catalog $catalog -Architecture amd64 -Profile opinionated | ForEach-Object { $_.Id })
            $aggressiveIds = @(Resolve-CatalogSelection -Catalog $catalog -Architecture amd64 -Profile aggressive | ForEach-Object { $_.Id })

            foreach ($id in $aggressiveIds) {
                $opinionatedIds | Should -Contain $id -Because 'opinionated builds on top of aggressive'
            }
            $opinionatedIds.Count | Should -BeGreaterThan $aggressiveIds.Count
        }
    }
}

Describe 'Combining profiles (union with gaming veto)' {
    It 'gaming,opinionated keeps the Xbox/gaming stack but adds the opinionated extras' {
        InModuleScope WindowsIsoMaker {
            $catalog = Import-ChangeCatalog
            $comboIds = @(Resolve-CatalogSelection -Catalog $catalog -Architecture amd64 -Profile gaming, opinionated | ForEach-Object { $_.Id })

            # Gaming veto: every Category=Gaming entry is preserved (not removed).
            $gamingCategoryIds = @($catalog | Where-Object {
                    ($_.PSObject.Properties.Name -contains 'Category') -and $_.Category -eq 'Gaming'
                } | ForEach-Object { $_.Id })
            foreach ($id in $gamingCategoryIds) {
                $comboIds | Should -Not -Contain $id -Because 'gaming in the combination preserves the gaming stack'
            }

            # Opinionated extras are included.
            foreach ($id in @('reg-reverse-mouse-scroll', 'feature-wsl', 'feature-vmplatform', 'reg-disable-start-web-search')) {
                $comboIds | Should -Contain $id -Because 'opinionated in the combination adds its personal-taste extras'
            }

            # Aggressive/default non-gaming debloat still applies.
            $comboIds | Should -Contain 'appx-clipchamp'
            $comboIds | Should -Contain 'reg-disable-recall'
        }
    }

    It 'gaming,opinionated equals opinionated minus the Category=Gaming entries' {
        InModuleScope WindowsIsoMaker {
            $catalog = Import-ChangeCatalog
            $comboIds = @(Resolve-CatalogSelection -Catalog $catalog -Architecture amd64 -Profile gaming, opinionated | ForEach-Object { $_.Id })
            $opinionatedIds = @(Resolve-CatalogSelection -Catalog $catalog -Architecture amd64 -Profile opinionated | ForEach-Object { $_.Id })

            $gamingCategoryIds = @($catalog | Where-Object {
                    ($_.PSObject.Properties.Name -contains 'Category') -and $_.Category -eq 'Gaming'
                } | ForEach-Object { $_.Id })

            $expected = @($opinionatedIds | Where-Object { $gamingCategoryIds -notcontains $_ })
            ($comboIds | Sort-Object) | Should -Be ($expected | Sort-Object)
        }
    }

    It 'EnableCatalogId still overrides the gaming veto in a combination' {
        InModuleScope WindowsIsoMaker {
            $catalog = Import-ChangeCatalog
            $ids = @(Resolve-CatalogSelection -Catalog $catalog -Architecture amd64 -Profile gaming, opinionated -EnableCatalogId 'appx-xbox-app' | ForEach-Object { $_.Id })
            $ids | Should -Contain 'appx-xbox-app' -Because 'an explicit EnableCatalogId beats the gaming veto'
        }
    }

    It 'a single-value array behaves like the scalar profile' {
        InModuleScope WindowsIsoMaker {
            $catalog = Import-ChangeCatalog
            $arrayIds = @(Resolve-CatalogSelection -Catalog $catalog -Architecture amd64 -Profile @('default') | ForEach-Object { $_.Id })
            $scalarIds = @(Resolve-CatalogSelection -Catalog $catalog -Architecture amd64 -Profile default | ForEach-Object { $_.Id })
            ($arrayIds | Sort-Object) | Should -Be ($scalarIds | Sort-Object)
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

    It 'enables a Category=Opinionated opt-in only in the opinionated profile' {
        InModuleScope WindowsIsoMaker {
            $entry = @{ Id = 'z'; Action = 'SetRegistry'; EvidenceGrade = 3; DefaultEnabled = $false; Category = 'Opinionated' }
            Test-CatalogEntryInProfile -Entry $entry -Profile opinionated | Should -BeTrue
            Test-CatalogEntryInProfile -Entry $entry -Profile aggressive | Should -BeFalse
            Test-CatalogEntryInProfile -Entry $entry -Profile default | Should -BeFalse
        }
    }
}
