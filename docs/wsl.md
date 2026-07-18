# Windows Subsystem for Linux (WSL)

WSL is shipped as an **opt-in** catalog entry that is **off by default**. Enabling it turns on
the required Windows optional features on the offline image so the finished ISO is "WSL-ready".

## Catalog entries

In [config/catalog.capabilities.psd1](../config/catalog.capabilities.psd1):

- `feature-wsl` — enables `Microsoft-Windows-Subsystem-Linux`
- `feature-vmplatform` — enables `VirtualMachinePlatform` (required for WSL 2)

Both use `Action = 'EnableOptionalFeature'`, which
[`Enable-WindowsFeature`](../src/WindowsIsoMaker/Public/Enable-WindowsFeature.ps1) applies to
the mounted image via `Enable-WindowsOptionalFeature -Path <mount>`.

## Enabling it

```powershell
# Local
./build.ps1 -EnableCatalogId feature-wsl,feature-vmplatform

# In config/build.config.psd1
Toggles = @{ 'feature-wsl' = $true; 'feature-vmplatform' = $true }
```

In the `build-image.yml` workflow, set the `enable_catalog_id` input to
`feature-wsl,feature-vmplatform`.

## Important: first-boot behaviour (a Windows constraint)

Enabling the optional features **offline** only turns on the platform. The **WSL 2 kernel** and
any **Linux distribution** are downloaded **online on first boot**. Right after the features are
enabled (and before a reboot + `wsl --update`), `wsl.exe` reports
`Wsl/CallMsi/Install/REGDB_E_CLASSNOTREG` — this is expected: the WSL app/kernel are not installed
yet, and this is a Microsoft platform constraint, not a fault of this tool.

## Finishing the install: `Install-WslDistribution` (detect-driven & resumable)

On current Windows 11 builds `wsl --install -d <Distro> --no-launch` does everything in one
command — it enables the required components, installs the WSL engine + kernel, and installs the
distribution (new installs default to WSL 2). The only complication is that this spans one or more
**reboots**, so the module ships `Install-WslDistribution`, a thin **detect → act → reboot-and-re-run**
wrapper. Each run:

1. If `<Distribution>` is already installed and WSL is functional → **Done** (idempotent).
2. If a reboot is pending → records the target distro in the tattoo (`HKLM\SOFTWARE\WindowsIsoMaker\Wsl`)
   and asks you to **reboot and re-run**.
3. Otherwise runs `wsl --install -d <Distribution> --no-launch` (`--no-launch` skips the interactive
   first-run account setup — you create your Linux user the first time you run `wsl -d <Distribution>`).
4. For the Store / WebDownload engines only, if WSL is still not functional afterwards (the
   `REGDB_E_CLASSNOTREG` state), runs `wsl --update` once to install/repair the app + kernel.
5. Re-checks: distro present → **Done**; otherwise a reboot is needed → reboot and re-run.

```powershell
# From an ELEVATED session:
Import-Module ./src/WindowsIsoMaker
Install-WslDistribution -Distribution Debian        # reboot and re-run until Stage = Done
Install-WslDistribution -Distribution Debian -WhatIf    # preview the next action
Install-WslDistribution -Distribution Debian -AutoReboot # reboot for you at each step
```

The command requires elevation for real runs and returns a result object with `Distribution`,
`Servicing`, `Stage`, `RebootRequired`, `DistributionInstalled`, and a `Message`. Once it reports
`Stage = Done`, launch the distro once (`wsl -d Debian`) to create your Linux account.

### Servicing model: `-WslServicing`

How WSL *itself* is obtained is selectable (the flag maps to `wsl --install` options):

| `-WslServicing` | Command | Engine | Notes |
|---|---|---|---|
| `Store` (default) | `wsl --install` | Modern WSL 2.x | **Auto-updates** via the Microsoft Store. Best for a normal dev machine. |
| `WebDownload` | `wsl --install --web-download` | Modern WSL 2.x | Same engine from GitHub; no Store dependency. Best when the Store is blocked. |
| `Inbox` | `wsl --install --inbox` | In-Windows component | Serviced by **Windows Update** (older engine). Hermetic/offline-friendly; matches an image that baked the WSL features. `wsl --update` is skipped for this mode. |

The natural split: **bake the inbox component offline in the image** (the `feature-wsl` /
`feature-vmplatform` catalog entries), and use **`-WslServicing Store`** (the default) when running
post-install on a vanilla ISO so you get the auto-updating modern engine.

### One command via `post-install.ps1`

Installing WSL is **on by default for the `opinionated` profile**, so a single run both applies the
catalog and installs WSL + the distribution (the WSL result is attached to the report as a `Wsl`
property):

```powershell
# From an ELEVATED session — opinionated implies WSL (Store engine, Debian, the defaults):
./post-install.ps1 -Profile opinionated
# ... reboot if asked, then re-run the same command until Wsl.Stage = Done ...

# Force WSL for another profile, or change the engine / reboot automatically:
./post-install.ps1 -Profile default -InstallWsl -WslServicing WebDownload -WslAutoReboot

# Opt OUT of WSL under opinionated:
./post-install.ps1 -Profile opinionated -InstallWsl:$false
```

`Install-WslDistribution` enables the WSL platform features itself via `wsl --install` if they are
not already on. `-InstallWsl` forces it for non-opinionated profiles; `-InstallWsl:$false` skips it
under opinionated.

### Troubleshooting: `REGDB_E_CLASSNOTREG`

If `wsl` keeps returning `Wsl/CallMsi/Install/REGDB_E_CLASSNOTREG` even after a reboot **and** the
Store package is installed (`winget list` shows it), WSL's COM server is not registered — which can
happen when the optional component was enabled **offline** (as the image build does) so the online
registration step never ran. Fix from an elevated prompt:

```powershell
# 1. Re-register the Store package for your user:
Get-AppxPackage -AllUsers *WindowsSubsystemForLinux* | ForEach-Object {
  Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppxManifest.xml"
}
wsl --shutdown; wsl --version

# 2. If still broken, complete the offline-enabled feature registration ONLINE, then reboot:
Enable-WindowsOptionalFeature -Online -All -FeatureName VirtualMachinePlatform, Microsoft-Windows-Subsystem-Linux
```

## Why opt-in

Enabling WSL adds virtualization features and attack surface that not every image needs, so it
is off by default (Principle VI). It is a grade-1, reversible change; to undo it on a running
system:

```powershell
Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
```
