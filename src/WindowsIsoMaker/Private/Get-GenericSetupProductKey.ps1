function Get-GenericSetupProductKey {
    <#
    .SYNOPSIS
        Return the generic (default retail) setup product key for a Windows 11 edition.
    .DESCRIPTION
        Windows Setup uses the <ProductKey> in the windowsPE pass only to decide WHICH edition
        to install and to skip the interactive product-key page. These are the public generic
        "default" keys Microsoft ships for exactly that purpose — they select an edition but do
        NOT activate Windows (activation still happens later via the user's own key, digital
        licence, or KMS). Baking the correct generic key in lets a fully-unattended install
        proceed past the "Setup has failed to validate the product key" / "Do you have a product
        key?" page that appears when a key is required but none is supplied.

        NOTE on Windows 11 24H2: its rearchitected Setup ("windlp") validates the key online in
        windowsPE. The *Home* generic key below is confirmed to pass that check and install
        hands-off; the non-Home generic keys may still be rejected there, so for Pro/Enterprise/etc.
        prefer a genuine key. See https://learn.microsoft.com/windows-server/get-started/kms-client-activation-keys.
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

    # Public generic / default retail setup keys (edition selectors that skip the OOBE
    # product-key page; they do NOT activate). Keyed by a normalized edition name.
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
