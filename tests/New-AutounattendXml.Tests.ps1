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
