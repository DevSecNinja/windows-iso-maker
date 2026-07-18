#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for Install-WslDistribution (the simplified, detect-driven WSL installer) and its
    servicing seams. All external seams (wsl.exe wrappers, elevation, pending-reboot, tattoo state,
    reboot) are mocked so these run on any platform.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force
}

Describe 'Install-WslDistribution' {

    Context 'Elevation and preview' {
        It 'throws when not elevated (real run)' {
            InModuleScope WindowsIsoMaker {
                Mock Test-IsAdministrator { $false }
                { Install-WslDistribution -Distribution Debian } | Should -Throw '*elevated*'
            }
        }

        It 'previews the plan under -WhatIf without elevation or side effects' {
            InModuleScope WindowsIsoMaker {
                Mock Test-IsAdministrator { $false }
                Mock Set-WimWslState { throw 'must not write state in preview' }
                Mock Install-WslDistributionPackage { throw 'must not install in preview' }
                Mock Update-WslKernel { throw 'must not update in preview' }

                $res = Install-WslDistribution -Distribution Debian -WhatIf
                $res.Stage | Should -Be 'Preview'
                $res.Distribution | Should -Be 'Debian'
                $res.Servicing | Should -Be 'Store'
            }
        }

        It 'reflects the selected servicing model in the preview message' {
            InModuleScope WindowsIsoMaker {
                Mock Test-IsAdministrator { $false }
                $res = Install-WslDistribution -Distribution Debian -WslServicing WebDownload -WhatIf
                $res.Servicing | Should -Be 'WebDownload'
                $res.Message | Should -BeLike '*--web-download*'
            }
        }
    }

    Context 'Idempotency' {
        It 'reports Done without installing when WSL is functional and the distro is present' {
            InModuleScope WindowsIsoMaker {
                Mock Test-IsAdministrator { $true }
                Mock Set-WimWslState { }
                Mock Test-WslCommandFunctional { $true }
                Mock Get-WslInstalledDistribution { @('Debian') }
                Mock Install-WslDistributionPackage { throw 'must not reinstall an existing distro' }
                Mock Update-WslKernel { throw 'must not update when already functional' }

                $res = Install-WslDistribution -Distribution Debian
                $res.Stage | Should -Be 'Done'
                $res.DistributionInstalled | Should -BeTrue
                Should -Invoke Install-WslDistributionPackage -Times 0
            }
        }

        It 'matches the installed distribution case-insensitively' {
            InModuleScope WindowsIsoMaker {
                Mock Test-IsAdministrator { $true }
                Mock Set-WimWslState { }
                Mock Test-WslCommandFunctional { $true }
                Mock Get-WslInstalledDistribution { @('debian') }
                Mock Install-WslDistributionPackage { throw 'must not reinstall' }

                (Install-WslDistribution -Distribution Debian).Stage | Should -Be 'Done'
            }
        }

        It 'is Done from the list pre-check alone (does not require --status to succeed)' {
            InModuleScope WindowsIsoMaker {
                Mock Test-IsAdministrator { $true }
                Mock Set-WimWslState { }
                Mock Test-PendingReboot { throw 'must short-circuit on the list pre-check before checking reboot' }
                Mock Get-WslInstalledDistribution { @('Debian') }
                Mock Install-WslDistributionPackage { throw 'must not reinstall an existing distro' }

                (Install-WslDistribution -Distribution Debian).Stage | Should -Be 'Done'
                Should -Invoke Install-WslDistributionPackage -Times 0
            }
        }
    }

    Context 'Pending reboot guard' {
        It 'asks to reboot when a reboot is pending, before touching wsl --install' {
            InModuleScope WindowsIsoMaker {
                Mock Test-IsAdministrator { $true }
                Mock Set-WimWslState { }
                Mock Test-WslCommandFunctional { $false }
                Mock Get-WslInstalledDistribution { @() }
                Mock Test-PendingReboot { $true }
                Mock Install-WslDistributionPackage { throw 'must not install while a reboot is pending' }
                Mock Restart-WindowsComputer { }

                $res = Install-WslDistribution -Distribution Debian
                $res.Stage | Should -Be 'RebootRequired'
                $res.RebootRequired | Should -BeTrue
                Should -Invoke Install-WslDistributionPackage -Times 0
                Should -Invoke Restart-WindowsComputer -Times 0
            }
        }

        It 'reboots automatically with -AutoReboot when a reboot is pending' {
            InModuleScope WindowsIsoMaker {
                Mock Test-IsAdministrator { $true }
                Mock Set-WimWslState { }
                Mock Test-WslCommandFunctional { $false }
                Mock Get-WslInstalledDistribution { @() }
                Mock Test-PendingReboot { $true }
                Mock Restart-WindowsComputer { }

                $res = Install-WslDistribution -Distribution Debian -AutoReboot
                $res.RebootRequired | Should -BeTrue
                Should -Invoke Restart-WindowsComputer -Times 1
            }
        }
    }

    Context 'Install + detect' {
        It 'runs wsl --install with the right distro/servicing when the distro is not yet present' {
            InModuleScope WindowsIsoMaker {
                Mock Test-IsAdministrator { $true }
                Mock Set-WimWslState { }
                Mock Test-PendingReboot { $false }
                Mock Test-WslCommandFunctional { $true }
                # Distro absent at the pre-check AND the final check (a --no-launch install).
                Mock Get-WslInstalledDistribution { @() }
                Mock Install-WslDistributionPackage { [pscustomobject]@{ ExitCode = 0; Output = @('Installing') } }
                Mock Update-WslKernel { throw 'must not need wsl --update when install made WSL functional' }

                $res = Install-WslDistribution -Distribution Debian
                $res.Stage | Should -Be 'Done'
                $res.DistributionInstalled | Should -BeTrue
                Should -Invoke Install-WslDistributionPackage -Times 1 -ParameterFilter { $Distribution -eq 'Debian' -and $Servicing -eq 'Store' }
            }
        }

        It 'reports Done after a --no-launch install even though the distro is not yet in wsl --list' {
            InModuleScope WindowsIsoMaker {
                Mock Test-IsAdministrator { $true }
                Mock Set-WimWslState { }
                Mock Test-PendingReboot { $false }
                Mock Test-WslCommandFunctional { $true }
                # --no-launch: the distro is installed but never appears in `wsl --list` here.
                Mock Get-WslInstalledDistribution { @() }
                Mock Install-WslDistributionPackage { [pscustomobject]@{ ExitCode = 0; Output = @('Installing') } }
                Mock Update-WslKernel { throw 'must not run wsl --update when WSL is functional' }

                $res = Install-WslDistribution -Distribution Debian
                $res.Stage | Should -Be 'Done'
                $res.DistributionInstalled | Should -BeTrue
                $res.Message | Should -BeLike '*first-time setup*'
            }
        }

        It 'treats an ERROR_ALREADY_EXISTS install result as idempotent success' {
            InModuleScope WindowsIsoMaker {
                Mock Test-IsAdministrator { $true }
                Mock Set-WimWslState { }
                Mock Test-PendingReboot { $false }
                Mock Test-WslCommandFunctional { $true }
                Mock Get-WslInstalledDistribution { @() }
                Mock Install-WslDistributionPackage { [pscustomobject]@{ ExitCode = -1; Output = @('Cannot create a file when that file already exists.', 'Error code: Wsl/InstallDistro/ERROR_ALREADY_EXISTS') } }
                Mock Update-WslKernel { throw 'must not run wsl --update when the distro already exists' }

                $res = Install-WslDistribution -Distribution Debian
                $res.Stage | Should -Be 'Done'
                $res.DistributionInstalled | Should -BeTrue
            }
        }

        It 'reports RebootRequired when the install signals a reboot (exit 3010) even if WSL is functional' {
            InModuleScope WindowsIsoMaker {
                Mock Test-IsAdministrator { $true }
                Mock Set-WimWslState { }
                Mock Test-PendingReboot { $false }
                Mock Test-WslCommandFunctional { $true }
                Mock Get-WslInstalledDistribution { @() }
                Mock Install-WslDistributionPackage { [pscustomobject]@{ ExitCode = 3010; Output = @('restart required') } }
                Mock Update-WslKernel { throw 'must not run wsl --update when WSL is functional' }
                Mock Restart-WindowsComputer { }

                $res = Install-WslDistribution -Distribution Debian
                $res.Stage | Should -Be 'RebootRequired'
                $res.RebootRequired | Should -BeTrue
            }
        }

        It 'passes the servicing model through to the install seam' {
            InModuleScope WindowsIsoMaker {
                Mock Test-IsAdministrator { $true }
                Mock Set-WimWslState { }
                Mock Test-PendingReboot { $false }
                Mock Test-WslCommandFunctional { $true }
                $script:listCalls = 0
                Mock Get-WslInstalledDistribution { $script:listCalls++; if ($script:listCalls -le 1) { @() } else { @('Debian') } }
                Mock Install-WslDistributionPackage { [pscustomobject]@{ ExitCode = 0; Output = @() } }
                Mock Update-WslKernel { [pscustomobject]@{ ExitCode = 0; Output = @() } }

                $null = Install-WslDistribution -Distribution Debian -WslServicing WebDownload
                Should -Invoke Install-WslDistributionPackage -Times 1 -ParameterFilter { $Servicing -eq 'WebDownload' }
            }
        }

        It 'self-heals the REGDB state with wsl --update when the install left WSL not functional (Store/WebDownload)' {
            InModuleScope WindowsIsoMaker {
                Mock Test-IsAdministrator { $true }
                Mock Set-WimWslState { }
                Mock Test-PendingReboot { $false }
                # Never becomes functional in this run -> reboot required at the end.
                Mock Test-WslCommandFunctional { $false }
                Mock Get-WslInstalledDistribution { @() }
                Mock Install-WslDistributionPackage { [pscustomobject]@{ ExitCode = 0; Output = @('Installing') } }
                Mock Update-WslKernel { [pscustomobject]@{ ExitCode = 0; Output = @('Updating') } }
                Mock Restart-WindowsComputer { }

                $res = Install-WslDistribution -Distribution Debian
                $res.Stage | Should -Be 'RebootRequired'
                Should -Invoke Update-WslKernel -Times 1 -ParameterFilter { $Servicing -eq 'Store' }
            }
        }

        It 'does NOT run wsl --update for Inbox servicing (Windows Update services the component)' {
            InModuleScope WindowsIsoMaker {
                Mock Test-IsAdministrator { $true }
                Mock Set-WimWslState { }
                Mock Test-PendingReboot { $false }
                Mock Test-WslCommandFunctional { $false }
                Mock Get-WslInstalledDistribution { @() }
                Mock Install-WslDistributionPackage { [pscustomobject]@{ ExitCode = 0; Output = @() } }
                Mock Update-WslKernel { throw 'must not run wsl --update for Inbox servicing' }
                Mock Restart-WindowsComputer { }

                $res = Install-WslDistribution -Distribution Debian -WslServicing Inbox
                $res.Stage | Should -Be 'RebootRequired'
                Should -Invoke Update-WslKernel -Times 0
            }
        }

        It 'throws when wsl --install returns a hard failure' {
            InModuleScope WindowsIsoMaker {
                Mock Test-IsAdministrator { $true }
                Mock Set-WimWslState { }
                Mock Test-PendingReboot { $false }
                Mock Test-WslCommandFunctional { $false }
                Mock Get-WslInstalledDistribution { @() }
                Mock Install-WslDistributionPackage { [pscustomobject]@{ ExitCode = 1; Output = @('boom') } }

                { Install-WslDistribution -Distribution Debian } | Should -Throw '*wsl --install*failed*'
            }
        }
    }

    Context 'Resume: persisted distribution' {
        It 'resumes with the persisted distribution when none is passed' {
            InModuleScope WindowsIsoMaker {
                Mock Test-IsAdministrator { $true }
                Mock Get-WimWslState { param($Name) if ($Name -eq 'Distribution') { 'Ubuntu' } else { $null } }
                Mock Set-WimWslState { }
                Mock Test-PendingReboot { $false }
                Mock Test-WslCommandFunctional { $true }
                Mock Get-WslInstalledDistribution { @('Ubuntu') }

                $res = Install-WslDistribution
                $res.Distribution | Should -Be 'Ubuntu'
                $res.Stage | Should -Be 'Done'
            }
        }
    }
}

