#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for Test-ImageIntegrity — the ISO structural inspection is mocked.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force

    $script:FakeIso = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-iso-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.iso')
    'iso' | Set-Content -LiteralPath $script:FakeIso
}
AfterAll {
    if (Test-Path $script:FakeIso) { Remove-Item $script:FakeIso -Force }
}

Describe 'Test-ImageIntegrity' {

    It 'passes when all structural checks and required boot files are present (amd64)' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            Mock Get-IsoStructuralInfo {
                [pscustomobject]@{
                    MediaReadable = $true; HasInstallImage = $true; ImageIndexValid = $true
                    BootFiles = @('boot\etfsboot.com', 'efi\microsoft\boot\efisys.bin')
                }
            }
            $result = Test-ImageIntegrity -IsoPath $Iso -Architecture amd64
            $result.Passed | Should -BeTrue
            $result.Boot | Should -BeNullOrEmpty
        }
    }

    It 'fails when a required boot file is missing' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            Mock Get-IsoStructuralInfo {
                [pscustomobject]@{
                    MediaReadable = $true; HasInstallImage = $true; ImageIndexValid = $true
                    BootFiles = @('efi\microsoft\boot\efisys.bin')  # missing etfsboot.com for amd64
                }
            }
            $result = Test-ImageIntegrity -IsoPath $Iso -Architecture amd64
            $result.Passed | Should -BeFalse
        }
    }

    It 'requires only UEFI boot for arm64' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            Mock Get-IsoStructuralInfo {
                [pscustomobject]@{
                    MediaReadable = $true; HasInstallImage = $true; ImageIndexValid = $true
                    BootFiles = @('efi\microsoft\boot\efisys.bin')
                }
            }
            $result = Test-ImageIntegrity -IsoPath $Iso -Architecture arm64
            $result.Passed | Should -BeTrue
        }
    }

    It 'does not run the VM boot test by default' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            Mock Get-IsoStructuralInfo {
                [pscustomobject]@{ MediaReadable = $true; HasInstallImage = $true; ImageIndexValid = $true; BootFiles = @('boot\etfsboot.com', 'efi\microsoft\boot\efisys.bin') }
            }
            Mock Invoke-VmBootTest { [pscustomobject]@{ Passed = $true; Detail = 'x' } }
            Test-ImageIntegrity -IsoPath $Iso -Architecture amd64 | Out-Null
            Should -Invoke Invoke-VmBootTest -Times 0
        }
    }
}

Describe 'Test-HeartbeatHealthy' {
    It 'treats OK-prefixed statuses as healthy and everything else as not' {
        InModuleScope WindowsIsoMaker {
            Test-HeartbeatHealthy -Status 'OK' | Should -BeTrue
            Test-HeartbeatHealthy -Status 'OkApplicationsHealthy' | Should -BeTrue
            Test-HeartbeatHealthy -Status 'ok' | Should -BeTrue
            Test-HeartbeatHealthy -Status 'No Contact' | Should -BeFalse
            Test-HeartbeatHealthy -Status 'Lost Communication' | Should -BeFalse
            Test-HeartbeatHealthy -Status '' | Should -BeFalse
            Test-HeartbeatHealthy -Status $null | Should -BeFalse
        }
    }
}

