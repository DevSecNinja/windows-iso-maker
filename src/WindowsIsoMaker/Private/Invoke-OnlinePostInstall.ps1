<#
    ONLINE (running-system) counterparts of the offline change-catalog appliers. These apply the
    SAME data-driven catalog entries to the machine you are running on — the post-install path
    (Invoke-PostInstallSetup) — instead of an offline mounted image. They mirror the offline
    Set-RegistryTweaks / Remove-Bloatware / Enable-WindowsFeature behaviour: idempotent (FR-017),
    -WhatIf aware (FR-016), architecture-filtered (FR-021), and returning one ChangeResult per
    entry for the audit trail (FR-022).

    They are private: the single public entry point is Invoke-PostInstallSetup, which dispatches
    through Invoke-OnlineCatalogEntry.
#>

function Set-OnlineRegistryTweaks {
    <#
    .SYNOPSIS
        Apply registry-tweak catalog entries to the RUNNING system.
    .DESCRIPTION
        Machine hives (SOFTWARE/SYSTEM) are written to HKLM directly. Per-user (DEFAULT) tweaks
        are applied — depending on -Scope — to the CURRENT user (HKCU) and/or the default-user
        profile template (C:\Users\Default\NTUSER.DAT, so NEW profiles inherit them). The template
        hive is loaded once and ALWAYS unloaded in a finally block (Principle VI). Re-runs are
        idempotent (a value already matching -> AlreadyApplied); -WhatIf reports without writing.
    .PARAMETER Catalog
        Catalog entries to apply. Non-SetRegistry entries are ignored.
    .PARAMETER Architecture
        Target architecture; entries not applicable to it are skipped.
    .PARAMETER Scope
        Which per-user targets receive DEFAULT-hive tweaks: 'CurrentUser', 'FutureUsers', or
        'Both' (default).
    .OUTPUTS
        System.Object[] of ChangeResult objects.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Applies a set of registry tweaks; plural mirrors the offline Set-RegistryTweaks command name.')]
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Catalog,

        [Parameter(Mandatory = $true)]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter()]
        [ValidateSet('CurrentUser', 'FutureUsers', 'Both')]
        [string] $Scope = 'Both'
    )

    $registryEntries = @(@($Catalog) | Where-Object {
        $_.Action -eq 'SetRegistry' -and (@($_.Arch) -contains $Architecture)
    })

    $results = [System.Collections.Generic.List[object]]::new()
    if ($registryEntries.Count -eq 0) {
        return $results.ToArray()
    }

    # Resolve the per-user (DEFAULT-hive) target roots up front so the template hive is loaded
    # at most once for the whole run.
    $wantCurrentUser = $Scope -in @('CurrentUser', 'Both')
    $wantFutureUsers = $Scope -in @('FutureUsers', 'Both')
    $hasDefaultEntries = @($registryEntries | Where-Object { $_.Target.Hive -eq 'DEFAULT' }).Count -gt 0

    $defaultHandle = $null
    $defaultLoaded = $false
    try {
        $perUserRoots = [System.Collections.Generic.List[string]]::new()
        if ($hasDefaultEntries -and $wantCurrentUser) { $perUserRoots.Add('HKCU') }
        if ($hasDefaultEntries -and $wantFutureUsers) {
            if ($WhatIfPreference) {
                $perUserRoots.Add('HKU\WIM_PostInstall_DefaultUser_Preview')
            }
            else {
                $defaultHandle = Mount-DefaultUserRegistryHive
                $defaultLoaded = $true
                $perUserRoots.Add($defaultHandle.MountKey)
            }
        }

        foreach ($entry in $registryEntries) {
            $target = $entry.Target
            $roots = if ($target.Hive -eq 'DEFAULT') {
                @($perUserRoots)
            }
            else {
                @(Get-OnlineMachineHiveRoot -Hive $target.Hive)
            }

            $results.Add((Invoke-OnlineRegistryEntry -Entry $entry -Roots $roots))
        }
    }
    finally {
        if ($defaultLoaded -and $defaultHandle) {
            Dismount-OfflineRegistryHive -MountKey $defaultHandle.MountKey
        }
    }

    return $results.ToArray()
}

