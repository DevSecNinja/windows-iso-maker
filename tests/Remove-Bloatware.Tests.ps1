#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for Remove-Bloatware — DISM appx/capability calls are mocked via module wrappers.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force

    $script:AppxCatalog = @(
        [pscustomobject]@{ Id = 'appx-a'; Type = 'Appx'; Action = 'RemoveAppx'; Target = 'Microsoft.AppA'; Citation = 'https://learn.microsoft.com/'; Arch = @('amd64', 'arm64') }
        [pscustomobject]@{ Id = 'appx-b'; Type = 'Appx'; Action = 'RemoveAppx'; Target = 'Microsoft.AppB'; Citation = 'https://learn.microsoft.com/'; Arch = @('amd64', 'arm64') }
        [pscustomobject]@{ Id = 'appx-arm-only'; Type = 'Appx'; Action = 'RemoveAppx'; Target = 'Microsoft.ArmApp'; Citation = 'https://learn.microsoft.com/'; Arch = @('arm64') }
    )
}

Describe 'Remove-Bloatware' {

    BeforeEach {
        $script:MountDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-mount-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:MountDir -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:MountDir) { Remove-Item $script:MountDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'removes provisioned packages that are present' {
        InModuleScope WindowsIsoMaker -Parameters @{ Catalog = $script:AppxCatalog; MountDir = $script:MountDir } {
            param($Catalog, $MountDir)
            Mock Get-ImageProvisionedAppx {
                @(
                    [pscustomobject]@{ DisplayName = 'Microsoft.AppA'; PackageName = 'Microsoft.AppA_1.0' }
                    [pscustomobject]@{ DisplayName = 'Microsoft.AppB'; PackageName = 'Microsoft.AppB_2.0' }
                )
            }
            Mock Remove-ImageProvisionedAppx { }

            $results = Remove-Bloatware -MountPath $MountDir -Catalog $Catalog -Architecture amd64
            ($results | Where-Object { $_.Id -eq 'appx-a' }).Status | Should -Be 'Applied'
            Should -Invoke Remove-ImageProvisionedAppx -Times 2
        }
    }

    It 'records NotApplicable when the package is absent' {
        InModuleScope WindowsIsoMaker -Parameters @{ Catalog = $script:AppxCatalog; MountDir = $script:MountDir } {
            param($Catalog, $MountDir)
            Mock Get-ImageProvisionedAppx { @() }
            Mock Remove-ImageProvisionedAppx { }

            $results = Remove-Bloatware -MountPath $MountDir -Catalog $Catalog -Architecture amd64
            ($results | Where-Object { $_.Id -eq 'appx-a' }).Status | Should -Be 'NotApplicable'
            Should -Invoke Remove-ImageProvisionedAppx -Times 0
        }
    }

    It 'is a no-op under -WhatIf' {
        InModuleScope WindowsIsoMaker -Parameters @{ Catalog = $script:AppxCatalog; MountDir = $script:MountDir } {
            param($Catalog, $MountDir)
            Mock Get-ImageProvisionedAppx { @([pscustomobject]@{ DisplayName = 'Microsoft.AppA'; PackageName = 'Microsoft.AppA_1.0' }) }
            Mock Remove-ImageProvisionedAppx { }

            Remove-Bloatware -MountPath $MountDir -Catalog $Catalog -Architecture amd64 -WhatIf | Out-Null
            Should -Invoke Remove-ImageProvisionedAppx -Times 0
        }
    }

    It 'filters entries by architecture' {
        InModuleScope WindowsIsoMaker -Parameters @{ Catalog = $script:AppxCatalog; MountDir = $script:MountDir } {
            param($Catalog, $MountDir)
            Mock Get-ImageProvisionedAppx { @() }
            Mock Remove-ImageProvisionedAppx { }

            $results = Remove-Bloatware -MountPath $MountDir -Catalog $Catalog -Architecture amd64
            ($results | Where-Object { $_.Id -eq 'appx-arm-only' }) | Should -BeNullOrEmpty
        }
    }
}

Describe 'Remove-Bloatware: DisableOptionalFeature (e.g. Recall)' {

    BeforeEach {
        $script:MountDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-mount-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:MountDir -Force | Out-Null
        $script:FeatureCatalog = @(
            [pscustomobject]@{ Id = 'feature-remove-recall'; Type = 'OptionalFeature'; Action = 'DisableOptionalFeature'; Target = 'Recall'; Citation = 'https://learn.microsoft.com/'; Arch = @('amd64', 'arm64') }
        )
    }
    AfterEach {
        if (Test-Path $script:MountDir) { Remove-Item $script:MountDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'disables and removes an enabled optional feature' {
        InModuleScope WindowsIsoMaker -Parameters @{ Catalog = $script:FeatureCatalog; MountDir = $script:MountDir } {
            param($Catalog, $MountDir)
            Mock Get-ImageOptionalFeature { @([pscustomobject]@{ FeatureName = 'Recall'; State = 'Enabled' }) }
            Mock Disable-ImageOptionalFeature { }

            $results = Remove-Bloatware -MountPath $MountDir -Catalog $Catalog -Architecture amd64
            ($results | Where-Object { $_.Id -eq 'feature-remove-recall' }).Status | Should -Be 'Applied'
            Should -Invoke Disable-ImageOptionalFeature -Times 1 -ParameterFilter { $FeatureName -eq 'Recall' }
        }
    }

    It 'records AlreadyApplied when the feature is already disabled' {
        InModuleScope WindowsIsoMaker -Parameters @{ Catalog = $script:FeatureCatalog; MountDir = $script:MountDir } {
            param($Catalog, $MountDir)
            Mock Get-ImageOptionalFeature { @([pscustomobject]@{ FeatureName = 'Recall'; State = 'DisabledWithPayloadRemoved' }) }
            Mock Disable-ImageOptionalFeature { }

            $results = Remove-Bloatware -MountPath $MountDir -Catalog $Catalog -Architecture amd64
            ($results | Where-Object { $_.Id -eq 'feature-remove-recall' }).Status | Should -Be 'AlreadyApplied'
            Should -Invoke Disable-ImageOptionalFeature -Times 0
        }
    }

    It 'records NotApplicable when the feature is not present in the image' {
        InModuleScope WindowsIsoMaker -Parameters @{ Catalog = $script:FeatureCatalog; MountDir = $script:MountDir } {
            param($Catalog, $MountDir)
            Mock Get-ImageOptionalFeature { @() }
            Mock Disable-ImageOptionalFeature { }

            $results = Remove-Bloatware -MountPath $MountDir -Catalog $Catalog -Architecture amd64
            ($results | Where-Object { $_.Id -eq 'feature-remove-recall' }).Status | Should -Be 'NotApplicable'
            Should -Invoke Disable-ImageOptionalFeature -Times 0
        }
    }

    It 'is a no-op under -WhatIf' {
        InModuleScope WindowsIsoMaker -Parameters @{ Catalog = $script:FeatureCatalog; MountDir = $script:MountDir } {
            param($Catalog, $MountDir)
            Mock Get-ImageOptionalFeature { @([pscustomobject]@{ FeatureName = 'Recall'; State = 'Enabled' }) }
            Mock Disable-ImageOptionalFeature { }

            Remove-Bloatware -MountPath $MountDir -Catalog $Catalog -Architecture amd64 -WhatIf | Out-Null
            Should -Invoke Disable-ImageOptionalFeature -Times 0
        }
    }

    It 'routes DisableOptionalFeature through Invoke-CatalogEntry to Remove-Bloatware' {
        InModuleScope WindowsIsoMaker -Parameters @{ Catalog = $script:FeatureCatalog; MountDir = $script:MountDir } {
            param($Catalog, $MountDir)
            Mock Get-ImageOptionalFeature { @([pscustomobject]@{ FeatureName = 'Recall'; State = 'Enabled' }) }
            Mock Disable-ImageOptionalFeature { }

            $result = Invoke-CatalogEntry -Entry $Catalog[0] -MountPath $MountDir -Architecture amd64
            $result.Status | Should -Be 'Applied'
            Should -Invoke Disable-ImageOptionalFeature -Times 1
        }
    }
}