Describe 'Invoke-VmBootTest polling' {

    BeforeEach {
        InModuleScope WindowsIsoMaker {
            # Isolate the polling logic: provisioning/teardown/wait are seams, so no Hyper-V is
            # touched and no real time is spent.
            Mock Get-HyperVReadiness { [pscustomobject]@{ Ready = $true; Reason = 'Hyper-V is available for the VM boot test.' } }
            Mock Test-HyperVAvailable { $true }
            Mock New-BootTestVm { }
            Mock Remove-BootTestVm { }
            Mock Start-Sleep { }
        }
    }

    It 'reports None (no fail throw) when Hyper-V is unavailable' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            Mock Get-HyperVReadiness { [pscustomobject]@{ Ready = $false; Reason = "VM boot test cannot run because the Hyper-V platform is not active (the 'vmms' service is absent)." } }
            Mock Get-VmBootStatus { throw 'should not poll' }
            $r = Invoke-VmBootTest -IsoPath $Iso -Architecture amd64
            $r.Passed | Should -BeFalse
            $r.Method | Should -Be 'None'
            $r.Detail | Should -BeLike '*vmms*'
            Should -Invoke New-BootTestVm -Times 0
        }
    }

    It 'passes via Heartbeat as soon as the guest heartbeat is healthy' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            $script:poll = 0
            Mock Get-VmBootStatus {
                $script:poll++
                if ($script:poll -ge 2) { [pscustomobject]@{ State = 'Running'; Heartbeat = 'OK'; HeartbeatHealthy = $true } }
                else { [pscustomobject]@{ State = 'Running'; Heartbeat = $null; HeartbeatHealthy = $false } }
            }
            $r = Invoke-VmBootTest -IsoPath $Iso -Architecture amd64 -TimeoutSeconds 300 -PollIntervalSeconds 10 -MinRunningSeconds 90
            $r.Passed | Should -BeTrue
            $r.Method | Should -Be 'Heartbeat'
            Should -Invoke Remove-BootTestVm -Times 1
        }
    }

    It 'passes via StayedRunning after MinRunningSeconds without a heartbeat' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            Mock Get-VmBootStatus { [pscustomobject]@{ State = 'Running'; Heartbeat = $null; HeartbeatHealthy = $false } }
            $r = Invoke-VmBootTest -IsoPath $Iso -Architecture amd64 -TimeoutSeconds 300 -PollIntervalSeconds 10 -MinRunningSeconds 30
            $r.Passed | Should -BeTrue
            $r.Method | Should -Be 'StayedRunning'
            $r.ElapsedSeconds | Should -BeGreaterOrEqual 30
        }
    }

    It 'fails via BootReset when the VM leaves Running after having started' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            $script:poll = 0
            Mock Get-VmBootStatus {
                $script:poll++
                if ($script:poll -ge 3) { [pscustomobject]@{ State = 'Off'; Heartbeat = $null; HeartbeatHealthy = $false } }
                else { [pscustomobject]@{ State = 'Running'; Heartbeat = $null; HeartbeatHealthy = $false } }
            }
            $r = Invoke-VmBootTest -IsoPath $Iso -Architecture amd64 -TimeoutSeconds 300 -PollIntervalSeconds 10 -MinRunningSeconds 90
            $r.Passed | Should -BeFalse
            $r.Method | Should -Be 'BootReset'
            $r.State | Should -Be 'Off'
        }
    }

    It 'fails via Timeout when no pass signal is seen in the window' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            Mock Get-VmBootStatus { [pscustomobject]@{ State = 'Running'; Heartbeat = $null; HeartbeatHealthy = $false } }
            $r = Invoke-VmBootTest -IsoPath $Iso -Architecture amd64 -TimeoutSeconds 30 -PollIntervalSeconds 10 -MinRunningSeconds 1000
            $r.Passed | Should -BeFalse
            $r.Method | Should -Be 'Timeout'
            $r.ElapsedSeconds | Should -BeGreaterOrEqual 30
        }
    }

    It 'always tears down the VM even when polling throws' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            Mock Get-VmBootStatus { throw 'boom' }
            $r = Invoke-VmBootTest -IsoPath $Iso -Architecture amd64 -TimeoutSeconds 30 -PollIntervalSeconds 10
            $r.Passed | Should -BeFalse
            $r.Method | Should -Be 'Error'
            Should -Invoke Remove-BootTestVm -Times 1
        }
    }

    It 'holds the VM for manual testing when -KeepBootTestVm is set (before teardown)' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            Mock Get-VmBootStatus { [pscustomobject]@{ State = 'Running'; Heartbeat = 'OK'; HeartbeatHealthy = $true } }
            Mock Wait-BootTestInspection { }
            $r = Invoke-VmBootTest -IsoPath $Iso -Architecture amd64 -TimeoutSeconds 300 -PollIntervalSeconds 10 -MinRunningSeconds 90 -KeepBootTestVm
            $r.Passed | Should -BeTrue
            Should -Invoke Wait-BootTestInspection -Times 1
            Should -Invoke Remove-BootTestVm -Times 1
        }
    }

    It 'does not pause when -KeepBootTestVm is not set' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            Mock Get-VmBootStatus { [pscustomobject]@{ State = 'Running'; Heartbeat = 'OK'; HeartbeatHealthy = $true } }
            Mock Wait-BootTestInspection { }
            $null = Invoke-VmBootTest -IsoPath $Iso -Architecture amd64 -TimeoutSeconds 300 -PollIntervalSeconds 10 -MinRunningSeconds 90
            Should -Invoke Wait-BootTestInspection -Times 0
        }
    }
}

