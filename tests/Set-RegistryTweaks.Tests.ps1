#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for Set-RegistryTweaks — hive load/unload and value writes are mocked.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force

    $script:RegCatalog = @(
        [pscustomobject]@{
            Id = 'reg-disable-recall'; Type = 'Registry'; Action = 'SetRegistry'; Citation = 'https://learn.microsoft.com/'; Arch = @('amd64', 'arm64')
            Target = @{ Hive = 'SOFTWARE'; Path = 'Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis'; Kind = 'DWord'; Value = 1 }
        }
        [pscustomobject]@{
            Id = 'reg-disable-widgets'; Type = 'Registry'; Action = 'SetRegistry'; Citation = 'https://learn.microsoft.com/'; Arch = @('amd64', 'arm64')
            Target = @{ Hive = 'SOFTWARE'; Path = 'Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests'; Kind = 'DWord'; Value = 0 }
        }
    )
}

Describe 'Set-RegistryTweaks' {

    BeforeEach {
        $script:MountDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-mount-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:MountDir -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:MountDir) { Remove-Item $script:MountDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'applies Recall and Widgets tweaks and unloads the hive' {
        InModuleScope WindowsIsoMaker -Parameters @{ Catalog = $script:RegCatalog; MountDir = $script:MountDir } {
            param($Catalog, $MountDir)
            Mock Mount-OfflineRegistryHive { [pscustomobject]@{ Hive = 'SOFTWARE'; MountKey = 'HKLM\WIM_Test_SOFTWARE' } }
            Mock Dismount-OfflineRegistryHive { }
            Mock Get-OfflineRegistryValue { $null }
            Mock Set-OfflineRegistryValue { }

            $results = Set-RegistryTweaks -MountPath $MountDir -Catalog $Catalog -Architecture amd64
            ($results | Where-Object { $_.Id -eq 'reg-disable-recall' }).Status | Should -Be 'Applied'
            ($results | Where-Object { $_.Id -eq 'reg-disable-widgets' }).Status | Should -Be 'Applied'
            Should -Invoke Set-OfflineRegistryValue -Times 2
            Should -Invoke Dismount-OfflineRegistryHive -Times 1
        }
    }

    It 'marks AlreadyApplied when the value already matches (idempotent)' {
        InModuleScope WindowsIsoMaker -Parameters @{ Catalog = $script:RegCatalog; MountDir = $script:MountDir } {
            param($Catalog, $MountDir)
            Mock Mount-OfflineRegistryHive { [pscustomobject]@{ Hive = 'SOFTWARE'; MountKey = 'HKLM\WIM_Test_SOFTWARE' } }
            Mock Dismount-OfflineRegistryHive { }
            Mock Get-OfflineRegistryValue { param($MountKey, $Path, $Name) if ($Name -eq 'DisableAIDataAnalysis') { 1 } else { 0 } }
            Mock Set-OfflineRegistryValue { }

            $results = Set-RegistryTweaks -MountPath $MountDir -Catalog $Catalog -Architecture amd64
            ($results | Where-Object { $_.Id -eq 'reg-disable-recall' }).Status | Should -Be 'AlreadyApplied'
            Should -Invoke Set-OfflineRegistryValue -Times 0
        }
    }

    It 'reports intended keys under -WhatIf without writing' {
        InModuleScope WindowsIsoMaker -Parameters @{ Catalog = $script:RegCatalog; MountDir = $script:MountDir } {
            param($Catalog, $MountDir)
            Mock Mount-OfflineRegistryHive { throw 'should not load hive in preview' }
            Mock Dismount-OfflineRegistryHive { }
            Mock Set-OfflineRegistryValue { }

            $results = Set-RegistryTweaks -MountPath $MountDir -Catalog $Catalog -Architecture amd64 -WhatIf
            ($results | Where-Object { $_.Id -eq 'reg-disable-recall' }).Status | Should -Be 'Skipped'
            Should -Invoke Set-OfflineRegistryValue -Times 0
        }
    }

    It 'always unloads the hive even when applying a value throws' {
        InModuleScope WindowsIsoMaker -Parameters @{ Catalog = $script:RegCatalog; MountDir = $script:MountDir } {
            param($Catalog, $MountDir)
            Mock Mount-OfflineRegistryHive { [pscustomobject]@{ Hive = 'SOFTWARE'; MountKey = 'HKLM\WIM_Test_SOFTWARE' } }
            Mock Dismount-OfflineRegistryHive { }
            Mock Get-OfflineRegistryValue { $null }
            Mock Set-OfflineRegistryValue { throw 'simulated write failure' }

            $results = Set-RegistryTweaks -MountPath $MountDir -Catalog $Catalog -Architecture amd64
            ($results | Where-Object { $_.Id -eq 'reg-disable-recall' }).Status | Should -Be 'Failed'
            Should -Invoke Dismount-OfflineRegistryHive -Times 1
        }
    }
}
