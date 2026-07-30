#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for the 'RegisterScheduledTask' catalog Action — the persistent helper tasks that keep a
    setting applied to devices that appear AFTER the change was made.
.DESCRIPTION
    These cover the behaviour that motivated the action: a setting stored per device instance
    (FlipFlopWheel) cannot be applied once and be done with, so the catalog
    installs a task that re-applies it on device arrival. The tests pin the generated task XML
    (Task Scheduler rejects several plausible-looking variants), the offline/online appliers, their
    idempotency, and -WhatIf. Everything that touches schtasks.exe goes through the mockable
    Invoke-ScheduledTaskCommand seam, so the suite runs on any platform.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force

    # A fresh entry per test: the Target is a hashtable, so a single shared instance would let one
    # test's mutation (Arch, Triggers) leak into the next.
    $script:NewSampleEntry = {
        @{
            Id            = 'task-sample'
            Type          = 'ScheduledTask'
            Action        = 'RegisterScheduledTask'
            Category      = 'Personalization'
            Description   = 'Sample task <with> markup'
            Citation      = 'https://learn.microsoft.com/'
            EvidenceGrade = 2
            Arch          = @('amd64', 'arm64')
            Target        = @{
                TaskName   = 'Sample task'
                ScriptName = 'Set-Sample.ps1'
                Triggers   = @(
                    @{ Type = 'Event'; Log = 'Microsoft-Windows-Kernel-PnP/Configuration'; Source = 'Microsoft-Windows-Kernel-PnP'; EventId = 410; Delay = 'PT5S' },
                    @{ Type = 'Logon' }
                )
                Script     = '"sample payload"'
            }
        }
    }
}

Describe 'Get-CatalogTaskDefinition' {

    It 'defaults the task into the shared \WindowsIsoMaker folder' {
        InModuleScope WindowsIsoMaker -Parameters @{ Entry = (& $script:NewSampleEntry) } {
            param($Entry)
            $definition = Get-CatalogTaskDefinition -Entry ([pscustomobject]$Entry)
            $definition.TaskFolder | Should -Be '\WindowsIsoMaker'
            $definition.FullTaskName | Should -Be '\WindowsIsoMaker\Sample task'
        }
    }

    It 'uses the SYSTEM principal so it can write machine state with nobody signed in' {
        InModuleScope WindowsIsoMaker -Parameters @{ Entry = (& $script:NewSampleEntry) } {
            param($Entry)
            $definition = Get-CatalogTaskDefinition -Entry ([pscustomobject]$Entry)
            $definition.PrincipalId | Should -Be 'S-1-5-18'
            $definition.LogonType | Should -Be 'S4U'
            $definition.RunLevel | Should -Be 'HighestAvailable'
        }
    }

    It 'requires a payload script and at least one trigger' {
        InModuleScope WindowsIsoMaker -Parameters @{ Entry = (& $script:NewSampleEntry) } {
            param($Entry)
            $noScript = [pscustomobject]@{ Id = 'x'; Target = @{ TaskName = 'n'; Script = ''; Triggers = @(@{ Type = 'Logon' }) } }
            { Get-CatalogTaskDefinition -Entry $noScript } | Should -Throw '*Target.Script*'

            $noTrigger = [pscustomobject]@{ Id = 'x'; Target = @{ TaskName = 'n'; Script = 'x'; Triggers = @() } }
            { Get-CatalogTaskDefinition -Entry $noTrigger } | Should -Throw '*Triggers*'
        }
    }
}

