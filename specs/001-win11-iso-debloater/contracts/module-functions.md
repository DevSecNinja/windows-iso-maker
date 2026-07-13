# Contract: WindowsIsoMaker Module Public Functions

This is the public interface contract for the `WindowsIsoMaker` module. Every function
below MUST: use an approved verb + PascalCase, declare `[CmdletBinding()]` (with
`SupportsShouldProcess` where it mutates state), carry comment-based help, use typed +
validated parameters, run under `Set-StrictMode -Version Latest`, use no aliases, and
`throw` terminating errors on unrecoverable failure (Constitution Principle I).

Legend: **[Mutating]** = supports `-WhatIf`/`-Confirm` and is idempotent.

---

## `Get-BuildConfiguration`

Load and resolve the effective build configuration.

| Parameter | Type | Validation | Default |
|-----------|------|-----------|---------|
| `Path` | string | file exists | `config/build.config.psd1` |
| `Edition` | string | non-empty | (from file) |
| `Language` | string | non-empty | (from file) |
| `Release` | string | non-empty | (from file) |
| `Architecture` | string | `ValidateSet('amd64','arm64')` | (from file) |
| `Profile` | string | `ValidateSet('minimal','default','aggressive')` | `default` |
| `EnableCatalogId` | string[] | ids exist in catalog | `@()` |
| `DisableCatalogId` | string[] | ids exist in catalog | `@()` |

- **Precedence**: file defaults ← environment variables ← explicit parameters (params win).
  The config file is the **primary interface**; parameters exist only as optional last-mile
  overrides. `Path` (aliased `-ConfigPath`) may point at an alternate config file so users can
  keep multiple saved profiles (e.g. `config/build.pro.psd1`, `config/build.arm64.psd1`).
- **No per-feature switches** (FR-024): there is no `RemoveEdge`/`RemoveOneDrive`/`EnableWsl`
  parameter. Change selection is data-driven — `Profile` baseline, then the config `Toggles`
  map, then `EnableCatalogId`/`DisableCatalogId` (explicit ids win). Edge/OneDrive/WSL are
  ordinary opt-in catalog entries.
- **Returns**: a `BuildConfiguration` object (see data-model), including the resolved effective
  enabled catalog-id set and the `Autounattend` sub-config.
- **Throws**: on invalid/unknown values, unknown catalog ids, or unreadable config.
- **Contract tests**: precedence order; validation rejects bad arch/edition/profile; env
  override; unknown catalog id in Toggles/Enable/Disable → terminating error.

---

## `Get-Windows11Iso`

Wrapper over a pinned, runtime-fetched Fido to resolve and download the base ISO.

| Parameter | Type | Validation | Default |
|-----------|------|-----------|---------|
| `Edition` | string | non-empty | `Pro` |
| `Language` | string | non-empty | `en-US` |
| `Release` | string | non-empty | `latest` |
| `Architecture` | string | `ValidateSet('amd64','arm64')` | required |
| `OutputPath` | string | writable dir | working dir |
| `IsoPath` | string | path exists | — (override: skip download) |
| `FidoPath` | string | file exists when set | `''` (empty = download pinned Fido) |

- **[Mutating]** downloads to disk (network + FS side effects).
- **Returns**: `BaseImage` object with resolved `Release`, `Path`, `Sha256`, `Verified`.
- **Behavior**: invokes Fido as a separate script (GPLv3 boundary). If `IsoPath` supplied,
  validates and uses it instead of downloading. Computes/records hash. Fails fast if the
  requested edition/language/release/arch is unavailable (edge case in spec).
- **Security**: builds Fido args as an array (no string injection); treats output as
  untrusted until integrity-checked (Principle VII).
- **Contract tests**: arg mapping to Fido (mocked); `IsoPath` override path; unavailable
  combo → terminating error.

---

## `Expand-WindowsImage`

Extract ISO media contents to a working directory (and, if needed, convert `install.esd`
handling for servicing).

| Parameter | Type | Validation |
|-----------|------|-----------|
| `IsoPath` | string | file exists |
| `Destination` | string | writable dir |

- **[Mutating]** writes extracted media tree.
- **Returns**: media root path + located `install.wim`/`.esd` path.
- **Contract tests**: locates `sources/install.*`; fails on missing sources.

---

## `Mount-WindowsBuildImage`

Mount a specific image index for offline servicing.