function Invoke-OnlineRegistryEntry {
    <#
    .SYNOPSIS
        Apply a single SetRegistry entry to one or more live registry roots, returning one
        aggregated ChangeResult (private helper for Set-OnlineRegistryTweaks).
    .DESCRIPTION
        A machine entry has a single root; a per-user (DEFAULT) entry may target both HKCU and the
        default-user template. The aggregated status is 'Applied' if any root was changed,
        'AlreadyApplied' if every applicable root already matched, else 'Skipped'/'Failed'.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][object] $Entry,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Roots
    )

    $result = [pscustomobject]@{
        PSTypeName = 'WindowsIsoMaker.ChangeResult'
        Id         = $Entry.Id
        Type       = 'Registry'
        Status     = 'Skipped'
        Reason     = $null
        Citation   = $Entry.Citation
    }

    if (@($Roots).Count -eq 0) {
        $result.Status = 'Skipped'
        $result.Reason = 'No target registry root for the requested scope.'
        return $result
    }

    $target = $Entry.Target
    $operation = if ($target -is [hashtable] -and $target.ContainsKey('Operation')) { $target['Operation'] } else { $null }
    # RunOnce values are DELETED by Windows once they execute at logon, so a re-run would
    # otherwise re-arm them and report 'Applied' every time. For RunOnce entries we also consult a
    # persistent idempotency marker (the WindowsIsoMaker\State tattoo): if it already records this
    # exact command, the entry is AlreadyApplied and is NOT re-armed (Principle VI idempotency).
    $isRunOnce = Test-IsRunOnceRegistryEntry -Entry $Entry

    # Read-only detection is safe under -WhatIf: the preview checks the current state and records
    # 'Skipped' (with a Reason starting "Preview (-WhatIf): would…") for entries that WOULD change,
    # and 'AlreadyApplied' for entries already in the desired state — consistent with the other
    # online handlers (Remove-OnlineBloatware, Enable-OnlineWindowsFeature).
    $applied = 0
    $already = 0
    $wouldChange = 0
    try {
        foreach ($root in $Roots) {
            $label = "$root\$($target.Path)\$($target.Name)"
            if ($operation -eq 'Delete') {
                $current = Get-OfflineRegistryValue -MountKey $root -Path $target.Path -Name $target.Name
                if ($null -eq $current) { $already++; continue }
                if ($WhatIfPreference) { $wouldChange++; continue }
                if ($PSCmdlet.ShouldProcess($label, 'Delete registry value')) {
                    Remove-OfflineRegistryValue -MountKey $root -Path $target.Path -Name $target.Name
                    $applied++
                }
            }
            else {
                $current = Get-OfflineRegistryValue -MountKey $root -Path $target.Path -Name $target.Name
                if ($null -ne $current -and "$current" -eq "$($target.Value)") { $already++; continue }
                if ($isRunOnce -and (Test-WimRunOnceMarker -Root $root -Id $Entry.Id -CommandValue "$($target.Value)")) {
                    $already++; continue
                }
                if ($WhatIfPreference) { $wouldChange++; continue }
                if ($PSCmdlet.ShouldProcess($label, "Set registry value = $($target.Value)")) {
                    Set-OfflineRegistryValue -MountKey $root -Path $target.Path -Name $target.Name -Kind $target.Kind -Value $target.Value
                    if ($isRunOnce) {
                        # Non-fatal: the RunOnce command is already armed; failing to persist the
                        # idempotency marker just means the next run re-arms it (old behaviour), so
                        # never fail the entry over a marker write.
                        try {
                            Set-WimRunOnceMarker -Id $Entry.Id -CommandValue "$($target.Value)"
                        }
                        catch {
                            Write-BuildLog -Level Warning -Component 'Set-OnlineRegistryTweaks' -Message "Could not persist idempotency marker for '$($Entry.Id)': $($_.Exception.Message)"
                        }
                    }
                    $applied++
                }
            }
        }

        if ($WhatIfPreference) {
            if ($wouldChange -gt 0) {
                $verb = if ($operation -eq 'Delete') { 'delete' } else { "set to $($target.Value)" }
                $suffix = if ($already -gt 0) { " ($already already in the desired state)" } else { '' }
                $result.Status = 'Skipped'
                $result.Reason = "Preview (-WhatIf): would $verb $($target.Hive)\$($target.Path)\$($target.Name) on $wouldChange target(s)$suffix."
            }
            else {
                $result.Status = 'AlreadyApplied'
                $result.Reason = "Preview (-WhatIf): already in the desired state on all $(@($Roots).Count) target(s); no change."
            }
        }
        elseif ($applied -gt 0) {
            $result.Status = 'Applied'
            $result.Reason = if ($operation -eq 'Delete') { "Deleted on $applied target(s)." } else { "Set to $($target.Value) on $applied target(s)." }
        }
        else {
            $result.Status = 'AlreadyApplied'
            $result.Reason = if ($operation -eq 'Delete') { 'Value already absent on all targets.' } else { "Value already set to $($target.Value) on all targets." }
        }
    }
    catch {
        $result.Status = 'Failed'
        $result.Reason = $_.Exception.Message
        Write-BuildLog -Level Warning -Component 'Set-OnlineRegistryTweaks' -Message "Entry '$($Entry.Id)' failed: $($_.Exception.Message)"
    }

    return $result
}

