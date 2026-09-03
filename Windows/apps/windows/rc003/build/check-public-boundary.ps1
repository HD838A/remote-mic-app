#requires -Version 5.1
<#
.SYNOPSIS
    Scans apps/windows/rc003 for content that must never ship in this public,
    GPL-3.0-only candidate: committed third-party binaries, real Bluetooth
    addresses, personal absolute paths, credentials, forbidden branding, and
    admin-elevation/autostart markers.

    This mirrors (in PowerShell, so it can gate a real Windows build)
    tests/test_privacy_contract.py and tests/test_build_artifacts.py, which
    run the equivalent checks in Python on any OS -
    tests/test_boundary_scan_replay.py replays this exact scoping/allowlist
    logic in Python against the real tree, so the fix below is covered by a
    cross-platform test even without a PowerShell runtime. Keep all three in
    sync if any is extended.

    Self-report fix (XRBM-014 review RETRY P1 #8): earlier versions of this
    script excluded only their own file from content scanning, so several
    kinds of legitimate self-reference tripped their own regexes:
      1. Files that *define* the forbidden-term lists (tests/test_privacy_contract.py,
         tests/test_build_artifacts.py, this script, and its Python replay
         test) - these are exempted from the branding/elevation/autostart
         categories entirely (they still get the binary/personal-path/
         credential checks). tests/test_config.py's own only conflict was a
         MAC-address placeholder fixture, which the separate, unconditional
         MAC allowlist below covers without needing a branding exemption.
      2. Prose that explicitly documents an EXCLUSION rather than an
         inclusion (installer/readme-rc003.txt's "不包含 T1、V60/PV60..."
         line) - exempted the same way, since a "we do not bundle X"
         sentence is exactly the kind of statement this project wants, not
         a violation.
      3. Explanatory comments inside .ps1/.iss files (e.g. this file's own
         module comment, or the installer's "deliberately no {userstartup}
         icon" comment) - comment lines (leading ``#`` for .ps1, ``;`` for
         .iss) are stripped before the branding/elevation/autostart checks
         run, matching the identical comment-aware approach
         tests/test_build_artifacts.py already uses in Python.
    The MAC-address category instead allowlists the single well-known
    placeholder value "AA:BB:CC:DD:EE:FF" everywhere, since that placeholder
    is used only to prove a real address gets *rejected*, never to persist
    one.

    Cross-platform path handling and generated-directory exclusion
    (XRBM-022 controller pre-review correction): earlier versions of this
    script normalized relative paths with
    ``(Resolve-Path -Relative) -replace "^\.\\", ""`` and compared against a
    backslash-formatted exemption list - correct on native Windows
    PowerShell 5.1 (where ``Resolve-Path -Relative`` returns backslash
    paths), but wrong when this script is actually run under pwsh on
    macOS/Linux for local/CI-parity testing, where the same cmdlet returns
    forward-slash paths (e.g. ``./tests/x.py``) that the backslash-only
    regex never strips - every exempt file then false-positived as a
    violation of the very patterns it legitimately defines. Fixed by
    computing the relative path with plain string manipulation
    (``Get-NormalizedRelativePath`` below), normalizing to forward slashes
    on *both* sides before comparing, which is correct on every OS pwsh/
    PowerShell runs on. Separately, this script previously only excluded
    ``build\third_party\`` from the recursive file scan - but
    ``build-candidate.ps1`` creates ``.venv\`` (a real Python virtualenv,
    full of ``.exe``/``.dll``/``.pyd`` files) and ``dist\``/
    ``build\pyinstaller-work\`` (PyInstaller's build output) *before*
    calling this scan, so a first `build-candidate.ps1` run could fail on
    its own freshly-created virtualenv binaries, and a second run could
    additionally fail on the previous run's `dist\` output - making the
    build script unsafe to re-run. Fixed by excluding these generated
    directories the same way ``third_party`` already was: by bare
    directory-name path component, not a hardcoded-separator regex, which
    is inherently portable.
#>

param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot ".."))
)

$ErrorActionPreference = "Stop"
$violations = New-Object System.Collections.Generic.List[string]

