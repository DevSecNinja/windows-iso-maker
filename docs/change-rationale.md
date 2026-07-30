# Change catalog & rationale

Every system change this tool makes is a **data-driven catalog entry**, not hard-coded logic.
The catalog lives in:

- [config/catalog.appx.psd1](../config/catalog.appx.psd1) — provisioned app removals
- [config/catalog.capabilities.psd1](../config/catalog.capabilities.psd1) — capabilities & optional features (incl. WSL)
- [config/catalog.registry.psd1](../config/catalog.registry.psd1) — registry tweaks
- [config/catalog.tasks.psd1](../config/catalog.tasks.psd1) — persistent helper tasks (settings that must be re-applied when a device appears)

The catalog files themselves are the authoritative, always-up-to-date documentation: each
entry states **what** it does, **why**, a **citation**, and an **evidence grade**. This page
explains the model and highlights the notable defaults.

## Entry schema

```powershell
@{
    Id             = 'reg-disable-recall'          # unique, stable id
    Type           = 'Registry'                    # Appx | Capability | Registry | OptionalFeature | ScheduledTask (informational)
    Action         = 'SetRegistry'                 # dispatch key: RemoveAppx | RemoveCapability | SetRegistry | EnableOptionalFeature | AddCapability | DisableOptionalFeature | RegisterScheduledTask
    Category       = 'Privacy & telemetry'         # required: semantic taxonomy (display/grouping only)
    Target         = @{ Hive='SOFTWARE'; Path='...'; Name='...'; Kind='DWord'; Value=1 }  # or a package/feature name string
    Description    = 'WHAT the change does.'       # required (Principle II)
    Rationale      = 'WHY it is safe/desirable.'   # required
    Citation       = 'https://learn.microsoft.com/...'  # required (URL or 'Unverified')
    EvidenceGrade  = 1                             # required: 1 official / 2 vendor / 3 forum
    Reversible     = $true
    Reversal       = 'How to undo it.'
    DefaultEnabled = $true                         # grade-3 entries must be $false
    Profiles       = @('opinionated')              # optional: profile-membership tags (gaming | opinionated)
    Condition      = @{ Script='...'; Description='...' }  # optional: hardware/machine applicability guard
    Arch           = @('amd64','arm64')
}
```

`Category` is a **semantic label** used purely for display and grouping (on the showcase site and
in reports); the allowed taxonomy is: `Browser`, `Bundled apps`, `Cloud storage`, `Development`,
`Gaming`, `Legacy components`, `Personalization`, `Privacy & telemetry`, `System & recovery`. It is deliberately kept
**separate** from `Profiles`, the curated profile-membership tag (`gaming` and/or `opinionated`),
so an entry can be, e.g., `Category = 'Development'` (WSL, Virtual Machine Platform) while still
belonging to the `opinionated` profile. Profile selection keys off `Profiles`, never `Category`.

The `Action` is the dispatch key: [`Invoke-CatalogEntry`](../src/WindowsIsoMaker/Public/Invoke-CatalogEntry.ps1)
routes each entry to the correct handler. **Adding a new change means adding an entry — never a
new code path or parameter** (FR-024/FR-025).

### `SetRegistry` target options

A `SetRegistry` target requires `Hive` / `Path` / `Name` / `Kind` / `Value` and accepts two
optional keys:

| Key | Default | Meaning |
| --- | --- | --- |
| `Operation` | `'Set'` | `'Delete'` removes the value instead of writing it. |
| `OnlyIfKeyExists` | `$false` | `$true` = only write when the key already exists; otherwise the entry is reported `NotApplicable` and the key is **not** created. |

`OnlyIfKeyExists` exists for third-party/OEM components a clean Windows image does not contain —
for example disabling an OEM **service**, which is done by setting its
`SYSTEM\ControlSet001\Services\<ServiceName>\Start` value (`2` = Automatic, `3` = Manual,
`4` = Disabled). No separate "service" action is needed: a service is just a registry target, and
the guard keeps the build from fabricating an orphan `Services\<Name>` key on images/machines
where that service is not installed. See `reg-disable-waves-audio-service` for a worked example.
Because the service key only appears once the OEM package is installed, such entries usually take
effect through [`post-install.ps1`](../post-install.ps1) on the installed machine (after a reboot)
rather than during the offline build.

