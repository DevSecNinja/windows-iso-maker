<#
    Shared helpers for the 'RegisterScheduledTask' catalog Action.

    Why this Action exists: some settings are not a value you can write once. FlipFlopWheel (mouse
    scroll direction) lives PER DEVICE INSTANCE under SYSTEM\...\Enum\HID\<instance>\Device
    Parameters, so a mouse paired after the image was built — or after post-install.ps1 ran — keeps
    the driver default and is never reached by a one-shot RunOnce command. The same is true of
    display placement, which only exists once a monitor has been attached. Both need a small helper
    that RE-RUNS whenever the relevant device shows up, which is exactly what a Task Scheduler
    event-triggered task provides.

    Both the offline and the online appliers share this file: the payload script and the task XML
    are generated identically, so an image build and a post-install run install byte-identical
    tasks. Every task is created inside a single Task Scheduler folder (\WindowsIsoMaker) so the
    tool's footprint is greppable, enumerable and removable in one place, and so later tasks join
    the same folder rather than scattering across the task library.

    Payload scripts are catalog DATA (Target.Script), not code in this module — adding another
    persistent helper stays a catalog edit (Constitution Principle II / FR-024).
#>

# Task Scheduler folder that owns every task this tool creates.
$script:WimTaskFolder = '\WindowsIsoMaker'
# Payload scripts + generated task XML are staged here, relative to the system drive root
# (the mounted image root when servicing offline).
$script:WimTaskPayloadRelativePath = 'ProgramData\WindowsIsoMaker\Tasks'
# Machine RunOnce key (relative to the SOFTWARE hive root) used to register staged tasks at first
# boot, since an offline image cannot register them directly.
$script:WimRunOncePath = 'Microsoft\Windows\CurrentVersion\RunOnce'
# Payload scripts live here in the repository, beside the catalog that references them.
$script:WimTaskSourceRelativePath = 'config\tasks'

function Get-CatalogTaskScriptDirectory {
    <#
    .SYNOPSIS
        Resolve the repository directory holding task payload scripts (config/tasks).
    .DESCRIPTION
        Payload scripts are kept as real .ps1 files rather than here-strings inside the catalog so
        PSScriptAnalyzer lints them and the schema gate can parse them as files. This mirrors how
        Import-ChangeCatalog locates config/, so both resolve against the same repository root.
    .OUTPUTS
        System.String — full path to the payload script directory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $repoRoot = Split-Path -Parent (Split-Path -Parent $script:ModuleRoot)
    return (Join-Path -Path $repoRoot -ChildPath $script:WimTaskSourceRelativePath)
}