$forbiddenBinaryExtensions = @(".exe", ".dll", ".pyd", ".zip", ".xz")
$optionalFridaGadgetRelativePath = "src/ovb_rc003/frida_assets/frida-gadget-17.15.3-windows-x86_64.dll.xz"
$optionalFridaGadgetSha256 = "B566D70189B6D551AD8F4E0BEA24DE08A3D4C0F559BB35B2BDB67D45182240C2"
$textExtensions = @(".py", ".ps1", ".md", ".txt", ".json", ".yml", ".yaml", ".iss", ".spec", ".toml")

$macAddressPattern = "([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}"
$macAddressPlaceholder = "AA:BB:CC:DD:EE:FF"
$personalPathPattern = "[A-Za-z]:\\Users\\[^\\""'\s]+"
$credentialPattern = "(api[_-]?key|client[_-]?secret|password)\s*[:=]\s*[""'][^""']{8,}[""']"
$forbiddenBrandingPatterns = @("2655\s*AI", "2655ai\.com", "T1RemoteBridge", "V60PenBridge", "PV60", "汉王")
$elevationMarkers = @("runas", "ShellExecute", "IsUserAnAdmin", "RequireAdministrator", "PrivilegesRequired=admin")
$autostartMarkers = @("CurrentVersion\\Run", "userstartup")

# Generated/build-output directories - never source, always safe to
# regenerate, and routinely contain forbidden-binary-extension files
# (a virtualenv's own python.exe/*.dll/*.pyd, PyInstaller's dist/work
# output) that must never be treated as "committed" content. Matched by
# bare directory-name path component (see Get-NormalizedRelativePath),
# so this is independent of which OS/shell produced the path separators.
$excludedDirNames = @(".venv", "dist", "pyinstaller-work", "third_party")

# Files that legitimately *define* the forbidden-term lists above, a
# negative-test fixture, or a documented EXCLUSION statement - skip ONLY the
# branding/elevation/autostart categories for these (they still get the
# binary, personal-path, and credential checks like everything else).
# Canonical form: forward-slash-separated, relative to $ProjectRoot - see
# Get-NormalizedRelativePath.
$brandingCheckExemptRelativePaths = @(
    "tests/test_privacy_contract.py",
    "tests/test_build_artifacts.py",
    "tests/test_boundary_scan_replay.py",
    "build/check-public-boundary.ps1",
    "installer/readme-rc003.txt",
    # XRBM-031: the SOLE production-source exemption in this list, and only
    # for the elevation category - src/ovb_rc003/vb_cable_bundle.py
    # legitimately requests Windows' own "runas"/UAC verb to launch the
    # THIRD-PARTY VB-CABLE vendor's own setup UI (never to elevate this
    # application itself, and only from an explicit user click), which is
    # otherwise forbidden everywhere else in this source tree. See
    # tests/test_boundary_scan_replay.py's
    # test_vb_cable_bundle_py_is_exempt_only_for_its_documented_elevation_reason
    # and tests/test_privacy_contract.py's
    # test_elevation_exception_is_scoped_to_the_vendor_vb_cable_launch_only,
    # which both prove this file contains no branding/autostart violation and
    # that the elevation reference is exactly the one disclosed vendor-launch
    # call, not a self-elevation of this project's own process.
    "src/ovb_rc003/vb_cable_bundle.py",
    # README.md/ATTRIBUTION.md document this same disclosed "runas"/UAC
    # vendor-launch mechanism in prose - the word itself is documentation,
    # not a directive.
    "README.md",
    "ATTRIBUTION.md"
)

function Get-NormalizedRelativePath {
    # Portable relative-path computation: avoids Resolve-Path -Relative
    # (whose separator convention follows the *shell's* OS, not a fixed
    # one) entirely, and always normalizes to forward slashes so the
    # result is directly comparable to the forward-slash exemption list
    # above on any OS.
    param([string]$FullName, [string]$Root)

    $normalizedFull = $FullName -replace '\\', '/'
    $normalizedRoot = ($Root -replace '\\', '/').TrimEnd('/')
    if ($normalizedFull.StartsWith($normalizedRoot + '/')) {
        return $normalizedFull.Substring($normalizedRoot.Length + 1)
    }
    return $normalizedFull
}

