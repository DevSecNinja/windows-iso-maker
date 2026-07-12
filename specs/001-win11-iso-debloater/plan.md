# Implementation Plan: Windows 11 ISO Builder & Debloater

**Branch**: `001-win11-iso-debloater` | **Date**: 2026-07-11 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-win11-iso-debloater/spec.md`

## Summary

Deliver a modular PowerShell program that downloads a Windows 11 base ISO (via a pinned,
vendored `pbatard/Fido`), offline-services the image with DISM to apply a **data-driven,
citation-backed, evidence-graded** change catalog — removals (appx/capabilities), registry
tweaks (incl. disabling Recall and Widgets), and additive enables (Windows optional features
like WSL, opt-in) — all dispatched by `Action` with no per-feature switches. It then generates a
per-architecture `Autounattend.xml` from the same config, repackages a bootable UEFI ISO per
architecture with `oscdimg`, emits SHA256 checksums + an Image BOM, and compresses it as an
artifact. The same shipped module functions run locally (via `build.ps1`) and in GitHub
Actions: a fast `ci.yml` (PSScriptAnalyzer + Pester v5 + catalog/evidence-grade gate + repo
SBOM on every push/PR) and a manual-dispatch `build-image.yml` matrix (amd64 on
`windows-latest`, arm64 on native `windows-11-arm`) that adds SLSA build provenance and an
optional OIDC Azure Blob upload (falling back to workflow artifacts). Every mutating operation
supports `-WhatIf`, is idempotent, and emits an auditable run report. Change selection is via
`Profile` + `Toggles` + `EnableCatalogId`/`DisableCatalogId`; Edge/OneDrive/WSL removal/enable
is opt-in and OFF by default. Dependencies are SHA-pinned and kept current by `renovate.json5`.

## Technical Context

**Language/Version**: PowerShell 7+ (`pwsh`) as primary; Windows PowerShell 5.1
compatibility validated for DISM-dependent paths. `Set-StrictMode -Version Latest`.

**Primary Dependencies**:
- `Dism` PowerShell module cmdlets (`Mount-WindowsImage`, `Get-AppxProvisionedPackage`,
  `Remove-AppxProvisionedPackage`, `Add-`/`Remove-WindowsCapability`,
  `Enable-WindowsOptionalFeature`, `Dismount-WindowsImage`) with `dism.exe` fallback where
  module coverage is incomplete.
- `oscdimg.exe` from Windows ADK **Deployment Tools** (bootable UEFI ISO authoring).
- Vendored `pbatard/Fido` `Fido.ps1` (pinned tag `v1.70`, recorded in `vendor/fido/VERSION`)
  for ISO URL resolution/download.
- Pester v5, PSScriptAnalyzer (pinned minimum versions via manifest / CI).
- CI-only (SHA-pinned) actions: `actions/checkout`, `actions/upload-artifact`,
  `actions/attest-build-provenance` (SLSA provenance), `anchore/sbom-action` (repo SBOM),
  `azure/login` + `az storage blob upload` (optional OIDC upload). Updated by
  `renovate.json5`.

**Storage**: Filesystem only — working directories for downloaded ISO, extracted media,
mount points, offline hive mounts, output ISO, and compressed artifact. No database.
Data-driven change catalog stored as versioned config files (`PSD1`/`JSON`). Autounattend
templates under `templates/autounattend/`.

**Testing**: Pester v5 (unit, mocked DISM/`reg`) + PSScriptAnalyzer with
`PSScriptAnalyzerSettings.psd1`. Catalog schema tests assert Action + What/Why/Citation +
EvidenceGrade on every entry and enforce the grade-3 opt-in gate. No heavy ISO build in
`ci.yml`.

**Target Platform**: Windows only (offline servicing requires the Windows image-servicing
stack). Build hosts: `windows-latest` (amd64) and native `windows-11-arm` (arm64) runners,
plus local Windows admin machines.

**Project Type**: PowerShell module + CLI entry script (single-project layout).

**Performance Goals**: Not throughput-bound. Target: `ci.yml` (lint + tests) completes in
minutes; full image build fits within GitHub-hosted runner disk (~14 GB usable on
`windows-latest`) and time (6 h job cap) limits, with a documented "skip heavy build" path.

**Constraints**: Runner disk headroom is the dominant constraint (base ISO ~5–7 GB +
extracted media + mounted image + output ISO). Must fail fast on insufficient disk,
missing admin rights, or missing servicing tooling before any destructive work. Fido is
GPLv3 — kept as a separately invoked script, not linked/embedded. All GitHub Actions are
SHA-pinned; Azure upload is optional and secretless (OIDC).

**Scale/Scope**: One module (~13 public functions + private helpers incl. an Action
dispatcher), one change catalog (dozens of entries, each Action/Citation/EvidenceGrade),
autounattend templates, two workflows, one local entry script. Two architectures (amd64,
arm64), configurable edition/language/release.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Verify this plan against the Windows ISO Maker Constitution (v1.1.0):

- [x] **I. Modularity & PowerShell Best Practices** — PASS. All logic ships as functions in
  the `WindowsIsoMaker` module (`.psm1`/`.psd1`), approved verbs + PascalCase,
  comment-based help, `[CmdletBinding(SupportsShouldProcess)]`, typed/validated params,
  `Set-StrictMode -Version Latest`, no aliases. `build.ps1` is a thin dispatcher only.
- [x] **II. Documentation-Backed System Changes (v1.1.0)** — PASS. Every appx/capability/
  optional-feature/registry change lives in the data-driven catalog under `config/` with
  Id/**Action**/Description (What)/Rationale (Why)/**Citation**/**EvidenceGrade**/Reversible/
  DefaultEnabled/Arch. **Evidence-grade gate**: a grade-3 (community/forum) entry MUST have
  `DefaultEnabled=false`; entries missing Citation or EvidenceGrade fail CI. The change model is
  generalized (removals + additive enables like WSL) and selected by `Profile`/`Toggles`/
  `EnableCatalogId`/`DisableCatalogId` via an `Action` dispatcher — **no per-feature switches**
  (RemoveEdge/RemoveOneDrive retired to catalog entries). Enforced by `Catalog.Schema.Tests.ps1`.
- [x] **III. Testing Discipline** — PASS. Pester v5 + PSScriptAnalyzer planned; catalog
  schema + evidence-grade lint tested; `ci.yml` runs on every commit/PR; test-first for new
  public functions via mocked DISM/`reg`/`Enable-WindowsOptionalFeature`.
- [x] **IV. Cross-Architecture Support** — PASS. Single code base; architecture is
  `[ValidateSet('amd64','arm64')]` config, not hardcoded; arm64 built on native
  `windows-11-arm` runner; arch-specific boot data (`efisys.bin`/`bootaa64.efi`), arch-scoped
  catalog entries, and per-arch `Autounattend.xml` (`processorArchitecture`) handled explicitly.
- [x] **V. Reproducibility & Local Parity** — PASS. Config-driven
  (`config/build.config.psd1`), pinned Fido tag + declared tool/module versions; local
  and CI both call `Invoke-IsoBuild`. No CI-only build path. Dependencies SHA-pinned and
  auto-updated via `renovate.json5`.
- [x] **VI. Safety & Reversibility** — PASS. All mutations `SupportsShouldProcess`
  (`-WhatIf`), idempotent, scoped to working dirs/mounted image. Edge/OneDrive/WSL are
  `DefaultEnabled=false` opt-in catalog entries; Recall & Widgets disable are in the default
  profile per FR-007 — a deliberate, spec-mandated, reversible-tweak choice, documented in the
  catalog. Grade-3 entries are opt-in only.
- [x] **VII. Security & Input Validation + Supply-Chain Integrity & Provenance (v1.1.0)** —
  PASS. No secrets in code/logs; edition/lang/release/arch/paths/catalog-ids validated;
  downloaded ISO integrity-checked before servicing; media treated as untrusted; OWASP guidance
  applied (array-arg DISM/Fido invocation, no shell-string injection). **Supply chain**: builds
  emit SLSA provenance (`actions/attest-build-provenance`) + SHA256SUMS per ISO; a repo SBOM
  (CycloneDX via `anchore/sbom-action`) and an Image BOM (`Export-ImageBom`, derived from the
  RunReport with citation+grade + base-image version/hash + pinned tool versions) are published;
  dependencies (incl. vendored Fido) are pinned and Renovate-updated; all Actions SHA-pinned;
  optional Azure upload is secretless (OIDC).

No unresolved FAILs. See **Complexity Tracking** for justified deviations (none blocking).

## Project Structure

### Documentation (this feature)

```text
specs/001-win11-iso-debloater/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output (function + catalog + config + workflow contracts)
│   ├── module-functions.md
│   ├── change-catalog.schema.json
│   ├── build-config.schema.md
│   └── workflows.md
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 output (/speckit.tasks — NOT created here)
```

### Source Code (repository root)

```text
build.ps1                              # Root entry: admin-elevation check → Invoke-IsoBuild

