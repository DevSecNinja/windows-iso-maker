# Provenance, checksums & BOM/SBOM

The build is designed to be **verifiable**: you can prove which tool produced an image, that it
has not been tampered with, and exactly what it contains.

## SHA256 checksums

Every build writes a `SHA256SUMS` manifest into the output directory next to the compressed
artifact. Verify locally:

```powershell
# Windows
Get-FileContent SHA256SUMS
Get-FileHash .\out\Windows11-Pro-amd64-latest.zip -Algorithm SHA256
```

```bash
# Linux/macOS
sha256sum -c SHA256SUMS
```

## SLSA build provenance (GitHub Artifact Attestations)

`build-image.yml` runs `actions/attest-build-provenance` for each produced image, generating a
signed SLSA provenance attestation tied to the workflow run. Verify it with the GitHub CLI:

```bash
gh attestation verify Windows11-Pro-amd64-latest.zip --repo DevSecNinja/windows-iso-maker
```

This confirms the artifact was built by this repository's workflow and has not been altered.

## SBOM (repository / tooling)

`ci.yml` generates a **CycloneDX** SBOM of the repository/tooling via `anchore/sbom-action` and
uploads it as a build artifact (`repo-sbom.cyclonedx.json`). It captures the dependencies of the
project itself.

## Image BOM (what is inside the image)

Because a Windows image is not a typical dependency tree, the build also emits an **Image BOM**
derived from the RunReport by
[`Export-ImageBom`](../src/WindowsIsoMaker/Public/Export-ImageBom.ps1). It records:

- the base image version + hash (as resolved by Fido),
- the pinned tool versions (Fido, ADK),
- **every change applied** to the image, each with its `Citation` and `EvidenceGrade`,
- and every change skipped, with the reason.

It is written in both CycloneDX JSON and a human-readable Markdown form to the output directory
alongside `run-report.json`. This is the auditable record that distinguishes this project from
opaque debloaters: for any produced image you can answer "what changed and why?" with citations.

## Putting it together

For a given release artifact you can:

1. `sha256sum -c SHA256SUMS` — integrity.
2. `gh attestation verify ...` — provenance/authenticity.
3. Open the Image BOM — full, cited inventory of every modification.
