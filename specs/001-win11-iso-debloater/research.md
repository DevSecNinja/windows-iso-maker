# Phase 0 Research: Windows 11 ISO Builder & Debloater

This document resolves the unknowns and technology choices behind the plan. Each item
records the **Decision**, **Rationale**, and **Alternatives considered**.

---

## 1. ISO acquisition — pbatard/Fido integration

**Decision**: Vendor `Fido.ps1` from `pbatard/Fido` into `vendor/fido/` pinned to a
specific commit/tag (recorded in `vendor/fido/VERSION`), and invoke it as a **separate
child script** from `Get-Windows11Iso`, passing `-Win 11`, `-Ed`, `-Lang`, `-Rel`, `-Arch`
(and `-GetUrl` to resolve a URL for our own hash-verified download).

**Rationale**:
- Fido is the reference implementation for resolving official Microsoft download URLs
  without a Microsoft account, and is the source named in the spec (FR-001).
- Fido is **GPLv3**. Keeping it as a standalone, separately invoked `.ps1` (not
  dot-sourced/embedded into our MIT-style module) keeps the license boundary clean; our
  module calls it as an external tool. We preserve Fido's `LICENSE` alongside it and cite
  it in `docs/` and `NOTICE`.
- Pinning a commit satisfies reproducibility (Principle V) and supply-chain hygiene
  (Principle VII); "latest release" is a *Windows* release resolved by Fido at build time,
  not a Fido version bump.

**Alternatives considered**:
- *Fetch latest Fido at build time* — rejected: breaks pinning/determinism.
- *Reimplement Microsoft download URL resolution ourselves* — rejected: brittle,
  duplicates Fido's maintained logic, high maintenance cost.
- *Require the user to supply a pre-downloaded ISO* — rejected as the default: violates
  FR-001/FR-011 (single command). Retained as an **optional `-IsoPath` override** for
  offline/air-gapped use and to let CI cache an ISO.

---

## 2. Offline servicing — Dism module vs dism.exe

**Decision**: Prefer the `Dism` PowerShell module cmdlets (`Mount-WindowsImage`,
`Get-AppxProvisionedPackage`, `Remove-AppxProvisionedPackage`,
`Get-`/`Add-`/`Remove-WindowsCapability`, `Dismount-WindowsImage`,
`Get-WindowsImage`). Provide a thin `Invoke-Dism` private wrapper around `dism.exe` for
operations without reliable module parity, and to run integrity/cleanup ops
(`/Cleanup-Image /StartComponentCleanup`).

**Rationale**:
- The module gives object output, native `-WhatIf`/`ShouldProcess` friendliness, and
  testability via `Mock` (Principle III), aligning with Principle I.
- A validated `dism.exe` fallback covers gaps and PS 5.1/7 differences deterministically
  (see Complexity Tracking). Arguments are built as arrays (no string concatenation) to
  avoid injection (Principle VII).

**Alternatives considered**:
- *dism.exe only* — rejected: harder to mock/test, string-parsing output is fragile.
- *Module only* — rejected: coverage gaps for some capability/ESD/cleanup operations.

**Notes for cross-version**: `Mount-WindowsImage`/`Dismount-WindowsImage` require elevation
and are available on both Windows PowerShell 5.1 and PowerShell 7 (via the `Dism` module
shipped with Windows). `install.esd` may need conversion to `install.wim`
(`Export-WindowsImage`) before some operations; handled in `Expand-WindowsImage`/mount step.

---

## 3. Offline registry tweaks on a mounted image

**Decision**: After mounting the image, load its hives with `reg load` into temporary
mount keys (e.g. `HKLM\WIM_SOFTWARE`, `HKLM\WIM_SYSTEM`, and the default user hive
`NTUSER.DAT` as `HKLM\WIM_DEFAULT`), apply catalog registry entries via
`Set-`/`Remove-ItemProperty` (or `reg add`/`reg delete` through a validated wrapper),
then `reg unload`. Wrap load/unload in `Mount-`/`Dismount-OfflineRegistryHive` private
helpers with GC + retry on unload (a well-known handle-leak pitfall).

**Rationale**:
- Offline hive editing is the standard, supported way to preconfigure an image without
  booting it. Loading the *image's* hives (not the host's live hives) keeps changes scoped
  to the target (Principle VI) and never touches the host OS.
