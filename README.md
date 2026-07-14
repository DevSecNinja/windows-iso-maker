# windows-iso-maker

Build a debloated, well-documented **Windows 11** installation image (ISO) for **amd64** and
**arm64** — locally or in GitHub Actions — using a modular, testable PowerShell program.

You point it at a Windows 11 ISO you supply via `IsoPath` — **required for Pro / Education /
Enterprise / …**, e.g. a business (volume) ISO from your Visual Studio or volume-licensing
subscription — or, for a **Home** build, let it auto-download the consumer ISO with
[pbatard/Fido](https://github.com/pbatard/Fido). The image is then serviced offline with DISM to
remove provisioned bloatware, apply documented registry tweaks, optionally enable features (e.g.
WSL), and repackaged into a bootable ISO with a dynamically generated `Autounattend.xml`.

> **Editions & media:** only the **Home** SKUs ship on the consumer ISO Fido can download (and
> activate with a retail generic key). Every other edition installs and activates only from the
> **business/volume ISO** with a GVLK, so supply it via `IsoPath`. See [docs/usage.md](docs/usage.md).

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

## Why windows-iso-maker (vs other image builders / debloaters)

Most tools in this space fall into a few buckets. windows-iso-maker deliberately sits at the
**offline, reproducible, auditable** end of the spectrum:

| Other approach | Examples | Common trade-off | What windows-iso-maker does instead |
|----------------|----------|------------------|--------------------------------------|
| **Post-install debloaters** | Win11Debloat, CTT WinUtil, O&O ShutUp10, BloatyNosy | Run *per machine* after Setup, so the first boot still ships bloated and results drift between machines | Bakes changes into the image **offline**, so the very first boot is already clean and identical on every machine — nothing to run per device |
| **Prebuilt "lite" ISOs** | Tiny11 & similar community spins | Opaque, hard to audit, can break Windows Update / servicing, and may bundle untrusted binaries | Starts from **official Microsoft media**, services it with **DISM** (servicing stays intact), and injects **no** third-party binaries |
| **GUI image editors** | NTLite, MSMG Toolkit | Manual, GUI-driven, hard to reproduce or run in CI; some are closed-source/paid | **Config-file + code**: versionable, Pester-tested, runs unattended in GitHub Actions, MIT-licensed |
| **Answer-file / USB tools** | Schneegans' unattend generator, Rufus | Automate the *unattended install* but don't do offline debloat or carry a documented change catalog | Combines **unattended install + offline debloat + provenance** in one pipeline |

On top of that, every build is **verifiable**: official media in, a documented change set applied,
SHA256 + SLSA provenance + a CycloneDX SBOM and an Image BOM out — and each change is **cited,
evidence-graded and reversible** (grade-3/community changes are never on by default). It's built to
be run **hands-off** (auto local or Entra account, generic/genuine product key, opt-in Hyper-V or
VMware boot test) and **repeatably** (locally or in CI, amd64 and arm64), not clicked through once by hand.

## Quick start (local, on Windows)

Requires Windows with administrator rights, PowerShell 5.1+/7+, and the Windows ADK
"Deployment Tools" (for `oscdimg`).

```powershell
# Build Windows 11 Home from the auto-downloaded consumer ISO (fully hands-off)
./build.ps1 -Edition Home -UseGenericProductKey

# Build Pro / Education / Enterprise from a business (volume) ISO you supply
./build.ps1 -Edition Pro -IsoPath 'C:\isos\Win11_24H2_Business_x64.iso' -UseGenericProductKey

# Preview only (no download/build) — shows exactly what would change
./build.ps1 -Edition Home -WhatIf

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
.github/workflows/            # ci.yml (lint+test+SBOM) and build-image.yml (manual matrix)
specs/                        # Spec-Driven Development artifacts (spec, plan, tasks, ...)
docs/                         # This documentation
```

## Building blocks

- **Config-driven** selection via named `Profile`s (`minimal`/`default`/`aggressive`/`gaming`/`opinionated`), a
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

This repository is MIT-licensed. For a **Home** build it can invoke `pbatard/Fido` (a separate
GPLv3 work) as an external program to download the consumer ISO; rather than vendoring it, the
pinned `Fido.ps1` (see the commit in the module manifest `RequiredToolingMinimums`) is downloaded at
build time from `raw.githubusercontent.com` and cached. Business editions bypass Fido entirely (you
supply the ISO via `IsoPath`). See [docs/provenance-bom.md](docs/provenance-bom.md) for the
licensing/attribution note.
