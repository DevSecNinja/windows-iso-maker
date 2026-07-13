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
| **Autounattend.xml** | Install / OOBE time | Select the edition + install target, skip OOBE prompts, set locale/keyboard/timezone, disk layout, create a local account **or present the Entra ID sign-in**, run first-logon/SetupComplete commands. |

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
    AccountMode        = 'local'        # 'local' (local admin) | 'entra' (join Entra ID / Intune)
    BypassMsAccount    = $true          # bypass the Microsoft-account requirement (local mode)
    CreateLocalAccount = $true          # create a local account (local mode)
    LocalAccountName   = 'Admin'        # username (NO password is stored in the file)
    Locale             = 'en-US'        # UI / system language
    UserLocale         = 'en-US'        # region format (dates/times/numbers); defaults to Locale
    KeyboardLayout     = '0409:00000409'  # input locale; 'opinionated' profile defaults to '0409:00020409' (US-International)
    TimeZone           = 'UTC'          # e.g. 'W. Europe Standard Time'
    ProductKey         = ''             # edition selector (see below)
    DiskId             = 0
    FirstLogonCommands    = @()         # optional command strings run at first logon
    SetupCompleteCommands = @()         # optional SetupComplete.cmd command strings
}
```

Set `Enabled = $false` to skip generation entirely and ship the stock Microsoft OOBE.

## Account provisioning (local vs Entra ID join)

`AccountMode` chooses how the first account is set up during OOBE:

| Mode | Behaviour | Use it for |
| --- | --- | --- |
| `'local'` (default) | Creates the local admin account (`LocalAccountName`) and hides the online-account screens. Fully hands-off — no sign-in required. | Standalone / gaming PCs, lab images. |
| `'entra'` (aliases `entraid`, `azuread`) | Does **not** create a local account. Leaves the *"Set up for work or school"* sign-in visible (and allows Wi-Fi setup) so you sign in with your **Entra ID** identity, which **joins Entra ID (Azure AD)** and **auto-enrolls into Intune** where configured. | Managed / corporate devices. |

> **Entra join is interactive by design.** A real Entra join needs credentials, so this mode
> *prepares* OOBE to present the Entra sign-in instead of forcing a local account — you still type
> your credentials once. A fully silent, zero-touch Entra join requires **Windows Autopilot** or a
> **provisioning package (PPKG)**, which are out of scope for the answer file.

You can also set it per build without editing the config:

```powershell
./build.ps1 -Edition Pro -ProductKey '<genuine-key>' -AccountMode entra
./scripts/Invoke-QuickBootTest.ps1 -Edition Home -AccountMode entra
```

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
  the bootloader cannot be written to an unformatted system partition. **Element order matters:** inside
  each `<ModifyPartition>` the children must follow the unattend schema sequence — in particular
  `<Label>` (and `<Letter>`) must come *before* `<Format>`. The Windows unattend parser is
  sequence-sensitive: an out-of-order `<Format>` is *silently dropped* (Setup neither errors nor
  formats), leaving the ESP RAW and reproducing the `0x800703ED` Finalize failure even though the
  answer file "looks" correct. Microsoft's own sample and known-good answer files use
  `Order, PartitionID, Label, [Letter,] Format`.
- **Key** — see the *Product key* section below. The key (if any) is applied in the **`specialize`**
  pass, not `windowsPE`, so 24H2's strict windowsPE key validation can't hard-stop the install; the
  edition itself is always chosen by the image metadata above.

The `ImageInstall`/`OSImage` block uses `WillShowUI = Never`.
On **Windows 11 24H2** the rearchitected Setup treats `OnError` as "show the interactive page on any
validation hiccup", so `Never` keeps image selection hands-off; a genuinely wrong image name
hard-fails (and is captured by the boot-test log harvest) instead of silently blocking on a page.

## Product key (edition selector)

The **edition is selected by the image metadata** (`ImageInstall/OSImage/InstallFrom/MetaData`,
`/IMAGE/NAME` = e.g. `Windows 11 Pro`) that this tool always writes into the `windowsPE` pass. That
alone is enough for Setup to skip the *"which edition?"* and product-key pages — no key is needed in
`windowsPE` to get a hands-off install.

**Windows 11 24H2's rearchitected Setup (`windlp`) validates any `windowsPE` product key and rejects
generic keys on multi-edition media** — it hard-stops with *"Setup has failed to validate the product
key"* even for the public generic/retail keys, a connected network, and `WillShowUI = Never`. So this
tool **never writes a `<ProductKey>` into the `windowsPE` pass**. Instead, any configured key is
applied in the **`specialize`** pass (`Microsoft-Windows-Shell-Setup/ProductKey`), which runs after
the image is applied and is not subject to the windowsPE validation hard-stop. This is Microsoft's
documented approach for unattended installs from multi-edition install.wim media.

By **default** no key is configured at all: Setup installs the edition chosen by the metadata and the
OS stays **unlicensed** until a key is entered later (a note is logged at generation time). Configure
a key to have it applied automatically in `specialize`.

`ProductKey` controls whether (and which) `<ProductKey>` element is written into the `specialize` pass:

| Value | Behaviour |
| --- | --- |
| `''` (default) / `'none'` | **No key.** Setup installs the metadata-selected edition hands-off; the OS is unlicensed until a key is entered. |
| `'XXXXX-XXXXX-XXXXX-XXXXX-XXXXX'` | Apply that explicit, **genuine** key in `specialize` (activates when valid). |
| `'generic'` / `'auto'` | Apply the resolved `Edition`'s public **generic / default retail** key in `specialize` (non-activating; selects/keeps the edition without prompting). Works for Home and other editions because it is no longer validated in `windowsPE`. |

The `build.ps1` / `Invoke-IsoBuild` / `Invoke-QuickBootTest.ps1` `-UseGenericProductKey` switch is a
shorthand that sets `ProductKey = 'generic'` for the resolved edition (an explicit `-ProductKey`
takes precedence). Use it for a fully hands-off **Home** build.

`scripts/Invoke-QuickBootTest.ps1` exposes `-Edition`, `-ProductKey`, `-UseGenericProductKey`, and
`-Profile` overrides, so you can test the hands-off path with `-Edition Home -UseGenericProductKey`
and do a keyed build with `-ProductKey '<your-key>'`. `-Profile` accepts one or more profiles (e.g.
`-Profile gaming,opinionated`);
because a quick boot test reuses the already-serviced `media\` folder it does **not** re-run debloat,
but it re-derives the answer file, so profile-driven `Autounattend` settings (such as the opinionated
United States-International keyboard) are reflected in the boot test.

To boot-test several editions at once, pass `-Isolated` to each parallel window. Isolated runs get a
uniquely-named `Autounattend-<tag>.xml` and ISO, and ISO authoring is serialized with a named mutex
(the answer file is staged inside the shared `media\` tree before imaging), so the fast rebuilds are
atomic while the slow VM boot tests overlap. Without `-Isolated`, concurrent runs share
`media\Autounattend.xml` and the deterministic ISO path and will clobber each other.

The generic keys are published by Microsoft — see
[KMS client activation and product keys](https://learn.microsoft.com/windows-server/get-started/kms-client-activation-keys).

## Security note

No password or secret is ever written into `Autounattend.xml` by this tool (Principle VII). If
you need an auto-logon or a pre-set password for a lab image, add it yourself with full
awareness that unattend files are stored in clear text on the media.
