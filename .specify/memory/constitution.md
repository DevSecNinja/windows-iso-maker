<!--
SYNC IMPACT REPORT
==================
Version change: 1.0.0 → 1.1.0
Bump rationale: MINOR amendment — materially expanded guidance. Added an Evidence Grading
system and generalized additive/enable actions to Principle II, and added Supply-Chain
Integrity & Provenance requirements (provenance/attestation, checksums, SBOM + Image BOM,
pinned + auto-updated dependencies, SHA-pinned Actions) to Principle VII. No principles
removed or redefined incompatibly.

Modified principles:
  - II. Documentation-Backed System Changes — added mandatory EvidenceGrade (1/2/3) per
    change; grade-3 entries MUST be opt-in (DefaultEnabled=false); generalized the change
    model to support additive/enable Actions (data-driven catalog entries, no per-feature
    parameter proliferation).
  - VII. Security & Input Validation — added Supply-Chain Integrity & Provenance:
    build attestation/provenance (SLSA), SHA256 checksums, SBOM + Image BOM, pinned and
    auto-updated dependencies (incl. vendored Fido), SHA-pinned GitHub Actions.
Added sections: N/A (existing principles extended)
Removed sections: N/A

Templates requiring updates:
  - .specify/templates/plan-template.md ................ ✅ updated (Constitution Check gates
    v1.1.0: evidence-grade gate + provenance/SBOM/Image BOM + pinned deps)
  - .specify/templates/spec-template.md ................ ✅ reviewed (no principle-specific
    edits required; remains domain-agnostic)
  - .specify/templates/tasks-template.md ............... ✅ updated (added evidence-grade
    catalog schema/lint tasks and provenance/SBOM/Image BOM + dependency-pinning tasks)
  - .specify/templates/checklist-template.md ........... ✅ reviewed (generic; no change needed)

Follow-up TODOs: None. RATIFICATION_DATE unchanged (original adoption date).
-->

# Windows ISO Maker Constitution

Windows ISO Maker is a PowerShell-based program that downloads, debloats, and repackages
Windows 11 installation media (amd64 and arm64) with fully documented, reversible system
changes, built identically on a local machine and in GitHub Actions.

## Core Principles

### I. Modularity & PowerShell Best Practices

Code MUST be organized into small, single-purpose functions packaged as a proper
PowerShell module (`.psm1` + `.psd1` manifest); ad-hoc monolithic scripts are prohibited
for shipped logic. All shipped code MUST comply with the following, verifiable rules:

- Every public function MUST use an approved verb (`Get-Verb`) and PascalCase naming
  (e.g. `Remove-ProvisionedApp`), and MUST carry comment-based help (`.SYNOPSIS`,
  `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`).
- Every function MUST declare `[CmdletBinding()]`; every parameter MUST use explicit types
  and validation attributes (`[ValidateNotNullOrEmpty()]`, `[ValidateSet()]`, etc.).
- Functions that change system or media state MUST support `SupportsShouldProcess` and
  gate mutations behind `$PSCmdlet.ShouldProcess(...)`, providing `-WhatIf`/`-Confirm`.
- Error handling MUST use `try/catch` with explicit `-ErrorAction Stop` on risky calls;
  `Set-StrictMode -Version Latest` MUST be enabled and modules MUST `throw` terminating
  errors on unrecoverable failure rather than silently continuing.
- Aliases (e.g. `%`, `?`, `ls`, `cat`) are FORBIDDEN in committed code; full cmdlet and
  parameter names MUST be used for readability and forward compatibility.

**Rationale**: Modular, convention-compliant PowerShell is testable, discoverable, and
safe to run against real installation media where mistakes are costly.

### II. Documentation-Backed System Changes (NON-NEGOTIABLE)

This is the project's core differentiator: there MUST be no "magic" tweaks. Every registry
key, every Appx/provisioned package, and every Windows capability or optional feature that
the tool adds, removes, enables, or disables MUST be defined as data (not scattered inline)
and MUST record, for each change:

1. **What** it does (the concrete effect on the image/OS).
2. **Why** it is safe and desirable (user-facing benefit and risk assessment).
3. **Citation** — a link to official Microsoft documentation or another authoritative
   source where one exists; if no authoritative source exists, the entry MUST be marked
   `Unverified` with an explicit rationale, and such entries MUST be opt-in only.
4. **EvidenceGrade** — a mandatory confidence rating for the citation:
   - **Grade 1** = official Microsoft documentation (Microsoft Learn, KB articles, official
     product docs) — highest confidence.
   - **Grade 2** = reputable third-party website or vendor documentation.
   - **Grade 3** = community/forum post or other unofficial source.

**Evidence-grade enforcement rules** (all testable and CI-enforced):

- A change with `EvidenceGrade` 3 MUST NOT be enabled by default: its `DefaultEnabled`
  field MUST be `false`. Grade-3 changes are opt-in only.
- The change-catalog schema test MUST fail the build if any entry is missing a `Citation`
  or an `EvidenceGrade`.
