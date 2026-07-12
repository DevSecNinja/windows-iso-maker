#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for Mount-WindowsBuildImage — the DISM mount/index-resolution calls are mocked.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force
}

Describe 'Mount-WindowsBuildImage' {

    Context 'Read-only image handling' {
        It 'clears the ReadOnly attribute before a read/write mount' {
            InModuleScope WindowsIsoMaker {
                # A WIM extracted off a read-only ISO keeps its ReadOnly attribute, which makes
                # DISM refuse to mount it for modification. Simulate that with a read-only file.
                $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-mount-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
                New-Item -ItemType Directory -Path $tmp -Force | Out-Null
                $wim = Join-Path $tmp 'install.wim'
                'fake-wim' | Set-Content -LiteralPath $wim
                (Get-Item -LiteralPath $wim).IsReadOnly = $true
                $mountDir = Join-Path $tmp 'mount'

                Mock Mount-BuildImage { }

                Mount-WindowsBuildImage -ImagePath $wim -MountPath $mountDir -Index 1 | Out-Null

                (Get-Item -LiteralPath $wim).IsReadOnly | Should -BeFalse
                Should -Invoke Mount-BuildImage -Times 1
                Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
