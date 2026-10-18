#Requires -Version 5.1
<#
.SYNOPSIS
    Private helpers for preparing a Windows 11 USB installation stick with the post-install
    toolkit (New-PostInstallUsb).
.DESCRIPTION
    These helpers inspect a target volume, validate that it really carries Windows Setup media,
    derive the media architecture from its EFI boot loader, and render the MINIMAL
    (oobeSystem-only) answer file used to hook post-install into the first logon.

    They deliberately never modify the Windows Setup media itself: the stick is treated as
    read-only apart from the additional toolkit folder and the optional Autounattend.xml.
#>

function Get-UsbTargetInfo {
    <#
    .SYNOPSIS
        Probe a target path/drive and report volume facts used to validate a USB stick.
    .DESCRIPTION
        Returns the normalized root, whether the path exists and is a volume root, and (on Windows,
        when the target is a drive letter) the volume label, file system, free space and whether the
        drive is removable. Probing is best-effort: on non-Windows hosts, or for a plain folder
        target, the volume facts are reported as $null/unknown instead of throwing, so the caller
        can still stage a toolkit into a directory.
    .PARAMETER Path
        The target path: a drive specification ('E:', 'E:\') or any directory.
    .EXAMPLE
        Get-UsbTargetInfo -Path 'E:'
    .OUTPUTS
        PSCustomObject (WindowsIsoMaker.UsbTargetInfo).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    # Normalize 'E:' -> 'E:\' so Join-Path yields 'E:\folder' and not the per-drive working dir.
    $root = $Path.Trim()
    if ($root -match '^[A-Za-z]:$') { $root = "$root\" }

    $driveLetter = $null
    if ($root -match '^([A-Za-z]):') { $driveLetter = $Matches[1].ToUpperInvariant() }

    $info = [pscustomobject]@{
        PSTypeName    = 'WindowsIsoMaker.UsbTargetInfo'
        Path          = $root
        DriveLetter   = $driveLetter
        IsVolumeRoot  = ($root -match '^[A-Za-z]:\\?$')
        Exists        = (Test-Path -LiteralPath $root)
        Label         = $null
        FileSystem    = $null
        FreeSpaceByte = $null
        IsRemovable   = $null
        DriveType     = $null
        BusType       = $null
    }

    if (-not $driveLetter) { return $info }

    try {
        $drive = Get-CimInstance -ClassName 'Win32_LogicalDisk' `
            -Filter ("DeviceID='{0}:'" -f $driveLetter) -ErrorAction Stop
        if ($drive) {
            # Win32_LogicalDisk DriveType: 2 = Removable, 3 = Local (fixed), 5 = CD-ROM.
            # https://learn.microsoft.com/windows/win32/cimwin32prov/win32-logicaldisk
            $info.DriveType = [int]$drive.DriveType
            $info.IsRemovable = ([int]$drive.DriveType -eq 2)
            $info.Label = [string]$drive.VolumeName
            $info.FileSystem = [string]$drive.FileSystem
            $info.FreeSpaceByte = [int64]$drive.FreeSpace
        }
    }
    catch {
        # Not Windows, no CIM, or the drive is not a local volume (e.g. a network share).
        Write-BuildLog -Level Verbose -Component 'Get-UsbTargetInfo' -Message "Could not query volume '$($driveLetter):': $($_.Exception.Message)"
    }

    # DriveType alone is not a reliable "is this a USB stick" test: USB SSDs and USB-NVMe
    # enclosures - increasingly what people use for Windows media, because the install image is
    # large - report DriveType 3 (fixed). Fall back to the physical bus so those are not rejected.
    if ($info.IsRemovable -eq $false) {
        try {
            $partition = Get-CimInstance -ClassName 'MSFT_Partition' -Namespace 'root/Microsoft/Windows/Storage' `
                -Filter ("DriveLetter='{0}'" -f $driveLetter) -ErrorAction Stop | Select-Object -First 1
            if ($partition) {
                $disk = Get-CimInstance -ClassName 'MSFT_Disk' -Namespace 'root/Microsoft/Windows/Storage' `
                    -Filter ("Number={0}" -f $partition.DiskNumber) -ErrorAction Stop | Select-Object -First 1
                # MSFT_Disk BusType 7 = USB.
                # https://learn.microsoft.com/previous-versions/windows/desktop/stormgmt/msft-disk
                if ($disk -and [int]$disk.BusType -eq 7) {
                    $info.BusType = 'USB'
                    $info.IsRemovable = $true
                    Write-BuildLog -Level Verbose -Component 'Get-UsbTargetInfo' -Message "Volume '$($driveLetter):' reports as fixed but sits on a USB bus; treating it as removable."
                }
            }
        }
        catch {
            Write-BuildLog -Level Verbose -Component 'Get-UsbTargetInfo' -Message "Could not query the storage bus for '$($driveLetter):': $($_.Exception.Message)"
        }
    }

    return $info
}

function Test-WindowsSetupMedia {
    <#
    .SYNOPSIS
        Verify that a path is the root of Windows Setup installation media.
    .DESCRIPTION
        Checks for the files Windows Setup media always carries: setup.exe, a sources directory
        holding install.wim or install.esd, and a boot loader directory (efi\ or boot\). Returns a
        result object describing what was found rather than throwing, so the caller decides how
        strict to be.
    .PARAMETER Path
        Root of the media to inspect (typically the USB stick's drive root).
    .EXAMPLE
        Test-WindowsSetupMedia -Path 'E:\'
    .OUTPUTS
        PSCustomObject (WindowsIsoMaker.SetupMediaInfo).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $setupExe = Join-Path -Path $Path -ChildPath 'setup.exe'
    $sources = Join-Path -Path $Path -ChildPath 'sources'
    $installWim = Join-Path -Path $sources -ChildPath 'install.wim'
    $installEsd = Join-Path -Path $sources -ChildPath 'install.esd'
    $efiDir = Join-Path -Path $Path -ChildPath 'efi'
    $bootDir = Join-Path -Path $Path -ChildPath 'boot'

    $hasSetup = Test-Path -LiteralPath $setupExe -PathType Leaf
    $hasWim = Test-Path -LiteralPath $installWim -PathType Leaf
    $hasEsd = Test-Path -LiteralPath $installEsd -PathType Leaf
    $hasBoot = (Test-Path -LiteralPath $efiDir -PathType Container) -or (Test-Path -LiteralPath $bootDir -PathType Container)

    $missing = [System.Collections.Generic.List[string]]::new()
    if (-not $hasSetup) { $missing.Add('setup.exe') }
    if (-not ($hasWim -or $hasEsd)) { $missing.Add('sources\install.wim or sources\install.esd') }
    if (-not $hasBoot) { $missing.Add('efi\ or boot\ (boot loader)') }

    $imageFile = $null
    $imageFormat = $null
    if ($hasWim) { $imageFile = $installWim; $imageFormat = 'wim' }
    elseif ($hasEsd) { $imageFile = $installEsd; $imageFormat = 'esd' }

    return [pscustomobject]@{
        PSTypeName   = 'WindowsIsoMaker.SetupMediaInfo'
        Path         = $Path
        IsSetupMedia = ($missing.Count -eq 0)
        ImageFile    = $imageFile
        ImageFormat  = $imageFormat
        Missing      = @($missing)
    }
}

function Get-SetupMediaArchitecture {
    <#
    .SYNOPSIS
        Derive the architecture of Windows Setup media from its EFI boot loader.
    .DESCRIPTION
        Windows media ships an architecture-specific UEFI boot loader: efi\boot\bootx64.efi for
        amd64 and efi\boot\bootaa64.efi for arm64. That file is the most reliable architecture
        marker available without mounting the image, so it is used here. Returns $null when the
        media cannot be classified (the caller then falls back to an explicit -Architecture or the
        running host).
    .PARAMETER Path
        Root of the media to inspect.
    .EXAMPLE
        Get-SetupMediaArchitecture -Path 'E:\'
    .OUTPUTS
        System.String - 'amd64', 'arm64', or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $efiBoot = Join-Path -Path (Join-Path -Path $Path -ChildPath 'efi') -ChildPath 'boot'
    if (Test-Path -LiteralPath (Join-Path -Path $efiBoot -ChildPath 'bootaa64.efi')) { return 'arm64' }
    if (Test-Path -LiteralPath (Join-Path -Path $efiBoot -ChildPath 'bootx64.efi')) { return 'amd64' }
    return $null
}

function New-FirstLogonUnattendXml {
    <#
    .SYNOPSIS
        Render the MINIMAL (oobeSystem-only) Autounattend.xml that runs commands at first logon.
    .DESCRIPTION
        Unlike New-AutounattendXml - which renders the full answer file for an ISO this tool builds
        (disk layout, edition selection, OOBE skip) - this renders an answer file that contains
        NOTHING but a FirstLogonCommands block. Windows Setup therefore behaves exactly as it
        normally would (interactive edition/partition/OOBE, including an Entra ID sign-in); the only
        addition is that the given commands run once at the first logon.

        Note that FirstLogonCommands run elevated only when the first user to sign in is a local
        administrator - see the template's header comment and New-PostInstallUsb's help.

        That distinction matters: dropping the full build answer file onto stock media would wipe
        the configured disk. This file never touches the install phase.

        Rendering is deterministic - the same input yields byte-identical output. No password or
        secret is ever written (Constitution Principle VII).
    .PARAMETER Command
        One or more command lines to run, in order, at the first logon.
    .PARAMETER Architecture
        Target architecture ('amd64' | 'arm64') written into processorArchitecture.
    .PARAMETER Description
        Optional human-readable note rendered into the file's header comment.
    .PARAMETER TemplatePath
        Directory containing firstlogon.xml.template. Defaults to templates/autounattend/.
    .EXAMPLE
        New-FirstLogonUnattendXml -Command 'powershell.exe -File X.ps1' -Architecture amd64
    .OUTPUTS
        System.String - the rendered XML.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure renderer: returns the XML as a string and writes nothing. The caller (New-PostInstallUsb) owns ShouldProcess for the actual file write.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Command,

        [Parameter(Mandatory = $true)]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter()]
        [string] $Description = '',

        [Parameter()]
        [string] $TemplatePath
    )

    if (-not $TemplatePath) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $script:ModuleRoot)
        $TemplatePath = Join-Path -Path $repoRoot -ChildPath 'templates/autounattend'
    }
    $templateFile = Join-Path -Path $TemplatePath -ChildPath 'firstlogon.xml.template'
    if (-not (Test-Path -LiteralPath $templateFile)) {
        throw "First-logon unattend template not found: '$templateFile'."
    }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('      <FirstLogonCommands>')
    $order = 1
    foreach ($line in $Command) {
        $safeCommand = [System.Security.SecurityElement]::Escape([string]$line)
        [void]$builder.AppendLine('        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">')
        [void]$builder.AppendLine("          <Order>$order</Order>")
        [void]$builder.AppendLine("          <CommandLine>$safeCommand</CommandLine>")
        [void]$builder.AppendLine("          <Description>windows-iso-maker post-install</Description>")
        [void]$builder.AppendLine('        </SynchronousCommand>')
        $order++
    }
    [void]$builder.Append('      </FirstLogonCommands>')

    $xml = Get-Content -LiteralPath $templateFile -Raw
    $replacements = @{
        '{{PROCESSOR_ARCHITECTURE}}' = $Architecture
        '{{DESCRIPTION}}'            = [System.Security.SecurityElement]::Escape($Description)
        '{{FIRSTLOGON_FRAGMENT}}'    = $builder.ToString()
    }
    foreach ($token in $replacements.Keys) {
        $xml = $xml.Replace($token, $replacements[$token])
    }

    return $xml
}
