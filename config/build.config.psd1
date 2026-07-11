@{
    # ============================================================================
    # Default build configuration for WindowsIsoMaker.
    #
    # THIS FILE IS THE PRIMARY INTERFACE for driving a build. Edit it (or copy it to a
    # saved profile such as config/build.arm64.psd1 and pass -ConfigPath / set
    # WIM_CONFIG_PATH) rather than passing long parameter lists. Explicit build.ps1
    # parameters and WIM_* environment variables exist only as optional last-mile overrides.
    #
    # Precedence (later wins): these file defaults  ->  WIM_* env vars  ->  explicit params.
    # See specs/.../contracts/build-config.schema.md for the full schema.
    # ============================================================================

    # --- Base image selection (FR-001, FR-002) ---
    Edition      = 'Pro'        # Windows 11 edition
    Language     = 'en-US'      # display language (BCP-47)
    Release      = 'latest'     # resolved by Fido at build time; actual recorded in RunReport
    Architecture = 'amd64'      # 'amd64' | 'arm64' (validated)

    # --- Profile & change selection ---
    Profile          = 'default'  # selects the DefaultEnabled catalog subset
    IncludeCatalogId = @()        # add specific catalog entries by Id (opt-in)
    ExcludeCatalogId = @()        # remove specific catalog entries by Id

    # --- Opt-in impactful removals (FR-008, Principle VI: default OFF) ---
    RemoveEdge     = $false
    RemoveOneDrive = $false

    # --- Working locations (Principle VI: scoped, no host-wide writes) ---
    WorkingDirectory = ''         # empty = <TEMP>\WindowsIsoMaker (resolved at runtime)
    OutputDirectory  = './out'    # where the compressed artifact + RunReport are written

    # --- Optional pre-downloaded ISO override (skip Fido download) ---
    IsoPath = ''                  # empty = download via Fido

    # --- Validation (FR-023) ---
    BootTest = $false             # opt-in VM boot test; default = structural checks only

    # --- Artifact ---
    CompressionFormat = 'zip'     # 'zip' | '7z'

    # --- Tooling (pinned; Principle V) ---
    FidoPath    = 'vendor/fido/Fido.ps1'
    OscdimgPath = ''              # empty = auto-detect from a Windows ADK install
}
