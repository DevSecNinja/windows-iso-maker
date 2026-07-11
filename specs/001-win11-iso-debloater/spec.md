# Feature Specification: Windows 11 ISO Builder & Debloater

**Feature Branch**: `001-win11-iso-debloater`

**Created**: 2026-07-11

**Status**: Draft

**Input**: User description: "A PowerShell program that produces a debloated, customized Windows 11 installation image (ISO/WIM) for both amd64 and arm64. It downloads the base Windows 11 ISO using pbatard/Fido, mounts and services the image to remove bloatware provisioned apps and apply well-documented registry/settings tweaks, then repackages a bootable ISO. It runs both locally and in GitHub Actions, producing a compressed image artifact."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Produce a debloated Windows 11 image locally (Priority: P1)

An IT admin or developer on a Windows machine with administrator rights runs a single
documented command. The program downloads the configured Windows 11 base image, removes the
default set of bloatware apps, applies the documented safety/privacy tweaks (including
disabling Windows Recall and the weather/stock Widgets), and repackages a bootable,
customized installation image on their local disk.

**Why this priority**: This is the core value of the product — a reproducible, trustworthy
debloated image. Without it, nothing else matters. It is also the minimum viable slice: one
architecture, default profile, produced locally, delivers immediate value.

**Independent Test**: Run the single documented build command on a clean Windows admin
machine with default configuration. Verify a bootable image is produced, the configured apps
are absent from it, and the configured tweaks are present in its registry hives.

**Acceptance Scenarios**:

1. **Given** a Windows machine with administrator rights and the required servicing tooling
   available, **When** the user runs the documented default build command, **Then** the
   program downloads the latest Windows 11 Pro en-US image, applies the default debloat
   profile, and outputs a bootable customized installation image without manual intervention.
2. **Given** the default debloat profile, **When** the build completes, **Then** every
   provisioned bloatware app in the profile is absent from the resulting image and every
   configured registry/setting tweak is present in the serviced image.
3. **Given** a completed build, **When** the user inspects the run output, **Then** an
   auditable change catalog lists every app removed and every tweak applied, each with a
   what/why description and a citation.

---

### User Story 2 - Build both amd64 and arm64 images in GitHub Actions (Priority: P1)

A maintainer manually triggers the build workflow in GitHub Actions. The workflow produces
both an amd64 image and an arm64 image (the arm64 image built on a native Windows-on-ARM
runner), compresses each, and uploads them as downloadable artifacts of the workflow run.

**Why this priority**: Cross-architecture, CI-produced artifacts are the primary distribution
mechanism and a core stakeholder requirement. It is equally critical to P1 because the value
proposition explicitly includes native arm64 support and downloadable artifacts.

**Independent Test**: Manually dispatch the workflow. Confirm two artifacts (one per
architecture) are produced, each compressed and downloadable, and that the arm64 artifact was
produced on a native Windows-on-ARM runner.

**Acceptance Scenarios**:

1. **Given** the repository's Actions tab, **When** a maintainer manually dispatches the build
   workflow, **Then** the full download-and-build runs and produces a compressed image
   artifact for each of amd64 and arm64.
2. **Given** the workflow uses the same shipped build logic as local runs, **When** it
   executes, **Then** no CI-only code path bypasses the shared build functions.
3. **Given** a completed workflow run, **When** a user opens the run summary, **Then** each
   architecture's compressed image is available as a named, downloadable artifact.
4. **Given** the build workflow definition, **When** a plain commit or non-dispatch event
   occurs, **Then** the full build does NOT run automatically (manual dispatch only).

---

### User Story 3 - Automated quality gates on every change (Priority: P1)

A contributor opens a pull request or pushes a commit. Automated tests and static analysis
run on every commit/PR and block merge when they fail, ensuring the change catalog stays
documented and the destructive code paths stay correct.

**Why this priority**: The product manipulates real installation media where mistakes are
costly; the automated guardrail is what makes the debloat logic safe to trust. It gates all
other work.

**Independent Test**: Push a commit that breaks a test or violates a lint rule; confirm the
check fails and is reported on the commit/PR. Push a compliant commit; confirm the checks pass.

