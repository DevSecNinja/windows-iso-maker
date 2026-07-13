function Get-Windows11Iso {
    <#
    .SYNOPSIS
        Resolve and download a Windows 11 base ISO using a pinned, runtime-fetched Fido script.
    .DESCRIPTION
        Wraps the GPLv3 Fido tool (invoked as a SEPARATE external script — see the licensing
        note in docs/provenance-bom.md) to resolve the official Microsoft download URL for the
        requested edition/language/release/architecture, then downloads the ISO and records a
        SHA-256 hash for integrity (FR-020, Principle VII). Fido itself is not vendored: a copy
        pinned to an exact upstream commit (see the manifest RequiredToolingMinimums) is
        downloaded from raw.githubusercontent.com on first use and cached; the 40-char commit
        SHA is content-addressed, so this is deterministic in the same way a pinned GitHub
        Action is. If -IsoPath is supplied, that pre-downloaded ISO is validated and used
        instead of downloading. Fails fast with a terminating error if the requested
        combination is unavailable.
    .PARAMETER Edition
        Windows 11 edition (e.g. 'Pro'). Consumer editions (Home, Pro, Education, ...) all resolve
        to the same downloaded consumer ISO — the edition is selected later at install/servicing
        time — so the cache is keyed by product family, not by edition. Business/Enterprise editions
        are not downloadable via Fido and require a caller-supplied -IsoPath.
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
        Optional path to a local Fido.ps1. When empty (the default), the pinned Fido.ps1 is
        downloaded from raw.githubusercontent.com (by the commit recorded in the manifest) and
        cached; set this only to use an offline/custom copy.
    .PARAMETER Force
        Re-download even if a matching ISO already exists in OutputPath (bypass the cache).
    .PARAMETER ExpectedSha256
        Optional known-good SHA-256. When supplied, the reused-or-downloaded ISO is verified
        against it and a mismatch fails the build; when omitted the hash is recorded only.
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
        [string] $FidoPath = '',

        [Parameter()]
        [switch] $Force,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ExpectedSha256
    )

    # --- Fast path: use a caller-provided ISO instead of downloading. ---
    if ($PSBoundParameters.ContainsKey('IsoPath') -and -not [string]::IsNullOrWhiteSpace($IsoPath)) {
        if (-not (Test-Path -LiteralPath $IsoPath)) {
            throw "Provided IsoPath does not exist: '$IsoPath'."
        }
        Write-BuildLog -Level Information -Component 'Get-Windows11Iso' -Message "Using provided ISO '$IsoPath' (skipping download)."
        $hash = Assert-IsoHash -Path $IsoPath -ExpectedSha256 $ExpectedSha256
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

    # Derive the ISO product family from the edition. Fido only offers the CONSUMER multi-edition
    # ISO for Windows 11 ("Windows 11 Home/Pro/Edu"), which contains Home / Pro / Education / ... —
    # the actual edition is picked at install time (Mount-WindowsBuildImage resolves the WIM index).
    # So every consumer edition shares ONE download, and the cache file is keyed by family (not by
    # edition) to avoid re-downloading the same ISO under Home/Pro/... names. Business/Enterprise
    # editions live in a separate ISO that Fido cannot fetch — those require a caller-supplied -IsoPath.
    $family = Get-Windows11IsoFamily -Edition $Edition

    $fileName = "Windows11-$family-$Architecture-$Release.iso" -replace '\s', ''
    $targetIso = Join-Path -Path $OutputPath -ChildPath $fileName

    # --- Cache path: reuse a previously downloaded ISO. ---
    # Downloads are atomic (see Invoke-IsoDownload), so a fully written target file is known to
    # be complete. Reusing it skips both the multi-GB transfer and the Fido/Sentinel round-trip
    # on repeat runs. Pass -Force to always re-download.
    if (-not $Force -and (Test-Path -LiteralPath $targetIso) -and ((Get-Item -LiteralPath $targetIso).Length -gt 0)) {
        Write-BuildLog -Level Information -Component 'Get-Windows11Iso' -Message "Reusing existing $family ISO '$targetIso' (skipping Fido and download); pass -Force to re-download."
        $hash = Assert-IsoHash -Path $targetIso -ExpectedSha256 $ExpectedSha256
        Write-BuildLog -Level Information -Component 'Get-Windows11Iso' -Message "Existing ISO SHA256=$hash."
        return [pscustomobject]@{
            PSTypeName   = 'WindowsIsoMaker.BaseImage'
            Path         = (Resolve-Path -LiteralPath $targetIso).Path
            Edition      = $Edition
            Language     = $Language
            Release      = $Release
            Architecture = $Architecture
            Sha256       = $hash
            SourceUrl    = $null
            Verified     = $true
        }
    }

    # Business/Enterprise editions are not downloadable via Fido (it only serves the consumer ISO).
    if ($family -eq 'business') {
        throw "Windows 11 '$Edition' is a business/enterprise edition, which is not part of the consumer ISO that Fido can download (Fido only offers the 'Windows 11 Home/Pro/Edu' multi-edition consumer ISO). Provide a business-editions ISO via -IsoPath (or the config 'IsoPath') and re-run."
    }

    # Map our normalized values onto Fido's expected argument vocabulary.
    $fidoArch = if ($Architecture -eq 'amd64') { 'x64' } else { 'Arm64' }
    $fidoLang = ConvertTo-FidoLanguage -Language $Language
    # Fido matches -Ed as a regex against its edition list; the consumer entry is
    # "Windows 11 Home/Pro/Edu". Request that entry explicitly so any consumer edition (Home,
    # Pro, Education, ...) resolves to the same multi-edition ISO regardless of the -Edition asked.
    $fidoEdition = 'Home/Pro/Edu'

    # Build Fido args as an ARRAY (no string concatenation => no shell injection, Principle VII).
    $fidoArgs = @(
        '-Win', '11',
        '-Rel', $Release,
        '-Ed', $fidoEdition,
        '-Lang', $fidoLang,
        '-Arch', $fidoArch,
        '-GetUrl'
    )

    Write-BuildLog -Level Information -Component 'Get-Windows11Iso' -Message "Resolving download URL via Fido ($Edition [$family] / $Language / $Release / $Architecture)."
    $resolvedFido = Resolve-FidoScriptPath -FidoPath $FidoPath
    $sourceUrl = Invoke-FidoUrlResolver -FidoPath $resolvedFido -Arguments $fidoArgs

    if ([string]::IsNullOrWhiteSpace($sourceUrl) -or $sourceUrl -notmatch '^https?://') {
        throw "The requested Windows 11 combination (Edition=$Edition, Language=$Language, Release=$Release, Architecture=$Architecture) is unavailable or Fido returned no URL."
    }

    $fileName = "Windows11-$family-$Architecture-$Release.iso" -replace '\s', ''
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

    $hash = Assert-IsoHash -Path $targetIso -ExpectedSha256 $ExpectedSha256
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

function Get-Windows11IsoFamily {
    <#
    .SYNOPSIS
        Classify a Windows 11 edition into its ISO product family: 'consumer' or 'business'.
    .DESCRIPTION
        Private helper for Get-Windows11Iso. Microsoft ships Windows 11 as two multi-edition ISOs:
        the retail "consumer" ISO (Home, Home N, Home Single Language, Pro, Pro N, Pro Education,
        Pro for Workstations, Education, Education N) and the "business/volume" ISO (Enterprise,
        Enterprise N, IoT Enterprise, LTSC). Fido can only download the consumer ISO for Windows 11,
        so this classification decides both the cache filename (shared across consumer editions) and
        whether Fido can serve the request at all.
    .PARAMETER Edition
        The Windows 11 edition (e.g. 'Home', 'Pro', 'Enterprise', 'Windows 11 Enterprise LTSC').
    .OUTPUTS
        System.String — 'consumer' or 'business'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string] $Edition)

    # Enterprise / IoT Enterprise / LTSC(B) editions are only in the business/volume ISO.
    if ($Edition -match '(?i)\b(Enterprise|LTSC|LTSB|IoT)\b') {
        return 'business'
    }
    return 'consumer'
}

