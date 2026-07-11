@{
    # ============================================================================
    # Windows capability (Feature-on-Demand) removal catalog
    # (Constitution Principle II / Principle IV / FR-021).
    #
    # Each entry documents a Windows capability removed from the offline image via
    # Remove-WindowsCapability. Capability names are versioned (e.g. '~~~~0.0.1.0'); the
    # applier matches by the capability Name prefix so it tolerates version drift and
    # records NotApplicable (not Failed) when a capability is absent (FR-021).
    #
    # Capabilities are arch-scoped where relevant (Principle IV). The defaults here target
    # only features Microsoft itself has deprecated, to stay conservative and safe.
    # ============================================================================

    Entries = @(

        @{
            Id             = 'cap-wordpad'
            Type           = 'Capability'
            Action         = 'Remove'
            Target         = 'Microsoft.Windows.WordPad'
            Description    = 'Removes the WordPad optional feature.'
            Rationale      = 'WordPad is deprecated by Microsoft and no longer receives updates; it is not installed by default on new Windows 11 images. Removing it (when present) trims a legacy, unmaintained component. Users needing rich text can use Word or a third-party editor.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/whats-new/deprecated-features'
            Reversible     = $true
            Reversal       = 'Add-WindowsCapability -Online -Name Microsoft.Windows.WordPad~~~~0.0.1.0 (source required).'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'cap-steps-recorder'
            Type           = 'Capability'
            Action         = 'Remove'
            Target         = 'App.StepsRecorder'
            Description    = 'Removes the Steps Recorder (PSR) optional feature.'
            Rationale      = 'Steps Recorder is deprecated by Microsoft and slated for removal; it captures screen steps and is unnecessary on managed images. Deprecated-feature status makes removal low-risk.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/whats-new/deprecated-features'
            Reversible     = $true
            Reversal       = 'Add-WindowsCapability -Online -Name App.StepsRecorder~~~~0.0.1.0 (source required).'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'cap-fax-scan'
            Type           = 'Capability'
            Action         = 'Remove'
            Target         = 'Print.Fax.Scan'
            Description    = 'Removes the Windows Fax and Scan optional feature.'
            Rationale      = 'Legacy fax/scan tooling that most modern managed builds do not use; removing it trims rarely used components. Opt-in for environments that still fax.'
            Citation       = 'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/features-on-demand-non-language-fod'
            Reversible     = $true
            Reversal       = 'Add-WindowsCapability -Online -Name Print.Fax.Scan~~~~0.0.1.0 (source required).'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'cap-media-player-legacy'
            Type           = 'Capability'
            Action         = 'Remove'
            Target         = 'Media.WindowsMediaPlayer'
            Description    = 'Removes the legacy Windows Media Player (WMP) optional feature.'
            Rationale      = 'The legacy WMP is superseded by the modern Media Player app; some environments still rely on the legacy player, so this is opt-in to avoid breaking media workflows.'
            Citation       = 'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/features-on-demand-non-language-fod'
            Reversible     = $true
            Reversal       = 'Add-WindowsCapability -Online -Name Media.WindowsMediaPlayer~~~~0.0.12.0 (source required).'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        }
    )
}
