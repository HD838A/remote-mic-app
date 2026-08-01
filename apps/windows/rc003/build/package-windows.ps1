#requires -Version 5.1
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [switch]$IncludeCertificateFingerprint
)

$ErrorActionPreference = "Stop"
$Rc003Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$RepoRoot = (Resolve-Path (Join-Path $Rc003Root "..\..\..")).Path
$DistRoot = Join-Path $Rc003Root "dist"
$AppDir = Join-Path $DistRoot "RemoteMicRC003"
$InstallerDir = Join-Path $DistRoot "installer"
$PortableRoot = Join-Path $DistRoot "portable"
$ReleaseDir = Join-Path $DistRoot "release"
$StageName = "RemoteMicRC003-$Version"
$StageDir = Join-Path $PortableRoot $StageName
$ZipPath = Join-Path $PortableRoot "$StageName-portable.zip"

if (-not (Test-Path (Join-Path $AppDir "RemoteMicRC003.exe"))) {
    throw "找不到 PyInstaller 应用目录：$AppDir"
}
$Installer = Get-ChildItem -Path $InstallerDir -Filter "RemoteMicRC003Setup-$Version.exe" | Select-Object -First 1
if (-not $Installer) {
    throw "找不到 Inno Setup 安装器：RemoteMicRC003Setup-$Version.exe"
}

foreach ($Path in @($StageDir, $ReleaseDir)) {
    if (Test-Path $Path) {
        Remove-Item -Path $Path -Recurse -Force
    }
}
if (Test-Path $ZipPath) {
    Remove-Item -Path $ZipPath -Force
}

New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
Copy-Item -Path (Join-Path $AppDir "*") -Destination $StageDir -Recurse -Force
Copy-Item -Path (Join-Path $RepoRoot "LICENSE.md") -Destination (Join-Path $StageDir "LICENSE.txt") -Force
Copy-Item -Path (Join-Path $RepoRoot "COPYRIGHT.md") -Destination (Join-Path $StageDir "COPYRIGHT.txt") -Force
Copy-Item -Path (Join-Path $RepoRoot "THIRD_PARTY_NOTICES.md") -Destination $StageDir -Force
Copy-Item -Path (Join-Path $Rc003Root "ATTRIBUTION.md") -Destination $StageDir -Force
Copy-Item -Path (Join-Path $Rc003Root "installer\readme-rc003.txt") -Destination (Join-Path $StageDir "README.txt") -Force

Compress-Archive -Path $StageDir -DestinationPath $ZipPath -CompressionLevel Optimal

New-Item -ItemType Directory -Path $ReleaseDir -Force | Out-Null
Copy-Item -Path $ZipPath -Destination $ReleaseDir -Force
Copy-Item -Path $Installer.FullName -Destination $ReleaseDir -Force
if ($IncludeCertificateFingerprint) {
    $FingerprintPath = Join-Path $DistRoot "WINDOWS-CERTIFICATE-SHA256.txt"
    if (-not (Test-Path $FingerprintPath)) {
        throw "签名发布缺少证书 SHA-256 指纹：$FingerprintPath"
    }
    Copy-Item -Path $FingerprintPath -Destination $ReleaseDir -Force
}

$ManifestPath = Join-Path $ReleaseDir "SHA256SUMS.txt"
$ManifestLines = Get-ChildItem -Path $ReleaseDir -File |
    Where-Object { $_.Name -ne "SHA256SUMS.txt" } |
    Sort-Object Name |
    ForEach-Object {
        $Hash = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$Hash  $($_.Name)"
    }
Set-Content -Path $ManifestPath -Value $ManifestLines -Encoding utf8

Write-Host "Windows 独立发布目录：$ReleaseDir"
