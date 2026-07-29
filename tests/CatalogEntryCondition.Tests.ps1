#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for catalog-entry applicability Conditions (Private/CatalogEntryCondition.ps1) and how the
    two dispatchers honour them.
.DESCRIPTION
    A Condition describes the TARGET machine ("Surface Laptop only"), so the two paths must behave
    differently and deliberately:

      * Invoke-CatalogEntry (offline build) must NEVER evaluate it — the build agent is not the
        target — and must report NotApplicable without touching a handler.
      * Invoke-OnlineCatalogEntry (post-install) runs on the target, so it evaluates the condition
        and only dispatches when it is satisfied.

    Evaluation is fail-closed throughout: throwing, empty, non-parsing and no-output conditions all
    leave the entry unapplied. These run on any platform (no Windows/CIM dependency).
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force
}

Describe 'Get-CatalogEntryCondition' {

    It 'returns $null for an entry that declares no Condition (hashtable and pscustomobject)' {
        InModuleScope WindowsIsoMaker {
            Get-CatalogEntryCondition -Entry @{ Id = 'x' } | Should -BeNullOrEmpty
            Get-CatalogEntryCondition -Entry ([pscustomobject]@{ Id = 'x' }) | Should -BeNullOrEmpty
        }
    }

    It 'returns the Condition block for both entry shapes' {
        InModuleScope WindowsIsoMaker {
            $cond = @{ Script = '$true'; Description = 'always' }

            (Get-CatalogEntryCondition -Entry @{ Id = 'x'; Condition = $cond }).Description |
                Should -Be 'always'
            (Get-CatalogEntryCondition -Entry ([pscustomobject]@{ Id = 'x'; Condition = $cond })).Description |
                Should -Be 'always'
        }
    }

    It 'reads Condition fields StrictMode-safely, returning empty for absent fields' {
        InModuleScope WindowsIsoMaker {
            Set-StrictMode -Version Latest
            $cond = @{ Script = '$true'; Description = 'always' }

            Get-CatalogConditionField -Condition $cond -Name 'Citation' | Should -BeNullOrEmpty
            Get-CatalogConditionField -Condition ([pscustomobject]$cond) -Name 'Citation' | Should -BeNullOrEmpty
            Get-CatalogConditionField -Condition $cond -Name 'Script' | Should -Be '$true'
        }
    }
}

Describe 'Test-CatalogEntryCondition' {

    It 'treats an entry with no Condition as satisfied' {
        InModuleScope WindowsIsoMaker {
            $verdict = Test-CatalogEntryCondition -Entry @{ Id = 'plain' }
            $verdict.HasCondition | Should -BeFalse
            $verdict.Satisfied | Should -BeTrue
        }
    }

    It 'is satisfied when the script evaluates true' {
        InModuleScope WindowsIsoMaker {
            $verdict = Test-CatalogEntryCondition -Entry @{
                Id = 'c'; Condition = @{ Script = '1 -eq 1'; Description = 'always true' }
            }
            $verdict.HasCondition | Should -BeTrue
            $verdict.Satisfied | Should -BeTrue
            $verdict.Description | Should -Be 'always true'
        }
    }

    It 'is not satisfied when the script evaluates false, and says so with the description' {
        InModuleScope WindowsIsoMaker {
            $verdict = Test-CatalogEntryCondition -Entry @{
                Id = 'c'; Condition = @{ Script = '$false'; Description = 'Surface Laptop only' }
            }
            $verdict.Satisfied | Should -BeFalse
            $verdict.Reason | Should -BeLike '*Surface Laptop only*'
        }
    }

    It 'judges a multi-statement condition on its final expression' {
        InModuleScope WindowsIsoMaker {
            $script = @'
$model = 'Surface Laptop 7'
$model -like '*Surface Laptop*'
'@
            $verdict = Test-CatalogEntryCondition -Entry @{
                Id = 'c'; Condition = @{ Script = $script; Description = 'multi-line' }
            }
            $verdict.Satisfied | Should -BeTrue
        }
    }

    It 'fails closed when the condition throws (e.g. CIM unavailable)' {
        InModuleScope WindowsIsoMaker {
            $verdict = Test-CatalogEntryCondition -Entry @{
                Id = 'c'; Condition = @{ Script = 'throw "no CIM here"'; Description = 'Surface only' }
            }
            $verdict.Satisfied | Should -BeFalse -Because 'detection failure must never apply a targeted tweak'
            $verdict.Reason | Should -BeLike '*could not be evaluated*'
        }
    }

    It 'fails closed when the condition emits nothing' {
        InModuleScope WindowsIsoMaker {
            $verdict = Test-CatalogEntryCondition -Entry @{
                Id = 'c'; Condition = @{ Script = '$null = 1'; Description = 'silent' }
            }
            $verdict.Satisfied | Should -BeFalse
        }
    }

    It 'fails closed when the Script is missing or blank' {
        InModuleScope WindowsIsoMaker {
            $verdict = Test-CatalogEntryCondition -Entry @{
                Id = 'c'; Condition = @{ Description = 'no script' }
            }
            $verdict.HasCondition | Should -BeTrue
            $verdict.Satisfied | Should -BeFalse
            $verdict.Reason | Should -BeLike '*no Script*'
        }
    }

    It 'fails closed when the Script is not valid PowerShell' {
        InModuleScope WindowsIsoMaker {
            $verdict = Test-CatalogEntryCondition -Entry @{
                Id = 'c'; Condition = @{ Script = 'if ('; Description = 'broken' }
            }
            $verdict.Satisfied | Should -BeFalse
            $verdict.Reason | Should -BeLike '*not valid PowerShell*'
        }
    }
}

