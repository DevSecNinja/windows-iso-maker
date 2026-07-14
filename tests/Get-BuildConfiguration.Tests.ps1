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
    Toggles = @{}
    EnableCatalogId = @()
    DisableCatalogId = @()
    WorkingDirectory = ''
    OutputDirectory = './out'
    IsoPath = ''
    BootTest = `$false
    CompressionFormat = 'zip'
    FidoPath = ''
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
    FidoPath = ''
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

        It 'applies WIM_ENABLE_CATALOG_ID to force-enable an opt-in entry' {
            $env:WIM_ENABLE_CATALOG_ID = 'remove-edge'
            $cfg = Get-BuildConfiguration -Path $script:DefaultConfig
            ($cfg.SelectedCatalog | ForEach-Object { $_.Id }) | Should -Contain 'remove-edge'
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

        It 'throws when a DisableCatalogId does not exist in the catalog' {
            { Get-BuildConfiguration -Path $script:DefaultConfig -DisableCatalogId 'does-not-exist' } | Should -Throw
        }
    }

    Context 'Hypervisor (boot-test provider selection)' {
        It 'defaults to HyperV when the config omits it' {
            (Get-BuildConfiguration -Path $script:DefaultConfig).Hypervisor | Should -Be 'HyperV'
        }

        It 'reads the hypervisor from the config file' {
            $vmwareConfig = Join-Path $script:TempRoot 'vmware.psd1'
            "@{ Edition = 'Pro'; Language = 'en-US'; Architecture = 'amd64'; Profile = 'default'; Hypervisor = 'VMware' }" |
                Set-Content -LiteralPath $vmwareConfig -Encoding UTF8
            (Get-BuildConfiguration -Path $vmwareConfig).Hypervisor | Should -Be 'VMware'
        }

        It 'applies WIM_HYPERVISOR over the file value' {
            $env:WIM_HYPERVISOR = 'vmware'
            (Get-BuildConfiguration -Path $script:DefaultConfig).Hypervisor | Should -Be 'VMware'
        }

        It 'normalizes case/space/hyphen variants to a canonical name' {
            $env:WIM_HYPERVISOR = 'Hyper-V'
            (Get-BuildConfiguration -Path $script:DefaultConfig).Hypervisor | Should -Be 'HyperV'
        }

        It 'throws on an unknown hypervisor' {
            $env:WIM_HYPERVISOR = 'virtualbox'
            { Get-BuildConfiguration -Path $script:DefaultConfig } | Should -Throw
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
            $cfg = Get-BuildConfiguration -Path $script:DefaultConfig -EnableCatalogId 'remove-edge'
            $ids = $cfg.SelectedCatalog | ForEach-Object { $_.Id }
            $ids | Should -Contain 'remove-edge'
            $ids | Should -Not -Contain 'remove-onedrive'
        }

        It 'excludes a specifically disabled catalog id' {
            $cfg = Get-BuildConfiguration -Path $script:DefaultConfig -DisableCatalogId 'reg-disable-widgets'
            $ids = $cfg.SelectedCatalog | ForEach-Object { $_.Id }
            $ids | Should -Not -Contain 'reg-disable-widgets'
        }

        It 'includes a normally-off entry when explicitly enabled' {
            $cfg = Get-BuildConfiguration -Path $script:DefaultConfig -EnableCatalogId 'cap-media-player-legacy'
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

    Context 'Profile combinations and opinionated keyboard layout' {
        It 'accepts a list of profiles and stores them joined' {
            $cfg = Get-BuildConfiguration -Path $script:DefaultConfig -Profile 'gaming', 'opinionated'
            $cfg.Profile | Should -Be 'gaming, opinionated'
        }

        It 'gaming,opinionated keeps the Xbox app but adds opinionated extras' {
            $cfg = Get-BuildConfiguration -Path $script:DefaultConfig -Profile 'gaming', 'opinionated'
            $ids = $cfg.SelectedCatalog | ForEach-Object { $_.Id }
            $ids | Should -Not -Contain 'appx-xbox-app'
            $ids | Should -Contain 'reg-reverse-mouse-scroll'
        }

        It 'defaults to United States-International keyboard under opinionated' {
            $cfg = Get-BuildConfiguration -Path $script:DefaultConfig -Profile 'opinionated'
            $cfg.Autounattend.KeyboardLayout | Should -Be '0409:00020409'
        }

        It 'keeps the plain US keyboard for non-opinionated profiles' {
            $cfg = Get-BuildConfiguration -Path $script:DefaultConfig -Profile 'aggressive'
            $cfg.Autounattend.KeyboardLayout | Should -Be '0409:00000409'
        }

        It 'still honours an explicit KeyboardLayout in the config under opinionated' {
            $customConfig = Join-Path $script:TempRoot 'kbd.psd1'
            @"
@{
    Edition = 'Pro'
    Language = 'en-US'
    Architecture = 'amd64'
    Profile = 'opinionated'
    Autounattend = @{ KeyboardLayout = '0413:00000413' }
}
"@ | Set-Content -LiteralPath $customConfig -Encoding UTF8
            $cfg = Get-BuildConfiguration -Path $customConfig
            $cfg.Autounattend.KeyboardLayout | Should -Be '0413:00000413'
        }
    }
}
