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
            RegisterScheduledTask              -> Register-ScheduledTaskEntry

        Adding a new feature is a catalog edit (zero new code); adding a whole new category of
        change is one new Action value plus one handler branch here — never a new pipeline
        parameter or switch. An unknown Action raises a terminating error.

        Architecture filtering (FR-021), idempotency (FR-017), and -WhatIf (FR-016) are handled
        uniformly by the underlying handlers, so behaviour is Action-agnostic.

        Entries that declare an applicability `Condition` (e.g. "Surface Laptop only") are NOT
        applied by the offline build: the condition describes the machine the image will be
        installed on, and the build agent is not that machine, so evaluating it here would test the
        wrong hardware. Such entries are reported NotApplicable with a reason pointing at
        post-install.ps1, which evaluates the condition on the installed machine. See
        Private/CatalogEntryCondition.ps1.
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

    # A machine-specific Condition cannot be answered while servicing an offline image: the build
    # host is not the machine the image will run on. Never guess — record it as NotApplicable and
    # point at the online path that CAN evaluate it.
    $condition = Get-CatalogEntryCondition -Entry $Entry
    if ($null -ne $condition) {
        $description = Get-CatalogConditionField -Condition $condition -Name 'Description'
        $label = if ($description) { $description } else { 'a machine-specific condition' }
        return New-ConditionNotApplicableResult -Entry $Entry -Reason (
            "Entry declares a condition ($label) that describes the target machine, which the " +
            'offline build cannot evaluate. Run post-install.ps1 on the installed machine to apply it.')
    }

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
        'RegisterScheduledTask' {
            $results = @(Register-ScheduledTaskEntry @handlerParams)
        }
        default {
            throw "Unknown catalog Action '$action' for entry '$($Entry.Id)'. Supported: RemoveAppx, RemoveCapability, DisableOptionalFeature, SetRegistry, EnableOptionalFeature, AddCapability, RegisterScheduledTask."
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
