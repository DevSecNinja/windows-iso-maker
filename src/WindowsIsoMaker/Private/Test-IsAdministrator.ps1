function Test-IsAdministrator {
    <#
    .SYNOPSIS
        Determine whether the current session has administrative (elevated) privileges.
    .DESCRIPTION
        Returns $true when the current Windows session is elevated (member of the local
        Administrators role). On non-Windows hosts (where offline image servicing is not
        possible) it returns $false, allowing callers to fail fast with a clear message.
        Used to fail fast or re-elevate before any destructive servicing work (FR-019).
    .EXAMPLE
        if (-not (Test-IsAdministrator)) { throw 'Elevation required.' }
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    # Offline Windows image servicing is only supported on Windows. On other platforms
    # there is no Administrators role to check, so report not-elevated.
    # NOTE: use a distinctly-named local ($onWindows), never $isWindows — PowerShell variable
    # names are case-insensitive, so $isWindows would clobber the read-only automatic $IsWindows.
    $onWindows = $true
    if (Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue) {
        $onWindows = $IsWindows
    }

    if (-not $onWindows) {
        return $false
    }

    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        Write-BuildLog -Level Warning -Component 'Test-IsAdministrator' -Message "Unable to determine elevation: $($_.Exception.Message)"
        return $false
    }
}