**Acceptance Scenarios**:

1. **Given** any commit or pull request, **When** CI runs, **Then** the unit test suite and
   static analysis both execute and their results gate the change.
2. **Given** a change catalog entry that is missing a what/why description or citation, **When**
   the tests run, **Then** the suite fails, preventing an undocumented tweak from merging.
3. **Given** a pull request where running the full ISO download-and-build would exceed runner
   disk/time limits, **When** CI runs, **Then** the heavy build may be skipped with a
   documented reason, while tests and analysis still run.

---

### User Story 4 - Customize edition, language, release, architecture, and change set (Priority: P2)

A user overrides the defaults through configuration: choosing a different edition, display
language, Windows release/version, or architecture, and adjusting which apps are removed and
which tweaks are applied — including opting in to remove Edge or OneDrive, which are NOT
removed by default.

**Why this priority**: Configurability is a stakeholder requirement and broadens the audience,
but the product delivers value with defaults first; customization is a fast follow.

**Independent Test**: Supply a non-default configuration (e.g., a different language and an
opt-in Edge removal) and confirm the produced image reflects exactly those choices and nothing
more.

**Acceptance Scenarios**:

1. **Given** a configuration selecting a non-default edition, language, release, or
   architecture, **When** the build runs, **Then** the produced image matches the selected
   values.
2. **Given** the default profile, **When** the build runs without opt-in flags, **Then**
   Microsoft Edge and OneDrive remain present in the image.
3. **Given** a configuration that opts in to removing Edge and/or OneDrive, **When** the build
   runs, **Then** those components are removed and each removal is recorded in the change
   catalog with a citation and reversibility note.
4. **Given** a configuration that adds or removes items from the app/tweak set, **When** the
   build runs, **Then** only the configured changes are applied.

---

### User Story 5 - Safe, previewable, idempotent, reversible operation (Priority: P2)

Before committing to a destructive build, a user previews exactly what will change using a
dry-run/preview mode. Re-running the build over the same inputs does not compound changes, and
reversible changes are documented so a user can undo them.

**Why this priority**: Safety and reversibility build the trust the product depends on, but the
core build must exist first for these guarantees to protect anything.

**Independent Test**: Run the build in preview mode and confirm it reports the intended changes
without modifying media. Run the real build twice and confirm the second run is a no-op for
already-applied changes and produces an equivalent image.

**Acceptance Scenarios**:

1. **Given** any build invocation, **When** the user requests a preview/dry-run, **Then** the
   program reports every app it would remove and every tweak it would apply, and modifies no
   media.
2. **Given** a build that has already been applied, **When** the same build runs again over the
   same inputs, **Then** it detects already-applied changes and does not re-apply or compound
   them (idempotent).
3. **Given** an interruption or failure mid-build, **When** the program exits, **Then** it
   surfaces a clear terminating error and leaves no silently corrupted output presented as a
   successful image.

---

### Edge Cases

- What happens when the base image download fails, is incomplete, or its integrity cannot be
  verified? The build MUST stop with a clear error and MUST NOT proceed to servicing a corrupt
  source.
- How does the system handle an app or capability listed for removal that is not present in the
  selected edition/architecture? The change is skipped and recorded as not-applicable in the
  change catalog rather than failing the whole build.
- What happens when the build runs without administrator rights or without the required
  servicing tooling? The program MUST fail fast with an actionable message before touching any
  media.
- How does the system behave when insufficient disk space is available for mounting/servicing/
  repackaging? It MUST detect and report the shortfall before beginning destructive work.
- What happens on a pull request where the full build is skipped due to runner limits? Tests and
  analysis still run and gate the change; the skip is logged with its documented reason.
- How does the system handle an architecture-specific app that exists on one architecture but not
  the other? It is handled explicitly per architecture and documented in the change catalog.
- What happens when a requested edition/language/release combination is unavailable from the
  download source? The build stops with a clear message listing what was requested.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST download a Windows 11 base installation image using the pbatard/Fido
  source, selecting edition, language, release/version, and architecture from configuration.
