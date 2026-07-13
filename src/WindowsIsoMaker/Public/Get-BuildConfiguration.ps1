function Get-BuildConfiguration {
    <#
    .SYNOPSIS
        Load and resolve the effective build configuration from a config file, environment,
        and optional last-mile parameters (schema v2).
    .DESCRIPTION
        The configuration FILE is the primary interface for driving a build (Constitution
        Principle V). This function loads config/build.config.psd1 by default, or any saved
        profile supplied via -Path (alias -ConfigPath) or the WIM_CONFIG_PATH environment
        variable, applies WIM_* environment overrides, then applies explicit parameters as
        optional last-mile overrides. Precedence (later wins):

            file defaults  ->  WIM_* environment variables  ->  explicit parameters

        Change selection is fully DATA-DRIVEN (FR-024): there are NO per-feature switches such
        as -RemoveEdge/-RemoveOneDrive. Selection is resolved from the Profile baseline, the
        config Toggles map, and EnableCatalogId/DisableCatalogId (explicit ids win) via
        Resolve-CatalogSelection. Edge/OneDrive/WSL are ordinary opt-in catalog entries.

        It validates the resolved values and returns a BuildConfiguration object (see
        data-model) with a SelectedCatalog property plus the resolved Autounattend and
        AzureUpload sub-configs.
    .PARAMETER Path
        Path to a build configuration .psd1 file. Alias: -ConfigPath. Defaults to
        config/build.config.psd1 (or WIM_CONFIG_PATH when set). Keep multiple saved profiles
        (e.g. build.pro.psd1, build.arm64.psd1) and point -Path at the one you want.
    .PARAMETER Edition
        Optional override for the Windows edition (non-empty).
    .PARAMETER Language
        Optional override for the display language (non-empty).
    .PARAMETER Release
        Optional override for the Windows release (non-empty).
    .PARAMETER Architecture
        Optional override for the target architecture ('amd64' | 'arm64').
    .PARAMETER Profile
        Optional override for the catalog profile ('minimal' | 'default' | 'aggressive' | 'gaming').
    .PARAMETER EnableCatalogId
        Catalog ids to force-enable (opt-in), e.g. 'remove-edge','feature-wsl'.
    .PARAMETER DisableCatalogId
        Catalog ids to force-disable (explicit ids win).
    .EXAMPLE
        Get-BuildConfiguration
        Loads the default config and returns the resolved BuildConfiguration.
    .EXAMPLE
        Get-BuildConfiguration -ConfigPath config/build.arm64.psd1 -EnableCatalogId 'feature-wsl'
        Loads a saved arm64 profile and enables the opt-in WSL feature.
    .OUTPUTS
        PSCustomObject (BuildConfiguration).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', 'Profile',
        Justification = "'Profile' is the documented, user-facing configuration concept (minimal/default/aggressive). The parameter is locally scoped and never writes the global profile path.")]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [Alias('ConfigPath')]
        [string] $Path,

        [Parameter()]
        [string] $Edition,

        [Parameter()]
        [string] $Language,

        [Parameter()]
        [string] $Release,

        [Parameter()]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter()]
        [ValidateSet('minimal', 'default', 'aggressive', 'gaming')]
        [string] $Profile,

        [Parameter()]
        [string[]] $EnableCatalogId,

        [Parameter()]
        [string[]] $DisableCatalogId
    )

    # --- 1. Resolve which config file to load (Path -> WIM_CONFIG_PATH -> default). ---
    if (-not $PSBoundParameters.ContainsKey('Path') -or [string]::IsNullOrWhiteSpace($Path)) {
        if ($env:WIM_CONFIG_PATH) {
            $Path = $env:WIM_CONFIG_PATH
        }
        else {
            $repoRoot = Split-Path -Parent (Split-Path -Parent $script:ModuleRoot)
            $Path = Join-Path -Path $repoRoot -ChildPath 'config/build.config.psd1'
        }
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Build configuration file not found: '$Path'."
    }

    Write-BuildLog -Level Verbose -Component 'Get-BuildConfiguration' -Message "Loading configuration from '$Path'"
    $fileData = Import-PowerShellDataFile -LiteralPath $Path

    # --- 2. Start from documented defaults, then layer the file on top. ---
    $resolved = @{
        Edition           = 'Pro'
        Language          = 'en-US'
        Release           = 'latest'
        Architecture      = 'amd64'
        Profile           = 'default'
        Toggles           = @{}
        EnableCatalogId   = @()
        DisableCatalogId  = @()
        Autounattend      = $null
        AzureUpload       = $null
        WorkingDirectory  = ''
        OutputDirectory   = './out'
        IsoPath           = ''
        BootTest          = $false
        CompressionFormat = 'zip'
        FidoPath          = 'vendor/fido/Fido.ps1'
        OscdimgPath       = ''
    }
    foreach ($key in $fileData.Keys) {
        $resolved[$key] = $fileData[$key]
    }

    # --- 3. Apply WIM_* environment overrides (over the file). ---
    $envMap = @{
        WIM_EDITION    = 'Edition'
        WIM_LANGUAGE   = 'Language'
        WIM_RELEASE    = 'Release'
        WIM_ARCH       = 'Architecture'
        WIM_PROFILE    = 'Profile'
        WIM_OUTPUT_DIR = 'OutputDirectory'
        WIM_BOOT_TEST  = 'BootTest'
    }
    $booleanFields = @('BootTest')
    foreach ($envName in $envMap.Keys) {
        $field = $envMap[$envName]
        $envItem = Get-Item -Path "Env:$envName" -ErrorAction SilentlyContinue
        if ($null -ne $envItem) {
            $value = $envItem.Value
            if ($field -in $booleanFields) {
                $resolved[$field] = ConvertTo-BuildBoolean -Value $value
            }
            else {
                $resolved[$field] = $value
            }
        }
    }

    # Comma/semicolon-separated id lists for opt-in enable/disable via env.
    if ($env:WIM_ENABLE_CATALOG_ID) {
        $resolved['EnableCatalogId'] = @($env:WIM_ENABLE_CATALOG_ID -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    if ($env:WIM_DISABLE_CATALOG_ID) {
        $resolved['DisableCatalogId'] = @($env:WIM_DISABLE_CATALOG_ID -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    # Optional Azure upload target from env (repo-var driven; never secrets).
    if ($env:WIM_AZURE_STORAGE_ACCOUNT -and $env:WIM_AZURE_STORAGE_CONTAINER) {
        $resolved['AzureUpload'] = @{
            StorageAccount   = $env:WIM_AZURE_STORAGE_ACCOUNT
            Container        = $env:WIM_AZURE_STORAGE_CONTAINER
        }
    }

    # --- 4. Apply explicit parameters (highest precedence). ---
    if ($PSBoundParameters.ContainsKey('Edition')) { $resolved['Edition'] = $Edition }
    if ($PSBoundParameters.ContainsKey('Language')) { $resolved['Language'] = $Language }
    if ($PSBoundParameters.ContainsKey('Release')) { $resolved['Release'] = $Release }
    if ($PSBoundParameters.ContainsKey('Architecture')) { $resolved['Architecture'] = $Architecture }
    if ($PSBoundParameters.ContainsKey('Profile')) { $resolved['Profile'] = $Profile }
    if ($PSBoundParameters.ContainsKey('EnableCatalogId')) { $resolved['EnableCatalogId'] = @($EnableCatalogId) }
    if ($PSBoundParameters.ContainsKey('DisableCatalogId')) { $resolved['DisableCatalogId'] = @($DisableCatalogId) }

    # --- 5. Validate the resolved values (Principle VII input validation). ---
    if ([string]::IsNullOrWhiteSpace([string]$resolved['Edition'])) {
        throw "Invalid configuration: 'Edition' must be a non-empty string."
    }
    if ([string]::IsNullOrWhiteSpace([string]$resolved['Language'])) {
        throw "Invalid configuration: 'Language' must be a non-empty string."
    }
    if ([string]::IsNullOrWhiteSpace([string]$resolved['Release'])) {
        throw "Invalid configuration: 'Release' must be a non-empty string."
    }
    if (@('amd64', 'arm64') -notcontains $resolved['Architecture']) {
        throw "Invalid configuration: 'Architecture' must be 'amd64' or 'arm64' (got '$($resolved['Architecture'])')."
    }
    if (@('minimal', 'default', 'aggressive', 'gaming') -notcontains $resolved['Profile']) {
        throw "Invalid configuration: 'Profile' must be 'minimal', 'default', 'aggressive', or 'gaming' (got '$($resolved['Profile'])')."
    }
    if (@('zip', '7z') -notcontains $resolved['CompressionFormat']) {
        throw "Invalid configuration: 'CompressionFormat' must be 'zip' or '7z' (got '$($resolved['CompressionFormat'])')."
    }

    # --- 6. Resolve working directory default. ---
    if ([string]::IsNullOrWhiteSpace([string]$resolved['WorkingDirectory'])) {
        $resolved['WorkingDirectory'] = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'WindowsIsoMaker'
    }

    # --- 7. Normalize the Toggles map (hashtable of Id -> bool). ---
    $toggles = @{}
    if ($resolved['Toggles'] -is [hashtable]) {
        foreach ($k in $resolved['Toggles'].Keys) {
            $toggles[[string]$k] = [bool]$resolved['Toggles'][$k]
        }
    }

    # --- 8. Resolve the effective catalog selection (validates unknown ids). ---
    $catalog = Import-ChangeCatalog
    $selected = Resolve-CatalogSelection -Catalog $catalog -Architecture $resolved['Architecture'] `
        -Profile $resolved['Profile'] -Toggles $toggles `
        -EnableCatalogId @($resolved['EnableCatalogId']) `
        -DisableCatalogId @($resolved['DisableCatalogId'])

    # --- 9. Resolve the Autounattend sub-config (merge over documented defaults). ---
    $autounattend = Resolve-AutounattendConfig -FileValue $resolved['Autounattend'] `
        -Language $resolved['Language'] -Architecture $resolved['Architecture']

    # --- 10. Emit the BuildConfiguration object. ---
    return [pscustomobject]@{
        PSTypeName        = 'WindowsIsoMaker.BuildConfiguration'
        ConfigPath        = (Resolve-Path -LiteralPath $Path).Path
        Edition           = [string]$resolved['Edition']
        Language          = [string]$resolved['Language']
        Release           = [string]$resolved['Release']
        Architecture      = [string]$resolved['Architecture']
        Profile           = [string]$resolved['Profile']
        Toggles           = $toggles
        EnableCatalogId   = @($resolved['EnableCatalogId'])
        DisableCatalogId  = @($resolved['DisableCatalogId'])
        Autounattend      = $autounattend
        AzureUpload       = $resolved['AzureUpload']
        WorkingDirectory  = [string]$resolved['WorkingDirectory']
        OutputDirectory   = [string]$resolved['OutputDirectory']
        IsoPath           = [string]$resolved['IsoPath']
        BootTest          = [bool]$resolved['BootTest']
        CompressionFormat = [string]$resolved['CompressionFormat']
        FidoPath          = [string]$resolved['FidoPath']
        OscdimgPath       = [string]$resolved['OscdimgPath']
        SelectedCatalog   = @($selected)
    }
}

function Resolve-AutounattendConfig {
    <#
    .SYNOPSIS
        Merge the Autounattend sub-config from the config file over documented defaults.
    .DESCRIPTION
        Private helper for Get-BuildConfiguration. Returns a normalized hashtable describing
        the Autounattend.xml generation options (FR-027). No password/secret is ever stored.
    .PARAMETER FileValue
        The raw Autounattend hashtable from the config file (or $null).
    .PARAMETER Language
        The resolved display language, used as the default locale.
    .PARAMETER Architecture
        The resolved architecture (recorded for reference; the XML processorArchitecture is
        set by New-AutounattendXml).
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] $FileValue,
        [Parameter(Mandatory = $true)] [string] $Language,
        [Parameter(Mandatory = $true)] [string] $Architecture
    )

    $defaults = @{
        Enabled               = $true
        SkipOobe              = $true
        BypassMsAccount       = $true
        CreateLocalAccount    = $true
        LocalAccountName      = 'Admin'
        Locale                = $Language
        KeyboardLayout        = '0409:00000409'
        TimeZone              = 'UTC'
        DiskId                = 0
        FirstLogonCommands    = @()
        SetupCompleteCommands = @()
    }

    if ($FileValue -is [hashtable]) {
        foreach ($k in $FileValue.Keys) {
            $defaults[[string]$k] = $FileValue[$k]
        }
    }

    return $defaults
}

function ConvertTo-BuildBoolean {
    <#
    .SYNOPSIS
        Convert a string environment value to a boolean.
    .DESCRIPTION
        Private helper. Interprets common truthy strings ('1','true','yes','on') as $true
        and everything else as $false, case-insensitively.
    .PARAMETER Value
        The string value to interpret.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()] [string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return @('1', 'true', 'yes', 'on') -contains $Value.Trim().ToLowerInvariant()
}
