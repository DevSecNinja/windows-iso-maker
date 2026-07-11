# Contract: GitHub Actions Workflows

Two workflows realize the CI requirements. They MUST call the same shipped module functions
used locally (Principle V, FR-010) — no CI-only build logic.

**Supply-chain rules (all workflows)**: every `uses:` action MUST be pinned by full commit
SHA (not a mutable tag/branch), per constitution v1.1.0 Principle VII. `renovate.json5`
(extends the shared `github>DevSecNinja/.github//.renovate/*` presets +
`helpers:pinGitHubActionDigests`) keeps those digests current and tracks the pinned Fido tag
in `vendor/fido/VERSION` (FR-031).

---

## `ci.yml` — Tests & Lint (fast, every change)

**Triggers**: `push` (all branches) and `pull_request`. (FR-013, SC-005)

**Runner**: `windows-latest`.

**Contract**:
| Aspect | Requirement |
|--------|-------------|
| Purpose | PSScriptAnalyzer + Pester v5 only; **no** ISO download/build |
| Steps | checkout → install pinned `Pester` v5 + `PSScriptAnalyzer` → run PSScriptAnalyzer with `PSScriptAnalyzerSettings.psd1` → run Pester (NUnit output) → publish results |
| Gate | Any lint error or failing test fails the job and blocks merge (FR-013) |
| Catalog gate | `Catalog.Schema.Tests.ps1` runs here → undocumented tweak, or one missing an `Action`/`Citation`/`EvidenceGrade`, or a grade-3 entry with `DefaultEnabled=true`, fails CI (FR-009, FR-026, SC-004, SC-010) |
| SBOM | Generate the repository/tooling SBOM (CycloneDX) via `anchore/sbom-action` (SHA-pinned) and upload it as an artifact (FR-029) |
| Duration | Minutes; must not perform heavy build |

**Never** runs the full ISO build (that is `build-image.yml` only).

---

## `build-image.yml` — Release Image Build (manual, matrix)

**Trigger**: `workflow_dispatch` **ONLY**. MUST NOT run on `push`/`pull_request`
(FR-012, US2 scenario 4).

**Inputs** (`workflow_dispatch`):
| Input | Type | Default | Purpose |
|-------|------|---------|---------|
| `edition` | string | `Pro` | Windows edition |
| `language` | string | `en-US` | Display language |
| `release` | string | `latest` | Windows release |
| `profile` | choice | `default` | `minimal`/`default`/`aggressive` catalog subset (FR-024) |
| `enable_catalog_id` | string | `''` | Comma-separated ids to force-enable (opt-in Edge/OneDrive/WSL, FR-024) |
| `disable_catalog_id` | string | `''` | Comma-separated ids to force-disable |
| `skip_heavy_build` | boolean | `false` | Preview-only path (FR-014) |
| `boot_test` | boolean | `false` | Opt-in VM boot validation (FR-023) |

> There are no `remove_edge`/`remove_onedrive` inputs (FR-024): Edge/OneDrive removal is an
> opt-in catalog entry enabled via `enable_catalog_id` (e.g. `remove-edge,remove-onedrive`).

**Permissions** (least privilege): `contents: read`, plus `id-token: write` and
`attestations: write` for provenance/OIDC (FR-028, FR-030).

**Matrix**:
| `arch` | `runs-on` | Requirement |
|--------|-----------|-------------|
| `amd64` | `windows-latest` | x64 build |
| `arm64` | `windows-11-arm` | **native** Windows-on-ARM runner (FR-004, Principle IV) |

**Job contract (per matrix leg)**:
1. Checkout.
2. Install Windows ADK **Deployment Tools** (pinned version) — provides `oscdimg`.
   Documented in `docs/ci.md`; verify availability on `windows-11-arm`.
3. Free/verify disk space; fail fast if insufficient (FR-019) — see runner-limits note.
4. Run `./build.ps1` → `Invoke-IsoBuild` with the dispatch inputs and matrix `arch`
   (the **same** path as local runs; Principle V/FR-010). This produces the ISO, the
   `Autounattend.xml` (per-arch, FR-027), the `SHA256SUMS` manifest (FR-028), the RunReport,
   and the Image BOM via `Export-ImageBom` (FR-029).
   - If `skip_heavy_build=true`: run in preview/`-WhatIf` mode (no download/build), still
     produce a RunReport (FR-014, FR-016).
5. `Compress-BuildArtifact` (done inside `Invoke-IsoBuild`).
6. **Provenance**: `actions/attest-build-provenance` (SHA-pinned) attests each produced ISO;
   publish the `SHA256SUMS` manifest alongside it (FR-028, SC-009).
7. **Publish artifact** — choose one, gated by repository variables (FR-030):
   - If `vars.AZURE_STORAGE_ACCOUNT` + `vars.AZURE_STORAGE_CONTAINER` are set: OIDC
     `azure/login` (using `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID`
     repo vars, **no stored secrets**) then `az storage blob upload` of the compressed image +
     `SHA256SUMS` + BOM.
   - Otherwise (default fallback): `actions/upload-artifact` — one **named** artifact per arch
     (`Windows11-<edition>-<arch>-<release>`) (FR-015, FR-030, SC-002). Rationale: GitHub
     artifacts have per-file/total size limits and retention caps that a ~5–7 GB ISO can
     strain, so Azure Blob is offered as an optional durable target.
8. Upload the RunReport, Image BOM, and `SHA256SUMS` as part of/alongside the artifact
   (FR-022, FR-029).

**Constraints & risks** (also in plan.md / `docs/ci.md`):
- **Disk**: base ISO (~5–7 GB) + extracted media + mounted image + output ISO can exceed
  `windows-latest` free space (~14 GB usable). The build cleans intermediates and fails fast
  on shortfall. `skip_heavy_build` keeps a green path when a full build is impractical.
- **Time**: 6 h job cap; a full build should fit but is monitored.
- **arm64 tooling**: ADK/`oscdimg`/PowerShell availability on `windows-11-arm` MUST be
  verified; document a scripted install fallback if needed.
- **No secrets**: no credentials required for the build; Azure upload uses OIDC federation
  (no stored keys) and is skipped when the repo variables are absent (Principle VII).
- **SHA-pinned actions**: every action (`checkout`, `upload-artifact`, `attest-build-provenance`,
  `azure/login`, `anchore/sbom-action`, ...) is pinned by commit SHA and kept current by
  Renovate (FR-031).

---

## Parity guarantee

Both `build-image.yml` and local `build.ps1` invoke `Invoke-IsoBuild`. There is exactly one
shipped build path (FR-010, Principle V). CI adds only environment setup (ADK install, disk
prep), provenance/SBOM emission, and artifact upload around that shared call.

---

## Dependency updates

`renovate.json5` (JSON5) governs dependency updates (FR-031, Principle VII):
- Extends `config:recommended`, `helpers:pinGitHubActionDigests`, and the shared
  `github>DevSecNinja/.github//.renovate/*` presets (autoMerge, base, customManagers, groups,
  labels, packageRules, semanticCommits).
- A repo-local `customManager` (regex) tracks the pinned pbatard/Fido tag recorded in
  `vendor/fido/VERSION` (`github-releases` datasource) so a maintainer is prompted to
  re-vendor `Fido.ps1` on a new upstream release.
- All GitHub Actions MUST be SHA-pinned; Renovate keeps the digests updated.