Describe 'Invoke-CatalogEntry (offline) never evaluates a Condition' {

    It 'reports NotApplicable and does not dispatch to a handler' {
        InModuleScope WindowsIsoMaker {
            Mock Set-RegistryTweaks { throw 'the offline build must not apply a conditional entry' }

            $entry = [pscustomobject]@{
                Id = 'reg-conditional'; Type = 'Registry'; Action = 'SetRegistry'; Citation = 'https://example.invalid'
                Arch = @('amd64', 'arm64')
                Condition = @{ Script = '$true'; Description = 'Surface Laptop only' }
                Target = @{ Hive = 'SOFTWARE'; Path = 'Policies\Foo'; Name = 'Bar'; Kind = 'DWord'; Value = 0 }
            }

            $result = Invoke-CatalogEntry -Entry $entry -MountPath 'TestDrive:\mount' -Architecture amd64

            $result.Status | Should -Be 'NotApplicable'
            $result.Id | Should -Be 'reg-conditional'
            $result.Reason | Should -BeLike '*Surface Laptop only*'
            $result.Reason | Should -BeLike '*post-install.ps1*' -Because 'the reason must point at the path that CAN evaluate it'
            Should -Invoke Set-RegistryTweaks -Times 0
        }
    }

    It 'still dispatches entries that declare no Condition' {
        InModuleScope WindowsIsoMaker {
            Mock Set-RegistryTweaks {
                [pscustomobject]@{ PSTypeName = 'WindowsIsoMaker.ChangeResult'; Id = 'reg-plain'
                    Type = 'Registry'; Status = 'Applied'; Reason = 'ok'; Citation = 'x' }
            }

            $entry = [pscustomobject]@{
                Id = 'reg-plain'; Type = 'Registry'; Action = 'SetRegistry'; Citation = 'x'; Arch = @('amd64')
                Target = @{ Hive = 'SOFTWARE'; Path = 'Policies\Foo'; Name = 'Bar'; Kind = 'DWord'; Value = 0 }
            }

            (Invoke-CatalogEntry -Entry $entry -MountPath 'TestDrive:\mount' -Architecture amd64).Status |
                Should -Be 'Applied'
            Should -Invoke Set-RegistryTweaks -Times 1
        }
    }
}

Describe 'Invoke-OnlineCatalogEntry (post-install) honours a Condition' {

    It 'applies the entry when the condition is satisfied on this machine' {
        InModuleScope WindowsIsoMaker {
            Mock Set-OnlineRegistryTweaks {
                [pscustomobject]@{ PSTypeName = 'WindowsIsoMaker.ChangeResult'; Id = 'reg-conditional'
                    Type = 'Registry'; Status = 'Applied'; Reason = 'ok'; Citation = 'x' }
            }

            $entry = [pscustomobject]@{
                Id = 'reg-conditional'; Type = 'Registry'; Action = 'SetRegistry'; Citation = 'x'; Arch = @('amd64')
                Condition = @{ Script = '$true'; Description = 'Surface Laptop only' }
                Target = @{ Hive = 'SOFTWARE'; Path = 'Policies\Foo'; Name = 'Bar'; Kind = 'DWord'; Value = 0 }
            }

            (Invoke-OnlineCatalogEntry -Entry $entry -Architecture amd64).Status | Should -Be 'Applied'
            Should -Invoke Set-OnlineRegistryTweaks -Times 1
        }
    }

    It 'skips the entry as NotApplicable when the condition is not satisfied' {
        InModuleScope WindowsIsoMaker {
            Mock Set-OnlineRegistryTweaks { throw 'must not apply an entry whose condition is unmet' }

            $entry = [pscustomobject]@{
                Id = 'reg-conditional'; Type = 'Registry'; Action = 'SetRegistry'; Citation = 'x'; Arch = @('amd64')
                Condition = @{ Script = '$false'; Description = 'Surface Laptop only' }
                Target = @{ Hive = 'SOFTWARE'; Path = 'Policies\Foo'; Name = 'Bar'; Kind = 'DWord'; Value = 0 }
            }

            $result = Invoke-OnlineCatalogEntry -Entry $entry -Architecture amd64
            $result.Status | Should -Be 'NotApplicable'
            $result.Reason | Should -BeLike '*Surface Laptop only*'
            Should -Invoke Set-OnlineRegistryTweaks -Times 0
        }
    }

    It 'skips the entry when the condition cannot be evaluated (fail-closed)' {
        InModuleScope WindowsIsoMaker {
            Mock Set-OnlineRegistryTweaks { throw 'must not apply an entry whose condition failed to evaluate' }

            $entry = [pscustomobject]@{
                Id = 'reg-conditional'; Type = 'Registry'; Action = 'SetRegistry'; Citation = 'x'; Arch = @('amd64')
                Condition = @{ Script = 'Get-DefinitelyNotACommand -ErrorAction Stop'; Description = 'Surface Laptop only' }
                Target = @{ Hive = 'SOFTWARE'; Path = 'Policies\Foo'; Name = 'Bar'; Kind = 'DWord'; Value = 0 }
            }

            (Invoke-OnlineCatalogEntry -Entry $entry -Architecture amd64).Status | Should -Be 'NotApplicable'
            Should -Invoke Set-OnlineRegistryTweaks -Times 0
        }
    }
}

