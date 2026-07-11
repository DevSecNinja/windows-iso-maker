function Invoke-Dism {
    <#
    .SYNOPSIS
        Invoke dism.exe with validated, array-built arguments (injection-safe fallback).
    .DESCRIPTION
        A thin, security-conscious wrapper around dism.exe used where the Dism PowerShell
        module's cmdlet coverage is incomplete or inconsistent across Windows PowerShell 5.1
        and PowerShell 7+. Arguments are passed as a validated array (never a concatenated
        command string), eliminating shell-injection risk (Constitution Principle VII /
        OWASP command injection). Throws a terminating error on a non-zero exit code.
    .PARAMETER Arguments
        The dism.exe arguments as an array, e.g. @('/Image:C:\mount', '/Get-Packages').
        Each element is passed as a discrete argv token; no shell interpolation occurs.
    .PARAMETER DismPath
        Optional explicit path to dism.exe. Defaults to resolving 'dism.exe' from PATH /
        the system directory.
    .PARAMETER IgnoreExitCodes
        Exit codes to treat as success in addition to 0 (e.g. 3010 for reboot-required).
    .EXAMPLE
        Invoke-Dism -Arguments @('/Image:C:\mount', '/Remove-ProvisionedAppxPackage', '/PackageName:Foo')
    .OUTPUTS
        PSCustomObject with ExitCode and Output (captured stdout/stderr lines).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Arguments,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $DismPath = 'dism.exe',

        [Parameter()]
        [int[]] $IgnoreExitCodes = @()
    )

    # Resolve the executable explicitly so we never rely on shell parsing.
    $resolved = $DismPath
    $command = Get-Command -Name $DismPath -CommandType Application -ErrorAction SilentlyContinue
    if ($command) {
        $resolved = $command.Source
    }
    elseif (-not (Test-Path -LiteralPath $DismPath)) {
        # Fall back to the well-known system location before giving up.
        $systemDism = Join-Path -Path ([Environment]::GetFolderPath('System')) -ChildPath 'dism.exe'
        if (Test-Path -LiteralPath $systemDism) {
            $resolved = $systemDism
        }
        else {
            throw "dism.exe was not found (looked for '$DismPath'). Ensure the Windows image-servicing tools are installed."
        }
    }

    Write-BuildLog -Level Verbose -Component 'Invoke-Dism' -Message "Running: $resolved $($Arguments -join ' ')"

    # Call operator with an argument array => each token is a separate argv entry (no shell).
    $output = & $resolved @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    $acceptable = @(0) + $IgnoreExitCodes
    if ($acceptable -notcontains $exitCode) {
        $joined = ($output | Out-String).Trim()
        throw "dism.exe failed with exit code $exitCode. Arguments: $($Arguments -join ' '). Output: $joined"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = @($output | ForEach-Object { $_.ToString() })
    }
}
