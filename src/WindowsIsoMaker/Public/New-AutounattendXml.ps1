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
    $skipOobe = [bool](& $get 'SkipOobe' $true)
    $bypassMsAccount = [bool](& $get 'BypassMsAccount' $true)
    $createLocalAccount = [bool](& $get 'CreateLocalAccount' $true)
    $localAccountName = [string](& $get 'LocalAccountName' 'Admin')
    $firstLogonCommands = @(& $get 'FirstLogonCommands' @())

    # --- OOBE fragment (skip screens). ---
    $oobeFragment = ''
    if ($skipOobe) {
        $hideOnline = if ($bypassMsAccount) { 'true' } else { 'false' }
        $oobeFragment = @"
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>$hideOnline</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
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
