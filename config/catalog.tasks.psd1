@{
    # ---------------------------------------------------------------------------------------------
    # Persistent helper tasks (Action = 'RegisterScheduledTask').
    #
    # Everything else in this catalog is a value you write once. These entries exist for the small
    # number of settings that CANNOT work that way, because the thing they configure does not exist
    # when the change is applied: a mouse that will be paired next month, say. Writing such a
    # setting once — at image build or at post-install time — only ever reaches the devices present
    # at that moment, and silently misses every device that arrives later.
    #
    # Each entry installs one small payload script plus a Task Scheduler task that re-runs it when
    # the relevant device appears. Every task is created inside the shared \WindowsIsoMaker folder
    # so the tool's footprint is enumerable and removable in one place.
    #
    # A task belongs here only when Windows raises a real event to trigger it. If a change would
    # need polling to notice its trigger condition, it does not go in this catalog: a recurring
    # wake-up forever is too high a price for a convenience tweak, and the delay makes it
    # unreliable anyway. Attaching a monitor, for example, logs nothing at all, which is why there
    # is no display-arrangement entry here.
    #
    # The payloads live in config/tasks/ as real .ps1 files (referenced here by name) rather than
    # here-strings, so PSScriptAnalyzer lints them like any other code and the schema gate can
    # parse them. Adding another persistent helper is still a catalog edit plus its script — no
    # change to the module (Constitution Principle II / FR-024). They are deliberately convergent:
    # each one checks current state first and does nothing when the machine already matches, which
    # is what makes a device-arrival trigger safe (the restart it performs re-fires the trigger, and
    # the next run finds nothing to do and stops).
    # ---------------------------------------------------------------------------------------------
    Entries = @(

        # --- Personalization: macOS-style "natural" (reversed) mouse scrolling -------------------
        # Replaces the earlier one-shot RunOnce approach. FlipFlopWheel is stored PER DEVICE
        # INSTANCE under SYSTEM\...\Enum\HID\<instance>\Device Parameters — there is no machine-wide
        # switch, and Windows' own Settings toggle writes exactly the same per-device value. So a
        # mouse paired after the one-shot ran kept the driver default and scrolled the wrong way.
        @{
            Id             = 'task-reverse-mouse-scroll'
            Type           = 'ScheduledTask'
            Action         = 'RegisterScheduledTask'
            Category       = 'Personalization'
            Profiles       = @('opinionated')
            Target         = @{
                TaskName   = 'Reverse mouse scroll direction'
                # The payload lives in config/tasks/ as a real .ps1 so PSScriptAnalyzer and the
                # schema gate can both see it; it is copied verbatim to the target machine.
                ScriptFile = 'Set-ReverseMouseScroll.ps1'
                Triggers   = @(
                    # Device arrival is the only trigger, and it is enough: Kernel-PnP logs 410
                    # ("Device ... was started") whenever a device stack starts, including a
                    # Bluetooth mouse reconnecting — not just the first time it is installed — and
                    # that also covers boot and logon, when every device starts anyway. A logon
                    # trigger would only add a second run of a payload that had already converged.
                    # The short delay lets the stack settle before the payload inspects it.
                    @{ Type = 'Event'; Log = 'Microsoft-Windows-Kernel-PnP/Configuration'; Source = 'Microsoft-Windows-Kernel-PnP'; EventId = 410; Delay = 'PT5S' }
                )
            }
            Description    = 'Installs a scheduled task that reverses the mouse wheel scroll direction (macOS-style "natural" scrolling) on every mouse, including mice paired after the image was built or after post-install ran.'
            Rationale      = 'FlipFlopWheel is the Microsoft-documented control that inverts wheel scroll direction (see Microsoft''s "How to reverse the mouse wheel scrolling direction" whitepaper, wheel.docx), but it is stored per device instance under SYSTEM\...\Enum\HID\<device>\Device Parameters. There is no machine-wide equivalent — Windows'' own Settings toggle writes the same per-device value — so any one-shot application (a first-boot RunOnce, a single post-install run) only reaches the devices enumerated at that moment and silently misses every mouse connected afterwards. A Task Scheduler task triggered by Kernel-PnP event 410 ("Device ... was started") re-applies the value whenever a mouse appears, and pnputil /restart-device makes it take effect without waiting for a reboot. It runs as SYSTEM because it writes machine state (HKLM) and must work with no user signed in. Kept opt-in (Profiles=opinionated) because reversed scrolling is a personal-taste preference, not a general improvement.'
            Citation       = 'https://download.microsoft.com/download/b/d/1/bd1f7ef4-7d72-419e-bc5c-9f79ad7bb66e/wheel.docx'
            EvidenceGrade  = 2
            Reversible     = $true
            Reversal       = 'Delete the scheduled task ("schtasks /delete /tn \WindowsIsoMaker\Reverse mouse scroll direction /f"), remove %ProgramData%\WindowsIsoMaker\Tasks\Set-ReverseMouseScroll.ps1 and its .task.xml, then set FlipFlopWheel to 0 under each mouse''s SYSTEM\CurrentControlSet\Enum\HID\<device>\Device Parameters key (or use Settings > Bluetooth & devices > Mouse > Scrolling direction).'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        }
    )
}
