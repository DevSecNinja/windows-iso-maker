#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for the ONLINE post-install path: Invoke-PostInstallSetup and its private online
    appliers (Set-OnlineRegistryTweaks / Remove-OnlineBloatware / Enable-OnlineWindowsFeature /
    Invoke-OnlineCatalogEntry). All external servicing seams (dism/Appx wrappers and the shared
    registry-value helpers) are mocked so these run on any platform.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force
}

Describe 'Set-OnlineRegistryTweaks' {

    It 'writes machine-hive (SOFTWARE) tweaks to live HKLM without loading a hive' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                [pscustomobject]@{ Id = 'reg-machine'; Type = 'Registry'; Action = 'SetRegistry'; Citation = 'x'; Arch = @('amd64', 'arm64')
                    Target = @{ Hive = 'SOFTWARE'; Path = 'Policies\Foo'; Name = 'Bar'; Kind = 'DWord'; Value = 1 } }
            )
            Mock Mount-DefaultUserRegistryHive { throw 'should not load a hive for machine tweaks' }
            Mock Get-OfflineRegistryValue { $null }
            Mock Set-OfflineRegistryValue { }

            $res = Set-OnlineRegistryTweaks -Catalog $catalog -Architecture amd64 -Scope Both
            $res.Status | Should -Be 'Applied'
            Should -Invoke Set-OfflineRegistryValue -Times 1 -ParameterFilter { $MountKey -eq 'HKLM\SOFTWARE' }
            Should -Invoke Mount-DefaultUserRegistryHive -Times 0
        }
    }

    It 'applies DEFAULT-hive per-user tweaks to BOTH HKCU and the default-user template, then unloads it' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                [pscustomobject]@{ Id = 'reg-user'; Type = 'Registry'; Action = 'SetRegistry'; Citation = 'x'; Arch = @('amd64', 'arm64')
                    Target = @{ Hive = 'DEFAULT'; Path = 'Software\Foo'; Name = 'Bar'; Kind = 'DWord'; Value = 0 } }
            )
            Mock Mount-DefaultUserRegistryHive { [pscustomobject]@{ MountKey = 'HKU\WIM_Test_Default'; HiveFile = 'x'; MountKeyName = 'WIM_Test_Default' } }
            Mock Dismount-OfflineRegistryHive { }
            Mock Get-OfflineRegistryValue { $null }
            Mock Set-OfflineRegistryValue { }

            $res = Set-OnlineRegistryTweaks -Catalog $catalog -Architecture amd64 -Scope Both
            $res.Status | Should -Be 'Applied'
            Should -Invoke Set-OfflineRegistryValue -Times 1 -ParameterFilter { $MountKey -eq 'HKCU' }
            Should -Invoke Set-OfflineRegistryValue -Times 1 -ParameterFilter { $MountKey -eq 'HKU\WIM_Test_Default' }
            Should -Invoke Dismount-OfflineRegistryHive -Times 1
        }
    }

    It 'CurrentUser scope targets only HKCU and never loads the template hive' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                [pscustomobject]@{ Id = 'reg-user'; Type = 'Registry'; Action = 'SetRegistry'; Citation = 'x'; Arch = @('amd64', 'arm64')
                    Target = @{ Hive = 'DEFAULT'; Path = 'Software\Foo'; Name = 'Bar'; Kind = 'DWord'; Value = 0 } }
            )
            Mock Mount-DefaultUserRegistryHive { throw 'should not load the template hive for CurrentUser scope' }
            Mock Dismount-OfflineRegistryHive { }
            Mock Get-OfflineRegistryValue { $null }
            Mock Set-OfflineRegistryValue { }

            $res = Set-OnlineRegistryTweaks -Catalog $catalog -Architecture amd64 -Scope CurrentUser
            $res.Status | Should -Be 'Applied'
            Should -Invoke Set-OfflineRegistryValue -Times 1 -ParameterFilter { $MountKey -eq 'HKCU' }
            Should -Invoke Mount-DefaultUserRegistryHive -Times 0
        }
    }

    It 'is idempotent: AlreadyApplied when the value already matches on all targets' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                [pscustomobject]@{ Id = 'reg-machine'; Type = 'Registry'; Action = 'SetRegistry'; Citation = 'x'; Arch = @('amd64', 'arm64')
                    Target = @{ Hive = 'SOFTWARE'; Path = 'Policies\Foo'; Name = 'Bar'; Kind = 'DWord'; Value = 1 } }
            )
            Mock Get-OfflineRegistryValue { 1 }
            Mock Set-OfflineRegistryValue { }

            $res = Set-OnlineRegistryTweaks -Catalog $catalog -Architecture amd64 -Scope Both
            $res.Status | Should -Be 'AlreadyApplied'
            Should -Invoke Set-OfflineRegistryValue -Times 0
        }
    }

    It 'previews would-change entries under -WhatIf without writing (Status Skipped = would change)' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                [pscustomobject]@{ Id = 'reg-machine'; Type = 'Registry'; Action = 'SetRegistry'; Citation = 'x'; Arch = @('amd64', 'arm64')
                    Target = @{ Hive = 'SOFTWARE'; Path = 'Policies\Foo'; Name = 'Bar'; Kind = 'DWord'; Value = 1 } }
            )
            Mock Get-OfflineRegistryValue { $null }
            Mock Set-OfflineRegistryValue { }

            $res = Set-OnlineRegistryTweaks -Catalog $catalog -Architecture amd64 -Scope Both -WhatIf
            $res.Status | Should -Be 'Skipped'
            $res.Reason | Should -BeLike '*Preview*would*'
            Should -Invoke Set-OfflineRegistryValue -Times 0
        }
    }

    It 'previews AlreadyApplied under -WhatIf when the value already matches (no change)' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                [pscustomobject]@{ Id = 'reg-machine'; Type = 'Registry'; Action = 'SetRegistry'; Citation = 'x'; Arch = @('amd64', 'arm64')
                    Target = @{ Hive = 'SOFTWARE'; Path = 'Policies\Foo'; Name = 'Bar'; Kind = 'DWord'; Value = 1 } }
            )
            Mock Get-OfflineRegistryValue { 1 }
            Mock Set-OfflineRegistryValue { }

            $res = Set-OnlineRegistryTweaks -Catalog $catalog -Architecture amd64 -Scope Both -WhatIf
            $res.Status | Should -Be 'AlreadyApplied'
            Should -Invoke Set-OfflineRegistryValue -Times 0
        }
    }

    It 'arms a RunOnce entry and persists an idempotency marker on first run' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                [pscustomobject]@{ Id = 'reg-runonce'; Type = 'Registry'; Action = 'SetRegistry'; Citation = 'x'; Arch = @('amd64', 'arm64')
                    Target = @{ Hive = 'SOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\RunOnce'; Name = '!WimThing'; Kind = 'String'; Value = 'tzutil.exe /s "W. Europe Standard Time"' } }
            )
            # Neither the RunOnce value nor the marker exists yet.
            Mock Get-OfflineRegistryValue { $null }
            Mock Set-OfflineRegistryValue { }
            Mock Set-LiveMachineRegistryValue { }

            $res = Set-OnlineRegistryTweaks -Catalog $catalog -Architecture amd64 -Scope Both
            $res.Status | Should -Be 'Applied'
            Should -Invoke Set-OfflineRegistryValue -Times 1 -ParameterFilter { $Path -eq 'Microsoft\Windows\CurrentVersion\RunOnce' }
            Should -Invoke Set-LiveMachineRegistryValue -Times 1 -ParameterFilter { $SubKey -eq 'SOFTWARE\WindowsIsoMaker\State' -and $Name -eq 'reg-runonce' }
        }
    }

    It 'is idempotent for a RunOnce entry: AlreadyApplied via marker after Windows consumed the value' {
        InModuleScope WindowsIsoMaker {
            $cmd = 'tzutil.exe /s "W. Europe Standard Time"'
            $catalog = @(
                [pscustomobject]@{ Id = 'reg-runonce'; Type = 'Registry'; Action = 'SetRegistry'; Citation = 'x'; Arch = @('amd64', 'arm64')
                    Target = @{ Hive = 'SOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\RunOnce'; Name = '!WimThing'; Kind = 'String'; Value = $cmd } }
            )
            # RunOnce value gone (consumed at logon); the marker records the same command.
            Mock Get-OfflineRegistryValue {
                param($MountKey, $Path, $Name)
                if ($Path -eq 'WindowsIsoMaker\State') { return $cmd }
                return $null
            }
            Mock Set-OfflineRegistryValue { }
            Mock Set-LiveMachineRegistryValue { }

            $res = Set-OnlineRegistryTweaks -Catalog $catalog -Architecture amd64 -Scope Both
            $res.Status | Should -Be 'AlreadyApplied'
            Should -Invoke Set-OfflineRegistryValue -Times 0
            Should -Invoke Set-LiveMachineRegistryValue -Times 0
        }
    }

    It 'does not fail the entry when the idempotency marker write throws (non-fatal)' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                [pscustomobject]@{ Id = 'reg-runonce'; Type = 'Registry'; Action = 'SetRegistry'; Citation = 'x'; Arch = @('amd64', 'arm64')
                    Target = @{ Hive = 'SOFTWARE'; Path = 'Microsoft\Windows\CurrentVersion\RunOnce'; Name = '!WimThing'; Kind = 'String'; Value = 'tzutil.exe /s "UTC"' } }
            )
            Mock Get-OfflineRegistryValue { $null }
            Mock Set-OfflineRegistryValue { }
            Mock Set-LiveMachineRegistryValue { throw 'Requested registry access is not allowed.' }

            $res = Set-OnlineRegistryTweaks -Catalog $catalog -Architecture amd64 -Scope Both
            $res.Status | Should -Be 'Applied'
        }
    }
}