- **FR-002**: System MUST default to Windows 11 Pro, en-US, the latest available release, while
  allowing each of edition, language, release/version, and architecture to be overridden by
  configuration.
- **FR-003**: System MUST build images for BOTH amd64 and arm64 from the same code base and
  configuration, with architecture as a first-class, validated configuration input.
- **FR-004**: System MUST produce the arm64 image on a native Windows-on-ARM GitHub-hosted
  runner (not via emulation or cross-service substitution) for CI artifacts.
- **FR-005**: System MUST mount/service the base image, remove the configured provisioned
  bloatware apps, apply the configured registry/setting tweaks, and repackage a bootable
  customized installation image.
- **FR-006**: The default debloat profile MUST remove common provisioned bloatware apps
  (e.g., King/Candy Crush titles, Clipchamp, Bing News/Weather, Xbox extras, Solitaire
  collection, consumer Teams, and similar) as enumerated in the change catalog.
- **FR-007**: The default profile MUST apply safe registry/setting tweaks AND specifically
  disable Windows Recall and disable the weather/stock Widgets.
- **FR-008**: The default profile MUST NOT remove Microsoft Edge or OneDrive; removal of either
  MUST be opt-in via configuration only.
- **FR-009**: Every registry key, app, provisioned package, or capability change MUST be defined
  as data in an auditable change catalog and MUST record: what it does, why it is safe/desirable,
  and a citation to Microsoft documentation or another authoritative source (entries lacking an
  authoritative source MUST be marked unverified and be opt-in only).
- **FR-010**: System MUST run through the SAME shipped build functions both locally and in CI;
  CI-only logic that bypasses the shared build path is prohibited.
- **FR-011**: System MUST be runnable locally with a single documented command on a Windows
  machine with administrator rights and produce an image without manual mid-build intervention.
- **FR-012**: The GitHub Actions full build workflow MUST run by manual dispatch only and MUST
  NOT run the full build automatically on ordinary commits or pull requests.
- **FR-013**: Automated tests and static analysis MUST run on every commit and pull request and
  MUST gate the change (failures block merge).
- **FR-014**: On pull requests where the full ISO download-and-build would exceed runner
  disk/time limits, the heavy build MAY be skipped with a documented reason while tests and
  analysis still run; the workflow MUST also allow attempting the full build.
- **FR-015**: System MUST compress each produced image and upload it as a named, downloadable
  workflow artifact, one per architecture.
- **FR-016**: System MUST support a preview/dry-run mode that reports all intended changes
  without modifying any media.
- **FR-017**: System MUST be idempotent: re-running a build over the same inputs MUST NOT
  re-apply or compound already-applied changes.
- **FR-018**: System MUST document reversibility for each change where the change is reversible,
  so users can understand how to undo it.
- **FR-019**: System MUST validate preconditions (administrator rights, required servicing
  tooling, sufficient disk space, valid configuration) and fail fast with actionable messages
  before performing destructive work.
- **FR-020**: System MUST verify the integrity of the downloaded base image before servicing it
  and MUST stop with a clear error if verification fails.
- **FR-021**: System MUST skip and record (rather than fail) removals for apps/capabilities that
  are not present in the selected edition/architecture.
- **FR-022**: System MUST emit an auditable run report that lists every change actually applied
  (and every change skipped and why) for each build.
- **FR-023**: System MUST produce a validated, bootable Windows 11 installation image as its
  output for each configured architecture. Validation MUST, by default, perform
  structural/media-integrity checks (verify the ISO/WIM structure, image index integrity via
  DISM, and presence of required boot files such as `boot/bootmgr`, `efi/boot/bootx64.efi` or
  `bootaa64.efi`, and `sources/install.wim`/`.esd`). An actual VM boot test is OPTIONAL and
  opt-in (disabled by default because hosted CI runners may lack nested-virtualization
  capacity); when enabled it boots the produced image in a VM and confirms it reaches Windows
  Setup.
- **FR-024**: Every enable/disable/remove/add MUST be expressed as a data-driven change catalog
  entry selected through configuration — via named Profiles (e.g., `minimal`, `default`,
  `aggressive`), a Toggles map, and explicit `EnableCatalogId`/`DisableCatalogId` lists. The
  system MUST NOT require a new code path or a new dedicated parameter/switch per feature. The
  removal of Microsoft Edge and OneDrive (see FR-008) MUST be modeled as ordinary opt-in catalog
  entries, not as dedicated parameters or switches.
