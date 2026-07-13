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
                Mock Resolve-FidoScriptPath { 'stub-fido.ps1' }
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
                Mock Resolve-FidoScriptPath { 'stub-fido.ps1' }
                Mock Invoke-FidoUrlResolver { 'https://software.download.microsoft.com/fake/win11arm.iso' }
                Mock Invoke-IsoDownload { param($Url, $Destination) 'iso' | Set-Content -LiteralPath $Destination }
                $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-dl-" + [guid]::NewGuid().ToString('N').Substring(0, 6))

                Get-Windows11Iso -Architecture arm64 -OutputPath $tmp | Out-Null

                Should -Invoke Invoke-FidoUrlResolver -Times 1 -ParameterFilter { $Arguments -contains 'Arm64' }
                Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'ISO cache reuse' {
        It 'reuses an existing ISO and skips both Fido and download' {
            InModuleScope WindowsIsoMaker {
                Mock Invoke-FidoUrlResolver { throw 'Fido should not be called' }
                Mock Invoke-IsoDownload { throw 'Download should not happen' }
                $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-cache-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
                New-Item -ItemType Directory -Path $tmp -Force | Out-Null
                $cached = Join-Path $tmp 'Windows11-Pro-amd64-latest.iso'
                'cached-iso' | Set-Content -LiteralPath $cached

                $result = Get-Windows11Iso -Architecture amd64 -OutputPath $tmp

                $result.Verified | Should -BeTrue
                $result.Path | Should -Be ((Resolve-Path $cached).Path)
                $result.Sha256 | Should -Not -BeNullOrEmpty
                Should -Invoke Invoke-FidoUrlResolver -Times 0
                Should -Invoke Invoke-IsoDownload -Times 0
                Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 're-downloads when -Force is set even if a cached ISO exists' {
            InModuleScope WindowsIsoMaker {
                Mock Resolve-FidoScriptPath { 'stub-fido.ps1' }
                Mock Invoke-FidoUrlResolver { 'https://software.download.microsoft.com/fake/win11.iso' }
                Mock Invoke-IsoDownload { param($Url, $Destination) 'fresh' | Set-Content -LiteralPath $Destination }
                $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-cache-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
                New-Item -ItemType Directory -Path $tmp -Force | Out-Null
                'stale' | Set-Content -LiteralPath (Join-Path $tmp 'Windows11-Pro-amd64-latest.iso')

                Get-Windows11Iso -Architecture amd64 -OutputPath $tmp -Force | Out-Null

                Should -Invoke Invoke-FidoUrlResolver -Times 1
                Should -Invoke Invoke-IsoDownload -Times 1
                Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'throws when a cached ISO fails -ExpectedSha256 verification' {
            InModuleScope WindowsIsoMaker {
                Mock Invoke-FidoUrlResolver { throw 'Fido should not be called' }
                $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-cache-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
                New-Item -ItemType Directory -Path $tmp -Force | Out-Null
                'cached-iso' | Set-Content -LiteralPath (Join-Path $tmp 'Windows11-Pro-amd64-latest.iso')

                { Get-Windows11Iso -Architecture amd64 -OutputPath $tmp -ExpectedSha256 'DEADBEEF' } |
                    Should -Throw '*hash mismatch*'
                Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Unavailable combination' {
        It 'throws a terminating error when Fido returns no URL' {
            InModuleScope WindowsIsoMaker {
                Mock Resolve-FidoScriptPath { 'stub-fido.ps1' }
                Mock Invoke-FidoUrlResolver { $null }
                { Get-Windows11Iso -Architecture amd64 -Release 'does-not-exist' } | Should -Throw
            }
        }
    }

    Context 'Fido resolver retry behaviour' {
        BeforeAll {
            $script:FidoStub = Join-Path ([System.IO.Path]::GetTempPath()) ("fido-stub-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
            '# stub Fido for tests' | Set-Content -LiteralPath $script:FidoStub
        }
        AfterAll {
            if (Test-Path $script:FidoStub) { Remove-Item $script:FidoStub -Force }
        }

        It 'retries after a transient Sentinel rejection and returns the URL on a later attempt' {
            InModuleScope WindowsIsoMaker -Parameters @{ FidoPath = $script:FidoStub } {
                param($FidoPath)
                $script:fidoCall = 0
                Mock Invoke-FidoProcess {
                    $script:fidoCall++
                    if ($script:fidoCall -lt 3) {
                        return [pscustomobject]@{ Url = $null; Output = 'Error: Sentinel marked this request as rejected.' }
                    }
                    return [pscustomobject]@{ Url = 'https://software.download.microsoft.com/fake/win11.iso'; Output = 'https://software.download.microsoft.com/fake/win11.iso' }
                }

                $url = Invoke-FidoUrlResolver -FidoPath $FidoPath -Arguments @('11') -RetryDelaySeconds 0

                $url | Should -Be 'https://software.download.microsoft.com/fake/win11.iso'
                Should -Invoke Invoke-FidoProcess -Times 3
            }
        }

        It 'gives up and returns $null after exhausting all attempts' {
            InModuleScope WindowsIsoMaker -Parameters @{ FidoPath = $script:FidoStub } {
                param($FidoPath)
                Mock Invoke-FidoProcess { [pscustomobject]@{ Url = $null; Output = 'Error: Sentinel marked this request as rejected.' } }

                $url = Invoke-FidoUrlResolver -FidoPath $FidoPath -Arguments @('11') -MaxAttempts 3 -RetryDelaySeconds 0

                $url | Should -BeNullOrEmpty
                Should -Invoke Invoke-FidoProcess -Times 3
            }
        }
    }

    Context 'Pinned Fido script resolution' {
        It 'Get-FidoPin returns the tag and 40-char commit from the manifest' {
            InModuleScope WindowsIsoMaker {
                $pin = Get-FidoPin
                $pin.Tag | Should -Match '^v[0-9]'
                $pin.Commit | Should -Match '^[0-9a-fA-F]{40}$'
            }
        }

        It 'Get-FidoCachePath is content-addressed by commit under the temp cache' {
            InModuleScope WindowsIsoMaker {
                $path = Get-FidoCachePath -Commit '3d47260b8915385c58e20c73e24b36e9a9536f3f'
                $path | Should -BeLike '*WindowsIsoMaker*fido*Fido-3d47260b8915385c58e20c73e24b36e9a9536f3f.ps1'
            }
        }

        It 'Resolve-FidoScriptPath uses a local override without downloading' {
            InModuleScope WindowsIsoMaker {
                Mock Invoke-FidoScriptDownload { throw 'Should not download when an override is given' }
                $stub = Join-Path ([System.IO.Path]::GetTempPath()) ("fido-override-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
                '# override' | Set-Content -LiteralPath $stub
                try {
                    $resolved = Resolve-FidoScriptPath -FidoPath $stub
                    $resolved | Should -Be ((Resolve-Path $stub).Path)
                    Should -Invoke Invoke-FidoScriptDownload -Times 0
                }
                finally { Remove-Item $stub -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'Resolve-FidoScriptPath throws when a local override does not exist' {
            InModuleScope WindowsIsoMaker {
                { Resolve-FidoScriptPath -FidoPath 'Z:\nope\Fido.ps1' } | Should -Throw '*does not exist*'
            }
        }

        It 'Resolve-FidoScriptPath downloads the pinned commit when no override and no cache' {
            InModuleScope WindowsIsoMaker {
                $fakeCache = Join-Path ([System.IO.Path]::GetTempPath()) ("fido-cache-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
                Mock Get-FidoCachePath { $fakeCache }
                Mock Invoke-FidoScriptDownload { param($Commit, $Destination) '# downloaded' | Set-Content -LiteralPath $Destination; $Destination }
                try {
                    $resolved = Resolve-FidoScriptPath -FidoPath ''
                    $resolved | Should -Be $fakeCache
                    Should -Invoke Invoke-FidoScriptDownload -Times 1
                }
                finally { Remove-Item $fakeCache -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'Resolve-FidoScriptPath reuses a cached copy without downloading' {
            InModuleScope WindowsIsoMaker {
                $fakeCache = Join-Path ([System.IO.Path]::GetTempPath()) ("fido-cache-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
                '# already cached' | Set-Content -LiteralPath $fakeCache
                Mock Get-FidoCachePath { $fakeCache }
                Mock Invoke-FidoScriptDownload { throw 'Should not download when cache exists' }
                try {
                    $resolved = Resolve-FidoScriptPath -FidoPath ''
                    $resolved | Should -Be $fakeCache
                    Should -Invoke Invoke-FidoScriptDownload -Times 0
                }
                finally { Remove-Item $fakeCache -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}