function Get-CatalogTaskDefinition {
    <#
    .SYNOPSIS
        Normalise a RegisterScheduledTask entry's Target into a validated task definition.
    .DESCRIPTION
        Reads the optional Target fields StrictMode-safely (via Get-RegistryTargetOption, the
        established catalog-Target reader) and applies the defaults every task shares: the
        \WindowsIsoMaker folder and the SYSTEM principal.

        The payload itself is NOT stored in the catalog. Target.ScriptFile names a .ps1 file under
        config/tasks, which is read here — keeping the payload a real script that PSScriptAnalyzer
        and the schema gate can both analyse, instead of a here-string that nothing lints.
    .PARAMETER Entry
        A single catalog entry whose Action is 'RegisterScheduledTask'.
    .PARAMETER ScriptDirectory
        Directory holding the payload scripts. Defaults to the repository's config/tasks.
    .OUTPUTS
        PSCustomObject with TaskName, TaskFolder, FullTaskName, ScriptName, Script, Triggers,
        PrincipalId, LogonType, RunLevel and Description.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Entry,

        [Parameter()]
        [string] $ScriptDirectory
    )

    $target = $Entry.Target
    if ($null -eq $target) {
        throw "Entry '$($Entry.Id)' has Action 'RegisterScheduledTask' but no Target."
    }

    $taskName = [string](Get-RegistryTargetOption -Target $target -Name 'TaskName')
    if ([string]::IsNullOrWhiteSpace($taskName)) {
        throw "Entry '$($Entry.Id)' must declare Target.TaskName."
    }

    $scriptName = [string](Get-RegistryTargetOption -Target $target -Name 'ScriptFile')
    if ([string]::IsNullOrWhiteSpace($scriptName)) {
        throw "Entry '$($Entry.Id)' must declare Target.ScriptFile (the payload script under config/tasks)."
    }
    # A path separator would let an entry read outside config/tasks; payloads are repository files,
    # so only a bare file name is accepted.
    if ($scriptName -match '[\\/]' -or $scriptName -eq '.' -or $scriptName -eq '..') {
        throw "Entry '$($Entry.Id)' Target.ScriptFile must be a file name in config/tasks, not a path ('$scriptName')."
    }

    if ([string]::IsNullOrWhiteSpace($ScriptDirectory)) {
        $ScriptDirectory = Get-CatalogTaskScriptDirectory
    }
    $scriptPath = Join-Path -Path $ScriptDirectory -ChildPath $scriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Entry '$($Entry.Id)' references payload script '$scriptName', which was not found in '$ScriptDirectory'."
    }

    # Read with an explicit encoding: Get-Content -Raw decodes a BOM-less UTF-8 file as ANSI under
    # Windows PowerShell 5.1, which would corrupt non-ASCII characters and break the staged-file
    # comparison that makes re-runs idempotent.
    $scriptBody = [System.IO.File]::ReadAllText($scriptPath, (New-Object System.Text.UTF8Encoding($false)))
    if ([string]::IsNullOrWhiteSpace($scriptBody)) {
        throw "Entry '$($Entry.Id)' payload script '$scriptName' is empty."
    }

    $folder = [string](Get-RegistryTargetOption -Target $target -Name 'TaskFolder')
    if ([string]::IsNullOrWhiteSpace($folder)) { $folder = $script:WimTaskFolder }
    $folder = '\' + $folder.Trim('\')

    $triggers = @(Get-RegistryTargetOption -Target $target -Name 'Triggers')
    if ($triggers.Count -eq 0) {
        throw "Entry '$($Entry.Id)' must declare at least one Target.Triggers entry."
    }

    # Tasks here run as SYSTEM: they configure machine state (HKLM device parameters, pnputil) and
    # must work with nobody signed in. That also keeps them out of the interactive desktop
    # entirely, so they can never flash a window at the user.
    $runLevel = [string](Get-RegistryTargetOption -Target $target -Name 'RunLevel')
    if ([string]::IsNullOrWhiteSpace($runLevel)) { $runLevel = 'HighestAvailable' }

    return [pscustomobject]@{
        PSTypeName   = 'WindowsIsoMaker.TaskDefinition'
        TaskName     = $taskName
        TaskFolder   = $folder
        FullTaskName = "$folder\$taskName"
        ScriptName   = $scriptName
        Script       = $scriptBody
        Triggers     = $triggers
        PrincipalId  = 'S-1-5-18'
        LogonType    = 'S4U'
        RunLevel     = $runLevel
        Description  = [string]$Entry.Description
    }
}

function New-CatalogTaskTriggerXml {
    <#
    .SYNOPSIS
        Render one trigger definition as its Task Scheduler XML element.
    .DESCRIPTION
        Supports the trigger types the catalog needs:
          Event — subscribes to a Windows event log query, which is how a task reacts to a device
                  arriving (e.g. Kernel-PnP 410 "Device ... was started"). This is the one the
                  shipped entry uses; because every device stack also starts at boot and at logon,
                  it covers those without a separate trigger.
          Logon / Boot — available for a payload that genuinely has no device event to key off.
        An optional Delay (xs:duration, e.g. 'PT5S') lets the device stack settle before the
        payload inspects it.

        There is deliberately no repeating/polling trigger: a task that has to poll to notice its
        trigger condition pays a recurring wake-up forever and still reacts late, which is not a
        trade worth making for the kind of change this catalog carries.
    .PARAMETER Trigger
        A single trigger hashtable from Target.Triggers.
    .OUTPUTS
        System.String — one XML element.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an XML string; changes no system state.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Trigger
    )

    $type = [string](Get-RegistryTargetOption -Target $Trigger -Name 'Type')
    $delay = [string](Get-RegistryTargetOption -Target $Trigger -Name 'Delay')
    $delayXml = if ([string]::IsNullOrWhiteSpace($delay)) { '' } else { "<Delay>$delay</Delay>" }

    switch ($type) {
        'Logon' {
            return "    <LogonTrigger><Enabled>true</Enabled>$delayXml</LogonTrigger>"
        }
        'Boot' {
            return "    <BootTrigger><Enabled>true</Enabled>$delayXml</BootTrigger>"
        }
        'Event' {
            $log = [string](Get-RegistryTargetOption -Target $Trigger -Name 'Log')
            $source = [string](Get-RegistryTargetOption -Target $Trigger -Name 'Source')
            $eventId = [string](Get-RegistryTargetOption -Target $Trigger -Name 'EventId')
            if ([string]::IsNullOrWhiteSpace($log) -or [string]::IsNullOrWhiteSpace($source) -or
                [string]::IsNullOrWhiteSpace($eventId)) {
                throw "An Event trigger requires Log, Source and EventId."
            }
            $query = "<QueryList><Query Id=`"0`" Path=`"$log`"><Select Path=`"$log`">" +
                "*[System[Provider[@Name='$source'] and EventID=$eventId]]" +
                '</Select></Query></QueryList>'
            $escaped = [System.Security.SecurityElement]::Escape($query)
            return "    <EventTrigger><Enabled>true</Enabled>$delayXml<Subscription>$escaped</Subscription></EventTrigger>"
        }
        default {
            throw "Unsupported scheduled-task trigger Type '$type'. Supported: Logon, Boot, Event."
        }
    }
}

