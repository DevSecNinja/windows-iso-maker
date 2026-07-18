@{
    # ============================================================================
    # Windows capability / optional-feature catalog
    # (Constitution Principle II v1.1.0 / Principle IV / FR-021 / FR-025 / FR-026).
    #
    # SCHEMA v2: entries carry an `Action` + `EvidenceGrade`. Two families live here:
    #   * RemoveCapability  — remove a Feature-on-Demand capability via Remove-WindowsCapability.
    #                         Capability names are versioned ('~~~~0.0.1.0'); the applier matches
    #                         by Name prefix and records NotApplicable (not Failed) when absent.
    #   * EnableOptionalFeature — enable an optional feature via Enable-WindowsOptionalFeature -Path
    #                         (additive, FR-025). Used for the opt-in WSL platform features.
    #
    # A grade-3 entry MUST be DefaultEnabled = $false (enforced by the schema tests).
    # ============================================================================

    Entries = @(

        # --- Deprecated capabilities removed by default (Microsoft-documented) ------------

        @{
            Id             = 'cap-wordpad'
            Type           = 'Capability'
            Action         = 'RemoveCapability'
            Category       = 'Legacy components'
            Target         = 'Microsoft.Windows.WordPad'
            Description    = 'Removes the WordPad optional feature.'
            Rationale      = 'WordPad is deprecated by Microsoft and no longer receives updates; it is not installed by default on new Windows 11 images. Removing it (when present) trims a legacy, unmaintained component. Users needing rich text can use Word or a third-party editor.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/whats-new/deprecated-features'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Add-WindowsCapability -Online -Name Microsoft.Windows.WordPad~~~~0.0.1.0 (source required).'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'cap-steps-recorder'
            Type           = 'Capability'
            Action         = 'RemoveCapability'
            Category       = 'Legacy components'
            Target         = 'App.StepsRecorder'
            Description    = 'Removes the Steps Recorder (PSR) optional feature.'
            Rationale      = 'Steps Recorder is deprecated by Microsoft and slated for removal; it captures screen steps and is unnecessary on managed images. Deprecated-feature status makes removal low-risk.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/whats-new/deprecated-features'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Add-WindowsCapability -Online -Name App.StepsRecorder~~~~0.0.1.0 (source required).'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'cap-fax-scan'
            Type           = 'Capability'
            Action         = 'RemoveCapability'
            Category       = 'Legacy components'
            Target         = 'Print.Fax.Scan'
            Description    = 'Removes the Windows Fax and Scan optional feature.'
            Rationale      = 'Legacy fax/scan tooling that most modern managed builds do not use; removing it trims rarely used components. Opt-in for environments that still fax.'
            Citation       = 'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/features-on-demand-non-language-fod'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Add-WindowsCapability -Online -Name Print.Fax.Scan~~~~0.0.1.0 (source required).'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'cap-media-player-legacy'
            Type           = 'Capability'
            Action         = 'RemoveCapability'
            Category       = 'Legacy components'
            Target         = 'Media.WindowsMediaPlayer'
            Description    = 'Removes the legacy Windows Media Player (WMP) optional feature.'
            Rationale      = 'The legacy WMP is superseded by the modern Media Player app; some environments still rely on the legacy player, so this is opt-in to avoid breaking media workflows.'
            Citation       = 'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/features-on-demand-non-language-fod'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Add-WindowsCapability -Online -Name Media.WindowsMediaPlayer~~~~0.0.12.0 (source required).'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        # --- Opt-in additive features: WSL (FR-025). --------------------------------------
        # Enabling these OFFLINE only pre-stages the platform optional features. The WSL2
        # kernel and any Linux distribution are downloaded ONLINE on first boot (a Windows
        # platform constraint) — see docs/wsl.md. Kept opt-in (DefaultEnabled = $false).

        @{
            Id             = 'feature-wsl'
            Type           = 'OptionalFeature'
            Action         = 'EnableOptionalFeature'
            Category       = 'Development'
            Profiles       = @('opinionated')
            Target         = 'Microsoft-Windows-Subsystem-Linux'
            Description    = 'Enables the Windows Subsystem for Linux optional feature on the offline image.'
            Rationale      = 'Pre-enables the WSL platform feature so the finished image ships WSL-ready. This offline step only turns on the OS feature; the actual WSL2 kernel and the chosen Linux distribution are installed online on first boot (`wsl --install`/`wsl --update`), which is a Microsoft platform constraint, not a limitation of this tool. Opt-in because it adds attack surface not everyone wants.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/wsl/install-on-server'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux (or omit the feature-wsl catalog id).'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'feature-vmplatform'
            Type           = 'OptionalFeature'
            Action         = 'EnableOptionalFeature'
            Category       = 'Development'
            Profiles       = @('opinionated')
            Target         = 'VirtualMachinePlatform'
            Description    = 'Enables the Virtual Machine Platform optional feature (WSL2 dependency) on the offline image.'
            Rationale      = 'WSL2 runs a lightweight utility VM and requires the Virtual Machine Platform feature. Enable it alongside feature-wsl for a WSL2-capable image. Like feature-wsl the actual WSL2 kernel is fetched online on first boot. Opt-in.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/wsl/install-on-server'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Disable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform (or omit the feature-vmplatform catalog id).'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        # --- Legacy / deprecated component removal (opt-in) --------------------------------

        @{
            Id             = 'cap-powershell-ise'
            Type           = 'Capability'
            Action         = 'RemoveCapability'
            Category       = 'Legacy components'
            Target         = 'Microsoft.Windows.PowerShell.ISE'
            Description    = 'Removes the Windows PowerShell ISE optional feature (Feature on Demand).'
            Rationale      = 'The PowerShell ISE is a legacy editor that is no longer being developed (Microsoft recommends Visual Studio Code with the PowerShell extension, and it does not support PowerShell 7+). It ships as the Feature-on-Demand capability Microsoft.Windows.PowerShell.ISE and can be removed cleanly and reversibly. Kept opt-in (only removed by the aggressive/opinionated profiles) so environments that still use the ISE are unaffected.'
            Citation       = 'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/features-on-demand-non-language-fod'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Add-WindowsCapability -Online -Name Microsoft.Windows.PowerShell.ISE~~~~0.0.1.0 (source required).'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        # --- Impactful first-party component removal (FR-008 / Principle VI: opt-in, default OFF) ---
        # Recall ships as an optional FEATURE (not a capability), so it is removed with
        # Disable-WindowsOptionalFeature -Remove (offline: dism /Disable-Feature /Remove), which
        # strips the component payload — beyond the reg-disable-recall POLICY, which only stops
        # snapshots. Constitution requires impactful first-party removals (Recall) to be opt-in.
        @{
            Id             = 'feature-remove-recall'
            Type           = 'OptionalFeature'
            Action         = 'DisableOptionalFeature'
            Category       = 'Privacy & telemetry'
            Profiles       = @('opinionated')
            Target         = 'Recall'
            Description    = 'Disables and removes the Windows Recall optional feature payload (the "Recall" component installed as a system component), going beyond the reg-disable-recall policy.'
            Rationale      = 'reg-disable-recall sets the DisableAIDataAnalysis policy so Recall stops saving snapshots, but the Recall component itself remains installed. Microsoft documents removing the Recall bits entirely with `Disable-WindowsOptionalFeature -Online -FeatureName "Recall" -Remove` (offline equivalent: dism /Disable-Feature /FeatureName:Recall /Remove). This eliminates the component rather than only disabling it. Recall is an impactful first-party feature, so per the constitution this removal is opt-in and default OFF (delivered via the opinionated profile or an explicit EnableCatalogId).'
            Citation       = 'https://learn.microsoft.com/en-us/windows/client-management/manage-recall'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Enable-WindowsOptionalFeature -Online -FeatureName Recall (source required), or omit the feature-remove-recall catalog id.'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        }
    )
}