function Remove-OnlineBloatware {
    <#
    .SYNOPSIS
        Apply Appx/Capability removal catalog entries to the RUNNING system.
    .DESCRIPTION
        For RemoveAppx entries the applier both de-provisions the package (so NEW profiles do not
        get it) and, when -Scope includes the current user, uninstalls it for the CURRENT user.
        RemoveCapability entries are removed via dism /online. Entries not present are recorded
        NotApplicable (never Failed); re-runs are idempotent; -WhatIf reports without changing
        anything. Returns a ChangeResult per entry.
    .PARAMETER Catalog
        Catalog entries to apply. Non-Appx/Capability entries are ignored.
    .PARAMETER Architecture
        Target architecture; entries not applicable to it are skipped.
    .PARAMETER Scope
        'CurrentUser' (uninstall for me only), 'FutureUsers' (de-provision only), or 'Both'
        (default).
    .OUTPUTS
        System.Object[] of ChangeResult objects.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Catalog,

        [Parameter(Mandatory = $true)]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter()]
        [ValidateSet('CurrentUser', 'FutureUsers', 'Both')]
        [string] $Scope = 'Both'
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $applicable = @(@($Catalog) | Where-Object {
        $_.Action -in @('RemoveAppx', 'RemoveCapability', 'DisableOptionalFeature') -and (@($_.Arch) -contains $Architecture)
    })
    if ($applicable.Count -eq 0) {
        return $results.ToArray()
    }

    $wantCurrentUser = $Scope -in @('CurrentUser', 'Both')
    $wantFutureUsers = $Scope -in @('FutureUsers', 'Both')

    # Cache the inventories once (avoids repeated dism/Appx calls).
    $provisioned = $null
    $capabilities = $null
    $features = $null

    foreach ($entry in $applicable) {
        $result = [pscustomobject]@{
            PSTypeName = 'WindowsIsoMaker.ChangeResult'
            Id         = $entry.Id
            Type       = $entry.Type
            Status     = 'Skipped'
            Reason     = $null
            Citation   = $entry.Citation
        }

        try {
            if ($entry.Action -eq 'RemoveAppx') {
                $notes = [System.Collections.Generic.List[string]]::new()
                $didSomething = $false
                $found = $false

                # 1. De-provision for future users.
                if ($wantFutureUsers) {
                    if ($null -eq $provisioned) {
                        $provisioned = if ($WhatIfPreference) { @() } else { @(Get-OnlineProvisionedAppx) }
                    }
                    $matched = @($provisioned | Where-Object { $_.DisplayName -like $entry.Target })
                    if ($matched.Count -gt 0) {
                        $found = $true
                        if ($WhatIfPreference) {
                            $notes.Add("would de-provision $($matched.Count) package(s)")
                        }
                        else {
                            foreach ($pkg in $matched) {
                                if ($PSCmdlet.ShouldProcess($pkg.PackageName, 'Remove-ProvisionedAppxPackage (online)')) {
                                    Remove-OnlineProvisionedAppx -PackageName $pkg.PackageName
                                    $didSomething = $true
                                }
                            }
                            $notes.Add("de-provisioned $($matched.Count) package(s)")
                        }
                    }
                }

                # 2. Uninstall for the current user.
                if ($wantCurrentUser) {
                    $installed = @()
                    if (-not $WhatIfPreference) { $installed = @(Get-OnlineInstalledAppxPackage -Name $entry.Target) }
                    if ($installed.Count -gt 0) {
                        $found = $true
                        foreach ($pkg in $installed) {
                            if ($PSCmdlet.ShouldProcess($pkg.PackageFullName, 'Remove-AppxPackage (current user)')) {
                                Remove-OnlineInstalledAppxPackage -PackageFullName $pkg.PackageFullName
                                $didSomething = $true
                            }
                        }
                        $notes.Add("uninstalled $($installed.Count) package(s) for the current user")
                    }
                    elseif ($WhatIfPreference) {
                        $notes.Add('would uninstall for the current user if present')
                    }
                }

                if ($WhatIfPreference) {
                    $result.Status = 'Skipped'
                    $result.Reason = "Preview (-WhatIf): $((@($notes) -join '; '))."
                }
                elseif ($didSomething) {
                    $result.Status = 'Applied'
                    $result.Reason = (@($notes) -join '; ') + '.'
                }
                elseif (-not $found) {
                    $result.Status = 'NotApplicable'
                    $result.Reason = "No provisioned or installed package matching '$($entry.Target)' is present."
                }
                else {
                    $result.Status = 'AlreadyApplied'
                    $result.Reason = "Package '$($entry.Target)' already removed."
                }
            }
            elseif ($entry.Action -eq 'RemoveCapability') {
                if ($null -eq $capabilities) {
                    $capabilities = if ($WhatIfPreference) { @() } else { @(Get-OnlineCapability) }
                }
                $matched = @($capabilities | Where-Object { $_.Name -like "$($entry.Target)*" })
                $installed = @($matched | Where-Object { "$($_.State)" -eq 'Installed' })

                if ($matched.Count -eq 0 -and -not $WhatIfPreference) {
                    $result.Status = 'NotApplicable'
                    $result.Reason = "Capability '$($entry.Target)' is not present on the running system."
                }
                elseif ($installed.Count -eq 0 -and -not $WhatIfPreference) {
                    $result.Status = 'AlreadyApplied'
                    $result.Reason = "Capability '$($entry.Target)' is already not installed."
                }
                elseif ($WhatIfPreference) {
                    $result.Status = 'Skipped'
                    $result.Reason = "Preview (-WhatIf): would remove capability '$($entry.Target)'."
                }
                else {
                    foreach ($cap in $installed) {
                        if ($PSCmdlet.ShouldProcess($cap.Name, 'Remove-Capability (online)')) {
                            Remove-OnlineCapability -Name $cap.Name
                        }
                    }
                    $result.Status = 'Applied'
                    $result.Reason = "Removed $($installed.Count) capability instance(s)."
                }
            }
            elseif ($entry.Action -eq 'DisableOptionalFeature') {
                if ($null -eq $features) {
                    $features = if ($WhatIfPreference) { @() } else { @(Get-OnlineOptionalFeature) }
                }
                $match = @($features | Where-Object { $_.FeatureName -eq $entry.Target }) | Select-Object -First 1

                if (-not $WhatIfPreference -and -not $match) {
                    $result.Status = 'NotApplicable'
                    $result.Reason = "Optional feature '$($entry.Target)' is not present on the running system."
                }
                elseif (-not $WhatIfPreference -and "$($match.State)" -in @('Disabled', 'DisabledWithPayloadRemoved')) {
                    $result.Status = 'AlreadyApplied'
                    $result.Reason = "Optional feature '$($entry.Target)' is already disabled."
                }
                elseif ($WhatIfPreference) {
                    $result.Status = 'Skipped'
                    $result.Reason = "Preview (-WhatIf): would disable and remove optional feature '$($entry.Target)'."
                }
                elseif ($PSCmdlet.ShouldProcess($entry.Target, 'Disable-Feature -Remove (online)')) {
                    Disable-OnlineOptionalFeature -FeatureName $entry.Target
                    $result.Status = 'Applied'
                    $result.Reason = "Disabled and removed optional feature '$($entry.Target)' (a reboot may be required)."
                }
            }
        }
        catch {
            $result.Status = 'Failed'
            $result.Reason = $_.Exception.Message
            Write-BuildLog -Level Warning -Component 'Remove-OnlineBloatware' -Message "Entry '$($entry.Id)' failed: $($_.Exception.Message)"
        }

        $results.Add($result)
    }

    return $results.ToArray()
}

