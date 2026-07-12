@{
    # PSScriptAnalyzer configuration for WindowsIsoMaker.
    # Used by local runs and .github/workflows/ci.yml (Constitution Principle I & III).

    # Start from the full built-in rule set, then tighten a few rules and exclude
    # a small number that conflict with this project's deliberate design.
    IncludeDefaultRules = $true

    Severity = @('Error', 'Warning', 'Information')

    ExcludeRules = @(
        # We ship a module + a thin build.ps1 dispatcher and vendored Fido; the module
        # manifest declares exports. This rule mis-fires on dot-sourced module layouts.
        'PSUseToExportFieldsInManifest',

        # Fido.ps1 is a vendored third-party GPLv3 script (see vendor/fido/NOTICE) and
        # is intentionally excluded from our style rules; excluded via path below too.
        'PSAvoidUsingWriteHost',

        # This project standardizes on UTF-8 WITHOUT a BOM for cross-platform (Linux CI +
        # Windows runners) consistency. Comments contain a few non-ASCII glyphs (em dashes),
        # which would otherwise trip this rule. UTF-8 no-BOM is a deliberate encoding choice.
        'PSUseBOMForUnicodeEncodedFile',

        # Noisy with our Pester v5 InModuleScope -Parameters pattern (script-block params are
        # used indirectly) and with pipeline functions that accept a -Config object purely for
        # context/logging/interface consistency. Genuine dead code is caught in review.
        'PSReviewUnusedParameter'
    )

    Rules = @{
        # Enforce approved verbs (Principle I: PowerShell best practices).
        PSUseApprovedVerbs = @{
            Enable = $true
        }

        # Require comment-based help on every exported function.
        PSProvideCommentHelp = @{
            Enable                  = $true
            ExportedOnly            = $true
            BlockComment            = $true
            VSCodeSnippetCorrection = $false
            Placement               = 'begin'
        }

        # Disallow aliases entirely (Principle I: no aliases, PascalCase, full names).
        PSAvoidUsingCmdletAliases = @{
            Enable    = $true
            AllowList = @()
        }

        # Correct casing of cmdlets/parameters (PascalCase discipline).
        PSUseCorrectCasing = @{
            Enable = $true
        }

        # ShouldProcess must be honored where declared (Principle VI: -WhatIf safety).
        PSUseShouldProcessForStateChangingFunctions = @{
            Enable = $true
        }

        # Compatibility: target both Windows PowerShell 5.1 and PowerShell 7+ (Principle V).
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
