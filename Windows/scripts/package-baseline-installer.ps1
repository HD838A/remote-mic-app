[CmdletBinding()]
param(
    [string]$Version = "0.1.0-candidate"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ArtifactsRoot = Join-Path $ProjectRoot "artifacts"
$SourceInstaller = Join-Path $ProjectRoot "apps\windows\rc003\dist\installer\RemoteMicRC003Setup-$Version-unsigned.exe"
$DestinationInstaller = Join-Path $ArtifactsRoot "RemoteMicRC003Setup-$Version-unsigned.exe"

if (-not (Test-Path -LiteralPath $SourceInstaller)) {
    throw "Compiled installer was not found. Build the Inno Setup candidate first."
}

$ResolvedArtifacts = [System.IO.Path]::GetFullPath($ArtifactsRoot).TrimEnd('\') + '\'
$ResolvedDestination = [System.IO.Path]::GetFullPath($DestinationInstaller)
if (-not $ResolvedDestination.StartsWith($ResolvedArtifacts, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Installer target resolved outside the artifacts directory: $ResolvedDestination"
}

$signature = Get-AuthenticodeSignature -LiteralPath $SourceInstaller
if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::NotSigned) {
    throw "Expected an unsigned candidate, but signature status was $($signature.Status)."
}

New-Item -ItemType Directory -Path $ArtifactsRoot -Force | Out-Null
Copy-Item -LiteralPath $SourceInstaller -Destination $DestinationInstaller -Force

$installerHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $DestinationInstaller).Hash
[System.IO.File]::WriteAllText(
    "$DestinationInstaller.sha256",
    "$installerHash  $([System.IO.Path]::GetFileName($DestinationInstaller))`r`n"
)

$installer = Get-Item -LiteralPath $DestinationInstaller
Write-Host "Installer candidate: $($installer.FullName)"
Write-Host "Bytes: $($installer.Length)"
Write-Host "SHA-256: $installerHash"
Write-Host "Signature: $($signature.Status)"
