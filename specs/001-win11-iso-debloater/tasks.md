---
description: "Actionable, dependency-ordered task list for Windows 11 ISO Builder & Debloater"
---

# Tasks: Windows 11 ISO Builder & Debloater

**Input**: Design documents from `/specs/001-win11-iso-debloater/`

**Prerequisites**: [plan.md](./plan.md) (required), [spec.md](./spec.md) (required),
[research.md](./research.md), [data-model.md](./data-model.md),
[contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: Test tasks are INCLUDED. The spec (Principle III / US3) mandates Pester v5 +
PSScriptAnalyzer and test-first for new public functions and the change-catalog schema.

**Organization**: Tasks are grouped by user story to enable independent implementation and
testing. All paths are repository-root relative per the plan's single-project layout.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: Which user story the task belongs to (US1–US5); Setup/Foundational/Polish
  tasks carry no story label
- Every task includes an exact file path

## Path Conventions

- Module: `src/WindowsIsoMaker/` (`Public/`, `Private/`, `WindowsIsoMaker.psd1/.psm1`)
- Config/catalog data: `config/`
- Tests: `tests/` (Pester v5)
- Docs: `docs/`; Vendored Fido: `vendor/fido/`; Workflows: `.github/workflows/`
- Root entry: `build.ps1`; Lint config: `PSScriptAnalyzerSettings.psd1`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project skeleton, module scaffold, lint/test scaffolding, vendored tooling, and
the local entry point — everything the rest of the work loads or is analyzed by.

- [ ] T001 Create the repository directory structure per plan (`src/WindowsIsoMaker/Public/`,
  `src/WindowsIsoMaker/Private/`, `config/`, `templates/autounattend/`, `tests/`, `docs/`,
  `vendor/fido/`, `.github/workflows/`)
- [ ] T002 [P] Create the pinned module manifest `src/WindowsIsoMaker/WindowsIsoMaker.psd1`
  (fixed `ModuleVersion`, `PowerShellVersion` floor, `RootModule = 'WindowsIsoMaker.psm1'`,
  and `FunctionsToExport` listing all 14 public functions — `Get-BuildConfiguration`,
  `Get-Windows11Iso`, `Expand-WindowsImage`, `Mount-WindowsBuildImage`, `Invoke-CatalogEntry`,
  `Remove-Bloatware`, `Set-RegistryTweaks`, `Enable-WindowsFeature`, `New-AutounattendXml`,
  `New-BootableIso`, `Compress-BuildArtifact`, `Test-ImageIntegrity`, `Export-ImageBom`,
  `Invoke-IsoBuild`; pin `RequiredModules`/documented minimums for Pester v5 + PSScriptAnalyzer)
- [ ] T003 [P] Create the module loader `src/WindowsIsoMaker/WindowsIsoMaker.psm1` that sets
  `Set-StrictMode -Version Latest`, dot-sources every `Private/*.ps1` then `Public/*.ps1`,
  and exports only the public functions
- [ ] T004 [P] Create `PSScriptAnalyzerSettings.psd1` at repo root (enable default rule set,
  disallow aliases/positional-heavy calls, require approved verbs; used by both local runs
  and `ci.yml`)
- [ ] T005 [P] Vendor pinned Fido under `vendor/fido/`: add `Fido.ps1` (record the pinned
  upstream commit), `LICENSE` (GPLv3 preserved), and `VERSION` (pinned commit/tag +
  upstream URL) per plan's GPLv3 isolation boundary
- [ ] T006 [P] Create the root entry script `build.ps1` (thin dispatcher: `Set-StrictMode`,
  import `src/WindowsIsoMaker`, run the admin/elevation check, accept a `-ConfigPath`
  parameter (default `config/build.config.psd1`) as the primary way to drive a build, forward
  it plus any optional override parameters to `Invoke-IsoBuild`; no build logic inline per
  Principle I/V)
- [ ] T007 [P] Create the Pester v5 test bootstrap `tests/PesterConfiguration.ps1` (v5
  `New-PesterConfiguration`, NUnit output path, discovery of `tests/*.Tests.ps1`) plus
  `tests/README.md` describing how to run tests locally

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared private helpers, the data-driven change-catalog (schema v2 with
`Action` + `EvidenceGrade`), the catalog-selection resolver, and the v2 configuration loader
that EVERY user story depends on.

**⚠️ CRITICAL**: No user-story phase can begin until this phase is complete.

- [ ] T008 [P] Implement structured logging helper
  `src/WindowsIsoMaker/Private/Write-BuildLog.ps1` (`[CmdletBinding()]`, level + message,
  no secrets per Principle VII, comment-based help)
- [ ] T009 [P] Implement admin/elevation check
  `src/WindowsIsoMaker/Private/Test-IsAdministrator.ps1` (returns bool; used to fail fast /
  re-elevate)
- [ ] T010 [P] Implement DISM fallback wrapper
  `src/WindowsIsoMaker/Private/Invoke-Dism.ps1` (validated array-arg `dism.exe` invocation,
  no string-built shell injection; used where `Dism` module coverage is incomplete)
- [ ] T011 [P] Implement offline hive load helper
  `src/WindowsIsoMaker/Private/Mount-OfflineRegistryHive.ps1` (`reg load` into a scoped temp
  mount, returns mount key handle)
- [ ] T012 [P] Implement offline hive unload helper
  `src/WindowsIsoMaker/Private/Dismount-OfflineRegistryHive.ps1` (`reg unload` with GC +
  retry; unload guaranteed by callers in `finally`)
- [ ] T013 [P] Implement run-report writer
  `src/WindowsIsoMaker/Private/New-RunReport.ps1` (assemble/serialize the `RunReport` object:
  `ResolvedConfig`, `BaseImage`, `Applied[]`, `Skipped[]`, `Artifact`, `Integrity`,
  `ToolVersions`, resolved `Autounattend`, `Bom`, optional `Provenance`, `Outcome`) per
  data-model — FR-022/FR-027/FR-028/FR-029
- [ ] T014 Implement preconditions gate
  `src/WindowsIsoMaker/Private/Test-BuildPrerequisite.ps1` (admin rights, `dism`/`oscdimg`
  tooling, free disk space, valid config; throws actionable errors — FR-019). Depends on
  T009, T010
- [ ] T015 [P] Implement catalog-selection resolver
  `src/WindowsIsoMaker/Private/Resolve-CatalogSelection.ps1` (compute the effective enabled
  catalog-id set from `Profile` baseline → config `Toggles` (`Id→bool`) →
  `EnableCatalogId`/`DisableCatalogId`, explicit ids win; unknown id → terminating error;
  returns the filtered `ChangeCatalogEntry[]`) — FR-024
- [ ] T016 [P] Write resolver tests FIRST in `tests/Resolve-CatalogSelection.Tests.ps1`
  (profile baseline selects `DefaultEnabled=$true` entries; `Toggles` override on/off;
  `EnableCatalogId` opt-in (e.g. `remove-edge`, `feature-wsl`); `DisableCatalogId` removal;
  explicit ids win over profile/toggles; unknown id → terminating error) — FR-024/SC-011
- [ ] T017 Write change-catalog **schema v2** tests FIRST in `tests/Catalog.Schema.Tests.ps1`:
  assert every entry across all catalog files has a non-empty `Action`
  (`RemoveAppx`/`RemoveCapability`/`SetRegistry`/`EnableOptionalFeature`/`AddCapability`), an
  `EvidenceGrade` (`1`/`2`/`3`), non-empty `Description`, `Rationale`, and a `Citation` (URL
  or explicit `Unverified`); every `EvidenceGrade=3` (or `Unverified`) entry has
  `DefaultEnabled=$false`; unique `Id`; non-empty `Arch` subset of `{amd64,arm64}`;
  `SetRegistry` `Target` shape (Hive/Path/Name/Kind/Value) — validate against
  [contracts/change-catalog.schema.json](./contracts/change-catalog.schema.json)
  (FR-009/FR-026, SC-004/SC-010)
- [ ] T018 [P] Create provisioned-appx removal catalog `config/catalog.appx.psd1` (default
  bloatware — Clipchamp, Bing News/Weather, Solitaire, Xbox extras, consumer Teams,
  King/Candy-Crush titles — each with `Action=RemoveAppx`, `EvidenceGrade` (1–2),
  `Description`/`Rationale`/`Citation`, `DefaultEnabled=$true`, `Reversible`, `Arch`) — FR-006
- [ ] T019 [P] Create Windows-capability/optional-feature catalog
  `config/catalog.capabilities.psd1` (arch-scoped capability entries with
  `Action=RemoveCapability`, each with What/Why/Citation + `EvidenceGrade`; PLUS the opt-in
  **WSL** entries `feature-wsl` (`Action=EnableOptionalFeature`,
  `Target='Microsoft-Windows-Subsystem-Linux'`) and `feature-vmplatform`
  (`Target='VirtualMachinePlatform'`), both `DefaultEnabled=$false`, cited + graded, with a
  Rationale/Reversal note that the WSL kernel + distro install online on first boot) —
  FR-021/FR-025
- [ ] T020 [P] Create registry-tweak catalog `config/catalog.registry.psd1` (every entry
  `Action=SetRegistry` + `EvidenceGrade`) including `reg-disable-recall` (Recall) and
  `reg-disable-widgets` (Widgets) as `DefaultEnabled=$true` reversible grade-1 tweaks, plus
  cited privacy/telemetry safe tweaks — each with What/Why/Citation and full `Target`
  (Hive/Path/Name/Kind/Value) — FR-007
- [ ] T021 [P] Create the default build config **v2** `config/build.config.psd1`
  (Edition=`Pro`, Language=`en-US`, Release=`latest`, Architecture=`amd64`, `Profile='default'`,
  `Toggles=@{}`, `EnableCatalogId=@()`, `DisableCatalogId=@()`, an `Autounattend` block
  (SkipOobe/BypassMsAccount/CreateLocalAccount/locale/keyboard/timezone/disk/FirstLogon/
  SetupComplete), an `AzureUpload=$null` block, working/output dirs, `CompressionFormat`,
  pinned `FidoPath`/`OscdimgPath`) — **no `RemoveEdge`/`RemoveOneDrive` fields** — per
  [contracts/build-config.schema.md](./contracts/build-config.schema.md) — FR-024/FR-027/FR-030
- [ ] T022 Write config loader **v2** tests FIRST in `tests/Get-BuildConfiguration.Tests.ps1`
  (config file is the primary interface; precedence: file defaults ← `WIM_*` env vars ←
  explicit params; `-ConfigPath`/`WIM_CONFIG_PATH` loads an alternate config file; a second
  saved profile file resolves independently; `Profile`/`Toggles`/`EnableCatalogId`/
  `DisableCatalogId` resolve the effective set via `Resolve-CatalogSelection`; `Autounattend`
  + `AzureUpload` sub-configs parsed; validation rejects bad arch/edition/profile and unknown
  catalog ids; `WIM_PROFILE`/`WIM_ENABLE_CATALOG_ID`/`WIM_AZURE_*` env overrides applied; **no
  `RemoveEdge`/`RemoveOneDrive` parameters exist**). Depends on T016
- [ ] T023 Implement `src/WindowsIsoMaker/Public/Get-BuildConfiguration.ps1` (config file is
  the primary interface: load `config/build.config.psd1` by default or an alternate file via
  `-Path`/`-ConfigPath` (alias) or `WIM_CONFIG_PATH`; parameters
  `Profile`/`EnableCatalogId`/`DisableCatalogId` (no per-feature switches); apply `WIM_*` env
  overrides then explicit params; call `Resolve-CatalogSelection` to attach the effective
  enabled catalog-id set + resolved `Autounattend`/`AzureUpload`; validate; return a
  `BuildConfiguration` object). Depends on T015, T021, T022

**Checkpoint**: Module imports, catalog schema v2 tests pass, resolver + config load — user
stories can begin.

---

## Phase 3: User Story 1 - Produce a debloated Windows 11 image locally (Priority: P1) 🎯 MVP

**Goal**: A single documented local command downloads Windows 11 Pro/en-US/latest, applies
the default catalog via the `Action` dispatcher (removes bloatware, disables Recall +
Widgets), generates a per-arch `Autounattend.xml`, and produces a bootable amd64 ISO +
`SHA256SUMS` + compressed artifact with an auditable RunReport and Image BOM. Edge/OneDrive/WSL
stay absent from the default set (opt-in only).

**Independent Test**: On a clean Windows admin machine run `./build.ps1 -Architecture amd64`
(quickstart Scenario C); verify a bootable image is produced, default apps are absent, the
configured tweaks are present, `Autounattend.xml` is at the ISO root, `SHA256SUMS` + Image BOM
are emitted, and the RunReport lists each change with citation + evidence grade.

### Tests for User Story 1 (write first, ensure they FAIL) ⚠️

- [ ] T024 [P] [US1] Write `tests/Get-Windows11Iso.Tests.ps1` (mocked Fido: arg mapping,
  `IsoPath` override path, unavailable edition/lang/release combo → terminating error)
- [ ] T025 [P] [US1] Write `tests/Remove-Bloatware.Tests.ps1` (mocked
  `Get-`/`Remove-AppxProvisionedPackage`: applies `RemoveAppx`/`RemoveCapability` entries,
  `NotApplicable` skip when absent, `-WhatIf` no-op, arch filtering)
- [ ] T026 [P] [US1] Write `tests/Set-RegistryTweaks.Tests.ps1` (mocked hive load/unload +
  `Set-ItemProperty`: Recall+Widgets applied, `-WhatIf` reports only, hives always unloaded
  on failure)
- [ ] T027 [P] [US1] Write `tests/Enable-WindowsFeature.Tests.ps1` (mocked
  `Enable-WindowsOptionalFeature`/`Add-WindowsCapability -Path`: enables optional features/
  capabilities, `AlreadyApplied` idempotency, `-WhatIf` no-op, arch filtering, WSL entry is
  opt-in) — FR-025
- [ ] T028 [P] [US1] Write `tests/Invoke-CatalogEntry.Tests.ps1` (Action routing:
  `RemoveAppx`/`RemoveCapability`→`Remove-Bloatware`, `SetRegistry`→`Set-RegistryTweaks`,
  `EnableOptionalFeature`/`AddCapability`→`Enable-WindowsFeature` (mocked handlers); unknown
  `Action` throws; arch/idempotency/`-WhatIf` behavior is Action-agnostic) — FR-024/FR-025
- [ ] T029 [P] [US1] Write `tests/New-AutounattendXml.Tests.ps1` (`processorArchitecture`
  differs amd64 vs arm64; OOBE-skip present; MS-account bypass + local-account default on and
  toggleable; locale/keyboard/timezone/disk applied; template-driven; no secret written) —
  FR-027
- [ ] T030 [P] [US1] Write `tests/Export-ImageBom.Tests.ps1` (BOM enumerates every `Applied`
  change with `Citation` + `EvidenceGrade`; includes base image version/hash and pinned tool
  versions; both CycloneDX + Markdown produced; derived solely from the RunReport) —
  FR-029/SC-012
- [ ] T031 [P] [US1] Write `tests/Invoke-IsoBuild.Tests.ps1` (mocked pipeline: preconditions
  gate blocks on failure; changes are driven per selected entry through `Invoke-CatalogEntry`;
  `New-AutounattendXml` + `New-BootableIso` (Autounattend at root + SHA256SUMS) +
  `Export-ImageBom` invoked; RunReport emitted)
- [ ] T032 [P] [US1] Write `tests/Test-ImageIntegrity.Tests.ps1` (missing boot file → fail;
  structural checks; `BootTest` off by default)

### Implementation for User Story 1

- [ ] T033 [P] [US1] Implement `src/WindowsIsoMaker/Public/Get-Windows11Iso.ps1` (Fido
  wrapper: array-built args, `IsoPath` override, hash/integrity recording, returns
  `BaseImage`) — FR-001/FR-002/FR-020
- [ ] T034 [P] [US1] Implement `src/WindowsIsoMaker/Public/Expand-WindowsImage.ps1` (extract
  ISO media to working dir, locate `sources/install.wim|.esd`)
- [ ] T035 [P] [US1] Implement `src/WindowsIsoMaker/Public/Mount-WindowsBuildImage.ps1`
  (resolve edition→index, mount via DISM, return `MountedImage`, guard cleanup)
- [ ] T036 [US1] Implement `src/WindowsIsoMaker/Public/Remove-Bloatware.ps1` (handler for
  `Action=RemoveAppx`/`RemoveCapability`: `SupportsShouldProcess`, apply catalog entries
  filtered by arch, record `ChangeResult[]`). Depends on T010, T018, T019
- [ ] T037 [US1] Implement `src/WindowsIsoMaker/Public/Set-RegistryTweaks.ps1` (handler for
  `Action=SetRegistry`: `SupportsShouldProcess`, load offline hives, apply registry entries
  incl. Recall+Widgets, unload in `finally`, record `ChangeResult[]`). Depends on T011, T012,
  T020
- [ ] T038 [US1] Implement `src/WindowsIsoMaker/Public/Enable-WindowsFeature.ps1` (handler for
  `Action=EnableOptionalFeature`/`AddCapability`: `SupportsShouldProcess`, enable optional
  features/add capabilities via `Enable-WindowsOptionalFeature -Path`/`Add-WindowsCapability
  -Path`, `AlreadyApplied` idempotency, arch filtering, record `ChangeResult[]`). Depends on
  T010, T019 — FR-025
- [ ] T039 [US1] Implement `src/WindowsIsoMaker/Public/Invoke-CatalogEntry.ps1` (Action
  dispatcher: route each `ChangeCatalogEntry` by `Action` to `Remove-Bloatware` /
  `Set-RegistryTweaks` / `Enable-WindowsFeature`; unknown `Action` → terminating error;
  applies arch filtering, idempotency, `-WhatIf` uniformly; returns a `ChangeResult`). Depends
  on T036, T037, T038 — FR-024/FR-025
- [ ] T040 [P] [US1] Create the per-arch Autounattend template(s) under
  `templates/autounattend/` (e.g. `autounattend.xml.template` with tokenized
  `processorArchitecture`, OOBE-skip, MS-account bypass + local-account, locale/keyboard/
  timezone, disk layout, FirstLogon/SetupComplete placeholders) — FR-027
- [ ] T041 [P] [US1] Implement `src/WindowsIsoMaker/Public/New-AutounattendXml.ps1` (render
  `Autounattend.xml` per architecture from `templates/autounattend/` + the `Autounattend`
  sub-config: correct `processorArchitecture`, skip OOBE, MS-account bypass + local account
  (default on, toggleable), locale/keyboard/timezone, disk, FirstLogon/SetupComplete; no
  secret written; idempotent). Depends on T040 — FR-027
- [ ] T042 [P] [US1] Implement `src/WindowsIsoMaker/Public/New-BootableIso.ps1` (oscdimg
  invocation with amd64 BIOS+UEFI boot data `etfsboot.com`+`efisys.bin`; place the generated
  `Autounattend.xml` at the ISO root; emit a `SHA256SUMS` manifest beside the ISO; fail fast
  if `oscdimg` missing) — FR-027/FR-028
- [ ] T043 [P] [US1] Implement `src/WindowsIsoMaker/Public/Compress-BuildArtifact.ps1`
  (compress ISO, name `Windows11-<edition>-<arch>-<release>.<ext>`, compute sha256, return
  `OutputImageArtifact`)
- [ ] T044 [P] [US1] Implement `src/WindowsIsoMaker/Public/Test-ImageIntegrity.ps1`
  (structural checks: media readable, `sources/install.*` + DISM index integrity, required
  amd64 boot files present) — FR-023 default path
- [ ] T045 [P] [US1] Implement `src/WindowsIsoMaker/Public/Export-ImageBom.ps1` (derive the
  Image BOM from the RunReport: base image version + hash, pinned Fido/ADK/PowerShell/Pester/
  PSSA versions, every applied change with its `Citation` + `EvidenceGrade`; emit CycloneDX
  JSON + human-readable Markdown; read solely from the RunReport). Depends on T013 — FR-029
- [ ] T046 [US1] Implement `src/WindowsIsoMaker/Public/Invoke-IsoBuild.ps1` orchestrator
  (`SupportsShouldProcess`: `Test-BuildPrerequisite` → `Get-Windows11Iso` → integrity →
  `Expand-WindowsImage` → `Mount-WindowsBuildImage` → `Resolve-CatalogSelection` → for each
  selected entry `Invoke-CatalogEntry` (dispatches Remove/Set/Enable) → dismount `-Save` →
  `New-AutounattendXml` (per-arch) → `New-BootableIso` (Autounattend at root + `SHA256SUMS`) →
  `Compress-BuildArtifact` → `Test-ImageIntegrity` → `New-RunReport` → `Export-ImageBom`).
  Depends on T014, T023, T033–T045 — FR-010/FR-024/FR-027/FR-028/FR-029
- [ ] T047 [US1] Verify `FunctionsToExport` in `src/WindowsIsoMaker/WindowsIsoMaker.psd1`
  covers all 14 public functions and that `Import-Module ./src/WindowsIsoMaker` succeeds

**Checkpoint**: Scenario C (default local amd64 build) works end-to-end via the dispatcher;
US1 is independently demonstrable with Autounattend + SHA256SUMS + Image BOM.

---

## Phase 4: User Story 2 - Build both amd64 and arm64 images in GitHub Actions (Priority: P1)

**Goal**: A manually dispatched workflow produces compressed amd64 and arm64 artifacts (the
arm64 leg on a native `windows-11-arm` runner) via the same shipped `Invoke-IsoBuild`, each
with SLSA provenance + a `SHA256SUMS` manifest, optionally uploaded to Azure Blob (OIDC).

**Independent Test**: Manually dispatch `build-image.yml` (quickstart Scenario F); confirm two
named compressed artifacts (one per arch), arm64 built natively, per-ISO provenance +
`SHA256SUMS`, and that a plain push does NOT trigger it.

- [ ] T048 [P] [US2] Add arm64 boot-data selection to
  `src/WindowsIsoMaker/Public/New-BootableIso.ps1` (UEFI-only `bootaa64.efi` layout when
  `Architecture=arm64`; Autounattend placement + `SHA256SUMS` behavior unchanged). Depends on
  T042
- [ ] T049 [P] [US2] Add `tests/New-BootableIso.Tests.ps1` (mocked oscdimg: arch→boot-arg
  selection for amd64 vs arm64; `Autounattend.xml` placed at ISO root; `SHA256SUMS` written;
  missing oscdimg → actionable terminating error) — FR-027/FR-028
- [ ] T050 [US2] Create `docs/ci.md` (runner disk/time limits, ADK Deployment Tools install,
  arm64 tooling verification, documented skip-heavy-build path, provenance/SBOM/Azure-upload
  overview + artifact-size rationale)
- [ ] T051 [US2] Create `.github/workflows/build-image.yml` (`workflow_dispatch` ONLY; inputs
  `edition`/`language`/`release`/`profile`/`enable_catalog_id`/`disable_catalog_id`/
  `skip_heavy_build`/`boot_test` — **no `remove_edge`/`remove_onedrive` inputs**; matrix
  `amd64`=`windows-latest`, `arm64`=`windows-11-arm`; `permissions: contents:read,
  id-token:write, attestations:write`; SHA-pinned actions; steps: checkout → install ADK
  Deployment Tools → disk check/fail-fast → `./build.ps1`/`Invoke-IsoBuild` with matrix arch
  → `upload-artifact` one named artifact per arch + RunReport + Image BOM; `skip_heavy_build=
  true` runs preview-only). Depends on T046, T048, T050 — FR-004/FR-012/FR-014/FR-015/FR-024
- [ ] T052 [US2] Add build provenance to `.github/workflows/build-image.yml`: publish the
  `SHA256SUMS` manifest and attest each produced ISO with `actions/attest-build-provenance`
  (SHA-pinned action) so consumers can `gh attestation verify`. Depends on T051 —
  FR-028/SC-009
- [ ] T053 [US2] Add an optional Azure Blob upload job/step to
  `.github/workflows/build-image.yml`: when `vars.AZURE_STORAGE_ACCOUNT` +
  `vars.AZURE_STORAGE_CONTAINER` are set, OIDC `azure/login` (SHA-pinned; `AZURE_CLIENT_ID`/
  `AZURE_TENANT_ID`/`AZURE_SUBSCRIPTION_ID` repo vars, **no stored secrets**) then
  `az storage blob upload` of the compressed image + `SHA256SUMS` + BOM; otherwise fall back
  to `actions/upload-artifact`; document the ~5–7 GB ISO artifact-size rationale in
  `docs/ci.md`. Depends on T051 — FR-030

**Checkpoint**: Manual dispatch yields per-arch artifacts with provenance + checksums (and
optional Azure upload); no auto-trigger on push/PR.

---

## Phase 5: User Story 3 - Automated quality gates on every change (Priority: P1)

**Goal**: PSScriptAnalyzer + Pester v5 (including the catalog schema v2 gate) plus a repo SBOM
run on every push/PR and gate merges; undocumented / ungraded catalog entries and grade-3
default-enabled entries fail CI; all Actions stay SHA-pinned via Renovate.

**Independent Test**: Push a commit deleting a `Citation`/`EvidenceGrade` (or marking a
grade-3 entry `DefaultEnabled=$true`, or breaking a test/lint rule); confirm the check fails
(quickstart Scenario A). Push a compliant commit; confirm it passes.

- [ ] T054 [US3] Create `.github/workflows/ci.yml` (triggers `push` + `pull_request` on
  `windows-latest`; SHA-pinned actions; install pinned Pester v5 + PSScriptAnalyzer; run
  `Invoke-ScriptAnalyzer -Settings ./PSScriptAnalyzerSettings.psd1 -Recurse`; run Pester with
  NUnit output; publish results; fail job on any lint error or test failure) — FR-013/SC-005
- [ ] T055 [US3] Add a repository/tooling SBOM step to `.github/workflows/ci.yml` using
  `anchore/sbom-action` (SHA-pinned) producing a CycloneDX SBOM and uploading it as an
  artifact. Depends on T054 — FR-029
- [ ] T056 [US3] Add negative-path assertions to `tests/Catalog.Schema.Tests.ps1` proving a
  catalog entry missing `Action`/`EvidenceGrade`/`Citation`/`Description`/`Rationale` fails
  the suite, AND that a grade-3 entry with `DefaultEnabled=$true` fails (documents the
  merge-blocking evidence gate — FR-009/FR-026/SC-004/SC-010). Depends on T017
- [ ] T057 [US3] Verify `renovate.json5` at repo root governs dependency updates: extends the
  shared `github>DevSecNinja/.github//.renovate/*` presets + `helpers:pinGitHubActionDigests`
  (all GitHub Actions SHA-pinned) and a repo-local `customManager` (regex) tracking the pinned
  pbatard/Fido tag in `vendor/fido/VERSION` via the `github-releases` datasource — FR-031

**Checkpoint**: CI runs lint + tests + evidence gate + SBOM on every change and blocks on
failure; heavy build never runs here; dependencies stay pinned.

---

## Phase 6: User Story 4 - Customize edition, language, release, architecture, and change set (Priority: P2)

**Goal**: Data-driven configuration (edition/language/release/arch, `Profile`, `Toggles`,
`EnableCatalogId`/`DisableCatalogId`) is honored exactly, and opt-in Edge/OneDrive/WSL removal
or enablement (OFF by default) works with zero new code — pure catalog selection (FR-024).

**Independent Test**: Run a build with `EnableCatalogId = 'remove-edge','remove-onedrive',
'feature-wsl'` (quickstart Scenario D); confirm the image reflects exactly those opt-in
choices and nothing more, each recorded with citation + evidence grade + reversibility.

- [ ] T058 [P] [US4] Add the opt-in removal catalog entries `remove-edge` and `remove-onedrive`
  (`Action=RemoveAppx`/`RemoveCapability`, `DefaultEnabled=$false`, `Citation`, `EvidenceGrade`,
  `Reversible`+`Reversal`) to `config/catalog.appx.psd1` / `config/catalog.capabilities.psd1`
  — FR-008/FR-024
- [ ] T059 [US4] Verify end-to-end opt-in enablement of `remove-edge`/`remove-onedrive`/
  `feature-wsl` (and `feature-vmplatform`) via `Profile`/`Toggles`/`EnableCatalogId`, and that
  the WSL entries carry the online-first-boot Rationale/Reversal note (no new
  parameter/switch/code path — SC-011). Depends on T015, T019, T058 — FR-024/FR-025
- [ ] T060 [US4] Wire resolved edition/language/release/arch pass-through from
  `Get-BuildConfiguration` through `src/WindowsIsoMaker/Public/Invoke-IsoBuild.ps1` into
  `Get-Windows11Iso`/`New-AutounattendXml`/`New-BootableIso`. Depends on T046 — FR-002/FR-003
- [ ] T061 [P] [US4] Extend `tests/Get-BuildConfiguration.Tests.ps1` with customization cases
  (non-default arch/language/release; `Profile=minimal|aggressive`; `Toggles` on/off;
  `EnableCatalogId` enables only opt-in entries; defaults keep Edge/OneDrive/WSL absent from
  the effective set; unknown catalog id → terminating error) — FR-024

**Checkpoint**: Non-default configs and opt-in Edge/OneDrive/WSL selection produce exactly the
requested image with no new switches.

---

## Phase 7: User Story 5 - Safe, previewable, idempotent, reversible operation (Priority: P2)

**Goal**: A dry-run previews all intended changes without touching media; re-runs are
idempotent; failures clean up without leaving corrupt output; reversible changes are
documented.

**Independent Test**: Run Scenario B (`-WhatIf`) → Preview RunReport, no media changed; run
Scenario C twice → second run reports `AlreadyApplied` and applies nothing new (Scenario E).

- [ ] T062 [US5] Implement `-WhatIf`/preview path in
  `src/WindowsIsoMaker/Public/Invoke-IsoBuild.ps1` producing a RunReport with
  `Outcome=Preview` and zero media changes (also drives `skip_heavy_build`). Depends on T046
- [ ] T063 [US5] Implement idempotency detection (read current state → mark `AlreadyApplied`)
  in `src/WindowsIsoMaker/Public/Remove-Bloatware.ps1`,
  `src/WindowsIsoMaker/Public/Set-RegistryTweaks.ps1`, and
  `src/WindowsIsoMaker/Public/Enable-WindowsFeature.ps1`. Depends on T036, T037, T038 —
  FR-017/SC-007
- [ ] T064 [US5] Add failure-path cleanup to
  `src/WindowsIsoMaker/Public/Invoke-IsoBuild.ps1` (`finally`: dismount `-Discard`, unload
  hives, surface terminating error, never present corrupt output as success). Depends on T046
  — FR-005
- [ ] T065 [P] [US5] Add `Reversal` notes to every reversible entry across
  `config/catalog.registry.psd1`, `config/catalog.appx.psd1`,
  `config/catalog.capabilities.psd1` — FR-018
- [ ] T066 [P] [US5] Add `tests/Invoke-IsoBuild.Preview.Tests.ps1` (preview modifies nothing;
  idempotent re-run applies zero changes; mid-build failure triggers cleanup)

**Checkpoint**: Preview, idempotency, and safe-failure guarantees are demonstrable.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Documentation (evidence grading, WSL, Autounattend, provenance/BOM, Azure upload)
and end-to-end validation across all stories.

- [ ] T067 [P] Create `docs/usage.md` (quick-start, config-file-first interface, single-command
  local build, `Profile`/`EnableCatalogId` examples) — SC-008
- [ ] T068 [P] Create `docs/change-rationale.md` (human-readable rendering of every catalog
  entry's What/Why/Citation/**EvidenceGrade**/Reversal) — Principle II
- [ ] T069 [P] Create `docs/evidence-grading.md` (the 1/2/3 grading rubric — MS official /
  reputable vendor / community — and the grade-3-may-not-be-DefaultEnabled gate) —
  FR-026/SC-010
- [ ] T070 [P] Create `docs/wsl.md` (WSL as an opt-in catalog entry; offline enables
  `Microsoft-Windows-Subsystem-Linux` + `VirtualMachinePlatform`; kernel + distro install
  online on first boot) — FR-025
- [ ] T071 [P] Create `docs/autounattend.md` (per-arch `processorArchitecture`; OOBE skip;
  MS-account bypass + local account default-on/toggleable; locale/keyboard/timezone; disk;
  FirstLogon/SetupComplete) — FR-027
- [ ] T072 [P] Create `docs/provenance-bom.md` (verify `SHA256SUMS`; `gh attestation verify`
  the SLSA provenance; read the Image BOM; locate the repo CycloneDX SBOM) — FR-028/FR-029
- [ ] T073 [P] Create `docs/azure-upload.md` (optional OIDC Azure Blob upload: required repo
  vars, no stored secrets, fallback to workflow artifact, ~5–7 GB artifact-size rationale) —
  FR-030
- [ ] T074 Run a clean `Invoke-ScriptAnalyzer -Settings ./PSScriptAnalyzerSettings.psd1
  -Recurse` pass and resolve all findings across `src/`, `tests/`, `build.ps1`
- [ ] T075 Execute quickstart validation Scenarios A–G from
  [quickstart.md](./quickstart.md) (incl. data-driven selection, provenance/BOM, and
  Autounattend) and confirm each expected outcome (SC-001…SC-012)
- [ ] T076 [P] Update root `README.md` with a project overview and pointers to `docs/usage.md`,
  `docs/ci.md`, `docs/evidence-grading.md`, and `docs/provenance-bom.md`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately.
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories.
- **User Stories (Phase 3–7)**: All depend on Foundational.
  - US1 (P1) is the MVP and should complete first (now includes the Action dispatcher,
    Autounattend, SHA256SUMS, and Image BOM).
  - US2 (P1) depends on US1's `Invoke-IsoBuild` + `New-BootableIso` (T046, T042).
  - US3 (P1) depends only on Foundational (schema v2 tests) + Setup (lint config); can run in
    parallel with US1/US2.
  - US4 (P2) depends on Foundational's `Resolve-CatalogSelection`/config loader and US1's
    orchestrator.
  - US5 (P2) depends on US1's mutating handlers and orchestrator.
- **Polish (Phase 8)**: Depends on all targeted stories being complete.

### Key Cross-Task Dependencies

- T014 → T009, T010 · T015 → (catalog data T018–T020) · T016 → T015
- T022 → T016 · T023 → T015, T021, T022
- T036 → T010, T018, T019 · T037 → T011, T012, T020 · T038 → T010, T019
- T039 → T036, T037, T038 (dispatcher) · T041 → T040 · T042 → (Autounattend from T041)
- T045 → T013 · T046 → T014, T023, T033–T045 · T047 → T046
- T048 → T042 · T051 → T046, T048, T050 · T052 → T051 · T053 → T051
- T055 → T054 · T056 → T017 · T059 → T015, T019, T058 · T060 → T046
- T062/T064 → T046 · T063 → T036, T037, T038

### Within Each User Story

- Tests are written FIRST and must FAIL before implementation.
- Private helpers/catalog/config (Foundational) before public functions.
- Handlers (`Remove-Bloatware`/`Set-RegistryTweaks`/`Enable-WindowsFeature`) before the
  `Invoke-CatalogEntry` dispatcher; dispatcher before the `Invoke-IsoBuild` orchestrator;
  orchestrator before workflows.

---

## Parallel Opportunities

- **Setup**: T002–T007 run in parallel after T001.
- **Foundational**: T008–T013 (private helpers) parallel; `Resolve-CatalogSelection` (T015) +
  its test (T016) parallel with catalog data T018–T021; schema v2 tests T017 gate the catalog
  data.
- **US1 tests**: T024–T032 parallel; independent public functions T033–T035, T040–T045
  parallel; handlers T036–T038 → dispatcher T039 → orchestrator T046 sequential on their deps.
- **US2**: provenance (T052) and Azure upload (T053) both extend `build-image.yml` (T051) and
  should be sequenced after it.
- **Cross-story (after Foundational)**: US3 (T054–T057) can proceed in parallel with US1/US2.

### Parallel Example: User Story 1

```text
# Write all US1 tests together (they must fail first):
Task: tests/Get-Windows11Iso.Tests.ps1
Task: tests/Remove-Bloatware.Tests.ps1
Task: tests/Set-RegistryTweaks.Tests.ps1
Task: tests/Enable-WindowsFeature.Tests.ps1
Task: tests/Invoke-CatalogEntry.Tests.ps1
Task: tests/New-AutounattendXml.Tests.ps1
Task: tests/Export-ImageBom.Tests.ps1
Task: tests/Invoke-IsoBuild.Tests.ps1
Task: tests/Test-ImageIntegrity.Tests.ps1

# Then implement independent public functions together:
Task: src/WindowsIsoMaker/Public/Get-Windows11Iso.ps1
Task: src/WindowsIsoMaker/Public/Expand-WindowsImage.ps1
Task: src/WindowsIsoMaker/Public/Mount-WindowsBuildImage.ps1
Task: src/WindowsIsoMaker/Public/New-AutounattendXml.ps1
Task: src/WindowsIsoMaker/Public/New-BootableIso.ps1
Task: src/WindowsIsoMaker/Public/Compress-BuildArtifact.ps1
Task: src/WindowsIsoMaker/Public/Test-ImageIntegrity.ps1
Task: src/WindowsIsoMaker/Public/Export-ImageBom.ps1
```

---

## Implementation Strategy

### MVP First (User Story 1)

1. Complete Phase 1 (Setup) + Phase 2 (Foundational).
2. Complete Phase 3 (US1) → **STOP and VALIDATE** with quickstart Scenario C.
3. This delivers the core value: a bootable, debloated local amd64 image driven by the
   data-driven `Action` dispatcher, with a per-arch `Autounattend.xml`, `SHA256SUMS`, an
   Image BOM, and an auditable RunReport.

### Incremental Delivery

1. Setup + Foundational → foundation ready (catalog schema v2, resolver, v2 config).
2. US1 → MVP (local debloated build with dispatcher + Autounattend + BOM).
3. US3 (CI quality gates + evidence gate + SBOM) — bring online early to guard all work.
4. US2 (CI matrix artifacts amd64 + arm64 + provenance + optional Azure upload).
5. US4 (data-driven customization / opt-in Edge/OneDrive/WSL) → US5 (preview / idempotency /
   reversibility).
6. Polish (docs incl. evidence-grading/WSL/Autounattend/provenance-BOM/Azure + Scenarios A–G).

### Parallel Team Strategy

After Foundational: Developer A → US1; Developer B → US3 (ci.yml + evidence gate + SBOM); once
US1's orchestrator lands, Developer C picks up US2 (provenance/Azure), then US4/US5.

---

## Notes

- [P] = different files, no dependency on incomplete tasks.
- Every mutating public function uses `[CmdletBinding(SupportsShouldProcess)]`, is
  idempotent, and is scoped to working dirs/mounted image (Principle VI).
- Catalog changes are data-only under `config/`; never inline in functions (Principle II).
- Verify tests fail before implementing; commit after each task or logical group.
