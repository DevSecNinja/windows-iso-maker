# Quickstart & Validation Guide: Windows 11 ISO Builder & Debloater

This guide proves the feature works end-to-end. It is a **validation/run guide** — full
implementation lives in the module (`src/WindowsIsoMaker/`) and `tasks.md`.

References: [plan.md](./plan.md) · [data-model.md](./data-model.md) ·
[contracts/](./contracts/) · [spec.md](./spec.md)

---

## Prerequisites

| Requirement | Why | Check |
|-------------|-----|-------|
| Windows 10/11 host | Offline servicing needs the Windows image stack (Assumptions) | `[Environment]::OSVersion` |
| **Administrator** rights | Mount/service media (FR-011, FR-019) | `Test-IsAdministrator` |
| PowerShell 7+ (`pwsh`) recommended; 5.1 supported | Primary/secondary runtimes | `$PSVersionTable.PSVersion` |
| Windows ADK **Deployment Tools** (`oscdimg`) | Bootable ISO authoring (research §5) | `Get-Command oscdimg.exe` |
| Pester v5 + PSScriptAnalyzer | Tests/lint | `Get-Module Pester,PSScriptAnalyzer -ListAvailable` |
| ~30+ GB free disk | ISO + extract + mount + output (Constraints) | `Get-PSDrive` |
| Network to Microsoft | Fido download (FR-001) | — |

`Test-BuildPrerequisite` performs these checks and fails fast with actionable messages
before any destructive work (FR-019).

---

## Scenario A — Fast quality gates (no admin, no build) — validates US3

Runs the same checks as `ci.yml`.

```powershell
# From repo root
Invoke-ScriptAnalyzer -Path . -Settings ./PSScriptAnalyzerSettings.psd1 -Recurse
Invoke-Pester -Path ./tests -Output Detailed
```

**Expected**:
- PSScriptAnalyzer reports zero errors.
- Pester passes, including `Catalog.Schema.Tests.ps1` — every catalog entry has an `Action`,
  `Description`, `Rationale`, a `Citation` (or `Unverified` + `DefaultEnabled=false`), and an
  `EvidenceGrade` (1/2/3); no grade-3 entry is `DefaultEnabled=true`.
- Deleting a `Citation` or `EvidenceGrade` from any catalog entry, or setting a grade-3 entry
  to `DefaultEnabled=true`, and re-running **fails** the suite (SC-004, SC-010, FR-009, FR-026).

---

## Scenario B — Preview / dry-run (no media changes) — validates US5, FR-016

```powershell
./build.ps1 -Architecture amd64 -WhatIf
```

**Expected**:
- A RunReport with `Outcome = Preview` lists every app it *would* remove and every tweak it
  *would* apply.
- **No** ISO is downloaded/built and no media is modified (SC-006).

---

## Scenario C — Default local build (amd64) — validates US1

```powershell
# Elevated PowerShell
./build.ps1 -Architecture amd64
```

**Expected** (SC-001, FR-005, FR-007, FR-008, FR-020):
- Downloads Windows 11 **Pro / en-US / latest**; integrity verified before servicing.
- Default provisioned bloatware removed; **Recall** and **Widgets** disabled.
- **Edge** and **OneDrive** remain present (opt-in OFF by default).
- Produces a bootable ISO under `./out/` and a compressed artifact.
- A RunReport lists each change Applied / Skipped(+reason) with citations (FR-022).

**Validate the output** (structural, FR-023):

```powershell
Import-Module ./src/WindowsIsoMaker
Test-ImageIntegrity -IsoPath ./out/Windows11-Pro-amd64-<release>.iso -Architecture amd64
```

Expected: all structural checks pass — `sources/install.wim|.esd` present with valid DISM
index, and required boot files present (`boot/bootmgr`, `efi/boot/bootx64.efi`,
`efi/microsoft/boot/efisys.bin`).

---

## Scenario D — Customization & opt-in removal — validates US4, FR-008, FR-024

