# Autounattend.xml generation

The build generates an `Autounattend.xml` **dynamically from the same build configuration**,
**per architecture**, and places it at the root of the produced ISO (FR-027). It is rendered by
[`New-AutounattendXml`](../src/WindowsIsoMaker/Public/New-AutounattendXml.ps1) from
[templates/autounattend/autounattend.xml.template](../templates/autounattend/autounattend.xml.template).

## Why it is complementary (not redundant)

Two different layers configure the image:

| Layer | When | What it does |
|-------|------|--------------|
| DISM offline servicing | Image build time | Remove provisioned apps, apply registry hive tweaks, enable optional features (e.g. WSL). |
| **Autounattend.xml** | Install / OOBE time | Select the edition + install target, skip OOBE prompts, set locale/keyboard/timezone, disk layout, create a local account, run first-logon/SetupComplete commands. |

## Why per-architecture

The unattend `<component>` elements carry a `processorArchitecture` attribute that differs
between `amd64` and `arm64`. Generating the file dynamically ensures the correct value for each
matrix leg — a static file would only be valid for one architecture.

## Configuration

The `Autounattend` block in `config/build.config.psd1`:

```powershell
Autounattend = @{
    Enabled            = $true
    SkipOobe           = $true          # skip the out-of-box experience
    BypassMsAccount    = $true          # bypass the Microsoft-account requirement (default on)
    CreateLocalAccount = $true          # create a local account instead
    LocalAccountName   = 'Admin'        # username (NO password is stored in the file)
    Locale             = 'en-US'        # UI / system language
    UserLocale         = 'en-US'        # region format (dates/times/numbers); defaults to Locale
    KeyboardLayout     = '0409:00000409'
    TimeZone           = 'UTC'          # e.g. 'W. Europe Standard Time'
    ProductKey         = ''             # edition selector (see below)
    DiskId             = 0
    FirstLogonCommands    = @()         # optional command strings run at first logon
    SetupCompleteCommands = @()         # optional SetupComplete.cmd command strings
}
```

Set `Enabled = $false` to skip generation entirely and ship the stock Microsoft OOBE.

## Fully-automated install (edition + partition + key)

The `windowsPE` pass specifies a complete `ImageInstall/OSImage` block so Windows Setup runs the
install phase **hands-off** — no interactive *"which edition?"*, *"where to install?"*, or product-key
pages. This matters on **Windows 11 24H2**, whose redesigned Setup drops to the interactive pages
whenever the install phase isn't fully specified:

- **Edition** — `InstallFrom/MetaData` sets `/IMAGE/NAME` to the install.wim image name, derived from
  `Edition` (`Pro` → `Windows 11 Pro`). Override with `Autounattend.ImageName` for non-standard media
  (e.g. `Windows 11 Enterprise` on a volume-licence WIM).
- **Target** — `InstallTo` points at disk `DiskId`, partition 3 (the Windows primary created by the
  `DiskConfiguration` layout: ESP 260 MB + MSR 16 MB + Windows).
- **Key** — the generic `ProductKey` below selects/validates that edition so the key page is skipped.

All three use `WillShowUI = OnError`, so a genuine mismatch still surfaces the relevant page instead
of hard-failing.

## Product key (edition selector)

Windows Setup shows a product-key page for non-Home editions; a **fully unattended** Pro
install otherwise stops with *"Setup has failed to validate the product key"*. `ProductKey`
controls the `<ProductKey>` element written into the `windowsPE` pass:

| Value | Behaviour |
| --- | --- |
| `''` (default) | Auto-pick Microsoft's public **generic (KMS client setup) key** for the resolved `Edition`. This only *selects the edition* and skips the key page — it does **not** activate Windows (activation still happens later via your own key, a digital licence, or KMS). |
| `'none'` | Omit the element entirely; Setup will prompt for a key. |
| `'XXXXX-XXXXX-XXXXX-XXXXX-XXXXX'` | Use that explicit key. |

The generic keys are published by Microsoft for exactly this purpose — see
[KMS client activation and product keys](https://learn.microsoft.com/windows-server/get-started/kms-client-activation-keys).

## Security note

No password or secret is ever written into `Autounattend.xml` by this tool (Principle VII). If
you need an auto-logon or a pre-set password for a lab image, add it yourself with full
awareness that unattend files are stored in clear text on the media.