- The default-user hive (`NTUSER.DAT`) is required for per-user policies like Widgets;
  machine policies (Recall) live in `SOFTWARE`.

**Alternatives considered**:
- *Editing live host registry* — rejected outright: wrong scope, violates Principle VI.
- *Unattend.xml / provisioning packages only* — rejected as primary: less granular than
  documented per-key tweaks, harder to cite per change. May be revisited for some settings.

**Idempotency**: each tweak reads current value first; if already at target, it is recorded
as `AlreadyApplied`/skipped (FR-017). `-WhatIf` reports intended key/value without writing.

---

## 4. Recall & Widgets disable (default profile, FR-007)

**Decision**: Disable via documented, reversible registry/policy keys in
`catalog.registry.psd1` with `DefaultEnabled=true`:
- **Recall**: machine policy `DisableAIDataAnalysis` (per Microsoft's documented policy
  for turning off Recall snapshots). Cite Microsoft Learn.
- **Widgets**: policy `AllowNewsAndInterests` / taskbar `TaskbarDa`, disabling the
  weather/stock taskbar widget. Cite Microsoft Learn.

**Rationale**: FR-007 mandates both in the default profile. Both are reversible policy
tweaks (not component removal), so they satisfy Principle VI while being on by default; the
plan's Complexity Tracking records this as a spec-mandated, documented exception to
"impactful defaults OFF". Every key carries What/Why/Citation per Principle II.

**Alternatives considered**:
- *Removing the Recall/Widgets components* — rejected: heavier, less reversible; policy
  keys achieve the requirement conservatively.

---

## 5. Bootable ISO repackaging — oscdimg

**Decision**: Use `oscdimg.exe` from the Windows ADK **Deployment Tools** to author a
bootable UEFI ISO. Boot data by architecture:
- **amd64**: BIOS+UEFI El Torito with `boot/etfsboot.com` (BIOS) and
  `efi/microsoft/boot/efisys.bin` (UEFI), via `oscdimg -bootdata:2#...`.
- **arm64**: UEFI-only; ensure `efi/boot/bootaa64.efi` is present in media; author
  UEFI-only boot image.

`New-BootableIso` selects the boot arguments based on the validated `Arch`.

**Rationale**:
- `oscdimg` is the Microsoft-supported tool that produces correctly bootable Windows media
  with proper El Torito boot catalog and UDF filesystem. There is no reliable pure-PS
  alternative (Complexity Tracking).
- Getting boot data right per arch is the crux of FR-023 (bootable output).

**Alternatives considered**:
- *`Add-` third-party ISO libs / genisoimage / mkisofs* — rejected: inconsistent Windows
  UEFI boot support; unsupported for Windows install media.
- *PowerShell-only ISO creation (IMAPI2FS)* — rejected: does not reliably set the UEFI boot
  entries needed for Windows Setup media.

**ADK dependency**: documented in `docs/ci.md`. CI installs only the Deployment Tools
feature of a pinned ADK version. Local users install ADK once; `Test-BuildPrerequisite`
fails fast with an actionable message if `oscdimg` is not found.

---

## 6. Compression / artifact format

**Decision**: Compress the final `.iso` to a `.zip` by default using
`Compress-Archive` (built-in, cross-runner), with an optional `7z` path when available for
better ratio on large ISOs. `Compress-BuildArtifact` emits one archive per architecture,
named `Windows11-<edition>-<arch>-<release>.zip`.

**Rationale**: `Compress-Archive` needs no external dependency and works identically on both
runners and locally (Principle V). GitHub `upload-artifact` also re-zips, but pre-compressing
gives a single named deliverable and lets us hash it for the run report.

**Alternatives considered**:
- *7z only* — rejected as default: extra dependency; kept as optional.
- *Uploading raw ISO* — allowed but not default; large and slower to upload.

---

## 7. Image integrity validation (FR-023)

**Decision**: `Test-ImageIntegrity` performs **structural checks by default**:
1. ISO mounts / media tree is readable.
2. `sources/install.wim` or `install.esd` present; `Get-WindowsImage` index integrity OK.
3. Required boot files present per arch (`boot/bootmgr`, `efi/boot/bootx64.efi` for amd64 /
   `efi/boot/bootaa64.efi` for arm64, `efi/microsoft/boot/efisys.bin`,
   `sources/install.wim|.esd`).

