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
- **Disk formatting** — `DiskConfiguration/ModifyPartitions` formats each created partition: the ESP
  (partition 1) as **FAT32** and the Windows partition (partition 3) as **NTFS** (drive `C:`); the MSR
  (partition 2) is deliberately left unformatted. The FAT32 format on the ESP is required — without it
  Setup installs Windows but then fails at the *Finalize / Update Boot Code* step
  (`BFSVC ServicingBootFiles`, error `0x800703ED` = the volume has no recognized file system), because
  the bootloader cannot be written to an unformatted system partition.
- **Key** — the generic `ProductKey` below selects/validates that edition so the key page is skipped.

The `ImageInstall`/`OSImage` block uses `WillShowUI = Never`, and so does the `ProductKey` element.
On **Windows 11 24H2** the redesigned Setup treats `OnError` as "show the interactive page on any
validation hiccup", which is what made unattended Pro installs stop on the *"Setup has failed to
validate the product key"* page even with a correct generic key. `Never` keeps the install fully
hands-off; a genuinely wrong key or image name hard-fails (and is captured by the boot-test log
harvest) instead of silently blocking on an interactive page.

## Product key (edition selector)

The **edition is selected by the image metadata** (`ImageInstall/OSImage/InstallFrom/MetaData`,
`/IMAGE/NAME` = e.g. `Windows 11 Pro`) that this tool always writes into the `windowsPE` pass.
Per Microsoft's *Automate Windows Setup* docs, configuring that image metadata **also skips the
"Type your product key" page** — so **no `<ProductKey>` element is needed at all** for a fully
unattended install, and none is emitted by default.

This matters on **Windows 11 24H2**: its redesigned Setup validates an explicit generic key more
strictly and stops with *"Setup has failed to validate the product key"* (even with `WillShowUI`
set), so emitting a redundant generic key actively breaks the unattended install. `ProductKey`
controls whether (and which) `<ProductKey>` element is written:

| Value | Behaviour |
| --- | --- |
| `''` (default) | **Omit** the `<ProductKey>` element; the image metadata selects the edition and skips the key page. Recommended (24H2-safe). |
| `'none'` | Also omit the element. |
| `'generic'` / `'auto'` | Inject Microsoft's public **generic (KMS client setup) key** for the resolved `Edition`. Only *selects the edition*; does **not** activate Windows. May fail on 24H2 — prefer the default. |
| `'XXXXX-XXXXX-XXXXX-XXXXX-XXXXX'` | Use that explicit key (e.g. a real retail key). |

When a key is emitted it uses `WillShowUI = Never` so Setup stays hands-off. The generic keys are
published by Microsoft — see
[KMS client activation and product keys](https://learn.microsoft.com/windows-server/get-started/kms-client-activation-keys).

## Security note

No password or secret is ever written into `Autounattend.xml` by this tool (Principle VII). If
you need an auto-logon or a pre-set password for a lab image, add it yourself with full
awareness that unattend files are stored in clear text on the media.
