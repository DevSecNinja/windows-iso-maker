#Requires -Version 5.1
<#
.SYNOPSIS
    Rebuild ONLY the ISO from already-serviced media and run the Hyper-V boot test — with all
    paths auto-discovered.

.DESCRIPTION
    A local convenience wrapper for the inner loop of "I already have serviced media in TEMP,
    just re-author the Autounattend.xml + ISO and boot it". It:

      1. Imports the WindowsIsoMaker module (from the manifest, so all public functions load).
      2. Auto-discovers the working directory (config.WorkingDirectory or <TEMP>\WindowsIsoMaker),
         the serviced media/ folder, and the output ISO path.
      3. Regenerates Autounattend.xml from config/build.config.psd1 (so the latest region/time-zone,
         product-key and other settings are baked in).
      4. Rebuilds the bootable ISO from the existing media (no re-mount / no re-servicing — fast).
      5. Runs Test-ImageIntegrity with the opt-in VM boot test, keeping the VM up for manual poking
         until you press Enter (unless -NoKeep is passed).

    It never downloads or re-services an image; it only re-authors the ISO and boots it. Run it in
    an ELEVATED PowerShell session (the boot test needs Hyper-V privileges).

.PARAMETER ConfigPath
    Build configuration file. Defaults to config/build.config.psd1 in the repo.

.PARAMETER WorkingDirectory
    Directory that holds the serviced media/ folder. Defaults to the config's WorkingDirectory,
    or <TEMP>\WindowsIsoMaker when that is blank.

.PARAMETER Architecture
    'amd64' | 'arm64'. Defaults to the config's Architecture.

.PARAMETER IsoPath
    Output ISO path. Defaults to <WorkingDirectory>\Windows11-<Edition>-<Arch>-bootcheck.iso.

.PARAMETER SkipRebuild
    Skip re-authoring the Autounattend.xml + ISO and boot-test the existing -IsoPath as-is.

.PARAMETER NoKeep
    Do not keep the VM / pause for manual inspection (runs the boot test unattended).

.PARAMETER ConnectVm
    Open the interactive VM console (vmconnect) as soon as the boot-test VM starts, so you can
    watch Setup and press Shift+F10 to capture logs on a stall.

.PARAMETER ConnectNetwork
    Give the boot-test VM a network connection (External switch preferred). Off by default on
    Hyper-V so the VM boots fully offline and ConX (the redesigned Setup on 24H2+ media) does not
    depend on a flaky WinPE-phase DNS/NAT proxy. On VMware the boot test is NETWORKED (NAT) by
    default; pass -ConnectNetwork:$false to force it offline there.

.PARAMETER Hypervisor
    Which hypervisor runs the boot-test VM: 'HyperV' (default, or the config's Hypervisor) or
    'VMware' (VMware Workstation). VMware's NAT gives WinPE real DNS for a 24H2+ ConX online
    product-key/edition check; VMware Workstation Pro must be downloaded manually (Broadcom
    login-gated, not on winget), and when it's missing this prints the download link + guided setup
    steps and stops.

.PARAMETER Isolated
    Make this run safe to execute in parallel with other Invoke-QuickBootTest runs against the same
    working directory. Each isolated run gets its own uniquely-named Autounattend.xml and output ISO
    (a short run tag is appended) so concurrent runs never clobber one another's answer file or ISO.
    ISO authoring is always serialized across processes with a named mutex (New-BootableIso stages
    the answer file inside the shared media\ tree before imaging it), so the fast rebuild step is
    atomic while the slow VM boot tests overlap. Pass -Isolated to EVERY parallel window.

.PARAMETER Edition
    Windows 11 edition to author into the answer file for this run (overrides the config's
    Edition). On multi-edition media a product key is what keeps the install hands-off.

.PARAMETER ProductKey
    Product key to bake into the answer file (overrides config Autounattend.ProductKey). Applied in
    the windowsPE UserData pass so multi-edition 24H2 media does not stop at the product-key page.
    Without a key Setup may prompt on multi-edition media; a genuine key activates when valid.

.PARAMETER UseGenericProductKey
    Bake the edition's generic/default retail key (applied in windowsPE UserData, non-activating) -
    use it for a fully hands-off run. Mutually exclusive with -ProductKey.

.PARAMETER Profile
    Debloat/customization profile(s) to apply for this run, overriding the config's Profile. Accepts
    a list to combine baselines (e.g. -Profile gaming,opinionated). Because a quick boot test reuses
    the already-serviced media\ folder, this does NOT re-run debloat; it re-derives the answer file,
    so profile-driven Autounattend settings (e.g. the opinionated United States-International
    keyboard) are reflected in the boot test.

.EXAMPLE
    ./scripts/Invoke-QuickBootTest.ps1
    Auto-discovers everything, rebuilds the ISO, and boot-tests it, pausing for manual inspection.

.EXAMPLE
    ./scripts/Invoke-QuickBootTest.ps1 -SkipRebuild
    Just boot-test the ISO that is already on disk.

.EXAMPLE
    # In two separate elevated windows, boot-test two editions at once against the same media:
    ./scripts/Invoke-QuickBootTest.ps1 -Edition Home -UseGenericProductKey -Isolated
    ./scripts/Invoke-QuickBootTest.ps1 -Edition Pro  -ProductKey '<key>'    -Isolated
#>
[CmdletBinding(SupportsShouldProcess = $true)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Interactive local helper: coloured status lines are written to the host on purpose.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', 'Profile',
    Justification = "'Profile' is the documented, user-facing configuration concept (minimal/default/aggressive). The parameter is locally scoped and never writes the global profile path.")]
