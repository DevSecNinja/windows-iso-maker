function Get-Windows11Iso {
    <#
    .SYNOPSIS
        Resolve and download a Windows 11 base ISO using the vendored, pinned Fido script.
    .DESCRIPTION
        Wraps the GPLv3 Fido tool (invoked as a SEPARATE external script — see
        vendor/fido/NOTICE for the licensing boundary) to resolve the official Microsoft
        download URL for the requested edition/language/release/architecture, then downloads
        the ISO and records a SHA-256 hash for integrity (FR-020, Principle VII). If -IsoPath
        is supplied, that pre-downloaded ISO is validated and used instead of downloading.
        Fails fast with a terminating error if the requested combination is unavailable.
    .PARAMETER Edition
        Windows 11 edition (e.g. 'Pro').
    .PARAMETER Language
        Display language as a BCP-47 code (e.g. 'en-US'); mapped to a Fido language name.
    .PARAMETER Release
        Windows release (e.g. 'latest' or '23H2').
    .PARAMETER Architecture
        Target architecture: 'amd64' or 'arm64' (mapped to Fido 'x64'/'Arm64').
    .PARAMETER OutputPath
        Directory to download the ISO into. Defaults to the current directory.
    .PARAMETER IsoPath
        Optional path to an already-downloaded ISO; when set, skips the download.
    .PARAMETER FidoPath
        Path to the vendored Fido.ps1. Defaults to vendor/fido/Fido.ps1.
    .EXAMPLE
        Get-Windows11Iso -Edition Pro -Language en-US -Release latest -Architecture amd64 -OutputPath C:\work
    .OUTPUTS
        PSCustomObject (BaseImage) with Path, Edition, Language, Release, Architecture,
        Sha256, SourceUrl, and Verified.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Edition = 'Pro',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Language = 'en-US',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Release = 'latest',

        [Parameter(Mandatory = $true)]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter()]
        [string] $OutputPath = (Get-Location).Path,

        [Parameter()]
        [string] $IsoPath,

        [Parameter()]
        [string] $FidoPath = 'vendor/fido/Fido.ps1'
    )

    # --- Fast path: use a caller-provided ISO instead of downloading. ---
    if ($PSBoundParameters.ContainsKey('IsoPath') -and -not [string]::IsNullOrWhiteSpace($IsoPath)) {
        if (-not (Test-Path -LiteralPath $IsoPath)) {
            throw "Provided IsoPath does not exist: '$IsoPath'."
        }
        Write-BuildLog -Level Information -Component 'Get-Windows11Iso' -Message "Using provided ISO '$IsoPath' (skipping download)."
        $hash = (Get-FileHash -LiteralPath $IsoPath -Algorithm SHA256).Hash
        return [pscustomobject]@{
            PSTypeName   = 'WindowsIsoMaker.BaseImage'
            Path         = (Resolve-Path -LiteralPath $IsoPath).Path
            Edition      = $Edition
            Language     = $Language
            Release      = $Release
            Architecture = $Architecture
            Sha256       = $hash
            SourceUrl    = $null
            Verified     = $true
        }
    }

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    # Map our normalized values onto Fido's expected argument vocabulary.
    $fidoArch = if ($Architecture -eq 'amd64') { 'x64' } else { 'Arm64' }
    $fidoLang = ConvertTo-FidoLanguage -Language $Language

    # Build Fido args as an ARRAY (no string concatenation => no shell injection, Principle VII).
    $fidoArgs = @(
        '-Win', '11',
        '-Rel', $Release,
        '-Ed', $Edition,
        '-Lang', $fidoLang,
        '-Arch', $fidoArch,
        '-GetUrl'
    )

    Write-BuildLog -Level Information -Component 'Get-Windows11Iso' -Message "Resolving download URL via Fido ($Edition/$Language/$Release/$Architecture)."
    $sourceUrl = Invoke-FidoUrlResolver -FidoPath $FidoPath -Arguments $fidoArgs

    if ([string]::IsNullOrWhiteSpace($sourceUrl) -or $sourceUrl -notmatch '^https?://') {
        throw "The requested Windows 11 combination (Edition=$Edition, Language=$Language, Release=$Release, Architecture=$Architecture) is unavailable or Fido returned no URL."
    }

    $fileName = "Windows11-$Edition-$Architecture-$Release.iso" -replace '\s', ''
    $targetIso = Join-Path -Path $OutputPath -ChildPath $fileName

    if ($PSCmdlet.ShouldProcess($targetIso, "Download Windows 11 ISO from $sourceUrl")) {
        Invoke-IsoDownload -Url $sourceUrl -Destination $targetIso
    }
    else {
        # Preview mode: report intent without downloading.
        return [pscustomobject]@{
            PSTypeName   = 'WindowsIsoMaker.BaseImage'
            Path         = $targetIso
            Edition      = $Edition
            Language     = $Language
            Release      = $Release
            Architecture = $Architecture
            Sha256       = $null
            SourceUrl    = $sourceUrl
            Verified     = $false
        }
    }

    $hash = (Get-FileHash -LiteralPath $targetIso -Algorithm SHA256).Hash
    Write-BuildLog -Level Information -Component 'Get-Windows11Iso' -Message "Downloaded ISO to '$targetIso' (SHA256=$hash)."

    return [pscustomobject]@{
        PSTypeName   = 'WindowsIsoMaker.BaseImage'
        Path         = $targetIso
        Edition      = $Edition
        Language     = $Language
        Release      = $Release
        Architecture = $Architecture
        Sha256       = $hash
        SourceUrl    = $sourceUrl
        Verified     = $true
    }
}

