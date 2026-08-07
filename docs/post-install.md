# Post-install setup (apply the catalog to an existing machine)

Sometimes you don't want to build a custom ISO — you already have a **stock Windows 11** running
and just want the same documented, data-driven changes applied to it. Typical cases:

- A machine you reset with **"Reset this PC" → cloud/local reinstall**.
- A VM or PC installed from an **ISO you downloaded from your Visual Studio subscription**.
- Any fresh Windows 11 you did **not** build with this tool.

`post-install.ps1` (→ `Invoke-PostInstallSetup`) is the **online sibling** of `build.ps1`
(→ `Invoke-IsoBuild`). Instead of servicing an offline image and producing an ISO, it applies the
**exact same change catalog** — same `Profile`s, same `EnableCatalogId`/`DisableCatalogId`, same
audit trail — directly to the running system.

> **Same catalog, same guarantees.** Every change is still a cited, evidence-graded, reversible
> catalog entry (see [change-rationale.md](change-rationale.md)). Nothing new is invented for the
> online path; it is the identical selection logic (`Resolve-CatalogSelection`) applied online.

> 💡 **Installing from your own USB stick?** [`prepare-usb.ps1`](usb.md) stages this same toolkit
> onto the stick and can run it automatically at the first logon, so you don't have to fetch the
> repo on the new machine.

## Quick start

Run from an **elevated** PowerShell session (Administrator):

```powershell
# Preview EVERYTHING the opinionated profile would change — touches nothing
./post-install.ps1 -Profile opinionated -WhatIf

# Apply the opinionated profile to this machine
./post-install.ps1 -Profile opinionated

# Default debloat plus opt-in Edge removal and the WSL platform features
./post-install.ps1 -Profile default -EnableCatalogId remove-edge,feature-wsl

# Keep the gaming stack while applying the opinionated tweaks
./post-install.ps1 -Profile gaming,opinionated
```

You can also call the command directly once the module is imported:

```powershell
Import-Module ./src/WindowsIsoMaker -Force
Invoke-PostInstallSetup -Profile aggressive -WhatIf
```

## What each catalog action does online

| Catalog `Action`        | Offline (ISO build)                          | Online (post-install)                                                                 |
|-------------------------|----------------------------------------------|----------------------------------------------------------------------------------------|
| `SetRegistry` (machine) | Writes the offline `SOFTWARE`/`SYSTEM` hive  | Writes live `HKLM\SOFTWARE` / `HKLM\SYSTEM`                                             |
| `SetRegistry` (per-user)| Writes the offline `DEFAULT` hive            | Writes the **current user** (`HKCU`) **and** the default-user template (`C:\Users\Default\NTUSER.DAT`), so both you and every new profile get it |
| `RemoveAppx`            | De-provisions in the image                   | **De-provisions** (new profiles) **and uninstalls** it for the **current user**        |
| `RemoveCapability`      | `dism /Image:` remove                        | `dism /online` remove                                                                  |
| `EnableOptionalFeature` / `AddCapability` | `dism /Image:` (staged)   | `dism /online` (a **reboot** may be required to finish, e.g. WSL — see [wsl.md](wsl.md)) |
| `RegisterScheduledTask` | Stages the payload into the image and arms a first-boot `RunOnce` to register it | **Registers the task immediately** into the `\WindowsIsoMaker` folder **and runs it once**, so devices already attached are handled straight away |

### Settings that need a helper task

Some settings cannot be written once and left alone, because Windows stores them **per device**
rather than machine-wide. Mouse scroll direction is the clearest example: `FlipFlopWheel` lives
under each mouse's own `Enum\HID\<instance>\Device Parameters` key — the same value Windows'
*Scrolling direction* toggle writes — so applying it once only covers the mice connected at that
moment, and a mouse paired afterwards keeps scrolling the other way.

Entries with `Action = RegisterScheduledTask` close that gap: they install a small payload plus a
task that re-applies the setting when the relevant device shows up. Running `post-install.ps1`
registers the task and runs it once immediately, so you do not have to wait for the next trigger.
Everything the tool installs this way lives in the `\WindowsIsoMaker` Task Scheduler folder and
under `%ProgramData%\WindowsIsoMaker\Tasks` (which is locked down to SYSTEM and Administrators,
since a SYSTEM task executes what it finds there):

