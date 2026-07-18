function Invoke-CatalogEntry {
    <#
    .SYNOPSIS
        Data-driven dispatcher: route a single change-catalog entry to the correct handler by
        its Action (FR-024/FR-025).
    .DESCRIPTION
        This is the single seam that turns catalog DATA into applied changes. Each entry's
        Action selects the handler:

            RemoveAppx / RemoveCapability      -> Remove-Bloatware
            SetRegistry                        -> Set-RegistryTweaks
            EnableOptionalFeature / AddCapability -> Enable-WindowsFeature
            DisableOptionalFeature             -> Remove-Bloatware (disable + remove payload)

        Adding a new feature is a catalog edit (zero new code); adding a whole new category of
        change is one new Action value plus one handler branch here — never a new pipeline
        parameter or switch. An unknown Action raises a terminating error.

        Architecture filtering (FR-021), idempotency (FR-017), and -WhatIf (FR-016) are handled
        uniformly by the underlying handlers, so behaviour is Action-agnostic.
    .PARAMETER Entry
        A single ChangeCatalogEntry object to apply.
    .PARAMETER MountPath
        Root of the mounted offline image.
    .PARAMETER Architecture
        Target architecture ('amd64' | 'arm64').
    .PARAMETER Config
        Optional resolved BuildConfiguration (for context/logging).
    .EXAMPLE
        Invoke-CatalogEntry -Entry $entry -MountPath C:\mount -Architecture amd64
    .OUTPUTS
        PSCustomObject (ChangeResult).
    #>
    # This dispatcher performs no direct state change itself; it delegates to handler
    # functions (Remove-Bloatware / Set-RegistryTweaks / Enable-WindowsFeature) that each
    # implement ShouldProcess / -WhatIf. It therefore does not declare SupportsShouldProcess.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Entry,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $MountPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter()]
        [object] $Config
    )

    $action = [string]$Entry.Action
    $handlerParams = @{
        MountPath    = $MountPath
        Catalog      = @($Entry)
        Architecture = $Architecture
        Config       = $Config
    }

    switch ($action) {
        { $_ -in @('RemoveAppx', 'RemoveCapability', 'DisableOptionalFeature') } {
            $results = @(Remove-Bloatware @handlerParams)
        }
        'SetRegistry' {
            $results = @(Set-RegistryTweaks @handlerParams)
        }
        { $_ -in @('EnableOptionalFeature', 'AddCapability') } {
            $results = @(Enable-WindowsFeature @handlerParams)
        }
        default {
            throw "Unknown catalog Action '$action' for entry '$($Entry.Id)'. Supported: RemoveAppx, RemoveCapability, DisableOptionalFeature, SetRegistry, EnableOptionalFeature, AddCapability."
        }
    }

    if ($results.Count -gt 0) {
        return $results[0]
    }

    # A handler may return nothing when the entry does not apply to this arch; surface a
    # NotApplicable result so every dispatched entry is accounted for in the RunReport.
    return [pscustomobject]@{
        PSTypeName = 'WindowsIsoMaker.ChangeResult'
        Id         = $Entry.Id
        Type       = $Entry.Type
        Status     = 'NotApplicable'
        Reason     = "Entry did not apply to architecture '$Architecture'."
        Citation   = $Entry.Citation
    }
}