- A lint/test MUST fail the build if any entry has `EvidenceGrade` 3 together with
  `DefaultEnabled` = `true`.

**Generalized change model** — the catalog is NOT only about removal. Every catalog entry
MUST declare an **Action** type (e.g. `Remove`, `Add`, `Enable`, `Disable`, `SetRegistry`),
so that additive/enable operations (such as enabling Windows optional features like WSL)
are first-class, data-driven catalog entries. Adding a new tweak MUST mean adding a catalog
entry (with Citation + EvidenceGrade + Action), NOT adding new code paths or per-feature
parameters/switches. Per-feature boolean parameter proliferation (e.g. `-EnableWsl`,
`-RemoveEdge`, `-DisableX`) is explicitly discouraged and MUST be rejected in review in
favor of catalog-driven entries selected by profile/configuration.

A change proposal that adds/removes/modifies a component without all four fields (What /
Why / Citation / EvidenceGrade) and an Action MUST be rejected in review. Reversibility
notes (see Principle VI) SHOULD accompany each entry.

**Rationale**: Undocumented debloat scripts erode user trust and cause silent breakage;
citation-backed, evidence-graded changes make every modification auditable and defensible,
while a single data-driven change model keeps additions cheap and code paths stable.

### III. Testing Discipline

Pester v5 unit tests MUST exist for every module and every public function, and
PSScriptAnalyzer MUST run clean against the configured rule set (no unsuppressed errors;
suppressions MUST be justified inline). The following are enforced:

- Continuous Integration MUST run Pester and PSScriptAnalyzer on **every commit and pull
  request**; a red test run or lint error blocks merge.
- Test-first development MUST be used where practical: for new public functions and bug
  fixes, a failing test SHOULD precede the implementation/fix.
- The change catalog from Principle II MUST be covered by tests asserting schema validity
  (each entry has What/Why/Citation) so undocumented tweaks fail CI automatically.

**Rationale**: Media-building operations are hard to hand-verify; automated tests and
linting are the primary guardrail against regressions in destructive code paths.

### IV. Cross-Architecture Support

The program MUST build both **amd64** and **arm64** Windows 11 images from the same code
base and configuration. Specifically:

- arm64 images MUST be produced on native `windows-11-arm` GitHub-hosted runners; emulated
  or cross-service arm64 builds are NOT an acceptable substitute for release artifacts.
- Architecture MUST be a first-class configuration input, never hardcoded; functions that
  branch on architecture MUST validate it via `[ValidateSet('amd64','arm64')]`.
- Any capability that is architecture-specific (e.g. an Appx or driver unavailable on one
  arch) MUST be handled explicitly and documented in the change catalog.

**Rationale**: First-class arm64 support on native runners guarantees correct, performant
images for modern Windows-on-ARM devices without silent parity gaps.

### V. Reproducibility & Local Parity

The exact same build MUST work locally and in CI — "it just works" locally is a hard
requirement, not a convenience. Therefore:

- All behavior MUST be driven by explicit configuration (files/parameters); magic numbers,
  hardcoded paths, and environment-specific assumptions are prohibited.
- Tool and module version requirements (PowerShell, Pester, PSScriptAnalyzer, Fido, ADK
  where needed) MUST be pinned/declared so a fresh machine reproduces CI results.
- CI and local entry points MUST invoke the **same** module functions; CI-only logic that
  bypasses the shipped build path is prohibited.

**Rationale**: Divergence between local and CI builds destroys debuggability; a single,
config-driven build path keeps results deterministic everywhere.

### VI. Safety & Reversibility

Changes to the image and host MUST be conservative, scoped, and recoverable:

- Every mutating operation MUST support a dry-run (`-WhatIf`) that reports intended actions
  without applying them, and MUST be idempotent (safe to re-run with no additional effect).
- Operations MUST be well-scoped to the mounted image/target and MUST NOT touch the host OS
  outside declared working directories.
- Removal of first-party components with functional impact (e.g. Microsoft Edge, OneDrive,
  Recall, Widgets) MUST be **opt-in** and default to OFF; the default profile removes only
  clearly non-essential, provisioned bloatware plus safe, documented registry tweaks.
- Reversal guidance SHOULD be recorded for each change so users can restore prior behavior.

**Rationale**: Irreversible, over-broad edits to Windows media cause unbootable or unstable
images; conservative, opt-in, idempotent changes keep users in control.

### VII. Security & Input Validation

Security is enforced at every boundary where external data or media enters the pipeline:

- No secrets (tokens, keys, credentials) may appear in code, configuration, or logs;
  secrets MUST be supplied via CI secret stores or local environment and never committed.
- All external inputs MUST be validated: ISO/download sources, user-supplied paths, and
  configuration values. Where integrity data is available (e.g. hashes surfaced via Fido),
  downloaded media MUST be integrity-checked before use.
- Applicable OWASP guidance (injection, insecure deserialization, untrusted input handling)
  MUST be followed for any parsing, download, or command-construction code.
- Downloaded artifacts and mounted images MUST be treated as untrusted until validated.