An **optional, opt-in VM boot test** (`-BootTest`) is disabled by default (hosted runners
may lack nested virtualization); when enabled it boots the ISO in a VM and confirms Windows
Setup is reached.

**Rationale**: Directly implements the spec's resolution of the former FR-023
NEEDS CLARIFICATION — structural checks are the default gate; VM boot is opt-in. Structural
checks are fast, deterministic, and CI-friendly.

**Alternatives considered**:
- *Always VM-boot* — rejected as default: nested-virt not guaranteed on hosted runners.
- *No validation* — rejected: violates FR-023.

**Status**: Prior open NEEDS CLARIFICATION on FR-023 is **RESOLVED** (structural default +
opt-in VM boot), matching the spec's FR-023 final text.

---

## 8. CI architecture — two workflows

**Decision**:
- `ci.yml` — triggers on `push` and `pull_request`. Runs on `windows-latest`. Steps:
  install pinned Pester v5 + PSScriptAnalyzer, run PSScriptAnalyzer with
  `PSScriptAnalyzerSettings.psd1`, run Pester with NUnit output, publish results. No ISO
  work. Fast.
- `build-image.yml` — `workflow_dispatch` **only**. Matrix `arch: [amd64, arm64]` mapping
  `amd64 → windows-latest`, `arm64 → windows-11-arm`. Steps: install ADK Deployment Tools,
  run `build.ps1`/`Invoke-IsoBuild` (which invokes Fido → build → integrity →
  compress), `upload-artifact` per arch. A `skip_heavy_build` input allows a dry-run/preview
  path.

**Rationale**: Directly implements FR-012 (manual full build), FR-013 (tests on every
commit/PR), FR-004 (native arm64), FR-014 (skip heavy build), FR-015 (artifact per arch).
Splitting keeps PR feedback fast while isolating the heavy, privileged build.

**Alternatives considered**:
- *Single workflow with conditionals* — rejected: harder to keep PRs fast and to guarantee
  the full build never runs on ordinary commits.
- *Emulated arm64 on x64* — rejected: violates FR-004/Principle IV.

**Runner limits research**: `windows-latest` provides limited free disk (~14 GB usable) and
a 6 h job cap; base ISO + extraction + mount + output ISO approaches those limits, so the
build cleans intermediates and fails fast on insufficient disk. `windows-11-arm`
availability and pre-installed tooling (PowerShell, ADK availability) must be verified during
implementation; if ADK is unavailable there, document a scripted install or an alternative
boot-data source. Recorded as a risk in plan.md.

---

## 9. Local parity entry point

**Decision**: `build.ps1` at repo root: sets strict mode, checks admin/elevation via
`Test-IsAdministrator` (re-launch elevated or fail fast with guidance), imports the module,
and calls `Invoke-IsoBuild` with parameters/config — the exact path CI uses.

**Rationale**: FR-010/FR-011 and Principle V: one shipped build path, no CI-only logic.

**Alternatives considered**:
- *Separate local vs CI scripts* — rejected: risks divergence (Principle V violation).

---

## 10. Config schema & precedence

**Decision**: The config file is the **primary interface** for driving a build (stakeholder
expects many settings, so editing/supplying a config file is preferred over long parameter
lists). `Get-BuildConfiguration` loads `config/build.config.psd1` defaults
(edition=Pro, language=en-US, release=latest, arch, profile, opt-in flags, working dirs),
then overlays environment variables, then explicit parameters (params win, as optional
last-mile overrides only). A `-ConfigPath`/`Path` parameter (and `WIM_CONFIG_PATH`) selects an
alternate file, so users can keep multiple saved profiles (e.g. `build.pro.psd1`,
`build.arm64.psd1`). Values validated (`ValidateSet` for arch/edition; non-empty for
language/paths). Returns a single resolved config object recorded in the run report.

**Rationale**: FR-002 defaults + overridability; Principle V (config-driven, no magic
values); FR-022 (resolved config in report).

**Alternatives considered**:
- *JSON config* — viable; PSD1 chosen for native PowerShell typing and comments. Catalog
  files may be PSD1 for authoring ergonomics with a JSON Schema mirror for validation.

---

## 11. Data-driven change model & Action dispatcher (retire per-feature switches)

