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

    It 'returns the generic (default retail) Home key for "Home"' {
        InModuleScope WindowsIsoMaker {
            Get-GenericSetupProductKey -Edition 'Home'             | Should -Be 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7'
            Get-GenericSetupProductKey -Edition 'Windows 11 Home'  | Should -Be 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7'
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

    It 'omits the ProductKey by default (generic fails 24H2; Home installs hands-off without one)' {
        $cfg = New-TestConfig -Edition 'Home' -Autounattend @{}
        New-AutounattendXml -Config $cfg -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        $xml = Get-Content -LiteralPath $script:OutPath -Raw
        $xml | Should -Not -Match '<ProductKey>'
        # Edition selection is still present via the image metadata.
        $xml | Should -Match ([regex]::Escape('<Value>Windows 11 Home</Value>'))
    }

    It 'renders no ProductKey and no interactive stop for a non-Home edition with no key (edition selected by image metadata)' {
        $cfg = New-TestConfig -Edition 'Pro' -Autounattend @{}
        New-AutounattendXml -Config $cfg -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        $xml = Get-Content -LiteralPath $script:OutPath -Raw
        $xml | Should -Not -Match '<ProductKey>'
        # Edition is still selected via the image metadata, so Setup does not stop at the key page.
        $xml | Should -Match ([regex]::Escape('<Value>Windows 11 Pro</Value>'))
    }

    It 'injects the generic key for the edition when ProductKey is "generic"' {
        $cfg = New-TestConfig -Edition 'Pro' -Autounattend @{ ProductKey = 'generic' }
        New-AutounattendXml -Config $cfg -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        $xml = Get-Content -LiteralPath $script:OutPath -Raw
        $xml | Should -Match '<ProductKey>'
        $xml | Should -Match ([regex]::Escape('VK7JG-NPHTM-C97JM-9MPGT-3V66T'))
    }

    It 'injects the generic (page-skipping) retail key for Home when ProductKey is "generic"' {
        $cfg = New-TestConfig -Edition 'Home' -Autounattend @{ ProductKey = 'generic' }
        New-AutounattendXml -Config $cfg -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        $xml = Get-Content -LiteralPath $script:OutPath -Raw
        $xml | Should -Match '<ProductKey>'
        $xml | Should -Match ([regex]::Escape('YTMG3-N6DKC-DKB77-7M9GH-8HVX7'))
    }

    It 'picks the generic key matching the resolved edition for "auto"' {
        $cfg = New-TestConfig -Edition 'Pro N' -Autounattend @{ ProductKey = 'auto' }
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

    It 'produces well-formed XML by default (no product key, Home)' {
        $cfg = New-TestConfig -Edition 'Home' -Autounattend @{}
        New-AutounattendXml -Config $cfg -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        { [xml](Get-Content -LiteralPath $script:OutPath -Raw) } | Should -Not -Throw
    }

    It 'produces well-formed XML with no ProductKey when set to "none"' {
        $cfg = New-TestConfig -Edition 'Pro' -Autounattend @{ ProductKey = 'none' }
        New-AutounattendXml -Config $cfg -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        { [xml](Get-Content -LiteralPath $script:OutPath -Raw) } | Should -Not -Throw
    }

    It 'applies the ProductKey in the specialize pass (not windowsPE) so 24H2 never fails windowsPE key validation' {
        $cfg = New-TestConfig -Edition 'Pro' -Autounattend @{ ProductKey = 'generic' }
        New-AutounattendXml -Config $cfg -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        $xml = [xml](Get-Content -LiteralPath $script:OutPath -Raw)
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        # Key lives under specialize / Microsoft-Windows-Shell-Setup.
        $specKey = $xml.SelectSingleNode("//u:settings[@pass='specialize']/u:component[@name='Microsoft-Windows-Shell-Setup']/u:ProductKey", $ns)
        $specKey | Should -Not -BeNullOrEmpty
        $specKey.InnerText | Should -Be 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
        # And NOT under windowsPE UserData (that is what 24H2 rejects on multi-edition media).
        $xml.SelectSingleNode("//u:settings[@pass='windowsPE']//u:UserData/u:ProductKey", $ns) | Should -BeNullOrEmpty
    }
}

Describe 'New-AutounattendXml account provisioning (local vs Entra join)' {

    BeforeEach {
        $script:OutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("au-acct-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.xml')
    }
    AfterEach {
        Remove-Item $script:OutPath -Force -ErrorAction SilentlyContinue
    }

    BeforeAll {
        function script:New-AcctConfig {
            param([hashtable]$Autounattend = @{})
            [pscustomobject]@{ Edition = 'Home'; Language = 'en-US'; Architecture = 'amd64'; Autounattend = $Autounattend }
        }
    }

    It 'creates a local admin account and hides the online-account screens by default (local mode)' {
        $cfg = New-AcctConfig -Autounattend @{ LocalAccountName = 'Admin' }
        New-AutounattendXml -Config $cfg -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        $xml = Get-Content -LiteralPath $script:OutPath -Raw
        $xml | Should -Match '<UserAccounts>'
        $xml | Should -Match ([regex]::Escape('<Name>Admin</Name>'))
        $xml | Should -Match ([regex]::Escape('<HideOnlineAccountScreens>true</HideOnlineAccountScreens>'))
        $xml | Should -Match ([regex]::Escape('<SkipUserOOBE>true</SkipUserOOBE>'))
    }

    It 'omits the local account and shows the online sign-in for AccountMode=entra (Entra join)' {
        $cfg = New-AcctConfig -Autounattend @{ AccountMode = 'entra' }
        New-AutounattendXml -Config $cfg -Architecture amd64 -OutputPath $script:OutPath | Out-Null
        $xml = Get-Content -LiteralPath $script:OutPath -Raw
        $xml | Should -Not -Match '<UserAccounts>'
        $xml | Should -Match ([regex]::Escape('<HideOnlineAccountScreens>false</HideOnlineAccountScreens>'))
        $xml | Should -Match ([regex]::Escape('<SkipUserOOBE>false</SkipUserOOBE>'))
        $xml | Should -Match ([regex]::Escape('<HideWirelessSetupInOOBE>false</HideWirelessSetupInOOBE>'))
    }

    It 'accepts azuread/entraid aliases for the Entra join mode' {
        foreach ($mode in 'entraid', 'azuread') {
            $cfg = New-AcctConfig -Autounattend @{ AccountMode = $mode }
            New-AutounattendXml -Config $cfg -Architecture amd64 -OutputPath $script:OutPath | Out-Null
            (Get-Content -LiteralPath $script:OutPath -Raw) | Should -Not -Match '<UserAccounts>'
        }
    }

    It 'warns and falls back to local for an unknown AccountMode' {
        $cfg = New-AcctConfig -Autounattend @{ AccountMode = 'bogus' }
        $warnings = New-AutounattendXml -Config $cfg -Architecture amd64 -OutputPath $script:OutPath 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        (Get-Content -LiteralPath $script:OutPath -Raw) | Should -Match '<UserAccounts>'
        "$warnings" | Should -Match 'AccountMode'
    }

    It 'produces well-formed XML in Entra mode' {
        $cfg = New-AcctConfig -Autounattend @{ AccountMode = 'entra' }
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
        # OSImage WillShowUI=Never keeps image selection hands-off on 24H2 too.
        $xml.SelectSingleNode("//u:ImageInstall/u:OSImage/u:WillShowUI", $ns).InnerText | Should -Be 'Never'
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

