function Get-BuildConfiguration {
    <#
    .SYNOPSIS
        Load and resolve the effective build configuration from a config file, environment,
        and optional last-mile parameters.
    .DESCRIPTION
        The configuration FILE is the primary interface for driving a build (Constitution
        Principle V). This function loads config/build.config.psd1 by default, or any saved
        profile supplied via -Path (alias -ConfigPath) or the WIM_CONFIG_PATH environment
        variable, applies WIM_* environment overrides, then applies explicit parameters as
        optional last-mile overrides. Precedence (later wins):

            file defaults  ->  WIM_* environment variables  ->  explicit parameters

        It validates the resolved values, resolves which catalog entries are enabled
        (profile + include/exclude + opt-in Edge/OneDrive), and returns a BuildConfiguration
        object (see data-model) with a SelectedCatalog property.
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
        Optional override for the catalog profile.
    .PARAMETER RemoveEdge
        Opt-in switch enabling the (default-off) Edge removal catalog entry.
    .PARAMETER RemoveOneDrive
        Opt-in switch enabling the (default-off) OneDrive removal catalog entry.
    .PARAMETER IncludeCatalogId
        Catalog ids to force-enable.
    .PARAMETER ExcludeCatalogId
        Catalog ids to force-disable.
    .EXAMPLE
        Get-BuildConfiguration
        Loads the default config and returns the resolved BuildConfiguration.
    .EXAMPLE
        Get-BuildConfiguration -ConfigPath config/build.arm64.psd1 -RemoveEdge
        Loads a saved arm64 profile and enables the opt-in Edge removal.
    .OUTPUTS
        PSCustomObject (BuildConfiguration).
    #>
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
        [string] $Profile,

        [Parameter()]
        [switch] $RemoveEdge,

        [Parameter()]
        [switch] $RemoveOneDrive,

        [Parameter()]
        [string[]] $IncludeCatalogId,

        [Parameter()]
        [string[]] $ExcludeCatalogId
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
        IncludeCatalogId  = @()
        ExcludeCatalogId  = @()
        RemoveEdge        = $false
        RemoveOneDrive    = $false
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
        WIM_EDITION         = 'Edition'
        WIM_LANGUAGE        = 'Language'
        WIM_RELEASE         = 'Release'
        WIM_ARCH            = 'Architecture'
        WIM_PROFILE         = 'Profile'
        WIM_REMOVE_EDGE     = 'RemoveEdge'
        WIM_REMOVE_ONEDRIVE = 'RemoveOneDrive'
        WIM_OUTPUT_DIR      = 'OutputDirectory'
        WIM_BOOT_TEST       = 'BootTest'
    }
    $booleanFields = @('RemoveEdge', 'RemoveOneDrive', 'BootTest')
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

    # --- 4. Apply explicit parameters (highest precedence). ---
    if ($PSBoundParameters.ContainsKey('Edition')) { $resolved['Edition'] = $Edition }
    if ($PSBoundParameters.ContainsKey('Language')) { $resolved['Language'] = $Language }
    if ($PSBoundParameters.ContainsKey('Release')) { $resolved['Release'] = $Release }
    if ($PSBoundParameters.ContainsKey('Architecture')) { $resolved['Architecture'] = $Architecture }
    if ($PSBoundParameters.ContainsKey('Profile')) { $resolved['Profile'] = $Profile }
    if ($PSBoundParameters.ContainsKey('RemoveEdge')) { $resolved['RemoveEdge'] = [bool]$RemoveEdge }
    if ($PSBoundParameters.ContainsKey('RemoveOneDrive')) { $resolved['RemoveOneDrive'] = [bool]$RemoveOneDrive }
    if ($PSBoundParameters.ContainsKey('IncludeCatalogId')) { $resolved['IncludeCatalogId'] = @($IncludeCatalogId) }
    if ($PSBoundParameters.ContainsKey('ExcludeCatalogId')) { $resolved['ExcludeCatalogId'] = @($ExcludeCatalogId) }

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
    if (@('zip', '7z') -notcontains $resolved['CompressionFormat']) {
        throw "Invalid configuration: 'CompressionFormat' must be 'zip' or '7z' (got '$($resolved['CompressionFormat'])')."
    }

    # --- 6. Resolve working directory default. ---
    if ([string]::IsNullOrWhiteSpace([string]$resolved['WorkingDirectory'])) {
        $resolved['WorkingDirectory'] = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'WindowsIsoMaker'
    }

    # --- 7. Resolve catalog selection (validate ids exist; enable/disable per rules). ---
    $catalog = Import-ChangeCatalog
    $knownIds = $catalog | ForEach-Object { $_.Id }
    foreach ($id in (@($resolved['IncludeCatalogId']) + @($resolved['ExcludeCatalogId']))) {
        if ($id -and ($knownIds -notcontains $id)) {
            throw "Unknown catalog id '$id' in Include/ExcludeCatalogId. Known ids: $($knownIds -join ', ')."
        }
    }

    $selected = Select-CatalogEntry -Catalog $catalog -Architecture $resolved['Architecture'] `
        -IncludeCatalogId @($resolved['IncludeCatalogId']) `
        -ExcludeCatalogId @($resolved['ExcludeCatalogId']) `
        -RemoveEdge ([bool]$resolved['RemoveEdge']) `
        -RemoveOneDrive ([bool]$resolved['RemoveOneDrive'])

    # --- 8. Emit the BuildConfiguration object. ---
    return [pscustomobject]@{
        PSTypeName        = 'WindowsIsoMaker.BuildConfiguration'
        ConfigPath        = (Resolve-Path -LiteralPath $Path).Path
        Edition           = [string]$resolved['Edition']
        Language          = [string]$resolved['Language']
        Release           = [string]$resolved['Release']
        Architecture      = [string]$resolved['Architecture']
        Profile           = [string]$resolved['Profile']
        RemoveEdge        = [bool]$resolved['RemoveEdge']
        RemoveOneDrive    = [bool]$resolved['RemoveOneDrive']
        IncludeCatalogId  = @($resolved['IncludeCatalogId'])
        ExcludeCatalogId  = @($resolved['ExcludeCatalogId'])
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