src/
└── WindowsIsoMaker/
    ├── WindowsIsoMaker.psd1           # Manifest (pinned version, exported fns, min PS ver)
    ├── WindowsIsoMaker.psm1           # Loader (dot-sources Public/Private, exports Public)
    ├── Public/
    │   ├── Get-Windows11Iso.ps1       # Fido wrapper (edition/language/release/arch params)
    │   ├── Invoke-IsoBuild.ps1        # Orchestrator (local + CI entry)
    │   ├── Expand-WindowsImage.ps1    # Extract ISO media to working dir
    │   ├── Mount-WindowsBuildImage.ps1# Mount install.wim/.esd index for servicing
    │   ├── Invoke-CatalogEntry.ps1    # Action dispatcher (Remove/Set/Enable/Add) — FR-024/025
    │   ├── Remove-Bloatware.ps1       # Handler: RemoveAppx/RemoveCapability from catalog
    │   ├── Set-RegistryTweaks.ps1     # Handler: SetRegistry (offline-hive) from catalog
    │   ├── Enable-WindowsFeature.ps1  # Handler: EnableOptionalFeature/AddCapability (WSL) — FR-025
    │   ├── New-AutounattendXml.ps1    # Per-arch Autounattend.xml from config/template — FR-027
    │   ├── New-BootableIso.ps1        # oscdimg → bootable UEFI ISO (+ Autounattend + SHA256SUMS)
    │   ├── Compress-BuildArtifact.ps1 # Zip/7z final ISO
    │   ├── Test-ImageIntegrity.ps1    # Structural checks (+ optional opt-in VM boot)
    │   ├── Export-ImageBom.ps1        # Image BOM (CycloneDX + md) from RunReport — FR-029
    │   └── Get-BuildConfiguration.ps1 # Load/merge config (defaults ← file ← params/env)
    └── Private/
        ├── Write-BuildLog.ps1         # Structured logging helper
        ├── Test-IsAdministrator.ps1   # Admin/elevation precondition check
        ├── Test-BuildPrerequisite.ps1 # Disk space / ADK / DISM / tooling checks
        ├── Resolve-CatalogSelection.ps1 # Effective enabled set: Profile+Toggles+Enable/Disable
        ├── Mount-OfflineRegistryHive.ps1   # reg load into temp mount point
        ├── Dismount-OfflineRegistryHive.ps1# reg unload (with GC/retry)
        ├── Invoke-Dism.ps1            # dism.exe fallback wrapper (validated args)
        └── New-RunReport.ps1          # Build the auditable run report object/file

