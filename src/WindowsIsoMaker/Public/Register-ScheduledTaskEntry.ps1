function Register-ScheduledTaskEntry {
    <#
    .SYNOPSIS
        Stage 'RegisterScheduledTask' catalog entries into a mounted offline image.
    .DESCRIPTION
        Installs the persistent helper tasks that keep a setting applied over time — the ones that
        cannot be expressed as a single registry value because the thing they configure does not
        exist yet at image-build time (a mouse that will be paired later, a monitor that will be
        attached later).

        An offline image cannot register a scheduled task directly: the Task Scheduler service is
        not running and its task store is not a plain file drop (a task lives in both
        %SystemRoot%\System32\Tasks and the TaskCache registry subtree, written together by the
        service). So this applier does the two halves it CAN do offline:

          1. writes the payload script and the generated task XML into the image under
             ProgramData\WindowsIsoMaker\Tasks, and
          2. arms a machine RunOnce command that registers the task from that XML at first logon —
             the same Microsoft-documented first-boot mechanism the catalog already uses for
             tzutil and friends.

        RunOnce runs once and is consumed by Windows, which is precisely the right shape here: its
        one job is to create a task that then persists on its own.

        Re-runs are idempotent (FR-017): unchanged payload plus an already-armed identical RunOnce
        command is reported AlreadyApplied. -WhatIf reports without writing (FR-016). The SOFTWARE
        hive is always unloaded in a finally block (Principle VI).
    .PARAMETER MountPath
        Root of the mounted offline image.
    .PARAMETER Catalog
        Catalog entries to apply. Entries whose Action is not 'RegisterScheduledTask' are ignored.
    .PARAMETER Architecture
        Target architecture; entries not applicable to it are skipped.
    .PARAMETER Config
        Optional resolved BuildConfiguration (for context/logging).
    .EXAMPLE
        Register-ScheduledTaskEntry -MountPath C:\mount -Catalog $cfg.SelectedCatalog -Architecture amd64
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

    $taskEntries = @(@($Catalog) | Where-Object {
            $_.Action -eq 'RegisterScheduledTask' -and (@($_.Arch) -contains $Architecture)
        })

    $results = [System.Collections.Generic.List[object]]::new()
    if ($taskEntries.Count -eq 0) {
        return $results.ToArray()
    }

    $handle = $null
    $loaded = $false
    try {
        if (-not $WhatIfPreference) {
            $handle = Mount-OfflineRegistryHive -MountPath $MountPath -Hive 'SOFTWARE'
            $loaded = $true
        }
        $mountKey = if ($handle) { $handle.MountKey } else { 'HKLM\WIM_Preview_SOFTWARE' }

        foreach ($entry in $taskEntries) {
            $result = [pscustomobject]@{
                PSTypeName = 'WindowsIsoMaker.ChangeResult'
                Id         = $entry.Id
                Type       = 'ScheduledTask'
                Status     = 'Skipped'
                Reason     = $null
                Citation   = $entry.Citation
            }

            try {
                $definition = Get-CatalogTaskDefinition -Entry $entry
                $paths = Get-CatalogTaskPath -RootPath $MountPath -Definition $definition
                $xml = New-CatalogTaskXml -Definition $definition -ScriptPath $paths.TargetScriptPath
                $command = Get-CatalogTaskRegistrationCommand -Definition $definition -XmlPath $paths.TargetXmlPath
                $runOnceName = "!Wim_$($entry.Id)"

                if ($WhatIfPreference) {
                    $result.Status = 'Skipped'
                    $result.Reason = "Preview (-WhatIf): would stage '$($definition.ScriptName)' and arm first-boot registration of '$($definition.FullTaskName)'."
                    $results.Add($result)
                    continue
                }

                $payloadChanged = $false
                if ($PSCmdlet.ShouldProcess($paths.ScriptPath, 'Stage scheduled-task payload')) {
                    $payloadChanged = Write-CatalogTaskPayload -Paths $paths -Script $definition.Script -Xml $xml
                }

                $currentCommand = Get-OfflineRegistryValue -MountKey $mountKey -Path $script:WimRunOncePath -Name $runOnceName
                $commandCurrent = ($null -ne $currentCommand -and "$currentCommand" -eq $command)

                if (-not $payloadChanged -and $commandCurrent) {
                    $result.Status = 'AlreadyApplied'
                    $result.Reason = "Task '$($definition.FullTaskName)' already staged and armed for first boot."
                }
                elseif ($PSCmdlet.ShouldProcess("SOFTWARE\$script:WimRunOncePath\$runOnceName", "Arm first-boot registration of '$($definition.FullTaskName)'")) {
                    Set-OfflineRegistryValue -MountKey $mountKey -Path $script:WimRunOncePath -Name $runOnceName -Kind 'String' -Value $command
                    $result.Status = 'Applied'
                    $result.Reason = "Staged '$($definition.ScriptName)' and armed first-boot registration of '$($definition.FullTaskName)'."
                }
            }
            catch {
                $result.Status = 'Failed'
                $result.Reason = $_.Exception.Message
                Write-BuildLog -Level Warning -Component 'Register-ScheduledTaskEntry' -Message "Entry '$($entry.Id)' failed: $($_.Exception.Message)"
            }

            $results.Add($result)
        }
    }
    finally {
        if ($loaded -and $handle) {
            Dismount-OfflineRegistryHive -Handle $handle
        }
    }

    return $results.ToArray()
}