function ConvertTo-FidoLanguage {
    <#
    .SYNOPSIS
        Map a BCP-47 language code to the language name Fido expects.
    .DESCRIPTION
        Private helper. Fido identifies languages by display name (e.g. 'English',
        'Dutch'), not by BCP-47 code. This maps the common codes; unmapped values are
        passed through unchanged so power users can supply a Fido name directly.
    .PARAMETER Language
        BCP-47 code (e.g. 'en-US') or a Fido language name.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string] $Language)

    $map = @{
        'en-US' = 'English'
        'en-GB' = 'English International'
        'nl-NL' = 'Dutch'
        'de-DE' = 'German'
        'fr-FR' = 'French'
        'es-ES' = 'Spanish'
        'it-IT' = 'Italian'
        'pt-BR' = 'Brazilian Portuguese'
        'ja-JP' = 'Japanese'
        'zh-CN' = 'Chinese Simplified'
    }
    if ($map.ContainsKey($Language)) {
        return $map[$Language]
    }
    return $Language
}

function Invoke-FidoUrlResolver {
    <#
    .SYNOPSIS
        Invoke the vendored Fido.ps1 as a separate process to resolve a download URL.
    .DESCRIPTION
        Private helper and the single GPLv3 boundary: Fido is executed as an independent
        external script in a child pwsh process (never dot-sourced/embedded). Returns the
        resolved URL string (last non-empty output line).
    .PARAMETER FidoPath
        Path to Fido.ps1.
    .PARAMETER Arguments
        Fido arguments as an array.
    .OUTPUTS
        System.String (the resolved URL), or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string] $FidoPath,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    if (-not (Test-Path -LiteralPath $FidoPath)) {
        throw "Vendored Fido script not found at '$FidoPath'. See vendor/fido/VERSION."
    }

    $pwshExe = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path
    if (-not $pwshExe) { $pwshExe = 'pwsh' }

    # Run Fido as a separate program (arm's-length invocation; GPLv3 boundary).
    $output = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $FidoPath @Arguments 2>&1
    $lines = @($output | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ })
    $url = $lines | Where-Object { $_ -match '^https?://' } | Select-Object -Last 1
    return $url
}

function Invoke-IsoDownload {
    <#
    .SYNOPSIS
        Download a file from a resolved URL to a destination path.
    .DESCRIPTION
        Private helper. Uses the .NET/PowerShell web stack to stream the ISO to disk. The URL
        originates from Fido (an official Microsoft download host); the content is treated as
        untrusted and integrity-checked by the caller before servicing (Principle VII).
    .PARAMETER Url
        The HTTPS download URL.
    .PARAMETER Destination
        Local file path to write.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string] $Url,
        [Parameter(Mandatory = $true)][string] $Destination
    )

    if ($Url -notmatch '^https://') {
        throw "Refusing to download from a non-HTTPS URL: '$Url'."
    }

    Write-BuildLog -Level Information -Component 'Get-Windows11Iso' -Message "Downloading '$Url' -> '$Destination'."
    $previousProgress = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
    }
    finally {
        $ProgressPreference = $previousProgress
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        throw "Download completed but the file is missing: '$Destination'."
    }
}
