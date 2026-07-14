#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for the VMware Workstation boot-test provider and the VMware path of Invoke-VmBootTest.
    Every external call (vmrun / vmware-vdiskmanager / winget / Read-Host) is behind a mockable seam.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force

    $script:FakeIso = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-vmw-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.iso')
    'iso' | Set-Content -LiteralPath $script:FakeIso
}
AfterAll {
    if (Test-Path $script:FakeIso) { Remove-Item $script:FakeIso -Force }
}

Describe 'New-VMwareVmxConfiguration' {
    It 'provisions EFI + Secure Boot + software TPM + CD-ROM first boot' {
        InModuleScope WindowsIsoMaker {
            $vmx = New-VMwareVmxConfiguration -VmName 'wim-x' -IsoPath 'C:\out\win11.iso' -VmdkFileName 'wim-x.vmdk' -ConnectNetwork
            $vmx | Should -Match 'firmware = "efi"'
            $vmx | Should -Match 'uefi\.secureBoot\.enabled = "TRUE"'
            $vmx | Should -Match 'managedvm\.autoAddVTPM = "software"'
            $vmx | Should -Match 'guestOS = "windows11-64"'
            $vmx | Should -Match 'bios\.bootOrder = "cdrom,hdd"'
            $vmx | Should -Match 'sata0:0\.fileName = "C:\\out\\win11\.iso"'
            $vmx | Should -Match 'nvme0:0\.fileName = "wim-x\.vmdk"'
            $vmx | Should -Match 'numvcpus = "2"'
            $vmx | Should -Match 'memsize = "4096"'
        }
    }

    It 'connects the NAT NIC when -ConnectNetwork is set and disconnects it otherwise' {
        InModuleScope WindowsIsoMaker {
            (New-VMwareVmxConfiguration -VmName 'a' -IsoPath 'i.iso' -VmdkFileName 'a.vmdk' -ConnectNetwork) |
                Should -Match 'ethernet0\.startConnected = "TRUE"'
            (New-VMwareVmxConfiguration -VmName 'a' -IsoPath 'i.iso' -VmdkFileName 'a.vmdk') |
                Should -Match 'ethernet0\.startConnected = "FALSE"'
        }
    }
}

Describe 'Get-VMwareReadiness' {
    It 'is Ready when vmrun is found' {
        InModuleScope WindowsIsoMaker {
            Mock Get-VMwareInstallPath { [pscustomobject]@{ Installed = $true; InstallDirectory = 'C:\VMware'; VmrunPath = 'C:\VMware\vmrun.exe'; VdiskManagerPath = 'C:\VMware\vmware-vdiskmanager.exe'; VmwarePath = 'C:\VMware\vmware.exe' } }
            (Get-VMwareReadiness).Ready | Should -BeTrue
        }
    }

    It 'is not Ready and names the winget command when VMware is missing' {
        InModuleScope WindowsIsoMaker {
            Mock Get-VMwareInstallPath { [pscustomobject]@{ Installed = $false; InstallDirectory = $null; VmrunPath = $null; VdiskManagerPath = $null; VmwarePath = $null } }
            $r = Get-VMwareReadiness
            $r.Ready | Should -BeFalse
            $r.Reason | Should -Match 'winget install --id VMware\.WorkstationPro'
            $r.Reason | Should -Match 'getworkstation'
        }
    }
}

Describe 'Install-VMwareWorkstation' {
    It 'returns true immediately when VMware is already installed' {
        InModuleScope WindowsIsoMaker {
            Mock Get-VMwareInstallPath { [pscustomobject]@{ Installed = $true; InstallDirectory = 'C:\VMware'; VmrunPath = 'C:\VMware\vmrun.exe'; VdiskManagerPath = $null; VmwarePath = $null } }
            Mock Invoke-Winget { throw 'should not run' }
            Install-VMwareWorkstation | Should -BeTrue
        }
    }

    It 'runs winget on consent and reports success when VMware then appears' {
        InModuleScope WindowsIsoMaker {
            $script:calls = 0
            Mock Get-VMwareInstallPath {
                $script:calls++
                $installed = $script:calls -gt 1  # not installed on first probe, installed after winget
                [pscustomobject]@{ Installed = $installed; InstallDirectory = 'C:\VMware'; VmrunPath = $(if ($installed) { 'C:\VMware\vmrun.exe' } else { $null }); VdiskManagerPath = $null; VmwarePath = $null }
            }
            Mock Read-VMwareInstallConsent { $true }
            Mock Invoke-Winget { [pscustomobject]@{ ExitCode = 0; Output = 'ok' } }
            Install-VMwareWorkstation | Should -BeTrue
            Should -Invoke Invoke-Winget -Times 1 -Exactly
        }
    }

    It 'prints guidance and does not run winget when declined' {
        InModuleScope WindowsIsoMaker {
            Mock Get-VMwareInstallPath { [pscustomobject]@{ Installed = $false; InstallDirectory = $null; VmrunPath = $null; VdiskManagerPath = $null; VmwarePath = $null } }
            Mock Read-VMwareInstallConsent { $false }
            Mock Invoke-Winget { throw 'should not run' }
            Install-VMwareWorkstation | Should -BeFalse
            Should -Invoke Invoke-Winget -Times 0 -Exactly
        }
    }

    It 'never prompts in -NonInteractive mode' {
        InModuleScope WindowsIsoMaker {
            Mock Get-VMwareInstallPath { [pscustomobject]@{ Installed = $false; InstallDirectory = $null; VmrunPath = $null; VdiskManagerPath = $null; VmwarePath = $null } }
            Mock Read-VMwareInstallConsent { throw 'should not prompt' }
            Mock Invoke-Winget { throw 'should not run' }
            Install-VMwareWorkstation -NonInteractive | Should -BeFalse
            Should -Invoke Read-VMwareInstallConsent -Times 0 -Exactly
        }
    }
}

