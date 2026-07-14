# Design: Bake in Microsoft Security Baseline policies (`hardened` profile)

> Status: **Design / proposal** — not yet implemented.
> Scope chosen: **Option A — a curated, registry-only subset of the Microsoft Security
> Baseline, baked into the offline image, opt-in, fully reversible.** No first-boot
> `secedit`/`auditpol`, no bundled `LGPO.exe`.

## 1. Goal

Let a build optionally bake a curated set of **Microsoft Security Baseline** policies
(from the [Security Compliance Toolkit](https://www.microsoft.com/en-us/download/details.aspx?id=55319),
specifically the *Windows 11 security baseline*) into the image, using the module's
existing offline-hive registry machinery. Selectable via a new **`hardened`** build
profile, with per-setting granularity through the existing `Toggles` /
`EnableCatalogId` / `DisableCatalogId` mechanism.

### Non-goals (deliberately out of scope for this MVP)

The full baseline is a Group Policy backup with four parts. Only part (1) is
registry-expressible and therefore in scope:

| Baseline component | Mechanism | In scope? |
|---|---|---|
| `registry.pol` (Administrative Templates) | Registry policy values | ✅ **Yes** — offline hive writes |
| `GptTmpl.inf` (password/lockout/user-rights/security-options) | `secedit` vs SAM/SECURITY DB | ❌ No (would need first-boot) |
| `audit.csv` (advanced audit policy) | `auditpol /restore` | ❌ No (would need first-boot) |
| ADMX / Defender / Exploit-Guard extras | mixed | ❌ No |

A later increment can add a first-boot `SetupComplete.cmd` step for the `.inf`/audit
remainder (there is already `Autounattend.SetupCompleteCommands`). This design keeps the
"everything baked offline, nothing runs at first boot" property.

## 2. Why this fits the existing architecture

`Set-RegistryTweaks` already loads the offline `SOFTWARE`/`SYSTEM`/`DEFAULT` hives from
the mounted image and writes policy values into them, idempotently, with `-WhatIf`
support and per-entry `ChangeResult`s. Security-baseline Admin-Template settings **are**
policy registry values, so they map 1:1 onto the current catalog entry shape
(`Action = 'SetRegistry'`, `Target = @{ Hive; Path; Name; Kind; Value }`). No new
servicing code is required — only new catalog data plus profile wiring.

Every entry automatically flows into the RunReport, the Image BOM, and the showcase
site, exactly like today's privacy tweaks.

## 3. Data model — new catalog file `config/catalog.baseline.psd1`

`Import-ChangeCatalog` globs `config/catalog.*.psd1`, so a new file is picked up with no
loader change. Each entry follows the **schema v2** contract enforced by
`tests/Catalog.Schema.Tests.ps1`:

```powershell
@{
    Id             = 'sec-disable-autorun'
    Type           = 'Registry'
    Action         = 'SetRegistry'
    Target         = @{
        Hive  = 'SOFTWARE'
        Path  = 'Policies\Microsoft\Windows\Explorer'
        Name  = 'NoDriveTypeAutoRun'
        Kind  = 'DWord'
        Value = 255            # 0xFF: disable Autorun on all drive types
    }
    Description    = 'Disables AutoRun/AutoPlay on all drive types.'
    Rationale      = 'AutoRun is a classic removable-media malware vector; the Windows security baseline sets NoDriveTypeAutoRun=0xFF. Reversible and low-impact.'
    Citation       = 'https://learn.microsoft.com/en-us/windows/security/operating-system-security/...'  # baseline doc
    EvidenceGrade  = 1          # official Microsoft baseline
    Reversible     = $true
    Reversal       = 'Delete NoDriveTypeAutoRun (or set 0) under SOFTWARE\Policies\Microsoft\Windows\Explorer.'
    DefaultEnabled = $false     # opt-in ONLY — never in default/minimal
    Category       = 'Security' # new taxonomy value (see §5)
    Profiles       = @('hardened')
    Arch           = @('amd64', 'arm64')
}
```

**Invariants for every baseline entry:**
- `EvidenceGrade = 1` (official Microsoft baseline).
- `DefaultEnabled = $false` — the baseline is opinionated and can reduce usability, so it
  must never be on in `default`/`minimal`/`aggressive`.
- `Reversible = $true` with an explicit `Reversal` string (all are policy value
  set/deletes).
- `Profiles = @('hardened')` — the profile-membership tag that the new profile keys off.
- `Category = 'Security'` — a new semantic category (see §5).
- File header comment records the **exact baseline version** the values were transcribed
  from (e.g. *"Windows 11 24H2 Security Baseline, SCT package version YYYY-MM"*), because
  the SCT zips are not Renovate-trackable and must be re-pinned by hand when Microsoft
  ships a new baseline.

### 3.1 Curated initial set (registry-expressible, low lock-out risk)

Chosen for high security value and low chance of locking out a single-user machine.
Final list to be reconciled against the pinned baseline spreadsheet during
implementation. `SYSTEM`-hive items are noted; the rest are `SOFTWARE`.

| Id | Setting | Risk |
|---|---|---|
| `sec-disable-autorun` | `Explorer\NoDriveTypeAutoRun=0xFF` + `NoAutorun=1` | low |
| `sec-smartscreen-explorer` | `System\EnableSmartScreen=1`, `ShellSmartScreenLevel=Block` | low |
| `sec-uac-consent-admin` | `System\ConsentPromptBehaviorAdmin=2`, `PromptOnSecureDesktop=1` | low |
| `sec-disable-insecure-guest` | `LanmanWorkstation\AllowInsecureGuestAuth=0` | low |
| `sec-wdigest-no-cleartext` | `SYSTEM` WDigest `UseLogonCredential=0` | low |
| `sec-no-lm-hash` | `SYSTEM` LSA `NoLMHash=1` | low |
| `sec-disable-llmnr` | `Policies\Microsoft\Windows NT\DNSClient\EnableMulticast=0` | low |
| `sec-restrict-anonymous-sam` | `SYSTEM` LSA `RestrictAnonymousSAM=1`, `EveryoneIncludesAnonymous=0` | low |
| `sec-no-installer-elevated` | `Policies\Microsoft\Windows\Installer\AlwaysInstallElevated=0` | low |
| `sec-enumerate-admins-off` | `CredUI\EnumerateAdministrators=0` | low |
| `sec-lsa-runasppl` | `SYSTEM` LSA `RunAsPPL=1` | medium (driver compat) |
| `sec-smb-client-signing` | `LanmanWorkstation\RequireSecuritySignature=1` | medium (old NAS) |

All of the above — **including the medium-risk `RunAsPPL` and SMB client signing** — are
tagged `Profiles=@('hardened')` and therefore enabled by the `hardened` profile. Their
medium-risk items remain individually removable via `DisableCatalogId` (e.g.
`DisableCatalogId = @('sec-smb-client-signing')`).

**Deliberately excluded** (high lock-out / breakage risk, or not registry-expressible):
account lockout & password-complexity policy (`.inf` only), forced SMB *server* signing,
disabling all legacy protocols, screen-saver inactivity lock, and anything that changes
sign-in requirements. These belong to a future first-boot `secedit` increment, if ever.

## 4. Profile wiring — the `hardened` profile

`hardened` is **additive over `default`**, mirroring how `opinionated` layers on top of
`aggressive`. So:
- `Profile = 'hardened'` → default debloat baseline **plus** all `Profiles=@('hardened')`
  entries. (A standalone `hardened` still keeps the default privacy tweaks — no surprise
  loss.)
- Profiles union as today, so `@('aggressive','hardened')` = aggressive debloat + baseline,
  `@('minimal','hardened')`… well, `minimal` union `hardened` = minimal tweaks + baseline
  (each profile contributes independently; `hardened` only adds its tagged entries and the
  default set).

Add a case to `Test-CatalogEntryInProfile` in
`src/WindowsIsoMaker/Private/Resolve-CatalogSelection.ps1`:

```powershell
'hardened' {
    # Default debloat baseline PLUS the curated security-baseline registry pack
    # (tagged Profiles=@('hardened')). Opt-in only; never in default/minimal/aggressive.
    if ((Get-CatalogEntryProfiles -Entry $Entry) -contains 'hardened') { return $true }
    return $isDefault
}
```

Granular control still works for free: because each baseline setting is a normal catalog
id, a user on any profile can cherry-pick with `EnableCatalogId = @('sec-lsa-runasppl')`
or exclude one with `DisableCatalogId = @('sec-smb-client-signing')`.

## 5. New `Security` category

The schema test's allowed `Category` taxonomy has no security bucket. Add **`Security`**
to:
- `tests/Catalog.Schema.Tests.ps1` (`$allowedCategories`).
- Any site grouping/legend that enumerates categories (`site/assets/app.js`,
  `site/index.html`) — verify during implementation.

(Alternative: reuse `Privacy & telemetry`. Rejected — a distinct `Security` group reads
better on the site and in the BOM.)

## 6. Exact file touch-list

**New:**
- `config/catalog.baseline.psd1` — the curated entries (with version header).

**Profile `ValidateSet` — add `'hardened'` (7 spots):**
- `build.ps1` (~L114)
- `src/WindowsIsoMaker/Public/Invoke-IsoBuild.ps1` (~L101)
- `src/WindowsIsoMaker/Public/Get-BuildConfiguration.ps1` (~L75 param + ~L202 `$validProfiles`)
- `src/WindowsIsoMaker/Private/Resolve-CatalogSelection.ps1` (~L66 + ~L184)
- `scripts/Invoke-QuickBootTest.ps1` (~L106)

**Profile logic:**
- `src/WindowsIsoMaker/Private/Resolve-CatalogSelection.ps1` — new `hardened` switch case
  (above) + doc-comment updates.

**Schema / taxonomy:**
- `tests/Catalog.Schema.Tests.ps1` — add `'hardened'` to allowed `Profiles` tags and
  `'Security'` to `$allowedCategories`.

**Site manifest:**
- `src/WindowsIsoMaker/Public/Export-CatalogManifest.ps1` — add a `hardened` entry to the
  `$profiles` descriptor list so the published `site/data/catalog.json` includes it.
- Regenerate `site/data/catalog.json` via `Export-CatalogManifest`.

**Docs / config comments:**
- `README.md`, `docs/usage.md`, `docs/change-rationale.md`, `config/build.config.psd1`
  profile comments — mention the `hardened` profile and the `Security` category.
- This file (`docs/security-baseline.md`) as the reference/provenance page.

**Tests:**
- `tests/Resolve-CatalogSelection.Tests.ps1` — `hardened` selects the tagged entries +
  default set; unions correctly; `DisableCatalogId` removes a baseline id.
- `tests/Get-BuildConfiguration.Tests.ps1` — `hardened` is a valid profile.
- `tests/Export-CatalogManifest.Tests.ps1` — manifest lists `hardened`.
- `tests/Set-RegistryTweaks.Tests.ps1` — (covered already; baseline entries are ordinary
  `SetRegistry` entries) optionally assert a baseline entry applies to the right hive.

## 7. Provenance, versioning & BOM

- Each entry's `Citation` points at the official Microsoft baseline/Learn documentation
  for that setting; `EvidenceGrade = 1`.
- The catalog file header records the **baseline package version** the values came from.
  Because SCT zips aren't Renovate-trackable, bumping to a new Windows release's baseline
  is a manual PR (re-transcribe changed values, update the header + citations).
- No behavioural BOM change needed: baseline entries appear in the RunReport and Image BOM
  through the existing catalog pipeline, so a `hardened` build is fully auditable.

## 8. Safety properties (Principle VI)

- **Opt-in only** — never enabled by `default`/`minimal`/`aggressive`/`gaming`.
- **Pure offline** — only offline-hive registry writes; nothing executes at first boot.
- **Idempotent + `-WhatIf`** — inherited from `Set-RegistryTweaks`.
- **Reversible** — every entry documents a `Reversal`; higher-risk items
  (`RunAsPPL`, SMB client signing) are called out and can be excluded individually.

## 9. Open decisions for @DevSecNinja

1. **Category:** new `Security` bucket (recommended) vs reuse `Privacy & telemetry`?
2. **Profile semantics:** `hardened` = *default + baseline* (recommended, matches
   `opinionated`) vs *baseline-only*?
3. ~~Higher-risk items in the profile?~~ **Decided:** `RunAsPPL` and SMB client signing
   **are** included in the `hardened` profile; both stay individually removable via
   `DisableCatalogId`.
4. **Final setting list:** confirm the §3.1 set, or widen/narrow it.