param(
    [string] $ConfigPath,
    [string] $WorkingDirectory,
    [ValidateSet('amd64', 'arm64')]
    [string] $Architecture,
    [string] $IsoPath,
    [switch] $SkipRebuild,
    [switch] $NoKeep,
    [switch] $ConnectVm,
    [switch] $ConnectNetwork,
    [ValidateSet('HyperV', 'VMware')]
    [string] $Hypervisor,
    [switch] $Isolated,
    [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            @('Home', 'HomeN', 'Pro', 'ProN', 'ProForWorkstations', 'ProEducation', 'Education',
                'EducationN', 'Enterprise', 'EnterpriseN', 'EnterpriseLTSC2024', 'IoTEnterpriseLTSC2024') |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
        })]
    [string] $Edition,
    [string] $ProductKey,
    [switch] $UseGenericProductKey,
    [ValidateSet('minimal', 'default', 'aggressive', 'gaming', 'opinionated')]
    [string[]] $Profile
)

$ErrorActionPreference = 'Stop'

# Fail fast on mutually exclusive product-key inputs: -ProductKey bakes a specific key,
# -UseGenericProductKey bakes the edition's generic key; supplying both is contradictory.
if ($UseGenericProductKey.IsPresent -and $PSBoundParameters.ContainsKey('ProductKey')) {
    throw "-ProductKey and -UseGenericProductKey are mutually exclusive. Pass -ProductKey '<key>' to bake a specific key, or -UseGenericProductKey for the edition's generic key - not both."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path $repoRoot 'src/WindowsIsoMaker/WindowsIsoMaker.psd1'
Write-Host "[QuickBootTest] Importing module from '$manifest'." -ForegroundColor Cyan
Import-Module $manifest -Force

if (-not $ConfigPath) { $ConfigPath = Join-Path $repoRoot 'config/build.config.psd1' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config file not found: '$ConfigPath'." }
$getConfigParams = @{ Path = $ConfigPath }
if ($PSBoundParameters.ContainsKey('Profile') -and $Profile) {
    $getConfigParams['Profile'] = $Profile
    Write-Host "[QuickBootTest] Profile override: '$($Profile -join ', ')'." -ForegroundColor Cyan
}
$cfg = Get-BuildConfiguration @getConfigParams

if (-not $Architecture) { $Architecture = [string]$cfg.Architecture }
if (-not $Architecture) { $Architecture = 'amd64' }

# --- Apply per-run edition / product-key overrides onto the config. ---
if ($PSBoundParameters.ContainsKey('Edition') -and $Edition) {
    $cfg.Edition = $Edition
    Write-Host "[QuickBootTest] Edition override: '$Edition'." -ForegroundColor Cyan
}
if ($PSBoundParameters.ContainsKey('ProductKey')) {
    if ($cfg.Autounattend -isnot [hashtable]) { throw 'Config Autounattend section is not a hashtable; cannot apply -ProductKey.' }
    $cfg.Autounattend['ProductKey'] = $ProductKey
}
if ($UseGenericProductKey -and -not $PSBoundParameters.ContainsKey('ProductKey')) {
    if ($cfg.Autounattend -isnot [hashtable]) { throw 'Config Autounattend section is not a hashtable; cannot apply -UseGenericProductKey.' }
    $cfg.Autounattend['ProductKey'] = 'generic'
    Write-Host "[QuickBootTest] Using the edition's generic product key (skips the OOBE product-key page)." -ForegroundColor Cyan
}

# The edition is tagged by the image metadata but on multi-edition media a key applied in windowsPE
# UserData is what keeps Setup from stopping at the product-key page. Without a usable key the run
# may prompt (and the OS stays unlicensed) - note that, but don't block the run.
$resolvedEdition = [string]$cfg.Edition
$resolvedKey = [string]$cfg.Autounattend['ProductKey']
$keyIsUsable = -not [string]::IsNullOrWhiteSpace($resolvedKey) -and $resolvedKey -notmatch '(?i)^\s*(none|generic|auto)\s*$'
if (-not $SkipRebuild -and -not $keyIsUsable) {
    Write-Host "[QuickBootTest] No genuine product key set for edition '$resolvedEdition'; it installs hands-off from the image metadata but stays unlicensed until a key is entered. Pass -ProductKey '<your-key>' to activate, or -UseGenericProductKey for a non-activating generic key." -ForegroundColor Yellow
}

# --- Resolve the working directory that holds the serviced media. ---
if (-not $WorkingDirectory) {
    $cfgWork = [string]$cfg.WorkingDirectory
    $WorkingDirectory = if ([string]::IsNullOrWhiteSpace($cfgWork)) {
        Join-Path ([System.IO.Path]::GetTempPath()) 'WindowsIsoMaker'
    }
    else { $cfgWork }
}
Write-Host "[QuickBootTest] Working directory: '$WorkingDirectory'." -ForegroundColor Cyan

$mediaRoot = Join-Path $WorkingDirectory 'media'
# -Isolated: give this run its own answer file + ISO so parallel runs don't clobber each other.
$runTag = if ($Isolated) { [guid]::NewGuid().ToString('N').Substring(0, 8) } else { '' }
$autounattend = if ($runTag) {
    Join-Path $WorkingDirectory "Autounattend-$runTag.xml"
}
else {
    Join-Path $WorkingDirectory 'Autounattend.xml'
}
if (-not $IsoPath) {
    $edition = ([string]$cfg.Edition) -replace '[^A-Za-z0-9]', ''
    if (-not $edition) { $edition = 'Pro' }
    $suffix = if ($runTag) { "-$runTag" } else { '' }
    $IsoPath = Join-Path $WorkingDirectory ("Windows11-$edition-$Architecture-bootcheck$suffix.iso")
}
if ($Isolated) { Write-Host "[QuickBootTest] Isolated run tag: '$runTag'." -ForegroundColor Cyan }

if (-not $SkipRebuild) {
    if (-not (Test-Path -LiteralPath $mediaRoot)) {
        throw "Serviced media not found at '$mediaRoot'. Run a full build first (build.ps1) so the media/ folder exists, or pass -SkipRebuild to boot an existing ISO."
    }

    Write-Host "[QuickBootTest] Regenerating Autounattend.xml -> '$autounattend'." -ForegroundColor Cyan
    New-AutounattendXml -Config $cfg -Architecture $Architecture -OutputPath $autounattend | Out-Null

    # New-BootableIso copies the answer file INTO the shared media\ tree before oscdimg images it,
    # so two concurrent authoring passes would race on media\Autounattend.xml (and SHA256SUMS). A
    # system-wide named mutex keyed on the media path makes the copy+image atomic; the far slower
    # VM boot tests still overlap freely.
    $mediaKey = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA1]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($mediaRoot.ToLowerInvariant()))
    ).Replace('-', '').Substring(0, 16)
    $mutex = [System.Threading.Mutex]::new($false, "Global\WindowsIsoMaker-media-$mediaKey")
    $haveLock = $false
    try {
        try { $haveLock = $mutex.WaitOne() }
        catch [System.Threading.AbandonedMutexException] { $haveLock = $true }
        Write-Host "[QuickBootTest] Rebuilding ISO (no re-servicing) -> '$IsoPath'." -ForegroundColor Cyan
        New-BootableIso -MediaRoot $mediaRoot -Architecture $Architecture -OutputIsoPath $IsoPath -AutounattendPath $autounattend | Out-Null
    }
    finally {
        if ($haveLock) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
elseif (-not (Test-Path -LiteralPath $IsoPath)) {
    throw "-SkipRebuild was set but the ISO '$IsoPath' does not exist."
}

# --- Resolve the hypervisor for the boot test (param wins, else config, else Hyper-V). ---
$bootHypervisor = if ($PSBoundParameters.ContainsKey('Hypervisor') -and $Hypervisor) {
    $Hypervisor
}
elseif ($cfg.PSObject.Properties.Match('Hypervisor').Count -and $cfg.Hypervisor) {
    [string]$cfg.Hypervisor
}
else { 'HyperV' }
Write-Host "[QuickBootTest] Hypervisor: '$bootHypervisor'." -ForegroundColor Cyan

# --- Readiness preflight (clear, actionable message before we try to spin a VM). ---
# The readiness helpers are internal; invoke them inside the module's scope. For VMware, offer the
# interactive winget install (+ manual-download guidance) when it is missing, then re-check.
$module = Get-Module WindowsIsoMaker | Select-Object -First 1
$readiness = & $module { param($h) if ($h -eq 'VMware') { Get-VMwareReadiness } else { Get-HyperVReadiness } } $bootHypervisor
if (-not $readiness.Ready -and $bootHypervisor -eq 'VMware') {
    Write-Warning "[QuickBootTest] $($readiness.Reason)"
    $installed = & $module { Install-VMwareWorkstation }
    if ($installed) {
        $readiness = & $module { Get-VMwareReadiness }
    }
}
if (-not $readiness.Ready) {
    Write-Warning "[QuickBootTest] $($bootHypervisor) is not ready for a boot test: $($readiness.Reason)"
    Write-Warning "[QuickBootTest] The ISO was still (re)built at '$IsoPath'; fix the above and re-run, or pass -SkipRebuild."
    return
}

$keep = -not $NoKeep
$diagnostics = Join-Path $WorkingDirectory 'boottest-diagnostics'
Write-Host "[QuickBootTest] Starting VM boot test (KeepBootTestVm=$keep, Hypervisor=$bootHypervisor) on '$IsoPath'." -ForegroundColor Green
Write-Host "[QuickBootTest] Windows Setup logs (if any) will be harvested to '$diagnostics'." -ForegroundColor Cyan
$bootTestParams = @{
    IsoPath         = $IsoPath
    Architecture    = $Architecture
    BootTest        = $true
    KeepBootTestVm  = $keep
    ConnectVm       = $ConnectVm
    Hypervisor      = $bootHypervisor
    DiagnosticsPath = $diagnostics
    Verbose         = $true
}
# Only forward ConnectNetwork when explicitly set, so each hypervisor keeps its own default
# (Hyper-V offline, VMware NAT) unless the caller overrides it.
if ($PSBoundParameters.ContainsKey('ConnectNetwork')) { $bootTestParams['ConnectNetwork'] = $ConnectNetwork }
$result = Test-ImageIntegrity @bootTestParams

$icon = if ($result.Passed) { 'PASS' } else { 'FAIL' }
$color = if ($result.Passed) { 'Green' } else { 'Red' }
Write-Host "[QuickBootTest] Result: $icon" -ForegroundColor $color
Write-Host "[QuickBootTest]   IsoPath        : $($result.IsoPath)"
Write-Host "[QuickBootTest]   Architecture   : $($result.Architecture)"
Write-Host "[QuickBootTest]   Passed         : $($result.Passed)"
$boot0 = if ($result.PSObject.Properties.Match('Boot').Count) { $result.Boot } else { $null }
if ($boot0 -and $boot0.PSObject.Properties.Match('InstallProgressed').Count) {
    Write-Host "[QuickBootTest]   InstallProgress: $($boot0.InstallProgressed)  (Method: $($boot0.Method))"
}
if ($result.PSObject.Properties.Match('DiagnosticsPath').Count -and $result.DiagnosticsPath) {
    Write-Host "[QuickBootTest]   DiagnosticsPath: $($result.DiagnosticsPath)" -ForegroundColor Yellow
}
$boot = if ($result.PSObject.Properties.Match('Boot').Count) { $result.Boot } else { $null }
if ($boot -and $boot.PSObject.Properties.Match('Diagnostics').Count -and $boot.Diagnostics) {
    $files = @($boot.Diagnostics.Files)
    if ($files.Count -gt 0) {
        Write-Host "[QuickBootTest] Harvested $($files.Count) Setup log file(s) to '$($boot.Diagnostics.Path)':" -ForegroundColor Yellow
        foreach ($f in $files) { Write-Host "[QuickBootTest]     $f" }
        if ($boot.Diagnostics.SetupErrorTail) {
            Write-Host "[QuickBootTest] --- setuperr.log (tail) ---" -ForegroundColor Yellow
            Write-Host $boot.Diagnostics.SetupErrorTail
        }
    }
    else {
        Write-Host "[QuickBootTest] No Setup logs were written to the VHDX (looked in '$($boot.Diagnostics.Path)')." -ForegroundColor Yellow
        Write-Host "[QuickBootTest] That points to a windowsPE-phase failure (answer-file/product-key rejection) whose logs live on the WinPE RAM disk (X:). Shift+F10 at the failing screen, then: 'robocopy X:\Windows\Logs C:\pe-logs /E' + 'copy X:\Windows\*.log C:\pe-logs\' (incl. ConX's X:\Windows\Logs\MoSetup\BlueBox.log) and re-run teardown to harvest them." -ForegroundColor Yellow
    }
}
return $result
