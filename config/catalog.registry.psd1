@{
    # ============================================================================
    # Registry-tweak catalog (Constitution Principle II / FR-007 / FR-018).
    #
    # Each entry documents an offline registry change applied to a mounted image's hives.
    # 'Target' is an object: Hive (SOFTWARE|SYSTEM|DEFAULT — the offline hive loaded from the
    # image), Path (relative to the hive root), Name, Kind, and Value. Machine-wide policies
    # live in SOFTWARE; per-user defaults (applied so every NEW profile inherits them) live in
    # the DEFAULT (ntuser) hive.
    #
    # Recall and Widgets disable are DefaultEnabled = $true per FR-007 (spec-mandated,
    # reversible). Every entry carries What/Why/Citation and a Reversal note.
    # ============================================================================

    Entries = @(

        # --- FR-007 mandated default-ON tweaks -----------------------------------

        @{
            Id             = 'reg-disable-recall'
            Type           = 'Registry'
            Action         = 'Set'
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Policies\Microsoft\Windows\WindowsAI'
                Name  = 'DisableAIDataAnalysis'
                Kind  = 'DWord'
                Value = 1
            }
            Description    = 'Disables Windows Recall by setting the DisableAIDataAnalysis policy (turns off saving Recall snapshots).'
            Rationale      = 'Recall periodically captures screenshots of user activity, which is a significant privacy/data-at-rest concern for managed builds. Microsoft documents DisableAIDataAnalysis as the supported policy to turn off saving snapshots. Spec FR-007 mandates this be disabled by default; it is fully reversible.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/client-management/manage-recall'
            Reversible     = $true
            Reversal       = 'Delete the DisableAIDataAnalysis value (or set it to 0) under SOFTWARE\Policies\Microsoft\Windows\WindowsAI.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-disable-widgets'
            Type           = 'Registry'
            Action         = 'Set'
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Policies\Microsoft\Dsh'
                Name  = 'AllowNewsAndInterests'
                Kind  = 'DWord'
                Value = 0
            }
            Description    = 'Disables the Widgets board (weather/stock/news feed) via the AllowNewsAndInterests policy.'
            Rationale      = 'The Widgets feed (weather, stocks, news) fetches internet content and adds taskbar surface area not wanted on managed builds. Microsoft documents AllowNewsAndInterests under Policies\Microsoft\Dsh as the control. Spec FR-007 mandates disabling weather/stock Widgets by default; reversible.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/client-management/manage-windows-widgets'
            Reversible     = $true
            Reversal       = 'Set AllowNewsAndInterests to 1 (or delete it) under SOFTWARE\Policies\Microsoft\Dsh.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        # --- Cited privacy / telemetry safe tweaks (default ON) ------------------

        @{
            Id             = 'reg-disable-consumer-features'
            Type           = 'Registry'
            Action         = 'Set'
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Policies\Microsoft\Windows\CloudContent'
                Name  = 'DisableWindowsConsumerFeatures'
                Kind  = 'DWord'
                Value = 1
            }
            Description    = 'Disables Windows consumer features (auto-installed suggested/promoted apps such as third-party games).'
            Rationale      = 'The consumer content-delivery experience silently installs promoted third-party apps (e.g. Candy Crush) and suggestions. Disabling it prevents re-appearance of bloat after debloating and is the supported enterprise control.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/configuration/windows-spotlight'
            Reversible     = $true
            Reversal       = 'Set DisableWindowsConsumerFeatures to 0 (or delete it) under SOFTWARE\Policies\Microsoft\Windows\CloudContent.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-disable-advertising-id'
            Type           = 'Registry'
            Action         = 'Set'
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Policies\Microsoft\Windows\AdvertisingInfo'
                Name  = 'DisabledByGroupPolicy'
                Kind  = 'DWord'
                Value = 1
            }
            Description    = 'Turns off the per-user advertising ID used to personalize ads across apps.'
            Rationale      = 'The advertising ID enables cross-app ad tracking. Microsoft documents DisabledByGroupPolicy under AdvertisingInfo as the control (Policy CSP Privacy/DisableAdvertisingId). A privacy-improving, reversible default.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy'
            Reversible     = $true
            Reversal       = 'Set DisabledByGroupPolicy to 0 (or delete it) under SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-telemetry-basic'
            Type           = 'Registry'
            Action         = 'Set'
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Policies\Microsoft\Windows\DataCollection'
                Name  = 'AllowTelemetry'
                Kind  = 'DWord'
                Value = 0
            }
            Description    = 'Sets the diagnostic-data (telemetry) policy to the lowest level (Security/Required).'
            Rationale      = 'Reduces diagnostic data sent to Microsoft. Note: on Pro the effective floor is "Required/Basic" (the 0/Security level is fully honored only on Enterprise/Education), which Microsoft documents; the policy is still the correct, supported control and is reversible.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/privacy/configure-windows-diagnostic-data-in-your-organization'
            Reversible     = $true
            Reversal       = 'Set AllowTelemetry to the desired level (1=Required, 3=Optional) or delete it under SOFTWARE\Policies\Microsoft\Windows\DataCollection.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-disable-cortana'
            Type           = 'Registry'
            Action         = 'Set'
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Policies\Microsoft\Windows\Windows Search'
                Name  = 'AllowCortana'
                Kind  = 'DWord'
                Value = 0
            }
            Description    = 'Disables Cortana via the AllowCortana policy.'
            Rationale      = 'Cortana is largely deprecated and unnecessary on managed builds; disabling it reduces background voice/assistant surface. Microsoft documents AllowCortana in Policy CSP Search. Reversible.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-search'
            Reversible     = $true
            Reversal       = 'Set AllowCortana to 1 (or delete it) under SOFTWARE\Policies\Microsoft\Windows\Windows Search.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-disable-tailored-experiences'
            Type           = 'Registry'
            Action         = 'Set'
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Policies\Microsoft\Windows\CloudContent'
                Name  = 'DisableTailoredExperiencesWithDiagnosticData'
                Kind  = 'DWord'
                Value = 1
            }
            Description    = 'Prevents Windows from using diagnostic data to show tailored experiences (personalized tips/ads/suggestions).'
            Rationale      = 'Stops Microsoft from using diagnostic data to personalize tips, ads, and recommendations in the shell. Microsoft documents the corresponding Experience/AllowTailoredExperiencesWithDiagnosticData policy. Privacy-improving and reversible.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience'
            Reversible     = $true
            Reversal       = 'Set DisableTailoredExperiencesWithDiagnosticData to 0 (or delete it) under SOFTWARE\Policies\Microsoft\Windows\CloudContent.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        # --- Opt-in / not independently citable (Unverified => DefaultEnabled=false) ---

        @{
            Id             = 'reg-disable-start-web-search'
            Type           = 'Registry'
            Action         = 'Set'
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Policies\Microsoft\Windows\Windows Search'
                Name  = 'DisableSearchBoxSuggestions'
                Kind  = 'DWord'
                Value = 1
            }
            Description    = 'Disables web/Bing suggestions in the Start menu and taskbar search box.'
            Rationale      = 'Removes internet-backed search suggestions from Start/search for a more local, private search experience. This exact value is community-documented rather than in a single authoritative Microsoft page, so it is Unverified and opt-in only.'
            Citation       = 'Unverified'
            Reversible     = $true
            Reversal       = 'Set DisableSearchBoxSuggestions to 0 (or delete it) under SOFTWARE\Policies\Microsoft\Windows\Windows Search.'
            DefaultEnabled = $false
            Unverified     = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-disable-lockscreen-spotlight'
            Type           = 'Registry'
            Action         = 'Set'
            Target         = @{
                Hive  = 'DEFAULT'
                Path  = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
                Name  = 'RotatingLockScreenOverlayEnabled'
                Kind  = 'DWord'
                Value = 0
            }
            Description    = 'Disables Windows Spotlight lock-screen "fun facts/ads" overlays for new user profiles.'
            Rationale      = 'Spotlight lock-screen overlays surface suggestions/ads. Applied to the DEFAULT hive so new profiles inherit it. The specific per-user ContentDeliveryManager value is community-documented (no single authoritative Microsoft page), so it is Unverified and opt-in only.'
            Citation       = 'Unverified'
            Reversible     = $true
            Reversal       = 'Set RotatingLockScreenOverlayEnabled to 1 (or delete it) under DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager.'
            DefaultEnabled = $false
            Unverified     = $true
            Arch           = @('amd64', 'arm64')
        },

        # --- Opt-in, impactful removal (FR-008 / Principle VI: DefaultEnabled = $false) ---
        @{
            Id             = 'remove-onedrive'
            Type           = 'Registry'
            Action         = 'Delete'
            Target         = @{
                Hive = 'DEFAULT'
                Path = 'Software\Microsoft\Windows\CurrentVersion\Run'
                Name = 'OneDriveSetup'
            }
            Description    = 'Removes the per-user OneDrive setup auto-run entry so new profiles do not auto-install the OneDrive sync client (opt-in).'
            Rationale      = 'Prevents the OneDrive first-run installer from launching for new users, which is the reversible, low-risk part of "removing OneDrive" from an image. Provided opt-in per FR-008; full removal of the OneDrive binary is a separate, more invasive step intentionally not performed here.'
            Citation       = 'https://support.microsoft.com/en-us/office/turn-off-disable-or-uninstall-onedrive-f32a17ce-3336-40fe-9c38-6efb09f944b0'
            Reversible     = $true
            Reversal       = 'Re-create the OneDriveSetup Run value (data: %SystemRoot%\System32\OneDriveSetup.exe /thfirstsetup) or run OneDriveSetup.exe manually.'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        }
    )
}
