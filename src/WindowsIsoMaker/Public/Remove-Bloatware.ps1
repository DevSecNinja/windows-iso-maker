function Remove-Bloatware {
    <#
    .SYNOPSIS
        Apply Appx/Capability removal catalog entries to a mounted offline image.
    .DESCRIPTION
        Iterates the provided (already-selected) catalog entries of Type 'Appx' and
        'Capability' and removes them from the mounted image via DISM. Entries not present in
        the image are recorded as NotApplicable rather than failing (FR-021); re-runs are
        idempotent (FR-017); -WhatIf reports intended changes without modifying the image
        (FR-016). Returns a ChangeResult per entry for the audit trail (FR-022).
    .PARAMETER MountPath
        Root of the mounted offline image.
    .PARAMETER Catalog
        The catalog entries to apply (typically Config.SelectedCatalog). Non-Appx/Capability
        entries are ignored.
    .PARAMETER Architecture
        Target architecture; entries not applicable to it are skipped.
    .PARAMETER Config
        Optional resolved BuildConfiguration (for context/logging).
    .EXAMPLE
        Remove-Bloatware -MountPath C:\mount -Catalog $cfg.SelectedCatalog -Architecture amd64
    .OUTPUTS
        System.Object[] of ChangeResult objects.
    #>
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

    $results = [System.Collections.Generic.List[object]]::new()

    $applicable = @($Catalog) | Where-Object {
        $_.Type -in @('Appx', 'Capability') -and (@($_.Arch) -contains $Architecture)
    }

    # Cache the image inventory once (avoids repeated DISM calls).
    $provisioned = $null
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
            if ($entry.Type -eq 'Appx') {
                if ($null -eq $provisioned) {
                    $provisioned = if ($WhatIfPreference) { @() } else { @(Get-ImageProvisionedAppx -Path $MountPath) }
                }
                $matches = @($provisioned | Where-Object { $_.DisplayName -like $entry.Target })

                if ($matches.Count -eq 0) {
                    $result.Status = 'NotApplicable'
                    $result.Reason = "No provisioned package matching '$($entry.Target)' is present in the image."
                }
                elseif ($WhatIfPreference) {
                    $result.Status = 'Skipped'
                    $result.Reason = 'Preview (-WhatIf): would remove provisioned package.'
                }
                else {
                    foreach ($pkg in $matches) {
                        if ($PSCmdlet.ShouldProcess($pkg.PackageName, 'Remove-AppxProvisionedPackage')) {
                            Remove-ImageProvisionedAppx -Path $MountPath -PackageName $pkg.PackageName
                        }
                    }
                    $result.Status = 'Applied'
                    $result.Reason = "Removed $($matches.Count) provisioned package(s)."
                }
            }
            elseif ($entry.Type -eq 'Capability') {
                if ($null -eq $capabilities) {
                    $capabilities = if ($WhatIfPreference) { @() } else { @(Get-ImageCapability -Path $MountPath) }
                }
                $matches = @($capabilities | Where-Object { $_.Name -like "$($entry.Target)*" })
                $installed = @($matches | Where-Object { "$($_.State)" -eq 'Installed' })

                if ($matches.Count -eq 0) {
                    $result.Status = 'NotApplicable'
                    $result.Reason = "Capability '$($entry.Target)' is not present in the image."
                }
                elseif ($installed.Count -eq 0) {
                    $result.Status = 'AlreadyApplied'
                    $result.Reason = "Capability '$($entry.Target)' is already not installed."
                }
                elseif ($WhatIfPreference) {
                    $result.Status = 'Skipped'
                    $result.Reason = 'Preview (-WhatIf): would remove capability.'
                }
                else {
                    foreach ($cap in $installed) {
                        if ($PSCmdlet.ShouldProcess($cap.Name, 'Remove-WindowsCapability')) {
                            Remove-ImageCapability -Path $MountPath -Name $cap.Name
                        }
                    }
                    $result.Status = 'Applied'
                    $result.Reason = "Removed $($installed.Count) capability instance(s)."
                }
            }
        }
        catch {
            $result.Status = 'Failed'
            $result.Reason = $_.Exception.Message
            Write-BuildLog -Level Warning -Component 'Remove-Bloatware' -Message "Entry '$($entry.Id)' failed: $($_.Exception.Message)"
        }

        $results.Add($result)
    }

    return $results.ToArray()
}