Selection is data-driven (no per-feature switches). Prefer a config file; ids may also be
passed as last-mile overrides.

```powershell
# Edit config (primary interface): set Language and opt in via catalog ids
# @{ Language='nl-NL'; EnableCatalogId=@('remove-edge','remove-onedrive') }
./build.ps1 -Architecture amd64 -ConfigPath ./config/build.nl.psd1

# …or override at the CLI without editing a file:
./build.ps1 -Architecture amd64 -Language nl-NL -EnableCatalogId remove-edge,remove-onedrive
```

**Expected**:
- Image built in the selected language.
- Edge and OneDrive **removed** (their catalog entries are `DefaultEnabled=false`, enabled
  here); each removal recorded in the RunReport with citation and reversibility note
  (FR-008, FR-024, US4 scenario 3).
- No changes beyond those configured (US4 scenario 4).
- Opting in `feature-wsl` (`EnableCatalogId feature-wsl`) pre-enables WSL platform features
  offline; the RunReport notes the kernel/distro install online on first boot (FR-025).

---

## Scenario E — Idempotency — validates US5, FR-017, SC-007

Run Scenario C twice over the same inputs/working dir.

**Expected**: the second run reports already-applied changes as `AlreadyApplied` and applies
zero additional changes; output is equivalent.

---

## Scenario F — CI artifacts (amd64 + arm64) — validates US2

Manually dispatch `build-image.yml` from the Actions tab.

**Expected** (SC-002, FR-004, FR-012, FR-015):
- The workflow runs **only** on manual dispatch (a plain push does not trigger it).
- Two named, compressed artifacts are produced — one per architecture.
- The **arm64** artifact is built on the native `windows-11-arm` runner.
- Each run summary exposes the downloadable artifact(s) + RunReport.

**Skip-heavy path** (FR-014): dispatch with `skip_heavy_build=true` → preview RunReport, no
full build, while `ci.yml` tests/lint still gate the change.

---

## Scenario G — Provenance, checksums & BOMs — validates FR-027…FR-029

After a build (local or CI):

```powershell
# Autounattend generated per-arch and placed at ISO root (FR-027)
Select-Xml -Path ./out/Autounattend.xml -XPath '//*[@processorArchitecture]' |
    ForEach-Object { $_.Node.processorArchitecture }   # → amd64 (or arm64)

# Checksums (FR-028)
Get-Content ./out/SHA256SUMS

# Image BOM lists every applied change with citation + grade (FR-029)
Get-Content ./out/image-bom.md
```

**Expected**:
- `Autounattend.xml` at the ISO root has the correct `processorArchitecture`, skips OOBE, and
  (by default) bypasses the MS-account requirement + creates a local account (SC-…, FR-027).
- `SHA256SUMS` lists the produced ISO's hash; in CI, `gh attestation verify` returns a positive
  result for SLSA provenance (SC-009, FR-028).
- The Image BOM enumerates 100% of applied changes (citation + evidence grade), the base image
  version + hash, and pinned tool versions (Fido, ADK) (SC-012, FR-029).

---

## Failure-path checks — validates edge cases / FR-019, FR-020

| Trigger | Expected |
|---------|----------|
| Run without admin | Fails fast before touching media, actionable message |
| Missing `oscdimg`/ADK | Fails fast naming the missing tool |
| Insufficient disk | Detected and reported before destructive work |
| Corrupt/failed download | Build stops; does not service a corrupt source |
| Catalog entry not present in edition/arch | Recorded `NotApplicable`, build continues (FR-021) |
| Interruption mid-build | Cleanup (dismount/discard, unload hives); no corrupt output presented as success (FR-005) |

---

## Definition of done for this feature

- Scenarios A–G pass with the described outcomes.
- All spec Success Criteria (SC-001…SC-012) demonstrably met.
- Constitution gates (I–VII, v1.1.0) satisfied; any deviations recorded in plan.md Complexity
  Tracking.
