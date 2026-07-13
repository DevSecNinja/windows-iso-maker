# Change catalog & rationale

Every system change this tool makes is a **data-driven catalog entry**, not hard-coded logic.
The catalog lives in:

- [config/catalog.appx.psd1](../config/catalog.appx.psd1) — provisioned app removals
- [config/catalog.capabilities.psd1](../config/catalog.capabilities.psd1) — capabilities & optional features (incl. WSL)
- [config/catalog.registry.psd1](../config/catalog.registry.psd1) — registry tweaks

The catalog files themselves are the authoritative, always-up-to-date documentation: each
entry states **what** it does, **why**, a **citation**, and an **evidence grade**. This page
explains the model and highlights the notable defaults.

## Entry schema

```powershell
@{
    Id             = 'reg-disable-recall'          # unique, stable id
    Type           = 'Registry'                    # Appx | Capability | Registry | OptionalFeature (informational)
    Action         = 'SetRegistry'                 # dispatch key: RemoveAppx | RemoveCapability | SetRegistry | EnableOptionalFeature | AddCapability
    Target         = @{ Hive='SOFTWARE'; Path='...'; Name='...'; Kind='DWord'; Value=1 }  # or a package/feature name string
    Description    = 'WHAT the change does.'       # required (Principle II)
    Rationale      = 'WHY it is safe/desirable.'   # required
    Citation       = 'https://learn.microsoft.com/...'  # required (URL or 'Unverified')
    EvidenceGrade  = 1                             # required: 1 official / 2 vendor / 3 forum
    Reversible     = $true
    Reversal       = 'How to undo it.'
    DefaultEnabled = $true                         # grade-3 entries must be $false
    Arch           = @('amd64','arm64')
}
```

The `Action` is the dispatch key: [`Invoke-CatalogEntry`](../src/WindowsIsoMaker/Public/Invoke-CatalogEntry.ps1)
routes each entry to the correct handler. **Adding a new change means adding an entry — never a
new code path or parameter** (FR-024/FR-025).

## Selecting changes

Selection is resolved by [`Resolve-CatalogSelection`](../src/WindowsIsoMaker/Private/Resolve-CatalogSelection.ps1)
from three inputs, in order of increasing precedence:

1. `Profile` — the baseline set (`minimal` / `default` / `aggressive` / `gaming` / `opinionated`,
   where `gaming` is `default` minus the `Category = 'Gaming'` entries so Xbox / Game Bar are
   preserved, and `opinionated` is `aggressive` plus the `Category = 'Opinionated'` personal-taste
   extras — reversed mouse scroll, Start web-search off, lock-screen Spotlight off, WSL).
2. `Toggles` — a per-id `@{ id = $true/$false }` map.
3. `EnableCatalogId` / `DisableCatalogId` — explicit ids always win.

Entries not applicable to the target `Architecture` are skipped automatically.

## Notable defaults

**Enabled by default (spec-mandated, grade 1, reversible):**

- `reg-disable-recall` — disables Windows Recall via the `DisableAIDataAnalysis` policy
  (privacy: Recall periodically captures screenshots).
  Cited: <https://learn.microsoft.com/en-us/windows/client-management/manage-recall>
- `reg-disable-widgets` — disables the Widgets board (weather/stock/news feed) via
  `AllowNewsAndInterests`.

Plus common consumer **provisioned app removals** (Candy Crush / King games, Clipchamp,
Bing News, MSN Weather, Solitaire, Xbox extras, Teams consumer, Get Help, Feedback Hub, etc.),
each citing Microsoft's provisioned-apps inventory
(<https://learn.microsoft.com/en-us/windows/application-management/provisioned-apps-windows-client-os>).

**Present but OFF by default (opt-in via `EnableCatalogId`):**

- `remove-edge`, `remove-onedrive` — impactful removals kept opt-in (FR-008).
- `feature-wsl`, `feature-vmplatform` — enable Windows Subsystem for Linux offline
  (see [wsl.md](wsl.md)).

## Auditing a build

After a build, `run-report.json` and the Image BOM list **exactly** which entries were applied
(and which were skipped and why), each with its citation and evidence grade. See
[provenance-bom.md](provenance-bom.md).
