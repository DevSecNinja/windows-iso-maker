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

function Invoke-DismExe {
    <#
    .SYNOPSIS
        Run dism.exe with the given arguments and capture output + exit code.
    .DESCRIPTION
        Private helper / mockable seam. The Dism PowerShell module's Appx-provisioned cmdlets
        (Get/Remove-AppxProvisionedPackage) throw "Class not registered" under PowerShell 7
        (Core) because they activate a COM/WinRT class only available in Windows PowerShell 5.1.
        dism.exe is the underlying servicing engine and behaves identically across editions, so
        provisioned-appx operations are driven through it (the "dism.exe fallback" policy noted
        above). Output is forced to English (/English) so parsing is locale-independent, and
        arguments are passed as an array (no shell string; avoids injection).
    .PARAMETER Arguments
        dism.exe arguments as an array.
    .OUTPUTS
        PSCustomObject with ExitCode (int) and Output (string[]).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string[]] $Arguments)

    $output = @(& dism.exe @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = $output
    }
}

function ConvertFrom-DismProvisionedAppx {
    <#
    .SYNOPSIS
        Parse `dism.exe /Get-ProvisionedAppxPackages` output into DisplayName/PackageName objects.
    .DESCRIPTION
        Private, pure helper (unit-testable without dism.exe). Each provisioned package appears
        as a block of "Key : Value" lines; we pair each DisplayName with the PackageName that
        follows it.
    .PARAMETER Output
        The raw dism.exe output lines.
    .OUTPUTS
        System.Object[] of objects with DisplayName and PackageName.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Output)

    $packages = [System.Collections.Generic.List[object]]::new()
    $currentDisplay = $null
    foreach ($line in $Output) {
        if ($line -match '^\s*DisplayName\s*:\s*(.*?)\s*$') {
            $currentDisplay = $Matches[1]
        }
        elseif ($line -match '^\s*PackageName\s*:\s*(.*?)\s*$') {
            $packageName = $Matches[1]
            if ($packageName) {
                $packages.Add([pscustomobject]@{
                        DisplayName = $currentDisplay
                        PackageName = $packageName
                    })
            }
            $currentDisplay = $null
        }
    }
    return $packages.ToArray()
}

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
    # Uses dism.exe (not Get-AppxProvisionedPackage) — see Invoke-DismExe for why.
    $dism = Invoke-DismExe -Arguments @('/English', "/Image:$Path", '/Get-ProvisionedAppxPackages')
    if ($dism.ExitCode -ne 0) {
        $tail = (@($dism.Output) | Select-Object -Last 5) -join ' '
        throw "dism.exe failed to list provisioned Appx packages for '$Path' (exit $($dism.ExitCode)): $tail"
    }
    return ConvertFrom-DismProvisionedAppx -Output @($dism.Output)
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
    # Uses dism.exe (not Remove-AppxProvisionedPackage) — see Invoke-DismExe for why.
    $dism = Invoke-DismExe -Arguments @('/English', "/Image:$Path", '/Remove-ProvisionedAppxPackage', "/PackageName:$PackageName")
    if ($dism.ExitCode -ne 0) {
        $tail = (@($dism.Output) | Select-Object -Last 5) -join ' '
        throw "dism.exe failed to remove provisioned Appx package '$PackageName' (exit $($dism.ExitCode)): $tail"
    }
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

function Get-MountedBuildImage {
    <#
    .SYNOPSIS
        Return images currently mounted for offline servicing (Get-WindowsImage -Mounted).
    .DESCRIPTION
        Private wrapper / mockable seam. Best-effort: returns an empty set rather than throwing
        when the query is unavailable (e.g. non-elevated) so callers can treat it as advisory.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    try {
        return @(Get-WindowsImage -Mounted -ErrorAction Stop)
    }
    catch {
        # Best-effort/advisory: querying mounts can fail (e.g. not elevated). Never let stale-mount
        # detection abort a build — just report nothing to clean.
        return @()
    }
}

function Clear-StaleImageMount {
    <#
    .SYNOPSIS
        Discard any image left mounted at the given path by a previously crashed run.
    .DESCRIPTION
        The orchestrator's finally block dismounts on normal failure and on Ctrl+C, but a hard
        kill or power loss can strand a mounted image at our mount directory — which then makes
        the next Mount-WindowsImage fail. This best-effort helper discards such a stale mount so
        re-runs are self-healing (Principle VI).
    .PARAMETER MountPath
        The mount directory to check.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory = $true)][string] $MountPath)

    $target = try { [System.IO.Path]::GetFullPath($MountPath).TrimEnd('\') } catch { $MountPath }
    foreach ($img in @(Get-MountedBuildImage)) {
        $mp = if ($img.PSObject.Properties['MountPath']) { $img.MountPath } else { $null }
        if (-not $mp) { continue }
        $normalized = try { [System.IO.Path]::GetFullPath($mp).TrimEnd('\') } catch { $mp }
        if ($normalized -ieq $target) {
            Write-BuildLog -Level Warning -Component 'Clear-StaleImageMount' -Message "Found a stale mounted image at '$mp' from a previous run; discarding it."
            try {
                Dismount-BuildImage -Path $mp -Discard
            }
            catch {
                Write-BuildLog -Level Warning -Component 'Clear-StaleImageMount' -Message "Failed to discard stale mount '$mp': $($_.Exception.Message). Run 'dism /Cleanup-Mountpoints' manually."
            }
        }
    }
}