**Decision**: Every catalog entry declares an `Action`
(`RemoveAppx` | `RemoveCapability` | `SetRegistry` | `EnableOptionalFeature` | `AddCapability`,
extensible). A single private dispatcher `Invoke-CatalogEntry` routes each entry to its handler
keyed by `Action` (`Remove-Bloatware`, `Set-RegistryTweaks`, `Enable-WindowsFeature`). Change
selection is purely data-driven: `Profile` (`minimal`/`default`/`aggressive`) baseline, then a
`Toggles` map (`Id -> bool`), then explicit `EnableCatalogId`/`DisableCatalogId` lists. Adding a
feature = adding a catalog entry (zero new code, SC-011); adding a *category* = one new
dispatcher branch.

**Migration**: the dedicated `RemoveEdge`/`RemoveOneDrive` boolean parameters (and the
`WIM_REMOVE_EDGE`/`WIM_REMOVE_ONEDRIVE` env vars, and `remove_edge`/`remove_onedrive` workflow
inputs) are **removed**. Edge and OneDrive removal are now ordinary opt-in catalog entries
(`remove-edge`, `remove-onedrive`, `DefaultEnabled=false`) enabled via `EnableCatalogId` or
`Toggles`. This removes switch proliferation while preserving FR-008 (opt-in, OFF by default).

**Rationale**: FR-024 and constitution v1.1.0 Principle II explicitly reject per-feature
parameter proliferation; a data-driven catalog with an Action dispatcher keeps code paths
stable as the catalog grows.

**Alternatives considered**:
- *Keep one switch per feature* — rejected: violates FR-024/Principle II; unbounded surface.
- *`if/switch` on `Type` inside each pipeline function* — rejected: couples new Action types to
  pipeline edits; the dispatcher isolates that to one branch.

---

## 12. Additive actions & WSL via optional features

**Decision**: Support additive actions through the same dispatcher. `Enable-WindowsFeature`
handles `EnableOptionalFeature`/`AddCapability` using `Enable-WindowsOptionalFeature -Path
<mount>` (and `Add-WindowsCapability -Path <mount>`). WSL ships as an opt-in catalog entry
(`feature-wsl` → `Microsoft-Windows-Subsystem-Linux`) plus its dependency
(`feature-vmplatform` → `VirtualMachinePlatform`), both `DefaultEnabled=false`.

**WSL online-first-boot caveat**: enabling the platform features offline only pre-enables WSL;
the WSL **kernel** and any **Linux distribution** are downloaded online on first boot — an
inherent Windows platform constraint. The catalog entry's Rationale/Reversal documents this so
users are not surprised that an offline image cannot fully provision a distro.

**Rationale**: FR-025 requires additive/enable actions to be first-class and WSL enablement to
be catalog-driven and opt-in.

**Alternatives considered**:
- *Bundle a distro into the image* — rejected: large, licensing/versioning burden, and not the
  supported WSL provisioning path.
- *A dedicated `-EnableWsl` switch* — rejected: FR-024 (no per-feature switches).

---

## 13. Autounattend.xml generation (per architecture)

**Decision**: `New-AutounattendXml` renders `Autounattend.xml` from the build config, **per
architecture** (correct `processorArchitecture`: `amd64` vs `arm64`), from templates under
`templates/autounattend/`. Toggles: skip OOBE, bypass MS-account + create a local account
(default ON, toggleable), locale/keyboard/timezone, disk layout, and FirstLogon/SetupComplete
commands. `New-BootableIso` places the generated file at the ISO root. This is complementary to
— not a replacement for — DISM offline (image-time) servicing.

**Rationale**: FR-027. OOBE/install-time behavior (account model, locale, disk) cannot be set by
offline servicing alone; a config-driven, per-arch `Autounattend.xml` covers install-time
settings from the same single source of truth. No password/secret is stored in the repo or
logs (Principle VII); a first-boot password flow is used where a credential is required.

**Alternatives considered**:
- *Hand-authored static XML per arch* — rejected: drifts from config, duplicates values, easy to
  desync amd64/arm64.
- *Provisioning packages (PPKG) only* — rejected as primary: less transparent than a cited,
  templated unattend for OOBE bypass; may complement later.

---

## 14. Provenance & integrity (SLSA + checksums)

