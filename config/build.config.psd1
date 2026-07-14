@{
    # ============================================================================
    # Default build configuration for WindowsIsoMaker (schema v2).
    #
    # THIS FILE IS THE PRIMARY INTERFACE for driving a build. Edit it (or copy it to a
    # saved profile such as config/build.arm64.psd1 and pass -ConfigPath / set
    # WIM_CONFIG_PATH) rather than passing long parameter lists. Explicit build.ps1
    # parameters and WIM_* environment variables exist only as optional last-mile overrides.
    #
    # Precedence (later wins): these file defaults  ->  WIM_* env vars  ->  explicit params.
    # See specs/.../contracts/build-config.schema.md for the full schema.
    #
    # Change selection is fully DATA-DRIVEN (FR-024) — there are NO per-feature switches such
    # as RemoveEdge/RemoveOneDrive. Select changes via Profile + Toggles + Enable/DisableCatalogId.
    # ============================================================================

    # --- Base image selection (FR-001, FR-002) ---
    Edition      = 'Pro'        # Windows 11 edition. Only Home comes from Fido; every other edition
                               # (Pro, Education, Enterprise, ...) needs a business ISO via IsoPath.
    Language     = 'en-US'      # display language (BCP-47)
    Release      = 'latest'     # resolved by Fido at build time; actual recorded in RunReport
    Architecture = 'amd64'      # 'amd64' | 'arm64' (validated)

    # --- Data-driven change selection (FR-024) ---
    Profile          = 'default'  # 'minimal' | 'default' | 'aggressive' | 'gaming' | 'opinionated'; accepts a list, e.g. @('gaming','opinionated')
    Toggles          = @{}        # per-id override map, e.g. @{ 'appx-todos' = $false; 'feature-wsl' = $true }
    EnableCatalogId  = @('reg-reverse-mouse-scroll')  # opt-in specific catalog entries by Id (e.g. 'remove-edge','feature-wsl')
    DisableCatalogId = @()        # force-disable specific catalog entries by Id (explicit ids win)

    # --- Autounattend.xml generation (FR-027) ---
    # Rendered per-architecture and placed at the ISO root by New-BootableIso. Complementary to
    # the DISM offline servicing above (this handles OOBE / install-time behaviour).
    Autounattend = @{
        Enabled          = $true
        SkipOobe         = $true          # skip the out-of-box experience screens
        # AccountMode: how the first account is provisioned during OOBE.
        #   'local' = create the local admin account below and bypass the online-account screens
        #             (fully hands-off; ideal for a standalone/gaming PC).
        #   'entra' = don't create a local account; let OOBE present the "Set up for work or school"
        #             sign-in so you join Entra ID (Azure AD) and auto-enroll into Intune. This step
        #             is interactive (you enter your Entra credentials); a fully silent join needs
        #             Autopilot or a provisioning package.
        AccountMode      = 'local'         # 'local' | 'entra'
        BypassMsAccount  = $true          # bypass the Microsoft-account requirement (FR-027; local mode)
        CreateLocalAccount = $true        # create a local account instead (default on, toggleable)
        LocalAccountName = 'Admin'        # local account username (no password stored in the file)
        Locale           = 'en-US'        # UI / system language (kept English (United States))
        UserLocale       = 'nl-NL'         # region format for dates/times/numbers = Dutch (Netherlands)
        # KeyboardLayout: input locale. Left unset so the profile-driven default applies:
        #   most profiles => '0409:00000409' (US); the 'opinionated' profile => '0409:00020409'
        #   (United States-International, so English (US) types on US-International). Uncomment to pin.
        # KeyboardLayout   = '0409:00000409'
        TimeZone         = 'W. Europe Standard Time' # Amsterdam (UTC+01:00, DST-aware)
        DiskId           = 0              # target disk for the default single-partition layout
        # ProductKey: baked into the answer file. Windows 11 24H2 Setup only installs hands-off
        # WITHOUT a key on Home; non-Home editions (Pro, Enterprise, ...) need a genuine key
        # (the generic KMS key fails 24H2's new online validation).
        #   ''      = omit the key. Home installs hands-off; non-Home Setup stops for a key.
        #   'none'  = omit entirely (same as '').
        #   '<key>' = use a specific, genuine product key (required for non-Home unattended).
        #   'generic'/'auto' = public generic key for the edition (older media only; fails 24H2).
        ProductKey       = ''
        FirstLogonCommands = @()          # optional array of command strings run at first logon
        SetupCompleteCommands = @()       # optional array of SetupComplete.cmd command strings
    }

    # --- Optional Azure Blob upload of the artifact (FR-030) ---
    # $null (default) => the CI workflow uploads a GitHub Actions artifact instead.
    # To enable, set repo variables (AZURE_STORAGE_ACCOUNT/CONTAINER, AZURE_CLIENT_ID/
    # TENANT_ID/SUBSCRIPTION_ID) — never stored secrets. See docs/azure-upload.md.
    AzureUpload = $null

    # --- Working locations (Principle VI: scoped, no host-wide writes) ---
    WorkingDirectory = ''         # empty = <TEMP>\WindowsIsoMaker (resolved at runtime)
    OutputDirectory  = './out'    # where the compressed artifact + RunReport + BOM are written

    # --- Optional pre-downloaded ISO override (skip Fido download) ---
    IsoPath = ''                  # empty = download via Fido (Home only). REQUIRED for every non-Home
                                  # edition: point it at the business/volume ISO (Fido can't fetch it,
                                  # and consumer Pro/Education images won't activate with a GVLK).

    # --- Validation (FR-023) ---
    BootTest = $false             # opt-in VM boot test; default = structural checks only
    KeepBootTestVm = $false       # with BootTest: keep the VM & pause for manual testing until Enter
    # Which hypervisor runs the opt-in boot test VM:
    #   'HyperV' (default) = Windows Hyper-V; boots OFFLINE by default (dodges the flaky WinPE
    #                        Default Switch DNS proxy).
    #   'VMware'           = VMware Workstation; boots NETWORKED (NAT) by default so WinPE has real
    #                        DNS for a 24H2+ ConX online product-key/edition check (see issue #5).
    #                        VMware Workstation Pro must be downloaded manually (Broadcom login-gated,
    #                        not on winget); if it's missing the boot test prints the download link +
    #                        guided setup steps and stops.
    Hypervisor = 'HyperV'         # 'HyperV' | 'VMware'

    # --- Artifact ---
    CompressionFormat = 'zip'     # 'zip' | '7z'

    # --- Tooling (pinned; Principle V) ---
    # FidoPath empty => download the Fido.ps1 pinned in the manifest (RequiredToolingMinimums)
    # at build time and cache it; set a local path only for offline/air-gapped use.
    FidoPath    = ''
    OscdimgPath = ''              # empty = auto-detect from a Windows ADK install
}
