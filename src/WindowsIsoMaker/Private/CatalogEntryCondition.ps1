<#
.SYNOPSIS
    Applicability conditions for change-catalog entries (private helpers).
.DESCRIPTION
    Some catalog entries only make sense on particular hardware — for example a power-button
    tweak that exists because Surface Laptop keyboards put the power key next to Delete. Rather
    than adding a per-feature switch (forbidden by Constitution Principle III), such an entry
    declares an optional `Condition` block:

        Condition = @{
            Description = 'Microsoft Surface Laptop devices only.'
            Script      = '<PowerShell expression returning $true/$false>'
            Citation    = 'https://learn.microsoft.com/...'
        }

    The condition describes the TARGET machine, so it can only be answered where that machine is
    running:

      * Offline build (Invoke-CatalogEntry)   — the build agent is NOT the target machine, so the
        condition is deliberately NOT evaluated. The entry is reported NotApplicable with a reason
        pointing at post-install.ps1. This mirrors how OnlyIfKeyExists entries behave for
        components a clean image does not contain.
      * Online post-install (Invoke-OnlineCatalogEntry) — the condition is evaluated against the
        live machine and the entry is applied only when it is satisfied.

    Evaluation ALWAYS fails closed: a condition that throws, returns nothing, or returns a false-y
    value leaves the entry unapplied. A machine-specific tweak is never applied to hardware it was
    not meant for just because detection broke.

    Trust boundary: `Script` is PowerShell that is executed as-is. Catalog files are
    repository-controlled data reviewed under Principle II (the module already bakes catalog-authored
    `powershell.exe -Command` payloads into RunOnce entries), so this adds no new trust boundary —
    but a condition must never be sourced from untrusted input.
#>

function Get-CatalogEntryCondition {
    <#
    .SYNOPSIS
        Return a catalog entry's optional Condition block, or $null when it declares none.
    .DESCRIPTION
        StrictMode-safe accessor that handles both entry shapes in use: raw hashtables (as authored
        in config/catalog.*.psd1 and used directly by tests) and the pscustomobject form produced by
        Import-ChangeCatalog. A missing key must never throw.
    .PARAMETER Entry
        A single catalog entry.
    .OUTPUTS
        System.Object (the Condition block) or $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Entry
    )

    $value = $null
    if ($Entry -is [System.Collections.IDictionary]) {
        if ($Entry.Contains('Condition')) { $value = $Entry['Condition'] }
    }
    elseif ($Entry.PSObject.Properties.Name -contains 'Condition') {
        $value = $Entry.Condition
    }

    if ($null -eq $value) { return $null }
    return $value
}

function Get-CatalogConditionField {
    <#
    .SYNOPSIS
        Read a single named field from a Condition block (private helper).
    .DESCRIPTION
        StrictMode-safe field accessor mirroring Get-CatalogEntryCondition, so a Condition authored
        as a hashtable and one round-tripped into a pscustomobject behave identically.
    .PARAMETER Condition
        The Condition block.
    .PARAMETER Name
        Field name to read ('Script', 'Description', 'Citation').
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Condition,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    if ($Condition -is [System.Collections.IDictionary]) {
        if ($Condition.Contains($Name)) { return [string]$Condition[$Name] }
        return ''
    }
    if ($Condition.PSObject.Properties.Name -contains $Name) {
        return [string]$Condition.$Name
    }
    return ''
}

function Test-CatalogEntryCondition {
    <#
    .SYNOPSIS
        Evaluate a catalog entry's applicability Condition against the LIVE machine.
    .DESCRIPTION
        Returns a verdict object describing whether the entry applies here. Only ever call this on
        the machine the entry targets (the online post-install path) — the offline build path must
        report conditional entries NotApplicable instead, because the build agent is not the target.

        The verdict is fail-closed: if the condition script throws, produces no output, or yields a
        false-y value, Satisfied is $false and Reason explains why. Evaluation is read-only by
        contract (a condition detects, it never changes state), so it is safe to run under -WhatIf
        and gives an accurate preview.
    .PARAMETER Entry
        A single catalog entry. An entry with no Condition is always satisfied.
    .EXAMPLE
        $verdict = Test-CatalogEntryCondition -Entry $entry
        if (-not $verdict.Satisfied) { Write-Host $verdict.Reason }
    .OUTPUTS
        PSCustomObject with HasCondition, Satisfied, Description and Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Entry
    )

    $verdict = [pscustomobject]@{
        PSTypeName   = 'WindowsIsoMaker.ConditionVerdict'
        HasCondition = $false
        Satisfied    = $true
        Description  = $null
        Reason       = $null
    }

    $condition = Get-CatalogEntryCondition -Entry $Entry
    if ($null -eq $condition) {
        return $verdict
    }

    $verdict.HasCondition = $true
    $script = Get-CatalogConditionField -Condition $condition -Name 'Script'
    $description = Get-CatalogConditionField -Condition $condition -Name 'Description'
    $verdict.Description = if ($description) { $description } else { $null }
    $label = if ($description) { $description } else { 'declared condition' }

    if ([string]::IsNullOrWhiteSpace($script)) {
        # Fail closed rather than throw: a malformed Condition is caught by the schema gate in
        # tests/Catalog.Schema.Tests.ps1, and a build must not apply a targeted tweak blindly.
        $verdict.Satisfied = $false
        $verdict.Reason = "Entry '$($Entry.Id)' declares a Condition with no Script; treated as not applicable."
        Write-BuildLog -Level Warning -Component 'Test-CatalogEntryCondition' -Message $verdict.Reason
        return $verdict
    }

    try {
        $scriptBlock = [scriptblock]::Create($script)
    }
    catch {
        $verdict.Satisfied = $false
        $verdict.Reason = "Condition for '$($Entry.Id)' ($label) is not valid PowerShell: $($_.Exception.Message). Entry not applied."
        Write-BuildLog -Level Warning -Component 'Test-CatalogEntryCondition' -Message $verdict.Reason
        return $verdict
    }

    try {
        # Take the last emitted object so a multi-statement condition (e.g. a Get-CimInstance query
        # followed by the comparison) is judged on its final expression.
        $raw = & $scriptBlock | Select-Object -Last 1
        $verdict.Satisfied = [bool]$raw
        $verdict.Reason = if ($verdict.Satisfied) {
            "Condition satisfied on this machine ($label)."
        }
        else {
            "Condition not satisfied on this machine ($label); entry does not apply here."
        }
    }
    catch {
        $verdict.Satisfied = $false
        $verdict.Reason = "Condition for '$($Entry.Id)' ($label) could not be evaluated: $($_.Exception.Message). Entry not applied (fail-closed)."
        Write-BuildLog -Level Warning -Component 'Test-CatalogEntryCondition' -Message $verdict.Reason
    }

    return $verdict
}

function New-ConditionNotApplicableResult {
    <#
    .SYNOPSIS
        Build the ChangeResult returned when a conditional entry is not applied (private helper).
    .PARAMETER Entry
        The catalog entry that was skipped.
    .PARAMETER Reason
        Human-readable explanation recorded in the run report / Image BOM.
    .OUTPUTS
        PSCustomObject (ChangeResult).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory factory for a ChangeResult describing an entry that was deliberately NOT applied; it changes no system state, so there is nothing for -WhatIf to gate.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Entry,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Reason
    )

    return [pscustomobject]@{
        PSTypeName = 'WindowsIsoMaker.ChangeResult'
        Id         = $Entry.Id
        Type       = $Entry.Type
        Status     = 'NotApplicable'
        Reason     = $Reason
        Citation   = $Entry.Citation
    }
}
