#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for Invoke-IsoBuild preview / idempotency / failure-cleanup guarantees (US5).
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force

    function Get-FakeConfig {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-prev-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [pscustomobject]@{
            PSTypeName        = 'WindowsIsoMaker.BuildConfiguration'
            Edition           = 'Pro'; Language = 'en-US'; Release = 'latest'; Architecture = 'amd64'
            Profile           = 'default'; Toggles = @{}
            EnableCatalogId   = @(); DisableCatalogId = @()
            Autounattend      = $null; AzureUpload = $null
            WorkingDirectory  = (Join-Path $tmp 'work'); OutputDirectory = (Join-Path $tmp 'out')
            IsoPath           = ''; BootTest = $false; CompressionFormat = 'zip'
            FidoPath          = ''; OscdimgPath = ''
            SelectedCatalog   = @(
                [pscustomobject]@{ Id = 'reg-disable-recall'; Type = 'Registry'; Action = 'SetRegistry'; Target = @{ Hive = 'SOFTWARE'; Path = 'P'; Name = 'N'; Kind = 'DWord'; Value = 1 }; Citation = 'https://learn.microsoft.com/'; Arch = @('amd64') }
            )
        }
    }
}

Describe 'Invoke-IsoBuild preview & safety (US5)' {

    It 'produces a Preview RunReport and touches no media under -WhatIf' {
        $cfg = Get-FakeConfig
        InModuleScope WindowsIsoMaker -Parameters @{ Cfg = $cfg } {
            param($Cfg)
            Mock Test-BuildPrerequisite { [pscustomobject]@{ } }
            Mock Get-Windows11Iso { throw 'must not download in preview' }
            Mock Mount-WindowsBuildImage { throw 'must not mount in preview' }
            Mock New-RunReport { param($Outcome) [pscustomobject]@{ Outcome = $Outcome } }

            $report = Invoke-IsoBuild -Config $Cfg -WhatIf
            $report.Outcome | Should -Be 'Preview'
            Should -Invoke Get-Windows11Iso -Times 0
            Should -Invoke Mount-WindowsBuildImage -Times 0
        }
    }

    It 'runs preview-only under -SkipHeavyBuild' {
        $cfg = Get-FakeConfig
        InModuleScope WindowsIsoMaker -Parameters @{ Cfg = $cfg } {
            param($Cfg)
            Mock Test-BuildPrerequisite { [pscustomobject]@{ } }
            Mock Get-Windows11Iso { throw 'must not download' }
            Mock New-RunReport { param($Outcome) [pscustomobject]@{ Outcome = $Outcome } }

            $report = Invoke-IsoBuild -Config $Cfg -SkipHeavyBuild
            $report.Outcome | Should -Be 'Preview'
            Should -Invoke Get-Windows11Iso -Times 0
        }
    }

    It 'applies a -ProductKey override onto the Autounattend sub-config' {
        $cfg = Get-FakeConfig
        $cfg.Autounattend = @{ Enabled = $true; ProductKey = '' }
        InModuleScope WindowsIsoMaker -Parameters @{ Cfg = $cfg } {
            param($Cfg)
            Mock Test-BuildPrerequisite { [pscustomobject]@{ } }
            Mock Get-Windows11Iso { throw 'must not download' }
            $script:capturedKey = 'UNSET'
            Mock New-RunReport {
                param($Outcome, $Autounattend)
                $script:capturedKey = $Autounattend['ProductKey']
                [pscustomobject]@{ Outcome = $Outcome }
            }

            $null = Invoke-IsoBuild -Config $Cfg -ProductKey 'ABCDE-FGHIJ-KLMNO-PQRST-UVWXY' -SkipHeavyBuild
            $script:capturedKey | Should -Be 'ABCDE-FGHIJ-KLMNO-PQRST-UVWXY'
        }
    }

    It 'sets the Autounattend ProductKey to "generic" when -UseGenericProductKey is passed' {
        $cfg = Get-FakeConfig
        $cfg.Autounattend = @{ Enabled = $true; ProductKey = '' }
        InModuleScope WindowsIsoMaker -Parameters @{ Cfg = $cfg } {
            param($Cfg)
            Mock Test-BuildPrerequisite { [pscustomobject]@{ } }
            Mock Get-Windows11Iso { throw 'must not download' }
            $script:capturedKey = 'UNSET'
            Mock New-RunReport {
                param($Outcome, $Autounattend)
                $script:capturedKey = $Autounattend['ProductKey']
                [pscustomobject]@{ Outcome = $Outcome }
            }

            $null = Invoke-IsoBuild -Config $Cfg -UseGenericProductKey -SkipHeavyBuild
            $script:capturedKey | Should -Be 'generic'
        }
    }

    It 'throws when both -ProductKey and -UseGenericProductKey are passed (mutually exclusive)' {
        $cfg = Get-FakeConfig
        $cfg.Autounattend = @{ Enabled = $true; ProductKey = '' }
        InModuleScope WindowsIsoMaker -Parameters @{ Cfg = $cfg } {
            param($Cfg)
            Mock Test-BuildPrerequisite { [pscustomobject]@{ } }
            Mock Get-Windows11Iso { throw 'must not download' }

            { Invoke-IsoBuild -Config $Cfg -ProductKey 'ABCDE-FGHIJ-KLMNO-PQRST-UVWXY' -UseGenericProductKey -SkipHeavyBuild } |
                Should -Throw '*mutually exclusive*'
        }
    }

    It 'discards the mounted image and rethrows when a mid-build step fails (FR-005)' {
        $cfg = Get-FakeConfig
        InModuleScope WindowsIsoMaker -Parameters @{ Cfg = $cfg } {
            param($Cfg)
            Mock Test-BuildPrerequisite { [pscustomobject]@{ } }
            Mock Get-Windows11Iso { [pscustomobject]@{ Path = 'x.iso'; Verified = $true } }
            Mock Expand-WindowsImage { [pscustomobject]@{ MediaRoot = 'm'; ImagePath = 'm\sources\install.wim' } }
            Mock Mount-WindowsBuildImage { [pscustomobject]@{ MountPath = 'mnt'; IsMounted = $true } }
            Mock Clear-StaleImageMount { }
            Mock Invoke-CatalogEntry { throw 'simulated servicing failure' }
            Mock Dismount-BuildImage { }
            Mock New-RunReport { param($Outcome) [pscustomobject]@{ Outcome = $Outcome } }

            { Invoke-IsoBuild -Config $Cfg } | Should -Throw
            # Cleanup must discard (not save) the mounted image.
            Should -Invoke Dismount-BuildImage -Times 1 -ParameterFilter { $Discard.IsPresent }
        }
    }
}
