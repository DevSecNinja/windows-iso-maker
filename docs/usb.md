# Prepare a USB stick (stock ISO + post-install, no custom image)

You already have a **stock Windows 11 ISO** — say one you downloaded from your Visual Studio
subscription — and you just want a machine that ends up configured the same documented way, without
building a custom image. That is what `prepare-usb.ps1` (→ `New-PostInstallUsb`) is for.

You flash the ISO to a USB stick with your usual tool (Rufus, Ventoy, the Media Creation Tool,
`dd`, …). This tool then **adds** two things to that stick:

1. a copy of this toolkit in a folder at the stick's root, and
2. (default) a **minimal `Autounattend.xml`** at the root that runs the toolkit **once, elevated, at
   the first logon**.

> **Windows Setup stays completely stock.** The generated answer file contains nothing but an
> `oobeSystem` `FirstLogonCommands` block — no disk layout, no edition selection, no OOBE skip, no
> product key. Edition choice, partitioning and OOBE (including an **Entra ID** sign-in) stay
> interactive, and **no disk is ever wiped by this tool**. The full unattended answer file, which
> *does* configure disks and editions, belongs to the ISO build path — see
> [autounattend.md](autounattend.md).
>
> The Windows Setup files on the stick are never modified.

## ⚠️ When the automatic run does *not* fire

