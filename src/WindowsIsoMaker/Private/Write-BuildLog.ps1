function Write-BuildLog {
    <#
    .SYNOPSIS
        Emit a structured, timestamped build log line.
    .DESCRIPTION
        Central logging helper for the WindowsIsoMaker module. Writes a single, structured
        line to the appropriate PowerShell stream based on severity level. Never logs
        secrets (Constitution Principle VII) — callers must not pass credentials or tokens.
    .PARAMETER Message
        The human-readable message to log.
    .PARAMETER Level
        Severity level: Debug, Verbose, Information, Warning, or Error. Controls which
        PowerShell stream the message is written to.
    .PARAMETER Component
        Optional short component/function name to prefix the message for traceability.
    .EXAMPLE
        Write-BuildLog -Level Information -Message 'Mounting install.wim index 6' -Component 'Mount-WindowsBuildImage'
    .OUTPUTS
        None. Writes to the Verbose/Information/Warning/Error/Debug streams.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [string] $Message,

        [Parameter()]
        [ValidateSet('Debug', 'Verbose', 'Information', 'Warning', 'Error')]
        [string] $Level = 'Information',

        [Parameter()]
        [string] $Component
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $prefix = if ($Component) { "[$Component] " } else { '' }
    $line = "{0} [{1}] {2}{3}" -f $timestamp, $Level.ToUpperInvariant(), $prefix, $Message

    switch ($Level) {
        'Debug'       { Write-Debug -Message $line }
        'Verbose'     { Write-Verbose -Message $line }
        'Information' { Write-Information -MessageData $line -InformationAction Continue }
        'Warning'     { Write-Warning -Message $line }
        'Error'       { Write-Error -Message $line }
    }
}