Describe 'WSL servicing seams' {
    It 'Install-WslDistributionPackage adds --web-download for WebDownload servicing' {
        InModuleScope WindowsIsoMaker {
            $script:captured = $null
            Mock Invoke-WslExe { $script:captured = $Arguments; [pscustomobject]@{ ExitCode = 0; Output = @() } }
            $null = Install-WslDistributionPackage -Distribution Debian -Servicing WebDownload
            $script:captured | Should -Contain '--web-download'
            $script:captured | Should -Contain '--no-launch'
        }
    }

    It 'Install-WslDistributionPackage adds --inbox for Inbox servicing' {
        InModuleScope WindowsIsoMaker {
            $script:captured = $null
            Mock Invoke-WslExe { $script:captured = $Arguments; [pscustomobject]@{ ExitCode = 0; Output = @() } }
            $null = Install-WslDistributionPackage -Distribution Debian -Servicing Inbox
            $script:captured | Should -Contain '--inbox'
        }
    }

    It 'Install-WslDistributionPackage uses the plain Store form by default (no --web-download/--inbox)' {
        InModuleScope WindowsIsoMaker {
            $script:captured = $null
            Mock Invoke-WslExe { $script:captured = $Arguments; [pscustomobject]@{ ExitCode = 0; Output = @() } }
            $null = Install-WslDistributionPackage -Distribution Debian
            $script:captured | Should -Not -Contain '--web-download'
            $script:captured | Should -Not -Contain '--inbox'
        }
    }

    It 'Update-WslKernel adds --web-download for WebDownload servicing' {
        InModuleScope WindowsIsoMaker {
            $script:captured = $null
            Mock Invoke-WslExe { $script:captured = $Arguments; [pscustomobject]@{ ExitCode = 0; Output = @() } }
            $null = Update-WslKernel -Servicing WebDownload
            $script:captured | Should -Contain '--web-download'
        }
    }

    It 'Get-WslInstalledDistribution strips NUL bytes and blank lines from wsl output' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-WslExe { [pscustomobject]@{ ExitCode = 0; Output = @("Debian`0", '', '  Ubuntu  ') } }
            $distros = Get-WslInstalledDistribution
            $distros | Should -Contain 'Debian'
            $distros | Should -Contain 'Ubuntu'
            $distros | Should -Not -Contain ''
        }
    }

    It 'Get-WslInstalledDistribution returns empty when wsl exits non-zero' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-WslExe { [pscustomobject]@{ ExitCode = 1; Output = @('error') } }
            @(Get-WslInstalledDistribution).Count | Should -Be 0
        }
    }

    It 'Test-WslCommandFunctional maps exit 0 to functional and non-zero to not' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-WslExe { [pscustomobject]@{ ExitCode = 0; Output = @(); TimedOut = $false } }
            Test-WslCommandFunctional | Should -BeTrue
            Mock Invoke-WslExe { [pscustomobject]@{ ExitCode = -1; Output = @('REGDB_E_CLASSNOTREG'); TimedOut = $false } }
            Test-WslCommandFunctional | Should -BeFalse
        }
    }

    It 'detection calls request a bounded timeout so a hung wsl.exe cannot stall the run' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-WslExe { [pscustomobject]@{ ExitCode = 0; Output = @(); TimedOut = $false } }
            $null = Test-WslCommandFunctional
            $null = Get-WslInstalledDistribution
            Should -Invoke Invoke-WslExe -Times 2 -ParameterFilter { $TimeoutSeconds -gt 0 }
        }
    }

    It 'Test-WslCommandFunctional treats a timeout (non-zero exit) as not functional' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-WslExe { [pscustomobject]@{ ExitCode = 258; Output = @('did not respond'); TimedOut = $true } }
            Test-WslCommandFunctional | Should -BeFalse
        }
    }

    It 'the long-running install/update seams do NOT impose a timeout (unbounded)' {
        InModuleScope WindowsIsoMaker {
            Mock Invoke-WslExe { [pscustomobject]@{ ExitCode = 0; Output = @(); TimedOut = $false } }
            $null = Install-WslDistributionPackage -Distribution Debian
            $null = Update-WslKernel -Servicing Store
            Should -Invoke Invoke-WslExe -Times 2 -ParameterFilter { -not $TimeoutSeconds }
        }
    }
}
