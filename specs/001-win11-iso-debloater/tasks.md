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
  `src/WindowsIsoMaker/Private/`, `config/`, `tests/`, `docs/`, `vendor/fido/`,
  `.github/workflows/`)
- [ ] T002 [P] Create the pinned module manifest `src/WindowsIsoMaker/WindowsIsoMaker.psd1`
  (fixed `ModuleVersion`, `PowerShellVersion` floor, `RootModule = 'WindowsIsoMaker.psm1'`,
  and `FunctionsToExport` listing all 10 public functions; pin `RequiredModules`/documented
  minimums for Pester v5 + PSScriptAnalyzer)
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

**Purpose**: Shared private helpers, the change-catalog data + schema tests, and the
configuration loader that EVERY user story depends on.

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
  `ResolvedConfig`, `Applied[]`, `Skipped[]`, `Artifact`, `Integrity`, `ToolVersions`,
  `Outcome`) per data-model
- [ ] T014 Implement preconditions gate
  `src/WindowsIsoMaker/Private/Test-BuildPrerequisite.ps1` (admin rights, `dism`/`oscdimg`
  tooling, free disk space, valid config; throws actionable errors — FR-019). Depends on
  T009, T010
- [ ] T015 Write change-catalog schema tests FIRST in `tests/Catalog.Schema.Tests.ps1`:
  assert every entry across all catalog files has non-empty `Description`, `Rationale`, and a
  `Citation` (URL or explicit `Unverified`); `Unverified` ⇒ `DefaultEnabled=$false`; unique
  `Id`; non-empty `Arch` subset of `{amd64,arm64}`; registry `Target` shape — validate
  against [contracts/change-catalog.schema.json](./contracts/change-catalog.schema.json)
  (FR-009, SC-004)
- [ ] T016 [P] Create provisioned-appx removal catalog `config/catalog.appx.psd1` (default
  bloatware — Clipchamp, Bing News/Weather, Solitaire, Xbox extras, consumer Teams,
  King/Candy-Crush titles — each with `Description`/`Rationale`/`Citation`,
  `DefaultEnabled=$true`, `Reversible`, `Arch`) — FR-006
- [ ] T017 [P] Create Windows-capability catalog `config/catalog.capabilities.psd1`
  (arch-scoped capability entries, each with What/Why/Citation) — FR-021/Principle IV
- [ ] T018 [P] Create registry-tweak catalog `config/catalog.registry.psd1` including
  `reg-disable-recall` (Recall) and `reg-disable-widgets` (Widgets) as `DefaultEnabled=$true`
  reversible tweaks, plus cited privacy/telemetry safe tweaks — each with What/Why/Citation
  and full `Target` (Hive/Path/Name/Kind/Value) — FR-007
- [ ] T019 [P] Create the default build config `config/build.config.psd1` (Edition=`Pro`,
  Language=`en-US`, Release=`latest`, Architecture=`amd64`, Profile=`default`,
  `RemoveEdge=$false`, `RemoveOneDrive=$false`, working/output dirs, `CompressionFormat`,
  pinned `FidoPath`) per [contracts/build-config.schema.md](./contracts/build-config.schema.md)
- [ ] T020 Write config loader tests FIRST in `tests/Get-BuildConfiguration.Tests.ps1`
  (config file is the primary interface; precedence: file defaults ← `WIM_*` env vars ←
  explicit params; `-ConfigPath`/`WIM_CONFIG_PATH` loads an alternate config file; a second
  saved profile file resolves independently; validation rejects bad arch/edition; env override
  applied)
- [ ] T021 Implement `src/WindowsIsoMaker/Public/Get-BuildConfiguration.ps1` (config file is
  the primary interface: load `config/build.config.psd1` by default or an alternate file via
  `-Path`/`-ConfigPath` (alias) or `WIM_CONFIG_PATH`, apply `WIM_*` env overrides then
  explicit params as optional last-mile overrides, validate, return a `BuildConfiguration`
  object). Depends on T019, T020

**Checkpoint**: Module imports, catalog schema tests pass, config loads — user stories can
begin.

---