Describe 'New-CatalogTaskXml' {

    It 'produces XML declaring UTF-16, which is the only encoding schtasks accepts for a BOM-ed file' {
        InModuleScope WindowsIsoMaker -Parameters @{ Entry = (& $script:NewSampleEntry) } {
            param($Entry)
            $definition = Get-CatalogTaskDefinition -Entry ([pscustomobject]$Entry)
            $xml = New-CatalogTaskXml -Definition $definition -ScriptPath 'C:\payload.ps1'
            $xml | Should -Match '<\?xml version="1\.0" encoding="UTF-16"\?>'
            { [xml]$xml } | Should -Not -Throw
        }
    }

    It 'escapes the event subscription so the nested query survives as text' {
        InModuleScope WindowsIsoMaker -Parameters @{ Entry = (& $script:NewSampleEntry) } {
            param($Entry)
            $definition = Get-CatalogTaskDefinition -Entry ([pscustomobject]$Entry)
            $xml = New-CatalogTaskXml -Definition $definition -ScriptPath 'C:\payload.ps1'

            $document = [xml]$xml
            $namespace = New-Object System.Xml.XmlNamespaceManager($document.NameTable)
            $namespace.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
            $subscription = $document.SelectSingleNode('//t:EventTrigger/t:Subscription', $namespace)

            $subscription.InnerText | Should -Match "Provider\[@Name='Microsoft-Windows-Kernel-PnP'\]"
            $subscription.InnerText | Should -Match 'EventID=410'
            # Escaped on the wire, decoded by the parser — proving it is data, not markup.
            $xml | Should -Match '&lt;QueryList&gt;'
        }
    }

    It 'runs the payload script non-interactively and escapes the description' {
        InModuleScope WindowsIsoMaker -Parameters @{ Entry = (& $script:NewSampleEntry) } {
            param($Entry)
            $definition = Get-CatalogTaskDefinition -Entry ([pscustomobject]$Entry)
            $xml = New-CatalogTaskXml -Definition $definition -ScriptPath 'C:\Tasks\Set-Sample.ps1'
            $xml | Should -Match '<Command>powershell\.exe</Command>'
            $xml | Should -Match 'ExecutionPolicy RemoteSigned'
            $xml | Should -Match 'Set-Sample\.ps1'
            $xml | Should -Match 'Sample task &lt;with&gt; markup'
        }
    }

    It 'never blocks on battery, because docking a monitor or waking a mouse usually happens on battery' {
        InModuleScope WindowsIsoMaker -Parameters @{ Entry = (& $script:NewSampleEntry) } {
            param($Entry)
            $definition = Get-CatalogTaskDefinition -Entry ([pscustomobject]$Entry)
            $xml = New-CatalogTaskXml -Definition $definition -ScriptPath 'C:\payload.ps1'
            $xml | Should -Match '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'
            $xml | Should -Match '<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'
        }
    }
}

Describe 'Write-CatalogTaskPayload' {

    BeforeEach {
        $script:Scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-task-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Scratch -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes on first call and reports no change on an identical second call' {
        InModuleScope WindowsIsoMaker -Parameters @{ Root = $script:Scratch; Entry = (& $script:NewSampleEntry) } {
            param($Root, $Entry)
            Mock Set-CatalogTaskDirectorySecurity { }
            $definition = Get-CatalogTaskDefinition -Entry ([pscustomobject]$Entry)
            $paths = Get-CatalogTaskPath -RootPath $Root -Definition $definition
            $xml = New-CatalogTaskXml -Definition $definition -ScriptPath $paths.TargetScriptPath

            Write-CatalogTaskPayload -Paths $paths -Script $definition.Script -Xml $xml | Should -BeTrue
            Write-CatalogTaskPayload -Paths $paths -Script $definition.Script -Xml $xml | Should -BeFalse
            Test-Path -LiteralPath $paths.ScriptPath | Should -BeTrue
            Test-Path -LiteralPath $paths.XmlPath | Should -BeTrue
        }
    }

    It 'writes the XML as UTF-16 with a BOM and the payload as UTF-8 without one' {
        InModuleScope WindowsIsoMaker -Parameters @{ Root = $script:Scratch; Entry = (& $script:NewSampleEntry) } {
            param($Root, $Entry)
            Mock Set-CatalogTaskDirectorySecurity { }
            $definition = Get-CatalogTaskDefinition -Entry ([pscustomobject]$Entry)
            $paths = Get-CatalogTaskPath -RootPath $Root -Definition $definition
            $xml = New-CatalogTaskXml -Definition $definition -ScriptPath $paths.TargetScriptPath
            [void](Write-CatalogTaskPayload -Paths $paths -Script $definition.Script -Xml $xml)

            $xmlBytes = [System.IO.File]::ReadAllBytes($paths.XmlPath)
            $xmlBytes[0] | Should -Be 0xFF
            $xmlBytes[1] | Should -Be 0xFE

            $scriptBytes = [System.IO.File]::ReadAllBytes($paths.ScriptPath)
            ($scriptBytes[0] -eq 0xEF -and $scriptBytes[1] -eq 0xBB) | Should -BeFalse
        }
    }

    It 'rewrites when the content changes' {
        InModuleScope WindowsIsoMaker -Parameters @{ Root = $script:Scratch; Entry = (& $script:NewSampleEntry) } {
            param($Root, $Entry)
            Mock Set-CatalogTaskDirectorySecurity { }
            $definition = Get-CatalogTaskDefinition -Entry ([pscustomobject]$Entry)
            $paths = Get-CatalogTaskPath -RootPath $Root -Definition $definition
            $xml = New-CatalogTaskXml -Definition $definition -ScriptPath $paths.TargetScriptPath

            [void](Write-CatalogTaskPayload -Paths $paths -Script 'old' -Xml $xml)
            Write-CatalogTaskPayload -Paths $paths -Script 'new' -Xml $xml | Should -BeTrue
            (Get-Content -LiteralPath $paths.ScriptPath -Raw) | Should -Be 'new'
        }
    }

    It 'treats a payload containing non-ASCII characters as unchanged on re-run' {
        InModuleScope WindowsIsoMaker -Parameters @{ Root = $script:Scratch; Entry = (& $script:NewSampleEntry) } {
            param($Root, $Entry)
            Mock Set-CatalogTaskDirectorySecurity { }
            # The shipped payloads contain em dashes in their comments. Reading a BOM-less UTF-8
            # file back with the wrong encoding makes those bytes decode to extra characters, so
            # the content never compares equal and every run looks like a change.
            $Entry.Target.Script = "# windows-iso-maker — placement helper`r`nWrite-Output 'ok'"
            $definition = Get-CatalogTaskDefinition -Entry ([pscustomobject]$Entry)
            $paths = Get-CatalogTaskPath -RootPath $Root -Definition $definition
            $xml = New-CatalogTaskXml -Definition $definition -ScriptPath $paths.TargetScriptPath

            Write-CatalogTaskPayload -Paths $paths -Script $definition.Script -Xml $xml | Should -BeTrue
            Write-CatalogTaskPayload -Paths $paths -Script $definition.Script -Xml $xml | Should -BeFalse
        }
    }
}