| Parameter | Type | Validation |
|-----------|------|-----------|
| `ImagePath` | string | file exists |
| `Index` | int | > 0 |
| `MountPath` | string | writable dir |
| `Edition` | string | — (resolve index by edition when Index not given) |

- **[Mutating]** mounts the image (DISM).
- **Returns**: `MountedImage` object.
- **Behavior**: resolves the correct index for the requested edition; guards cleanup.
- **Contract tests**: index resolution by edition (mocked `Get-WindowsImage`); mount failure
  → terminating error + no partial state.

---

## `Invoke-CatalogEntry`

Data-driven dispatcher (FR-024/FR-025): routes a single `ChangeCatalogEntry` to the correct
handler keyed by its `Action`, so adding a feature is a catalog edit and adding a new
*category* is one new dispatcher branch — never a new pipeline parameter/switch.

| Parameter | Type | Validation |
|-----------|------|-----------|
| `Entry` | object | valid `ChangeCatalogEntry` |
| `MountPath` | string | dir exists |
| `Architecture` | string | `ValidateSet('amd64','arm64')` |
| `Config` | BuildConfiguration | — |

- **[Mutating]** applies the entry's effect to the mounted image.
- **Action routing**: `RemoveAppx`/`RemoveCapability` → `Remove-Bloatware` handler;
  `SetRegistry` → `Set-RegistryTweaks` handler; `EnableOptionalFeature`/`AddCapability` →
  `Enable-WindowsFeature` handler. Unknown `Action` → terminating error.
- **Returns**: a `ChangeResult` (Applied/AlreadyApplied/NotApplicable/Skipped/Failed).
- **Behavior**: honors arch filtering (FR-021), idempotency (FR-017), and `-WhatIf` (FR-016)
  uniformly for every Action.
- **Contract tests**: each Action routes to its handler (mocked); unknown Action throws;
  arch/idempotency/`-WhatIf` behavior is Action-agnostic.

---

## `Remove-Bloatware`

Appx/Capability **removal handler** invoked by `Invoke-CatalogEntry` for
`Action=RemoveAppx`/`RemoveCapability` (also callable directly over a filtered catalog).

| Parameter | Type | Validation |
|-----------|------|-----------|
| `MountPath` | string | dir exists |
| `Catalog` | object[] | entries |
| `Architecture` | string | `ValidateSet('amd64','arm64')` |
| `Config` | BuildConfiguration | — |

- **[Mutating]** removes provisioned appx/capabilities via DISM.
- **Returns**: `ChangeResult[]` (Applied/AlreadyApplied/NotApplicable/Skipped/Failed).
- **Behavior**: only entries applicable to `Architecture` and enabled by profile/flags;
  entries not present in the image are recorded `NotApplicable`, not failed (FR-021);
  idempotent (FR-017); `-WhatIf` reports without removing (FR-016).
- **Contract tests**: mocked `Get-`/`Remove-AppxProvisionedPackage`; not-applicable skip;
  idempotency; `-WhatIf` no-op; arch filtering.

---

## `Set-RegistryTweaks`

Apply registry-tweak catalog entries to the mounted image's offline hives.

| Parameter | Type | Validation |
|-----------|------|-----------|
| `MountPath` | string | dir exists |
| `Catalog` | object[] | registry entries |
| `Architecture` | string | `ValidateSet('amd64','arm64')` |
| `Config` | BuildConfiguration | — |

- **[Mutating]** loads offline hives, sets/deletes values, unloads hives.
- **Returns**: `ChangeResult[]`.
- **Behavior**: loads `SOFTWARE`/`SYSTEM`/`DEFAULT` hives from the mounted image, applies
  entries (including Recall + Widgets in default profile), unloads with retry; idempotent
  (reads current value, marks `AlreadyApplied`); `-WhatIf` reports intended keys only.
- **Contract tests**: mocked hive load/unload + `Set-ItemProperty`; idempotency; `-WhatIf`;
  ensures hives always unloaded even on failure.

---

## `Enable-WindowsFeature`

Additive handler invoked by `Invoke-CatalogEntry` for
`Action=EnableOptionalFeature`/`AddCapability` (FR-025). Enables Windows optional features and
adds capabilities on the mounted image — e.g. WSL (`Microsoft-Windows-Subsystem-Linux` +
`VirtualMachinePlatform`).