- **FR-025**: The change catalog MUST support additive actions (enable Windows optional features
  and add capabilities), not only removals. The system MUST be able to enable Windows Subsystem
  for Linux (WSL) offline by enabling the `Microsoft-Windows-Subsystem-Linux` and
  `VirtualMachinePlatform` features on the mounted image. The WSL entry MUST ship as opt-in
  (`DefaultEnabled = false`). The catalog entry MUST document that the WSL kernel and Linux
  distribution are downloaded online on first boot (a Windows platform constraint), so the
  offline image only pre-enables the platform features.
- **FR-026**: Every change catalog entry MUST carry an `EvidenceGrade` (1 = Microsoft official,
  2 = reputable third-party website/vendor, 3 = community/forum) in addition to its mandatory
  citation. A grade-3 entry MUST NOT be `DefaultEnabled`. Validation MUST fail the build if any
  entry lacks a citation or an `EvidenceGrade`, or if a grade-3 entry is default-enabled.
- **FR-027**: System MUST generate an `Autounattend.xml` dynamically from the same build
  configuration, per architecture (with the correct `processorArchitecture`, i.e. `amd64` vs
  `arm64`). It MUST handle install/OOBE-time settings: skipping OOBE prompts, locale/keyboard/
  timezone, disk layout, and FirstLogon/SetupComplete commands. The default profile MUST bypass
  the Microsoft-account requirement and create a local account (configurable/toggleable). The
  generated `Autounattend.xml` MUST be placed at the ISO root (and/or injected into the image).
  This is complementary to — not a replacement for — DISM offline servicing.
- **FR-028**: The build MUST produce verifiable provenance/attestation (SLSA build provenance via
  GitHub Artifact Attestations) for each output ISO and MUST publish SHA256 checksums so a
  consumer can independently verify the authenticity and integrity of a produced image.
- **FR-029**: The build MUST publish (a) a repository/tooling SBOM in a standard format
  (CycloneDX) and (b) an Image BOM enumerating every change applied to the image (each with its
  citation and evidence grade), the base image version and hash, and the pinned tool versions
  (Fido, Windows ADK). The Image BOM MUST be derived from the run report.
- **FR-030**: System MUST support an OPTIONAL upload of the compressed artifact to Azure Blob
  Storage, authenticated via OIDC (no stored secrets), gated by configuration/repository
  variables. When Azure upload is not configured, the system MUST fall back to publishing the
  compressed image as a workflow artifact (per FR-015).
- **FR-031**: The repository MUST use an automated dependency update mechanism (Renovate) that
  covers GitHub Actions (SHA-pinned) and the vendored Fido version.

### Key Entities *(include if data involved)*

- **Build Configuration**: The user-controllable inputs for a build — edition, display language,
  Windows release/version, target architecture(s), the selected app-removal set, the selected
  tweak set, and opt-in flags (e.g., remove Edge, remove OneDrive). Drives all behavior.
- **Change Catalog Entry**: A single documented modification. Attributes: identifier, `Action`
  (e.g., RemoveAppx, RemoveCapability, SetRegistry, EnableOptionalFeature/AddCapability), target,
  what-it-does, why-it-is-safe, citation (or unverified marker), `EvidenceGrade` (1/2/3),
  `DefaultEnabled`, applicable architectures/editions, reversibility note. Selectable through
  Profiles, Toggles, and Enable/Disable catalog-id lists rather than dedicated switches.
- **Autounattend Profile**: The install/OOBE-time settings generated per architecture into an
  `Autounattend.xml` from the build configuration — OOBE skip, Microsoft-account bypass + local
  account creation, locale/keyboard/timezone, disk layout, and FirstLogon/SetupComplete commands.
- **Provenance Attestation**: The SLSA build-provenance attestation and SHA256 checksum manifest
  associated with each produced ISO, enabling consumers to verify authenticity and integrity.
