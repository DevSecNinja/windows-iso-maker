# Tests

Pester v5 unit tests for the `WindowsIsoMaker` module. All Windows-servicing calls
(DISM cmdlets, `reg`, `oscdimg`, Fido) are **mocked**, so the whole suite runs on any
platform (Windows, Linux, macOS) with PowerShell 7+ and Pester v5 — no admin rights and
no real image servicing required.

## Running locally

```powershell
# From the repository root:
$config = ./tests/PesterConfiguration.ps1
Invoke-Pester -Configuration $config
```

Or run a single test file:

```powershell
Invoke-Pester -Path ./tests/Catalog.Schema.Tests.ps1 -Output Detailed
```

## What is covered

| Test file | Focus |
|-----------|-------|
| `Catalog.Schema.Tests.ps1` | Every catalog entry has Description/Rationale/Citation; unique Id; Arch subset; registry Target shape; the merge-blocking gate (Principle II). |
| `Get-BuildConfiguration.Tests.ps1` | Config file is the primary interface; precedence (file -> env -> params); `-ConfigPath`/`WIM_CONFIG_PATH`; validation; include/exclude + opt-in removals. |
| `Get-Windows11Iso.Tests.ps1` | Fido arg mapping (mocked); `IsoPath` override; unavailable combo -> terminating error. |
| `Remove-Bloatware.Tests.ps1` | Mocked appx cmdlets; NotApplicable skip; `-WhatIf`; arch filtering; idempotency. |
| `Set-RegistryTweaks.Tests.ps1` | Mocked hive load/unload; Recall+Widgets applied; `-WhatIf`; hives always unloaded on failure. |
| `New-BootableIso.Tests.ps1` | Mocked oscdimg; arch -> boot-arg selection; missing oscdimg -> error. |
| `Invoke-IsoBuild.Tests.ps1` | Orchestration order; preconditions gate; RunReport emitted. |
| `Invoke-IsoBuild.Preview.Tests.ps1` | Preview modifies nothing; idempotent re-run; failure cleanup. |
| `Test-ImageIntegrity.Tests.ps1` | Missing boot file -> fail; structural checks; `BootTest` off by default. |

## Notes

* Tests that assert real DISM/`reg`/`oscdimg`/VM-boot behavior are **runtime-only** and
  can only be fully exercised on an elevated Windows host; those paths are validated here
  via mocks and by the manual `build-image.yml` workflow.
* The catalog schema gate (`Catalog.Schema.Tests.ps1`) is the enforcement point for
  Constitution Principle II and runs in `ci.yml` on every push/PR.
