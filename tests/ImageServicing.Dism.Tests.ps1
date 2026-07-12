#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for the dism.exe-based provisioned-Appx servicing wrappers (Invoke-DismExe is mocked).
    These operations use dism.exe instead of Get/Remove-AppxProvisionedPackage because the
    Dism module's Appx cmdlets throw "Class not registered" under PowerShell 7 (Core).
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force
}

Describe 'ConvertFrom-DismProvisionedAppx' {
    It 'parses DisplayName/PackageName pairs from dism output' {
        InModuleScope WindowsIsoMaker {
            $sample = @(
                'Deployment Image Servicing and Management tool',
                'Version: 10.0.26100.1',
                '',
                'Packages listing:',
                '',
                'DisplayName : Microsoft.Clipchamp',
                'PackageName : Clipchamp.Clipchamp_2.2.8.0_neutral_~_yxz26nhyzhsrt',
                'Version : 2.2.8.0',
                'Architecture : neutral',
                '',
                'DisplayName : Microsoft.BingNews',
                'PackageName : Microsoft.BingNews_1.0_x64__8wekyb3d8bbwe',
                '',
                'The operation completed successfully.'
            )
            $packages = ConvertFrom-DismProvisionedAppx -Output $sample
            $packages.Count | Should -Be 2
            $packages[0].DisplayName | Should -Be 'Microsoft.Clipchamp'
            $packages[0].PackageName | Should -Be 'Clipchamp.Clipchamp_2.2.8.0_neutral_~_yxz26nhyzhsrt'
            $packages[1].DisplayName | Should -Be 'Microsoft.BingNews'
        }
    }

    It 'returns nothing for output with no packages' {
        InModuleScope WindowsIsoMaker {
            $packages = ConvertFrom-DismProvisionedAppx -Output @('The operation completed successfully.')
            @($packages).Count | Should -Be 0
        }
    }
}

Describe 'Get-ImageProvisionedAppx (dism.exe)' {
    It 'invokes dism.exe with the offline image and get verb, and parses the result' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-DismExe {
                [pscustomobject]@{
                    ExitCode = 0
                    Output   = @('DisplayName : Microsoft.AppA', 'PackageName : Microsoft.AppA_1.0')
                }
            }
            $result = Get-ImageProvisionedAppx -Path 'C:\mount'
            $result.Count | Should -Be 1
            $result[0].PackageName | Should -Be 'Microsoft.AppA_1.0'
            Should -Invoke Invoke-DismExe -Times 1 -ParameterFilter {
                ($Arguments -contains '/Get-ProvisionedAppxPackages') -and ($Arguments -contains '/Image:C:\mount')
            }
        }
    }

    It 'throws when dism.exe returns a non-zero exit code' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-DismExe { [pscustomobject]@{ ExitCode = 5; Output = @('Error: 5', 'Access is denied.') } }
            { Get-ImageProvisionedAppx -Path 'C:\mount' } | Should -Throw '*exit 5*'
        }
    }
}

Describe 'Remove-ImageProvisionedAppx (dism.exe)' {
    It 'invokes dism.exe with the remove verb and package name' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-DismExe { [pscustomobject]@{ ExitCode = 0; Output = @('The operation completed successfully.') } }
            Remove-ImageProvisionedAppx -Path 'C:\mount' -PackageName 'Microsoft.AppA_1.0'
            Should -Invoke Invoke-DismExe -Times 1 -ParameterFilter {
                ($Arguments -contains '/Remove-ProvisionedAppxPackage') -and ($Arguments -contains '/PackageName:Microsoft.AppA_1.0')
            }
        }
    }

    It 'throws when dism.exe fails to remove' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-DismExe { [pscustomobject]@{ ExitCode = 2; Output = @('Error') } }
            { Remove-ImageProvisionedAppx -Path 'C:\mount' -PackageName 'X' } | Should -Throw '*exit 2*'
        }
    }
}