- **SBOM / Image BOM**: The repository/tooling SBOM (CycloneDX) plus the Image BOM enumerating
  every applied change (with citation + evidence grade), the base image version + hash, and the
  pinned tool versions (Fido, ADK); the Image BOM is derived from the run report.
- **Base Image**: The downloaded Windows 11 installation media identified by edition, language,
  release, and architecture, plus an integrity/verification indicator.
- **Output Image Artifact**: The repackaged, customized, bootable installation image for one
  architecture, in compressed form, with an associated run report.
- **Run Report**: The auditable record of a single build — which catalog entries were applied,
  which were skipped and why, the resolved configuration, and the produced artifact reference.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A single documented command on a clean Windows admin machine produces a bootable,
  customized Windows 11 image with zero manual steps after invocation.
- **SC-002**: A manually dispatched CI run produces a downloadable, compressed image artifact for
  each of amd64 and arm64, with the arm64 artifact built on a native Windows-on-ARM runner.
- **SC-003**: 100% of the provisioned bloatware apps in the applied profile are absent from the
  produced image, and 100% of the applied tweaks (including Recall and Widgets disabled) are
  present, as verified against the run report.
- **SC-004**: 100% of change catalog entries carry a what/why description and a citation (or an
  explicit unverified+opt-in marker); any entry missing these fails automated checks.
- **SC-005**: Tests and static analysis run and report a pass/fail result on 100% of commits and
  pull requests, and a failing check blocks merge.
- **SC-006**: A preview/dry-run run modifies zero media while reporting 100% of the changes a real
  run would make.
- **SC-007**: Running the same build twice over identical inputs produces equivalent output and
  applies zero additional changes on the second run (idempotent).
- **SC-008**: A new user can go from a fresh checkout to a produced local image by following the
  documented quick-start without needing undocumented steps.
- **SC-009**: A consumer can independently verify both the SLSA build provenance and the SHA256
  checksum of a produced ISO and obtain a positive verification result.
- **SC-010**: 100% of change catalog entries carry both a citation and an `EvidenceGrade`, and no
  grade-3 entry is default-enabled (0 violations); any violation fails automated checks.
- **SC-011**: Adding a new debloat/tweak/optional-feature item requires only a new change catalog
  entry and zero code changes (no new parameter, switch, or code path).
- **SC-012**: Every build produces an Image BOM that lists 100% of the changes actually applied
  to the image, together with the base image version + hash and the pinned tool versions.

## Assumptions

- Windows-only servicing is required: image mounting/servicing depends on Windows-native
  offline-servicing tooling (DISM and the Windows image-servicing stack). Non-Windows hosts are
  out of scope for performing the build.
- The build host (local or runner) has administrator rights, sufficient free disk space for
  mounting/servicing/repackaging, and network access to the download source.
- "Latest release" is resolved through the download source (Fido) at build time; the exact
  resolved version is recorded in the run report.
- The default artifact compression is a widely supported archive format suitable for GitHub
  Actions artifact upload/download; the specific format is an implementation detail chosen for
  portability.
- Native Windows-on-ARM GitHub-hosted runners remain available for producing arm64 artifacts.
- itsNileshHere/Windows-ISO-Debloater is used only as inspiration; this product intentionally
  exceeds it on documentation/citation rigor and is not a dependency.
- Runner disk and time limits may make a full ISO download-and-build impractical on pull-request
  events; this is expected and handled by allowing a documented skip while still running tests.
- The initial default profile targets a common, conservative bloatware/tweak set; the exact
  enumerated list is maintained in the change catalog and may evolve with citations.
- Enabling WSL offline only pre-enables the platform features; the WSL Linux kernel and any
  distribution are downloaded online on first boot, which is an inherent Windows constraint.
- `Autounattend.xml` is architecture-specific (the `processorArchitecture` value differs between
  amd64 and arm64); a separate file is generated per target architecture from the same config.
- Optional Azure Blob upload requires a consumer-provided Azure account with OIDC federation
  configured; when it is not configured, the build falls back to the standard workflow artifact.
- This specification is consistent with constitution v1.1.0 (evidence grading and supply-chain
  provenance/SBOM principles).
