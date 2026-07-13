function New-AutounattendXml {
    <#
    .SYNOPSIS
        Render an Autounattend.xml from the build configuration, per architecture (FR-027).
    .DESCRIPTION
        Renders an Autounattend.xml from templates/autounattend/autounattend.xml.template plus
        the resolved Autounattend sub-config. The correct processorArchitecture (amd64 vs
        arm64) is written into every unattend component. Applies the sub-config: skip OOBE,
        bypass the Microsoft-account requirement + create a local account (default on,
        toggleable), locale / keyboard / time zone, disk layout, and any FirstLogonCommands.

        Rendering is deterministic/idempotent — the same config yields byte-identical output.
        No password or secret is ever written to the file or logs (Principle VII). The file is
        placed at the ISO root by New-BootableIso; it complements (does not replace) DISM
        offline servicing.
    .PARAMETER Config
        The resolved BuildConfiguration (its Autounattend sub-config drives rendering).
    .PARAMETER Architecture
        Target architecture ('amd64' | 'arm64'). Overrides Config.Architecture when supplied.
    .PARAMETER OutputPath
        Path to write the generated Autounattend.xml.
    .PARAMETER TemplatePath
        Directory containing autounattend.xml.template. Defaults to templates/autounattend/.
    .EXAMPLE
        New-AutounattendXml -Config $cfg -Architecture amd64 -OutputPath ./out/Autounattend.xml
    .OUTPUTS
        System.String — the path to the generated Autounattend.xml.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Config,

        [Parameter()]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath,

        [Parameter()]
        [string] $TemplatePath
    )

    if (-not $TemplatePath) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $script:ModuleRoot)
        $TemplatePath = Join-Path -Path $repoRoot -ChildPath 'templates/autounattend'
    }
    $templateFile = Join-Path -Path $TemplatePath -ChildPath 'autounattend.xml.template'
    if (-not (Test-Path -LiteralPath $templateFile)) {
        throw "Autounattend template not found: '$templateFile'."
    }

    if (-not $PSBoundParameters.ContainsKey('Architecture')) {
        $Architecture = [string]$Config.Architecture
    }

    # Resolve the Autounattend sub-config with safe defaults.
    $au = $Config.Autounattend
    $get = {
        param($key, $default)
        if ($au -is [hashtable] -and $au.ContainsKey($key)) { return $au[$key] }
        if ($au -and ($au.PSObject.Properties.Name -contains $key)) { return $au.$key }
        return $default
    }

    $locale = [string](& $get 'Locale' $Config.Language)
    # UserLocale = the "region format" (dates/times/numbers) shown under Control Panel > Clock and
    # Region. It is independent of the UI language; default it to the UI locale for back-compat.
    $userLocale = [string](& $get 'UserLocale' $locale)
    $keyboard = [string](& $get 'KeyboardLayout' '0409:00000409')
    $timezone = [string](& $get 'TimeZone' 'UTC')
    $diskId = [int](& $get 'DiskId' 0)
    # The install.wim image name to deploy. Derived from Edition ("Pro" -> "Windows 11 Pro") so
    # Setup's ImageInstall/InstallFrom skips the interactive edition picker; overridable via
    # Autounattend.ImageName for non-standard media (e.g. an Enterprise volume-licence WIM).
    $editionRaw = [string]$Config.Edition
    $defaultImageName = if ($editionRaw -match '(?i)^\s*windows\s') { $editionRaw.Trim() } else { "Windows 11 $($editionRaw.Trim())" }
    $editionImageName = [string](& $get 'ImageName' $defaultImageName)
    $skipOobe = [bool](& $get 'SkipOobe' $true)
    $bypassMsAccount = [bool](& $get 'BypassMsAccount' $true)
    $createLocalAccount = [bool](& $get 'CreateLocalAccount' $true)
    $localAccountName = [string](& $get 'LocalAccountName' 'Admin')
    $firstLogonCommands = @(& $get 'FirstLogonCommands' @())

    # --- Account provisioning mode (FR-027). ---
    #   'local' (default) -> create a local admin account and bypass the online-account screens.
    #                        Fully hands-off; ideal for standalone/gaming PCs.
    #   'entra' ('entraid'/'azuread') -> DON'T create a local account and DON'T hide the online-
    #                        account screens: let OOBE present the "Set up for work or school"
    #                        flow so the user signs in with their Entra ID (Azure AD join), which
    #                        triggers Intune MDM auto-enrollment where configured. Note: a genuine
    #                        hands-free Entra join needs credentials and is only fully automated via
    #                        Windows Autopilot or a provisioning package - this image simply prepares
    #                        OOBE to present the Entra sign-in instead of forcing a local account.
    $accountModeRaw = [string](& $get 'AccountMode' 'local')
    $accountMode = $accountModeRaw.Trim().ToLowerInvariant()
    if ($accountMode -notin @('local', 'entra', 'entraid', 'azuread')) {
        Write-BuildLog -Level Warning -Component 'New-AutounattendXml' -Message "Unknown AccountMode '$accountModeRaw'; defaulting to 'local'. Valid values: local, entra."
        $accountMode = 'local'
    }
    $isEntraJoin = $accountMode -in @('entra', 'entraid', 'azuread')
    if ($isEntraJoin) {
        # Entra join is interactive at OOBE: no local account, and the online-account screens must
        # be visible so the user can sign in with their work/school (Entra) identity.
        $createLocalAccount = $false
        $bypassMsAccount = $false
    }

    # --- ProductKey fragment (edition selector, NOT an activation key). ---
    # Windows 11 24H2's rearchitected Setup ("windlp") validates a product key online during
    # windowsPE. The public generic (KMS client setup) keys FAIL that new validation and hard-stop
    # with "Setup has failed to validate the product key" - even with WillShowUI=Never and a
    # network connection - so they are no longer emitted by default. Windows 11 *Home* installs
    # fully unattended WITHOUT any key, so the default (omit) works for Home. Non-Home editions
    # (Pro, Enterprise, ...) require a genuine key: supply it via Autounattend.ProductKey (a real
    # key), or via the -ProductKey parameter of scripts/Invoke-QuickBootTest.ps1.
    #   ProductKey not set / '' / whitespace / 'none' -> omit entirely (Home installs hands-off;
    #                                                    non-Home Setup will stop for a key)
    #   ProductKey = 'generic' | 'auto'               -> generic key for the edition (NOTE: fails
    #                                                    24H2 validation; kept for older media only)
    #   ProductKey = 'XXXXX-...'                       -> use that explicit key verbatim
    $productKeyRaw = & $get 'ProductKey' $null
    $productKey = ''
    if ($null -eq $productKeyRaw -or [string]::IsNullOrWhiteSpace([string]$productKeyRaw) -or
        [string]$productKeyRaw -match '(?i)^\s*none\s*$') {
        $productKey = ''
    }
    elseif ([string]$productKeyRaw -match '(?i)^\s*(generic|auto)\s*$') {
        $productKey = Get-GenericSetupProductKey -Edition ([string]$Config.Edition)
    }
    else {
        $productKey = [string]$productKeyRaw.ToString().Trim()
    }

    # A non-Home edition with no key will stop at Setup's product-key page. Surface that early so a
    # direct caller (CI, Invoke-IsoBuild) is not surprised by an interactive stall in the boot test.
    if ([string]::IsNullOrWhiteSpace($productKey) -and ([string]$Config.Edition) -notmatch '(?i)home') {
        Write-BuildLog -Level Warning -Component 'New-AutounattendXml' -Message "Edition '$($Config.Edition)' has no product key, so Windows 11 24H2 Setup will stop at the product-key page. Set Autounattend.ProductKey to a genuine key (only Home installs hands-off without one)."
    }

    $productKeyFragment = ''
    if (-not [string]::IsNullOrWhiteSpace($productKey)) {
        $safeKey = [System.Security.SecurityElement]::Escape($productKey)
        $productKeyFragment = @"
        <ProductKey>
          <Key>$safeKey</Key>
          <WillShowUI>Never</WillShowUI>
        </ProductKey>
"@
    }

    # --- OOBE fragment (skip screens). ---
    $oobeFragment = ''
    if ($skipOobe) {
        $hideOnline = if ($bypassMsAccount) { 'true' } else { 'false' }
        # For an Entra join we must let the user OOBE run so the "work or school" sign-in appears,
        # and allow wireless setup so a Wi-Fi-only device can reach Entra/Intune. A local install
        # keeps the fully hands-off skip.
        $hideWireless = if ($isEntraJoin) { 'false' } else { 'true' }
        $skipUserOobe = if ($isEntraJoin) { 'false' } else { 'true' }
        $skipMachineOobe = if ($isEntraJoin) { 'false' } else { 'true' }
        $oobeFragment = @"
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>$hideOnline</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>$hideWireless</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>$skipMachineOobe</SkipMachineOOBE>
        <SkipUserOOBE>$skipUserOobe</SkipUserOOBE>
      </OOBE>
"@
    }

    # --- Local-account fragment (no password/secret is ever written). ---
    $userAccountsFragment = ''
    if ($createLocalAccount) {
        $safeName = [System.Security.SecurityElement]::Escape($localAccountName)
        $userAccountsFragment = @"
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <Name>$safeName</Name>
            <Group>Administrators</Group>
            <DisplayName>$safeName</DisplayName>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
"@
    }

    # --- FirstLogonCommands fragment. ---
    $firstLogonFragment = ''
    if ($firstLogonCommands.Count -gt 0) {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('      <FirstLogonCommands>')
        $order = 1
        foreach ($cmd in $firstLogonCommands) {
            $safeCmd = [System.Security.SecurityElement]::Escape([string]$cmd)
            [void]$sb.AppendLine('        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">')
            [void]$sb.AppendLine("          <Order>$order</Order>")
            [void]$sb.AppendLine("          <CommandLine>$safeCmd</CommandLine>")
            [void]$sb.AppendLine('        </SynchronousCommand>')
            $order++
        }
        [void]$sb.Append('      </FirstLogonCommands>')
        $firstLogonFragment = $sb.ToString()
    }

    # --- Token substitution. ---
    $xml = Get-Content -LiteralPath $templateFile -Raw
    $replacements = @{
        '{{PROCESSOR_ARCHITECTURE}}' = $Architecture
        '{{LOCALE}}'                 = [System.Security.SecurityElement]::Escape($locale)
        '{{USER_LOCALE}}'            = [System.Security.SecurityElement]::Escape($userLocale)
        '{{KEYBOARD}}'               = [System.Security.SecurityElement]::Escape($keyboard)
        '{{TIMEZONE}}'               = [System.Security.SecurityElement]::Escape($timezone)
        '{{DISK_ID}}'                = [string]$diskId
        '{{EDITION_IMAGE_NAME}}'     = [System.Security.SecurityElement]::Escape($editionImageName)
        '{{PRODUCTKEY_FRAGMENT}}'    = $productKeyFragment.TrimEnd("`r", "`n")
        '{{OOBE_FRAGMENT}}'          = $oobeFragment.TrimEnd("`r", "`n")
        '{{USERACCOUNTS_FRAGMENT}}'  = $userAccountsFragment.TrimEnd("`r", "`n")
        '{{FIRSTLOGON_FRAGMENT}}'    = $firstLogonFragment.TrimEnd("`r", "`n")
    }
    foreach ($token in $replacements.Keys) {
        $xml = $xml.Replace($token, $replacements[$token])
    }

    # Collapse any blank lines left by empty fragments for a tidy, deterministic file.
    $xml = ($xml -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 -or $true }) -join [Environment]::NewLine
    $xml = [regex]::Replace($xml, '(\r?\n){3,}', [Environment]::NewLine + [Environment]::NewLine)

    $outputDir = Split-Path -Parent $OutputPath
    if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    if ($PSCmdlet.ShouldProcess($OutputPath, "Write $Architecture Autounattend.xml")) {
        Set-Content -LiteralPath $OutputPath -Value $xml -Encoding UTF8 -NoNewline
        Write-BuildLog -Level Information -Component 'New-AutounattendXml' -Message "Wrote $Architecture Autounattend.xml -> '$OutputPath'."
    }

    return $OutputPath
}
