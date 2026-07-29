<#
    Private helpers that map the change-catalog's logical hive names to ONLINE (running-system)
    registry roots, and load/unload the default-user profile template hive.

    Machine-wide policies (Hive = SOFTWARE | SYSTEM) live under HKLM directly — no load needed.
    Per-user tweaks (Hive = DEFAULT) are applied online to two possible targets:
      * the CURRENT user's live hive (HKCU), so the running profile sees the change now, and
      * the default-user profile TEMPLATE (C:\Users\Default\NTUSER.DAT), loaded into HKU so every
        NEW profile created afterwards inherits the change.
    The offline build writes DEFAULT-hive tweaks into the image so new profiles inherit them;
    online we replicate that with the NTUSER.DAT template AND cover the already-existing current
    user, whom the offline path never touches.

    The actual value read/write/delete uses the shared Get-/Set-/Remove-OfflineRegistryValue
    helpers (they operate on any 'Registry::<MountKey>\<Path>' target, offline or online).
#>

function Get-OnlineMachineHiveRoot {
    <#
    .SYNOPSIS
        Map a machine hive name to its live HKLM root used as a MountKey for the value helpers.
    .PARAMETER Hive
        'SOFTWARE' or 'SYSTEM'.
    .OUTPUTS
        System.String — e.g. 'HKLM\SOFTWARE'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('SOFTWARE', 'SYSTEM')]
        [string] $Hive
    )
    return "HKLM\$Hive"
}

function Resolve-OnlineRegistryPath {
    <#
    .SYNOPSIS
        Translate a catalog Target Path authored for the OFFLINE hive into its ONLINE equivalent.
    .DESCRIPTION
        SYSTEM-hive catalog paths are authored against an explicit control set ('ControlSet001\...')
        because the offline loaded SYSTEM hive has no CurrentControlSet symlink — it does not exist
        until the image boots. On a RUNNING system CurrentControlSet is the authoritative active
        control set and is NOT always ControlSet001 (HKLM\SYSTEM\Select\Current decides; a Last
        Known Good rollback can make ControlSet002 active). Writing to an inactive control set
        would silently have no effect, so the authored prefix is rewritten to CurrentControlSet
        for the online appliers. All other hives/paths are returned unchanged.
    .PARAMETER Hive
        The entry's logical hive ('SOFTWARE', 'SYSTEM' or 'DEFAULT').
    .PARAMETER Path
        The entry's Target Path, relative to the hive root.
    .OUTPUTS
        System.String — the path to use against the live registry.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Hive,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if ($Hive -eq 'SYSTEM' -and $Path -match '^ControlSet\d{3}\\') {
        return ($Path -replace '^ControlSet\d{3}\\', 'CurrentControlSet\')
    }
    return $Path
}

function Mount-DefaultUserRegistryHive {
    <#
    .SYNOPSIS
        Load the default-user profile template hive (C:\Users\Default\NTUSER.DAT) into HKU.
    .DESCRIPTION
        Uses 'reg.exe load' to mount the new-user template hive into a uniquely named subkey
        under HKU so per-user (DEFAULT) catalog tweaks can be written into it, making every NEW
        profile inherit them. Callers MUST unload it (Dismount-OfflineRegistryHive -MountKey ...)
        in a finally block so the hive is never left loaded on failure (Principle VI).
    .PARAMETER DefaultUserHivePath
        Path to the NTUSER.DAT template. Defaults to %SystemDrive%\Users\Default\NTUSER.DAT.
    .PARAMETER MountKeyPrefix
        Prefix for the temporary HKU subkey name. A random suffix is appended to avoid collisions.
    .OUTPUTS
        PSCustomObject with HiveFile, MountKey (HKU\<name>) and MountKeyName.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $DefaultUserHivePath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $MountKeyPrefix = 'WIM_PostInstall_DefaultUser'
    )

    if ([string]::IsNullOrWhiteSpace($DefaultUserHivePath)) {
        $systemDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
        $DefaultUserHivePath = Join-Path -Path $systemDrive -ChildPath 'Users\Default\NTUSER.DAT'
    }

    if (-not (Test-Path -LiteralPath $DefaultUserHivePath)) {
        throw "Default-user profile hive not found: '$DefaultUserHivePath'."
    }

    $mountKeyName = "$MountKeyPrefix`_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $mountKey = "HKU\$mountKeyName"

    if ($PSCmdlet.ShouldProcess($mountKey, "reg load $DefaultUserHivePath")) {
        Write-BuildLog -Level Verbose -Component 'Mount-DefaultUserRegistryHive' -Message "Loading '$DefaultUserHivePath' -> '$mountKey'"
        $result = & reg.exe load $mountKey $DefaultUserHivePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to load default-user hive '$DefaultUserHivePath' into '$mountKey' (exit $LASTEXITCODE): $($result | Out-String)"
        }
    }

    return [pscustomobject]@{
        HiveFile     = $DefaultUserHivePath
        MountKey     = $mountKey
        MountKeyName = $mountKeyName
    }
}
