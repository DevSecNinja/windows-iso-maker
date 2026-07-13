function Get-GenericSetupProductKey {
    <#
    .SYNOPSIS
        Return the public generic (KMS client setup) product key for a Windows 11 edition.
    .DESCRIPTION
        Windows Setup uses the <ProductKey> in the windowsPE pass only to decide WHICH edition
        to install and to skip the interactive product-key page. Microsoft publishes generic
        "KMS client setup keys" for exactly this purpose — they select an edition but do NOT
        activate Windows (activation still happens later via the user's own key, digital
        licence, or KMS). Baking the correct generic key in lets fully-unattended Pro (and
        other non-Home) installs proceed past the "Setup has failed to validate the product
        key" page that appears when a key is required but none is supplied.

        See https://learn.microsoft.com/windows-server/get-started/kms-client-activation-keys.
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

    # Public generic Volume Licensing / KMS client setup keys (edition selectors, not
    # activation keys). Keyed by a normalized edition name.
    $keys = @{
        'home'                    = 'TX9XD-98N7V-6WMQ6-BX7FG-H8Q99'
        'homen'                   = '3KHY7-WNT83-DGQKR-F7HPR-844BM'
        'homesinglelanguage'      = '7HNRX-D7KGG-3K4RQ-4WPJ4-YTDFH'
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
