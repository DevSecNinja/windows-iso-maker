#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for the Autounattend product-key (edition selector) behaviour:
    Get-GenericSetupProductKey and New-AutounattendXml rendering.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force
}

Describe 'Get-GenericSetupProductKey' {

    It 'returns the generic Pro key for "Pro"' {
        InModuleScope WindowsIsoMaker {
            Get-GenericSetupProductKey -Edition 'Pro' | Should -Be 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
        }
    }

    It 'normalizes edition variants to the same key' {
        InModuleScope WindowsIsoMaker {
            $expected = '2B87N-8KFHP-DKV6R-Y2C8J-PKCKT'
            Get-GenericSetupProductKey -Edition 'Pro N'          | Should -Be $expected
            Get-GenericSetupProductKey -Edition 'pro-n'          | Should -Be $expected
            Get-GenericSetupProductKey -Edition 'Windows 11 Pro N' | Should -Be $expected
        }
    }

    It 'returns the generic Home key for "Home"' {
        InModuleScope WindowsIsoMaker {
            Get-GenericSetupProductKey -Edition 'Home' | Should -Be 'TX9XD-98N7V-6WMQ6-BX7FG-H8Q99'
        }
    }

    It 'returns empty string for an unknown edition' {
        InModuleScope WindowsIsoMaker {
            Get-GenericSetupProductKey -Edition 'MegaUltra' | Should -BeNullOrEmpty
        }
    }
}

