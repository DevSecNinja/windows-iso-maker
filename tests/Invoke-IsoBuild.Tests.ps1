#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for Invoke-IsoBuild orchestration — every pipeline step is mocked.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force

    function Get-FakeConfig {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-build-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
                [pscustomobject]@{ Id = 'appx-a'; Type = 'Appx'; Action = 'RemoveAppx'; Target = 'Microsoft.AppA'; Citation = 'https://learn.microsoft.com/'; Arch = @('amd64') }
                [pscustomobject]@{ Id = 'reg-disable-recall'; Type = 'Registry'; Action = 'SetRegistry'; Target = @{ Hive = 'SOFTWARE'; Path = 'P'; Name = 'N'; Kind = 'DWord'; Value = 1 }; Citation = 'https://learn.microsoft.com/'; Arch = @('amd64') }
            )
        }
    }
}

Describe 'Invoke-IsoBuild orchestration' {

    It 'runs the pipeline in the correct order and emits a Succeeded RunReport' {
        $cfg = Get-FakeConfig
        InModuleScope WindowsIsoMaker -Parameters @{ Cfg = $cfg } {
            param($Cfg)
            $script:CallOrder = [System.Collections.Generic.List[string]]::new()

            Mock Test-BuildPrerequisite { $script:CallOrder.Add('prereq'); [pscustomobject]@{ OscdimgPath = 'x'; DismPath = 'x' } }
            Mock Get-Windows11Iso { $script:CallOrder.Add('download'); [pscustomobject]@{ Path = 'C:\work\win11.iso'; Verified = $true } }
            Mock Expand-WindowsImage { $script:CallOrder.Add('expand'); [pscustomobject]@{ MediaRoot = 'C:\work\media'; ImagePath = 'C:\work\media\sources\install.wim' } }
            Mock Clear-StaleImageMount { }
            Mock Mount-WindowsBuildImage { $script:CallOrder.Add('mount'); [pscustomobject]@{ MountPath = 'C:\work\mount'; IsMounted = $true } }
            Mock Invoke-CatalogEntry { $script:CallOrder.Add('apply'); [pscustomobject]@{ Id = 'x'; Status = 'Applied' } }
            Mock Dismount-BuildImage { $script:CallOrder.Add('dismount-save') }
            Mock New-BootableIso { $script:CallOrder.Add('iso'); 'C:\work\win11.iso' }
            Mock Compress-BuildArtifact { $script:CallOrder.Add('compress'); [pscustomobject]@{ ArchivePath = 'C:\out\a.zip' } }
            Mock Test-ImageIntegrity { $script:CallOrder.Add('integrity'); [pscustomobject]@{ Passed = $true } }
            Mock Export-ImageBom { [pscustomobject]@{ Path = 'C:\out\bom.json' } }
            Mock New-RunReport { param($Outcome) [pscustomobject]@{ Outcome = $Outcome } }

            $report = Invoke-IsoBuild -Config $Cfg
            $report.Outcome | Should -Be 'Succeeded'

            # Verify key ordering constraints.
            $order = $script:CallOrder
            ($order.IndexOf('prereq'))   | Should -BeLessThan ($order.IndexOf('download'))
            ($order.IndexOf('download')) | Should -BeLessThan ($order.IndexOf('mount'))
            ($order.IndexOf('apply'))    | Should -BeLessThan ($order.IndexOf('dismount-save'))
            ($order.IndexOf('dismount-save')) | Should -BeLessThan ($order.IndexOf('iso'))
            ($order.IndexOf('compress')) | Should -BeLessThan ($order.IndexOf('integrity'))
        }
    }

    It 'blocks when the preconditions gate fails and does not download' {
        $cfg = Get-FakeConfig
        InModuleScope WindowsIsoMaker -Parameters @{ Cfg = $cfg } {
            param($Cfg)
            Mock Test-BuildPrerequisite { throw 'insufficient disk space' }
            Mock Get-Windows11Iso { }

            { Invoke-IsoBuild -Config $Cfg } | Should -Throw
            Should -Invoke Get-Windows11Iso -Times 0
        }
    }

    It 'refuses to service an unverified base image (FR-020)' {
        $cfg = Get-FakeConfig
        InModuleScope WindowsIsoMaker -Parameters @{ Cfg = $cfg } {
            param($Cfg)
            Mock Test-BuildPrerequisite { [pscustomobject]@{ } }
            Mock Get-Windows11Iso { [pscustomobject]@{ Path = 'x'; Verified = $false } }
            Mock Expand-WindowsImage { }

            { Invoke-IsoBuild -Config $Cfg } | Should -Throw
            Should -Invoke Expand-WindowsImage -Times 0
        }
    }
}

Describe 'Clear-StaleImageMount' {
    It 'discards a mount that matches the target path' {
        InModuleScope WindowsIsoMaker {
            Mock Get-MountedBuildImage {
                @([pscustomobject]@{ MountPath = 'C:\work\mount'; ImagePath = 'C:\work\media\sources\install.wim' })
            }
            Mock Dismount-BuildImage { }

            Clear-StaleImageMount -MountPath 'C:\work\mount\'

            Should -Invoke Dismount-BuildImage -Times 1 -ParameterFilter { $Discard.IsPresent -and $Path -eq 'C:\work\mount' }
        }
    }

    It 'does nothing when no mounted image matches the target path' {
        InModuleScope WindowsIsoMaker {
            Mock Get-MountedBuildImage {
                @([pscustomobject]@{ MountPath = 'C:\other\mount'; ImagePath = 'x' })
            }
            Mock Dismount-BuildImage { }

            Clear-StaleImageMount -MountPath 'C:\work\mount'

            Should -Invoke Dismount-BuildImage -Times 0
        }
    }
}
