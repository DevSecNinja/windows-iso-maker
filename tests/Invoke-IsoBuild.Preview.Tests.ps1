#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for Invoke-IsoBuild preview / idempotency / failure-cleanup guarantees (US5).
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force

    function New-FakeConfig {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-prev-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [pscustomobject]@{
            PSTypeName        = 'WindowsIsoMaker.BuildConfiguration'
            Edition           = 'Pro'; Language = 'en-US'; Release = 'latest'; Architecture = 'amd64'
            Profile           = 'default'; RemoveEdge = $false; RemoveOneDrive = $false
            IncludeCatalogId  = @(); ExcludeCatalogId = @()
            WorkingDirectory  = (Join-Path $tmp 'work'); OutputDirectory = (Join-Path $tmp 'out')
            IsoPath           = ''; BootTest = $false; CompressionFormat = 'zip'
            FidoPath          = 'vendor/fido/Fido.ps1'; OscdimgPath = ''
            SelectedCatalog   = @(
                [pscustomobject]@{ Id = 'reg-disable-recall'; Type = 'Registry'; Citation = 'https://learn.microsoft.com/'; Arch = @('amd64') }
            )
        }
    }
}

Describe 'Invoke-IsoBuild preview & safety (US5)' {

    It 'produces a Preview RunReport and touches no media under -WhatIf' {
        $cfg = New-FakeConfig
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
        $cfg = New-FakeConfig
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

    It 'discards the mounted image and rethrows when a mid-build step fails (FR-005)' {
        $cfg = New-FakeConfig
        InModuleScope WindowsIsoMaker -Parameters @{ Cfg = $cfg } {
            param($Cfg)
            Mock Test-BuildPrerequisite { [pscustomobject]@{ } }
            Mock Get-Windows11Iso { [pscustomobject]@{ Path = 'x.iso'; Verified = $true } }
            Mock Expand-WindowsImage { [pscustomobject]@{ MediaRoot = 'm'; ImagePath = 'm\sources\install.wim' } }
            Mock Mount-WindowsBuildImage { [pscustomobject]@{ MountPath = 'mnt'; IsMounted = $true } }
            Mock Remove-Bloatware { throw 'simulated servicing failure' }
            Mock Dismount-BuildImage { }
            Mock New-RunReport { param($Outcome) [pscustomobject]@{ Outcome = $Outcome } }

            { Invoke-IsoBuild -Config $Cfg } | Should -Throw
            # Cleanup must discard (not save) the mounted image.
            Should -Invoke Dismount-BuildImage -Times 1 -ParameterFilter { $Discard.IsPresent }
        }
    }
}