Describe 'New-VMwareBootTestVm' {
    It 'writes the vmx, threads -ConnectNetwork into it, and starts headless via vmrun' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            $vmDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-vmw-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $vmx = Join-Path $vmDir 'vm.vmx'
            $vhd = Join-Path $vmDir 'vm.vmdk'
            Mock Get-VMwareInstallPath { [pscustomobject]@{ Installed = $true; InstallDirectory = 'C:\VMware'; VmrunPath = 'C:\VMware\vmrun.exe'; VdiskManagerPath = $null; VmwarePath = $null } }
            $script:startArgs = $null
            Mock Invoke-Vmrun { $script:startArgs = $Arguments; [pscustomobject]@{ ExitCode = 0; Output = '' } }
            try {
                New-VMwareBootTestVm -VmName 'vm' -IsoPath $Iso -VmxPath $vmx -VhdPath $vhd -ConnectNetwork
                Test-Path -LiteralPath $vmx | Should -BeTrue
                (Get-Content -Raw -LiteralPath $vmx) | Should -Match 'ethernet0\.startConnected = "TRUE"'
                $script:startArgs[0] | Should -Be 'start'
                $script:startArgs[-1] | Should -Be 'nogui'
            }
            finally {
                if (Test-Path $vmDir) { Remove-Item $vmDir -Recurse -Force }
            }
        }
    }

    It 'throws when VMware is not installed' {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            Mock Get-VMwareInstallPath { [pscustomobject]@{ Installed = $false; InstallDirectory = $null; VmrunPath = $null; VdiskManagerPath = $null; VmwarePath = $null } }
            { New-VMwareBootTestVm -VmName 'vm' -IsoPath $Iso -VmxPath 'C:\x\vm.vmx' -VhdPath 'C:\x\vm.vmdk' } |
                Should -Throw '*not installed*'
        }
    }
}

Describe 'Get-VMwareVmBootStatus' {
    It 'reports Running and a healthy heartbeat when tools are running' {
        InModuleScope WindowsIsoMaker {
            $vmx = Join-Path ([System.IO.Path]::GetTempPath()) 'wim-run\vm.vmx'
            Mock Invoke-Vmrun {
                if ($Arguments[0] -eq 'list') { return [pscustomobject]@{ ExitCode = 0; Output = "Total running VMs: 1`r`n$vmx" } }
                if ($Arguments[0] -eq 'checkToolsState') { return [pscustomobject]@{ ExitCode = 0; Output = "running`r`n" } }
                [pscustomobject]@{ ExitCode = 1; Output = '' }
            }
            $s = Get-VMwareVmBootStatus -VmName 'vm' -VmxPath $vmx
            $s.State | Should -Be 'Running'
            $s.HeartbeatHealthy | Should -BeTrue
        }
    }

    It 'reports Off when the VM is not in the running list' {
        InModuleScope WindowsIsoMaker {
            $vmx = Join-Path ([System.IO.Path]::GetTempPath()) 'wim-run\vm.vmx'
            Mock Invoke-Vmrun { [pscustomobject]@{ ExitCode = 0; Output = "Total running VMs: 0`r`n" } }
            (Get-VMwareVmBootStatus -VmName 'vm' -VmxPath $vmx).State | Should -Be 'Off'
        }
    }
}

Describe 'Stop/Remove-VMwareBootTestVm' {
    It 'stops and deletes via vmrun and removes the VM folder' {
        InModuleScope WindowsIsoMaker {
            $vmDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-rm-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $vmx = Join-Path $vmDir 'vm.vmx'
            New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
            'vmx' | Set-Content -LiteralPath $vmx
            Mock Get-VMwareInstallPath { [pscustomobject]@{ Installed = $true; InstallDirectory = 'C:\VMware'; VmrunPath = 'C:\VMware\vmrun.exe'; VdiskManagerPath = $null; VmwarePath = $null } }
            $script:cmds = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-Vmrun { $script:cmds.Add($Arguments[0]); [pscustomobject]@{ ExitCode = 0; Output = '' } }
            Remove-VMwareBootTestVm -VmxPath $vmx -VmDirectory $vmDir
            $script:cmds | Should -Contain 'stop'
            $script:cmds | Should -Contain 'deleteVM'
            Test-Path -LiteralPath $vmDir | Should -BeFalse
        }
    }
}