config/
├── build.config.psd1                  # Defaults: edition=Pro, language=en-US, release=latest, profile, toggles
├── catalog.appx.psd1                  # RemoveAppx entries (Action/EvidenceGrade)
├── catalog.capabilities.psd1          # RemoveCapability + EnableOptionalFeature/AddCapability (WSL), arch-scoped
└── catalog.registry.psd1              # SetRegistry entries (Recall, Widgets, privacy, ...)

templates/
└── autounattend/                      # Autounattend.xml templates (per-arch fragments) — FR-027
    ├── autounattend.amd64.xml.template
    └── autounattend.arm64.xml.template

tests/
├── Catalog.Schema.Tests.ps1           # Action + Description/Rationale/Citation + EvidenceGrade; grade-3 opt-in gate
├── Get-BuildConfiguration.Tests.ps1   # Config load/merge/override + catalog selection precedence
├── Invoke-CatalogEntry.Tests.ps1      # Action → handler routing; unknown Action throws
├── Remove-Bloatware.Tests.ps1         # Mocked DISM; idempotency; not-applicable skip
├── Set-RegistryTweaks.Tests.ps1       # Mocked reg/hive; -WhatIf; idempotency
├── Enable-WindowsFeature.Tests.ps1    # Mocked Enable-WindowsOptionalFeature; WSL opt-in; idempotency
├── New-AutounattendXml.Tests.ps1      # Per-arch processorArchitecture; MS-acct bypass; OOBE skip
├── Export-ImageBom.Tests.ps1          # BOM lists every applied change w/ citation+grade
├── Invoke-IsoBuild.Tests.ps1          # Orchestration + preconditions (mocked)
└── Test-ImageIntegrity.Tests.ps1      # Structural check logic

