#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for Get-BuildConfiguration — the config file is the PRIMARY interface.
.DESCRIPTION
    Verifies that the configuration file drives a build; that -ConfigPath/-Path and
    WIM_CONFIG_PATH select alternate saved profiles; the precedence chain
    (file defaults -> WIM_* env vars -> explicit parameters); validation of bad values;
    and catalog selection (include/exclude + opt-in Edge/OneDrive). All filesystem-only,
    so it runs on any platform.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-cfg-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

    # A default-style profile.
    $script:DefaultConfig = Join-Path $script:TempRoot 'default.psd1'
    @"
@{
    Edition = 'Pro'
    Language = 'en-US'
    Release = 'latest'
    Architecture = 'amd64'
    Profile = 'default'
    IncludeCatalogId = @()
    ExcludeCatalogId = @()
    RemoveEdge = `$false
    RemoveOneDrive = `$false
    WorkingDirectory = ''
    OutputDirectory = './out'
    IsoPath = ''
    BootTest = `$false
    CompressionFormat = 'zip'
    FidoPath = 'vendor/fido/Fido.ps1'
    OscdimgPath = ''
}
"@ | Set-Content -LiteralPath $script:DefaultConfig -Encoding UTF8

    # A second, independent saved profile (arm64, Dutch).
    $script:Arm64Config = Join-Path $script:TempRoot 'arm64.psd1'
    @"
@{
    Edition = 'Pro'
    Language = 'nl-NL'
    Release = 'latest'
    Architecture = 'arm64'
    Profile = 'default'
    CompressionFormat = '7z'
    FidoPath = 'vendor/fido/Fido.ps1'
}
"@ | Set-Content -LiteralPath $script:Arm64Config -Encoding UTF8

    # Clear any WIM_* env vars that could leak in from the host.
    Get-ChildItem Env: | Where-Object { $_.Name -like 'WIM_*' } | ForEach-Object { Remove-Item "Env:$($_.Name)" -ErrorAction SilentlyContinue }
}

AfterAll {
    Get-ChildItem Env: | Where-Object { $_.Name -like 'WIM_*' } | ForEach-Object { Remove-Item "Env:$($_.Name)" -ErrorAction SilentlyContinue }
    if (Test-Path $script:TempRoot) { Remove-Item $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Get-BuildConfiguration' {

    AfterEach {
        Get-ChildItem Env: | Where-Object { $_.Name -like 'WIM_*' } | ForEach-Object { Remove-Item "Env:$($_.Name)" -ErrorAction SilentlyContinue }
    }

    Context 'Config file is the primary interface' {
        It 'loads defaults from the config file' {
            $cfg = Get-BuildConfiguration -Path $script:DefaultConfig
            $cfg.Edition | Should -Be 'Pro'
            $cfg.Language | Should -Be 'en-US'
            $cfg.Architecture | Should -Be 'amd64'
            $cfg.CompressionFormat | Should -Be 'zip'
        }

        It 'resolves a second saved profile independently via -ConfigPath alias' {
            $cfg = Get-BuildConfiguration -ConfigPath $script:Arm64Config
            $cfg.Architecture | Should -Be 'arm64'
            $cfg.Language | Should -Be 'nl-NL'
            $cfg.CompressionFormat | Should -Be '7z'
        }

        It 'selects the config file from WIM_CONFIG_PATH when no -Path is given' {
            $env:WIM_CONFIG_PATH = $script:Arm64Config
            $cfg = Get-BuildConfiguration
            $cfg.Architecture | Should -Be 'arm64'
            $cfg.Language | Should -Be 'nl-NL'
        }
    }

    Context 'Precedence: file defaults <- WIM_* env vars <- explicit params' {
        It 'applies a WIM_* environment override over the file value' {
            $env:WIM_LANGUAGE = 'de-DE'
            $cfg = Get-BuildConfiguration -Path $script:DefaultConfig
            $cfg.Language | Should -Be 'de-DE'
        }

        It 'lets an explicit parameter win over both file and env' {
            $env:WIM_ARCH = 'arm64'
            $cfg = Get-BuildConfiguration -Path $script:DefaultConfig -Architecture 'amd64'
            $cfg.Architecture | Should -Be 'amd64'
        }

        It 'applies WIM_REMOVE_EDGE=true as a boolean override' {
            $env:WIM_REMOVE_EDGE = 'true'
            $cfg = Get-BuildConfiguration -Path $script:DefaultConfig
            $cfg.RemoveEdge | Should -BeTrue
        }
    }

    Context 'Validation' {
        It 'throws on an invalid architecture' {
            { Get-BuildConfiguration -Path $script:DefaultConfig -Architecture 'ppc64' } | Should -Throw
        }

        It 'throws on an empty edition override' {
            $env:WIM_EDITION = ''
            { Get-BuildConfiguration -Path $script:DefaultConfig -Edition '' } | Should -Throw
        }

        It 'throws when the config file does not exist' {
            { Get-BuildConfiguration -Path (Join-Path $script:TempRoot 'nope.psd1') } | Should -Throw
        }

        It 'throws when an ExcludeCatalogId does not exist in the catalog' {
            { Get-BuildConfiguration -Path $script:DefaultConfig -ExcludeCatalogId 'does-not-exist' } | Should -Throw
        }
    }

    Context 'Catalog selection (profile, include/exclude, opt-in removals)' {
        It 'enables the default-ON Recall and Widgets entries by default' {
            $cfg = Get-BuildConfiguration -Path $script:DefaultConfig
            $ids = $cfg.SelectedCatalog | ForEach-Object { $_.Id }
            $ids | Should -Contain 'reg-disable-recall'
            $ids | Should -Contain 'reg-disable-widgets'
        }

        It 'keeps Edge and OneDrive removal OUT of the default selection' {
            $cfg = Get-BuildConfiguration -Path $script:DefaultConfig
            $ids = $cfg.SelectedCatalog | ForEach-Object { $_.Id }
            $ids | Should -Not -Contain 'remove-edge'
            $ids | Should -Not -Contain 'remove-onedrive'
        }

        It 'enables ONLY the opt-in removals that were flagged' {
            $cfg = Get-BuildConfiguration -Path $script:DefaultConfig -RemoveEdge
            $ids = $cfg.SelectedCatalog | ForEach-Object { $_.Id }
            $ids | Should -Contain 'remove-edge'
            $ids | Should -Not -Contain 'remove-onedrive'
        }

        It 'excludes a specifically excluded catalog id' {
            $cfg = Get-BuildConfiguration -Path $script:DefaultConfig -ExcludeCatalogId 'reg-disable-cortana'
            $ids = $cfg.SelectedCatalog | ForEach-Object { $_.Id }
            $ids | Should -Not -Contain 'reg-disable-cortana'
        }

        It 'includes a normally-off entry when explicitly included' {
            $cfg = Get-BuildConfiguration -Path $script:DefaultConfig -IncludeCatalogId 'cap-media-player-legacy'
            $ids = $cfg.SelectedCatalog | ForEach-Object { $_.Id }
            $ids | Should -Contain 'cap-media-player-legacy'
        }

        It 'filters selection by architecture' {
            $cfg = Get-BuildConfiguration -Path $script:DefaultConfig -Architecture 'arm64'
            foreach ($entry in $cfg.SelectedCatalog) {
                $entry.Arch | Should -Contain 'arm64'
            }
        }
    }
}
