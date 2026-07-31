function Set-RegistryTweaks {
    <#
    .SYNOPSIS
        Apply registry-tweak catalog entries to a mounted image's offline hives.
    .DESCRIPTION
        Applies the provided registry catalog entries to a mounted image IN CATALOG ORDER (the
        order Import-ChangeCatalog resolved from the entries' RunAfter declarations), loading each
        required offline hive (SOFTWARE/SYSTEM/DEFAULT) on first use and ALWAYS unloading every
        loaded hive in a finally block so none is left loaded on failure (Principle VI; FR-005).
        Order is preserved even across hives, because some changes are only correct in sequence
        (e.g. first-logon RunOnce commands, which Windows executes in the order their values were
        written). Re-runs are idempotent: an entry whose value already matches is recorded
        AlreadyApplied (FR-017). An entry whose Target sets OnlyIfKeyExists = $true is recorded
        NotApplicable when its key is absent from the image (used for third-party/OEM components
        that the image does not contain), so the key is never fabricated. -WhatIf reports intended
        keys without writing (FR-016). Returns a ChangeResult per entry.
    .PARAMETER MountPath
        Root of the mounted offline image.
    .PARAMETER Catalog
        Catalog entries to apply (typically Config.SelectedCatalog). Non-Registry entries are
        ignored.
    .PARAMETER Architecture
        Target architecture; entries not applicable to it are skipped.
    .PARAMETER Config
        Optional resolved BuildConfiguration (for context/logging).
    .EXAMPLE
        Set-RegistryTweaks -MountPath C:\mount -Catalog $cfg.SelectedCatalog -Architecture amd64
    .OUTPUTS
        System.Object[] of ChangeResult objects.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Set-RegistryTweaks applies a set of registry tweaks; the plural noun is the established public command name referenced across config, tests and docs.')]
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $MountPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Catalog,

        [Parameter(Mandatory = $true)]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter()]
        [object] $Config
    )

    if (-not $WhatIfPreference -and -not (Test-Path -LiteralPath $MountPath)) {
        throw "Mount path not found: '$MountPath'."
    }

    $registryEntries = @($Catalog) | Where-Object {
        $_.Action -eq 'SetRegistry' -and (@($_.Arch) -contains $Architecture)
    }

    $results = [System.Collections.Generic.List[object]]::new()
    if ($registryEntries.Count -eq 0) {
        return $results.ToArray()
    }

    # Apply in CATALOG order (which Import-ChangeCatalog has already resolved against the RunAfter
    # declarations) rather than grouping by hive: grouping would emit every SOFTWARE entry before
    # every SYSTEM entry, silently breaking any ordering constraint that crosses hives. Each hive is
    # still loaded at most once — it is mounted on first use and every mounted hive is unloaded in
    # the finally block (FR-005).
    $handles = @{}
    try {
        foreach ($entry in $registryEntries) {
            $hiveName = [string]$entry.Target.Hive
            if (-not $WhatIfPreference -and -not $handles.ContainsKey($hiveName)) {
                $handles[$hiveName] = Mount-OfflineRegistryHive -MountPath $MountPath -Hive $hiveName
            }
            $mountKey = if ($handles.ContainsKey($hiveName)) { $handles[$hiveName].MountKey } else { "HKLM\WIM_Preview_$hiveName" }

            $result = [pscustomobject]@{
                PSTypeName = 'WindowsIsoMaker.ChangeResult'
                Id         = $entry.Id
                Type       = 'Registry'
                Status     = 'Skipped'
                Reason     = $null
                Citation   = $entry.Citation
            }

            try {
                $target = $entry.Target
                # 'Operation' (default = Set) and 'OnlyIfKeyExists' are optional Target keys;
                # read them StrictMode-safely (a missing key must not throw).
                $operation = Get-RegistryTargetOption -Target $target -Name 'Operation'
                $onlyIfKeyExists = [bool](Get-RegistryTargetOption -Target $target -Name 'OnlyIfKeyExists')

                if ($onlyIfKeyExists -and -not $WhatIfPreference -and
                    -not (Test-OfflineRegistryKey -MountKey $mountKey -Path $target.Path)) {
                    # The component this entry targets (e.g. a third-party service) is not in
                    # the image; never fabricate its key.
                    $result.Status = 'NotApplicable'
                    $result.Reason = "Key '$hiveName\$($target.Path)' does not exist in the image; nothing to change."
                    $results.Add($result)
                    continue
                }

                if ($operation -eq 'Delete') {
                    if ($WhatIfPreference) {
                        $result.Status = 'Skipped'
                        $result.Reason = "Preview (-WhatIf): would delete $hiveName\$($target.Path)\$($target.Name)."
                    }
                    else {
                        $current = Get-OfflineRegistryValue -MountKey $mountKey -Path $target.Path -Name $target.Name
                        if ($null -eq $current) {
                            $result.Status = 'AlreadyApplied'
                            $result.Reason = 'Value already absent.'
                        }
                        elseif ($PSCmdlet.ShouldProcess("$hiveName\$($target.Path)\$($target.Name)", 'Delete registry value')) {
                            Remove-OfflineRegistryValue -MountKey $mountKey -Path $target.Path -Name $target.Name
                            $result.Status = 'Applied'
                            $result.Reason = 'Value deleted.'
                        }
                    }
                }
                else {
                    # Set / Disable => write Kind=Value.
                    if ($WhatIfPreference) {
                        $result.Status = 'Skipped'
                        $suffix = if ($onlyIfKeyExists) { ' (only if that key already exists)' } else { '' }
                        $result.Reason = "Preview (-WhatIf): would set $hiveName\$($target.Path)\$($target.Name) = $($target.Value)$suffix."
                    }
                    else {
                        $current = Get-OfflineRegistryValue -MountKey $mountKey -Path $target.Path -Name $target.Name
                        if ($null -ne $current -and "$current" -eq "$($target.Value)") {
                            $result.Status = 'AlreadyApplied'
                            $result.Reason = "Value already set to $($target.Value)."
                        }
                        elseif ($PSCmdlet.ShouldProcess("$hiveName\$($target.Path)\$($target.Name)", "Set registry value = $($target.Value)")) {
                            Set-OfflineRegistryValue -MountKey $mountKey -Path $target.Path -Name $target.Name -Kind $target.Kind -Value $target.Value
                            $result.Status = 'Applied'
                            $result.Reason = "Set to $($target.Value)."
                        }
                    }
                }
            }
            catch {
                $result.Status = 'Failed'
                $result.Reason = $_.Exception.Message
                Write-BuildLog -Level Warning -Component 'Set-RegistryTweaks' -Message "Entry '$($entry.Id)' failed: $($_.Exception.Message)"
            }

            $results.Add($result)
        }
    }
    finally {
        # Guarantee every hive is unloaded even if applying an entry threw (FR-005).
        foreach ($handle in @($handles.Values)) {
            Dismount-OfflineRegistryHive -Handle $handle
        }
    }

    return $results.ToArray()
}