function Get-FidoPin {
    <#
    .SYNOPSIS
        Read the pinned Fido tag and commit from the module manifest.
    .DESCRIPTION
        Private helper. RequiredToolingMinimums in WindowsIsoMaker.psd1 is the single source of
        truth for the Fido pin (Renovate keeps FidoTag/FidoCommit current). Returns both so the
        downloader can content-address by the 40-char commit while logs name the readable tag.
    .OUTPUTS
        PSCustomObject with Tag and Commit.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $manifestPath = Join-Path $script:ModuleRoot 'WindowsIsoMaker.psd1'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Module manifest not found at '$manifestPath'; cannot resolve the pinned Fido version."
    }
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    $mins = $manifest.PrivateData.PSData.RequiredToolingMinimums
    $commit = [string]$mins.FidoCommit
    $tag = [string]$mins.FidoTag
    if ($commit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Manifest FidoCommit ('$commit') is not a full 40-character commit SHA."
    }
    return [pscustomobject]@{ Tag = $tag; Commit = $commit }
}

function Get-FidoCachePath {
    <#
    .SYNOPSIS
        Return the on-disk cache path for a Fido.ps1 pinned to a given commit.
    .DESCRIPTION
        Private helper. The cache lives under <TEMP>\WindowsIsoMaker\fido and the file name embeds
        the commit, so different pins never collide and a cached copy is safe to reuse across runs.
    .PARAMETER Commit
        Full 40-character upstream commit SHA.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string] $Commit)

    $cacheDir = Join-Path ([System.IO.Path]::GetTempPath()) 'WindowsIsoMaker\fido'
    return Join-Path $cacheDir "Fido-$Commit.ps1"
}