> **Control sets:** `SYSTEM`-hive paths are authored against `ControlSet001` because the offline
> hive loaded from the image has no `CurrentControlSet` — that symlink only exists once Windows
> boots. The online post-install applier rewrites the `ControlSet001\` prefix to
> `CurrentControlSet\` (`Resolve-OnlineRegistryPath`), so it always writes to the *active* control
> set even when that is not `ControlSet001` (e.g. after a Last Known Good rollback).

### `RegisterScheduledTask` — settings that must survive new devices

A few settings cannot be applied once and left alone, because what they configure does not exist
yet when the change is made:

- **Mouse scroll direction** (`FlipFlopWheel`) is stored **per device instance** under
  `SYSTEM\...\Enum\HID\<instance>\Device Parameters`. There is no machine-wide equivalent —
  Windows' own *Scrolling direction* toggle writes that same per-device value. So writing it once
  only reaches the mice enumerated at that moment; a mouse paired next week keeps the driver
  default and scrolls the other way.

Such settings need something that re-runs when the device shows up. An entry declares a small
payload script plus the triggers that should re-run it:

```powershell
Target = @{
    TaskName   = 'Reverse mouse scroll direction'
    ScriptName = 'Set-ReverseMouseScroll.ps1'
    Triggers   = @(
        @{ Type = 'Event'; Log = 'Microsoft-Windows-Kernel-PnP/Configuration'; Source = 'Microsoft-Windows-Kernel-PnP'; EventId = 410; Delay = 'PT5S' },
        @{ Type = 'Logon'; Delay = 'PT30S' }
    )
    Script     = @'
# ... payload ...
'@
}
```

| Key | Required | Meaning |
| --- | --- | --- |
| `TaskName` | yes | Task name, created inside the shared `\WindowsIsoMaker` Task Scheduler folder. |
| `Script` | yes | The payload, run by `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File`. Parsed by the schema tests, so a syntax error is a merge-blocking failure rather than a task that fails silently forever. |
| `ScriptName` | no | Payload filename under `%ProgramData%\WindowsIsoMaker\Tasks` (defaults to `<Id>.ps1`). |
| `TaskFolder` | no | Overrides the `\WindowsIsoMaker` folder. |
| `Triggers` | yes | One or more of `Event` (needs `Log`, `Source`, `EventId`), `Logon`, `Boot`; each accepts an optional `Delay` (xs:duration). |

Tasks run as **SYSTEM**: they configure machine state and must work with nobody signed in. That
also keeps them off the interactive desktop, so they can never flash a console window at the user.

**Payloads must be convergent.** Each one checks current state first and does nothing when the
machine already matches. That is what makes a device-arrival trigger safe: restarting a device to
apply a change raises another arrival event, and the next run finds nothing to do and stops.

**An entry belongs here only if Windows raises a real event to trigger on.** Not everything does —
attaching a monitor, for instance, logs nothing at all, in Kernel-PnP or any other enabled log. The
temptation is to fall back to a repeating trigger, but polling forever to notice a condition is a
permanent cost and still reacts late, which is a bad trade for the kind of convenience tweak this
catalog carries. Check for a real event first; if there is none, the change does not belong here.
That is why there is no display-arrangement entry.

#### Execution details worth knowing

- **`RemoteSigned`, not `Bypass`.** Payloads are generated locally, so they carry no Mark of the
  Web and run unsigned under `RemoteSigned`; signing them later — even with a certificate the
  machine does not trust — changes nothing, because `RemoteSigned` only validates signatures on
  files that came from elsewhere. `Bypass` would only add the ability to run a downloaded file,
  which is the one case worth blocking. (`AllSigned` would break an untrusted-publisher signature,
  so it is deliberately not used.)
- **The payload directory is locked down.** Directories under `%ProgramData%` inherit an ACE
  granting `BUILTIN\Users` write access, which is enough for a standard user to pre-create a
  payload, become its `CREATOR OWNER`, and rewrite it later — code execution as SYSTEM. The
  appliers therefore break inheritance and apply an explicit DACL (SYSTEM + Administrators full
  control, Users read and execute) *after* writing.
- **A SYSTEM task is only visible elevated.** `schtasks /query` as a normal user reports
  *Access is denied* rather than "not found".

The two paths differ only in *when* the task is registered:

- **Post-install** ([`Register-OnlineScheduledTask`](../src/WindowsIsoMaker/Private/Invoke-OnlinePostInstall.ps1))
  registers it immediately and runs it once, so devices already attached converge straight away.
- **Offline build** ([`Register-ScheduledTaskEntry`](../src/WindowsIsoMaker/Public/Register-ScheduledTaskEntry.ps1))
  cannot: the Task Scheduler service is not running and a task is not a plain file drop (it lives
  in both `%SystemRoot%\System32\Tasks` and the `TaskCache` registry subtree, written together by
  the service). So it stages the payload and XML into the image and arms a machine `RunOnce` that
  registers the task at first logon — a one-shot whose only job is to create something permanent.

To remove one, delete the task and its payload:

```powershell
schtasks /delete /tn "\WindowsIsoMaker\Reverse mouse scroll direction" /f
Remove-Item "$env:ProgramData\WindowsIsoMaker\Tasks\Set-ReverseMouseScroll.ps1*"
```

### `Condition` — hardware-specific entries

Some changes only make sense on particular hardware. Rather than growing a per-feature switch
(forbidden by Principle III), an entry declares an optional `Condition`:

```powershell
Condition = @{
    Description = 'Microsoft Surface Laptop devices only (SMBIOS System SKU starts with Surface_Laptop).'
    Citation    = 'https://learn.microsoft.com/en-us/surface/surface-system-sku-reference'
    Script      = @'
$cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
($cs.SystemSKUNumber -like 'Surface_Laptop*') -or ($cs.Model -like '*Surface Laptop*')
'@
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `Script` | yes | PowerShell evaluated on the live target machine; its **last** emitted object is coerced to a boolean. Must be read-only detection (it also runs under `-WhatIf`). |
| `Description` | yes | Plain-English statement of the requirement, surfaced verbatim in the `NotApplicable` reason in the run report / Image BOM. |
| `Citation` | no | Authoritative source for the detection method. |

A `Condition` describes **the machine the image will run on**, so the two paths deliberately differ:

- **Offline build** ([`Invoke-CatalogEntry`](../src/WindowsIsoMaker/Public/Invoke-CatalogEntry.ps1))
  never evaluates it — the build agent is not the target machine, so testing it there would check
  the wrong hardware. The entry is reported `NotApplicable` with a reason pointing at
  `post-install.ps1`.
- **Post-install** ([`Invoke-OnlineCatalogEntry`](../src/WindowsIsoMaker/Private/Invoke-OnlinePostInstall.ps1))
  runs on the target, so it evaluates the condition and applies the entry only when satisfied.

Evaluation always **fails closed**: a condition that throws, fails to parse, emits nothing, or is
false-y leaves the entry unapplied, so a targeted tweak is never applied to hardware it was not
meant for because detection broke. The logic lives in
[`Private/CatalogEntryCondition.ps1`](../src/WindowsIsoMaker/Private/CatalogEntryCondition.ps1).

> `Script` is executed as-is. Catalog files are reviewed, repository-controlled data (the module
> already bakes catalog-authored `powershell.exe` RunOnce payloads), so this adds no new trust
> boundary — but a condition must never be sourced from untrusted input.

See `reg-power-button-no-action-ac` / `-dc` for a worked example: on Surface Laptops the power
button sits next to Delete, so an accidental press sleeps the machine; the entries set the
documented power-button action to *Take no action* and are a no-op on every other machine.

## Selecting changes

Selection is resolved by [`Resolve-CatalogSelection`](../src/WindowsIsoMaker/Private/Resolve-CatalogSelection.ps1)
from three inputs, in order of increasing precedence:

1. `Profile` — the baseline set (`minimal` / `default` / `aggressive` / `gaming` / `opinionated`,
   where `gaming` is `default` minus the entries tagged `Profiles = @('gaming')` so Xbox / Game Bar
   are preserved, and `opinionated` is `aggressive` plus the entries tagged
   `Profiles = @('opinionated')` personal-taste extras — reversed mouse scroll (via a helper task,
   so mice paired later are covered too), Start web-search off, lock-screen Spotlight off, a
   Surface-Laptop-only power button that does nothing instead of sleeping, WSL, and the United
   States-International keyboard layout for English (US)).
   `Profile` also accepts a list to combine baselines (e.g. `gaming,opinionated`):
   the selected profiles are UNIONed, and when `gaming` is one of them the `Profiles = @('gaming')`
   entries stay preserved — so `gaming,opinionated` gives aggressive debloat + opinionated tweaks
   with a working gaming stack.
2. `Toggles` — a per-id `@{ id = $true/$false }` map.
3. `EnableCatalogId` / `DisableCatalogId` — explicit ids always win.

Entries not applicable to the target `Architecture` are skipped automatically.

## Notable defaults

**Enabled by default (spec-mandated, grade 1, reversible):**

- `reg-disable-recall` — disables Windows Recall via the `DisableAIDataAnalysis` policy
  (privacy: Recall periodically captures screenshots).
  Cited: <https://learn.microsoft.com/en-us/windows/client-management/manage-recall>
- `reg-disable-widgets` — disables the Widgets board (weather/stock/news feed) via
  `AllowNewsAndInterests`.
- `reg-disable-device-metadata-apps` — stops the "get the companion app for your device" toasts
  (e.g. "Power up your precision mouse with Microsoft Mouse and Keyboard Center") by setting
  `PreventDeviceMetadataFromNetwork`. Drivers still install; only the metadata-driven vendor-app
  download/advertising stops. Cited:
  <https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-deviceinstallation#preventdevicemetadatafromnetwork>

Plus common consumer **provisioned app removals** (Candy Crush / King games, Clipchamp,
Bing News, MSN Weather, Solitaire, Xbox extras, Teams consumer, Get Help, Feedback Hub, etc.),
each citing Microsoft's provisioned-apps inventory
(<https://learn.microsoft.com/en-us/windows/application-management/provisioned-apps-windows-client-os>).

**Present but OFF by default (opt-in via `EnableCatalogId`):**

- `remove-edge`, `remove-onedrive` — impactful removals kept opt-in (FR-008).
- `feature-wsl`, `feature-vmplatform` — enable Windows Subsystem for Linux offline
  (see [wsl.md](wsl.md)).

## Auditing a build

After a build, `run-report.json` and the Image BOM list **exactly** which entries were applied
(and which were skipped and why), each with its citation and evidence grade. See
[provenance-bom.md](provenance-bom.md).
