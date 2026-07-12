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

Describe 'ConvertFrom-DismCapabilities' {
    It 'parses Capability Identity/State pairs from dism output' {
        InModuleScope WindowsIsoMaker {
            $sample = @(
                'Deployment Image Servicing and Management tool',
                '',
                'Capabilities listing:',
                '',
                'Capability Identity : Language.Basic~~~en-US~0.0.1.0',
                'State : Installed',
                '',
                'Capability Identity : Microsoft.Windows.WordPad~~~~0.0.1.0',
                'State : Not Present',
                '',
                'The operation completed successfully.'
            )
            $caps = ConvertFrom-DismCapabilities -Output $sample
            $caps.Count | Should -Be 2
            $caps[0].Name | Should -Be 'Language.Basic~~~en-US~0.0.1.0'
            $caps[0].State | Should -Be 'Installed'
            $caps[1].Name | Should -Be 'Microsoft.Windows.WordPad~~~~0.0.1.0'
            $caps[1].State | Should -Be 'Not Present'
        }
    }

    It 'returns nothing for output with no capabilities' {
        InModuleScope WindowsIsoMaker {
            $caps = ConvertFrom-DismCapabilities -Output @('The operation completed successfully.')
            @($caps).Count | Should -Be 0
        }
    }
}

Describe 'ConvertFrom-DismFeatures' {
    It 'parses Feature Name/State pairs from dism output' {
        InModuleScope WindowsIsoMaker {
            $sample = @(
                'Features listing:',
                '',
                'Feature Name : NetFx3',
                'State : Disabled',
                '',
                'Feature Name : Microsoft-Windows-Subsystem-Linux',
                'State : Enabled',
                '',
                'The operation completed successfully.'
            )
            $features = ConvertFrom-DismFeatures -Output $sample
            $features.Count | Should -Be 2
            $features[0].FeatureName | Should -Be 'NetFx3'
            $features[0].State | Should -Be 'Disabled'
            $features[1].FeatureName | Should -Be 'Microsoft-Windows-Subsystem-Linux'
            $features[1].State | Should -Be 'Enabled'
        }
    }

    It 'returns nothing for output with no features' {
        InModuleScope WindowsIsoMaker {
            $features = ConvertFrom-DismFeatures -Output @('The operation completed successfully.')
            @($features).Count | Should -Be 0
        }
    }
}

Describe 'Get-ImageCapability (dism.exe)' {
    It 'invokes dism.exe with the get-capabilities verb and parses the result' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-DismExe {
                [pscustomobject]@{
                    ExitCode = 0
                    Output   = @('Capability Identity : Microsoft.Windows.WordPad~~~~0.0.1.0', 'State : Installed')
                }
            }
            $result = Get-ImageCapability -Path 'C:\mount'
            $result.Count | Should -Be 1
            $result[0].Name | Should -Be 'Microsoft.Windows.WordPad~~~~0.0.1.0'
            $result[0].State | Should -Be 'Installed'
            Should -Invoke Invoke-DismExe -Times 1 -ParameterFilter {
                ($Arguments -contains '/Get-Capabilities') -and ($Arguments -contains '/Image:C:\mount')
            }
        }
    }

    It 'throws when dism.exe returns a non-zero exit code' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-DismExe { [pscustomobject]@{ ExitCode = 5; Output = @('Error: 5') } }
            { Get-ImageCapability -Path 'C:\mount' } | Should -Throw '*exit 5*'
        }
    }
}

Describe 'Remove-ImageCapability (dism.exe)' {
    It 'invokes dism.exe with the remove-capability verb and capability name' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-DismExe { [pscustomobject]@{ ExitCode = 0; Output = @('The operation completed successfully.') } }
            Remove-ImageCapability -Path 'C:\mount' -Name 'Microsoft.Windows.WordPad~~~~0.0.1.0'
            Should -Invoke Invoke-DismExe -Times 1 -ParameterFilter {
                ($Arguments -contains '/Remove-Capability') -and ($Arguments -contains '/CapabilityName:Microsoft.Windows.WordPad~~~~0.0.1.0')
            }
        }
    }

    It 'throws when dism.exe fails to remove' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-DismExe { [pscustomobject]@{ ExitCode = 2; Output = @('Error') } }
            { Remove-ImageCapability -Path 'C:\mount' -Name 'X' } | Should -Throw '*exit 2*'
        }
    }
}

Describe 'Add-ImageCapability (dism.exe)' {
    It 'invokes dism.exe with the add-capability verb and capability name' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-DismExe { [pscustomobject]@{ ExitCode = 0; Output = @('The operation completed successfully.') } }
            Add-ImageCapability -Path 'C:\mount' -Name 'Microsoft.Windows.Notepad~~~~0.0.1.0'
            Should -Invoke Invoke-DismExe -Times 1 -ParameterFilter {
                ($Arguments -contains '/Add-Capability') -and ($Arguments -contains '/CapabilityName:Microsoft.Windows.Notepad~~~~0.0.1.0')
            }
        }
    }

    It 'throws when dism.exe fails to add' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-DismExe { [pscustomobject]@{ ExitCode = 3; Output = @('Error') } }
            { Add-ImageCapability -Path 'C:\mount' -Name 'X' } | Should -Throw '*exit 3*'
        }
    }
}

Describe 'Get-ImageOptionalFeature (dism.exe)' {
    It 'invokes dism.exe with the get-features verb and parses the result' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-DismExe {
                [pscustomobject]@{ ExitCode = 0; Output = @('Feature Name : NetFx3', 'State : Disabled') }
            }
            $result = Get-ImageOptionalFeature -Path 'C:\mount'
            $result.Count | Should -Be 1
            $result[0].FeatureName | Should -Be 'NetFx3'
            $result[0].State | Should -Be 'Disabled'
            Should -Invoke Invoke-DismExe -Times 1 -ParameterFilter {
                ($Arguments -contains '/Get-Features') -and ($Arguments -contains '/Image:C:\mount')
            }
        }
    }

    It 'passes a specific FeatureName to dism.exe when supplied' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-DismExe { [pscustomobject]@{ ExitCode = 0; Output = @('Feature Name : NetFx3', 'State : Enabled') } }
            Get-ImageOptionalFeature -Path 'C:\mount' -FeatureName 'NetFx3' | Out-Null
            Should -Invoke Invoke-DismExe -Times 1 -ParameterFilter { $Arguments -contains '/FeatureName:NetFx3' }
        }
    }

    It 'throws when dism.exe returns a non-zero exit code' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-DismExe { [pscustomobject]@{ ExitCode = 5; Output = @('Error') } }
            { Get-ImageOptionalFeature -Path 'C:\mount' } | Should -Throw '*exit 5*'
        }
    }
}

Describe 'Enable-ImageOptionalFeature (dism.exe)' {
    It 'invokes dism.exe with the enable-feature verb, feature name and /All' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-DismExe { [pscustomobject]@{ ExitCode = 0; Output = @('The operation completed successfully.') } }
            Enable-ImageOptionalFeature -Path 'C:\mount' -FeatureName 'NetFx3'
            Should -Invoke Invoke-DismExe -Times 1 -ParameterFilter {
                ($Arguments -contains '/Enable-Feature') -and ($Arguments -contains '/FeatureName:NetFx3') -and ($Arguments -contains '/All')
            }
        }
    }

    It 'throws when dism.exe fails to enable' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-DismExe { [pscustomobject]@{ ExitCode = 4; Output = @('Error') } }
            { Enable-ImageOptionalFeature -Path 'C:\mount' -FeatureName 'X' } | Should -Throw '*exit 4*'
        }
    }
}
