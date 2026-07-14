#Requires -Version 5.1
<#
.SYNOPSIS
    Tab-completion (ArgumentCompleter) tests for the build.ps1 and Invoke-QuickBootTest.ps1 entry
    scripts. Exercises the completers via CommandCompletion so a broken/renamed catalog field or a
    dropped completer surfaces as a failing test rather than a silently worse CLI experience.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:BuildScript = (Resolve-Path (Join-Path $script:RepoRoot 'build.ps1')).Path
    $script:QuickScript = (Resolve-Path (Join-Path $script:RepoRoot 'scripts/Invoke-QuickBootTest.ps1')).Path

    function Get-Completion {
        param([string] $CommandLine)
        $result = [System.Management.Automation.CommandCompletion]::CompleteInput($CommandLine, $CommandLine.Length, $null)
        return $result.CompletionMatches
    }
}

Describe 'build.ps1 argument completion' {
    Context 'catalog id parameters' {
        It 'completes -EnableCatalogId from the on-disk change catalog' {
            $completions = Get-Completion "& '$script:BuildScript' -EnableCatalogId appx-"
            $completions.Count | Should -BeGreaterThan 0
            $completions.CompletionText | ForEach-Object { $_ | Should -BeLike 'appx-*' }
            # A stable, well-known catalog id should always be offered.
            $completions.CompletionText | Should -Contain 'appx-clipchamp'
        }

        It 'completes -DisableCatalogId and surfaces a [Category] Description tooltip' {
            $completions = Get-Completion "& '$script:BuildScript' -DisableCatalogId reg-"
            $completions.Count | Should -BeGreaterThan 0
            $completions.CompletionText | ForEach-Object { $_ | Should -BeLike 'reg-*' }
            # Tooltip is the completer's value-add: "[<Category>] <Description>".
            ($completions | Select-Object -First 1).ToolTip | Should -Match '^\[.+\] .+'
        }

        It 'filters catalog ids by the word being completed' {
            $completions = Get-Completion "& '$script:BuildScript' -EnableCatalogId feature-"
            $completions.Count | Should -BeGreaterThan 0
            $completions.CompletionText | ForEach-Object { $_ | Should -BeLike 'feature-*' }
        }
    }

    Context 'edition / language / release parameters' {
        It 'suggests editions for -Edition' {
            $completions = Get-Completion "& '$script:BuildScript' -Edition Pro"
            $completions.CompletionText | Should -Contain 'Pro'
            $completions.CompletionText | Should -Contain 'ProForWorkstations'
        }

        It 'suggests common languages for -Language' {
            $completions = Get-Completion "& '$script:BuildScript' -Language en-"
            $completions.CompletionText | Should -Contain 'en-US'
            $completions.CompletionText | Should -Contain 'en-GB'
        }

        It 'suggests releases for -Release' {
            $completions = Get-Completion "& '$script:BuildScript' -Release "
            $completions.CompletionText | Should -Contain 'latest'
            $completions.CompletionText | Should -Contain '24H2'
        }
    }
}

Describe 'Invoke-QuickBootTest.ps1 argument completion' {
    It 'suggests editions for -Edition' {
        $completions = Get-Completion "& '$script:QuickScript' -Edition E"
        $completions.CompletionText | ForEach-Object { $_ | Should -BeLike 'E*' }
        $completions.CompletionText | Should -Contain 'Enterprise'
    }
}