function Invoke-FidoScriptDownload {
    <#
    .SYNOPSIS
        Download the pinned Fido.ps1 from raw.githubusercontent.com to the commit-addressed cache.
    .DESCRIPTION
        Private helper. Fetches https://raw.githubusercontent.com/pbatard/Fido/<commit>/Fido.ps1 to
        a sibling .part file and renames it on success, so an interrupted transfer never leaves a
        truncated script that a later run would trust. Pinning to the exact commit makes the fetch
        deterministic (content-addressed like a pinned GitHub Action); no separate hash is needed.
    .PARAMETER Commit
        Full 40-character upstream commit SHA to fetch.
    .PARAMETER Destination
        Cache file path to write (from Get-FidoCachePath).
    .OUTPUTS
        System.String (the Destination path).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string] $Commit,
        [Parameter(Mandatory = $true)][string] $Destination
    )

    $url = "https://raw.githubusercontent.com/pbatard/Fido/$Commit/Fido.ps1"
    $cacheDir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }

    Write-BuildLog -Level Information -Component 'Get-Windows11Iso' -Message "Downloading pinned Fido.ps1 (commit $Commit) from '$url'."
    $tempFile = "$Destination.part"
    if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force }

    $previousProgress = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $tempFile -UseBasicParsing -ErrorAction Stop
    }
    finally {
        $ProgressPreference = $previousProgress
    }

    if (-not (Test-Path -LiteralPath $tempFile) -or ((Get-Item -LiteralPath $tempFile).Length -le 0)) {
        throw "Fido download from '$url' produced no content."
    }

    Move-Item -LiteralPath $tempFile -Destination $Destination -Force
    return $Destination
}

function Resolve-FidoScriptPath {
    <#
    .SYNOPSIS
        Resolve the Fido.ps1 to run: a caller-supplied local copy, or the pinned cached download.
    .DESCRIPTION
        Private helper. A non-empty FidoPath is an offline/custom override and is used as-is (it
        must exist). Otherwise the commit pinned in the manifest is resolved: a cached copy at
        <TEMP>\WindowsIsoMaker\fido\Fido-<commit>.ps1 is reused when present, else downloaded once.
        This is the seam mocked in tests so no network call happens under unit tests.
    .PARAMETER FidoPath
        Optional local Fido.ps1 override. Empty => download the pinned commit.
    .OUTPUTS
        System.String (path to a usable Fido.ps1).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][string] $FidoPath = '')

    if (-not [string]::IsNullOrWhiteSpace($FidoPath)) {
        if (-not (Test-Path -LiteralPath $FidoPath)) {
            throw "Local FidoPath override '$FidoPath' does not exist."
        }
        Write-BuildLog -Level Information -Component 'Get-Windows11Iso' -Message "Using local Fido override '$FidoPath'."
        return (Resolve-Path -LiteralPath $FidoPath).Path
    }

    $pin = Get-FidoPin
    $cachePath = Get-FidoCachePath -Commit $pin.Commit
    if ((Test-Path -LiteralPath $cachePath) -and ((Get-Item -LiteralPath $cachePath).Length -gt 0)) {
        Write-BuildLog -Level Information -Component 'Get-Windows11Iso' -Message "Reusing cached Fido.ps1 (tag $($pin.Tag), commit $($pin.Commit))."
        return $cachePath
    }

    return (Invoke-FidoScriptDownload -Commit $pin.Commit -Destination $cachePath)
}