function New-CatalogTaskXml {
    <#
    .SYNOPSIS
        Build the Task Scheduler XML registration document for a task definition.
    .DESCRIPTION
        Produces a Task Scheduler 1.2 schema document suitable for 'schtasks /create /xml'.
        Settings are chosen so the task still runs on the machines these images target:
        battery conditions never block it (a laptop docking a monitor or waking a Bluetooth mouse
        is usually ON battery), instances never queue up (IgnoreNew — the payloads are
        convergent, so a missed overlap is harmless), and a short execution limit stops a wedged
        run from lingering.
    .PARAMETER Definition
        The normalised definition from Get-CatalogTaskDefinition.
    .PARAMETER ScriptPath
        Full path (on the target machine) of the payload script the task executes.
    .OUTPUTS
        System.String — the task XML.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an XML string; changes no system state.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Definition,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $ScriptPath
    )

    $triggerXml = @(@($Definition.Triggers) | ForEach-Object { New-CatalogTaskTriggerXml -Trigger $_ })
    $description = [System.Security.SecurityElement]::Escape([string]$Definition.Description)
    # -ExecutionPolicy RemoteSigned rather than Bypass: the payload is generated locally by this
    # tool, so it carries no Mark of the Web and runs unsigned under RemoteSigned — signing it
    # later (even with a certificate the machine does not trust) does not change that, because
    # RemoteSigned only validates signatures on files that came from another machine. Bypass would
    # additionally suppress the MotW check, which is exactly the check worth keeping if anything
    # ever manages to drop a downloaded file into the payload directory.
    $payloadArguments = "-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File `"$ScriptPath`""

    $arguments = [System.Security.SecurityElement]::Escape($payloadArguments)

    $lines = @(
        '<?xml version="1.0" encoding="UTF-16"?>'
        '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">'
        '  <RegistrationInfo>'
        "    <Description>$description</Description>"
        '    <Author>windows-iso-maker</Author>'
        '  </RegistrationInfo>'
        '  <Triggers>'
        $triggerXml
        '  </Triggers>'
        '  <Principals>'
        '    <Principal id="Author">'
        "      <UserId>$($Definition.PrincipalId)</UserId>"
        "      <LogonType>$($Definition.LogonType)</LogonType>"
        "      <RunLevel>$($Definition.RunLevel)</RunLevel>"
        '    </Principal>'
        '  </Principals>'
        '  <Settings>'
        '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>'
        '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'
        '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'
        '    <AllowHardTerminate>true</AllowHardTerminate>'
        '    <StartWhenAvailable>true</StartWhenAvailable>'
        '    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>'
        '    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>'
        '    <AllowStartOnDemand>true</AllowStartOnDemand>'
        '    <Enabled>true</Enabled>'
        '    <Hidden>false</Hidden>'
        '    <RunOnlyIfIdle>false</RunOnlyIfIdle>'
        '    <WakeToRun>false</WakeToRun>'
        '    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>'
        '    <Priority>7</Priority>'
        '  </Settings>'
        '  <Actions Context="Author">'
        '    <Exec>'
        "      <Command>powershell.exe</Command>"
        "      <Arguments>$arguments</Arguments>"
        '    </Exec>'
        '  </Actions>'
        '</Task>'
    )

    return ($lines -join "`r`n")
}

function Get-CatalogTaskPath {
    <#
    .SYNOPSIS
        Resolve where a task's payload script and XML live, for a given filesystem root.
    .DESCRIPTION
        The same relative layout (ProgramData\WindowsIsoMaker\Tasks) is used offline and online;
        only the root differs — the mounted image root when servicing an image, the live system
        drive when running post-install. TargetScriptPath is the path as the INSTALLED system will
        see it (always on the system drive), which is what the task XML must reference even when
        the file is currently being written into a mount point.
    .PARAMETER RootPath
        Filesystem root to stage files under (e.g. 'C:\mount' or 'C:\').
    .PARAMETER Definition
        The normalised task definition.
    .PARAMETER TargetSystemDrive
        System drive of the INSTALLED machine, used to build TargetScriptPath. Defaults to 'C:'.
    .OUTPUTS
        PSCustomObject with Directory, ScriptPath, XmlPath and TargetScriptPath.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $RootPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Definition,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $TargetSystemDrive = 'C:'
    )

    $directory = Join-Path -Path $RootPath -ChildPath $script:WimTaskPayloadRelativePath
    $targetDirectory = Join-Path -Path "$($TargetSystemDrive.TrimEnd('\'))\" -ChildPath $script:WimTaskPayloadRelativePath
    $xmlName = "$($Definition.ScriptName).task.xml"
    return [pscustomobject]@{
        Directory        = $directory
        ScriptPath       = Join-Path -Path $directory -ChildPath $Definition.ScriptName
        XmlPath          = Join-Path -Path $directory -ChildPath $xmlName
        TargetScriptPath = Join-Path -Path $targetDirectory -ChildPath $Definition.ScriptName
        TargetXmlPath    = Join-Path -Path $targetDirectory -ChildPath $xmlName
    }
}

function Get-CatalogTaskRegistrationCommand {
    <#
    .SYNOPSIS
        Build the schtasks.exe command line that registers a staged task from its XML.
    .DESCRIPTION
        Used by both appliers so the offline (first-boot RunOnce) and online (immediate) paths
        register byte-identical tasks. '/f' makes re-registration overwrite rather than fail, which
        keeps the operation idempotent, and naming the task with its full folder path makes
        schtasks create the \WindowsIsoMaker folder on demand.
    .PARAMETER Definition
        The normalised task definition.
    .PARAMETER XmlPath
        Path to the task XML as the TARGET machine will see it.
    .OUTPUTS
        System.String — the command line.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNull()][object] $Definition,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $XmlPath
    )
    return "schtasks.exe /create /tn `"$($Definition.FullTaskName)`" /xml `"$XmlPath`" /f"
}

