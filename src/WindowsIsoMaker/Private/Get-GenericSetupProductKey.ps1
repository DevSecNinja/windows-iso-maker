function Get-GenericSetupProductKey {
    <#
    .SYNOPSIS
        Return the generic (default retail) setup product key for a Windows 11 edition.
    .DESCRIPTION
        These are the public generic "default" keys Microsoft ships to select a Windows 11 edition
        without activating it (activation still happens later via the user's own key, digital
        licence, or KMS). This tool applies the key in the *specialize* pass, never in windowsPE:
        Windows 11 24H2's rearchitected Setup ("windlp") performs strict key validation during the
        windowsPE phase on multi-edition media and hard-stops generic keys with "Setup has failed to
        validate the product key", so the edition is selected by the ImageInstall /IMAGE/NAME
        metadata instead and the key is applied afterwards in specialize (where it is not revalidated
        that way). See https://learn.microsoft.com/windows-server/get-started/kms-client-activation-keys.
    .PARAMETER Edition
        The Windows 11 edition name (e.g. 'Pro', 'Pro N', 'Home', 'Education').
    .OUTPUTS
        System.String — the generic setup key, or '' when the edition is unknown.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Edition
    )

    # Public generic / default retail setup keys (edition selectors applied in the specialize pass;
    # they do NOT activate). Keyed by a normalized edition name.
    $keys = @{
        'home'                    = 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7'
        'homen'                   = '4CPRK-NM3K3-X6XXQ-RXX86-WXCHW'
        'homesinglelanguage'      = 'BT79Q-G7N6G-PGBYW-4YWX6-6F4BT'
        'pro'                     = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
        'pron'                    = '2B87N-8KFHP-DKV6R-Y2C8J-PKCKT'
        'proforworkstations'      = 'DXG7C-N36C4-C4HTG-X4T3X-2YV77'
        'pronforworkstations'     = 'WYPNQ-8C467-V2W6J-TX4WX-WT2RQ'
        'proeducation'            = '8PTT6-RNW4C-6V7J2-C2D3X-MHBPB'
        'proeducationn'           = 'GJTYN-HDMQY-FRR76-HVGC7-QPF8P'
        'education'               = 'NW6C2-QMPVW-D7KKK-3GKT6-VCFB2'
        'educationn'              = '2WH4N-8QGP4-HBJTJ-XDR9G-VYT6W'
        'enterprise'              = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'
        'enterprisen'             = 'DPH2V-TTNVB-4X9Q3-TJR4H-KHJW4'
    }

    # Normalize: drop a leading "Windows 11" prefix and any non-alphanumeric characters
    # so 'Pro N', 'Pro-N', 'ProN', 'Windows 11 Pro N' all resolve to the same entry.
    $normalized = ($Edition -replace '(?i)windows\s*11', '') -replace '[^a-zA-Z0-9]', ''
    $normalized = $normalized.ToLowerInvariant()

    if ($keys.ContainsKey($normalized)) {
        return $keys[$normalized]
    }
    return ''
}