| Parameter | Type | Validation |
|-----------|------|-----------|
| `MountPath` | string | dir exists |
| `Catalog` | object[] | feature/capability entries |
| `Architecture` | string | `ValidateSet('amd64','arm64')` |
| `Config` | BuildConfiguration | — |

- **[Mutating]** enables optional features / adds capabilities via
  `Enable-WindowsOptionalFeature -Path <mount>` (and `Add-WindowsCapability -Path <mount>`).
- **Returns**: `ChangeResult[]`.
- **Behavior**: WSL ships opt-in (`DefaultEnabled=false`); the offline image only
  pre-enables the platform features — the WSL kernel and Linux distribution are downloaded
  online on first boot (a Windows platform constraint), which is documented in the catalog
  entry's Rationale/Reversal. Already-enabled features are recorded `AlreadyApplied`
  (idempotent); features not applicable to the arch are `NotApplicable` (FR-021); `-WhatIf`
  reports intended features only.
- **Contract tests**: mocked `Enable-WindowsOptionalFeature`/`Add-WindowsCapability`;
  idempotency; `-WhatIf` no-op; arch filtering; WSL entry is opt-in.

---

## `New-AutounattendXml`

Render an `Autounattend.xml` from the build configuration, **per architecture** (FR-027),
from a template under `templates/autounattend/`.

| Parameter | Type | Validation |
|-----------|------|-----------|
| `Config` | BuildConfiguration | — |
| `Architecture` | string | `ValidateSet('amd64','arm64')` |
| `OutputPath` | string | writable path |
| `TemplatePath` | string | dir exists = `templates/autounattend/` |

- **[Mutating]** writes an `Autounattend.xml` (idempotent — same config yields same file).
- **Returns**: path to the generated `Autounattend.xml`.
- **Behavior**: writes the correct `processorArchitecture` (`amd64` vs `arm64`) into every
  unattend component; applies the `Autounattend` sub-config — skip OOBE, bypass MS-account +
  create local account (default on), locale/keyboard/timezone, disk layout, FirstLogon and
  SetupComplete commands. Placed at the ISO root by `New-BootableIso`. Complementary to — not
  a replacement for — DISM offline servicing. No secret/password is written to the file or logs.
- **Contract tests**: `processorArchitecture` differs amd64 vs arm64; MS-account-bypass +
  local-account default on and toggleable; OOBE-skip present; template-driven rendering.

Repackage the serviced media into a bootable UEFI ISO using `oscdimg`, with arch-correct
boot data.

| Parameter | Type | Validation |
|-----------|------|-----------|
| `MediaRoot` | string | dir exists |
| `Architecture` | string | `ValidateSet('amd64','arm64')` |
| `OutputIsoPath` | string | writable path |
| `OscdimgPath` | string | file exists (from ADK) |
| `AutounattendPath` | string | file exists (from `New-AutounattendXml`) |

- **[Mutating]** writes a bootable `.iso` and a `SHA256SUMS` manifest beside it.
- **Returns**: path to the built ISO (and the `SHA256SUMS` path).
- **Behavior**: places the generated `Autounattend.xml` at the ISO root (FR-027); amd64 →
  BIOS+UEFI boot data (`etfsboot.com` + `efisys.bin`); arm64 → UEFI-only (`bootaa64.efi`).
  Emits SHA256 checksums for the produced ISO into `SHA256SUMS` (FR-028). Fails fast if
  `oscdimg` missing.
- **Contract tests**: arch → boot-arg selection (mocked `oscdimg` invocation); `Autounattend.xml`
  placed at root; `SHA256SUMS` written; missing oscdimg → actionable terminating error.

---

## `Compress-BuildArtifact`

Compress the final ISO into a named archive artifact.

| Parameter | Type | Validation |
|-----------|------|-----------|
| `IsoPath` | string | file exists |
| `OutputDirectory` | string | writable dir |
| `Format` | string | `ValidateSet('zip','7z')` = `zip` |

- **[Mutating]** writes archive.
- **Returns**: `OutputImageArtifact` (archive path, sha256, size).
- **Contract tests**: names archive `Windows11-<edition>-<arch>-<release>.<ext>`; computes
  hash.

---

## `Test-ImageIntegrity`

Validate the produced image structurally (default) with optional VM boot test.

| Parameter | Type | Validation |
|-----------|------|-----------|
| `IsoPath` | string | file exists |
| `Architecture` | string | `ValidateSet('amd64','arm64')` |
| `BootTest` | switch | — (opt-in) |