## Phase 3: User Story 1 - Produce a debloated Windows 11 image locally (Priority: P1) 🎯 MVP

**Goal**: A single documented local command downloads Windows 11 Pro/en-US/latest, removes
the default bloatware, disables Recall + Widgets, leaves Edge/OneDrive present, and produces
a bootable amd64 ISO + compressed artifact with an auditable RunReport.

**Independent Test**: On a clean Windows admin machine run `./build.ps1 -Architecture amd64`
(quickstart Scenario C); verify a bootable image is produced, default apps are absent, the
configured tweaks are present, and the RunReport lists each change with citations.

### Tests for User Story 1 (write first, ensure they FAIL) ⚠️

- [ ] T022 [P] [US1] Write `tests/Get-Windows11Iso.Tests.ps1` (mocked Fido: arg mapping,
  `IsoPath` override path, unavailable edition/lang/release combo → terminating error)
- [ ] T023 [P] [US1] Write `tests/Remove-Bloatware.Tests.ps1` (mocked
  `Get-`/`Remove-AppxProvisionedPackage`: applies default entries, `NotApplicable` skip when
  absent, `-WhatIf` no-op, arch filtering)
- [ ] T024 [P] [US1] Write `tests/Set-RegistryTweaks.Tests.ps1` (mocked hive load/unload +
  `Set-ItemProperty`: Recall+Widgets applied, `-WhatIf` reports only, hives always unloaded
  on failure)
- [ ] T025 [P] [US1] Write `tests/Invoke-IsoBuild.Tests.ps1` (mocked pipeline: preconditions
  gate blocks on failure, correct call order, RunReport emitted)
- [ ] T026 [P] [US1] Write `tests/Test-ImageIntegrity.Tests.ps1` (missing boot file → fail;
  structural checks; `BootTest` off by default)

### Implementation for User Story 1

- [ ] T027 [P] [US1] Implement `src/WindowsIsoMaker/Public/Get-Windows11Iso.ps1` (Fido
  wrapper: array-built args, `IsoPath` override, hash/integrity recording, returns
  `BaseImage`) — FR-001/FR-002/FR-020
- [ ] T028 [P] [US1] Implement `src/WindowsIsoMaker/Public/Expand-WindowsImage.ps1` (extract
  ISO media to working dir, locate `sources/install.wim|.esd`)
- [ ] T029 [P] [US1] Implement `src/WindowsIsoMaker/Public/Mount-WindowsBuildImage.ps1`
  (resolve edition→index, mount via DISM, return `MountedImage`, guard cleanup)
- [ ] T030 [US1] Implement `src/WindowsIsoMaker/Public/Remove-Bloatware.ps1`
  (`SupportsShouldProcess`, apply appx/capability catalog entries filtered by arch/profile,
  record `ChangeResult[]`). Depends on T010, T016, T017
- [ ] T031 [US1] Implement `src/WindowsIsoMaker/Public/Set-RegistryTweaks.ps1`
  (`SupportsShouldProcess`, load offline hives, apply registry entries incl. Recall+Widgets,
  unload in `finally`, record `ChangeResult[]`). Depends on T011, T012, T018
- [ ] T032 [P] [US1] Implement `src/WindowsIsoMaker/Public/New-BootableIso.ps1` (oscdimg
  invocation with amd64 BIOS+UEFI boot data `etfsboot.com`+`efisys.bin`; fail fast if
  `oscdimg` missing)
- [ ] T033 [P] [US1] Implement `src/WindowsIsoMaker/Public/Compress-BuildArtifact.ps1`
  (compress ISO, name `Windows11-<edition>-<arch>-<release>.<ext>`, compute sha256, return
  `OutputImageArtifact`)
- [ ] T034 [P] [US1] Implement `src/WindowsIsoMaker/Public/Test-ImageIntegrity.ps1`
  (structural checks: media readable, `sources/install.*` + DISM index integrity, required
  amd64 boot files present) — FR-023 default path
