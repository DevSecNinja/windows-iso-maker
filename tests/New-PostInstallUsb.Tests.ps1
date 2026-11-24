#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for New-PostInstallUsb - preparing a Windows 11 USB stick with the post-install toolkit.
.DESCRIPTION
    A temporary directory stands in for the USB stick, populated with the marker files real
    Windows Setup media carries. Because a plain directory has no drive letter, the removable-media
    probe reports "unknown" and is skipped, which keeps these tests runnable on any OS.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force

    function script:New-FakeUsb {
        param(
            [ValidateSet('amd64', 'arm64', 'none')]
            [string] $Architecture = 'amd64',
            [switch] $NoMedia
        )

        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("usb-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        if ($NoMedia) { return $root }

        New-Item -ItemType Directory -Path (Join-Path $root 'sources') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'sources/install.wim') -Value 'fake' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $root 'setup.exe') -Value 'fake' -Encoding Ascii

        $efiBoot = Join-Path $root 'efi/boot'
        New-Item -ItemType Directory -Path $efiBoot -Force | Out-Null
        switch ($Architecture) {
            'amd64' { Set-Content -LiteralPath (Join-Path $efiBoot 'bootx64.efi') -Value 'fake' -Encoding Ascii }
            'arm64' { Set-Content -LiteralPath (Join-Path $efiBoot 'bootaa64.efi') -Value 'fake' -Encoding Ascii }
            default { }
        }
        return $root
    }
}