**Supply-Chain Integrity & Provenance** — builds MUST be verifiable end to end:

- Produced artifacts MUST carry build provenance/attestation (e.g. SLSA provenance via
  GitHub Artifact Attestations) and MUST publish cryptographic checksums (SHA256) for every
  released artifact.
- The build MUST publish a **Software Bill of Materials (SBOM)** for the tooling/repo AND an
  **Image BOM** that enumerates every change applied to the image (each with its Citation and
  EvidenceGrade per Principle II), the base image version + hash, and the pinned tool versions
  (Fido, ADK).
- Dependencies MUST be pinned and kept current via an automated mechanism (e.g. Renovate),
  including the vendored Fido version.
- GitHub Actions MUST be pinned by full commit SHA (not by mutable tags/branches).

**Rationale**: The pipeline pulls large binaries from the internet and mounts privileged
media; rigorous input validation, secret hygiene, and verifiable provenance (attestation,
checksums, SBOM/Image BOM, pinned dependencies) prevent supply-chain and injection risk and
let users independently verify what a build did.

## Additional Constraints & Standards

- **Language/Runtime**: PowerShell (Windows PowerShell 5.1 and PowerShell 7+ compatibility
  SHOULD be validated where feasible; ARM builds run on native Windows-on-ARM runners).
- **Module shape**: A versioned module manifest (`.psd1`) MUST declare exported functions,
  required modules, and minimum PowerShell version.
- **Configuration**: Debloat/registry/appx/feature definitions live in versioned
  configuration data files consumed by the module — never inline in control flow. Each
  catalog entry declares an `Action` (e.g. `Remove`/`Add`/`Enable`/`Disable`/`SetRegistry`),
  a `Citation`, an `EvidenceGrade` (1/2/3), and `DefaultEnabled`. New tweaks are added as
  catalog entries, not as new per-feature parameters or code paths.
- **Supply chain**: Dependencies (PowerShell modules, Fido, ADK, GitHub Actions) MUST be
  pinned — Actions by commit SHA — and updated via an automated tool (e.g. Renovate).
  Releases MUST publish SHA256 checksums, build provenance/attestation, an SBOM, and an
  Image BOM enumerating every applied change with its citation, evidence grade, and the
  base-image version + hash.
- **Workflow trigger**: The full download-and-build GitHub Actions workflow runs MANUALLY
  (`workflow_dispatch`); test and lint workflows run automatically on every commit and PR.
  Heavy build steps MAY be skipped on PRs provided limitations are documented.
- **Reference implementations** (for study, not verbatim copying): pbatard/Fido for ISO
  acquisition, itsNileshHere/Windows-ISO-Debloater for debloat patterns.

## Development Workflow & Quality Gates

- **Gate 1 — Lint**: PSScriptAnalyzer MUST pass with zero unsuppressed errors.
- **Gate 2 — Test**: Pester v5 suite MUST pass, including the change-catalog schema tests
  (What / Why / Citation / EvidenceGrade present for every entry) and the evidence-grade
  lint (no `EvidenceGrade` 3 entry may have `DefaultEnabled` = `true`).
- **Gate 3 — Documentation review**: Any PR adding/removing/enabling registry keys,
  Appx/provisioned packages, capabilities, or optional features MUST include catalog
  entries with an Action, citation, and evidence grade; reviewers MUST reject undocumented
  tweaks and per-feature parameter proliferation.
- **Gate 4 — Cross-arch sanity**: Changes affecting the build path MUST be validated (or
  explicitly reasoned about) for both amd64 and arm64.
- **Gate 5 — Safety review**: Any new mutating operation MUST demonstrate `-WhatIf` support,
  idempotency, and correct opt-in gating for component removal.
- **Gate 6 — Supply-chain review**: Releases MUST emit provenance/attestation, SHA256
  checksums, an SBOM, and an Image BOM; dependencies (incl. vendored Fido) MUST be pinned
  and Actions pinned by commit SHA.
- Code review MUST verify compliance with all seven principles before merge; deviations
  MUST be recorded in the plan's Complexity Tracking with justification.

## Governance

This constitution supersedes ad-hoc practices and conventions for the windows-iso-maker
repository. All pull requests and reviews MUST verify compliance with the Core Principles
and Quality Gates above.

- **Amendments** MUST be proposed via pull request that edits this file, includes an updated
  Sync Impact Report, and adjusts dependent templates in `.specify/templates/`.
- **Versioning policy** follows semantic versioning for governance:
  - **MAJOR**: Backward-incompatible removal or redefinition of a principle or governance rule.
  - **MINOR**: A new principle/section is added or existing guidance is materially expanded.
  - **PATCH**: Clarifications, wording, or non-semantic refinements.
- **Compliance review**: Every merge is a compliance checkpoint; recurring violations MUST
  trigger a review of tooling or principle wording. Complexity that violates a principle MUST
  be justified in the plan or rejected.

**Version**: 1.1.0 | **Ratified**: 2026-07-11 | **Last Amended**: 2026-07-11