- [ ] T035 [US1] Implement `src/WindowsIsoMaker/Public/Invoke-IsoBuild.ps1` orchestrator
  (`SupportsShouldProcess`: `Test-BuildPrerequisite` → `Get-Windows11Iso` → integrity →
  `Expand-WindowsImage` → `Mount-WindowsBuildImage` → `Remove-Bloatware` →
  `Set-RegistryTweaks` → dismount `-Save` → `New-BootableIso` → `Compress-BuildArtifact` →
  `Test-ImageIntegrity` → `New-RunReport`). Depends on T014, T021, T027–T034
- [ ] T036 [US1] Verify `FunctionsToExport` in `src/WindowsIsoMaker/WindowsIsoMaker.psd1`
  covers all US1 public functions and that `Import-Module ./src/WindowsIsoMaker` succeeds

**Checkpoint**: Scenario C (default local amd64 build) works end-to-end; US1 is independently
demonstrable.

---

## Phase 4: User Story 2 - Build both amd64 and arm64 images in GitHub Actions (Priority: P1)

**Goal**: A manually dispatched workflow produces compressed amd64 and arm64 artifacts, the
arm64 leg on a native `windows-11-arm` runner, using the same shipped `Invoke-IsoBuild`.

**Independent Test**: Manually dispatch `build-image.yml` (quickstart Scenario F); confirm
two named compressed artifacts (one per arch), arm64 built natively, and that a plain push
does NOT trigger it.

- [ ] T037 [P] [US2] Add arm64 boot-data selection to
  `src/WindowsIsoMaker/Public/New-BootableIso.ps1` (UEFI-only `bootaa64.efi` layout when
  `Architecture=arm64`). Depends on T032
- [ ] T038 [P] [US2] Add `tests/New-BootableIso.Tests.ps1` (mocked oscdimg: arch→boot-arg
  selection for amd64 vs arm64; missing oscdimg → actionable terminating error)
- [ ] T039 [US2] Create `docs/ci.md` (runner disk/time limits, ADK Deployment Tools install,
  arm64 tooling verification, documented skip-heavy-build path)
- [ ] T040 [US2] Create `.github/workflows/build-image.yml` (`workflow_dispatch` ONLY; inputs
  edition/language/release/remove_edge/remove_onedrive/skip_heavy_build/boot_test; matrix
  `amd64`=`windows-latest`, `arm64`=`windows-11-arm`; steps: checkout → install ADK
  Deployment Tools → disk check/fail-fast → `./build.ps1`/`Invoke-IsoBuild` with matrix arch
  → `upload-artifact` one named artifact per arch + RunReport; `skip_heavy_build=true` runs
  preview-only). Depends on T035, T037, T039 — FR-004/FR-012/FR-014/FR-015

**Checkpoint**: Manual dispatch yields per-arch artifacts; no auto-trigger on push/PR.

---

## Phase 5: User Story 3 - Automated quality gates on every change (Priority: P1)

**Goal**: PSScriptAnalyzer + Pester v5 (including catalog schema tests) run on every push/PR
and gate merges; undocumented catalog entries fail CI.

**Independent Test**: Push a commit deleting a `Citation` (or breaking a test/lint rule);
confirm the check fails (quickstart Scenario A). Push a compliant commit; confirm it passes.

- [ ] T041 [US3] Create `.github/workflows/ci.yml` (triggers `push` + `pull_request` on
  `windows-latest`; install pinned Pester v5 + PSScriptAnalyzer; run
  `Invoke-ScriptAnalyzer -Settings ./PSScriptAnalyzerSettings.psd1 -Recurse`; run Pester with
  NUnit output; publish results; fail job on any lint error or test failure) — FR-013/SC-005
- [ ] T042 [US3] Add a negative-path assertion to `tests/Catalog.Schema.Tests.ps1` proving a
  catalog entry missing `Citation`/`Description`/`Rationale` fails the suite (documents the
  merge-blocking gate — FR-009/SC-004). Depends on T015

**Checkpoint**: CI runs lint + tests on every change and blocks on failure; heavy build never
runs here.

---

## Phase 6: User Story 4 - Customize edition, language, release, architecture, and change set (Priority: P2)

**Goal**: Configuration overrides (edition/language/release/arch, include/exclude catalog
ids) and opt-in Edge/OneDrive removal (OFF by default) are honored exactly.

