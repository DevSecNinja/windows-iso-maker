@{
    # ============================================================================
    # Registry-tweak catalog (Constitution Principle II v1.1.0 / FR-007 / FR-018 / FR-026).
    #
    # SCHEMA v2: every entry uses Action = 'SetRegistry' and declares an `EvidenceGrade`
    # (1 = official Microsoft docs, 2 = reputable third-party, 3 = community/forum). A grade-3
    # entry MUST be DefaultEnabled = $false (enforced by tests/Catalog.Schema.Tests.ps1).
    #
    # 'Target' is an object: Hive (SOFTWARE|SYSTEM|DEFAULT — the offline hive loaded from the
    # image), Path (relative to the hive root), Name, Kind, Value, an optional
    # Operation ('Set' default, or 'Delete' to remove the value), and an optional
    # OnlyIfKeyExists ($true = only change the value when the key already exists; the entry is
    # reported NotApplicable instead of creating the key — use it for third-party/OEM components
    # that a clean image does not contain). Machine-wide policies live in SOFTWARE; per-user
    # defaults (so every NEW profile inherits them) live in the DEFAULT (ntuser) hive.
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
            Rationale      = 'The Widgets feed (weather, stocks, news) fetches internet content and adds taskbar surface area not wanted on managed builds. The NewsAndInterests Policy CSP documents AllowNewsAndInterests with the exact registry mapping (SOFTWARE\Policies\Microsoft\Dsh, 0 = not allowed) used here. Spec FR-007 mandates disabling weather/stock Widgets by default; reversible.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-newsandinterests'
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
            Rationale      = 'The consumer content-delivery experience silently installs promoted third-party apps (e.g. Candy Crush) and suggestions. Disabling it prevents re-appearance of bloat after debloating and is the supported enterprise control. Microsoft documents the corresponding Experience/AllowWindowsConsumerFeatures policy (registry mapping SOFTWARE\Policies\Microsoft\Windows\CloudContent, DisableWindowsConsumerFeatures = 1).'
            Citation       = 'https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience'
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

        @{
            Id             = 'reg-disable-device-metadata-apps'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Bundled apps'
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Policies\Microsoft\Windows\Device Metadata'
                Name  = 'PreventDeviceMetadataFromNetwork'
                Kind  = 'DWord'
                Value = 1
            }
            Description    = 'Stops Windows from downloading device metadata and the vendor apps associated with it, which suppresses the "get the companion app for your device" toasts shown when a mouse, keyboard, headset or printer is connected.'
            Rationale      = 'When a peripheral is attached, the Device Setup Manager fetches device metadata from Microsoft''s device-metadata service and uses it to advertise and auto-download the vendor''s companion app (for example the "Power up your precision mouse with Microsoft Mouse and Keyboard Center" toast for Surface/Microsoft mice, or vendor-app prompts for other peripherals). Microsoft documents the supported control as the DeviceInstallation/PreventDeviceMetadataFromNetwork policy ("Prevent automatic download of applications associated with device metadata", Computer Configuration > System > Device Installation), which maps to SOFTWARE\Policies\Microsoft\Windows\Device Metadata!PreventDeviceMetadataFromNetwork = 1 and overrides the per-machine Device Installation Settings dialog. Drivers still install normally through Windows Update; only the metadata-driven app download/advertising stops. Side effect: some devices show a generic icon/name in Devices and Printers instead of the vendor-supplied one. Fully reversible.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-deviceinstallation#preventdevicemetadatafromnetwork'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Set PreventDeviceMetadataFromNetwork to 0 (or delete it) under SOFTWARE\Policies\Microsoft\Windows\Device Metadata, then re-enable "Automatically download manufacturers'' apps..." in Device Installation Settings (Control Panel > System > Advanced system settings > Hardware).'
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

        # --- Personalization: Europe/Amsterdam time zone ---------------------------------
        # The time zone is a system-wide setting driven by tzutil (which recomputes the
        # TimeZoneInformation biases/DST rules) rather than a single registry value, so it is
        # applied via a first-boot RunOnce command. Standard users hold SeTimeZonePrivilege by
        # default, so the command works in the (possibly non-elevated) first-logon context.
        @{
            Id             = 'reg-timezone-amsterdam'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Personalization'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Microsoft\Windows\CurrentVersion\RunOnce'
                Name  = '!WimTimeZoneAmsterdam'
                Kind  = 'String'
                Value = 'tzutil.exe /s "W. Europe Standard Time"'
            }
            Description    = 'Sets the system time zone to (UTC+01:00) Amsterdam ("W. Europe Standard Time", DST-aware) via a first-boot RunOnce tzutil command.'
            Rationale      = 'The time zone is a machine-wide setting whose registry representation (TimeZoneInformation: Bias/StandardBias/DaylightBias/TimeZoneKeyName/DynamicDaylightTimeDisabled) must be kept consistent; Microsoft''s supported tool for changing it is tzutil.exe, which recomputes all of those values and the DST rules from the time-zone id. Because tzutil is a command (not a single value) and the offline image cannot run it, it is baked as a machine RunOnce (a Microsoft-documented mechanism) that runs at first logon. Standard users are granted SeTimeZonePrivilege by default, so it succeeds even when the first-logon context is not elevated. Kept opt-in (Profiles=opinionated) because a fixed time zone is a personal/deployment-specific preference.'
            Citation       = 'https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/tzutil'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Remove the !WimTimeZoneAmsterdam value under SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce before first boot, or after boot run tzutil /s with your preferred time-zone id (e.g. tzutil /s "UTC").'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        # --- Personalization: Netherlands regional (date/time/number) format -------------
        # The per-user "region format" (UserLocale) governs the taskbar clock/date format. It is
        # applied with the Microsoft International-module cmdlets via a first-boot RunOnce so the
        # logged-on user gets nl-NL formatting (24-hour HH:mm, dd-MM-yyyy) and the Netherlands home
        # location, without changing the English (en-US) UI/display language.
        @{
            Id             = 'reg-region-format-nl'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Personalization'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Microsoft\Windows\CurrentVersion\RunOnce'
                Name  = '!WimRegionFormatNL'
                Kind  = 'String'
                Value = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Set-Culture -CultureInfo nl-NL; Set-WinHomeLocation -GeoId 176"'
            }
            Description    = 'Sets the regional format to Dutch (Netherlands) — 24-hour HH:mm time and dd-MM-yyyy short date (e.g. 20:03 16-07-2026) — and the home location to the Netherlands, without changing the English UI language.'
            Rationale      = 'The taskbar clock/date format is driven by the per-user "region format" (UserLocale) under HKCU\Control Panel\International, not the display language. Microsoft''s supported cmdlets to set it are Set-Culture (region format) and Set-WinHomeLocation (Region > Country/region, GeoId 176 = Netherlands). nl-NL yields the 24-hour HH:mm time and dd-MM-yyyy short date the user wants. These are per-user, cannot be run against an offline image, and are applied via a first-boot RunOnce that runs in the logged-on user''s context. The English (en-US) UI/system locale is intentionally left unchanged. Kept opt-in (Profiles=opinionated) as a personal/regional preference.'
            Citation       = 'https://learn.microsoft.com/en-us/powershell/module/international/set-culture'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Remove the !WimRegionFormatNL value under SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce before first boot, or after boot run Set-Culture -CultureInfo en-US (and Set-WinHomeLocation -GeoId 244 for the United States) to revert.'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        # --- Personalization: NL + EN input languages, both on the US-International layout ---
        # Replaces the per-user input-language list so only Dutch (nl-NL) and English (en-US)
        # remain, each bound to the United States-International keyboard layout (KLID 00020409),
        # removing the stray plain-US (0409:00000409) layout Windows often adds. English is kept
        # first so the display language stays English.
        @{
            Id             = 'reg-keyboard-nl-en-intl'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Personalization'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Microsoft\Windows\CurrentVersion\RunOnce'
                Name  = '!WimKeyboardNlEnIntl'
                Kind  = 'String'
                Value = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$l = New-WinUserLanguageList -Language ''en-US''; $l[0].InputMethodTips.Clear(); $l[0].InputMethodTips.Add(''0409:00020409''); $l.Add(''nl-NL''); $l[1].InputMethodTips.Clear(); $l[1].InputMethodTips.Add(''0413:00020409''); Set-WinUserLanguageList -LanguageList $l -Force"'
            }
            Description    = 'Sets exactly two input languages — English (en-US) and Dutch (nl-NL) — both bound to the United States-International keyboard layout (00020409), removing the stray plain-US (00000409) layout Windows often adds.'
            Rationale      = 'The input-language list is a per-user setting managed through Microsoft''s Set-WinUserLanguageList cmdlet; hand-editing its serialized HKCU\Control Panel\International\User Profile blob is unreliable. Building the list with New-WinUserLanguageList and pinning each language''s InputMethodTips to the US-International layout (LANGID:KLID = 0409:00020409 for English, 0413:00020409 for Dutch) guarantees both languages type on US-International and drops the default plain-US (0409:00000409) layout that is commonly added but unwanted. English is kept as the first entry so the display language remains English. Applied via a first-boot RunOnce in the user''s context (cannot run against an offline image). Kept opt-in (Profiles=opinionated) as a personal keyboard preference.'
            Citation       = 'https://learn.microsoft.com/en-us/powershell/module/international/set-winuserlanguagelist'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Remove the !WimKeyboardNlEnIntl value under SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce before first boot, or after boot reset the list via Settings > Time & language > Language & region (or Set-WinUserLanguageList en-US -Force).'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        # --- Personalization: dark mode (per-user, current + future via DEFAULT hive) -----
        # AppsUseLightTheme/SystemUsesLightTheme are per-user values under the Personalize key.
        # Applied to the DEFAULT hive so NEW profiles inherit dark mode; the online post-install
        # path applies them to the current user (HKCU) as well (Scope=Both). Community-documented
        # (no single authoritative policy page), so grade 3 / opt-in.
        @{
            Id             = 'reg-dark-mode-apps'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Personalization'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'DEFAULT'
                Path  = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
                Name  = 'AppsUseLightTheme'
                Kind  = 'DWord'
                Value = 0
            }
            Description    = 'Enables dark mode for apps (AppsUseLightTheme = 0) for new profiles and, via post-install, the current user.'
            Rationale      = 'Windows stores the app/system theme per user under HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize; AppsUseLightTheme = 0 selects the dark app theme (Microsoft documents these values in its theme-support guidance). Written to the DEFAULT hive so new profiles start in dark mode, and applied to the current user by the post-install path (Scope=Both). Community-documented for scripting (no single authoritative policy page), so EvidenceGrade 3 / opt-in.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/apply-windows-themes'
            EvidenceGrade  = 3
            Reversible     = $true
            Reversal       = 'Set AppsUseLightTheme to 1 (or delete it) under Software\Microsoft\Windows\CurrentVersion\Themes\Personalize in HKCU and the default-user hive.'
            DefaultEnabled = $false
            Unverified     = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-dark-mode-system'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Personalization'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'DEFAULT'
                Path  = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
                Name  = 'SystemUsesLightTheme'
                Kind  = 'DWord'
                Value = 0
            }
            Description    = 'Enables dark mode for the Windows shell/taskbar (SystemUsesLightTheme = 0) for new profiles and, via post-install, the current user.'
            Rationale      = 'SystemUsesLightTheme = 0 selects the dark theme for the taskbar, Start and system surfaces (the companion to AppsUseLightTheme). Written to the DEFAULT hive for new profiles and applied to the current user by post-install (Scope=Both). Community-documented for scripting, so EvidenceGrade 3 / opt-in.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/apply-windows-themes'
            EvidenceGrade  = 3
            Reversible     = $true
            Reversal       = 'Set SystemUsesLightTheme to 1 (or delete it) under Software\Microsoft\Windows\CurrentVersion\Themes\Personalize in HKCU and the default-user hive.'
            DefaultEnabled = $false
            Unverified     = $true
            Arch           = @('amd64', 'arm64')
        },

        # --- Personalization: show file extensions (per-user, current + future) -----------
        @{
            Id             = 'reg-show-file-extensions'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Personalization'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'DEFAULT'
                Path  = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
                Name  = 'HideFileExt'
                Kind  = 'DWord'
                Value = 0
            }
            Description    = 'Shows known file-type extensions in File Explorer (HideFileExt = 0) for new profiles and, via post-install, the current user.'
            Rationale      = 'HideFileExt lives per-user under Explorer\Advanced; setting it to 0 makes File Explorer show extensions, which is a small security/clarity win (helps spot e.g. invoice.pdf.exe). Written to the DEFAULT hive for new profiles and applied to the current user by post-install (Scope=Both). The exact value is community-documented rather than in a single authoritative policy page, so it is opt-in.'
            Citation       = 'Unverified'
            EvidenceGrade  = 3
            Reversible     = $true
            Reversal       = 'Set HideFileExt to 1 (or delete it) under Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced in HKCU and the default-user hive.'
            DefaultEnabled = $false
            Unverified     = $true
            Arch           = @('amd64', 'arm64')
        },

        # --- Personalization: US number format so Excel uses comma CSV delimiter ----------
        # Windows couples the Excel CSV column separator to the List separator (sList), and it
        # forbids sList from equalling the decimal symbol. NL uses a decimal comma, so to get
        # comma-delimited CSVs the decimal must become '.' and the thousands ',' — i.e. adopt US
        # number formatting for these three NLS values only (the display language/locale is left
        # unchanged). Per-user (DEFAULT hive + current user via Scope=Both).
        @{
            Id             = 'reg-number-format-decimal-us'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Personalization'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'DEFAULT'
                Path  = 'Control Panel\International'
                Name  = 'sDecimal'
                Kind  = 'String'
                Value = '.'
            }
            Description    = 'Sets the decimal symbol to a dot (sDecimal = ".") so a comma can be used as the CSV list separator (US number formatting).'
            Rationale      = 'sDecimal is the per-user NLS decimal-symbol override (LOCALE_SDECIMAL) under HKCU\Control Panel\International. Windows refuses to make the List separator equal the decimal symbol, so a comma CSV delimiter requires the decimal symbol to be a dot. Set to "." here (with sThousand="," and sList=",") to give Excel comma-delimited CSVs without changing the display language. Applied to new profiles (DEFAULT hive) and the current user (Scope=Both).'
            Citation       = 'https://learn.microsoft.com/en-us/windows/win32/intl/locale-custom-constants'
            EvidenceGrade  = 2
            Reversible     = $true
            Reversal       = 'Set sDecimal back to "," (the NL default) under Control Panel\International in HKCU and the default-user hive.'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-number-format-thousands-us'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Personalization'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'DEFAULT'
                Path  = 'Control Panel\International'
                Name  = 'sThousand'
                Kind  = 'String'
                Value = ','
            }
            Description    = 'Sets the digit-grouping (thousands) symbol to a comma (sThousand = ",") to complete US number formatting.'
            Rationale      = 'sThousand is the per-user NLS thousands-separator override (LOCALE_STHOUSAND). With the decimal symbol changed to ".", the thousands separator must move off "." (it may not equal the decimal); "," is the US convention. Applied to new profiles (DEFAULT hive) and the current user (Scope=Both).'
            Citation       = 'https://learn.microsoft.com/en-us/windows/win32/intl/locale-custom-constants'
            EvidenceGrade  = 2
            Reversible     = $true
            Reversal       = 'Set sThousand back to "." (the NL default) under Control Panel\International in HKCU and the default-user hive.'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-number-format-list-us'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Personalization'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'DEFAULT'
                Path  = 'Control Panel\International'
                Name  = 'sList'
                Kind  = 'String'
                Value = ','
            }
            Description    = 'Sets the list separator to a comma (sList = ",") so Excel imports/exports CSV files with comma-delimited columns.'
            Rationale      = 'sList is the per-user NLS list-separator override (LOCALE_SLIST); Excel uses it as the CSV column delimiter. Setting it to "," makes downloaded comma-separated CSVs open correctly (instead of the NL default ";"). Requires sDecimal="." (see reg-number-format-decimal-us) because Windows forbids sList == sDecimal. Applied to new profiles (DEFAULT hive) and the current user (Scope=Both).'
            Citation       = 'https://learn.microsoft.com/en-us/windows/win32/intl/locale-custom-constants'
            EvidenceGrade  = 2
            Reversible     = $true
            Reversal       = 'Set sList back to ";" (the NL default) under Control Panel\International in HKCU and the default-user hive.'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        # --- Privacy: clipboard history, local only (enable history, block cloud sync) ----
        @{
            Id             = 'reg-clipboard-history-enable'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Privacy & telemetry'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Policies\Microsoft\Windows\System'
                Name  = 'AllowClipboardHistory'
                Kind  = 'DWord'
                Value = 1
            }
            Description    = 'Enables clipboard history (Win+V) via the AllowClipboardHistory policy.'
            Rationale      = 'Clipboard history keeps the last clipboard items available via Win+V, a productivity feature. Microsoft documents AllowClipboardHistory under Policy CSP - System. Paired with reg-clipboard-no-cross-device it stays LOCAL only (no cloud roaming), which is the security-conscious configuration. Opt-in because storing clipboard history is a personal choice.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-system'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Set AllowClipboardHistory to 0 (or delete it) under SOFTWARE\Policies\Microsoft\Windows\System.'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-clipboard-no-cross-device'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Privacy & telemetry'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Policies\Microsoft\Windows\System'
                Name  = 'AllowCrossDeviceClipboard'
                Kind  = 'DWord'
                Value = 0
            }
            Description    = 'Disables cross-device (cloud) clipboard sync via the AllowCrossDeviceClipboard policy, keeping clipboard history local only.'
            Rationale      = 'Cross-device clipboard roams clipboard contents to the Microsoft cloud/other devices, which is a privacy/security concern (copied secrets leave the machine). Microsoft documents AllowCrossDeviceClipboard under Policy CSP - System; setting it to 0 keeps clipboard history strictly local. Pairs with reg-clipboard-history-enable for "local history, no cloud". Opt-in.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-system'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Set AllowCrossDeviceClipboard to 1 (or delete it) under SOFTWARE\Policies\Microsoft\Windows\System.'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        # --- System & recovery: hibernation + Start-menu Hibernate button -----------------
        @{
            Id             = 'reg-show-hibernate-button'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'System & recovery'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings'
                Name  = 'ShowHibernateOption'
                Kind  = 'DWord'
                Value = 1
            }
            Description    = 'Adds Hibernate to the Start menu / Ctrl+Alt+Del power (Shut down or sign out) menu via ShowHibernateOption = 1.'
            Rationale      = 'The Hibernate entry in the power flyout is controlled by ShowHibernateOption under Explorer\FlyoutMenuSettings, which is the setting behind the "Show hibernate in the power options menu" administrative-template policy (Policy CSP - ADMX_WindowsExplorer). Enabling it surfaces the Hibernate button the user otherwise sets manually via Power Options. Requires hibernation to be enabled (reg-enable-hibernation). Opt-in.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-windowsexplorer'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Set ShowHibernateOption to 0 (or delete it) under SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings.'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        # NOTE (SYSTEM hive): offline the loaded SYSTEM hive exposes ControlSet001 (there is no
        # CurrentControlSet symlink until boot); online HKLM\SYSTEM\ControlSet001 also exists and
        # is normally the active control set, so ControlSet001 is used as the single path that
        # works for both the offline build and the online post-install.
        @{
            Id             = 'reg-enable-hibernation'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'System & recovery'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'SYSTEM'
                Path  = 'ControlSet001\Control\Power'
                Name  = 'HibernateEnabled'
                Kind  = 'DWord'
                Value = 1
            }
            Description    = 'Enables hibernation (HibernateEnabled = 1), the machine-wide flag toggled by "powercfg /hibernate on".'
            Rationale      = 'Hibernation is controlled machine-wide by HibernateEnabled under SYSTEM\...\Control\Power; this is the value "powercfg /hibernate on" sets. Enabling it lets Windows create hiberfil.sys and offer Hibernate (surfaced in the menu by reg-show-hibernate-button). Reversible via powercfg /hibernate off. EvidenceGrade 2 (powercfg is the canonical documented tool; the registry value is its backing store).'
            Citation       = 'https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options'
            EvidenceGrade  = 2
            Reversible     = $true
            Reversal       = 'Run "powercfg /hibernate off", or set HibernateEnabled to 0 under SYSTEM\ControlSet001\Control\Power.'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        # --- System & recovery: power-button action (Surface Laptop mis-press guard) -------
        # Power.admx stores every power-setting policy under
        # Software\Policies\Microsoft\Power\PowerSettings\<setting-GUID> with the plugged-in value
        # in ACSettingIndex and the on-battery value in DCSettingIndex, so the two entries below are
        # a pair: enable both to make the behaviour identical on and off mains power.
        #
        # Both carry a Condition, so they are applied ONLY on Surface Laptop hardware. The offline
        # build reports them NotApplicable (the build agent is not the target machine) and
        # post-install.ps1 evaluates the condition on the installed machine. Microsoft publishes the
        # System Model / System SKU values that SMBIOS reports for every Surface device, and every
        # Surface Laptop SKU begins with 'Surface_Laptop' (Surface_Laptop, Surface_Laptop_3_1867:1868,
        # Surface_Laptop_6_for_Business_2033, Surface_Laptop_7th_Edition_2036, ...); the Model check is
        # a fallback for devices whose SystemSKUNumber is not populated.
        @{
            Id             = 'reg-power-button-no-action-ac'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'System & recovery'
            Profiles       = @('opinionated')
            Condition      = @{
                Description = 'Microsoft Surface Laptop devices only (SMBIOS System SKU starts with Surface_Laptop).'
                Citation    = 'https://learn.microsoft.com/en-us/surface/surface-system-sku-reference'
                Script      = @'
$cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
($cs.SystemSKUNumber -like 'Surface_Laptop*') -or ($cs.Model -like '*Surface Laptop*')
'@
            }
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Policies\Microsoft\Power\PowerSettings\7648EFA3-DD9C-4E3E-B566-50F929386280'
                Name  = 'ACSettingIndex'
                Kind  = 'DWord'
                Value = 0
            }
            Description    = 'On Surface Laptops only: makes pressing the power button do nothing while plugged in (power-button action = Take no action) instead of putting the machine to sleep.'
            Rationale      = 'On Surface Laptops the power button sits on the outer edge of the top row, immediately next to Delete/Backspace, which is the reverse of most other laptops (for example Dell, where Delete is outboard of the power key). Muscle memory therefore sleeps the machine on a mis-press. Microsoft documents SelectPowerButtonActionPluggedIn ("Select the Power button action (plugged in)", Computer Configuration > System > Power Management > Button Settings) with the registry key Software\Policies\Microsoft\Power\PowerSettings\7648EFA3-DD9C-4E3E-B566-50F929386280 and allowed values 0 = Take no action, 1 = Sleep (default), 2 = Hibernate, 3 = Shut down; the same GUID is documented as the PBUTTONACTION power setting in the OEM power-settings reference. Power.admx puts the plugged-in value in ACSettingIndex (the same page documents that value name for the sibling ACPromptForPasswordOnResume_2 policy under the identical key layout). Because the annoyance is specific to the Surface keyboard layout, the entry declares a Condition matching the documented Surface Laptop SMBIOS System SKU, so it is a no-op on other hardware. Holding the power button for several seconds still force-powers the machine off at firmware level, and Sleep/Shut down remain available from the Start menu, so nothing is lost. Kept opt-in (Profiles=opinionated) because it is a personal preference.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-power#selectpowerbuttonactionpluggedin'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Set ACSettingIndex to 1 (Sleep, the Windows default) or delete the value/key under SOFTWARE\Policies\Microsoft\Power\PowerSettings\7648EFA3-DD9C-4E3E-B566-50F929386280; with the policy removed the choice returns to Control Panel > Power Options > Choose what the power button does.'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-power-button-no-action-dc'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'System & recovery'
            Profiles       = @('opinionated')
            Condition      = @{
                Description = 'Microsoft Surface Laptop devices only (SMBIOS System SKU starts with Surface_Laptop).'
                Citation    = 'https://learn.microsoft.com/en-us/surface/surface-system-sku-reference'
                Script      = @'
$cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
($cs.SystemSKUNumber -like 'Surface_Laptop*') -or ($cs.Model -like '*Surface Laptop*')
'@
            }
            Target         = @{
                Hive  = 'SOFTWARE'
                Path  = 'Policies\Microsoft\Power\PowerSettings\7648EFA3-DD9C-4E3E-B566-50F929386280'
                Name  = 'DCSettingIndex'
                Kind  = 'DWord'
                Value = 0
            }
            Description    = 'On Surface Laptops only: makes pressing the power button do nothing while on battery (power-button action = Take no action) instead of putting the machine to sleep.'
            Rationale      = 'The on-battery counterpart of reg-power-button-no-action-ac: without it a Surface Laptop would still sleep on an accidental power-button press whenever it is unplugged, which is the common case for a laptop. Microsoft documents SelectPowerButtonActionOnBattery ("Select the Power button action (on battery)", Computer Configuration > System > Power Management > Button Settings) with the registry key Software\Policies\Microsoft\Power\PowerSettings\7648EFA3-DD9C-4E3E-B566-50F929386280 and allowed values 0 = Take no action, 1 = Sleep (default), 2 = Hibernate, 3 = Shut down; Power.admx puts the on-battery value in DCSettingIndex (the same page documents that value name for the sibling DCPromptForPasswordOnResume_2 policy under the identical key layout). It carries the same documented Surface Laptop SMBIOS System SKU Condition as its plugged-in counterpart, so it is a no-op on other hardware. The lid-close action is deliberately left untouched, so closing the lid still sleeps the machine as usual. Kept opt-in (Profiles=opinionated) as a personal preference.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-power#selectpowerbuttonactiononbattery'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Set DCSettingIndex to 1 (Sleep, the Windows default) or delete the value/key under SOFTWARE\Policies\Microsoft\Power\PowerSettings\7648EFA3-DD9C-4E3E-B566-50F929386280; with the policy removed the choice returns to Control Panel > Power Options > Choose what the power button does.'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-time-dst-automatic'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'System & recovery'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'SYSTEM'
                Path  = 'ControlSet001\Control\TimeZoneInformation'
                Name  = 'DynamicDaylightTimeDisabled'
                Kind  = 'DWord'
                Value = 0
            }
            Description    = 'Ensures "Adjust for daylight saving time automatically" is ON (DynamicDaylightTimeDisabled = 0).'
            Rationale      = 'The automatic DST adjustment is controlled machine-wide by DynamicDaylightTimeDisabled under SYSTEM\...\Control\TimeZoneInformation; 0 = automatically adjust for DST (the Windows default). Set explicitly to guarantee it is on. The exact value name is community-documented rather than in a single authoritative policy page, so it is opt-in.'
            Citation       = 'Unverified'
            EvidenceGrade  = 3
            Reversible     = $true
            Reversal       = 'Set DynamicDaylightTimeDisabled to 1 to stop auto-adjusting for DST, under SYSTEM\ControlSet001\Control\TimeZoneInformation.'
            DefaultEnabled = $false
            Unverified     = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-time-sync-automatic'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'System & recovery'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'SYSTEM'
                Path  = 'ControlSet001\Services\W32Time'
                Name  = 'Start'
                Kind  = 'DWord'
                Value = 2
            }
            Description    = 'Sets the Windows Time service (W32Time) to start automatically so time is kept in sync ("Set time automatically").'
            Rationale      = 'The "Set time automatically" toggle relies on the Windows Time service running and syncing via NTP. Setting the W32Time service Start type to 2 (Automatic) under SYSTEM\...\Services\W32Time ensures the service runs and keeps the clock synced. Microsoft documents the Windows Time service and its settings. The precise mapping of the Settings toggle to Start=2 is inferred/community-documented, so it is opt-in and should be validated on first boot.'
            Citation       = 'https://learn.microsoft.com/en-us/windows-server/networking/windows-time-service/windows-time-service-tools-and-settings'
            EvidenceGrade  = 3
            Reversible     = $true
            Reversal       = 'Set the W32Time service Start value back to 3 (Manual/trigger-start, the default) under SYSTEM\ControlSet001\Services\W32Time.'
            DefaultEnabled = $false
            Unverified     = $true
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-timezone-automatic'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'System & recovery'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'SYSTEM'
                Path  = 'ControlSet001\Services\tzautoupdate'
                Name  = 'Start'
                Kind  = 'DWord'
                Value = 3
            }
            Description    = 'Enables "Set time zone automatically" by setting the tzautoupdate service Start to 3 (demand/enabled). Requires Location services to be on.'
            Rationale      = 'The "Set time zone automatically" toggle is backed by the tzautoupdate service; Start = 3 enables it (Start = 4 disables it). It only actually updates the time zone when Location services are enabled, because it derives the zone from location. The value is community-documented (no single authoritative policy page) and depends on Location being on, so it is opt-in and should be validated on first boot.'
            Citation       = 'Unverified'
            EvidenceGrade  = 3
            Reversible     = $true
            Reversal       = 'Set the tzautoupdate service Start value to 4 (disabled) under SYSTEM\ControlSet001\Services\tzautoupdate.'
            DefaultEnabled = $false
            Unverified     = $true
            Arch           = @('amd64', 'arm64')
        },

        # Third-party/OEM service disable. The service key only exists once the OEM audio package
        # is installed, so the Target sets OnlyIfKeyExists = $true: on a clean image (or a machine
        # without Waves) the entry is reported NotApplicable instead of fabricating an orphan
        # Services key. In practice this lands via post-install.ps1 on the installed machine.
        @{
            Id             = 'reg-disable-waves-audio-service'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Bundled apps'
            Profiles       = @('opinionated')
            Target         = @{
                Hive            = 'SYSTEM'
                Path            = 'ControlSet001\Services\WavesSysSvc'
                Name            = 'Start'
                Kind            = 'DWord'
                Value           = 4
                OnlyIfKeyExists = $true
            }
            Description    = 'Disables the OEM-bundled "Waves Audio Services" service (WavesSysSvc) by setting its Start value to 4 (Disabled). Only applied when the service is actually present, so it normally takes effect through post-install.ps1 on the installed machine; the running instance keeps going until the next reboot.'
            Rationale      = 'WavesSysSvc is the service behind Waves MaxxAudio, pre-installed by OEMs such as Dell alongside the Realtek audio driver. Owners repeatedly report the MaxxAudio service pegging a core (70-90% CPU) indefinitely, keeping fans spinning; disabling the service stops that at the cost of the MaxxAudio enhancements (and, on some models, the headphone/speaker auto-switch prompt) while Windows keeps working with the standard audio driver. Setting a service Start value to 4 under SYSTEM\...\Services\<Name> is the documented way to disable a service (SERVICE_DISABLED). The cited source is an OEM support forum thread that establishes the high-CPU behaviour but not the fix, and the trade-off is user-visible, so this is EvidenceGrade 3 and strictly opt-in (part of the opinionated profile only). Because the service key does not exist in a clean Windows image, the Target sets OnlyIfKeyExists so the entry reports NotApplicable rather than fabricating an orphan Services key.'
            Citation       = 'https://www.dell.com/community/en/conversations/windows-general/waves-maxxaudio-service-70-90-of-cpu-on-windows-11/647f9984f4ccf8a8dece3709'
            EvidenceGrade  = 3
            Reversible     = $true
            Reversal       = 'Restore the previous Start value for WavesSysSvc under SYSTEM\ControlSet001\Services\WavesSysSvc (typically 2 = Automatic; check your OEM build before changing it) — or set "Waves Audio Services" back to its original startup type in services.msc — and reboot. Reinstall the OEM Waves MaxxAudio package if it was removed.'
            DefaultEnabled = $false
            Unverified     = $true
            Arch           = @('amd64', 'arm64')
        },

        # Built-in OpenSSH agent disable, for setups where a third-party agent (1Password,
        # KeePassXC, ...) owns the \\.\pipe\openssh-ssh-agent named pipe. OnlyIfKeyExists guards
        # the (unlikely) case of an image with the OpenSSH Client capability removed.
        @{
            Id             = 'reg-disable-openssh-agent'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Development'
            Profiles       = @('opinionated')
            Target         = @{
                Hive            = 'SYSTEM'
                Path            = 'ControlSet001\Services\ssh-agent'
                Name            = 'Start'
                Kind            = 'DWord'
                Value           = 4
                OnlyIfKeyExists = $true
            }
            Description    = 'Disables the built-in "OpenSSH Authentication Agent" service (ssh-agent) by setting its Start value to 4 (Disabled), so a third-party SSH agent such as 1Password can own the OpenSSH named pipe.'
            Rationale      = 'The Windows OpenSSH Authentication Agent serves keys over the named pipe \\.\pipe\openssh-ssh-agent. Third-party agents (1Password, and equally KeePassXC or Bitwarden) reuse that same pipe, so when the built-in ssh-agent service is running it takes the pipe first and clients silently talk to the wrong agent — 1Password''s own Windows setup guide therefore instructs you to stop the service and set its Startup type to Disabled. Setting the service Start value to 4 under SYSTEM\...\Services\ssh-agent is the documented registry representation of "Disabled" (SERVICE_DISABLED) and is exactly what services.msc writes. Stock Windows 11 already ships ssh-agent as Disabled, so offline this is a guarantee rather than a change; it mainly matters through post-install.ps1 on machines where something (a dev tool, Git for Windows setup, or a previous manual "sc config ssh-agent start=auto") turned it on. Grade 2: the disable step is documented by 1Password (reputable third-party) rather than by Microsoft, and the Start=4 mapping is Microsoft-documented service configuration. Kept opt-in (Profiles=opinionated) because it breaks the native ssh-agent workflow for anyone not using a third-party agent.'
            Citation       = 'https://www.1password.dev/ssh/get-started#check-if-the-openssh-authentication-agent-service-is-installed-and-running'
            EvidenceGrade  = 2
            Reversible     = $true
            Reversal       = 'Set the ssh-agent service Start value back to 3 (Manual) — or 2 (Automatic) if you want it to start on boot — under SYSTEM\ControlSet001\Services\ssh-agent, or set "OpenSSH Authentication Agent" back to Manual/Automatic in services.msc, then start the service.'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        # --- Personalization: taskbar & File Explorer per-user tweaks (current + future) ---
        @{
            Id             = 'reg-hide-taskbar-search'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Personalization'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'DEFAULT'
                Path  = 'Software\Microsoft\Windows\CurrentVersion\Search'
                Name  = 'SearchboxTaskbarMode'
                Kind  = 'DWord'
                Value = 0
            }
            Description    = 'Hides the taskbar search box/icon (SearchboxTaskbarMode = 0 = Hide) for new profiles and, via post-install, the current user.'
            Rationale      = 'The taskbar search presentation is the per-user SearchboxTaskbarMode value under HKCU\Software\Microsoft\Windows\CurrentVersion\Search; Microsoft documents the modes (0 = Hide, 1 = icon, 2 = icon+label, 3 = box) alongside the ConfigureSearchOnTaskbarMode policy. 0 removes the search UI from the taskbar. Written to the DEFAULT hive for new profiles and applied to the current user by post-install (Scope=Both). Kept opt-in as a personal-taste taskbar preference.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/apps/develop/settings/settings-windows-11'
            EvidenceGrade  = 2
            Reversible     = $true
            Reversal       = 'Set SearchboxTaskbarMode to 3 (search box, the default) or delete it under Software\Microsoft\Windows\CurrentVersion\Search in HKCU and the default-user hive.'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-disable-task-view'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Personalization'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'DEFAULT'
                Path  = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
                Name  = 'ShowTaskViewButton'
                Kind  = 'DWord'
                Value = 0
            }
            Description    = 'Removes the Task View button from the taskbar (ShowTaskViewButton = 0) for new profiles and, via post-install, the current user.'
            Rationale      = 'The Task View taskbar button is the per-user ShowTaskViewButton value under HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced, documented by Microsoft in the Windows 11 settings reference; 0 hides it (Win+Tab still works). Written to the DEFAULT hive for new profiles and applied to the current user by post-install (Scope=Both). Opt-in personal-taste preference.'
            Citation       = 'https://learn.microsoft.com/en-us/windows/apps/develop/settings/settings-windows-11'
            EvidenceGrade  = 1
            Reversible     = $true
            Reversal       = 'Set ShowTaskViewButton to 1 (or delete it) under Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced in HKCU and the default-user hive.'
            DefaultEnabled = $false
            Arch           = @('amd64', 'arm64')
        },

        @{
            Id             = 'reg-show-hidden-items'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Personalization'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'DEFAULT'
                Path  = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
                Name  = 'Hidden'
                Kind  = 'DWord'
                Value = 1
            }
            Description    = 'Shows hidden files and folders in File Explorer (Hidden = 1) for new profiles and, via post-install, the current user.'
            Rationale      = 'The "show hidden files" toggle is the per-user Hidden value under HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced (1 = show, 2 = do not show). Showing hidden items is a developer/power-user convenience. Written to the DEFAULT hive for new profiles and applied to the current user by post-install (Scope=Both). The exact value is community-documented rather than in a single authoritative policy page, so it is opt-in.'
            Citation       = 'Unverified'
            EvidenceGrade  = 3
            Reversible     = $true
            Reversal       = 'Set Hidden to 2 (or delete it) under Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced in HKCU and the default-user hive.'
            DefaultEnabled = $false
            Unverified     = $true
            Arch           = @('amd64', 'arm64')
        },

        # --- Personalization: Windows Spotlight as the desktop background (best-effort) ----
        # Microsoft documents the desktop background kind as the Personalization WallpaperKind
        # enum (SolidColor=0, Image=1, Slideshow=2, Spotlight=3), surfaced through the
        # Personalization CSP rather than a single authoritative registry value. The per-user
        # HKCU\...\Explorer\Wallpapers\BackgroundType mirrors that enum, so BackgroundType=3
        # selects Spotlight. This is best-effort/community-territory (grade 3, opt-in): it may need
        # an Explorer restart / sign-in to take effect and the Spotlight content-delivery must be
        # available on the edition.
        @{
            Id             = 'reg-spotlight-desktop-background'
            Type           = 'Registry'
            Action         = 'SetRegistry'
            Category       = 'Personalization'
            Profiles       = @('opinionated')
            Target         = @{
                Hive  = 'DEFAULT'
                Path  = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers'
                Name  = 'BackgroundType'
                Kind  = 'DWord'
                Value = 3
            }
            Description    = 'Selects Windows Spotlight as the desktop background (BackgroundType = 3) for new profiles and, via post-install, the current user (best-effort).'
            Rationale      = 'Microsoft documents the desktop background kind as the Personalization WallpaperKind enumeration where Spotlight = 3 (settings reference). That enum is exposed through the Personalization CSP; the per-user HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers\BackgroundType value mirrors it, so BackgroundType = 3 selects the daily Windows Spotlight image. There is no single authoritative registry-only citation for activating desktop Spotlight (it is CSP-driven), so this is a best-effort, community-territory tweak (EvidenceGrade 3, opt-in) that may require an Explorer restart or sign-in to take effect. Written to the DEFAULT hive for new profiles and the current user (Scope=Both).'
            Citation       = 'https://learn.microsoft.com/en-us/windows/apps/develop/settings/settings-windows-11'
            EvidenceGrade  = 3
            Reversible     = $true
            Reversal       = 'Set BackgroundType to 1 (Image) or your preferred kind, or delete it, under Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers in HKCU and the default-user hive, then reselect a background in Settings > Personalization > Background.'
            DefaultEnabled = $false
            Unverified     = $true
            Arch           = @('amd64', 'arm64')
        }
    )
}