**Decision**: `New-BootableIso`/the pipeline emit a `SHA256SUMS` manifest for each produced
ISO. In CI, `build-image.yml` adds SLSA build provenance via `actions/attest-build-provenance`
(SHA-pinned) and attests each ISO. Consumers verify with `gh attestation verify` and by checking
`SHA256SUMS`.

**Rationale**: FR-028 and constitution v1.1.0 Principle VII (Supply-Chain Integrity &
Provenance) — consumers must be able to independently verify authenticity + integrity (SC-009).

**Alternatives considered**:
- *Checksums only, no provenance* — rejected: does not prove who/what built the artifact.
- *Third-party signing infra* — rejected as default: GitHub Artifact Attestations provide SLSA
  provenance natively with OIDC, no key management.

---

## 15. SBOM & Image BOM

**Decision**: Two BOMs (FR-029). (a) A repository/tooling **SBOM** (CycloneDX) generated in CI
by `anchore/sbom-action` (SHA-pinned). (b) An **Image BOM** produced by `Export-ImageBom`
(CycloneDX JSON + human-readable Markdown) **derived from the RunReport**: base image
version + hash, pinned Fido tag/commit and ADK version, and every applied change with its
`Citation` + `EvidenceGrade`.

**Rationale**: FR-029/Principle VII. Deriving the Image BOM from the RunReport (single source of
truth) guarantees it lists 100% of changes actually applied (SC-012), not an aspirational list.

**Alternatives considered**:
- *Recompute the applied set independently for the BOM* — rejected: risks divergence from what
  was actually applied.
- *SPDX* — viable; CycloneDX chosen for tooling fit (`anchore/sbom-action`, CycloneDX libs) and
  because the constitution names CycloneDX.

---

## 16. Optional Azure Blob upload (OIDC)

**Decision**: `build-image.yml` gains an optional publish path: when `vars.AZURE_STORAGE_ACCOUNT`
+ `vars.AZURE_STORAGE_CONTAINER` are set, authenticate via OIDC `azure/login` (repo vars
`AZURE_CLIENT_ID`/`AZURE_TENANT_ID`/`AZURE_SUBSCRIPTION_ID`, **no stored secrets**) and
`az storage blob upload` the compressed image + `SHA256SUMS` + BOM. When not configured, fall
back to `actions/upload-artifact` (FR-015).

**Rationale**: FR-030. A produced ISO (~5–7 GB) can strain GitHub artifact per-file/total size
limits and retention caps, so an optional durable Azure target is offered; OIDC federation keeps
it secretless. It remains fully optional so the default experience needs no Azure account.

**Alternatives considered**:
- *Stored storage keys/SAS as secrets* — rejected: violates secret hygiene (Principle VII); OIDC
  federation avoids stored credentials.
- *Always upload to Azure* — rejected: forces an Azure dependency; artifact fallback keeps the
  default zero-config.

---

## 17. Renovate dependency updates

**Decision**: Dependency updates use `renovate.json5` (JSON5, already added), mirroring the
DevSecNinja/repo-starter convention: it extends `config:recommended`,
`helpers:pinGitHubActionDigests`, and the shared `github>DevSecNinja/.github//.renovate/*`
presets (autoMerge, base, customManagers, groups, labels, packageRules, semanticCommits), plus a
repo-local `customManager` (regex) that tracks the pinned pbatard/Fido tag in
`vendor/fido/VERSION` via the `github-releases` datasource. All GitHub Actions MUST be
SHA-pinned; Renovate keeps the digests current.

**Rationale**: FR-031/Principle VII — dependencies (incl. vendored Fido and SHA-pinned Actions)
must be kept current via an automated mechanism.

**Alternatives considered**:
- *Dependabot* — viable; Renovate chosen for JSON5 support, shared presets already used across
  DevSecNinja repos, and its custom-manager regex for the vendored Fido tag.
- *Manual updates* — rejected: not sustainable, drifts from pinned/current requirement.

---

## Open items carried into design

- Verify `oscdimg`/PowerShell/ADK availability on `windows-11-arm` runner (implementation
  spike) — tracked as a risk; does not block design.
- Exact pinned Fido commit and ADK version to be recorded in `vendor/fido/VERSION` and
  `docs/ci.md` during implementation.

All spec NEEDS CLARIFICATION items (FR-023 validation method) are **resolved**.