**Independent Test**: Run `./build.ps1 -Architecture amd64 -Language nl-NL -RemoveEdge
-RemoveOneDrive` (quickstart Scenario D); confirm the image reflects those choices and nothing
more, and each opt-in removal is recorded with citation + reversibility.

- [ ] T043 [P] [US4] Add opt-in removal catalog entries `remove-edge` and `remove-onedrive`
  (`DefaultEnabled=$false`, `Citation`, `Reversible`+`Reversal`) to
  `config/catalog.appx.psd1` and/or `config/catalog.registry.psd1` — FR-008
- [ ] T044 [US4] Implement `IncludeCatalogId`/`ExcludeCatalogId` + `RemoveEdge`/`RemoveOneDrive`
  catalog selection logic in `src/WindowsIsoMaker/Public/Get-BuildConfiguration.ps1` (enable
  opt-in entries only when flagged). Depends on T021, T043
- [ ] T045 [US4] Wire resolved edition/language/release/arch pass-through from
  `Get-BuildConfiguration` through `src/WindowsIsoMaker/Public/Invoke-IsoBuild.ps1` into
  `Get-Windows11Iso`/`New-BootableIso`. Depends on T035, T044
- [ ] T046 [P] [US4] Extend `tests/Get-BuildConfiguration.Tests.ps1` with customization cases
  (non-default arch/language; include/exclude ids; `-RemoveEdge`/`-RemoveOneDrive` enable
  only the opt-in entries; defaults keep Edge/OneDrive present)

**Checkpoint**: Non-default configs and opt-in removals produce exactly the requested image.

---

## Phase 7: User Story 5 - Safe, previewable, idempotent, reversible operation (Priority: P2)

**Goal**: A dry-run previews all intended changes without touching media; re-runs are
idempotent; failures clean up without leaving corrupt output; reversible changes are
documented.

**Independent Test**: Run Scenario B (`-WhatIf`) → Preview RunReport, no media changed; run
Scenario C twice → second run reports `AlreadyApplied` and applies nothing new (Scenario E).

- [ ] T047 [US5] Implement `-WhatIf`/preview path in
  `src/WindowsIsoMaker/Public/Invoke-IsoBuild.ps1` producing a RunReport with
  `Outcome=Preview` and zero media changes (also drives `skip_heavy_build`). Depends on T035
- [ ] T048 [US5] Implement idempotency detection (read current state → mark `AlreadyApplied`)
  in `src/WindowsIsoMaker/Public/Remove-Bloatware.ps1` and
  `src/WindowsIsoMaker/Public/Set-RegistryTweaks.ps1`. Depends on T030, T031 — FR-017/SC-007
- [ ] T049 [US5] Add failure-path cleanup to
  `src/WindowsIsoMaker/Public/Invoke-IsoBuild.ps1` (`finally`: dismount `-Discard`, unload
  hives, surface terminating error, never present corrupt output as success). Depends on T035
  — FR-005
- [ ] T050 [P] [US5] Add `Reversal` notes to every reversible entry across
  `config/catalog.registry.psd1`, `config/catalog.appx.psd1`,
  `config/catalog.capabilities.psd1` — FR-018
- [ ] T051 [P] [US5] Add `tests/Invoke-IsoBuild.Preview.Tests.ps1` (preview modifies nothing;
  idempotent re-run applies zero changes; mid-build failure triggers cleanup)

**Checkpoint**: Preview, idempotency, and safe-failure guarantees are demonstrable.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Documentation and end-to-end validation across all stories.

- [ ] T052 [P] Create `docs/usage.md` (quick-start, parameters, single-command local build)
  — SC-008
