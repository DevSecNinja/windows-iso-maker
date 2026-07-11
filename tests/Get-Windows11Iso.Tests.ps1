#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for Get-Windows11Iso (Fido wrapper) — all Fido/download calls are mocked.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force
}

Describe 'Get-Windows11Iso' {

    Context 'IsoPath override (skip download)' {
        BeforeAll {
            $script:FakeIso = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-iso-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.iso')
            'not-a-real-iso' | Set-Content -LiteralPath $script:FakeIso
        }
        AfterAll {
            if (Test-Path $script:FakeIso) { Remove-Item $script:FakeIso -Force }
        }

        It 'uses the provided ISO and does not call Fido' {
            InModuleScope WindowsIsoMaker -Parameters @{ FakeIso = $script:FakeIso } {
                param($FakeIso)
                Mock Invoke-FidoUrlResolver { throw 'Fido should not be called' }
                $result = Get-Windows11Iso -Architecture amd64 -IsoPath $FakeIso
                $result.Verified | Should -BeTrue
                $result.Path | Should -Be ((Resolve-Path $FakeIso).Path)
                $result.Sha256 | Should -Not -BeNullOrEmpty
                Should -Invoke Invoke-FidoUrlResolver -Times 0
            }
        }
    }

    Context 'Fido argument mapping' {
        It 'maps amd64 -> x64 and en-US -> English in the Fido arguments' {
            InModuleScope WindowsIsoMaker {
                Mock Invoke-FidoUrlResolver { 'https://software.download.microsoft.com/fake/win11.iso' }
                Mock Invoke-IsoDownload { param($Url, $Destination) 'iso' | Set-Content -LiteralPath $Destination }
                $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-dl-" + [guid]::NewGuid().ToString('N').Substring(0, 6))

                Get-Windows11Iso -Architecture amd64 -Language en-US -OutputPath $tmp | Out-Null

                Should -Invoke Invoke-FidoUrlResolver -Times 1 -ParameterFilter {
                    ($Arguments -contains 'x64') -and ($Arguments -contains 'English') -and ($Arguments -contains '11')
                }
                Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'maps arm64 -> Arm64' {
            InModuleScope WindowsIsoMaker {
                Mock Invoke-FidoUrlResolver { 'https://software.download.microsoft.com/fake/win11arm.iso' }
                Mock Invoke-IsoDownload { param($Url, $Destination) 'iso' | Set-Content -LiteralPath $Destination }
                $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-dl-" + [guid]::NewGuid().ToString('N').Substring(0, 6))

                Get-Windows11Iso -Architecture arm64 -OutputPath $tmp | Out-Null

                Should -Invoke Invoke-FidoUrlResolver -Times 1 -ParameterFilter { $Arguments -contains 'Arm64' }
                Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Unavailable combination' {
        It 'throws a terminating error when Fido returns no URL' {
            InModuleScope WindowsIsoMaker {
                Mock Invoke-FidoUrlResolver { $null }
                { Get-Windows11Iso -Architecture amd64 -Release 'does-not-exist' } | Should -Throw
            }
        }
    }
}