Describe 'Save-VMwareBootTestSetupLog' {
    It 'reports Inspected=$false when vmware-mount is unavailable (best-effort limit)' {
        InModuleScope WindowsIsoMaker {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-sv-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            $vmdk = Join-Path $tmp 'vm.vmdk'
            'disk' | Set-Content -LiteralPath $vmdk
            $dest = Join-Path $tmp 'diag'
            Mock Get-VMwareInstallPath { [pscustomobject]@{ Installed = $true; InstallDirectory = $tmp; VmrunPath = (Join-Path $tmp 'vmrun.exe'); VdiskManagerPath = $null; VmwarePath = $null } }
            try {
                $r = Save-VMwareBootTestSetupLog -VhdPath $vmdk -DestinationDirectory $dest
                $r.Inspected | Should -BeFalse
                @($r.Files).Count | Should -Be 0
            }
            finally {
                if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
            }
        }
    }

    It 'returns $null when the disk does not exist' {
        InModuleScope WindowsIsoMaker {
            Save-VMwareBootTestSetupLog -VhdPath 'C:\nope\missing.vmdk' -DestinationDirectory 'C:\nope\diag' | Should -BeNullOrEmpty
        }
    }
}

Describe 'Invoke-VmBootTest (VMware path)' {
    BeforeEach {
        InModuleScope WindowsIsoMaker -Parameters @{ Iso = $script:FakeIso } {
            param($Iso)
            $script:Iso = $Iso
            Mock Get-VMwareReadiness { [pscustomobject]@{ Ready = $true; Reason = 'ok' } }
            Mock New-VMwareBootTestVm { }
            Mock Remove-VMwareBootTestVm { }
            Mock Stop-VMwareBootTestVm { }
            Mock Start-VMwareVmConnect { }
            Mock Start-Sleep { }
        }
    }

    It 'passes via Heartbeat using the VMware seams' {
        InModuleScope WindowsIsoMaker {
            Mock Get-VMwareVmBootStatus { [pscustomobject]@{ State = 'Running'; Heartbeat = 'running'; HeartbeatHealthy = $true } }
            $r = Invoke-VmBootTest -IsoPath $script:Iso -Architecture amd64 -Hypervisor VMware
            $r.Passed | Should -BeTrue
            $r.Method | Should -Be 'Heartbeat'
            Should -Invoke New-VMwareBootTestVm -Times 1 -Exactly
            Should -Invoke Get-VMwareVmBootStatus -Times 1 -Exactly
        }
    }

    It 'defaults the VMware NIC to connected (NAT) when -ConnectNetwork is not passed' {
        InModuleScope WindowsIsoMaker {
            Mock Get-VMwareVmBootStatus { [pscustomobject]@{ State = 'Running'; Heartbeat = 'running'; HeartbeatHealthy = $true } }
            $null = Invoke-VmBootTest -IsoPath $script:Iso -Architecture amd64 -Hypervisor VMware
            Should -Invoke New-VMwareBootTestVm -Times 1 -Exactly -ParameterFilter { $ConnectNetwork -eq $true }
        }
    }

    It 'honours -ConnectNetwork:$false to force VMware offline' {
        InModuleScope WindowsIsoMaker {
            Mock Get-VMwareVmBootStatus { [pscustomobject]@{ State = 'Running'; Heartbeat = 'running'; HeartbeatHealthy = $true } }
            $null = Invoke-VmBootTest -IsoPath $script:Iso -Architecture amd64 -Hypervisor VMware -ConnectNetwork:$false
            Should -Invoke New-VMwareBootTestVm -Times 1 -Exactly -ParameterFilter { $ConnectNetwork -eq $false }
        }
    }

    It 'returns None and offers the install when VMware is not ready' {
        InModuleScope WindowsIsoMaker {
            Mock Get-VMwareReadiness { [pscustomobject]@{ Ready = $false; Reason = 'not installed' } }
            Mock Install-VMwareWorkstation { $false }
            Mock New-VMwareBootTestVm { throw 'should not create a VM' }
            $r = Invoke-VmBootTest -IsoPath $script:Iso -Architecture amd64 -Hypervisor VMware
            $r.Method | Should -Be 'None'
            Should -Invoke Install-VMwareWorkstation -Times 1 -Exactly
        }
    }

    It 'does NOT downgrade a StayedRunning pass when the VMware disk could not be inspected' {
        InModuleScope WindowsIsoMaker {
            Mock Get-VMwareVmBootStatus { [pscustomobject]@{ State = 'Running'; Heartbeat = $null; HeartbeatHealthy = $false } }
            Mock Save-VMwareBootTestSetupLog { [pscustomobject]@{ Path = 'C:\out\diag'; Files = @(); SetupErrorTail = $null; Inspected = $false } }
            $r = Invoke-VmBootTest -IsoPath $script:Iso -Architecture amd64 -Hypervisor VMware -TimeoutSeconds 30 -PollIntervalSeconds 1 -MinRunningSeconds 1 -DiagnosticsPath 'C:\out\diag'
            $r.Passed | Should -BeTrue
            $r.Method | Should -Be 'StayedRunning'
        }
    }
}
