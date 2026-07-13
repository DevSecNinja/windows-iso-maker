# CI / GitHub Actions

Two workflows implement the CI requirements. Both call the **same shipped module functions**
used locally — there is no CI-only build logic (Principle V, FR-010). Every `uses:` action is
pinned by commit SHA and kept current by Renovate (Principle VII, FR-031).

## `ci.yml` — tests & lint (every change)

- **Triggers**: `push` (all branches) and `pull_request`.
- **Runner**: `windows-latest`.
- **Steps**: install Pester v5 + PSScriptAnalyzer → run PSScriptAnalyzer with
  `PSScriptAnalyzerSettings.psd1` (scans `./src`, `./tests`, `./build.ps1`) → run the
  Pester v5 suite (NUnit results uploaded) → generate the repository/tooling **CycloneDX SBOM**
  via `anchore/sbom-action`.
- **Gate**: any lint error/warning or failing test fails the job. The catalog documentation
  gate ([Catalog.Schema.Tests.ps1](../tests/Catalog.Schema.Tests.ps1)) fails the build if any
  entry lacks an `Action`/`Citation`/`EvidenceGrade`, or if a grade-3 entry is default-enabled.
- **Never** downloads or builds an ISO.

## `build-image.yml` — release image build (manual)

- **Trigger**: `workflow_dispatch` **only** — never on push/PR (FR-012).
- **Inputs**: `edition`, `language`, `release`, `profile`, `enable_catalog_id`,
  `disable_catalog_id`, `skip_heavy_build`, `boot_test`. There are deliberately **no**
  `remove_edge`/`remove_onedrive` inputs — pass `enable_catalog_id: remove-edge,remove-onedrive`
  instead (data-driven selection, FR-024).
- **Product key (optional secret)**: CI ships **no product key by default** — a keyless build
  installs the metadata-selected edition hands-off (the OS is simply unlicensed until a key is
  entered). If you want a keyed/activated build, set the optional
  `WINDOWS_PRODUCT_KEY` repo secret; the build step reads it from an environment variable (so the
  key is masked and never appears on a command line) and passes it as `-ProductKey` (applied in the
  `specialize` pass). Leaving the secret unset keeps the key out of CI entirely.
- **Permissions** (least privilege): `contents: read`, plus `id-token: write` and
  `attestations: write` for provenance/OIDC.
- **Matrix**:
  | `arch` | `runs-on` |
  |--------|-----------|
  | `amd64` | `windows-latest` |
  | `arm64` | `windows-11-arm` (native Windows-on-ARM) |
- **Per-leg steps**: checkout → install Windows ADK Deployment Tools (`oscdimg`) → verify free
  disk (fail fast) → `./build.ps1` (produces ISO + `Autounattend.xml` + `SHA256SUMS` +
  RunReport + Image BOM) → `actions/attest-build-provenance` (SLSA) → publish to Azure Blob
  (optional, OIDC) **or** fall back to a per-arch workflow artifact.

### Installing the ADK

The workflow installs the Windows ADK "Deployment Tools" feature quietly:

```powershell
Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2289980' -OutFile adksetup.exe
Start-Process adksetup.exe -Wait -ArgumentList '/quiet','/norestart','/features','OptionId.DeploymentTools'
```

`oscdimg` is then found under
`C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\<arch>\Oscdimg`.
`OscdimgPath` in the config is left empty so it is auto-detected.

## Runner limits & risks

- **Disk**: a full build needs the base ISO (~5–7 GB) + extracted media + mounted image +
  output ISO, which can strain `windows-latest` free space. The job checks free space and fails
  fast; use `skip_heavy_build: true` for a green preview-only run, or upload to Azure Blob
  ([azure-upload.md](azure-upload.md)) if artifacts are too large.
- **Time**: within the 6-hour job cap, but monitored.
- **arm64 tooling**: ADK/`oscdimg`/PowerShell availability on `windows-11-arm` should be
  verified for your ADK version; `adksetup` runs under emulation on that runner.
- **No secrets by default**: the build needs none. Azure upload uses OIDC federation (no stored
  keys) and is skipped unless the `AZURE_*` repository variables are set. The only optional secret
  is `WINDOWS_PRODUCT_KEY` (see above), used solely for a keyed non-Home build; leave it unset to
  keep product keys out of CI.

## Parity guarantee

`build-image.yml` and local `build.ps1` both call `Invoke-IsoBuild`. CI only adds environment
setup (ADK, disk check), provenance/SBOM emission, and artifact upload around that one shared
build path.
