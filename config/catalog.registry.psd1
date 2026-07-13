@{
    # ============================================================================
    # Registry-tweak catalog (Constitution Principle II v1.1.0 / FR-007 / FR-018 / FR-026).
    #
    # SCHEMA v2: every entry uses Action = 'SetRegistry' and declares an `EvidenceGrade`
    # (1 = official Microsoft docs, 2 = reputable third-party, 3 = community/forum). A grade-3
    # entry MUST be DefaultEnabled = $false (enforced by tests/Catalog.Schema.Tests.ps1).
    #
    # 'Target' is an object: Hive (SOFTWARE|SYSTEM|DEFAULT — the offline hive loaded from the
    # image), Path (relative to the hive root), Name, Kind, Value, and an optional
    # Operation ('Set' default, or 'Delete' to remove the value). Machine-wide policies live
    # in SOFTWARE; per-user defaults (so every NEW profile inherits them) live in the DEFAULT
    # (ntuser) hive.
    #
    # Recall and Widgets disable are DefaultEnabled = $true per FR-007 (spec-mandated,
    # reversible, grade 1). Every entry carries What/Why/Citation/EvidenceGrade and a Reversal.
    # ============================================================================

    Entries = @(

        # --- FR-007 mandated default-ON tweaks -----------------------------------

        @{
            Id             = 'reg-disable-recall'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Privacy & telemetry'
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
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Delete the DisableAIDataAnalysis value (or set it to 0) under SOFTWARE\Policies\Microsoft\Windows\WindowsAI.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-disable-widgets'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Personalization'
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
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Set AllowNewsAndInterests to 1 (or delete it) under SOFTWARE\Policies\Microsoft\Dsh.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        # --- Cited privacy / telemetry safe tweaks (default ON, grade 1) ---------

        @{
            Id             = 'reg-disable-consumer-features'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Bundled apps'
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
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Set DisableWindowsConsumerFeatures to 0 (or delete it) under SOFTWARE\Policies\Microsoft\Windows\CloudContent.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-disable-advertising-id'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Privacy & telemetry'
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
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Set DisabledByGroupPolicy to 0 (or delete it) under SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-telemetry-basic'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Privacy & telemetry'
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
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Set AllowTelemetry to the desired level (1=Required, 3=Optional) or delete it under SOFTWARE\Policies\Microsoft\Windows\DataCollection.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-disable-cortana'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Privacy & telemetry'
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
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Set AllowCortana to 1 (or delete it) under SOFTWARE\Policies\Microsoft\Windows\Windows Search.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-disable-tailored-experiences'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Privacy & telemetry'
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
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Set DisableTailoredExperiencesWithDiagnosticData to 0 (or delete it) under SOFTWARE\Policies\Microsoft\Windows\CloudContent.'
            DefaultEnabled = $true
            Arch           = @('amd64', 'arm64')
        },

        # --- Community-documented tweaks (EvidenceGrade 3 => DefaultEnabled=false) ---------

        @{
            Id             = 'reg-disable-start-web-search'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Personalization'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Policies\Microsoft\Windows\Windows Search'
                Name  = 'DisableSearchBoxSuggestions'
                Kind  = 'DWord'
                Value = 1
            }
            Description    = 'Disables web/Bing suggestions in the Start menu and taskbar search box.'
            Rationale      = 'Removes internet-backed search suggestions from Start/search for a more local, private search experience. This exact value is community-documented rather than in a single authoritative Microsoft page (EvidenceGrade 3), so it is opt-in only.'
            Citation       = 'https://learn.microsoft.com/en-us/answers/questions/1737991/how-to-disable-web-search-in-windows-11-search'
            EvidenceGrade  = 3
            Reversible     = $true
            Reversal       = 'Set DisableSearchBoxSuggestions to 0 (or delete it) under SOFTWARE\Policies\Microsoft\Windows\Windows Search.'
            DefaultEnabled = $false
            Unverified     = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-disable-lockscreen-spotlight'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Personalization'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'DEFAULT'
                Path  = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
                Name  = 'RotatingLockScreenOverlayEnabled'
                Kind  = 'DWord'
                Value = 0
            }
            Description    = 'Disables Windows Spotlight lock-screen "fun facts/ads" overlays for new user profiles.'
            Rationale      = 'Spotlight lock-screen overlays surface suggestions/ads. Applied to the DEFAULT hive so new profiles inherit it. The specific per-user ContentDeliveryManager value is community-documented (EvidenceGrade 3), so it is opt-in only.'
            Citation       = 'https://learn.microsoft.com/en-us/answers/questions/1326668/how-to-disable-windows-spotlight-via-registry'
            EvidenceGrade  = 3
            Reversible     = $true
            Reversal       = 'Set RotatingLockScreenOverlayEnabled to 1 (or delete it) under DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager.'
            DefaultEnabled = $false
            Unverified     = $true
            Arch           = @('amd64', 'arm64')
        },

        # --- Opt-in, impactful removal (FR-008 / Principle VI: DefaultEnabled = $false) ---
        # OneDrive "removal" here uses the Microsoft-documented supported policy to prevent the
        # OneDrive sync client rather than deleting binaries (grade 1, reversible, opt-in).
        @{
            Id             = 'remove-onedrive'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Cloud storage'
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Policies\Microsoft\Windows\OneDrive'
                Name  = 'DisableFileSyncNGSC'
                Kind  = 'DWord'
                Value = 1
            }
            Description    = 'Prevents the OneDrive sync client from being used, via the supported DisableFileSyncNGSC policy (opt-in).'
            Rationale      = 'Microsoft documents the "Prevent the usage of OneDrive for file storage" policy (DisableFileSyncNGSC = 1) as the supported way to disable OneDrive. This is the reversible, low-risk part of "removing OneDrive" from an image; it does not delete the OneDrive binary. Provided opt-in per FR-008.'
            Citation       = 'https://learn.microsoft.com/en-us/sharepoint/use-group-policy'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Set DisableFileSyncNGSC to 0 (or delete it) under SOFTWARE\Policies\Microsoft\Windows\OneDrive.'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        # --- Personalization: macOS-style "natural" (reversed) mouse scrolling -----------
        # FlipFlopWheel lives per-device under SYSTEM\...\Enum\HID\<device>\Device Parameters,
        # which do not exist in a generalized offline image (PnP populates them at first boot).
        # So we bake a machine RunOnce command that, on first boot, sets FlipFlopWheel=1 on every
        # enumerated HID mouse device. FlipFlopWheel is documented by Microsoft (wheel.docx),
        # so EvidenceGrade 1; kept opt-in (DefaultEnabled=$false) as a personal-taste preference.
        @{
            Id             = 'reg-reverse-mouse-scroll'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Personalization'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Microsoft\Windows\CurrentVersion\RunOnce'
                Name  = '!WimReverseMouseScroll'
                Kind  = 'String'
                Value = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Get-ChildItem -Path ''HKLM:\SYSTEM\CurrentControlSet\Enum\HID'' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq ''Device Parameters'' } | ForEach-Object { New-ItemProperty -Path $_.PSPath -Name ''FlipFlopWheel'' -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue }"'
            }
            Description    = 'Reverses the mouse wheel scroll direction (macOS-style "natural" scrolling) by setting FlipFlopWheel=1 on every HID mouse via a first-boot RunOnce command.'
            Rationale      = 'FlipFlopWheel is the Microsoft-documented per-device control that inverts wheel scroll direction (see Microsoft''s "How to reverse the mouse wheel scrolling direction" whitepaper, wheel.docx). It lives under each mouse''s SYSTEM\...\Enum\HID\<device>\Device Parameters key, which is only populated by PnP at first boot and therefore cannot be written into a generalized offline image. Baking a machine RunOnce (also a Microsoft-documented mechanism: https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys) that sets FlipFlopWheel=1 on all enumerated HID mice at first logon is the reliable, reversible way to apply it. Kept opt-in (DefaultEnabled=$false) because reversed scrolling is a personal-taste preference, not a general improvement.'
            Citation       = 'https://download.microsoft.com/download/b/d/1/bd1f7ef4-7d72-419e-bc5c-9f79ad7bb66e/wheel.docx'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Remove the !WimReverseMouseScroll value under SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce before first boot, or after boot set FlipFlopWheel to 0 (or delete it) under each mouse''s SYSTEM\CurrentControlSet\Enum\HID\<device>\Device Parameters key.'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        }
    )
}