Describe 'Register-ScheduledTaskEntry (offline image)' {

    BeforeEach {
        $script:Mount = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-mount-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -Path $script:Mount -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Mount -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'stages the payload into the image and arms first-boot registration' {
        InModuleScope WindowsIsoMaker -Parameters @{ Mount = $script:Mount; Entry = (& $script:NewSampleEntry) } {
            param($Mount, $Entry)
            Mock Set-CatalogTaskDirectorySecurity { }
            Mock Mount-OfflineRegistryHive { [pscustomobject]@{ MountKey = 'HKLM\WIM_Test_SOFTWARE'; HiveFile = 'x' } }
            Mock Dismount-OfflineRegistryHive { }
            Mock Get-OfflineRegistryValue { $null }
            Mock Set-OfflineRegistryValue { }

            $result = Register-ScheduledTaskEntry -MountPath $Mount -Catalog @([pscustomobject]$Entry) -Architecture amd64

            $result.Status | Should -Be 'Applied'
            Test-Path -LiteralPath (Join-Path $Mount 'ProgramData\WindowsIsoMaker\Tasks\Set-Sample.ps1') | Should -BeTrue

            # The image cannot register a task itself, so the RunOnce that does it at first boot
            # is the load-bearing half of the offline path.
            Should -Invoke Set-OfflineRegistryValue -Times 1 -ParameterFilter {
                $Path -eq 'Microsoft\Windows\CurrentVersion\RunOnce' -and
                $Name -eq '!Wim_task-sample' -and
                $Value -like '*schtasks.exe /create /tn "\WindowsIsoMaker\Sample task"*'
            }
        }
    }

    It 'reports AlreadyApplied when the payload and the armed command are unchanged' {
        InModuleScope WindowsIsoMaker -Parameters @{ Mount = $script:Mount; Entry = (& $script:NewSampleEntry) } {
            param($Mount, $Entry)
            Mock Set-CatalogTaskDirectorySecurity { }
            Mock Mount-OfflineRegistryHive { [pscustomobject]@{ MountKey = 'HKLM\WIM_Test_SOFTWARE'; HiveFile = 'x' } }
            Mock Dismount-OfflineRegistryHive { }
            Mock Set-OfflineRegistryValue { }
            $definition = Get-CatalogTaskDefinition -Entry ([pscustomobject]$Entry)
            $paths = Get-CatalogTaskPath -RootPath $Mount -Definition $definition
            Mock Get-OfflineRegistryValue {
                Get-CatalogTaskRegistrationCommand -Definition $definition -XmlPath $paths.TargetXmlPath
            }

            [void](Register-ScheduledTaskEntry -MountPath $Mount -Catalog @([pscustomobject]$Entry) -Architecture amd64)
            $second = Register-ScheduledTaskEntry -MountPath $Mount -Catalog @([pscustomobject]$Entry) -Architecture amd64

            $second.Status | Should -Be 'AlreadyApplied'
        }
    }

    It 'writes nothing under -WhatIf' {
        InModuleScope WindowsIsoMaker -Parameters @{ Mount = $script:Mount; Entry = (& $script:NewSampleEntry) } {
            param($Mount, $Entry)
            Mock Set-CatalogTaskDirectorySecurity { }
            Mock Mount-OfflineRegistryHive { throw 'must not load a hive in preview' }
            Mock Set-OfflineRegistryValue { throw 'must not write in preview' }

            $result = Register-ScheduledTaskEntry -MountPath $Mount -Catalog @([pscustomobject]$Entry) -Architecture amd64 -WhatIf

            $result.Status | Should -Be 'Skipped'
            $result.Reason | Should -Match 'Preview'
            Test-Path -LiteralPath (Join-Path $Mount 'ProgramData\WindowsIsoMaker\Tasks\Set-Sample.ps1') | Should -BeFalse
        }
    }

    It 'ignores entries that do not target the requested architecture' {
        InModuleScope WindowsIsoMaker -Parameters @{ Mount = $script:Mount; Entry = (& $script:NewSampleEntry) } {
            param($Mount, $Entry)
            Mock Set-CatalogTaskDirectorySecurity { }
            $Entry.Arch = @('arm64')
            $result = @(Register-ScheduledTaskEntry -MountPath $Mount -Catalog @([pscustomobject]$Entry) -Architecture amd64)
            $result.Count | Should -Be 0
        }
    }
}

Describe 'Register-OnlineScheduledTask (running system)' {

    It 'registers the task and runs it once so already-attached devices converge immediately' {
        InModuleScope WindowsIsoMaker -Parameters @{ Entry = (& $script:NewSampleEntry) } {
            param($Entry)
            Mock Write-CatalogTaskPayload { $true }
            Mock Test-ScheduledTaskRegistered { $false }
            Mock Invoke-ScheduledTaskCommand { [pscustomobject]@{ ExitCode = 0; Output = '' } }

            $result = Register-OnlineScheduledTask -Catalog @([pscustomobject]$Entry) -Architecture amd64

            $result.Status | Should -Be 'Applied'
            Should -Invoke Invoke-ScheduledTaskCommand -Times 1 -ParameterFilter { $Arguments -contains '/create' }
            # Without this the task would not touch the mouse already paired — the exact gap that
            # made the previous one-shot approach look like it had worked.
            Should -Invoke Invoke-ScheduledTaskCommand -Times 1 -ParameterFilter { $Arguments -contains '/run' }
        }
    }

    It 'reports AlreadyApplied without re-registering when payload and task are current' {
        InModuleScope WindowsIsoMaker -Parameters @{ Entry = (& $script:NewSampleEntry) } {
            param($Entry)
            Mock Write-CatalogTaskPayload { $false }
            Mock Test-ScheduledTaskRegistered { $true }
            Mock Invoke-ScheduledTaskCommand { [pscustomobject]@{ ExitCode = 0; Output = '' } }

            $result = Register-OnlineScheduledTask -Catalog @([pscustomobject]$Entry) -Architecture amd64

            $result.Status | Should -Be 'AlreadyApplied'
            Should -Invoke Invoke-ScheduledTaskCommand -Times 0
        }
    }

    It 're-registers when the payload changed even though the task exists' {
        InModuleScope WindowsIsoMaker -Parameters @{ Entry = (& $script:NewSampleEntry) } {
            param($Entry)
            Mock Write-CatalogTaskPayload { $true }
            Mock Test-ScheduledTaskRegistered { $true }
            Mock Invoke-ScheduledTaskCommand { [pscustomobject]@{ ExitCode = 0; Output = '' } }

            $result = Register-OnlineScheduledTask -Catalog @([pscustomobject]$Entry) -Architecture amd64

            $result.Status | Should -Be 'Applied'
            Should -Invoke Invoke-ScheduledTaskCommand -ParameterFilter { $Arguments -contains '/create' }
        }
    }

    It 'fails the entry when schtasks rejects the registration' {
        InModuleScope WindowsIsoMaker -Parameters @{ Entry = (& $script:NewSampleEntry) } {
            param($Entry)
            Mock Write-CatalogTaskPayload { $true }
            Mock Test-ScheduledTaskRegistered { $false }
            Mock Invoke-ScheduledTaskCommand { [pscustomobject]@{ ExitCode = 1; Output = 'ERROR: The task XML is malformed.' } }

            $result = Register-OnlineScheduledTask -Catalog @([pscustomobject]$Entry) -Architecture amd64

            $result.Status | Should -Be 'Failed'
            $result.Reason | Should -Match 'malformed'
        }
    }

    It 'still reports Applied when only the initial run could not start' {
        InModuleScope WindowsIsoMaker -Parameters @{ Entry = (& $script:NewSampleEntry) } {
            param($Entry)
            Mock Write-CatalogTaskPayload { $true }
            Mock Test-ScheduledTaskRegistered { $false }
            Mock Invoke-ScheduledTaskCommand {
                if ($Arguments -contains '/run') { return [pscustomobject]@{ ExitCode = 1; Output = 'busy' } }
                return [pscustomobject]@{ ExitCode = 0; Output = '' }
            }

            $result = Register-OnlineScheduledTask -Catalog @([pscustomobject]$Entry) -Architecture amd64

            $result.Status | Should -Be 'Applied'
            $result.Reason | Should -Match 'next trigger'
        }
    }

    It 'writes nothing under -WhatIf' {
        InModuleScope WindowsIsoMaker -Parameters @{ Entry = (& $script:NewSampleEntry) } {
            param($Entry)
            Mock Write-CatalogTaskPayload { throw 'must not write in preview' }
            Mock Invoke-ScheduledTaskCommand { throw 'must not call schtasks in preview' }

            $result = Register-OnlineScheduledTask -Catalog @([pscustomobject]$Entry) -Architecture amd64 -WhatIf

            $result.Status | Should -Be 'Skipped'
            $result.Reason | Should -Match 'Preview'
        }
    }
}

Describe 'Payload directory hardening' {

    BeforeEach {
        $script:Scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-acl-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Scratch -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'hardens the payload directory after writing, since the payload runs as SYSTEM' {
        InModuleScope WindowsIsoMaker -Parameters @{ Root = $script:Scratch; Entry = (& $script:NewSampleEntry) } {
            param($Root, $Entry)
            Mock Set-CatalogTaskDirectorySecurity { }
            $definition = Get-CatalogTaskDefinition -Entry ([pscustomobject]$Entry)
            $paths = Get-CatalogTaskPath -RootPath $Root -Definition $definition
            $xml = New-CatalogTaskXml -Definition $definition -ScriptPath $paths.TargetScriptPath

            [void](Write-CatalogTaskPayload -Paths $paths -Script $definition.Script -Xml $xml)

            Should -Invoke Set-CatalogTaskDirectorySecurity -Times 1 -ParameterFilter { $Path -eq $paths.Directory }
        }
    }

    It 'removes inherited write access for ordinary users' -Skip:(-not $IsWindows) {
        InModuleScope WindowsIsoMaker -Parameters @{ Root = $script:Scratch } {
            param($Root)
            $directory = Join-Path $Root 'Tasks'
            New-Item -Path $directory -ItemType Directory -Force | Out-Null

            Set-CatalogTaskDirectorySecurity -Path $directory

            $acl = Get-Acl -LiteralPath $directory
            $acl.AreAccessRulesProtected | Should -BeTrue -Because 'the permissive %ProgramData% inheritance must be broken'

            # %ProgramData% grants BUILTIN\Users write access, which lets a standard user
            # pre-create the payload and own it — enough to get code running as SYSTEM later.
            $users = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
            $userRules = @($acl.Access | Where-Object {
                    $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -eq $users
                })
            $userRules.Count | Should -BeGreaterThan 0
            foreach ($rule in $userRules) {
                ($rule.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Write) |
                    Should -Be 0 -Because 'ordinary users must not be able to write a payload that SYSTEM executes'
            }
        }
    }
}

Describe 'How the payload is launched' {

    It 'leaves SYSTEM tasks on plain powershell.exe, having no desktop to flash on' {
        InModuleScope WindowsIsoMaker -Parameters @{ Entry = (& $script:NewSampleEntry) } {
            param($Entry)
            $definition = Get-CatalogTaskDefinition -Entry ([pscustomobject]$Entry)
            $xml = New-CatalogTaskXml -Definition $definition -ScriptPath 'C:\payload.ps1'
            ([xml]$xml).Task.Actions.Exec.Command | Should -Be 'powershell.exe'
        }
    }

    It 'uses RemoteSigned rather than Bypass, keeping the Mark-of-the-Web check' {
        InModuleScope WindowsIsoMaker -Parameters @{ Entry = (& $script:NewSampleEntry) } {
            param($Entry)
            $definition = Get-CatalogTaskDefinition -Entry ([pscustomobject]$Entry)
            $xml = New-CatalogTaskXml -Definition $definition -ScriptPath 'C:\payload.ps1'
            # The payload is generated locally, so it has no MotW and runs unsigned under
            # RemoteSigned; Bypass would only add the ability to run a downloaded file.
            $xml | Should -Match 'ExecutionPolicy RemoteSigned'
            $xml | Should -Not -Match 'ExecutionPolicy Bypass'
        }
    }

}

Describe 'Dispatchers route the new Action' {

    It 'sends RegisterScheduledTask to the offline handler' {
        InModuleScope WindowsIsoMaker -Parameters @{ Entry = (& $script:NewSampleEntry) } {
            param($Entry)
            Mock Register-ScheduledTaskEntry {
                @([pscustomobject]@{ PSTypeName = 'WindowsIsoMaker.ChangeResult'; Id = 'task-sample'; Type = 'ScheduledTask'; Status = 'Applied'; Reason = 'x'; Citation = 'y' })
            }

            $result = Invoke-CatalogEntry -Entry ([pscustomobject]$Entry) -MountPath 'C:\mount' -Architecture amd64

            $result.Status | Should -Be 'Applied'
            Should -Invoke Register-ScheduledTaskEntry -Times 1
        }
    }

    It 'sends RegisterScheduledTask to the online handler' {
        InModuleScope WindowsIsoMaker -Parameters @{ Entry = (& $script:NewSampleEntry) } {
            param($Entry)
            Mock Register-OnlineScheduledTask {
                @([pscustomobject]@{ PSTypeName = 'WindowsIsoMaker.ChangeResult'; Id = 'task-sample'; Type = 'ScheduledTask'; Status = 'Applied'; Reason = 'x'; Citation = 'y' })
            }

            $result = Invoke-OnlineCatalogEntry -Entry ([pscustomobject]$Entry) -Architecture amd64

            $result.Status | Should -Be 'Applied'
            Should -Invoke Register-OnlineScheduledTask -Times 1
        }
    }
}

Describe 'Shipped task entries' {

    It 'ships the mouse-scroll task in the opinionated profile and opt-in by default' {
        InModuleScope WindowsIsoMaker {
            $entry = @(Import-ChangeCatalog | Where-Object { $_.Id -eq 'task-reverse-mouse-scroll' })[0]
            $entry | Should -Not -BeNullOrEmpty
            @($entry.Profiles) | Should -Contain 'opinionated'
            $entry.DefaultEnabled | Should -BeFalse
        }
    }

    It 'triggers both tasks on device arrival so devices connected later are covered' {
        InModuleScope WindowsIsoMaker {
            foreach ($id in @('task-reverse-mouse-scroll')) {
                $entry = @(Import-ChangeCatalog | Where-Object { $_.Id -eq $id })[0]
                $eventTriggers = @(@($entry.Target.Triggers) | Where-Object { $_.Type -eq 'Event' })
                $eventTriggers.Count | Should -BeGreaterThan 0 -Because "$id exists to react to devices appearing later"
                $eventTriggers[0].EventId | Should -Be 410
                # A logon trigger backstops the event trigger if that log is ever unavailable.
                @(@($entry.Target.Triggers) | Where-Object { $_.Type -eq 'Logon' }).Count | Should -BeGreaterThan 0
            }
        }
    }

    It 'only restarts mouse devices it actually changed, so the arrival trigger cannot feed itself' {
        InModuleScope WindowsIsoMaker {
            $entry = @(Import-ChangeCatalog | Where-Object { $_.Id -eq 'task-reverse-mouse-scroll' })[0]
            $payload = [string]$entry.Target.Script
            # Only devices bound to the mouse HID mapper are touched (not keyboards).
            $payload | Should -Match "Service -ne 'mouhid'"
            # Devices already at 1 are skipped before any write or restart.
            $payload | Should -Match 'if \(\$current -eq 1\) \{ continue \}'
            $payload | Should -Match 'pnputil\.exe /restart-device'
        }
    }

}