- [ ] T053 [P] Create `docs/change-rationale.md` (human-readable rendering of every catalog
  entry's What/Why/Citation/Reversal) — Principle II
- [ ] T054 Run a clean `Invoke-ScriptAnalyzer -Settings ./PSScriptAnalyzerSettings.psd1
  -Recurse` pass and resolve all findings across `src/`, `tests/`, `build.ps1`
- [ ] T055 Execute quickstart validation Scenarios A–F from
  [quickstart.md](./quickstart.md) and confirm each expected outcome (SC-001…SC-008)
- [ ] T056 [P] Update root `README.md` with a project overview and pointer to `docs/usage.md`
  and `docs/ci.md`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately.
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories.
- **User Stories (Phase 3–7)**: All depend on Foundational.
  - US1 (P1) is the MVP and should complete first.
  - US2 (P1) depends on US1's `Invoke-IsoBuild` + `New-BootableIso` (T035, T032).
  - US3 (P1) depends only on Foundational (schema tests) + Setup (lint config); can run in
    parallel with US1/US2.
  - US4 (P2) depends on US1's `Invoke-IsoBuild` and Foundational config loader.
  - US5 (P2) depends on US1's mutating functions and orchestrator.
- **Polish (Phase 8)**: Depends on all targeted stories being complete.

### Key Cross-Task Dependencies

- T014 → T009, T010 · T021 → T019, T020
- T030 → T010, T016, T017 · T031 → T011, T012, T018
- T035 → T014, T021, T027–T034 · T036 → T035
- T037 → T032 · T040 → T035, T037, T039
- T042 → T015 · T044 → T021, T043 · T045 → T035, T044
- T047/T049 → T035 · T048 → T030, T031

### Within Each User Story

- Tests are written FIRST and must FAIL before implementation.
- Private helpers/catalog/config (Foundational) before public functions.
- Public functions before the orchestrator; orchestrator before workflows.

---

## Parallel Opportunities

- **Setup**: T002–T007 run in parallel after T001.
- **Foundational**: T008–T013 (private helpers) parallel; catalog data T016–T019 parallel
  after T015.
- **US1 tests**: T022–T026 parallel; independent public functions T027–T029, T032–T034
  parallel; T030/T031/T035 sequential on their deps.
- **Cross-story (after Foundational)**: US3 (T041) can proceed in parallel with US1/US2.

### Parallel Example: User Story 1

```text
# Write all US1 tests together (they must fail first):
Task: tests/Get-Windows11Iso.Tests.ps1
Task: tests/Remove-Bloatware.Tests.ps1
Task: tests/Set-RegistryTweaks.Tests.ps1
Task: tests/Invoke-IsoBuild.Tests.ps1
Task: tests/Test-ImageIntegrity.Tests.ps1

# Then implement independent public functions together:
Task: src/WindowsIsoMaker/Public/Get-Windows11Iso.ps1
Task: src/WindowsIsoMaker/Public/Expand-WindowsImage.ps1
Task: src/WindowsIsoMaker/Public/Mount-WindowsBuildImage.ps1
Task: src/WindowsIsoMaker/Public/New-BootableIso.ps1
Task: src/WindowsIsoMaker/Public/Compress-BuildArtifact.ps1
Task: src/WindowsIsoMaker/Public/Test-ImageIntegrity.ps1
```

---

## Implementation Strategy

### MVP First (User Story 1)

1. Complete Phase 1 (Setup) + Phase 2 (Foundational).
2. Complete Phase 3 (US1) → **STOP and VALIDATE** with quickstart Scenario C.
3. This delivers the core value: a bootable, debloated local amd64 image with an auditable
   RunReport.

### Incremental Delivery

1. Setup + Foundational → foundation ready.
2. US1 → MVP (local debloated build).
3. US3 (CI quality gates) — bring online early to guard all subsequent work.
4. US2 (CI matrix artifacts amd64 + arm64).
5. US4 (customization / opt-in removals) → US5 (preview / idempotency / reversibility).
6. Polish (docs + Scenarios A–F).

### Parallel Team Strategy

After Foundational: Developer A → US1; Developer B → US3 (ci.yml + gate); once US1's
orchestrator lands, Developer C picks up US2, then US4/US5.

---

## Notes

- [P] = different files, no dependency on incomplete tasks.
- Every mutating public function uses `[CmdletBinding(SupportsShouldProcess)]`, is
  idempotent, and is scoped to working dirs/mounted image (Principle VI).
- Catalog changes are data-only under `config/`; never inline in functions (Principle II).
- Verify tests fail before implementing; commit after each task or logical group.
