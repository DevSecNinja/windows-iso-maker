function New-RunReport {
    <#
    .SYNOPSIS
        Assemble (and optionally serialize) the auditable RunReport for a build.
    .DESCRIPTION
        Builds the RunReport object described in the data model (FR-022): the resolved
        configuration, base image metadata, the applied/skipped ChangeResult lists, the
        produced artifact, integrity results, captured tool versions, and the overall
        outcome. Optionally writes it to disk as JSON for the audit trail (FR-009). No
        secrets are included (Constitution Principle VII).
    .PARAMETER ResolvedConfig
        The fully resolved BuildConfiguration object.
    .PARAMETER BaseImage
        The BaseImage object (may be $null for preview runs).
    .PARAMETER Applied
        Array of ChangeResult objects that were applied (or would be, in preview).
    .PARAMETER Skipped
        Array of ChangeResult objects that were skipped, with reasons.
    .PARAMETER Artifact
        The OutputImageArtifact object (may be $null for preview/failed runs).
    .PARAMETER Integrity
        The integrity result object from Test-ImageIntegrity (may be $null).
    .PARAMETER ToolVersions
        Hashtable of tool/module versions (Fido commit, ADK, Pester, PSSA, PowerShell).
    .PARAMETER Outcome
        Overall outcome: 'Succeeded', 'Failed', or 'Preview'.
    .PARAMETER OutputPath
        Optional path to write the serialized JSON report. When omitted, nothing is written.
    .EXAMPLE
        $report = New-RunReport -ResolvedConfig $cfg -Applied $applied -Skipped $skipped -Outcome 'Succeeded' -OutputPath './out/run-report.json'
    .OUTPUTS
        PSCustomObject (RunReport).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $ResolvedConfig,

        [Parameter()]
        [object] $BaseImage,

        [Parameter()]
        [object[]] $Applied = @(),

        [Parameter()]
        [object[]] $Skipped = @(),

        [Parameter()]
        [object] $Artifact,

        [Parameter()]
        [object] $Integrity,

        [Parameter()]
        [hashtable] $ToolVersions = @{},

        [Parameter()]
        [object] $Autounattend,

        [Parameter()]
        [object] $Bom,

        [Parameter()]
        [object] $Provenance,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Succeeded', 'Failed', 'Preview')]
        [string] $Outcome,

        [Parameter()]
        [string] $OutputPath
    )

    $report = [pscustomobject]@{
        PSTypeName     = 'WindowsIsoMaker.RunReport'
        Timestamp      = (Get-Date).ToUniversalTime()
        SchemaVersion  = '1.0'
        ResolvedConfig = $ResolvedConfig
        BaseImage      = $BaseImage
        Applied        = @($Applied)
        Skipped        = @($Skipped)
        Artifact       = $Artifact
        Integrity      = $Integrity
        ToolVersions   = $ToolVersions
        Autounattend   = $Autounattend
        Bom            = $Bom
        Provenance     = $Provenance
        Outcome        = $Outcome
    }

    if ($OutputPath) {
        if ($PSCmdlet.ShouldProcess($OutputPath, 'Write RunReport JSON')) {
            $directory = Split-Path -Parent $OutputPath
            if ($directory -and -not (Test-Path -LiteralPath $directory)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
            $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
            Write-BuildLog -Level Information -Component 'New-RunReport' -Message "RunReport written to '$OutputPath' (Outcome=$Outcome)"
        }
    }

    return $report
}