docs/
├── usage.md                           # Quick-start & parameters
├── change-rationale.md                # Human-readable catalog rationale/citations
└── ci.md                              # Runner limits, ADK install, skip-heavy-build path

vendor/
└── fido/
    ├── Fido.ps1                        # Pinned pbatard/Fido (commit recorded)
    ├── LICENSE                         # GPLv3 (Fido's license, preserved)
    └── VERSION                         # Pinned commit/tag + upstream URL

.github/workflows/
├── ci.yml                             # PSScriptAnalyzer + Pester v5 + catalog/evidence gate + repo SBOM (anchore/sbom-action)
└── build-image.yml                    # workflow_dispatch matrix: amd64 + arm64; SLSA provenance + SHA256SUMS + optional OIDC Azure upload

renovate.json5                         # Dependency updates: shared DevSecNinja presets + SHA-pin Actions + vendored Fido tag (FR-031)
PSScriptAnalyzerSettings.psd1          # Lint rule configuration
```

**Structure Decision**: Single-project PowerShell module layout. The `WindowsIsoMaker`
module under `src/` holds all shipped logic (Public/Private split per Principle I).
`build.ps1` is a thin local entry point that performs the elevation check and calls the
same `Invoke-IsoBuild` used by CI (Principle V). All system changes are externalized to
`config/` catalog data and dispatched by `Action` through `Invoke-CatalogEntry`, so new
features are catalog edits, not new code paths (Principle II/FR-024). Install-time behavior
is generated per-arch by `New-AutounattendXml` from `templates/autounattend/` (FR-027).
Provenance/BOM: `Export-ImageBom` derives the Image BOM from the RunReport, while CI emits
SLSA provenance + SHA256SUMS and a repo SBOM (Principle VII). Fido is isolated under
`vendor/fido/` with its GPLv3 license preserved and invoked as a separate script;
`renovate.json5` keeps SHA-pinned Actions and the vendored Fido tag current (FR-031).

## Complexity Tracking

> Constitution Check passed with no blocking violations. The items below are noted
> deviations/risks tracked for transparency, each with justification; none require waiving
> a principle.

| Item | Why Needed | Simpler Alternative Rejected Because |
|------|------------|--------------------------------------|
| `dism.exe` fallback alongside `Dism` module cmdlets | Some servicing operations lack full/parity module coverage across PS 5.1/7 | Module-only path leaves gaps (e.g. certain capability/ESD ops); a validated wrapper keeps behavior deterministic |
| Recall & Widgets disabled in default profile (impactful tweaks ON by default) | FR-007 mandates it; both are reversible registry/policy tweaks, not component removal | Making them opt-in would violate the spec; they are documented + reversible, unlike Edge/OneDrive removal which stays opt-in |
| Vendoring GPLv3 Fido into the repo | Reproducibility/pinning requires a fixed version; network fetch at build time is less deterministic | Downloading latest Fido at runtime breaks pinning (Principle V) and supply-chain hygiene (Principle VII) |
| ADK/`oscdimg` external dependency | Only supported tool to author a bootable UEFI Windows ISO with correct boot data | No pure-PowerShell equivalent produces correctly bootable UEFI media |
| `Action` dispatcher (`Invoke-CatalogEntry`) as an extra indirection | FR-024/025 require data-driven selection with no per-feature switches and additive actions (WSL) | One switch/parameter per feature explodes the surface and violates Principle II; a dispatcher isolates new Action types to one branch |
| ADK-independent extra CI actions (attest-build-provenance, sbom-action, azure/login) | FR-028/029/030 + Principle VII require provenance, SBOM/BOM, and optional durable upload | Skipping them fails the supply-chain gate; they are SHA-pinned and Azure is optional/secretless |

## Cross-Architecture & Runner Risk Notes

- **arm64 native runners**: `windows-11-arm` GitHub-hosted runners are required (FR-004);
  ADK/`oscdimg` and PowerShell tooling availability on that image must be verified. If a
  tool is missing, document a fallback install step. Tracked in research.md.
- **ADK install in CI**: ADK is a large, external installer; CI installs only the
  Deployment Tools feature to save time/disk. Pin the ADK version. See docs/ci.md.
- **Disk headroom**: Base ISO + extracted media + mount + output ISO can exceed runner
  free space; `build-image.yml` cleans intermediate artifacts and the module fails fast on
  insufficient disk. The "skip heavy build" path keeps PR CI green without a full build.
- **arch-specific boot data**: amd64 uses `etfsboot.com` + `efisys.bin`; arm64 uses the
  EFI-only boot layout (`bootaa64.efi`). `New-BootableIso` selects boot data by arch.
- **WSL online first boot**: enabling `Microsoft-Windows-Subsystem-Linux` +
  `VirtualMachinePlatform` offline only pre-enables the platform; the WSL kernel and any Linux
  distribution download online on first boot (a Windows constraint). Documented in the catalog
  entry so users are not surprised; WSL ships opt-in (`DefaultEnabled=false`).
- **arm64 unattend specifics**: `Autounattend.xml` is arch-specific — `processorArchitecture`
  must be `arm64` (not `amd64`) and disk/boot components differ; `New-AutounattendXml` renders
  per-arch from `templates/autounattend/` and is validated by tests.
- **Azure OIDC optionality**: the Azure Blob upload is optional and gated on repo variables
  (`vars.AZURE_STORAGE_ACCOUNT`/`vars.AZURE_STORAGE_CONTAINER` + OIDC
  `AZURE_CLIENT_ID`/`AZURE_TENANT_ID`/`AZURE_SUBSCRIPTION_ID`); when unset the build falls back
  to `actions/upload-artifact`. No stored secrets. Requires the consumer to configure Azure
  federation; otherwise it is a no-op.
- **GPLv3 boundary unchanged**: Fido remains a vendored, pinned, separately-invoked GPLv3
  script (not embedded/linked); the module calls it as an external tool. This v1.1.0 refresh
  does not alter that licensing boundary.