`FirstLogonCommands` is a Windows mechanism with a real limitation. Microsoft
[documents](https://learn.microsoft.com/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-firstlogoncommands-synchronouscommand)
that the commands run with elevated privileges **only when the first user to sign in is a local
administrator**. If that account is a standard user:

- with UAC enabled, a consent dialog appears and the commands **don't run if it is declined**;
- with UAC disabled, the commands **don't run at all**.

**This matters for Entra ID sign-in**, which is probably why you're here. Whether the account you
sign in with becomes a local administrator on the device is decided by your **Entra / Intune device
settings**, not by this tool — so the automatic run is **not guaranteed** in that scenario. Related:
`FirstLogonCommands` does not run in **Autopilot** pre-provisioning / self-deploying flows.

Because a silent no-op on a brand-new machine is the worst possible failure, the generated command
**always leaves a breadcrumb**:

```
C:\ProgramData\windows-iso-maker\logs\bootstrap.log
```

It records that discovery started, which toolkit it found (or that it found none), and whether
elevation succeeded. If nothing was applied, that file says so — and you can simply run the toolkit
by hand:

```powershell
# elevated
C:\ProgramData\windows-iso-maker\Invoke-PostInstall.ps1
```

If you'd rather not depend on the first-logon hook at all, use `-Mode Toolkit`.

## Quick start

```powershell
# Preview: validate the stick and show exactly what would be staged — writes nothing
./prepare-usb.ps1 -Path E: -Profile opinionated -WhatIf

# Prepare the stick
./prepare-usb.ps1 -Path E: -Profile opinionated
```

Then: boot the target PC from the stick, install Windows as usual, sign in — and the catalog is
applied automatically. Elevation is **not** required to prepare the stick (you are only writing to
the USB drive); the run on the target machine self-elevates.

## What it checks before writing

| Check | Behaviour |
|-------|-----------|
| Target exists | Hard error if the path/drive isn't there. |
| Target is removable | Refuses the **root of a fixed drive** (a mistyped `C:`) unless `-Force`. USB SSDs that report as "fixed" are still accepted when they sit on a USB bus. A folder target is always allowed. |
| Windows Setup media | Requires `setup.exe`, `sources\install.wim` (or `.esd`) and a boot loader (`efi\` / `boot\`). Tells you to flash the ISO first, or `-Force` to stage anyway. |
| Architecture | Derived from the media's UEFI boot loader — `bootx64.efi` → `amd64`, `bootaa64.efi` → `arm64`. Override with `-Architecture`. |
| Catalog selection | Resolves the `Profile` / `EnableCatalogId` / `DisableCatalogId` **before** touching the stick, so a typo'd id fails here instead of on the new PC. |
| Free space | Fails early if the stick can't hold the toolkit. |
| Existing `Autounattend.xml` | Never overwritten silently — needs `-Force` (or use `-Mode Toolkit`). |

## Modes

| Mode | What lands on the stick | What you do on the new PC |
|------|--------------------------|----------------------------|
| `FirstLogon` (default) | Toolkit folder **+** minimal `Autounattend.xml` | Install Windows, sign in — the catalog applies itself. |
| `Toolkit` | Toolkit folder only | Install Windows, sign in, then run `\<ToolkitFolder>\Invoke-PostInstall.cmd` from the stick (it self-elevates). |

Use `-Mode Toolkit` if the machine is enrolled through **Autopilot** or another provisioning flow
you'd rather not interleave with, or if you simply want to decide per machine.

## What lands on the stick

```
E:\
├── Autounattend.xml                    # only in FirstLogon mode; oobeSystem/FirstLogonCommands only
└── windows-iso-maker\                  # -ToolkitFolder (default 'windows-iso-maker')
    ├── Invoke-PostInstall.ps1          # generated bootstrap; your settings are baked in at the top
    ├── Invoke-PostInstall.cmd          # double-clickable launcher (self-elevates)
    ├── post-install.ps1                # the normal entry point
    ├── src\WindowsIsoMaker\            # the module
    ├── config\                         # build config + the change catalog
    └── docs\
```

The rest of the stick — `sources\`, `boot\`, `efi\`, `setup.exe` — is untouched.

Windows Setup finds the answer file through its documented
[implicit search order](https://learn.microsoft.com/windows-hardware/manufacture/desktop/windows-setup-automation-overview#implicit-answer-file-search-order):
removable media at the root of the drive, and — for a USB SSD that reports as fixed — the drive
Setup itself is running from.

## What happens on the target machine

The generated `Invoke-PostInstall.ps1`:

1. **Writes a breadcrumb** to `C:\ProgramData\windows-iso-maker\logs\bootstrap.log` before anything
   else, so even a run that cannot elevate leaves evidence.
2. **Self-elevates** if it isn't already running elevated, and reports loudly (log + warning) if that
   fails rather than exiting quietly.
3. **Copies the toolkit to `C:\ProgramData\windows-iso-maker`**, so the run survives the stick being
   unplugged and can be repeated after a reboot (a WSL install spans reboots).
4. Starts a **transcript** in `C:\ProgramData\windows-iso-maker\logs\`.
5. Runs `post-install.ps1` with the settings baked in when you prepared the stick, writing the usual
   auditable run report to `C:\ProgramData\windows-iso-maker\out\`.

Because every catalog change is idempotent, re-running it is always safe:

```powershell
# On the new machine, any time afterwards (elevated)
C:\ProgramData\windows-iso-maker\Invoke-PostInstall.ps1

# Preview only — needs no elevation
C:\ProgramData\windows-iso-maker\Invoke-PostInstall.ps1 -Preview
```

The settings live in an editable `$PostInstallSettings` hashtable at the top of that script, so you
can adjust the profile on the machine without re-preparing the stick.

## Parameters

| Parameter | Purpose |
|-----------|---------|
| `-Path` | The stick: `E:`, `E:\`, or any directory. |
| `-Mode` | `FirstLogon` (default) or `Toolkit`. |
| `-Profile` | One or more of `minimal` \| `default` \| `aggressive` \| `gaming` \| `opinionated` (UNIONed). Defaults to `default`. |
| `-EnableCatalogId` / `-DisableCatalogId` | Opt-in / opt-out catalog ids for the staged run (explicit ids win). |
| `-Scope` | Per-user target of the staged run: `CurrentUser`, `FutureUsers`, `Both` (default). |
| `-Architecture` | `amd64` \| `arm64`. Auto-detected from the media. |
| `-InstallWsl` / `-WslDistribution` / `-WslServicing` / `-WslAutoReboot` | Have the staged run install WSL (implied by `opinionated`), which distribution, how WSL is obtained, and whether it may reboot on its own. |
| `-ToolkitFolder` | Folder name at the stick's root (default `windows-iso-maker`). |
| `-Force` | Allow a fixed-drive root or non-Setup media, and overwrite an existing `Autounattend.xml` / staged toolkit. |
| `-WhatIf` | Validate everything and report the plan without writing. |

## Caveats

- **Entra ID / work accounts.** See [the section above](#-when-the-automatic-run-does-not-fire) —
  the first-logon hook only runs elevated when the signed-in account is a local administrator, which
  Entra/Intune decides. Check `bootstrap.log`, and prefer `-Mode Toolkit` for **Autopilot** devices.
- **Security.** The answer file makes Windows run a script from removable media, elevated, with
  `-ExecutionPolicy Bypass`, at the first logon. That is inherent to the mechanism. Anyone who can
  modify the staged toolkit could already modify `install.wim` on the same stick, so treat the stick
  itself as the trust boundary and don't prepare a stick you then leave unattended.
- **The commands run in order, one at a time.** Modern Windows runs `FirstLogonCommands`
  asynchronously with respect to other logon work, but each command still runs to completion in
  sequence. Expect the first logon to be busy for several minutes; the transcript shows progress.
- **Reboots.** Additive features (notably WSL) finish after a reboot — just re-run the bootstrap
  from `C:\ProgramData\windows-iso-maker`. See [wsl.md](wsl.md).
- **Hardware-conditional entries** are evaluated here (unlike an offline build) because this runs on
  the actual machine — see [change-rationale.md](change-rationale.md#condition--hardware-specific-entries).
- **Ventoy and other multi-ISO loaders** boot the ISO, not the stick's file system, so Setup will not
  find an `Autounattend.xml` you placed next to it. Use `-Mode Toolkit` there.
- This path produces **no ISO, no SBOM and no provenance bundle** — those belong to the offline build
  path ([provenance-bom.md](provenance-bom.md)). It shares the change catalog and the run report.

## Related

- [post-install.md](post-install.md) — running the catalog on a machine that is already installed.
- [usage.md](usage.md) — building a custom ISO instead.
- [autounattend.md](autounattend.md) — the *full* answer file used by the ISO build path.