```powershell
schtasks /query /tn "\WindowsIsoMaker\" /fo list
```

> A task running as SYSTEM is only visible to an **elevated** session — querying it as a normal
> user returns *Access is denied*, not "not found".

These tasks are triggered by real Windows events (device arrival), never by polling — see
[change-rationale.md](change-rationale.md#registerscheduledtask--settings-that-must-survive-new-devices)
for why a change that would need a repeating trigger is deliberately left out of the catalog.

See [change-rationale.md](change-rationale.md#registerscheduledtask--settings-that-must-survive-new-devices)
for the full schema and how to remove one.

### Hardware-specific entries

An entry may declare a `Condition` describing the machine it applies to (for example
`reg-power-button-no-action-ac`, which only makes sense on a Surface Laptop). **This is the path
that evaluates it.** The offline build cannot — the build agent is not the machine the image ends
up on — so it reports such entries `NotApplicable`; running `post-install.ps1` on the installed
machine is what actually applies them. A condition that is unmet, or that cannot be evaluated,
leaves the entry unapplied and is recorded with its reason. See
[change-rationale.md](change-rationale.md#condition--hardware-specific-entries).

## Parameters

| Parameter            | Purpose                                                                                          |
|----------------------|--------------------------------------------------------------------------------------------------|
| `-Profile`           | One or more of `minimal` \| `default` \| `aggressive` \| `gaming` \| `opinionated` (UNIONed). Defaults to `default`. |
| `-EnableCatalogId`   | Opt-in catalog ids to force-enable (e.g. `remove-edge`, `feature-wsl`).                          |
| `-DisableCatalogId`  | Catalog ids to force-disable (explicit ids win).                                                 |
| `-Architecture`      | `amd64` \| `arm64`. **Auto-detected** from the running OS when omitted.                          |
| `-Scope`             | Where per-user tweaks/Appx removals land: `CurrentUser`, `FutureUsers`, or `Both` (default).     |
| `-OutputDirectory`   | Where the run-report JSON is written. Defaults to `./out`.                                       |
| `-NoReport`          | Do not write the run-report JSON (the object is still returned).                                 |
| `-InstallWsl`        | After the catalog, advance the staged WSL + distribution install (multi-reboot; re-run until done). Attaches a `Wsl` result to the report. See [wsl.md](wsl.md). |
| `-WslDistribution`   | Linux distribution to install when `-InstallWsl` is set (default `Debian`).                       |
| `-WslAutoReboot`     | When `-InstallWsl` needs a reboot, restart the computer automatically instead of just asking.    |
| `-WhatIf`            | Preview the full plan without changing anything.                                                 |

## Scope: current user vs. future profiles

Per-user changes on an **already-installed** machine are subtle: your profile already exists, so a
tweak written only to the new-user template (the offline behaviour) would never reach you. By
default (`-Scope Both`) the post-install path therefore applies per-user registry tweaks and Appx
removals to **both**:

- the **current user** (`HKCU`, and `Remove-AppxPackage` for installed apps), and
- **future profiles** (the `C:\Users\Default\NTUSER.DAT` template, and de-provisioning).

Use `-Scope CurrentUser` to only affect the profile you're logged in as, or `-Scope FutureUsers`
to leave your current profile untouched and only shape new ones.

## Idempotency, safety & auditing

- **Idempotent** — re-running is safe; entries already in the desired state are recorded
  `AlreadyApplied`.
- **`-WhatIf`** — a full dry run that changes nothing and requires no elevation.
- **Run report** — a JSON `RunReport` (`out/post-install-report.json`, or
  `…preview.json` under `-WhatIf`) records every applied/skipped change with its citation, exactly
  like a build.
- **Reversible** — every change carries a `Reversal` in the catalog; see
  [change-rationale.md](change-rationale.md).

## Requirements & notes

- Run **elevated** (Administrator): machine-wide `HKLM` and `dism /online` changes require it.
  `-WhatIf` does not.
- Some additive features (e.g. WSL) finish only after a **reboot** plus a follow-up command — see
  [wsl.md](wsl.md).
- This path does **not** produce an ISO, an `Autounattend.xml`, or an SBOM/provenance bundle — those
  belong to the offline build path (`build.ps1`). It shares only the change catalog and its report.
