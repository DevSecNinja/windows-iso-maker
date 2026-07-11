#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for Remove-Bloatware — DISM appx/capability calls are mocked via module wrappers.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force

    $script:AppxCatalog = @(
        [pscustomobject]@{ Id = 'appx-a'; Type = 'Appx'; Action = 'Remove'; Target = 'Microsoft.AppA'; Citation = 'https://learn.microsoft.com/'; Arch = @('amd64', 'arm64') }
        [pscustomobject]@{ Id = 'appx-b'; Type = 'Appx'; Action = 'Remove'; Target = 'Microsoft.AppB'; Citation = 'https://learn.microsoft.com/'; Arch = @('amd64', 'arm64') }
        [pscustomobject]@{ Id = 'appx-arm-only'; Type = 'Appx'; Action = 'Remove'; Target = 'Microsoft.ArmApp'; Citation = 'https://learn.microsoft.com/'; Arch = @('arm64') }
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
