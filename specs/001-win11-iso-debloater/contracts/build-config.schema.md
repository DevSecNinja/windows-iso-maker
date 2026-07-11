# Contract: build.config.psd1 (Build Configuration Schema)

The build configuration file is the **primary interface** for driving a build. The default
lives at `config/build.config.psd1` and is loaded by `Get-BuildConfiguration`. It is a
PowerShell data file (`.psd1`) returning a hashtable. Because the program exposes many
settings, users are expected to configure builds by editing (or supplying) a config file
rather than passing long parameter lists.

A user MAY point at an alternate file with `-ConfigPath <path>` (or `WIM_CONFIG_PATH`),
enabling multiple saved profiles (e.g. `config/build.pro.psd1`, `config/build.arm64.psd1`).
A small set of explicit parameters remains available purely as optional last-mile overrides
(precedence: **config file → environment variables → explicit parameters**, later wins), but
the config file is the intended, documented way to configure a build.

## Shape

```powershell
@{
    # --- Base image selection (FR-001, FR-002) ---
    Edition      = 'Pro'        # Windows 11 edition
    Language     = 'en-US'      # display language
    Release      = 'latest'     # resolved by Fido at build time
    Architecture = 'amd64'      # 'amd64' | 'arm64'  (validated)

    # --- Profile & change selection (FR-024: data-driven, no per-feature switches) ---
    Profile          = 'default'   # 'minimal' | 'default' | 'aggressive' — named catalog subset
    Toggles          = @{}         # per-entry overrides: @{ 'remove-edge' = $true; 'reg-x' = $false }
    EnableCatalogId  = @()         # force-enable specific entries by Id (opt-in Edge/OneDrive/WSL)
    DisableCatalogId = @()         # force-disable specific entries by Id

    # --- Working locations (Principle VI: scoped, no host-wide writes) ---
    WorkingDirectory = "$env:TEMP\WindowsIsoMaker"
    OutputDirectory  = './out'

    # --- Autounattend (FR-027: generated per-arch from this config) ---
    Autounattend = @{
        SkipOobe           = $true
        BypassMsAccount    = $true      # bypass MS-account requirement (toggleable)
        CreateLocalAccount = $true      # create a local account (default on)
        LocalAccountName   = 'admin'
        KeyboardLayout     = '0409:00000409'
        TimeZone           = 'UTC'
        DiskLayout         = 'default-uefi-gpt'
        FirstLogonCommands    = @()
        SetupCompleteCommands = @()
    }

    # --- Optional Azure Blob upload (FR-030: OIDC, no stored secrets) ---
    AzureUpload = $null              # or @{ StorageAccount = '...'; Container = '...' }

    # --- Validation (FR-023) ---
    BootTest = $false           # opt-in VM boot test; default structural checks only

    # --- Artifact ---
    CompressionFormat = 'zip'   # 'zip' | '7z'

    # --- Tooling (pinned; Principle V) ---
    FidoPath    = 'vendor/fido/Fido.ps1'
    OscdimgPath = ''            # empty = auto-detect from ADK install
}
```

## Validation rules

| Field | Rule |
|-------|------|
| `Edition` | non-empty string |
| `Language` | non-empty string |
| `Release` | non-empty string (`latest` allowed) |
| `Architecture` | one of `amd64`, `arm64` |
| `Profile` | one of `minimal`, `default`, `aggressive` |
| `Toggles` | hashtable; every key MUST be a catalog Id; values boolean |
| `EnableCatalogId` / `DisableCatalogId` | every id MUST exist in the catalog |
| `WorkingDirectory` / `OutputDirectory` | resolvable, creatable, writable |
| `Autounattend` | hashtable; booleans are boolean; `processorArchitecture` is derived from `Architecture` (FR-027) |
| `AzureUpload` | `$null`, or hashtable with non-empty `StorageAccount` + `Container` (FR-030) |
| `BootTest` | boolean |
| `CompressionFormat` | one of `zip`, `7z` |
| `FidoPath` | resolvable file when a download is required |
| `OscdimgPath` | resolvable file, or empty to auto-detect from ADK |

> **Migration note (FR-024)**: the former `RemoveEdge` / `RemoveOneDrive` boolean fields have
> been removed. Edge and OneDrive removal are now ordinary opt-in catalog entries
> (`remove-edge`, `remove-onedrive`, `DefaultEnabled=false`) enabled via `EnableCatalogId` or
> `Toggles`. This keeps the config free of per-feature switch proliferation (SC-011).

## Environment variable overrides

Recognized env vars (prefix `WIM_`) map onto fields, e.g.:

| Env var | Field |
|---------|-------|
| `WIM_EDITION` | `Edition` |
| `WIM_LANGUAGE` | `Language` |
| `WIM_RELEASE` | `Release` |
| `WIM_ARCH` | `Architecture` |
| `WIM_PROFILE` | `Profile` |
| `WIM_ENABLE_CATALOG_ID` | `EnableCatalogId` (comma-separated) |
| `WIM_DISABLE_CATALOG_ID` | `DisableCatalogId` (comma-separated) |
| `WIM_OUTPUT_DIR` | `OutputDirectory` |
| `WIM_BOOT_TEST` | `BootTest` |
| `WIM_AZURE_STORAGE_ACCOUNT` | `AzureUpload.StorageAccount` |
| `WIM_AZURE_STORAGE_CONTAINER` | `AzureUpload.Container` |

Secrets are never read from config files or logged (Principle VII); none are required for a
build (Fido resolves public Microsoft URLs).

## Catalog files

The change catalog is split across `config/catalog.appx.psd1`,
`config/catalog.capabilities.psd1` (including `EnableOptionalFeature`/`AddCapability` entries
such as WSL), and `config/catalog.registry.psd1`. Each returns an array of
`ChangeCatalogEntry` hashtables conforming to
[change-catalog.schema.json](./change-catalog.schema.json) and validated by
`tests/Catalog.Schema.Tests.ps1` (including the mandatory `Action` + `EvidenceGrade` and the
grade-3 opt-in gate).
