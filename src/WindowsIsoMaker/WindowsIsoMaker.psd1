@{
    # Pinned module manifest for WindowsIsoMaker (Constitution Principle I & V).
    RootModule        = 'WindowsIsoMaker.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'd8121641-afde-49bf-adf4-cedab60dac30'
    Author            = 'DevSecNinja'
    CompanyName       = 'DevSecNinja'
    Copyright         = '(c) DevSecNinja. All rights reserved.'
    Description       = 'Downloads a Windows 11 base ISO (via vendored Fido), offline-services it with DISM to remove documented, citation-backed bloatware and apply documented registry tweaks, then repackages a bootable, compressed per-architecture ISO artifact.'

    # PowerShell 7+ is primary; 5.1 compatibility is validated for DISM-dependent paths.
    PowerShellVersion = '5.1'

    # Public surface: the 10 exported functions (Constitution Principle I).
    FunctionsToExport = @(
        'Get-BuildConfiguration',
        'Get-Windows11Iso',
        'Expand-WindowsImage',
        'Mount-WindowsBuildImage',
        'Remove-Bloatware',
        'Set-RegistryTweaks',
        'New-BootableIso',
        'Compress-BuildArtifact',
        'Test-ImageIntegrity',
        'Invoke-IsoBuild'
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
                FidoTag          = 'v1.55'
                FidoCommit       = '4e6f25f35112c82ee554bb8c602ce85bdccdfeb7'
            }
        }
    }
}
