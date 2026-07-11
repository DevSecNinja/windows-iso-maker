#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for New-BootableIso — oscdimg invocation and path resolution are mocked.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force
}

Describe 'New-BootableIso' {

    BeforeEach {
        $script:MediaRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-media-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path (Join-Path $script:MediaRoot 'boot') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:MediaRoot 'efi/microsoft/boot') -Force | Out-Null
        'x' | Set-Content -LiteralPath (Join-Path $script:MediaRoot 'boot/etfsboot.com')
        'x' | Set-Content -LiteralPath (Join-Path $script:MediaRoot 'efi/microsoft/boot/efisys.bin')
        $script:OutIso = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-out-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.iso')
    }
    AfterEach {
        Remove-Item $script:MediaRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $script:OutIso -Force -ErrorAction SilentlyContinue
    }

    It 'selects dual BIOS+UEFI boot data for amd64' {
        InModuleScope WindowsIsoMaker -Parameters @{ MediaRoot = $script:MediaRoot; OutIso = $script:OutIso } {
            param($MediaRoot, $OutIso)
            Mock Resolve-OscdimgPath { 'C:\adk\oscdimg.exe' }
            Mock Invoke-OscdimgTool { param($OscdimgPath, $Arguments) 'iso' | Set-Content -LiteralPath $OutIso }

            New-BootableIso -MediaRoot $MediaRoot -Architecture amd64 -OutputIsoPath $OutIso | Out-Null

            Should -Invoke Invoke-OscdimgTool -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -match 'bootdata:2#p0,e,b.*#pEF,e,b'
            }
        }
    }

    It 'selects UEFI-only boot data for arm64' {
        InModuleScope WindowsIsoMaker -Parameters @{ MediaRoot = $script:MediaRoot; OutIso = $script:OutIso } {
            param($MediaRoot, $OutIso)
            Mock Resolve-OscdimgPath { 'C:\adk\oscdimg.exe' }
            Mock Invoke-OscdimgTool { param($OscdimgPath, $Arguments) 'iso' | Set-Content -LiteralPath $OutIso }

            New-BootableIso -MediaRoot $MediaRoot -Architecture arm64 -OutputIsoPath $OutIso | Out-Null

            Should -Invoke Invoke-OscdimgTool -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -match 'bootdata:1#pEF,e,b' -and ($Arguments -join ' ') -notmatch 'p0,e,b'
            }
        }
    }

    It 'throws an actionable error when oscdimg is missing' {
        InModuleScope WindowsIsoMaker -Parameters @{ MediaRoot = $script:MediaRoot; OutIso = $script:OutIso } {
            param($MediaRoot, $OutIso)
            Mock Resolve-OscdimgPath { $null }
            { New-BootableIso -MediaRoot $MediaRoot -Architecture amd64 -OutputIsoPath $OutIso } |
                Should -Throw -ExpectedMessage '*oscdimg*'
        }
    }
}
