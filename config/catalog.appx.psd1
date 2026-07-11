@{
    # ============================================================================
    # Provisioned Appx removal catalog (Constitution Principle II / FR-006).
    #
    # Each entry documents a provisioned (per-image) Windows Store app that is removed
    # from the offline image via Remove-AppxProvisionedPackage. Every entry carries a
    # Description (WHAT), Rationale (WHY it is safe/desirable), and Citation (authoritative
    # source). 'Target' is matched against the provisioned package DisplayName (supports
    # wildcards). Removing a provisioned package prevents it from being installed for new
    # user profiles; it does not touch already-provisioned system components.
    #
    # Primary citation for the provisioned-apps inventory:
    #   https://learn.microsoft.com/en-us/windows/application-management/provisioned-apps-windows-client-os
    # ============================================================================

    # This file returns an ARRAY of ChangeCatalogEntry hashtables.
    Entries = @(

        @{
            Id             = 'appx-clipchamp'
            Type           = 'Appx'
            Action         = 'Remove'
            Target         = 'Clipchamp.Clipchamp'
            Description    = 'Removes the Clipchamp video editor provisioned app.'
            Rationale      = 'Clipchamp is a consumer video editor bundled with Windows 11 that most managed/clean builds do not require; removing the provisioned package prevents auto-install for new users. It can be reinstalled from the Store on demand.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/application-management/provisioned-apps-windows-client-os'
            Reversible     = $true
            Reversal       = 'Reinstall from the Microsoft Store (Clipchamp) or re-add the provisioned package with Add-AppxProvisionedPackage.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'appx-bingnews'
            Type           = 'Appx'
            Action         = 'Remove'
            Target         = 'Microsoft.BingNews'
            Description    = 'Removes the Microsoft News (Bing News) provisioned app.'
            Rationale      = 'Bing News is a consumer content/advertising app not needed for a clean baseline; it periodically fetches feed content and notifications. Reinstallable from the Store.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/application-management/provisioned-apps-windows-client-os'
            Reversible     = $true
            Reversal       = 'Reinstall Microsoft News from the Microsoft Store.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'appx-bingweather'
            Type           = 'Appx'
            Action         = 'Remove'
            Target         = 'Microsoft.BingWeather'
            Description    = 'Removes the MSN Weather (Bing Weather) provisioned app.'
            Rationale      = 'MSN Weather is a consumer app that is redundant on managed builds and is a common bloatware removal; it is not a Windows component. Reinstallable from the Store.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/application-management/provisioned-apps-windows-client-os'
            Reversible     = $true
            Reversal       = 'Reinstall MSN Weather from the Microsoft Store.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'appx-solitaire'
            Type           = 'Appx'
            Action         = 'Remove'
            Target         = 'Microsoft.MicrosoftSolitaireCollection'
            Description    = 'Removes the Microsoft Solitaire Collection provisioned app.'
            Rationale      = 'A consumer game bundled with Windows; not required for productivity/managed images and shows ads. Reinstallable from the Store.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/application-management/provisioned-apps-windows-client-os'
            Reversible     = $true
            Reversal       = 'Reinstall Microsoft Solitaire Collection from the Microsoft Store.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'appx-xbox-gaming-overlay'
            Type           = 'Appx'
            Action         = 'Remove'
            Target         = 'Microsoft.XboxGamingOverlay'
            Description    = 'Removes the Xbox Game Bar overlay provisioned app.'
            Rationale      = 'The Xbox Game Bar overlay is a gaming feature unnecessary on non-gaming/managed builds. Note: fully disabling Game Bar may require the associated registry tweak; this only removes the provisioned app for new users.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/application-management/provisioned-apps-windows-client-os'
            Reversible     = $true
            Reversal       = 'Reinstall Xbox Game Bar from the Microsoft Store.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'appx-xbox-game-overlay'
            Type           = 'Appx'
            Action         = 'Remove'
            Target         = 'Microsoft.XboxGameOverlay'
            Description    = 'Removes the legacy Xbox Game Overlay provisioned app.'
            Rationale      = 'Companion overlay component for Xbox gaming features; redundant on managed/non-gaming images.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/application-management/provisioned-apps-windows-client-os'
            Reversible     = $true
            Reversal       = 'Reinstall from the Microsoft Store.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'appx-xbox-tcui'
            Type           = 'Appx'
            Action         = 'Remove'
            Target         = 'Microsoft.Xbox.TCUI'
            Description    = 'Removes the Xbox TCUI (title callable UI) provisioned app.'
            Rationale      = 'Shared Xbox UI component used by gaming titles; not required on managed/non-gaming builds. Some Store games may re-request it.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/application-management/provisioned-apps-windows-client-os'
            Reversible     = $true
            Reversal       = 'Reinstall from the Microsoft Store.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'appx-xbox-speech-to-text'
            Type           = 'Appx'
            Action         = 'Remove'
            Target         = 'Microsoft.XboxSpeechToTextOverlay'
            Description    = 'Removes the Xbox speech-to-text overlay provisioned app.'
            Rationale      = 'Accessibility overlay tied to Xbox gaming; unnecessary on managed/non-gaming images.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/application-management/provisioned-apps-windows-client-os'
            Reversible     = $true
            Reversal       = 'Reinstall from the Microsoft Store.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'appx-solitaire-teams-consumer'
            Type           = 'Appx'
            Action         = 'Remove'
            Target         = 'MicrosoftTeams'
            Description    = 'Removes the consumer Microsoft Teams (personal / Chat) provisioned app.'
            Rationale      = 'The consumer Teams app (the taskbar Chat) is distinct from Teams for work/school and is commonly removed on managed builds. Removing the provisioned consumer package does not affect the enterprise Teams client, which is installed separately.'
            Citation       = 'https://learn.microsoft.com/en-us/microsoftteams/teams-classic-client-end-of-availability'
            Reversible     = $true
            Reversal       = 'Reinstall the personal Teams app from the Microsoft Store.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'appx-getstarted-tips'
            Type           = 'Appx'
            Action         = 'Remove'
            Target         = 'Microsoft.Getstarted'
            Description    = 'Removes the Windows Tips (Get Started) provisioned app.'
            Rationale      = 'The Tips app surfaces promotional/onboarding content and is not needed on managed images.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/application-management/provisioned-apps-windows-client-os'
            Reversible     = $true
            Reversal       = 'Reinstall Tips from the Microsoft Store.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'appx-gethelp'
            Type           = 'Appx'
            Action         = 'Remove'
            Target         = 'Microsoft.GetHelp'
            Description    = 'Removes the Get Help provisioned app.'
            Rationale      = 'Consumer support/contact app that is redundant on managed builds with their own support channels.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/application-management/provisioned-apps-windows-client-os'
            Reversible     = $true
            Reversal       = 'Reinstall Get Help from the Microsoft Store.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'appx-feedback-hub'
            Type           = 'Appx'
            Action         = 'Remove'
            Target         = 'Microsoft.WindowsFeedbackHub'
            Description    = 'Removes the Feedback Hub provisioned app.'
            Rationale      = 'Feedback Hub sends diagnostic feedback to Microsoft and is unnecessary on managed/privacy-conscious builds.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/application-management/provisioned-apps-windows-client-os'
            Reversible     = $true
            Reversal       = 'Reinstall Feedback Hub from the Microsoft Store.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'appx-todos'
            Type           = 'Appx'
            Action         = 'Remove'
            Target         = 'Microsoft.Todos'
            Description    = 'Removes the Microsoft To Do provisioned app.'
            Rationale      = 'Consumer task app tied to a Microsoft account; not part of a minimal managed baseline. Reinstallable from the Store.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/application-management/provisioned-apps-windows-client-os'
            Reversible     = $true
            Reversal       = 'Reinstall Microsoft To Do from the Microsoft Store.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'appx-power-automate-desktop'
            Type           = 'Appx'
            Action         = 'Remove'
            Target         = 'Microsoft.PowerAutomateDesktop'
            Description    = 'Removes the Power Automate desktop provisioned app.'
            Rationale      = 'Bundled RPA tool that most clean images do not require; can be deployed intentionally where needed.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/application-management/provisioned-apps-windows-client-os'
            Reversible     = $true
            Reversal       = 'Reinstall Power Automate from the Microsoft Store.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'appx-quickassist'
            Type           = 'Appx'
            Action         = 'Remove'
            Target         = 'MicrosoftCorporationII.QuickAssist'
            Description    = 'Removes the Quick Assist remote-help provisioned app.'
            Rationale      = 'Quick Assist enables inbound remote assistance and is a known social-engineering/support-scam vector; removing it from the default image reduces attack surface. Re-add intentionally where remote assistance is a supported workflow.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/client-management/client-tools/quick-assist'
            Reversible     = $true
            Reversal       = 'Reinstall Quick Assist from the Microsoft Store.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        # --- Historically pre-installed third-party "stub"/promoted titles (King / Candy Crush).
        # These are often delivered via the consumer content-delivery experience rather than as
        # provisioned packages on modern images; the removal is a no-op (recorded NotApplicable)
        # when absent, which is expected and non-fatal (FR-021).
        @{
            Id             = 'appx-king-candycrush'
            Type           = 'Appx'
            Action         = 'Remove'
            Target         = 'king.com.CandyCrush*'
            Description    = 'Removes any King.com Candy Crush titles delivered as provisioned/stub apps.'
            Rationale      = 'Third-party promoted games installed via the Windows consumer content-delivery experience; pure advertising bloat with no productivity value. Removed if present; skipped as NotApplicable if absent.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/configuration/windows-spotlight'
            Reversible     = $true
            Reversal       = 'Reinstall from the Microsoft Store if desired.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        # --- Opt-in, impactful removal (FR-008 / Principle VI: DefaultEnabled = $false) ---
        @{
            Id             = 'remove-edge'
            Type           = 'Appx'
            Action         = 'Remove'
            Target         = 'Microsoft.MicrosoftEdge*'
            Description    = 'Removes the provisioned Microsoft Edge browser packaging (opt-in, impactful).'
            Rationale      = 'Edge is a deeply integrated Windows component and Microsoft treats it as part of the OS; removal can break WebView2-dependent apps and Windows features. Provided strictly as an opt-in choice for users who deploy an alternative browser. The exact offline-removal technique is community-documented rather than an officially supported single procedure, so it is Unverified and MUST stay opt-in.'
            Citation       = 'Unverified'
            Reversible     = $true
            Reversal       = 'Reinstall Microsoft Edge from https://www.microsoft.com/edge or via the Edge stable installer.'
            DefaultEnabled = $false
            Unverified     = $true
            Arch           = @('amd64', 'arm64')
        }
    )
}