Describe 'Remove-OnlineBloatware' {

    It 'de-provisions for future users AND uninstalls for the current user (Scope Both)' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                [pscustomobject]@{ Id = 'appx-a'; Type = 'Appx'; Action = 'RemoveAppx'; Target = 'Microsoft.AppA'; Citation = 'x'; Arch = @('amd64', 'arm64') }
            )
            Mock Get-OnlineProvisionedAppx { @([pscustomobject]@{ DisplayName = 'Microsoft.AppA'; PackageName = 'Microsoft.AppA_1.0_x64' }) }
            Mock Remove-OnlineProvisionedAppx { }
            Mock Get-OnlineInstalledAppxPackage { @([pscustomobject]@{ Name = 'Microsoft.AppA'; PackageFullName = 'Microsoft.AppA_1.0_x64__abc' }) }
            Mock Remove-OnlineInstalledAppxPackage { }

            $res = Remove-OnlineBloatware -Catalog $catalog -Architecture amd64 -Scope Both
            $res.Status | Should -Be 'Applied'
            Should -Invoke Remove-OnlineProvisionedAppx -Times 1
            Should -Invoke Remove-OnlineInstalledAppxPackage -Times 1
        }
    }

    It 'FutureUsers scope only de-provisions and never touches the current user' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                [pscustomobject]@{ Id = 'appx-a'; Type = 'Appx'; Action = 'RemoveAppx'; Target = 'Microsoft.AppA'; Citation = 'x'; Arch = @('amd64', 'arm64') }
            )
            Mock Get-OnlineProvisionedAppx { @([pscustomobject]@{ DisplayName = 'Microsoft.AppA'; PackageName = 'Microsoft.AppA_1.0_x64' }) }
            Mock Remove-OnlineProvisionedAppx { }
            Mock Get-OnlineInstalledAppxPackage { throw 'should not query current-user packages for FutureUsers scope' }
            Mock Remove-OnlineInstalledAppxPackage { }

            $res = Remove-OnlineBloatware -Catalog $catalog -Architecture amd64 -Scope FutureUsers
            $res.Status | Should -Be 'Applied'
            Should -Invoke Remove-OnlineProvisionedAppx -Times 1
            Should -Invoke Remove-OnlineInstalledAppxPackage -Times 0
        }
    }

    It 'records NotApplicable when neither provisioned nor installed package is present' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                [pscustomobject]@{ Id = 'appx-a'; Type = 'Appx'; Action = 'RemoveAppx'; Target = 'Microsoft.AppA'; Citation = 'x'; Arch = @('amd64', 'arm64') }
            )
            Mock Get-OnlineProvisionedAppx { @() }
            Mock Remove-OnlineProvisionedAppx { }
            Mock Get-OnlineInstalledAppxPackage { @() }
            Mock Remove-OnlineInstalledAppxPackage { }

            $res = Remove-OnlineBloatware -Catalog $catalog -Architecture amd64 -Scope Both
            $res.Status | Should -Be 'NotApplicable'
            Should -Invoke Remove-OnlineProvisionedAppx -Times 0
            Should -Invoke Remove-OnlineInstalledAppxPackage -Times 0
        }
    }

    It 'removes an installed capability via dism /online' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                [pscustomobject]@{ Id = 'cap-a'; Type = 'Capability'; Action = 'RemoveCapability'; Target = 'App.Foo'; Citation = 'x'; Arch = @('amd64', 'arm64') }
            )
            Mock Get-OnlineCapability { @([pscustomobject]@{ Name = 'App.Foo~~~~0.0.1.0'; State = 'Installed' }) }
            Mock Remove-OnlineCapability { }

            $res = Remove-OnlineBloatware -Catalog $catalog -Architecture amd64 -Scope Both
            $res.Status | Should -Be 'Applied'
            Should -Invoke Remove-OnlineCapability -Times 1
        }
    }

    It 'disables and removes an enabled optional feature (Recall) via dism /online' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                [pscustomobject]@{ Id = 'feature-remove-recall'; Type = 'OptionalFeature'; Action = 'DisableOptionalFeature'; Target = 'Recall'; Citation = 'x'; Arch = @('amd64', 'arm64') }
            )
            Mock Get-OnlineOptionalFeature { @([pscustomobject]@{ FeatureName = 'Recall'; State = 'Enabled' }) }
            Mock Disable-OnlineOptionalFeature { }

            $res = Remove-OnlineBloatware -Catalog $catalog -Architecture amd64 -Scope Both
            $res.Status | Should -Be 'Applied'
            Should -Invoke Disable-OnlineOptionalFeature -Times 1 -ParameterFilter { $FeatureName -eq 'Recall' }
        }
    }

    It 'is idempotent: AlreadyApplied when the optional feature is already disabled' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                [pscustomobject]@{ Id = 'feature-remove-recall'; Type = 'OptionalFeature'; Action = 'DisableOptionalFeature'; Target = 'Recall'; Citation = 'x'; Arch = @('amd64', 'arm64') }
            )
            Mock Get-OnlineOptionalFeature { @([pscustomobject]@{ FeatureName = 'Recall'; State = 'DisabledWithPayloadRemoved' }) }
            Mock Disable-OnlineOptionalFeature { }

            $res = Remove-OnlineBloatware -Catalog $catalog -Architecture amd64 -Scope Both
            $res.Status | Should -Be 'AlreadyApplied'
            Should -Invoke Disable-OnlineOptionalFeature -Times 0
        }
    }

    It 'is a no-op under -WhatIf' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                [pscustomobject]@{ Id = 'appx-a'; Type = 'Appx'; Action = 'RemoveAppx'; Target = 'Microsoft.AppA'; Citation = 'x'; Arch = @('amd64', 'arm64') }
            )
            Mock Get-OnlineProvisionedAppx { @([pscustomobject]@{ DisplayName = 'Microsoft.AppA'; PackageName = 'Microsoft.AppA_1.0_x64' }) }
            Mock Remove-OnlineProvisionedAppx { }
            Mock Get-OnlineInstalledAppxPackage { @() }
            Mock Remove-OnlineInstalledAppxPackage { }

            $res = Remove-OnlineBloatware -Catalog $catalog -Architecture amd64 -Scope Both -WhatIf
            $res.Status | Should -Be 'Skipped'
            Should -Invoke Remove-OnlineProvisionedAppx -Times 0
        }
    }
}