Describe 'Test-WindowsSetupMedia' {

    It 'accepts a directory carrying setup.exe, sources\install.wim and a boot loader' {
        $usb = script:New-FakeUsb
        try {
            InModuleScope WindowsIsoMaker -Parameters @{ Usb = $usb } {
                param($Usb)
                $result = Test-WindowsSetupMedia -Path $Usb
                $result.IsSetupMedia | Should -BeTrue
                $result.ImageFormat  | Should -Be 'wim'
                $result.Missing      | Should -BeNullOrEmpty
            }
        }
        finally { Remove-Item $usb -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports every missing marker on an empty directory' {
        $usb = script:New-FakeUsb -NoMedia
        try {
            InModuleScope WindowsIsoMaker -Parameters @{ Usb = $usb } {
                param($Usb)
                $result = Test-WindowsSetupMedia -Path $Usb
                $result.IsSetupMedia | Should -BeFalse
                $result.Missing.Count | Should -Be 3
            }
        }
        finally { Remove-Item $usb -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-SetupMediaArchitecture' {

    It 'derives arm64 from bootaa64.efi' {
        $usb = script:New-FakeUsb -Architecture arm64
        try {
            InModuleScope WindowsIsoMaker -Parameters @{ Usb = $usb } {
                param($Usb)
                Get-SetupMediaArchitecture -Path $Usb | Should -Be 'arm64'
            }
        }
        finally { Remove-Item $usb -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'derives amd64 from bootx64.efi' {
        $usb = script:New-FakeUsb -Architecture amd64
        try {
            InModuleScope WindowsIsoMaker -Parameters @{ Usb = $usb } {
                param($Usb)
                Get-SetupMediaArchitecture -Path $Usb | Should -Be 'amd64'
            }
        }
        finally { Remove-Item $usb -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'returns nothing when the media cannot be classified' {
        $usb = script:New-FakeUsb -Architecture none
        try {
            InModuleScope WindowsIsoMaker -Parameters @{ Usb = $usb } {
                param($Usb)
                Get-SetupMediaArchitecture -Path $Usb | Should -BeNullOrEmpty
            }
        }
        finally { Remove-Item $usb -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'New-PostInstallUsb' {

    BeforeEach { $script:Usb = script:New-FakeUsb }
    AfterEach { Remove-Item $script:Usb -Recurse -Force -ErrorAction SilentlyContinue }

    It 'stages the toolkit, the bootstrap and the first-logon answer file' {
        $result = New-PostInstallUsb -Path $script:Usb -Profile opinionated -InformationAction SilentlyContinue

        $result.Mode              | Should -Be 'FirstLogon'
        $result.Architecture      | Should -Be 'amd64'
        $result.MediaValidated    | Should -BeTrue
        $result.SelectedEntryCount | Should -BeGreaterThan 0
        $result.StagedFileCount   | Should -BeGreaterThan 0

        Test-Path (Join-Path $script:Usb 'windows-iso-maker/post-install.ps1')            | Should -BeTrue
        Test-Path (Join-Path $script:Usb 'windows-iso-maker/src/WindowsIsoMaker/WindowsIsoMaker.psd1') | Should -BeTrue
        Test-Path (Join-Path $script:Usb 'windows-iso-maker/config/build.config.psd1')    | Should -BeTrue
        Test-Path (Join-Path $script:Usb 'windows-iso-maker/Invoke-PostInstall.ps1')      | Should -BeTrue
        Test-Path (Join-Path $script:Usb 'windows-iso-maker/Invoke-PostInstall.cmd')      | Should -BeTrue
        Test-Path (Join-Path $script:Usb 'Autounattend.xml')                              | Should -BeTrue
    }

    It 'writes an answer file that only runs a first-logon command (never a disk layout)' {
        New-PostInstallUsb -Path $script:Usb -Profile default -InformationAction SilentlyContinue | Out-Null

        $xml = Get-Content -LiteralPath (Join-Path $script:Usb 'Autounattend.xml') -Raw
        $xml | Should -Match 'FirstLogonCommands'
        $xml | Should -Match 'Invoke-PostInstall.ps1'
        $xml | Should -Match 'processorArchitecture="amd64"'
        # The stock media must remain fully interactive: no install phase, no disk wipe.
        $xml | Should -Not -Match 'DiskConfiguration'
        $xml | Should -Not -Match 'WillWipeDisk'
        $xml | Should -Not -Match 'windowsPE'
        ([xml]$xml) | Should -Not -BeNullOrEmpty
    }

    It 'bakes the requested profile and catalog ids into the bootstrap' {
        New-PostInstallUsb -Path $script:Usb -Profile gaming, opinionated -EnableCatalogId feature-wsl `
            -Scope CurrentUser -InformationAction SilentlyContinue | Out-Null

        $bootstrap = Get-Content -LiteralPath (Join-Path $script:Usb 'windows-iso-maker/Invoke-PostInstall.ps1') -Raw
        $bootstrap | Should -Match "Profile\s+=\s+@\('gaming', 'opinionated'\)"
        $bootstrap | Should -Match "EnableCatalogId\s+=\s+@\('feature-wsl'\)"
        $bootstrap | Should -Match "Scope\s+=\s+'CurrentUser'"
        # It must be valid PowerShell.
        { [scriptblock]::Create($bootstrap) } | Should -Not -Throw
    }

    It 'honours -Mode Toolkit by leaving the media without an answer file' {
        $result = New-PostInstallUsb -Path $script:Usb -Mode Toolkit -InformationAction SilentlyContinue

        $result.AutounattendPath | Should -BeNullOrEmpty
        Test-Path (Join-Path $script:Usb 'Autounattend.xml')                         | Should -BeFalse
        Test-Path (Join-Path $script:Usb 'windows-iso-maker/Invoke-PostInstall.ps1') | Should -BeTrue
    }

    It 'changes nothing under -WhatIf' {
        $result = New-PostInstallUsb -Path $script:Usb -WhatIf -InformationAction SilentlyContinue

        $result.Preview | Should -BeTrue
        Test-Path (Join-Path $script:Usb 'windows-iso-maker') | Should -BeFalse
        Test-Path (Join-Path $script:Usb 'Autounattend.xml')  | Should -BeFalse
    }

    It 'refuses a target that is not Windows installation media' {
        $empty = script:New-FakeUsb -NoMedia
        try {
            { New-PostInstallUsb -Path $empty -InformationAction SilentlyContinue } |
                Should -Throw '*does not look like Windows 11 installation media*'
        }
        finally { Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'stages onto non-Setup media when -Force is supplied' {
        $empty = script:New-FakeUsb -NoMedia
        try {
            $result = New-PostInstallUsb -Path $empty -Force -Architecture amd64 `
                -InformationAction SilentlyContinue -WarningAction SilentlyContinue
            $result.MediaValidated | Should -BeFalse
            Test-Path (Join-Path $empty 'windows-iso-maker/Invoke-PostInstall.ps1') | Should -BeTrue
        }
        finally { Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses to overwrite an existing Autounattend.xml without -Force' {
        Set-Content -LiteralPath (Join-Path $script:Usb 'Autounattend.xml') -Value '<unattend/>' -Encoding Ascii

        { New-PostInstallUsb -Path $script:Usb -InformationAction SilentlyContinue } |
            Should -Throw '*already exists*'

        (Get-Content -LiteralPath (Join-Path $script:Usb 'Autounattend.xml') -Raw).Trim() | Should -Be '<unattend/>'
    }

    It 'overwrites an existing Autounattend.xml with -Force' {
        Set-Content -LiteralPath (Join-Path $script:Usb 'Autounattend.xml') -Value '<unattend/>' -Encoding Ascii

        New-PostInstallUsb -Path $script:Usb -Force -InformationAction SilentlyContinue | Out-Null

        (Get-Content -LiteralPath (Join-Path $script:Usb 'Autounattend.xml') -Raw) | Should -Match 'FirstLogonCommands'
    }

    It 'takes the architecture from the media when not specified' {
        $arm = script:New-FakeUsb -Architecture arm64
        try {
            $result = New-PostInstallUsb -Path $arm -InformationAction SilentlyContinue
            $result.MediaArchitecture | Should -Be 'arm64'
            $result.Architecture      | Should -Be 'arm64'
            (Get-Content -LiteralPath (Join-Path $arm 'Autounattend.xml') -Raw) | Should -Match 'processorArchitecture="arm64"'
        }
        finally { Remove-Item $arm -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects an unknown catalog id before touching the stick' {
        { New-PostInstallUsb -Path $script:Usb -EnableCatalogId 'no-such-entry' -InformationAction SilentlyContinue } |
            Should -Throw

        Test-Path (Join-Path $script:Usb 'windows-iso-maker') | Should -BeFalse
    }

    It 'is idempotent - re-staging replaces the toolkit cleanly' {
        New-PostInstallUsb -Path $script:Usb -Force -InformationAction SilentlyContinue | Out-Null
        $strayFile = Join-Path $script:Usb 'windows-iso-maker/stray.txt'
        Set-Content -LiteralPath $strayFile -Value 'stale' -Encoding Ascii

        New-PostInstallUsb -Path $script:Usb -Force -InformationAction SilentlyContinue | Out-Null

        Test-Path $strayFile | Should -BeFalse
        Test-Path (Join-Path $script:Usb 'windows-iso-maker/Invoke-PostInstall.ps1') | Should -BeTrue
    }

    It 'uses a custom toolkit folder name in both the stick layout and the answer file' {
        New-PostInstallUsb -Path $script:Usb -ToolkitFolder 'wim' -InformationAction SilentlyContinue | Out-Null

        Test-Path (Join-Path $script:Usb 'wim/Invoke-PostInstall.ps1') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $script:Usb 'Autounattend.xml') -Raw) | Should -Match 'wim\\Invoke-PostInstall.ps1'
    }

    It 'refuses the root of a fixed drive' -Skip:($env:OS -ne 'Windows_NT') {
        { New-PostInstallUsb -Path "$env:SystemDrive\" -InformationAction SilentlyContinue } |
            Should -Throw '*root of a FIXED drive*'
    }
}

Describe 'Get-UsbTargetInfo volume probing' {

    It 'reports a removable volume from Win32_LogicalDisk DriveType 2' {
        InModuleScope WindowsIsoMaker {
            Mock Get-CimInstance -MockWith {
                [pscustomobject]@{ DriveType = 2; VolumeName = 'WIN11'; FileSystem = 'FAT32'; FreeSpace = [int64]8GB }
            } -ParameterFilter { $ClassName -eq 'Win32_LogicalDisk' }

            $info = Get-UsbTargetInfo -Path 'E:'
            $info.Path          | Should -Be 'E:\'
            $info.IsVolumeRoot  | Should -BeTrue
            $info.IsRemovable   | Should -BeTrue
            $info.Label         | Should -Be 'WIN11'
            $info.FreeSpaceByte | Should -Be ([int64]8GB)
        }
    }

    It 'treats a fixed-reporting volume on a USB bus as removable (USB SSD)' {
        InModuleScope WindowsIsoMaker {
            Mock Get-CimInstance -MockWith {
                [pscustomobject]@{ DriveType = 3; VolumeName = 'SSD'; FileSystem = 'NTFS'; FreeSpace = [int64]200GB }
            } -ParameterFilter { $ClassName -eq 'Win32_LogicalDisk' }
            Mock Get-CimInstance -MockWith { [pscustomobject]@{ DiskNumber = 2 } } -ParameterFilter { $ClassName -eq 'MSFT_Partition' }
            # MSFT_Disk BusType 7 = USB.
            Mock Get-CimInstance -MockWith { [pscustomobject]@{ BusType = 7 } } -ParameterFilter { $ClassName -eq 'MSFT_Disk' }

            $info = Get-UsbTargetInfo -Path 'E:'
            $info.DriveType   | Should -Be 3
            $info.BusType     | Should -Be 'USB'
            $info.IsRemovable | Should -BeTrue
        }
    }

    It 'keeps a genuinely internal disk marked as not removable' {
        InModuleScope WindowsIsoMaker {
            Mock Get-CimInstance -MockWith {
                [pscustomobject]@{ DriveType = 3; VolumeName = 'OS'; FileSystem = 'NTFS'; FreeSpace = [int64]100GB }
            } -ParameterFilter { $ClassName -eq 'Win32_LogicalDisk' }
            Mock Get-CimInstance -MockWith { [pscustomobject]@{ DiskNumber = 0 } } -ParameterFilter { $ClassName -eq 'MSFT_Partition' }
            # BusType 17 = NVMe.
            Mock Get-CimInstance -MockWith { [pscustomobject]@{ BusType = 17 } } -ParameterFilter { $ClassName -eq 'MSFT_Disk' }

            (Get-UsbTargetInfo -Path 'C:').IsRemovable | Should -BeFalse
        }
    }

    It 'reports unknown volume facts instead of throwing when CIM is unavailable' {
        InModuleScope WindowsIsoMaker {
            Mock Get-CimInstance -MockWith { throw 'no CIM here' }

            $info = Get-UsbTargetInfo -Path 'E:'
            $info.IsRemovable | Should -BeNullOrEmpty
            $info.DriveType   | Should -BeNullOrEmpty
        }
    }

    It 'does not treat a folder as a volume root' {
        InModuleScope WindowsIsoMaker {
            (Get-UsbTargetInfo -Path 'C:\some\folder').IsVolumeRoot | Should -BeFalse
        }
    }
}

Describe 'New-PostInstallDiscoveryCommand' {

    It 'emits valid PowerShell that targets the toolkit and logs either outcome' {
        InModuleScope WindowsIsoMaker {
            $command = New-PostInstallDiscoveryCommand -ToolkitFolder 'windows-iso-maker'

            $command | Should -BeLike 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "*"'
            $command | Should -Match 'windows-iso-maker\\Invoke-PostInstall\.ps1'
            $command | Should -Match 'bootstrap\.log'
            $command | Should -Match 'NO TOOLKIT FOUND'

            # The inner script is embedded in a -Command "..." argument, so it must not itself
            # contain a double quote, and it must parse.
            $inner = $command -replace '^[^"]*"', '' -replace '"$', ''
            $inner | Should -Not -Match '"'
            { [scriptblock]::Create($inner) } | Should -Not -Throw
        }
    }

    It 'rejects a toolkit folder containing quotes' {
        InModuleScope WindowsIsoMaker {
            { New-PostInstallDiscoveryCommand -ToolkitFolder "eviL'; rm -rf /" } | Should -Throw '*quote characters*'
        }
    }
}

Describe 'New-PostInstallBootstrapScript' {

    It 'reports loudly instead of exiting silently when elevation fails' {
        InModuleScope WindowsIsoMaker {
            $script = New-PostInstallBootstrapScript -Profile @('default') -Scope Both -Architecture amd64

            $script | Should -Match 'ELEVATION FAILED'
            $script | Should -Match 'NOTHING WAS APPLIED'
            $script | Should -Match 'Write-Breadcrumb'
            # A child that starts and then dies must not be reported as a success.
            $script | Should -Match 'ELEVATED RUN FAILED'
            $script | Should -Match '-PassThru'
            { [scriptblock]::Create($script) } | Should -Not -Throw
        }
    }

    It 'carries the WSL servicing settings when the opinionated profile implies WSL' {
        InModuleScope WindowsIsoMaker {
            $script = New-PostInstallBootstrapScript -Profile @('opinionated') -Scope Both -Architecture amd64 `
                -WslDistribution 'Ubuntu' -WslServicing 'WebDownload' -WslAutoReboot

            $script | Should -Match "WslDistribution\s+=\s+'Ubuntu'"
            $script | Should -Match "WslServicing\s+=\s+'WebDownload'"
            $script | Should -Match 'WslAutoReboot\s+=\s+\$true'
        }
    }

    It 'omits WSL settings for a profile that does not install WSL' {
        InModuleScope WindowsIsoMaker {
            $script = New-PostInstallBootstrapScript -Profile @('minimal') -Scope Both -Architecture amd64
            $script | Should -Not -Match 'WslServicing'
        }
    }
}

Describe 'ConvertTo-PowerShellLiteral' {

    It 'escapes embedded single quotes so a value cannot break out of the literal' {
        InModuleScope WindowsIsoMaker {
            ConvertTo-PowerShellLiteral -Value "it's" | Should -Be "'it''s'"
            ConvertTo-PowerShellLiteral -Value @("a'b", 'c') | Should -Be "@('a''b', 'c')"
            ConvertTo-PowerShellLiteral -Value $true | Should -Be '$true'
            ConvertTo-PowerShellLiteral -Value $null | Should -Be '$null'
        }
    }
}
