function Mount-OfflineRegistryHive {
    <#
    .SYNOPSIS
        Load an offline registry hive from a mounted Windows image into a scoped temp key.
    .DESCRIPTION
        Uses 'reg.exe load' to mount a hive file from a mounted (offline) Windows image into
        a uniquely named subkey under HKLM, so registry tweaks can be applied to the image
        without affecting the host. Returns a handle describing where the hive was mounted;
        callers MUST unload it (Dismount-OfflineRegistryHive) in a finally block so hives are
        never left loaded on failure (Constitution Principle VI; FR-005).
    .PARAMETER MountPath
        Root directory of the mounted Windows image (from Mount-WindowsBuildImage).
    .PARAMETER Hive
        Logical hive to load: SOFTWARE, SYSTEM, or DEFAULT.
    .PARAMETER MountKeyPrefix
        Prefix used for the temporary HKLM subkey name. A random suffix is appended to keep
        concurrent/retried loads from colliding.
    .EXAMPLE
        $handle = Mount-OfflineRegistryHive -MountPath 'C:\mount' -Hive SOFTWARE
        try { ... } finally { Dismount-OfflineRegistryHive -Handle $handle }
    .OUTPUTS
        PSCustomObject with Hive, HiveFile, MountKey (HKLM\<name>), and PSDrivePath.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $MountPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('SOFTWARE', 'SYSTEM', 'DEFAULT')]
        [string] $Hive,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $MountKeyPrefix = 'WIM_Offline'
    )

    # Map the logical hive to its file location inside the offline image.
    $hiveFile = switch ($Hive) {
        'SOFTWARE' { Join-Path -Path $MountPath -ChildPath 'Windows\System32\config\SOFTWARE' }
        'SYSTEM'   { Join-Path -Path $MountPath -ChildPath 'Windows\System32\config\SYSTEM' }
        'DEFAULT'  { Join-Path -Path $MountPath -ChildPath 'Windows\System32\config\DEFAULT' }
    }

    if (-not (Test-Path -LiteralPath $hiveFile)) {
        throw "Offline hive file not found: '$hiveFile'. Is the image mounted at '$MountPath'?"
    }

    $mountKeyName = "$MountKeyPrefix`_$Hive`_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $mountKey = "HKLM\$mountKeyName"

    if ($PSCmdlet.ShouldProcess($mountKey, "reg load $hiveFile")) {
        Write-BuildLog -Level Verbose -Component 'Mount-OfflineRegistryHive' -Message "Loading '$hiveFile' -> '$mountKey'"
        $result = & reg.exe load $mountKey $hiveFile 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to load hive '$hiveFile' into '$mountKey' (exit $LASTEXITCODE): $($result | Out-String)"
        }
    }

    return [pscustomobject]@{
        Hive        = $Hive
        HiveFile    = $hiveFile
        MountKey    = $mountKey
        MountKeyName = $mountKeyName
        PSDrivePath = "Registry::$mountKey"
    }
}
