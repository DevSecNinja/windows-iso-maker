# Usage (local builds)

The **configuration file is the primary interface**. You normally edit
`config/build.config.psd1` (or keep several saved profiles) and run `./build.ps1`. Command-line
parameters and `WIM_*` environment variables exist only as optional last-mile overrides.

## Prerequisites

- Windows 10/11 with **administrator** rights (offline DISM servicing is Windows-only).
- PowerShell 5.1 or PowerShell 7+.
- Windows ADK **Deployment Tools** installed (provides `oscdimg`). `OscdimgPath` is
  auto-detected from a standard ADK install; set it explicitly if installed elsewhere.
- Internet access for Fido to resolve/download the base ISO (unless you supply `IsoPath`).

> On Linux you can develop and run the tests/linter (`Invoke-Pester`, `Invoke-ScriptAnalyzer`),
> but not the actual image build. Use the GitHub Actions `build-image.yml` workflow or a
> Windows machine for that.

## The config file

`config/build.config.psd1` returns a hashtable. Key fields:

| Field | Meaning |
|-------|---------|
| `Edition` / `Language` / `Release` / `Architecture` | Base image selection. `Architecture` is `amd64` or `arm64`. **Only the Home SKUs** (Home, Home N, Home Single Language) come from the Fido consumer ISO — cached once per architecture/release. **Every other edition** (Pro, Education, Enterprise, LTSC, IoT, ...) only installs and activates from the **business/volume ISO** (retail generic keys and volume/GVLK keys are not interchangeable), which Fido can't download; supply `IsoPath` with the matching business-editions ISO (e.g. from a Visual Studio / volume-licensing subscription). |
| `Profile` | Baseline change set: `minimal` (fewest changes), `default` (balanced), `aggressive` (most debloat), `gaming` (keeps Xbox/Game Bar), or `opinionated` (aggressive + personal-taste extras: reversed scroll, Start web-search off, Spotlight off, WSL, and the United States-International keyboard layout for English (US)). Accepts a list to combine profiles, e.g. `@('gaming','opinionated')` — the baselines are UNIONed and `gaming` keeps the gaming stack. |
| `Toggles` | Per-id override map, e.g. `@{ 'appx-todos' = $false; 'feature-wsl' = $true }`. |
| `EnableCatalogId` / `DisableCatalogId` | Force-enable / force-disable specific entries by `Id` (explicit ids win). |
| `Autounattend` | Install/OOBE-time options (see [autounattend.md](autounattend.md)). |
| `AzureUpload` | Optional off-box artifact storage (see [azure-upload.md](azure-upload.md)). |
| `WorkingDirectory` / `OutputDirectory` | Scoped working + output locations. |
| `IsoPath` | Provide a pre-downloaded ISO to skip Fido. **Required for every non-Home edition** (Pro / Education / Enterprise / LTSC / IoT — Fido only serves the consumer ISO, whose Pro/Education images won't activate with a volume/GVLK key). |
| `BootTest` | Opt-in VM boot validation: boots the ISO in a throwaway VM (Hyper-V or VMware, see `Hypervisor`) and polls (bounded timeout) until the guest heartbeat is healthy, or the VM stays continuously Running long enough to prove it booted; default is structural checks only. |
| `Hypervisor` | Which hypervisor runs the opt-in boot test: `HyperV` (default) or `VMware` (VMware Workstation Pro). Hyper-V boots the VM **offline** by default; VMware boots it **NAT-connected** by default so WinPE has real DNS for 24H2 "ConX" online product-key/edition validation (issue #5). VMware Workstation Pro must be **downloaded manually** (Broadcom login-gated; not installable via winget) — if it's missing the build prints the Broadcom download link + first-run guidance. |
| `KeepBootTestVm` | With `BootTest`: after the test resolves, keep the throwaway VM alive and pause until you press Enter so you can attach interactively (`vmconnect localhost <vm>` for Hyper-V, `vmware -t <vmx>` for VMware); the VM and its disk are still cleaned up afterwards. |
| `CompressionFormat` | `zip` or `7z`. |
| `FidoPath` / `OscdimgPath` | Tool locations. `FidoPath` empty = download the pinned Fido at build time (set a path only for offline use); `OscdimgPath` empty = auto-detect from a Windows ADK install. |

### Multiple saved profiles

Copy the default to, say, `config/build.arm64.psd1`, tweak it, then:

```powershell
./build.ps1 -ConfigPath config/build.arm64.psd1
# or
$env:WIM_CONFIG_PATH = 'config/build.arm64.psd1'; ./build.ps1
```

## `build.ps1` parameters (optional overrides)

| Parameter | Purpose |
|-----------|---------|
| `-ConfigPath` (alias `-Path`) | Config file to load (default `config/build.config.psd1`). |
| `-Architecture` | `amd64` \| `arm64`. |
| `-Edition` / `-Language` / `-Release` | Base image overrides. Non-Home editions require `-IsoPath` (business ISO). |
| `-IsoPath` | Pre-downloaded base ISO (skips Fido). **Required for non-Home editions** (Pro / Education / Enterprise / ...), which only ship on the business/volume ISO. |
| `-Profile` | `minimal` \| `default` \| `aggressive` \| `gaming` \| `opinionated`. Accepts a comma-separated list to combine, e.g. `-Profile gaming,opinionated`. |
| `-EnableCatalogId` / `-DisableCatalogId` | Opt-in / opt-out specific catalog ids. **Tab-completes** live from the change catalog — press <kbd>Tab</kbd> to cycle ids; each suggestion's tooltip shows its `[Category]` and description. |
| `-ProductKey` | Override the Autounattend product key. Applied in the **`windowsPE`** UserData pass so 24H2 multi-edition media does not stop at the product-key page. `''`/`none` omit the key (Setup may prompt on multi-edition media); a genuine key activates when valid. |
| `-UseGenericProductKey` | Bake the edition's generic key (applied in `windowsPE`, non-activating): the **retail generic** key for Home (consumer ISO) or the **GVLK / KMS client** key for business editions (business ISO). Makes a fully hands-off build. **Mutually exclusive** with `-ProductKey` (passing both is an error). |
| `-AccountMode` | OOBE account provisioning: `local` (create a local admin, hands-off) or `entra` (present the work/school sign-in to join Entra ID and auto-enroll into Intune). |
| `-SkipHeavyBuild` | Preview only: resolve config + report changes, no download/build. |
| `-BootTest` | Run the opt-in VM boot test. |
| `-Hypervisor` | `HyperV` (default) \| `VMware`. Selects the boot-test hypervisor. `VMware` uses VMware Workstation Pro and boots NAT-connected by default (real WinPE DNS for 24H2 ConX validation); it must be **downloaded manually** (Broadcom login-gated, no winget), and the build prints the download link + guidance when it's missing. |
| `-KeepBootTestVm` | With `-BootTest`: keep the VM and pause for manual testing until Enter, then clean up. Attach with `vmconnect` (Hyper-V) or the VMware console (`vmware -t <vmx>`). |
| `-WhatIf` | Dry-run the whole pipeline (no media modified). |

> **Tab completion.** `-Edition`, `-Language`, `-Release`, `-EnableCatalogId` and `-DisableCatalogId`
> all offer <kbd>Tab</kbd> suggestions (alongside the fixed-choice `-Architecture`, `-Profile`,
> `-AccountMode` and `-Hypervisor`). The catalog-id parameters complete live from `config/catalog.*.psd1`,
> so new entries appear automatically. Edition/Language/Release suggestions are advisory — any valid
> value is still accepted even if it isn't listed.

## Examples

```powershell
# Default build
./build.ps1

# Dry-run to see exactly which changes would be applied
./build.ps1 -WhatIf

# Fully hands-off Home build with the generic key baked in (skips the product-key page)
./build.ps1 -Edition Home -UseGenericProductKey

# Hands-off Pro build from a business/volume ISO (bakes the Pro GVLK; supply the business ISO)
./build.ps1 -Edition Pro -IsoPath 'C:\isos\Win11_24H2_Business_x64.iso' -UseGenericProductKey

# Keyed Pro build (business ISO + a genuine key applied in windowsPE; activates when valid)
./build.ps1 -Edition Pro -IsoPath 'C:\isos\Win11_24H2_Business_x64.iso' -ProductKey '<genuine-key>'

# Corporate image: join Entra ID / auto-enroll into Intune at OOBE
./build.ps1 -Edition Pro -ProductKey '<genuine-key>' -AccountMode entra

# Aggressive profile, but keep the Xbox game overlay
./build.ps1 -Profile aggressive -DisableCatalogId appx-xbox-game-overlay

# Gaming profile: full debloat but preserve Xbox Game Bar and the Xbox provisioned apps
./build.ps1 -Profile gaming

# Game PC: aggressive debloat + opinionated tweaks (reversed scroll, US-International keyboard,
# WSL, ...) while keeping the whole Xbox / Game Bar gaming stack
./build.ps1 -Profile gaming,opinionated

# Opt in to Edge + OneDrive removal and enable WSL
./build.ps1 -EnableCatalogId remove-edge,remove-onedrive,feature-wsl

# Environment-variable overrides (CI-friendly)
$env:WIM_ARCH = 'arm64'; $env:WIM_ENABLE_CATALOG_ID = 'feature-wsl'; ./build.ps1

# Boot-test the built ISO in a throwaway Hyper-V VM (offline by default)
./build.ps1 -BootTest

# Boot-test in VMware Workstation instead (NAT-connected: real WinPE DNS for 24H2 ConX validation).
# If VMware isn't installed you'll get the Broadcom download link + setup guidance and the build stops.
./build.ps1 -BootTest -Hypervisor VMware

# Keep the VMware VM up after the test so you can watch Setup / press Shift+F10 for logs
./build.ps1 -BootTest -Hypervisor VMware -KeepBootTestVm
```

## Boot-test hypervisors (Hyper-V vs VMware)

The opt-in boot test (`-BootTest`) can run under either hypervisor via `-Hypervisor` (or the
`Hypervisor` config field / `WIM_HYPERVISOR` env var):

- **`HyperV`** (default) — boots a throwaway Gen2 VM **offline**. Requires the Hyper-V feature and
  membership in the *Hyper-V Administrators* group.
- **`VMware`** — boots a throwaway VM under **VMware Workstation Pro**, **NAT-connected by default**
  so WinPE gets working DNS. This is the recommended path for diagnosing the 24H2 "ConX" Setup
  *"failed to validate the product key"* failure (issue #5), which needs real online validation.
  Pass `-ConnectNetwork:$false` to force it offline.

> **No virtual TPM under VMware.** Unlike the Hyper-V VM (which gets a real vTPM 2.0 via a local key
> protector), the VMware boot-test VM has **no vTPM**: VMware Workstation can only add one to an
> *encrypted* VM through the GUI, and `vmrun`/`vmcli` expose no TPM or encryption command, so it
> can't be scripted headlessly. This is fine for the boot test — the generated media runs a fully
> scripted `windowsPE` image apply, which never invokes the Windows 11 hardware appraiser (the
> CPU/TPM/RAM "This PC can't run Windows 11" gate only runs in *interactive* Setup), so the
> unattended install proceeds without one. Secure Boot is still enabled on both hypervisors.

If `-Hypervisor VMware` is selected but VMware Workstation is not installed, the build cannot install
it for you: Broadcom puts VMware Workstation Pro behind a **free-account login**, so it is not on
winget and can't be scripted. The build prints the download link and step-by-step guidance:

1. Open the Broadcom portal (sign in / create a free account when prompted) and download
   **VMware Workstation Pro**:
   <https://support.broadcom.com/group/ecx/productdownloads?subfamily=VMware%20Workstation%20Pro&freeDownloads=true>
2. Run the installer — VMware Workstation Pro is **free for personal, non-commercial use**.
3. First-run setup: accept the EULA and select *"Use VMware Workstation Pro for Personal Use"*.
4. Re-run with `-Hypervisor VMware` once `vmrun.exe` exists under the VMware Workstation folder.

For reference the build also shows the (delisted) winget command and, if you insist, will attempt it —
but it almost always fails with *"No package found"*, so prefer the manual download above.

> **Log harvest note:** modern VMware Workstation dropped `vmware-mount`, so the build cannot mount
> the VM's virtual disk offline to harvest Setup logs. Use `-KeepBootTestVm` to keep the VM up, then
> in the VMware console press **Shift+F10** at the Setup screen and copy the WinPE logs (e.g.
> `robocopy X:\Windows\Logs C:\pe-logs /E`).

## Outputs

Written to `OutputDirectory` (default `./out`):

- The compressed ISO artifact (`.zip`/`.7z`).
- `SHA256SUMS` — integrity manifest.
- `run-report.json` — every change applied (and skipped, with reasons).
- The Image BOM (CycloneDX + human-readable) — see [provenance-bom.md](provenance-bom.md).
