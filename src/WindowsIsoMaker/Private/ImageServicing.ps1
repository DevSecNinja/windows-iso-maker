<#
    Thin, private wrapper functions around the Windows image-servicing cmdlets (the Dism
    PowerShell module) and Appx/Capability provisioning cmdlets.

    Why wrappers exist:
      * They give the module a single, mockable seam for every external servicing call, so
        the Pester suite can run on ANY platform (the real Dism cmdlets only exist on
        Windows). Public functions call these wrappers; tests mock the wrappers.
      * They centralize the "Dism module first, dism.exe fallback" policy (Principle V /
        Complexity Tracking) in one place.

    These are intentionally thin pass-throughs. The ShouldProcess/-WhatIf gating and change
    accounting live in the PUBLIC functions, so the state-changing analyzer rule is
    suppressed here deliberately.
#>

function Get-ImageProvisionedAppx {
    <#
    .SYNOPSIS
        Return the provisioned Appx packages in a mounted offline image.
    .PARAMETER Path
        Mount path of the offline image.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory = $true)][string] $Path)
    return @(Get-AppxProvisionedPackage -Path $Path)
}

function Remove-ImageProvisionedAppx {
    <#
    .SYNOPSIS
        Remove a provisioned Appx package from a mounted offline image.
    .PARAMETER Path
        Mount path of the offline image.
    .PARAMETER PackageName
        The exact provisioned PackageName to remove.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $PackageName
    )
    Remove-AppxProvisionedPackage -Path $Path -PackageName $PackageName -ErrorAction Stop | Out-Null
}

function Get-ImageCapability {
    <#
    .SYNOPSIS
        Return the Windows capabilities available/installed in a mounted offline image.
    .PARAMETER Path
        Mount path of the offline image.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory = $true)][string] $Path)
    return @(Get-WindowsCapability -Path $Path)
}

function Remove-ImageCapability {
    <#
    .SYNOPSIS
        Remove a Windows capability from a mounted offline image.
    .PARAMETER Path
        Mount path of the offline image.
    .PARAMETER Name
        The capability Name to remove.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Name
    )
    Remove-WindowsCapability -Path $Path -Name $Name -ErrorAction Stop | Out-Null
}

function Get-ImageOptionalFeature {
    <#
    .SYNOPSIS
        Return the optional features (and their state) in a mounted offline image.
    .PARAMETER Path
        Mount path of the offline image.
    .PARAMETER FeatureName
        Optional specific feature name to query.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter()][string] $FeatureName
    )
    if ($PSBoundParameters.ContainsKey('FeatureName') -and $FeatureName) {
        return @(Get-WindowsOptionalFeature -Path $Path -FeatureName $FeatureName)
    }
    return @(Get-WindowsOptionalFeature -Path $Path)
}

function Enable-ImageOptionalFeature {
    <#
    .SYNOPSIS
        Enable a Windows optional feature on a mounted offline image.
    .PARAMETER Path
        Mount path of the offline image.
    .PARAMETER FeatureName
        The optional feature to enable (e.g. 'Microsoft-Windows-Subsystem-Linux').
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $FeatureName
    )
    Enable-WindowsOptionalFeature -Path $Path -FeatureName $FeatureName -All -ErrorAction Stop | Out-Null
}

function Add-ImageCapability {
    <#
    .SYNOPSIS
        Add a Windows capability to a mounted offline image.
    .PARAMETER Path
        Mount path of the offline image.
    .PARAMETER Name
        The capability Name to add.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Name
    )
    Add-WindowsCapability -Path $Path -Name $Name -ErrorAction Stop | Out-Null
}

function Get-BuildImageInfo {
    <#
    .SYNOPSIS
        Return image (edition/index) information for a .wim/.esd file.
    .PARAMETER ImagePath
        Path to install.wim/install.esd.
    .PARAMETER Index
        Optional specific index to query.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][string] $ImagePath,
        [Parameter()][int] $Index
    )
    if ($PSBoundParameters.ContainsKey('Index') -and $Index -gt 0) {
        return @(Get-WindowsImage -ImagePath $ImagePath -Index $Index)
    }
    return @(Get-WindowsImage -ImagePath $ImagePath)
}

function Mount-BuildImage {
    <#
    .SYNOPSIS
        Mount a .wim/.esd image index at a path for offline servicing.
    .PARAMETER ImagePath
        Path to install.wim/install.esd.
    .PARAMETER Index
        Image index to mount.
    .PARAMETER Path
        Empty directory to mount the image at.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $ImagePath,
        [Parameter(Mandatory = $true)][int] $Index,
        [Parameter(Mandatory = $true)][string] $Path
    )
    Mount-WindowsImage -ImagePath $ImagePath -Index $Index -Path $Path -ErrorAction Stop | Out-Null
}

function Dismount-BuildImage {
    <#
    .SYNOPSIS
        Dismount a mounted image, saving or discarding changes.
    .PARAMETER Path
        The mount path to dismount.
    .PARAMETER Save
        Commit changes back to the image.
    .PARAMETER Discard
        Discard changes (used on failure cleanup — never present corrupt output).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter()][switch] $Save,
        [Parameter()][switch] $Discard
    )
    if ($Save) {
        Dismount-WindowsImage -Path $Path -Save -ErrorAction Stop | Out-Null
    }
    else {
        Dismount-WindowsImage -Path $Path -Discard -ErrorAction Stop | Out-Null
    }
}
