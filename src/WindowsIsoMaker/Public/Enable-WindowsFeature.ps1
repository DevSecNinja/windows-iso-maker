function Enable-WindowsFeature {
    <#
    .SYNOPSIS
        Additive handler: enable Windows optional features and add capabilities on a mounted
        offline image (FR-025).
    .DESCRIPTION
        Invoked by Invoke-CatalogEntry for catalog entries whose Action is
        'EnableOptionalFeature' or 'AddCapability' (also callable directly over a filtered
        catalog). Enables optional features via Enable-WindowsOptionalFeature -Path and adds
        capabilities via Add-WindowsCapability -Path.

        Idempotent (FR-017): a feature already enabled / capability already installed is
        recorded AlreadyApplied. Features not applicable to the target architecture are skipped
        (Principle IV / FR-021). -WhatIf reports intended features without changing the image
        (FR-016). Returns a ChangeResult per entry for the audit trail (FR-022).

        NOTE (WSL): enabling 'Microsoft-Windows-Subsystem-Linux' + 'VirtualMachinePlatform'
        offline only pre-stages the platform features. The WSL2 kernel and any Linux
        distribution are installed ONLINE on first boot (a Windows platform constraint) — see
        the catalog entry Rationale and docs/wsl.md.
    .PARAMETER MountPath
        Root of the mounted offline image.
    .PARAMETER Catalog
        The catalog entries to apply (typically Config.SelectedCatalog). Entries whose Action
        is not EnableOptionalFeature/AddCapability are ignored.
    .PARAMETER Architecture
        Target architecture; entries not applicable to it are skipped.
    .PARAMETER Config
        Optional resolved BuildConfiguration (for context/logging).
    .EXAMPLE
        Enable-WindowsFeature -MountPath C:\mount -Catalog $cfg.SelectedCatalog -Architecture amd64
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
        $_.Action -in @('EnableOptionalFeature', 'AddCapability') -and (@($_.Arch) -contains $Architecture)
    }

    # Cache image inventories once (avoids repeated DISM calls).
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
                    $features = if ($WhatIfPreference) { @() } else { @(Get-ImageOptionalFeature -Path $MountPath) }
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
                elseif ($PSCmdlet.ShouldProcess($entry.Target, 'Enable-WindowsOptionalFeature')) {
                    Enable-ImageOptionalFeature -Path $MountPath -FeatureName $entry.Target
                    $result.Status = 'Applied'
                    $result.Reason = "Enabled optional feature '$($entry.Target)'."
                }
            }
            elseif ($entry.Action -eq 'AddCapability') {
                if ($null -eq $capabilities) {
                    $capabilities = if ($WhatIfPreference) { @() } else { @(Get-ImageCapability -Path $MountPath) }
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
                elseif ($PSCmdlet.ShouldProcess($entry.Target, 'Add-WindowsCapability')) {
                    $addName = if ($match) { $match.Name } else { $entry.Target }
                    Add-ImageCapability -Path $MountPath -Name $addName
                    $result.Status = 'Applied'
                    $result.Reason = "Added capability '$addName'."
                }
            }
        }
        catch {
            $result.Status = 'Failed'
            $result.Reason = $_.Exception.Message
            Write-BuildLog -Level Warning -Component 'Enable-WindowsFeature' -Message "Entry '$($entry.Id)' failed: $($_.Exception.Message)"
        }

        $results.Add($result)
    }

    return $results.ToArray()
}
