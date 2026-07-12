# Evidence grading

Every change in the catalog carries an `EvidenceGrade` in addition to its mandatory
`Citation`. This makes the *confidence* behind each tweak explicit and auditable
(Constitution Principle II v1.1.0, FR-026).

| Grade | Source | Examples | May be default-enabled? |
|:-----:|--------|----------|:-----------------------:|
| **1** | Official Microsoft documentation | Microsoft Learn, KB articles, official policy docs | Yes |
| **2** | Reputable third-party website / vendor | Well-known vendor docs, established technical sites | Yes |
| **3** | Community / forum post | Forum threads, blog comments, gists | **No — opt-in only** |

## The rule

- Every entry **must** have a `Citation` (an `http(s)` URL, or the literal `Unverified`) **and**
  an `EvidenceGrade` of `1`, `2`, or `3`.
- A **grade-3** entry (or one whose citation is `Unverified`) **must** have
  `DefaultEnabled = $false`. It can still be opted into via `EnableCatalogId`/`Toggles`.

## Enforcement

These rules are enforced automatically so an undocumented or over-eager tweak cannot merge:

- [tests/Catalog.Schema.Tests.ps1](../tests/Catalog.Schema.Tests.ps1) fails if any entry is
  missing a `Description`, `Rationale`, `Citation`, or `EvidenceGrade`, and fails if a grade-3
  entry is `DefaultEnabled`.
- [contracts/change-catalog.schema.json](../specs/001-win11-iso-debloater/contracts/change-catalog.schema.json)
  encodes the same constraints as JSON Schema.
- `ci.yml` runs this gate on every push/PR.

## Authoring guidance

Prefer grade 1. Reach for grade 2 when Microsoft does not document a setting but a reputable
source does. Use grade 3 sparingly and only for opt-in entries, and prefer replacing it with a
higher-grade citation over time.