Describe 'New-AutounattendXml product key' {

    BeforeEach {
        $script:OutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("au-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.xml')
    }
    AfterEach {
        Remove-Item $script:OutPath -Force -ErrorAction SilentlyContinue
    }

    BeforeAll {
        function script:New-TestConfig {
            param($Edition = 'Pro', [hashtable]$Autounattend = @{})
            [pscustomobject]@{
                Edition      = $Edition
                Language     = 'en-US'
                Architecture = 'amd64'
                Autounattend = $Autounattend
            }
        }
    }

    It 'auto-injects the generic Pro key when ProductKey is not set' {
        $cfg = New-TestConfig -Edition 'Pro' -Autounattend @{}
        New-AutounattendXml -Config $cfg -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        $xml = Get-Content -LiteralPath $script:OutPath -Raw
        $xml | Should -Match '<ProductKey>'
        $xml | Should -Match ([regex]::Escape('VK7JG-NPHTM-C97JM-9MPGT-3V66T'))
    }

    It 'auto-picks the key matching the resolved edition' {
        $cfg = New-TestConfig -Edition 'Pro N' -Autounattend @{}
        New-AutounattendXml -Config $cfg -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        (Get-Content -LiteralPath $script:OutPath -Raw) | Should -Match ([regex]::Escape('2B87N-8KFHP-DKV6R-Y2C8J-PKCKT'))
    }

    It 'omits the ProductKey element when set to "none"' {
        $cfg = New-TestConfig -Edition 'Pro' -Autounattend @{ ProductKey = 'none' }
        New-AutounattendXml -Config $cfg -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        (Get-Content -LiteralPath $script:OutPath -Raw) | Should -Not -Match '<ProductKey>'
    }

    It 'uses an explicit product key verbatim' {
        $cfg = New-TestConfig -Edition 'Pro' -Autounattend @{ ProductKey = 'ABCDE-FGHIJ-KLMNO-PQRST-UVWXY' }
        New-AutounattendXml -Config $cfg -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        (Get-Content -LiteralPath $script:OutPath -Raw) | Should -Match ([regex]::Escape('ABCDE-FGHIJ-KLMNO-PQRST-UVWXY'))
    }

    It 'produces well-formed XML with the injected key' {
        $cfg = New-TestConfig -Edition 'Pro' -Autounattend @{}
        New-AutounattendXml -Config $cfg -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        { [xml](Get-Content -LiteralPath $script:OutPath -Raw) } | Should -Not -Throw
    }
}

Describe 'New-AutounattendXml ImageInstall (edition + install target)' {

    BeforeEach {
        $script:OutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("au-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.xml')
    }
    AfterEach {
        Remove-Item $script:OutPath -Force -ErrorAction SilentlyContinue
    }

    BeforeAll {
        function script:New-ImgConfig {
            param($Edition = 'Pro', [hashtable]$Autounattend = @{})
            [pscustomobject]@{ Edition = $Edition; Language = 'en-US'; Architecture = 'amd64'; Autounattend = $Autounattend }
        }
    }

    It 'derives the install.wim image name from the edition' {
        New-AutounattendXml -Config (New-ImgConfig -Edition 'Pro') -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        $xml = [xml](Get-Content -LiteralPath $script:OutPath -Raw)
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        $value = $xml.SelectSingleNode("//u:ImageInstall/u:OSImage/u:InstallFrom/u:MetaData/u:Value", $ns).InnerText
        $value | Should -Be 'Windows 11 Pro'
    }

    It 'does not double-prefix an edition that already names Windows' {
        New-AutounattendXml -Config (New-ImgConfig -Edition 'Windows 11 Enterprise') -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        (Get-Content -LiteralPath $script:OutPath -Raw) | Should -Match ([regex]::Escape('<Value>Windows 11 Enterprise</Value>'))
    }

    It 'honours an explicit ImageName override' {
        New-AutounattendXml -Config (New-ImgConfig -Edition 'Pro' -Autounattend @{ ImageName = 'Windows 11 Pro for Workstations' }) -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        (Get-Content -LiteralPath $script:OutPath -Raw) | Should -Match ([regex]::Escape('<Value>Windows 11 Pro for Workstations</Value>'))
    }

    It 'targets the Windows primary partition (DiskID 0, PartitionID 3)' {
        New-AutounattendXml -Config (New-ImgConfig -Edition 'Pro') -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        $xml = [xml](Get-Content -LiteralPath $script:OutPath -Raw)
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        $installTo = $xml.SelectSingleNode("//u:ImageInstall/u:OSImage/u:InstallTo", $ns)
        $installTo.DiskID | Should -Be '0'
        $installTo.PartitionID | Should -Be '3'
    }

    It 'formats the EFI system partition as FAT32 so the bootloader can be serviced (prevents 0x800703ED)' {
        New-AutounattendXml -Config (New-ImgConfig -Edition 'Pro') -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        $xml = [xml](Get-Content -LiteralPath $script:OutPath -Raw)
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        # Partition 1 (ESP) must be modified to FAT32; without this BFSVC ServicingBootFiles fails.
        $esp = $xml.SelectSingleNode("//u:ModifyPartitions/u:ModifyPartition[u:PartitionID='1']", $ns)
        $esp | Should -Not -BeNullOrEmpty
        $esp.Format | Should -Be 'FAT32'
        # Partition 3 (Windows) is NTFS and gets C:.
        $win = $xml.SelectSingleNode("//u:ModifyPartitions/u:ModifyPartition[u:PartitionID='3']", $ns)
        $win.Format | Should -Be 'NTFS'
        $win.Letter | Should -Be 'C'
        # Partition 2 (MSR) must NOT be formatted.
        $msr = $xml.SelectSingleNode("//u:ModifyPartitions/u:ModifyPartition[u:PartitionID='2']", $ns)
        $msr.SelectSingleNode('u:Format', $ns) | Should -BeNullOrEmpty
        # Guard against invalid children (e.g. <Type>, which belongs on CreatePartition only):
        # an unknown element makes Windows Setup reject the whole answer file and fall back to a
        # fully interactive install (product-key page). Only allow the documented ModifyPartition
        # elements.
        $allowed = @('Order', 'PartitionID', 'Format', 'Label', 'Letter', 'Active', 'Extend', 'TypeID')
        foreach ($mp in $xml.SelectNodes('//u:ModifyPartitions/u:ModifyPartition', $ns)) {
            foreach ($child in $mp.ChildNodes) {
                $allowed | Should -Contain $child.LocalName
            }
        }
    }
}