Describe 'Enable-OnlineWindowsFeature' {

    It 'enables an optional feature that is disabled' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                [pscustomobject]@{ Id = 'feature-wsl'; Type = 'Capability'; Action = 'EnableOptionalFeature'; Target = 'Microsoft-Windows-Subsystem-Linux'; Citation = 'x'; Arch = @('amd64', 'arm64') }
            )
            Mock Get-OnlineOptionalFeature { @([pscustomobject]@{ FeatureName = 'Microsoft-Windows-Subsystem-Linux'; State = 'Disabled' }) }
            Mock Enable-OnlineOptionalFeature { }

            $res = Enable-OnlineWindowsFeature -Catalog $catalog -Architecture amd64
            $res.Status | Should -Be 'Applied'
            Should -Invoke Enable-OnlineOptionalFeature -Times 1
        }
    }

    It 'is idempotent: AlreadyApplied when the feature is already enabled' {
        InModuleScope WindowsIsoMaker {
            $catalog = @(
                [pscustomobject]@{ Id = 'feature-wsl'; Type = 'Capability'; Action = 'EnableOptionalFeature'; Target = 'Microsoft-Windows-Subsystem-Linux'; Citation = 'x'; Arch = @('amd64', 'arm64') }
            )
            Mock Get-OnlineOptionalFeature { @([pscustomobject]@{ FeatureName = 'Microsoft-Windows-Subsystem-Linux'; State = 'Enabled' }) }
            Mock Enable-OnlineOptionalFeature { }

            $res = Enable-OnlineWindowsFeature -Catalog $catalog -Architecture amd64
            $res.Status | Should -Be 'AlreadyApplied'
            Should -Invoke Enable-OnlineOptionalFeature -Times 0
        }
    }
}