function Invoke-ScheduledTaskCommand {
    <#
    .SYNOPSIS
        Run schtasks.exe with the given arguments (mockable seam).
    .DESCRIPTION
        Every online scheduled-task interaction goes through this one function so the Pester suite
        can exercise the appliers on any platform, mirroring how Invoke-Dism isolates DISM.
    .PARAMETER Arguments
        Arguments to pass to schtasks.exe.
    .OUTPUTS
        PSCustomObject with ExitCode and Output.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Arguments
    )

    $output = & schtasks.exe @Arguments 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String)
    }
}

function Test-ScheduledTaskRegistered {
    <#
    .SYNOPSIS
        Return whether a task is already registered under its full folder path.
    .PARAMETER FullTaskName
        Full task name including its folder (e.g. '\WindowsIsoMaker\My task').
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $FullTaskName
    )

    $query = Invoke-ScheduledTaskCommand -Arguments @('/query', '/tn', $FullTaskName)
    return ($query.ExitCode -eq 0)
}

function Test-IsWindowsPlatform {
    <#
    .SYNOPSIS
        Return whether the current host is Windows (PowerShell 5.1-safe).
    .DESCRIPTION
        $IsWindows only exists on PowerShell Core, so it cannot be read directly under 5.1 with
        StrictMode. Used to skip Windows-only ACL work when the suite runs on Linux/macOS CI.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    return [bool](Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction SilentlyContinue)
}

