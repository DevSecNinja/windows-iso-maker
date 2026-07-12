# Windows Subsystem for Linux (WSL)

WSL is shipped as an **opt-in** catalog entry that is **off by default**. Enabling it turns on
the required Windows optional features on the offline image so the finished ISO is "WSL-ready".

## Catalog entries

In [config/catalog.capabilities.psd1](../config/catalog.capabilities.psd1):

- `feature-wsl` — enables `Microsoft-Windows-Subsystem-Linux`
- `feature-vmplatform` — enables `VirtualMachinePlatform` (required for WSL 2)

Both use `Action = 'EnableOptionalFeature'`, which
[`Enable-WindowsFeature`](../src/WindowsIsoMaker/Public/Enable-WindowsFeature.ps1) applies to
the mounted image via `Enable-WindowsOptionalFeature -Path <mount>`.

## Enabling it

```powershell
# Local
./build.ps1 -EnableCatalogId feature-wsl,feature-vmplatform

# In config/build.config.psd1
Toggles = @{ 'feature-wsl' = $true; 'feature-vmplatform' = $true }
```

In the `build-image.yml` workflow, set the `enable_catalog_id` input to
`feature-wsl,feature-vmplatform`.

## Important: first-boot behaviour (a Windows constraint)

Enabling the optional features **offline** only turns on the platform. The **WSL 2 kernel** and
any **Linux distribution** are downloaded **online on first boot**, e.g.:

```powershell
wsl --update
wsl --install -d Ubuntu
```

This is a Microsoft platform constraint — the kernel/distribution are serviced from Microsoft's
online sources and cannot be provisioned into an offline image by this tool.

## Why opt-in

Enabling WSL adds virtualization features and attack surface that not every image needs, so it
is off by default (Principle VI). It is a grade-1, reversible change; to undo it on a running
system:

```powershell
Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
```
