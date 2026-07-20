# Copilot instructions for windows-iso-maker

A modular, testable PowerShell program that downloads, **offline-debloats** (DISM), and
repackages **Windows 11** installation media (amd64 + arm64) with fully documented, reversible,
citation-backed system changes. The same code path runs locally and in GitHub Actions.

## Architecture (the big picture)

- **Thin dispatchers → single module.** `build.ps1` and `post-install.ps1` contain *no* build
  logic; they import `src/WindowsIsoMaker` and forward to `Invoke-IsoBuild` /
  `Invoke-PostInstallSetup`. Local and CI runs share exactly one build path (never add CI-only
  logic that bypasses the module).
- **Module layout** (`src/WindowsIsoMaker/`): `WindowsIsoMaker.psm1` dot-sources every `Private/`
  helper first, then every `Public/` function, and exports only the functions listed in
  `WindowsIsoMaker.psd1`'s `FunctionsToExport`. Adding a public function means: new file in
  `Public/`, add it to the manifest, add a `*.Tests.ps1`.
- **Config file is the primary interface.** `config/build.config.psd1` (schema v2) drives a build;
  CLI params and `WIM_*` env vars are last-mile overrides. Precedence (later wins):
  **config-file defaults → `WIM_*` env vars → explicit parameters.** `Get-BuildConfiguration`
  re-applies the full precedence chain.
- **Data-driven change catalog.** All changes live in `config/catalog.*.psd1` (registry / appx /
  capabilities), NOT inline. `Invoke-CatalogEntry` is the single dispatcher routing each entry by
  its `Action` to a handler (`SetRegistry`→`Set-RegistryTweaks`, `RemoveAppx`/`RemoveCapability`→
  `Remove-Bloatware`, `EnableOptionalFeature`/`AddCapability`→`Enable-WindowsFeature`).
- **Selection logic** lives in `Resolve-CatalogSelection.ps1`: `Profile`
  (`minimal`/`default`/`aggressive`/`gaming`/`opinionated`, unioned as a list) + `Toggles` map +
  `EnableCatalogId`/`DisableCatalogId` (explicit ids win). Note the schema `Category` field is for
  display/grouping only — selection keys off the separate `Profiles` field.
- **Offline vs online parity.** The `post-install.ps1` path (`Invoke-OnlinePostInstall`) applies
  the *same* catalog to a running OS via `dism /online`, mirroring the offline build.

## Non-negotiable convention: every change is documented

This is the project's core differentiator (see `.specify/memory/constitution.md`, Principle II).
Every catalog entry MUST carry: `Action`, `Description` (what), `Rationale` (why), `Citation`
(authoritative URL), and `EvidenceGrade` (1 = official Microsoft, 2 = reputable third-party,
3 = community). **Grade-3 entries MUST be `DefaultEnabled = $false`.** `tests/Catalog.Schema.Tests.ps1`
is the merge-blocking gate that fails CI on any missing field or grade-3-default-on entry.

**Add a new tweak by adding a catalog entry — never a new per-feature switch/parameter**
(e.g. `-EnableWsl`, `-RemoveEdge` are explicitly rejected in review). Removal of impactful
first-party components (Edge/OneDrive/Recall/Widgets) must be opt-in and default OFF.

## PowerShell code rules (enforced by PSScriptAnalyzer + review)

- Approved verbs + PascalCase; `[CmdletBinding()]` on every function; explicit param types +
  validation attributes (`[ValidateSet()]`, `[ValidateNotNullOrEmpty()]`).
- State-changing functions MUST `SupportsShouldProcess` and gate mutations behind
  `$PSCmdlet.ShouldProcess(...)` (so `-WhatIf` works); operations must be idempotent.
- `Set-StrictMode -Version Latest` + `$ErrorActionPreference = 'Stop'`; `throw` on unrecoverable
  errors; `try/catch` with `-ErrorAction Stop` on risky calls.
- **Aliases are forbidden** in committed code (`%`, `?`, `ls`, `cat`, etc.) — use full cmdlet and
  parameter names. Comment-based help (`.SYNOPSIS`/`.DESCRIPTION`/`.PARAMETER`/`.EXAMPLE`) is
  required on every exported function.
- Architecture is always a first-class `[ValidateSet('amd64','arm64')]` input, never hardcoded.
- Files are UTF-8 **without BOM** (deliberate cross-platform choice; `PSUseBOMForUnicodeEncodedFile`
  is excluded). Indent with spaces.

## Build / test / lint

Lint and tests run on any OS (DISM/`oscdimg`/`reg`/Fido are all mocked); the actual image build is
Windows + admin only.

```powershell
# Lint (must be zero Error/Warning findings)
Invoke-ScriptAnalyzer -Path ./src,./tests,./build.ps1,./post-install.ps1 -Recurse -Settings ./PSScriptAnalyzerSettings.psd1

# Full test suite
Invoke-Pester -Configuration (./tests/PesterConfiguration.ps1)

# Single test file
Invoke-Pester -Path ./tests/Catalog.Schema.Tests.ps1 -Output Detailed
```

- Tests are **Pester v5** (min 5.5.0). Each public function has a matching `tests/<Name>.Tests.ps1`;
  private helpers and internals are reached via `InModuleScope`. Windows-only servicing paths are
  validated through mocks + the manual `build-image.yml` workflow.
- CI (`.github/workflows/ci.yml`) runs lint + Pester + SBOM on every push/PR and never downloads or
  builds an image. `build-image.yml` is the manual (`workflow_dispatch`) matrix build.

## Supply chain

GitHub Actions are pinned by full commit SHA (kept current by `renovate.json5`). Tooling minimums
(Pester, PSScriptAnalyzer, ADK, and the pinned Fido tag/commit) are declared in the manifest's
`RequiredToolingMinimums`. Releases emit SHA256 checksums, SLSA provenance, a CycloneDX SBOM, and an
Image BOM enumerating every applied change with its citation + evidence grade.

## Where to look

- `docs/` — usage, post-install, change-rationale, evidence-grading, autounattend, provenance-bom.
- `.specify/memory/constitution.md` — the authoritative 7-principle ruleset all changes must satisfy.
- `specs/` — Spec-Driven Development artifacts (spec / plan / tasks) behind features.