Describe 'Surface Laptop power-button entries in the shipped catalog' {

    BeforeAll {
        $script:PowerIds = @('reg-power-button-no-action-ac', 'reg-power-button-no-action-dc')
    }

    It 'declares a Surface Laptop Condition on both the AC and DC entries' {
        InModuleScope WindowsIsoMaker -Parameters @{ PowerIds = $script:PowerIds } {
            param($PowerIds)
            $catalog = Import-ChangeCatalog
            foreach ($id in $PowerIds) {
                $entry = $catalog | Where-Object { $_.Id -eq $id }
                $entry | Should -Not -BeNullOrEmpty -Because "catalog must contain '$id'"

                $condition = Get-CatalogEntryCondition -Entry $entry
                $condition | Should -Not -BeNullOrEmpty -Because 'the tweak is Surface-specific'
                $condition.Description | Should -BeLike '*Surface Laptop*'
                $condition.Script | Should -BeLike '*Surface_Laptop*'
                $condition.Citation | Should -Be 'https://learn.microsoft.com/en-us/surface/surface-system-sku-reference'
            }
        }
    }

    It 'matches Surface Laptop SKUs and models but not other hardware' {
        InModuleScope WindowsIsoMaker -Parameters @{ PowerIds = $script:PowerIds } {
            param($PowerIds)
            $catalog = Import-ChangeCatalog
            $entry = $catalog | Where-Object { $_.Id -eq $PowerIds[0] }
            $script = (Get-CatalogEntryCondition -Entry $entry).Script

            # Exercise the real condition logic against documented SMBIOS values (Surface System SKU
            # reference) by substituting a stub for the CIM query, so it runs on any platform.
            $harness = $script -replace
                'Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop', '$stub'

            $surface = @(
                @{ SystemSKUNumber = 'Surface_Laptop'; Model = 'Surface Laptop' }
                @{ SystemSKUNumber = 'Surface_Laptop_3_1867:1868'; Model = 'Surface Laptop 3' }
                @{ SystemSKUNumber = 'Surface_Laptop_6_for_Business_2033'; Model = 'Surface Laptop 6 for Business' }
                @{ SystemSKUNumber = 'Surface_Laptop_7th_Edition_2036'; Model = 'Microsoft Surface Laptop, 7th Edition' }
                @{ SystemSKUNumber = ''; Model = 'Surface Laptop 5' }
            )
            foreach ($case in $surface) {
                $stub = [pscustomobject]$case
                $result = & ([scriptblock]::Create("`$stub = `$args[0]; $harness")) $stub
                [bool]$result | Should -BeTrue -Because "SKU '$($case.SystemSKUNumber)' / model '$($case.Model)' is a Surface Laptop"
            }

            $others = @(
                @{ SystemSKUNumber = 'Surface_Pro_9_1996'; Model = 'Surface Pro 9' }
                @{ SystemSKUNumber = 'Surface_Book_3_1900'; Model = 'Surface Book 3' }
                @{ SystemSKUNumber = '0A3C'; Model = 'XPS 15 9520' }
                @{ SystemSKUNumber = ''; Model = 'Virtual Machine' }
            )
            foreach ($case in $others) {
                $stub = [pscustomobject]$case
                $result = & ([scriptblock]::Create("`$stub = `$args[0]; $harness")) $stub
                [bool]$result | Should -BeFalse -Because "SKU '$($case.SystemSKUNumber)' / model '$($case.Model)' is not a Surface Laptop"
            }
        }
    }

    It 'is selected only by the opinionated profile' {
        InModuleScope WindowsIsoMaker -Parameters @{ PowerIds = $script:PowerIds } {
            param($PowerIds)
            $catalog = Import-ChangeCatalog

            foreach ($profileName in @('minimal', 'default', 'aggressive', 'gaming')) {
                $ids = @((Resolve-CatalogSelection -Catalog $catalog -Architecture amd64 -Profile $profileName).Id)
                foreach ($id in $PowerIds) {
                    $ids | Should -Not -Contain $id -Because "'$id' is a personal preference, not part of '$profileName'"
                }
            }

            $opinionated = @((Resolve-CatalogSelection -Catalog $catalog -Architecture amd64 -Profile opinionated).Id)
            foreach ($id in $PowerIds) {
                $opinionated | Should -Contain $id
            }
        }
    }
}
