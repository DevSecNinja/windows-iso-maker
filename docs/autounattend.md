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
| **Autounattend.xml** | Install / OOBE time | Skip OOBE prompts, set locale/keyboard/timezone, disk layout, create a local account, run first-logon/SetupComplete commands. |

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
    Locale             = 'en-US'
    KeyboardLayout     = '0409:00000409'
    TimeZone           = 'UTC'          # e.g. 'W. Europe Standard Time'
    DiskId             = 0
    FirstLogonCommands    = @()         # optional command strings run at first logon
    SetupCompleteCommands = @()         # optional SetupComplete.cmd command strings
}
```

Set `Enabled = $false` to skip generation entirely and ship the stock Microsoft OOBE.

## Security note

No password or secret is ever written into `Autounattend.xml` by this tool (Principle VII). If
you need an auto-logon or a pre-set password for a lab image, add it yourself with full
awareness that unattend files are stored in clear text on the media.