Describe 'Invoke-VmBootTest diagnostics harvesting' {

    BeforeEach {
        InModuleScope WindowsIsoMaker {
            Mock Get-HyperVReadiness { [pscustomobject]@{ Ready = $true; Reason = 'ok' } }
            Mock Test-HyperVAvailable { $true }
            Mock New-BootTestVm { }
            Mock Remove-BootTestVm { }
            Mock Stop-BootTestVm { }
            Mock Start-Sleep { }
            Mock Get-VmBootStatus { [pscustomobject]@{ State = 'Running'; Heartbeat = $null; HeartbeatHealthy = $false } }
        }
    }

    It 'harvests Setup logs and attaches Diagnostics when -DiagnosticsPath is set' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            Mock Save-BootTestSetupLog {
                [pscustomobject]@{ Path = 'C:\out\diag'; Files = @('C:\out\diag\a_setuperr.log'); SetupErrorTail = 'Error: 0x1234' }
            }
            $r = Invoke-VmBootTest -IsoPath $Iso -Architecture amd64 -TimeoutSeconds 30 -PollIntervalSeconds 10 -MinRunningSeconds 1000 -DiagnosticsPath 'C:\out\diag'
            Should -Invoke Save-BootTestSetupLog -Times 1
            $r.Diagnostics.Path | Should -Be 'C:\out\diag'
            $r.Diagnostics.SetupErrorTail | Should -Be 'Error: 0x1234'
        }
    }

    It 'stops the VM before harvesting (so the VHDX can be mounted offline)' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            $script:order = [System.Collections.Generic.List[string]]::new()
            Mock Stop-BootTestVm { $script:order.Add('stop') }
            Mock Save-BootTestSetupLog { $script:order.Add('harvest'); $null }
            $null = Invoke-VmBootTest -IsoPath $Iso -Architecture amd64 -TimeoutSeconds 30 -PollIntervalSeconds 10 -MinRunningSeconds 1000 -DiagnosticsPath 'C:\out\diag'
            $script:order[0] | Should -Be 'stop'
            $script:order[1] | Should -Be 'harvest'
        }
    }

    It 'nests harvested logs in a per-VM subfolder of -DiagnosticsPath' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            $script:capturedDest = $null
            Mock Save-BootTestSetupLog { $script:capturedDest = $DestinationDirectory; $null }
            $null = Invoke-VmBootTest -IsoPath $Iso -Architecture amd64 -TimeoutSeconds 30 -PollIntervalSeconds 10 -MinRunningSeconds 1000 -DiagnosticsPath 'C:\out\diag'
            $script:capturedDest | Should -Match ([regex]::Escape('C:\out\diag\wim-boottest-'))
        }
    }

    It 'does not harvest when -DiagnosticsPath is empty' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            Mock Save-BootTestSetupLog { }
            $null = Invoke-VmBootTest -IsoPath $Iso -Architecture amd64 -TimeoutSeconds 30 -PollIntervalSeconds 10 -MinRunningSeconds 1000
            Should -Invoke Save-BootTestSetupLog -Times 0
            Should -Invoke Stop-BootTestVm -Times 0
        }
    }

    It 'still tears down the VM when harvesting throws' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            Mock Save-BootTestSetupLog { throw 'mount failed' }
            $r = Invoke-VmBootTest -IsoPath $Iso -Architecture amd64 -TimeoutSeconds 30 -PollIntervalSeconds 10 -MinRunningSeconds 1000 -DiagnosticsPath 'C:\out\diag'
            $r.Method | Should -Be 'Timeout'
            Should -Invoke Remove-BootTestVm -Times 1
        }
    }
}

