function Set-RegistryTweaks {
    <#
    .SYNOPSIS
        Apply registry-tweak catalog entries to a mounted image's offline hives.
    .DESCRIPTION
        Groups the provided registry catalog entries by hive, loads each required offline hive
        (SOFTWARE/SYSTEM/DEFAULT) from the mounted image, applies the entries (including the
        default Recall + Widgets disables), and ALWAYS unloads the hives in a finally block so
        they are never left loaded on failure (Principle VI; FR-005). Re-runs are idempotent:
        an entry whose value already matches is recorded AlreadyApplied (FR-017). -WhatIf
        reports intended keys without writing (FR-016). Returns a ChangeResult per entry.
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

    # Group by hive so each hive is loaded/unloaded exactly once.
    $byHive = $registryEntries | Group-Object -Property { $_.Target.Hive }

    foreach ($group in $byHive) {
        $hiveName = $group.Name
        $handle = $null
        $loaded = $false

        try {
            if (-not $WhatIfPreference) {
                $handle = Mount-OfflineRegistryHive -MountPath $MountPath -Hive $hiveName
                $loaded = $true
            }
            $mountKey = if ($handle) { $handle.MountKey } else { "HKLM\WIM_Preview_$hiveName" }

            foreach ($entry in $group.Group) {
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
                    # 'Operation' is an optional Target key (default = Set). Access it in a
                    # StrictMode-safe way: a hashtable missing key must not throw.
                    $operation = if ($target -is [hashtable] -and $target.ContainsKey('Operation')) {
                        $target['Operation']
                    }
                    else {
                        $null
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
                            $result.Reason = "Preview (-WhatIf): would set $hiveName\$($target.Path)\$($target.Name) = $($target.Value)."
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
            # Guarantee the hive is unloaded even if applying an entry threw (FR-005).
            if ($loaded -and $handle) {
                Dismount-OfflineRegistryHive -Handle $handle
            }
        }
    }

    return $results.ToArray()
}
