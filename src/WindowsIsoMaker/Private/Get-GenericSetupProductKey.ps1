function Get-GenericSetupProductKey {
    <#
    .SYNOPSIS
        Return the generic (non-activating) setup product key for a Windows 11 edition.
    .DESCRIPTION
        Returns the public generic key that selects a Windows 11 edition during Setup without
        activating it (activation still happens later via the user's own key, digital licence, or
        KMS). The key is applied in the *windowsPE* UserData pass
        (`Microsoft-Windows-Setup/UserData/ProductKey`): on multi-edition media Windows 11 24H2
        Setup stops at the interactive "enter a product key" page unless windowsPE supplies a key
        (the ImageInstall /IMAGE/NAME metadata alone does not suppress it), and clicking "I don't
        have a product key" then fails with "Setup has failed to validate the product key". A
        generic key in windowsPE selects the edition and keeps the install hands-off.

        IMPORTANT — the key CLASS must match the media family (see Get-Windows11IsoFamily):
          * Consumer media (the Fido retail Home ISO) accepts the public **retail generic** keys
            (Home / Home N / Home Single Language). A GVLK is REJECTED on retail media with
            "the product key entered doesn't work" — it "won't activate or serve as a retail
            license key".
          * Business/volume media (caller-supplied -IsoPath) accepts the **GVLK / KMS client**
            keys (Pro, Education, Enterprise, ...). A retail generic key is rejected there.
        Because only Home ships on retail consumer media, every non-Home edition below uses its
        GVLK. See https://learn.microsoft.com/windows-server/get-started/kms-client-activation-keys.
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

    # Generic setup keys (edition selectors applied in windowsPE UserData; they do NOT activate).
    # Keyed by a normalized edition name. Home variants use the public RETAIL generic keys (they
    # ship on the Fido consumer ISO); every other edition uses its GVLK / KMS client key because
    # it only installs from business/volume media (see Get-Windows11IsoFamily). Keys verified
    # against https://learn.microsoft.com/windows-server/get-started/kms-client-activation-keys.
    $keys = @{
        # --- Consumer (retail generic keys; Fido consumer ISO) ---
        'home'                    = 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7'
        'homen'                   = '4CPRK-NM3K3-X6XXQ-RXX86-WXCHW'
        'homesinglelanguage'      = 'BT79Q-G7N6G-PGBYW-4YWX6-6F4BT'
        # --- Business (GVLK / KMS client keys; business/volume ISO via -IsoPath) ---
        'pro'                     = 'W269N-WFGWX-YVC9B-4J6C9-T83GX'
        'pron'                    = 'MH37W-N47XK-V7XM9-C7227-GCQG9'
        'proforworkstations'      = 'NRG8B-VKK3Q-CXVCJ-9G2XF-6Q84J'
        'pronforworkstations'     = '9FNHH-K3HBT-3W4TD-6383H-6XYWF'
        'proeducation'            = '6TP4R-GNPTD-KYYHQ-7B7DP-J447Y'
        'proeducationn'           = 'YVWGF-BXNMC-HTQYQ-CPQ99-66QFC'
        'education'               = 'NW6C2-QMPVW-D7KKK-3GKT6-VCFB2'
        'educationn'              = '2WH4N-8QGBV-H22JP-CT43Q-MDWWJ'
        'enterprise'              = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'
        'enterprisen'             = 'DPH2V-TTNVB-4X9Q3-TJR4H-KHJW4'
        'enterpriseg'             = 'YYVX9-NTFWV-6MDM3-9PT4T-4M68B'
        'enterprisegn'            = '44RPN-FTY23-9VTTB-MP9BX-T84FV'
        'enterpriseltsc2024'      = 'M7XTQ-FN8P6-TTKYV-9D4CC-J462D'
        'enterprisenltsc2024'     = '92NFX-8DJQP-P6BBQ-THF9C-7CG2H'
        'iotenterpriseltsc2024'   = 'KBN8V-HFGQ4-MGXVD-347P6-PDQGT'
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