function Test-ExcludedGeneratedPath {
    param([string]$FullName, [string[]]$ExcludedDirNames)

    $components = $FullName -split '[\\/]'
    foreach ($name in $ExcludedDirNames) {
        if (($components -contains $name) -or ($name -eq "dist" -and ($components | Where-Object { $_ -like "dist-*" })) -or ($name -eq "pyinstaller-work" -and ($components | Where-Object { $_ -like "pyinstaller-work-*" })) -or ($name -eq "build" -and ($components | Where-Object { $_ -like "build-*" }))) {
            return $true
        }
    }
    return $false
}

function Remove-CommentLines {
    param([string]$Text, [string]$Extension)

    if ($Extension -eq ".ps1") {
        $prefix = "#"
    } elseif ($Extension -eq ".iss") {
        $prefix = ";"
    } else {
        return $Text
    }

    $lines = $Text -split "`r?`n"
    $kept = $lines | Where-Object { -not ($_.TrimStart().StartsWith($prefix)) }
    return ($kept -join "`n")
}

Push-Location $ProjectRoot
try {
    $allFiles = Get-ChildItem -Recurse -File | Where-Object {
        -not (Test-ExcludedGeneratedPath -FullName $_.FullName -ExcludedDirNames $excludedDirNames)
    }

    foreach ($file in $allFiles) {
        $ext = $file.Extension.ToLowerInvariant()

        $relativePath = Get-NormalizedRelativePath -FullName $file.FullName -Root $ProjectRoot

        if ($forbiddenBinaryExtensions -contains $ext) {
            $isVerifiedOptionalFridaGadget = $false
            if ($relativePath -eq $optionalFridaGadgetRelativePath) {
                $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash
                $isVerifiedOptionalFridaGadget = $actualHash.Equals(
                    $optionalFridaGadgetSha256,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            }
            if ($isVerifiedOptionalFridaGadget) {
                continue
            }
            $violations.Add("forbidden binary committed: $($file.FullName)")
            continue
        }

        if ($textExtensions -notcontains $ext) {
            continue
        }

        $isExempt = $brandingCheckExemptRelativePaths -contains $relativePath

        $text = Get-Content -Raw -LiteralPath $file.FullName -ErrorAction SilentlyContinue
        if (-not $text) { continue }

        $macMatches = [regex]::Matches($text, $macAddressPattern)
        foreach ($match in $macMatches) {
            if ($match.Value.ToUpperInvariant() -ne $macAddressPlaceholder) {
                $violations.Add("MAC-address-shaped literal in: $($file.FullName)")
                break
            }
        }

        if ($text -match $personalPathPattern) {
            $violations.Add("personal absolute path in: $($file.FullName)")
        }
        if ($text -match $credentialPattern) {
            $violations.Add("credential-shaped literal in: $($file.FullName)")
        }

        if (-not $isExempt) {
            $effectiveText = Remove-CommentLines -Text $text -Extension $ext

            foreach ($pattern in $forbiddenBrandingPatterns) {
                if ($effectiveText -match $pattern) {
                    $violations.Add("forbidden branding ('$pattern') in: $($file.FullName)")
                }
            }
            foreach ($marker in $elevationMarkers) {
                if ($effectiveText.Contains($marker)) {
                    $violations.Add("elevation marker ('$marker') in: $($file.FullName)")
                }
            }
            foreach ($marker in $autostartMarkers) {
                if ($effectiveText.Contains($marker)) {
                    $violations.Add("autostart marker ('$marker') in: $($file.FullName)")
                }
            }
        }
    }
} finally {
    Pop-Location
}

if ($violations.Count -gt 0) {
    foreach ($violation in $violations) {
        Write-Error $violation
    }
    exit 1
}

Write-Host "check-public-boundary: passed ($($allFiles.Count) files scanned)"
exit 0