function Invoke-FidoUrlResolver {
    <#
    .SYNOPSIS
        Invoke the pinned Fido.ps1 as a separate process to resolve a download URL, with retries.
    .DESCRIPTION
        Private helper and the single GPLv3 boundary: Fido is executed as an independent
        external script in a child pwsh process (never dot-sourced/embedded). Returns the
        resolved URL string (last non-empty output line).

        Microsoft's download endpoint is fronted by an anti-bot system ("Sentinel") that
        intermittently rejects otherwise-valid requests based on client IP/reputation. A
        single rejection is usually transient, so this resolver retries a few times with a
        back-off before giving up — mirroring the proven headless approach from the earlier
        windows-iso-debloater workflow. Retries also cover Fido's own transient network hiccups.
    .PARAMETER FidoPath
        Path to Fido.ps1.
    .PARAMETER Arguments
        Fido arguments as an array.
    .PARAMETER MaxAttempts
        Maximum number of Fido invocations before giving up (default 3).
    .PARAMETER RetryDelaySeconds
        Seconds to wait between attempts (default 15).
    .OUTPUTS
        System.String (the resolved URL), or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string] $FidoPath,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter()][int] $MaxAttempts = 3,
        [Parameter()][int] $RetryDelaySeconds = 15
    )

    if (-not (Test-Path -LiteralPath $FidoPath)) {
        throw "Fido script not found at '$FidoPath'."
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result = Invoke-FidoProcess -FidoPath $FidoPath -Arguments $Arguments
        if ($result.Url) {
            return $result.Url
        }

        # Distinguish Microsoft's anti-bot rejection from a genuinely unavailable combination so
        # logs are actionable; both are retried in case the rejection was a transient IP throttle.
        $reason = if ($result.Output -match 'Sentinel marked this request as rejected') {
            "Microsoft's anti-bot check (Sentinel) rejected the request"
        }
        else {
            'Fido returned no download URL'
        }

        if ($attempt -lt $MaxAttempts) {
            Write-BuildLog -Level Warning -Component 'Get-Windows11Iso' `
                -Message "Fido attempt $attempt/$MaxAttempts failed ($reason); retrying in ${RetryDelaySeconds}s."
            if ($RetryDelaySeconds -gt 0) { Start-Sleep -Seconds $RetryDelaySeconds }
        }
        else {
            Write-BuildLog -Level Warning -Component 'Get-Windows11Iso' `
                -Message "Fido attempt $attempt/$MaxAttempts failed ($reason); no attempts remaining."
        }
    }

    return $null
}

function Invoke-FidoProcess {
    <#
    .SYNOPSIS
        Run the pinned Fido.ps1 once in a child process and extract any resolved URL.
    .DESCRIPTION
        Private helper (mockable seam for the retry loop in Invoke-FidoUrlResolver). Executes
        Fido as a separate program (arm's-length GPLv3 invocation) and returns both the parsed
        URL (if any) and the raw combined output so the caller can classify failures.
    .PARAMETER FidoPath
        Path to Fido.ps1.
    .PARAMETER Arguments
        Fido arguments as an array.
    .OUTPUTS
        PSCustomObject with Url (string or $null) and Output (string).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string] $FidoPath,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    $pwshExe = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path
    if (-not $pwshExe) { $pwshExe = 'pwsh' }

    # Run Fido as a separate program (arm's-length invocation; GPLv3 boundary).
    $output = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $FidoPath @Arguments 2>&1
    $lines = @($output | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ })
    $url = $lines | Where-Object { $_ -match '^https?://' } | Select-Object -Last 1

    return [pscustomobject]@{
        Url    = $url
        Output = ($lines -join "`n")
    }
}

function Assert-IsoHash {
    <#
    .SYNOPSIS
        Compute an ISO's SHA-256 and, when a known-good value is supplied, verify against it.
    .DESCRIPTION
        Private helper. Always returns the computed SHA-256 (integrity recording, FR-020). When
        ExpectedSha256 is provided, a mismatch throws so a corrupt or wrong ISO never reaches
        servicing (Principle VII). Comparison is case-insensitive.
    .PARAMETER Path
        Path to the ISO file.
    .PARAMETER ExpectedSha256
        Optional known-good SHA-256 to verify against.
    .OUTPUTS
        System.String (the computed SHA-256 hash).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter()][string] $ExpectedSha256
    )

    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and ($hash -ne $ExpectedSha256.Trim())) {
        throw "ISO hash mismatch for '$Path': expected '$($ExpectedSha256.Trim())' but computed '$hash'. Delete the file or pass -Force to re-download."
    }
    return $hash
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
    # Download to a sibling .part file and rename on success so an interrupted transfer never
    # leaves a truncated ISO at the final path (which the cache-reuse check would trust).
    $tempFile = "$Destination.part"
    if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force }

    $previousProgress = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $tempFile -UseBasicParsing -ErrorAction Stop
    }
    finally {
        $ProgressPreference = $previousProgress
    }

    if (-not (Test-Path -LiteralPath $tempFile)) {
        throw "Download completed but the file is missing: '$tempFile'."
    }

    Move-Item -LiteralPath $tempFile -Destination $Destination -Force
    if (-not (Test-Path -LiteralPath $Destination)) {
        throw "Download completed but the file is missing: '$Destination'."
    }
}
