#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for Resolve-CatalogOrder / Get-CatalogEntryRunAfter — the data-driven RunAfter ordering
    system that guarantees an entry is applied after the entries it depends on (e.g. a first-logon
    RunOnce that repairs what an earlier RunOnce overwrote).
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force
}

Describe 'Resolve-CatalogOrder' {

    It 'preserves authoring order when nothing declares RunAfter' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                @{ Id = 'a' }, @{ Id = 'b' }, @{ Id = 'c' }
            )
            $ordered = @(Resolve-CatalogOrder -Catalog $catalog | ForEach-Object { $_.Id })
            $ordered | Should -Be @('a', 'b', 'c')
        }
    }

    It 'moves an entry after the id it declares in RunAfter' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                @{ Id = 'a'; RunAfter = @('c') }, @{ Id = 'b' }, @{ Id = 'c' }
            )
            $ordered = @(Resolve-CatalogOrder -Catalog $catalog | ForEach-Object { $_.Id })
            $ordered | Should -Be @('b', 'c', 'a')
        }
    }

    It 'is stable: unconstrained entries keep their relative authoring order' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                @{ Id = 'a' }, @{ Id = 'b'; RunAfter = @('e') }, @{ Id = 'c' },
                @{ Id = 'd' }, @{ Id = 'e' }
            )
            $ordered = @(Resolve-CatalogOrder -Catalog $catalog | ForEach-Object { $_.Id })
            $ordered | Should -Be @('a', 'c', 'd', 'e', 'b')
        }
    }

    It 'resolves transitive chains' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                @{ Id = 'a'; RunAfter = @('b') }, @{ Id = 'b'; RunAfter = @('c') }, @{ Id = 'c' }
            )
            $ordered = @(Resolve-CatalogOrder -Catalog $catalog | ForEach-Object { $_.Id })
            $ordered | Should -Be @('c', 'b', 'a')
        }
    }

    It 'supports multiple prerequisites on one entry' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                @{ Id = 'a'; RunAfter = @('b', 'c') }, @{ Id = 'b' }, @{ Id = 'c' }
            )
            $ordered = @(Resolve-CatalogOrder -Catalog $catalog | ForEach-Object { $_.Id })
            $ordered | Should -Be @('b', 'c', 'a')
        }
    }

    It 'ignores a RunAfter id that is not in the supplied set (filtered-out prerequisite)' {
        InModuleScope WindowsIsoMaker {
            # Mirrors a prerequisite dropped by the architecture/profile selection: it cannot be
            # violated, so it must not fail or reorder anything.
            $catalog = @(
                @{ Id = 'a'; RunAfter = @('not-selected') }, @{ Id = 'b' }
            )
            $ordered = @(Resolve-CatalogOrder -Catalog $catalog | ForEach-Object { $_.Id })
            $ordered | Should -Be @('a', 'b')
        }
    }

    It 'works on pscustomobject entries as produced by Import-ChangeCatalog' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                [pscustomobject]@{ Id = 'a'; RunAfter = @('b') }, [pscustomobject]@{ Id = 'b' }
            )
            $ordered = @(Resolve-CatalogOrder -Catalog $catalog | ForEach-Object { $_.Id })
            $ordered | Should -Be @('b', 'a')
        }
    }

    It 'throws on a circular RunAfter dependency' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                @{ Id = 'a'; RunAfter = @('b') }, @{ Id = 'b'; RunAfter = @('a') }
            )
            { Resolve-CatalogOrder -Catalog $catalog } | Should -Throw -ExpectedMessage '*Circular RunAfter dependency*'
        }
    }

    It 'throws when an entry lists itself in RunAfter' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(@{ Id = 'a'; RunAfter = @('a') }, @{ Id = 'b' })
            { Resolve-CatalogOrder -Catalog $catalog } | Should -Throw -ExpectedMessage "*lists itself in RunAfter*"
        }
    }

    It 'throws on duplicate ids' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(@{ Id = 'a' }, @{ Id = 'a' })
            { Resolve-CatalogOrder -Catalog $catalog } | Should -Throw -ExpectedMessage '*Duplicate catalog id*'
        }
    }

    It 'handles empty and single-entry catalogs' {
        InModuleScope WindowsIsoMaker {
            @(Resolve-CatalogOrder -Catalog @()).Count | Should -Be 0
            @(Resolve-CatalogOrder -Catalog @(@{ Id = 'a' }) | ForEach-Object { $_.Id }) | Should -Be @('a')
        }
    }
}

Describe 'Get-CatalogEntryRunAfter' {

    It 'returns an empty array when the entry declares no RunAfter' {
        InModuleScope WindowsIsoMaker {
            @(Get-CatalogEntryRunAfter -Entry @{ Id = 'a' }).Count | Should -Be 0
            @(Get-CatalogEntryRunAfter -Entry ([pscustomobject]@{ Id = 'a' })).Count | Should -Be 0
        }
    }

    It 'returns the declared ids for both entry shapes' {
        InModuleScope WindowsIsoMaker {
            @(Get-CatalogEntryRunAfter -Entry @{ Id = 'a'; RunAfter = @('x', 'y') }) | Should -Be @('x', 'y')
            @(Get-CatalogEntryRunAfter -Entry ([pscustomobject]@{ Id = 'a'; RunAfter = @('x') })) | Should -Be @('x')
        }
    }
}