Describe 'Invoke-OnlineCatalogEntry dispatch' {

    It 'routes SetRegistry to Set-OnlineRegistryTweaks' {
        InModuleScope WindowsIsoMaker {
            $entry = [pscustomobject]@{ Id = 'reg-x'; Type = 'Registry'; Action = 'SetRegistry'; Citation = 'x'; Arch = @('amd64', 'arm64')
                Target = @{ Hive = 'SOFTWARE'; Path = 'P'; Name = 'N'; Kind = 'DWord'; Value = 1 } }
            Mock Set-OnlineRegistryTweaks { @([pscustomobject]@{ Id = 'reg-x'; Status = 'Applied' }) }
            Mock Remove-OnlineBloatware { throw 'wrong handler' }
            Mock Enable-OnlineWindowsFeature { throw 'wrong handler' }

            (Invoke-OnlineCatalogEntry -Entry $entry -Architecture amd64 -Scope Both).Status | Should -Be 'Applied'
            Should -Invoke Set-OnlineRegistryTweaks -Times 1
        }
    }

    It 'routes RemoveAppx to Remove-OnlineBloatware' {
        InModuleScope WindowsIsoMaker {
            $entry = [pscustomobject]@{ Id = 'appx-x'; Type = 'Appx'; Action = 'RemoveAppx'; Target = 'X'; Citation = 'x'; Arch = @('amd64', 'arm64') }
            Mock Remove-OnlineBloatware { @([pscustomobject]@{ Id = 'appx-x'; Status = 'Applied' }) }
            (Invoke-OnlineCatalogEntry -Entry $entry -Architecture amd64 -Scope Both).Status | Should -Be 'Applied'
            Should -Invoke Remove-OnlineBloatware -Times 1
        }
    }

    It 'routes DisableOptionalFeature to Remove-OnlineBloatware' {
        InModuleScope WindowsIsoMaker {
            $entry = [pscustomobject]@{ Id = 'feature-remove-recall'; Type = 'OptionalFeature'; Action = 'DisableOptionalFeature'; Target = 'Recall'; Citation = 'x'; Arch = @('amd64', 'arm64') }
            Mock Remove-OnlineBloatware { @([pscustomobject]@{ Id = 'feature-remove-recall'; Status = 'Applied' }) }
            Mock Enable-OnlineWindowsFeature { throw 'wrong handler' }
            (Invoke-OnlineCatalogEntry -Entry $entry -Architecture amd64 -Scope Both).Status | Should -Be 'Applied'
            Should -Invoke Remove-OnlineBloatware -Times 1
        }
    }

    It 'throws on an unknown Action' {
        InModuleScope WindowsIsoMaker {
            $entry = [pscustomobject]@{ Id = 'bad'; Type = 'X'; Action = 'Nope'; Citation = 'x'; Arch = @('amd64', 'arm64') }
            { Invoke-OnlineCatalogEntry -Entry $entry -Architecture amd64 } | Should -Throw
        }
    }
}

