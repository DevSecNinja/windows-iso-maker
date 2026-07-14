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
        }
    )
}