Describe 'Import-ChangeCatalog RunAfter integration' {

    It 'applies the real catalog ordering so the number-format repair follows the regional format' {
        InModuleScope WindowsIsoMaker {
            $ids = @(Import-ChangeCatalog | ForEach-Object { $_.Id })
            $region = [Array]::IndexOf($ids, 'reg-region-format-nl')
            $repair = [Array]::IndexOf($ids, 'reg-number-format-us-first-logon')

            $region | Should -BeGreaterThan -1
            $repair | Should -BeGreaterThan -1
            # Set-Culture (reg-region-format-nl) wipes sDecimal/sThousand/sList, so the repair
            # RunOnce must be written — and therefore executed — after it.
            $repair | Should -BeGreaterThan $region
        }
    }

    It 'keeps the ordering after the profile/architecture selection filters the catalog' {
        InModuleScope WindowsIsoMaker {
            $selected = Resolve-CatalogSelection -Catalog (Import-ChangeCatalog) -Architecture amd64 -Profile opinionated
            $ids = @($selected | ForEach-Object { $_.Id })
            $ids | Should -Contain 'reg-number-format-us-first-logon'
            [Array]::IndexOf($ids, 'reg-number-format-us-first-logon') |
                Should -BeGreaterThan ([Array]::IndexOf($ids, 'reg-region-format-nl'))
        }
    }

    It 'enforces the real catalog ordering even when the entries are loaded in the wrong order' {
        InModuleScope WindowsIsoMaker {
            # Proves the constraint is carried by RunAfter and not merely by where the entries
            # happen to sit in catalog.registry.psd1: reversing the input must still order them.
            $reversed = @(Import-ChangeCatalog)
            [Array]::Reverse($reversed)
            $ids = @(Resolve-CatalogOrder -Catalog $reversed | ForEach-Object { $_.Id })
            [Array]::IndexOf($ids, 'reg-number-format-us-first-logon') |
                Should -BeGreaterThan ([Array]::IndexOf($ids, 'reg-region-format-nl'))
        }
    }

    It 'reaches the offline applier in the resolved order (end to end)' {
        InModuleScope WindowsIsoMaker {
            # The ordering only matters if it survives all the way to the physical write, so assert
            # on Set-RegistryTweaks' own per-entry results rather than on the catalog array.
            $selected = Resolve-CatalogSelection -Catalog (Import-ChangeCatalog) -Architecture amd64 -Profile opinionated
            $mountDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-order-" + [guid]::NewGuid().ToString('N'))
            New-Item -Path $mountDir -ItemType Directory -Force | Out-Null
            try {
                $applied = @(Set-RegistryTweaks -MountPath $mountDir -Catalog $selected -Architecture amd64 -WhatIf |
                        ForEach-Object { $_.Id })
                $applied | Should -Contain 'reg-number-format-us-first-logon'
                [Array]::IndexOf($applied, 'reg-number-format-us-first-logon') |
                    Should -BeGreaterThan ([Array]::IndexOf($applied, 'reg-region-format-nl'))
            }
            finally {
                Remove-Item -LiteralPath $mountDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'keeps the repair RunOnce value name sorting last, so lexical execution order works too' {
        InModuleScope WindowsIsoMaker {
            # Belt and braces: Windows does not document RunOnce execution order, so the repair must
            # win under BOTH write order (RunAfter) and lexical order (value name).
            $catalog = @(Import-ChangeCatalog)
            $region = @($catalog | Where-Object { $_.Id -eq 'reg-region-format-nl' })[0]
            $repair = @($catalog | Where-Object { $_.Id -eq 'reg-number-format-us-first-logon' })[0]

            $region.Target.Path | Should -Be $repair.Target.Path
            ([string]::Compare($repair.Target.Name, $region.Target.Name, $true)) |
                Should -BeGreaterThan 0 -Because 'the repair value name must sort after the regional-format one'
        }
    }

    It 'rejects a RunAfter id that does not exist in the catalog' {        InModuleScope WindowsIsoMaker {            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-runafter-" + [guid]::NewGuid().ToString('N'))
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            try {
                $content = @'
@{
    Entries = @(
        @{ Id = 'reg-alpha'; Action = 'SetRegistry'; RunAfter = @('reg-does-not-exist') }
    )
}
'@
                Set-Content -LiteralPath (Join-Path $dir 'catalog.test.psd1') -Value $content -Encoding UTF8
                { Import-ChangeCatalog -CatalogDirectory $dir } |
                    Should -Throw -ExpectedMessage '*not a known catalog id*'
            }
            finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