- **Returns**: an integrity result object (`Structural` checks pass/fail per item; optional
  `Boot` result).
- **Behavior (default)**: verify media tree readable, `sources/install.wim|.esd` present +
  DISM index integrity, required boot files present per arch. `-BootTest` boots in a VM and
  confirms Windows Setup is reached (disabled by default; FR-023).
- **Contract tests**: missing boot file → fail; arch-specific boot file selection;
  `BootTest` off by default.

---

## `Export-ImageBom`

Derive an **Image BOM** from the RunReport (FR-029): CycloneDX JSON + a human-readable
Markdown enumerating every applied change (with its `Citation` + `EvidenceGrade`), the base
image version + hash, and the pinned tool versions (Fido, ADK, PowerShell/Pester/PSSA).

| Parameter | Type | Validation |
|-----------|------|-----------|
| `RunReport` | RunReport | — |
| `OutputDirectory` | string | writable dir |
| `Format` | string[] | `ValidateSet('cyclonedx','markdown')` = both |

- **[Mutating]** writes the BOM file(s).
- **Returns**: an `SBOM/ImageBOM` object (paths + summary).
- **Behavior**: reads solely from the RunReport (single source of truth) so the BOM lists
  100% of the changes actually applied (SC-012). The repository/tooling SBOM (CycloneDX) is
  produced separately in CI by `anchore/sbom-action` (see workflows contract).
- **Contract tests**: BOM enumerates every `Applied` change with citation + grade; includes
  base image version/hash and pinned tool versions; both output formats produced.

---

## `Invoke-IsoBuild`

Orchestrator that runs the full pipeline; the single shared entry for local and CI
(Principle V, FR-010).

| Parameter | Type | Validation |
|-----------|------|-----------|
| `Config` | BuildConfiguration | — (or build from below) |
| `ConfigPath` | string | file exists |
| `Architecture` | string | `ValidateSet('amd64','arm64')` |
| `SkipHeavyBuild` | switch | — (preview/CI-light path, FR-014) |
| `BootTest` | switch | — |

- **[Mutating]** runs the whole build.
- **Returns**: `RunReport`.
- **Behavior/order**: `Test-BuildPrerequisite` (admin, tooling, disk — fail fast, FR-019)
  → `Get-Windows11Iso` → integrity (FR-020) → `Expand-WindowsImage` →
  `Mount-WindowsBuildImage` → for each selected catalog entry `Invoke-CatalogEntry`
  (dispatches RemoveAppx/RemoveCapability/SetRegistry/EnableOptionalFeature/AddCapability) →
  dismount `-Save` → `New-AutounattendXml` (per-arch) → `New-BootableIso` (places
  `Autounattend.xml` at root + emits `SHA256SUMS`) → `Compress-BuildArtifact` →
  `Test-ImageIntegrity` → `New-RunReport` → `Export-ImageBom` (from the RunReport). On any
  failure: cleanup (dismount `-Discard`, unload hives), emit a clear terminating error, never
  present corrupt output as success (FR-005). `-WhatIf` produces a preview RunReport with no
  media changes (FR-016). Idempotent (FR-017).
- **Contract tests**: preconditions gate (mocked); preview path modifies nothing; failure
  mid-build triggers cleanup; `SkipHeavyBuild` runs preview-only; dispatcher applies each
  selected entry once.

---

## Private helpers (not exported; behavior contracts)

- `Test-IsAdministrator` → bool; used to fail fast / re-elevate.
- `Test-BuildPrerequisite` → throws with actionable message if admin/DISM/oscdimg/disk
  requirements unmet (FR-019).
- `Mount-OfflineRegistryHive` / `Dismount-OfflineRegistryHive` → load/unload with GC+retry;
  unload guaranteed in `finally`.
- `Invoke-Dism` → validated array-arg wrapper over `dism.exe` (no string injection).
- `Write-BuildLog` → structured log lines (no secrets, Principle VII).
- `New-RunReport` → assemble/serialize the `RunReport` (FR-022), including `ToolVersions`,
  resolved `Autounattend`, and the applied-change list consumed by `Export-ImageBom`.
- `Resolve-CatalogSelection` → compute the effective enabled catalog-id set from
  `Profile` + `Toggles` + `EnableCatalogId`/`DisableCatalogId` (FR-024).