function Enable-OnlineWindowsFeature {
    <#
    .SYNOPSIS
        Additive handler: enable optional features / add capabilities on the RUNNING system.
    .DESCRIPTION
        Online counterpart of Enable-WindowsFeature. Enables optional features via dism /online
        /Enable-Feature and adds capabilities via dism /online /Add-Capability. Idempotent
        (already-enabled/installed -> AlreadyApplied); -WhatIf reports without changing anything.

        NOTE (WSL): enabling the WSL platform features online stages them, but a reboot plus
        `wsl --install` is still required to finish — see docs/wsl.md.
    .PARAMETER Catalog
        Catalog entries to apply. Non-EnableOptionalFeature/AddCapability entries are ignored.
    .PARAMETER Architecture
        Target architecture; entries not applicable to it are skipped.
    .OUTPUTS
        System.Object[] of ChangeResult objects.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Catalog,

        [Parameter(Mandatory = $true)]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $applicable = @(@($Catalog) | Where-Object {
        $_.Action -in @('EnableOptionalFeature', 'AddCapability') -and (@($_.Arch) -contains $Architecture)
    })
    if ($applicable.Count -eq 0) {
        return $results.ToArray()
    }

    $features = $null
    $capabilities = $null

    foreach ($entry in $applicable) {
        $result = [pscustomobject]@{
            PSTypeName = 'WindowsIsoMaker.ChangeResult'
            Id         = $entry.Id
            Type       = $entry.Type
            Status     = 'Skipped'
            Reason     = $null
            Citation   = $entry.Citation
        }

        try {
            if ($entry.Action -eq 'EnableOptionalFeature') {
                if ($null -eq $features) {
                    $features = if ($WhatIfPreference) { @() } else { @(Get-OnlineOptionalFeature) }
                }
                $match = @($features | Where-Object { $_.FeatureName -eq $entry.Target }) | Select-Object -First 1

                if (-not $WhatIfPreference -and $match -and "$($match.State)" -eq 'Enabled') {
                    $result.Status = 'AlreadyApplied'
                    $result.Reason = "Optional feature '$($entry.Target)' is already enabled."
                }
                elseif ($WhatIfPreference) {
                    $result.Status = 'Skipped'
                    $result.Reason = "Preview (-WhatIf): would enable optional feature '$($entry.Target)'."
                }
                elseif ($PSCmdlet.ShouldProcess($entry.Target, 'Enable-Feature (online)')) {
                    Enable-OnlineOptionalFeature -FeatureName $entry.Target
                    $result.Status = 'Applied'
                    $result.Reason = "Enabled optional feature '$($entry.Target)' (a reboot may be required)."
                }
            }
            elseif ($entry.Action -eq 'AddCapability') {
                if ($null -eq $capabilities) {
                    $capabilities = if ($WhatIfPreference) { @() } else { @(Get-OnlineCapability) }
                }
                $match = @($capabilities | Where-Object { $_.Name -like "$($entry.Target)*" }) | Select-Object -First 1

                if (-not $WhatIfPreference -and $match -and "$($match.State)" -eq 'Installed') {
                    $result.Status = 'AlreadyApplied'
                    $result.Reason = "Capability '$($entry.Target)' is already installed."
                }
                elseif ($WhatIfPreference) {
                    $result.Status = 'Skipped'
                    $result.Reason = "Preview (-WhatIf): would add capability '$($entry.Target)'."
                }
                elseif ($PSCmdlet.ShouldProcess($entry.Target, 'Add-Capability (online)')) {
                    $addName = if ($match) { $match.Name } else { $entry.Target }
                    Add-OnlineCapability -Name $addName
                    $result.Status = 'Applied'
                    $result.Reason = "Added capability '$addName'."
                }
            }
        }
        catch {
            $result.Status = 'Failed'
            $result.Reason = $_.Exception.Message
            Write-BuildLog -Level Warning -Component 'Enable-OnlineWindowsFeature' -Message "Entry '$($entry.Id)' failed: $($_.Exception.Message)"
        }

        $results.Add($result)
    }

    return $results.ToArray()
}