function Set-CatalogTaskDirectorySecurity {
    <#
    .SYNOPSIS
        Lock a staged task directory down to SYSTEM/Administrators write access.
    .DESCRIPTION
        The payloads staged here are executed by a SYSTEM task, so write access to this directory
        is equivalent to code execution as SYSTEM. Directories under %ProgramData% inherit an ACE
        granting BUILTIN\Users write access, which lets a standard user CREATE files here. That is
        enough for a privilege-escalation: pre-create the payload before the first run and the
        attacker becomes its CREATOR OWNER with full control, so they can rewrite it after the
        tool has populated it, and SYSTEM then executes their code at the next trigger.

        Inheritance is therefore removed and an explicit DACL applied: SYSTEM and Administrators
        get full control, Users only read and execute.

        Well-known SIDs are used rather than names so this is correct on non-English installs, and
        the same call works against a mounted offline image (the SIDs are identical there).
    .PARAMETER Path
        Directory to protect.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Callers gate this behind their own ShouldProcess; this is the ACL seam.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if (-not (Test-IsWindowsPlatform)) { return }

    $system = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administrators = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $users = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow

    $acl = Get-Acl -LiteralPath $Path
    # $true = protect from inheritance, $false = do NOT copy the inherited ACEs across, so the
    # permissive %ProgramData% Users ACE is dropped rather than preserved as an explicit one.
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRule($rule)
    }
    foreach ($grant in @(
            @{ Sid = $system; Rights = 'FullControl' },
            @{ Sid = $administrators; Rights = 'FullControl' },
            @{ Sid = $users; Rights = 'ReadAndExecute' })) {
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $grant.Sid,
                [System.Security.AccessControl.FileSystemRights]$grant.Rights,
                $inherit, $none, $allow))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Write-CatalogTaskPayload {
    <#
    .SYNOPSIS
        Write a task's payload script and task XML to disk, returning whether anything changed.
    .DESCRIPTION
        Idempotency seam (FR-017): content already byte-identical is left untouched and reported
        as unchanged, so a re-run over a converged machine reports no changes.

        Encoding is not a free choice for the task XML: schtasks.exe rejects a UTF-8 file with a
        BOM ("incorrect document syntax") and rejects a declaration that disagrees with the actual
        encoding ("unable to switch the encoding"). UTF-16 LE with a BOM plus encoding="UTF-16" is
        the combination Task Scheduler itself exports, so that is what is written here. The payload
        script keeps the repository's UTF-8-without-BOM convention.
    .PARAMETER Paths
        The path set from Get-CatalogTaskPath.
    .PARAMETER Script
        The payload script content.
    .PARAMETER Xml
        The task XML content.
    .OUTPUTS
        System.Boolean — $true when a file was created or updated.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Callers gate this behind their own ShouldProcess; this is the file-write seam.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][object] $Paths,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Script,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Xml
    )

    $changed = $false
    if (-not (Test-Path -LiteralPath $Paths.Directory)) {
        New-Item -Path $Paths.Directory -ItemType Directory -Force -ErrorAction Stop | Out-Null
        $changed = $true
    }

    foreach ($pair in @(
            @{ Path = $Paths.ScriptPath; Content = $Script; Encoding = (New-Object System.Text.UTF8Encoding($false)) },
            @{ Path = $Paths.XmlPath; Content = $Xml; Encoding = (New-Object System.Text.UnicodeEncoding($false, $true)) })) {
        $current = if (Test-Path -LiteralPath $pair.Path) {
            # Read with the SAME encoding used to write. Get-Content -Raw would decode a BOM-less
            # UTF-8 payload as ANSI under Windows PowerShell 5.1, so every non-ASCII character came
            # back as multiple characters, the comparison never matched, and each run rewrote the
            # file and re-registered the task instead of reporting AlreadyApplied.
            [System.IO.File]::ReadAllText($pair.Path, $pair.Encoding)
        }
        else { $null }

        if ($null -eq $current -or $current -ne $pair.Content) {
            [System.IO.File]::WriteAllText($pair.Path, $pair.Content, $pair.Encoding)
            $changed = $true
        }
    }

    # Hardened AFTER the writes, not before: the tightened DACL denies write access to everyone
    # but SYSTEM and Administrators, which would otherwise lock out the very write above on the
    # first run. Re-applied on every run rather than only on creation, because the directory may
    # survive from an earlier version that created it with the inherited %ProgramData% ACL.
    Set-CatalogTaskDirectorySecurity -Path $Paths.Directory

    return $changed
}
