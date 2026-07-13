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

.PARAMETER Isolated
    Make this run safe to execute in parallel with other Invoke-QuickBootTest runs against the same
    working directory. Each isolated run gets its own uniquely-named Autounattend.xml and output ISO
    (a short run tag is appended) so concurrent runs never clobber one another's answer file or ISO.
    ISO authoring is always serialized across processes with a named mutex (New-BootableIso stages
    the answer file inside the shared media\ tree before imaging it), so the fast rebuild step is
    atomic while the slow VM boot tests overlap. Pass -Isolated to EVERY parallel window.

.PARAMETER Edition
    Windows 11 edition to author into the answer file for this run (overrides the config's
    Edition). Handy for testing the no-key path with -Edition Home before doing a keyed Pro build.

.PARAMETER ProductKey
    Product key to bake into the answer file (overrides config Autounattend.ProductKey). REQUIRED
    for any non-Home edition: Windows 11 24H2 Setup only installs hands-off without a key on Home;
    Pro/Enterprise/etc. need a genuine key (the generic KMS key fails 24H2's new validation).

.PARAMETER UseGenericProductKey
    Bake the edition's generic/default retail key so Setup skips the OOBE product-key page without
    activating - use it for a fully hands-off Home run (no key prompt). An explicit -ProductKey wins
    over this switch; non-Home generic keys may still fail 24H2 validation.

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
    [switch] $Isolated,
    [string] $Edition,
    [string] $ProductKey,
    [switch] $UseGenericProductKey,
    [ValidateSet('minimal', 'default', 'aggressive', 'gaming', 'opinionated')]
    [string[]] $Profile
)

$ErrorActionPreference = 'Stop'

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

# Windows 11 24H2 only installs hands-off WITHOUT a product key on Home. Non-Home editions need a
# genuine key (the generic KMS key fails 24H2's new online validation), so require one up front.
$resolvedEdition = [string]$cfg.Edition
$resolvedKey = [string]$cfg.Autounattend['ProductKey']
$isHomeEdition = $resolvedEdition -match '(?i)home'
$keyIsUsable = -not [string]::IsNullOrWhiteSpace($resolvedKey) -and $resolvedKey -notmatch '(?i)^\s*(none|generic|auto)\s*$'
if (-not $SkipRebuild -and -not $isHomeEdition -and -not $keyIsUsable) {
    throw "Edition '$resolvedEdition' needs a genuine product key for an unattended 24H2 install (the generic key fails 24H2's new validation for non-Home editions). Re-run with -ProductKey '<your-key>', or test the fully hands-off path with -Edition Home -UseGenericProductKey."
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

# --- Readiness preflight (clear, actionable message before we try to spin a VM). ---
# Get-HyperVReadiness is an internal helper; invoke it inside the module's scope.
$module = Get-Module WindowsIsoMaker | Select-Object -First 1
$readiness = & $module { Get-HyperVReadiness }
if (-not $readiness.Ready) {
    Write-Warning "[QuickBootTest] Hyper-V is not ready for a boot test: $($readiness.Reason)"
    Write-Warning "[QuickBootTest] The ISO was still (re)built at '$IsoPath'; fix the above and re-run, or pass -SkipRebuild."
    return
}

$keep = -not $NoKeep
$diagnostics = Join-Path $WorkingDirectory 'boottest-diagnostics'
Write-Host "[QuickBootTest] Starting VM boot test (KeepBootTestVm=$keep) on '$IsoPath'." -ForegroundColor Green
Write-Host "[QuickBootTest] Windows Setup logs (if any) will be harvested to '$diagnostics'." -ForegroundColor Cyan
$result = Test-ImageIntegrity -IsoPath $IsoPath -Architecture $Architecture -BootTest -KeepBootTestVm:$keep -ConnectVm:$ConnectVm -DiagnosticsPath $diagnostics -Verbose

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
        Write-Host "[QuickBootTest] That points to a windowsPE-phase failure (answer-file/product-key rejection) whose logs live on the WinPE RAM disk: Shift+F10 -> X:\Windows\Panther\setupact.log." -ForegroundColor Yellow
    }
}
return $result
