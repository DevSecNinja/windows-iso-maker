@{
    # Pinned module manifest for WindowsIsoMaker (Constitution Principle I & V).
    RootModule        = 'WindowsIsoMaker.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'd8121641-afde-49bf-adf4-cedab60dac30'
    Author            = 'DevSecNinja'
    CompanyName       = 'DevSecNinja'
    Copyright         = '(c) DevSecNinja. All rights reserved.'
    Description       = 'Downloads a Windows 11 base ISO (via a pinned, runtime-fetched Fido), offline-services it with DISM to remove documented, citation-backed bloatware and apply documented registry tweaks, then repackages a bootable, compressed per-architecture ISO artifact.'

    # PowerShell 7+ is primary; 5.1 compatibility is validated for DISM-dependent paths.
    PowerShellVersion = '5.1'

    # Public surface: the 14 exported functions (Constitution Principle I).
    FunctionsToExport = @(
        'Get-BuildConfiguration',
        'Get-Windows11Iso',
        'Expand-WindowsImage',
        'Mount-WindowsBuildImage',
        'Invoke-CatalogEntry',
        'Remove-Bloatware',
        'Set-RegistryTweaks',
        'Enable-WindowsFeature',
        'New-AutounattendXml',
        'New-BootableIso',
        'Compress-BuildArtifact',
        'Test-ImageIntegrity',
        'Export-ImageBom',
        'Export-CatalogManifest',
        'Invoke-IsoBuild',
        'Invoke-PostInstallSetup'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    # Documented minimum tooling versions. These are NOT auto-imported at build time
    # (DISM lives on the host); they are pinned here for local/CI test parity.
    # RequiredModules is intentionally left empty so the module imports on non-Windows
    # hosts for lint/schema tests; Pester v5+ and PSScriptAnalyzer are installed by CI.
    RequiredModules   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Windows11', 'ISO', 'DISM', 'Debloat', 'DevSecOps')
            LicenseUri   = 'https://github.com/DevSecNinja/windows-iso-maker/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/DevSecNinja/windows-iso-maker'
            ReleaseNotes = 'Initial release: modular Windows 11 ISO builder & debloater with documented change catalog.'

            # Documented tool/module minimums (Principle V reproducibility).
            RequiredToolingMinimums = @{
                Pester           = '5.5.0'
                PSScriptAnalyzer = '1.21.0'
                WindowsAdk       = '10.1.22621' # Deployment Tools (oscdimg)
                FidoTag          = 'v1.70'
                FidoCommit       = '3d47260b8915385c58e20c73e24b36e9a9536f3f'
            }
        }
    }
}
