# windows-iso-maker

Build a debloated, well-documented **Windows 11** installation image (ISO) for **amd64** and
**arm64** — locally or in GitHub Actions — using a modular, testable PowerShell program.

The base ISO is fetched with [pbatard/Fido](https://github.com/pbatard/Fido); the image is
serviced offline with DISM to remove provisioned bloatware, apply documented registry tweaks,
optionally enable features (e.g. WSL), and repackaged into a bootable ISO with a dynamically
generated `Autounattend.xml`.

## Why this project is different

Most debloaters apply registry keys and app removals with no explanation. Here **every change
is a data-driven catalog entry** that MUST carry:

- **What** it does (`Description`)
- **Why** it is safe/desirable (`Rationale`)
- **A citation** (`Citation`) to an authoritative source
- **An evidence grade** (`EvidenceGrade`: 1 = Microsoft official, 2 = reputable third-party,
  3 = community/forum). Grade-3 changes may never be enabled by default.

Adding a new tweak means adding a catalog entry — not writing new code or a new switch.
See [docs/change-rationale.md](docs/change-rationale.md) and
[docs/evidence-grading.md](docs/evidence-grading.md).

## Quick start (local, on Windows)

Requires Windows with administrator rights, PowerShell 5.1+/7+, and the Windows ADK
"Deployment Tools" (for `oscdimg`).

```powershell
# Build the default amd64 image using config/build.config.psd1
./build.ps1

# Preview only (no download/build) — shows exactly what would change
./build.ps1 -WhatIf

# Build arm64, enable the opt-in WSL feature, keep a saved profile file
./build.ps1 -ConfigPath config/build.arm64.psd1 -EnableCatalogId feature-wsl
```

The **configuration file is the primary interface** (see [docs/usage.md](docs/usage.md)); CLI
parameters are optional last-mile overrides.

## Documentation

| Topic | Doc |
|-------|-----|
| Local usage & configuration | [docs/usage.md](docs/usage.md) |
| Change catalog & rationale | [docs/change-rationale.md](docs/change-rationale.md) |
| Evidence grading | [docs/evidence-grading.md](docs/evidence-grading.md) |
| CI / GitHub Actions | [docs/ci.md](docs/ci.md) |
| Autounattend.xml generation | [docs/autounattend.md](docs/autounattend.md) |
| Windows Subsystem for Linux | [docs/wsl.md](docs/wsl.md) |
| Provenance, checksums & BOM/SBOM | [docs/provenance-bom.md](docs/provenance-bom.md) |
| Azure Blob upload | [docs/azure-upload.md](docs/azure-upload.md) |

## Repository layout

```
build.ps1                     # Thin local entry point -> Invoke-IsoBuild
config/                       # build.config.psd1 + catalog.*.psd1 (the change catalog)
src/WindowsIsoMaker/          # The PowerShell module (Public/ + Private/)
templates/autounattend/       # Autounattend.xml template
tests/                        # Pester v5 tests (incl. the catalog documentation gate)
vendor/fido/                  # Vendored, pinned pbatard/Fido (GPLv3) + LICENSE/NOTICE
.github/workflows/            # ci.yml (lint+test+SBOM) and build-image.yml (manual matrix)
specs/                        # Spec-Driven Development artifacts (spec, plan, tasks, ...)
docs/                         # This documentation
```

## Building blocks

- **Config-driven** selection via named `Profile`s (`minimal`/`default`/`aggressive`), a
  `Toggles` map, and `EnableCatalogId`/`DisableCatalogId` lists.
- **Cross-architecture**: amd64 on `windows-latest`, arm64 on native `windows-11-arm` runners.
- **Verifiable builds**: SHA256 checksums + SLSA build provenance + a CycloneDX SBOM and an
  Image BOM enumerating every applied change.
- **Safe**: dry-run/`-WhatIf`, idempotent, guaranteed cleanup on failure, impactful removals
  (Edge/OneDrive) opt-in and off by default.

## Development

```powershell
Invoke-ScriptAnalyzer -Path ./src,./tests,./build.ps1 -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-Pester -Configuration (New-PesterConfiguration @{ Run = @{ Path = './tests' } })
```

Both run on Linux (DISM/oscdimg are mocked in tests); the actual image build is Windows-only.

## License

This repository is MIT-licensed. The vendored `vendor/fido/Fido.ps1` is a separate GPLv3 work
invoked as an external program; see [vendor/fido/NOTICE](vendor/fido/NOTICE).
