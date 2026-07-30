#Requires -Version 5.1
<#
    windows-iso-maker — reverse mouse wheel scroll direction (catalog id: task-reverse-mouse-scroll).

    Sets FlipFlopWheel = 1 on every device that feeds the mouse stack (Service = mouhid, which
    covers both mice and mouse-emulating touchpads), then restarts ONLY the devices it changed.
    mouhid reads FlipFlopWheel when the device stack starts, so an already-running device keeps the
    old direction until it is restarted; restarting just the changed devices means the restart's own
    arrival event finds nothing left to do, so the trigger cannot feed itself indefinitely.

    Managed by windows-iso-maker: this file is the source of the payload, and the appliers copy it
    verbatim to %ProgramData%\WindowsIsoMaker\Tasks on the target machine. Edit it here, not there
    — the staged copy is overwritten on the next run of build.ps1/post-install.ps1.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$enumRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\HID'
if (-not (Test-Path -LiteralPath $enumRoot)) { return }

$changed = New-Object System.Collections.Generic.List[string]

foreach ($container in Get-ChildItem -LiteralPath $enumRoot -ErrorAction SilentlyContinue) {
    foreach ($instance in Get-ChildItem -LiteralPath $container.PSPath -ErrorAction SilentlyContinue) {
        $properties = Get-ItemProperty -LiteralPath $instance.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $properties) { continue }
        if ($properties.PSObject.Properties.Name -notcontains 'Service') { continue }
        if ($properties.Service -ne 'mouhid') { continue }

        $parametersPath = Join-Path -Path $instance.PSPath -ChildPath 'Device Parameters'
        if (-not (Test-Path -LiteralPath $parametersPath)) { continue }

        $parameters = Get-ItemProperty -LiteralPath $parametersPath -ErrorAction SilentlyContinue
        $current = if ($null -ne $parameters -and ($parameters.PSObject.Properties.Name -contains 'FlipFlopWheel')) {
            $parameters.FlipFlopWheel
        }
        else { $null }

        if ($current -eq 1) { continue }

        New-ItemProperty -LiteralPath $parametersPath -Name 'FlipFlopWheel' -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        $changed.Add("HID\$($container.PSChildName)\$($instance.PSChildName)")
    }
}

foreach ($instanceId in $changed) {
    & pnputil.exe /restart-device $instanceId 2>&1 | Out-Null
}