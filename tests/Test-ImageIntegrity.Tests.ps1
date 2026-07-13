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
            Mock Test-HyperVAvailable { $true }
            Mock New-BootTestVm { }
            Mock Remove-BootTestVm { }
            Mock Start-Sleep { }
        }
    }

    It 'reports None (no fail throw) when Hyper-V is unavailable' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            Mock Test-HyperVAvailable { $false }
            Mock Get-VmBootStatus { throw 'should not poll' }
            $r = Invoke-VmBootTest -IsoPath $Iso -Architecture amd64
            $r.Passed | Should -BeFalse
            $r.Method | Should -Be 'None'
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
}
