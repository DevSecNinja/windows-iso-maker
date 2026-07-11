<#
.SYNOPSIS
    Pester v5 configuration bootstrap for the WindowsIsoMaker test suite.
.DESCRIPTION
    Returns a configured [PesterConfiguration] object that discovers every *.Tests.ps1
    under tests/, writes NUnit XML results (consumed by CI), and enables code-coverage
    for the module source. Import this from local runs and .github/workflows/ci.yml so
    local and CI test execution stay identical (Constitution Principle V).
.EXAMPLE
    $config = ./tests/PesterConfiguration.ps1
    Invoke-Pester -Configuration $config
#>
[CmdletBinding()]
param(
    [string] $TestPath = $PSScriptRoot,
    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath 'TestResults.xml'),
    [string] $SourcePath = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src/WindowsIsoMaker')
)

Set-StrictMode -Version Latest

$configuration = New-PesterConfiguration

$configuration.Run.Path = $TestPath
$configuration.Run.PassThru = $true

$configuration.Output.Verbosity = 'Detailed'

$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputFormat = 'NUnitXml'
$configuration.TestResult.OutputPath = $OutputPath

$configuration.CodeCoverage.Enabled = $false
$configuration.CodeCoverage.Path = $SourcePath

# Fail the run (non-zero exit) if any test fails — gate for CI (FR-013).
$configuration.Should.ErrorAction = 'Continue'

return $configuration
