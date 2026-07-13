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
| `Edition` / `Language` / `Release` / `Architecture` | Base image selection (Fido inputs). `Architecture` is `amd64` or `arm64`. Consumer editions (Home, Pro, Education, ...) all come from the **same** Fido consumer ISO — the edition is picked at install time — so the download is cached once per architecture/release and shared across them. **Enterprise / LTSC / IoT** editions aren't downloadable via Fido; supply `IsoPath` with a business-editions ISO. |
| `Profile` | Baseline change set: `minimal` (fewest changes), `default` (balanced), `aggressive` (most debloat), `gaming` (keeps Xbox/Game Bar), or `opinionated` (aggressive + personal-taste extras: reversed scroll, Start web-search off, Spotlight off, WSL, and the United States-International keyboard layout for English (US)). Accepts a list to combine profiles, e.g. `@('gaming','opinionated')` — the baselines are UNIONed and `gaming` keeps the gaming stack. |
| `Toggles` | Per-id override map, e.g. `@{ 'appx-todos' = $false; 'feature-wsl' = $true }`. |
| `EnableCatalogId` / `DisableCatalogId` | Force-enable / force-disable specific entries by `Id` (explicit ids win). |
| `Autounattend` | Install/OOBE-time options (see [autounattend.md](autounattend.md)). |
| `AzureUpload` | Optional off-box artifact storage (see [azure-upload.md](azure-upload.md)). |
| `WorkingDirectory` / `OutputDirectory` | Scoped working + output locations. |
| `IsoPath` | Provide a pre-downloaded ISO to skip Fido. **Required for Enterprise / LTSC / IoT** editions (Fido only serves the consumer ISO). |
| `BootTest` | Opt-in VM boot validation: boots the ISO in a throwaway Hyper-V VM and polls (bounded timeout) until the guest heartbeat is healthy, or the VM stays continuously Running long enough to prove it booted; default is structural checks only. |
| `KeepBootTestVm` | With `BootTest`: after the test resolves, keep the throwaway VM alive and pause until you press Enter so you can attach with `vmconnect localhost <vm>` and test interactively; the VM (and its VHDX) are still cleaned up afterwards. |
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
| `-Edition` / `-Language` / `-Release` | Base image overrides. |
| `-Profile` | `minimal` \| `default` \| `aggressive` \| `gaming` \| `opinionated`. Accepts a comma-separated list to combine, e.g. `-Profile gaming,opinionated`. |
| `-EnableCatalogId` / `-DisableCatalogId` | Opt-in / opt-out specific catalog ids. |
| `-ProductKey` | Override the Autounattend product key. Applied in the **`specialize`** pass (not `windowsPE`), so it is never subject to 24H2's windowsPE key-validation hard-stop. `''`/`none` install the metadata-selected edition unlicensed; a genuine key activates when valid. |
| `-UseGenericProductKey` | Bake the edition's generic/default retail key (applied in `specialize`, non-activating). The easy way to make a fully hands-off **Home** build. An explicit `-ProductKey` wins. |
| `-AccountMode` | OOBE account provisioning: `local` (create a local admin, hands-off) or `entra` (present the work/school sign-in to join Entra ID and auto-enroll into Intune). |
| `-SkipHeavyBuild` | Preview only: resolve config + report changes, no download/build. |
| `-BootTest` | Run the opt-in VM boot test. |
| `-KeepBootTestVm` | With `-BootTest`: keep the VM and pause for manual testing (vmconnect) until Enter, then clean up. |
| `-WhatIf` | Dry-run the whole pipeline (no media modified). |

## Examples

```powershell
# Default build
./build.ps1

# Dry-run to see exactly which changes would be applied
./build.ps1 -WhatIf

# Hands-off Home build (installs without a product key)
./build.ps1 -Edition Home

# Fully hands-off Home build with the generic key baked in (skips the OOBE product-key page)
./build.ps1 -Edition Home -UseGenericProductKey

# Keyed Pro build (applies a genuine key in the specialize pass; activates when valid)
./build.ps1 -Edition Pro -ProductKey '<genuine-key>'

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
```

## Outputs

Written to `OutputDirectory` (default `./out`):

- The compressed ISO artifact (`.zip`/`.7z`).
- `SHA256SUMS` — integrity manifest.
- `run-report.json` — every change applied (and skipped, with reasons).
- The Image BOM (CycloneDX + human-readable) — see [provenance-bom.md](provenance-bom.md).
