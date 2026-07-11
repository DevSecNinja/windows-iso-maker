function Dismount-OfflineRegistryHive {
    <#
    .SYNOPSIS
        Unload a previously loaded offline registry hive, with GC and retry.
    .DESCRIPTION
        Uses 'reg.exe unload' to release a hive loaded by Mount-OfflineRegistryHive. Because
        lingering .NET registry handles can keep a hive locked, this forces garbage
        collection and retries a few times before failing. Callers MUST invoke this in a
        finally block so hives are guaranteed to be unloaded even when servicing fails
        (Constitution Principle VI; FR-005 — never leave the image in a corrupt state).
    .PARAMETER Handle
        The handle object returned by Mount-OfflineRegistryHive.
    .PARAMETER MountKey
        Alternatively, the raw mount key (e.g. 'HKLM\WIM_Offline_SOFTWARE_1a2b3c4d').
    .PARAMETER RetryCount
        Number of unload attempts before throwing. Default 5.
    .PARAMETER RetryDelayMilliseconds
        Delay between attempts. Default 500 ms.
    .EXAMPLE
        Dismount-OfflineRegistryHive -Handle $handle
    .OUTPUTS
        None.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ByHandle')]
        [ValidateNotNull()]
        [pscustomobject] $Handle,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByKey')]
        [ValidateNotNullOrEmpty()]
        [string] $MountKey,

        [Parameter()]
        [ValidateRange(1, 20)]
        [int] $RetryCount = 5,

        [Parameter()]
        [ValidateRange(0, 10000)]
        [int] $RetryDelayMilliseconds = 500
    )

    $key = if ($PSCmdlet.ParameterSetName -eq 'ByHandle') { $Handle.MountKey } else { $MountKey }

    if (-not $PSCmdlet.ShouldProcess($key, 'reg unload')) {
        return
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        # Release any dangling handles that may keep the hive locked.
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()

        $result = & reg.exe unload $key 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-BuildLog -Level Verbose -Component 'Dismount-OfflineRegistryHive' -Message "Unloaded '$key' (attempt $attempt)"
            return
        }

        $lastError = ($result | Out-String).Trim()
        Write-BuildLog -Level Warning -Component 'Dismount-OfflineRegistryHive' -Message "Unload attempt $attempt/$RetryCount for '$key' failed: $lastError"
        if ($attempt -lt $RetryCount) {
            Start-Sleep -Milliseconds $RetryDelayMilliseconds
        }
    }

    throw "Failed to unload registry hive '$key' after $RetryCount attempts. Last error: $lastError"
}
