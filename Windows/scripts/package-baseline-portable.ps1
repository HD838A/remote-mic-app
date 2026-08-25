[CmdletBinding()]
param(
    [string]$Version = "0.1.0-candidate"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ArtifactsRoot = Join-Path $ProjectRoot "artifacts"
$BuiltApp = Join-Path $ProjectRoot "apps\windows\rc003\dist\RemoteMicRC003"
$PackageName = "RemoteMicRC003-$Version-portable-unsigned"
$StagingRoot = Join-Path $ArtifactsRoot $PackageName
$StagedApp = Join-Path $StagingRoot "RemoteMicRC003"
$ZipPath = Join-Path $ArtifactsRoot "$PackageName.zip"

if (-not (Test-Path -LiteralPath (Join-Path $BuiltApp "RemoteMicRC003.exe"))) {
    throw "Built candidate was not found. Run scripts/build-baseline-candidate.ps1 first."
}

$ResolvedArtifacts = [System.IO.Path]::GetFullPath($ArtifactsRoot).TrimEnd('\') + '\'
foreach ($target in @($StagingRoot, $ZipPath)) {
    $resolved = [System.IO.Path]::GetFullPath($target)
    if (-not $resolved.StartsWith($ResolvedArtifacts, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Package target resolved outside the artifacts directory: $resolved"
    }
}

New-Item -ItemType Directory -Path $ArtifactsRoot -Force | Out-Null
if (Test-Path -LiteralPath $StagingRoot) {
    Remove-Item -LiteralPath $StagingRoot -Recurse -Force
}
if (Test-Path -LiteralPath $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
}

New-Item -ItemType Directory -Path $StagingRoot -Force | Out-Null
Copy-Item -LiteralPath $BuiltApp -Destination $StagedApp -Recurse
Copy-Item -LiteralPath (Join-Path $ProjectRoot "LICENSE.md") -Destination (Join-Path $StagingRoot "LICENSE.txt")
Copy-Item -LiteralPath (Join-Path $ProjectRoot "COPYRIGHT.md") -Destination (Join-Path $StagingRoot "COPYRIGHT.txt")
Copy-Item -LiteralPath (Join-Path $ProjectRoot "THIRD_PARTY_NOTICES.md") -Destination (Join-Path $StagingRoot "THIRD_PARTY_NOTICES.md")
Copy-Item -LiteralPath (Join-Path $ProjectRoot "apps\windows\rc003\installer\readme-rc003.txt") -Destination (Join-Path $StagingRoot "README.txt")

$hashTargets = @(
    (Join-Path $StagedApp "RemoteMicRC003.exe"),
    (Join-Path $StagedApp "_internal\vb_cable_bundle\VBCABLE_Driver_Pack45.zip"),
    (Join-Path $StagingRoot "LICENSE.txt"),
    (Join-Path $StagingRoot "THIRD_PARTY_NOTICES.md")
)
$hashLines = foreach ($path in $hashTargets) {
    # Windows PowerShell 5.1 can run on a .NET Framework version that does not
    # provide Path.GetRelativePath. Every target above is constructed below the
    # already-validated staging root, so a prefix trim is both compatible and
    # deterministic here.
    $resolvedPath = [System.IO.Path]::GetFullPath($path)
    $resolvedStaging = [System.IO.Path]::GetFullPath($StagingRoot).TrimEnd('\') + '\'
    if (-not $resolvedPath.StartsWith($resolvedStaging, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Hash target resolved outside the staging directory: $resolvedPath"
    }
    $relative = $resolvedPath.Substring($resolvedStaging.Length).Replace('\', '/')
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
    "$hash  $relative"
}
[System.IO.File]::WriteAllLines((Join-Path $StagingRoot "SHA256SUMS.txt"), $hashLines)

Compress-Archive -Path $StagingRoot -DestinationPath $ZipPath -CompressionLevel Optimal -ErrorAction Stop
$zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ZipPath).Hash
[System.IO.File]::WriteAllText("$ZipPath.sha256", "$zipHash  $([System.IO.Path]::GetFileName($ZipPath))`r`n")

$zip = Get-Item -LiteralPath $ZipPath
Write-Host "Portable candidate: $($zip.FullName)"
Write-Host "Bytes: $($zip.Length)"
Write-Host "SHA-256: $zipHash"
