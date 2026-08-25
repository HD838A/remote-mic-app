#requires -Version 5.1
<#
.SYNOPSIS
    Downloads the official VB-Audio VB-CABLE Basic driver package
    (VBCABLE_Driver_Pack45.zip) over HTTPS and verifies its SHA-256 against
    the same pin recorded in src/ovb_rc003/vb_cable_bundle.py's
    VB_CABLE_PACK45 constant, BEFORE
    build-candidate.ps1/windows-rc003-ci.yml ever hand it to PyInstaller.

    This is a REQUIRED step for both the local candidate build and Windows
    CI (XRBM-031 In-scope item 8) - unlike build/fetch-frida-gadget.ps1
    (optional, never wired into any build step), a missing or hash-mismatched
    VB-CABLE package must fail the build closed rather than silently
    producing a candidate with no bundled driver helper.

    The downloaded ZIP is the vendor's ORIGINAL, unmodified package - this
    script never extracts, patches, or repacks it (see
    src/ovb_rc003/vb_cable_bundle.py for the runtime extraction/launch
    logic, which independently re-verifies the same hash before ever
    touching the file). Written to build/third_party/, which this
    directory's own .gitignore already excludes - never committed to Git.

.PARAMETER Destination
    Where to place the verified ZIP. Defaults to build/third_party/ next to
    this script.
#>

param(
    [string]$Destination = (Join-Path $PSScriptRoot "third_party\VBCABLE_Driver_Pack45.zip")
)

$ErrorActionPreference = "Stop"

$AssetName = "VB-CABLE Driver Pack (Basic, Donationware) - Pack45"
$AssetUrl = "https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip"
# Pinned exactly to VB_CABLE_PACK45.sha256 in src/ovb_rc003/vb_cable_bundle.py
# - keep both in sync; a real upstream package change must fail this script
# closed, never be silently re-pinned without a reviewed task.
$ExpectedSha256 = "B950E39F01AF1D04EA623C8F6D8EB9B6EA5C477C637295FABF20631C85116BFB"

function Get-Sha256Upper([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Get-VerifiedAsset {
    param(
        [string]$Name,
        [string]$Url,
        [string]$Destination,
        [string]$ExpectedSha256
    )

    $destinationDir = Split-Path -Parent $Destination
    if (-not (Test-Path $destinationDir)) {
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
    }

    if (Test-Path $Destination) {
        $existingHash = Get-Sha256Upper $Destination
        if ($existingHash -eq $ExpectedSha256.ToUpperInvariant()) {
            Write-Host "[fetch-vb-cable] $Name already verified at $Destination"
            return
        }
        Write-Warning "[fetch-vb-cable] existing file at $Destination has an unexpected hash; re-downloading"
        Remove-Item -Force -LiteralPath $Destination
    }

    $tempFile = "$Destination.download"
    try {
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            $curlArgs = @(
                "--fail", "--location", "--silent", "--show-error",
                "--retry", "5", "--retry-delay", "2",
                "--connect-timeout", "30", "--max-time", "600",
                "--output", $tempFile, $Url
            )
            if (Test-Path $tempFile) {
                $curlArgs = @("--continue-at", "-") + $curlArgs
            }
            & curl.exe @curlArgs
            if ($LASTEXITCODE -ne 0) {
                throw "curl.exe exited with code $LASTEXITCODE while fetching $Name"
            }
        } else {
            Invoke-WebRequest -Uri $Url -OutFile $tempFile -UseBasicParsing -TimeoutSec 600
        }

        $actualHash = Get-Sha256Upper $tempFile
        if ($actualHash -ne $ExpectedSha256.ToUpperInvariant()) {
            throw "SHA-256 mismatch for $Name`: expected $ExpectedSha256, got $actualHash. Refusing to use this file - the build must fail closed here."
        }

        Move-Item -Force -LiteralPath $tempFile -Destination $Destination
        Write-Host "[fetch-vb-cable] verified and saved $Name to $Destination"
    } finally {
        if (Test-Path $tempFile) {
            Remove-Item -Force -LiteralPath $tempFile -ErrorAction SilentlyContinue
        }
    }
}

Get-VerifiedAsset -Name $AssetName -Url $AssetUrl -Destination $Destination -ExpectedSha256 $ExpectedSha256

Write-Host ""
Write-Host "VB-CABLE is Donationware by VB-Audio - see https://vb-audio.com/Services/licensing.htm"
Write-Host "and https://www.vb-cable.com. Only the Basic package is fetched here; the paid"
Write-Host "A+B/C+D bundles are never downloaded or bundled by this project."
Write-Host "This script only downloads and verifies the package - it never installs anything;"
Write-Host "installation only happens via src/ovb_rc003/vb_cable_bundle.py's user-initiated,"
Write-Host "UAC-elevated launch of the vendor's own original setup UI."
