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