Describe 'Invoke-PostInstallSetup orchestration' {

    It 'requires elevation for a real (non-preview) run' {
        InModuleScope WindowsIsoMaker {
            Mock Test-IsAdministrator { $false }
            { Invoke-PostInstallSetup -Profile default -Architecture amd64 -NoReport } | Should -Throw '*elevated*'
        }
    }

    It 'produces a Preview RunReport under -WhatIf (dispatched as a no-op) without requiring admin' {
        InModuleScope WindowsIsoMaker {
            Mock Test-IsAdministrator { $false }
            # Under -WhatIf the dispatcher is still called, but $WhatIfPreference propagates so the
            # appliers change nothing and return Skipped preview results.
            Mock Invoke-OnlineCatalogEntry {
                param($Entry, $Architecture, $Scope)
                if (-not $WhatIfPreference) { throw 'preview run must not perform real changes' }
                [pscustomobject]@{ PSTypeName = 'WindowsIsoMaker.ChangeResult'; Id = $Entry.Id; Type = $Entry.Type; Status = 'Skipped'; Reason = 'Preview'; Citation = $Entry.Citation }
            }

            $report = Invoke-PostInstallSetup -Profile opinionated -Architecture amd64 -WhatIf -NoReport
            $report.Outcome | Should -Be 'Preview'
            $report.ResolvedConfig.Mode | Should -Be 'PostInstall'
            $report.ResolvedConfig.SelectedCatalog.Count | Should -BeGreaterThan 0
            $report.Skipped.Count | Should -Be $report.ResolvedConfig.SelectedCatalog.Count
        }
    }

    It 'applies every selected entry through the dispatcher and returns a Succeeded report' {
        InModuleScope WindowsIsoMaker {
            Mock Test-IsAdministrator { $true }
            Mock Write-WimRegistryTattoo { }
            Mock Invoke-OnlineCatalogEntry {
                param($Entry, $Architecture, $Scope)
                [pscustomobject]@{ PSTypeName = 'WindowsIsoMaker.ChangeResult'; Id = $Entry.Id; Type = $Entry.Type; Status = 'Applied'; Reason = 'ok'; Citation = $Entry.Citation }
            }

            $report = Invoke-PostInstallSetup -Profile default -Architecture amd64 -NoReport
            $report.Outcome | Should -Be 'Succeeded'
            $report.Applied.Count | Should -Be $report.ResolvedConfig.SelectedCatalog.Count
            Should -Invoke Invoke-OnlineCatalogEntry -Times $report.ResolvedConfig.SelectedCatalog.Count
            Should -Invoke Write-WimRegistryTattoo -Times 1
        }
    }

    It 'does not write the provenance tattoo under -WhatIf (preview)' {
        InModuleScope WindowsIsoMaker {
            Mock Test-IsAdministrator { $true }
            Mock Write-WimRegistryTattoo { }
            Mock Invoke-OnlineCatalogEntry {
                param($Entry, $Architecture, $Scope)
                [pscustomobject]@{ PSTypeName = 'WindowsIsoMaker.ChangeResult'; Id = $Entry.Id; Type = $Entry.Type; Status = 'Applied'; Reason = 'would change'; Citation = $Entry.Citation }
            }

            $null = Invoke-PostInstallSetup -Profile default -Architecture amd64 -WhatIf -NoReport
            Should -Invoke Write-WimRegistryTattoo -Times 0
        }
    }

    It 'reports Failed when any entry fails to apply' {
        InModuleScope WindowsIsoMaker {
            Mock Test-IsAdministrator { $true }
            Mock Invoke-OnlineCatalogEntry {
                param($Entry, $Architecture, $Scope)
                [pscustomobject]@{ PSTypeName = 'WindowsIsoMaker.ChangeResult'; Id = $Entry.Id; Type = $Entry.Type; Status = 'Failed'; Reason = 'boom'; Citation = $Entry.Citation }
            }

            $report = Invoke-PostInstallSetup -Profile minimal -Architecture amd64 -NoReport
            $report.Outcome | Should -Be 'Failed'
        }
    }

    It 'auto-detects the architecture when not supplied' {
        InModuleScope WindowsIsoMaker {
            Mock Test-IsAdministrator { $true }
            Mock Write-WimRegistryTattoo { }
            Mock Get-OnlineArchitecture { 'arm64' }
            Mock Invoke-OnlineCatalogEntry {
                param($Entry, $Architecture, $Scope)
                [pscustomobject]@{ PSTypeName = 'WindowsIsoMaker.ChangeResult'; Id = $Entry.Id; Type = $Entry.Type; Status = 'Applied'; Reason = 'ok'; Citation = $Entry.Citation }
            }

            $report = Invoke-PostInstallSetup -Profile minimal -NoReport
            $report.ResolvedConfig.Architecture | Should -Be 'arm64'
            Should -Invoke Get-OnlineArchitecture -Times 1
        }
    }

    It 'runs the staged WSL installer and attaches its result when -InstallWsl is set' {
        InModuleScope WindowsIsoMaker {
            Mock Test-IsAdministrator { $true }
            Mock Write-WimRegistryTattoo { }
            Mock Invoke-OnlineCatalogEntry {
                param($Entry, $Architecture, $Scope)
                [pscustomobject]@{ PSTypeName = 'WindowsIsoMaker.ChangeResult'; Id = $Entry.Id; Type = $Entry.Type; Status = 'Applied'; Reason = 'ok'; Citation = $Entry.Citation }
            }
            Mock Install-WslDistribution {
                [pscustomobject]@{ PSTypeName = 'WindowsIsoMaker.WslInstallResult'; Distribution = 'Debian'; Servicing = 'Store'; Stage = 'RebootRequired'; RebootRequired = $true; DistributionInstalled = $false; Message = 'reboot' }
            }

            $report = Invoke-PostInstallSetup -Profile minimal -Architecture amd64 -InstallWsl -WslDistribution Debian -NoReport
            Should -Invoke Install-WslDistribution -Times 1 -ParameterFilter { $Distribution -eq 'Debian' }
            $report.Wsl.Stage | Should -Be 'RebootRequired'
            $report.Wsl.RebootRequired | Should -BeTrue
        }
    }

    It 'does not run the WSL installer when -InstallWsl is not set' {
        InModuleScope WindowsIsoMaker {
            Mock Test-IsAdministrator { $true }
            Mock Write-WimRegistryTattoo { }
            Mock Invoke-OnlineCatalogEntry {
                param($Entry, $Architecture, $Scope)
                [pscustomobject]@{ PSTypeName = 'WindowsIsoMaker.ChangeResult'; Id = $Entry.Id; Type = $Entry.Type; Status = 'Applied'; Reason = 'ok'; Citation = $Entry.Citation }
            }
            Mock Install-WslDistribution { throw 'must not run WSL install without -InstallWsl' }

            $report = Invoke-PostInstallSetup -Profile minimal -Architecture amd64 -NoReport
            Should -Invoke Install-WslDistribution -Times 0
            $report.PSObject.Properties.Name | Should -Not -Contain 'Wsl'
        }
    }

    It 'installs WSL by default when the opinionated profile is selected (no -InstallWsl needed)' {
        InModuleScope WindowsIsoMaker {
            Mock Test-IsAdministrator { $true }
            Mock Write-WimRegistryTattoo { }
            Mock Invoke-OnlineCatalogEntry {
                param($Entry, $Architecture, $Scope)
                [pscustomobject]@{ PSTypeName = 'WindowsIsoMaker.ChangeResult'; Id = $Entry.Id; Type = $Entry.Type; Status = 'Applied'; Reason = 'ok'; Citation = $Entry.Citation }
            }
            Mock Install-WslDistribution {
                [pscustomobject]@{ PSTypeName = 'WindowsIsoMaker.WslInstallResult'; Distribution = 'Debian'; Servicing = 'Store'; Stage = 'Done'; RebootRequired = $false; DistributionInstalled = $true; Message = 'done' }
            }

            $report = Invoke-PostInstallSetup -Profile opinionated -Architecture amd64 -NoReport
            Should -Invoke Install-WslDistribution -Times 1
            $report.Wsl.Stage | Should -Be 'Done'
        }
    }

    It 'skips WSL under the opinionated profile when -InstallWsl:$false is passed explicitly' {
        InModuleScope WindowsIsoMaker {
            Mock Test-IsAdministrator { $true }
            Mock Write-WimRegistryTattoo { }
            Mock Invoke-OnlineCatalogEntry {
                param($Entry, $Architecture, $Scope)
                [pscustomobject]@{ PSTypeName = 'WindowsIsoMaker.ChangeResult'; Id = $Entry.Id; Type = $Entry.Type; Status = 'Applied'; Reason = 'ok'; Citation = $Entry.Citation }
            }
            Mock Install-WslDistribution { throw 'must not run WSL install when explicitly opted out' }

            $report = Invoke-PostInstallSetup -Profile opinionated -Architecture amd64 -InstallWsl:$false -NoReport
            Should -Invoke Install-WslDistribution -Times 0
            $report.PSObject.Properties.Name | Should -Not -Contain 'Wsl'
        }
    }

    It 'previews the WSL installer under -WhatIf (passes -WhatIf through, no changes)' {
        InModuleScope WindowsIsoMaker {
            Mock Test-IsAdministrator { $true }
            Mock Write-WimRegistryTattoo { }
            Mock Invoke-OnlineCatalogEntry {
                param($Entry, $Architecture, $Scope)
                [pscustomobject]@{ PSTypeName = 'WindowsIsoMaker.ChangeResult'; Id = $Entry.Id; Type = $Entry.Type; Status = 'Skipped'; Reason = 'Preview'; Citation = $Entry.Citation }
            }
            Mock Install-WslDistribution {
                if (-not $WhatIfPreference) { throw 'WSL install must be a no-op under -WhatIf' }
                [pscustomobject]@{ PSTypeName = 'WindowsIsoMaker.WslInstallResult'; Distribution = 'Debian'; Stage = 'Platform'; RebootRequired = $false; DistributionInstalled = $false; Message = 'preview' }
            }

            $report = Invoke-PostInstallSetup -Profile minimal -Architecture amd64 -InstallWsl -WhatIf -NoReport
            $report.Outcome | Should -Be 'Preview'
            Should -Invoke Install-WslDistribution -Times 1
            $report.Wsl.Stage | Should -Be 'Platform'
        }
    }
}