Describe 'Save-BootTestSetupLog' {

    It 'returns $null when the VHDX does not exist' {
        InModuleScope WindowsIsoMaker {
            $missing = Join-Path ([System.IO.Path]::GetTempPath()) ('no-such-' + [guid]::NewGuid().ToString('N') + '.vhdx')
            Save-BootTestSetupLog -VhdPath $missing -DestinationDirectory ([System.IO.Path]::GetTempPath()) | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-HyperVReadiness' {

    It 'is Ready when the module, service, and privilege are all present' {
        InModuleScope WindowsIsoMaker {
            Mock Test-HyperVAvailable { $true }
            Mock Get-HyperVServiceInfo { [pscustomobject]@{ Installed = $true; State = 'Running' } }
            Mock Test-HyperVPrivilege { [pscustomobject]@{ Elevated = $true; InHyperVAdmins = $false } }

            $r = Get-HyperVReadiness
            $r.Ready | Should -BeTrue
            $r.CmdletsAvailable | Should -BeTrue
            $r.ServiceState | Should -Be 'Running'
        }
    }

    It 'is Ready via Hyper-V Administrators membership without elevation' {
        InModuleScope WindowsIsoMaker {
            Mock Test-HyperVAvailable { $true }
            Mock Get-HyperVServiceInfo { [pscustomobject]@{ Installed = $true; State = 'Running' } }
            Mock Test-HyperVPrivilege { [pscustomobject]@{ Elevated = $false; InHyperVAdmins = $true } }

            (Get-HyperVReadiness).Ready | Should -BeTrue
        }
    }

    It 'reports the missing PowerShell module in the reason' {
        InModuleScope WindowsIsoMaker {
            Mock Test-HyperVAvailable { $false }
            Mock Get-HyperVServiceInfo { [pscustomobject]@{ Installed = $true; State = 'Running' } }
            Mock Test-HyperVPrivilege { [pscustomobject]@{ Elevated = $true; InHyperVAdmins = $false } }

            $r = Get-HyperVReadiness
            $r.Ready | Should -BeFalse
            $r.Reason | Should -BeLike '*PowerShell module is missing*'
        }
    }

    It 'reports the absent vmms service (staged feature / pending reboot) in the reason' {
        InModuleScope WindowsIsoMaker {
            Mock Test-HyperVAvailable { $true }
            Mock Get-HyperVServiceInfo { [pscustomobject]@{ Installed = $false; State = 'NotInstalled' } }
            Mock Test-HyperVPrivilege { [pscustomobject]@{ Elevated = $true; InHyperVAdmins = $false } }
            Mock Test-PendingReboot { $false }

            $r = Get-HyperVReadiness
            $r.Ready | Should -BeFalse
            $r.Reason | Should -BeLike "*'vmms' service is absent*"
        }
    }

    It 'tells the user to reboot when the feature is staged with a pending reboot' {
        InModuleScope WindowsIsoMaker {
            Mock Test-HyperVAvailable { $true }
            Mock Get-HyperVServiceInfo { [pscustomobject]@{ Installed = $false; State = 'NotInstalled' } }
            Mock Test-HyperVPrivilege { [pscustomobject]@{ Elevated = $true; InHyperVAdmins = $false } }
            Mock Test-PendingReboot { $true }

            $r = Get-HyperVReadiness
            $r.Ready | Should -BeFalse
            $r.PendingReboot | Should -BeTrue
            $r.Reason | Should -BeLike '*reboot is pending*'
        }
    }

    It 'reports insufficient privilege in the reason' {
        InModuleScope WindowsIsoMaker {
            Mock Test-HyperVAvailable { $true }
            Mock Get-HyperVServiceInfo { [pscustomobject]@{ Installed = $true; State = 'Running' } }
            Mock Test-HyperVPrivilege { [pscustomobject]@{ Elevated = $false; InHyperVAdmins = $false } }

            $r = Get-HyperVReadiness
            $r.Ready | Should -BeFalse
            $r.Reason | Should -BeLike '*Hyper-V Administrators*'
        }
    }
}