function Invoke-OnlineCatalogEntry {
    <#
    .SYNOPSIS
        Online counterpart of Invoke-CatalogEntry: route a single catalog entry to the correct
        ONLINE handler by its Action.
    .DESCRIPTION
        The single seam that turns catalog DATA into changes on the RUNNING system:

            RemoveAppx / RemoveCapability          -> Remove-OnlineBloatware
            SetRegistry                            -> Set-OnlineRegistryTweaks
            EnableOptionalFeature / AddCapability  -> Enable-OnlineWindowsFeature

        An unknown Action raises a terminating error.
    .PARAMETER Entry
        A single catalog entry to apply.
    .PARAMETER Architecture
        Target architecture ('amd64' | 'arm64').
    .PARAMETER Scope
        Per-user application scope for registry/appx entries: 'CurrentUser', 'FutureUsers' or
        'Both' (default).
    .OUTPUTS
        PSCustomObject (ChangeResult).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Entry,

        [Parameter(Mandatory = $true)]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter()]
        [ValidateSet('CurrentUser', 'FutureUsers', 'Both')]
        [string] $Scope = 'Both'
    )

    $action = [string]$Entry.Action

    switch ($action) {
        { $_ -in @('RemoveAppx', 'RemoveCapability', 'DisableOptionalFeature') } {
            $results = @(Remove-OnlineBloatware -Catalog @($Entry) -Architecture $Architecture -Scope $Scope)
        }
        'SetRegistry' {
            $results = @(Set-OnlineRegistryTweaks -Catalog @($Entry) -Architecture $Architecture -Scope $Scope)
        }
        { $_ -in @('EnableOptionalFeature', 'AddCapability') } {
            $results = @(Enable-OnlineWindowsFeature -Catalog @($Entry) -Architecture $Architecture)
        }
        default {
            throw "Unknown catalog Action '$action' for entry '$($Entry.Id)'. Supported: RemoveAppx, RemoveCapability, DisableOptionalFeature, SetRegistry, EnableOptionalFeature, AddCapability."
        }
    }

    if ($results.Count -gt 0) {
        return $results[0]
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsIsoMaker.ChangeResult'
        Id         = $Entry.Id
        Type       = $Entry.Type
        Status     = 'NotApplicable'
        Reason     = "Entry did not apply to architecture '$Architecture'."
        Citation   = $Entry.Citation
    }
}
