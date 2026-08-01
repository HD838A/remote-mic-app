#requires -Version 5.1
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [string]$IsccPath = ""
)

$ErrorActionPreference = "Stop"
$Rc003Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$PfxBase64 = $env:WINDOWS_CERTIFICATE_PFX_BASE64
$PfxPassword = $env:WINDOWS_CERTIFICATE_PASSWORD

if ([string]::IsNullOrWhiteSpace($PfxBase64) -or [string]::IsNullOrWhiteSpace($PfxPassword)) {
    throw "Release 签名要求 WINDOWS_CERTIFICATE_PFX_BASE64 和 WINDOWS_CERTIFICATE_PASSWORD"
}

if ([string]::IsNullOrWhiteSpace($IsccPath)) {
    $IsccPath = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
}
if (-not (Test-Path $IsccPath)) {
    throw "未找到 Inno Setup 编译器：$IsccPath"
}

$SignTool = (Get-Command signtool.exe -ErrorAction SilentlyContinue).Source
if (-not $SignTool) {
    $SignTool = Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\x64\\signtool\.exe$" } |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $SignTool) {
    throw "未找到 Windows SDK SignTool.exe"
}

$TemporaryPfx = Join-Path ([System.IO.Path]::GetTempPath()) ("remote-mic-windows-" + [guid]::NewGuid().ToString("N") + ".pfx")
$ImportedPersonal = $null
$ImportedRoot = $null

function Assert-LastExitCode {
    param([string]$Step)
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE"
    }
}

try {
    [System.IO.File]::WriteAllBytes($TemporaryPfx, [Convert]::FromBase64String($PfxBase64))
    $SecurePassword = ConvertTo-SecureString -String $PfxPassword -AsPlainText -Force
    $ImportedPersonal = Import-PfxCertificate -FilePath $TemporaryPfx -CertStoreLocation "Cert:\CurrentUser\My" -Password $SecurePassword -Exportable:$false
    if (-not $ImportedPersonal.HasPrivateKey) {
        throw "导入的证书没有私钥"
    }
    if ($ImportedPersonal.Subject -ne $ImportedPersonal.Issuer) {
        throw "当前策略只接受项目免费自签证书"
    }
    $CodeSigningOid = "1.3.6.1.5.5.7.3.3"
    if ($ImportedPersonal.EnhancedKeyUsageList.ObjectId.Value -notcontains $CodeSigningOid) {
        throw "证书缺少 Code Signing EKU"
    }

    $CertificatePath = Join-Path ([System.IO.Path]::GetTempPath()) ("remote-mic-windows-" + [guid]::NewGuid().ToString("N") + ".cer")
    Export-Certificate -Cert $ImportedPersonal -FilePath $CertificatePath | Out-Null
    $ImportedRoot = Import-Certificate -FilePath $CertificatePath -CertStoreLocation "Cert:\CurrentUser\Root"
    Remove-Item -Path $CertificatePath -Force

    $MainExe = Join-Path $Rc003Root "dist\RemoteMicRC003\RemoteMicRC003.exe"
    if (-not (Test-Path $MainExe)) {
        throw "找不到待签名主程序：$MainExe"
    }

    & $SignTool sign /fd SHA256 /sha1 $ImportedPersonal.Thumbprint /s My /v $MainExe
    Assert-LastExitCode "SignTool main executable"

    $InnoSignCommand = "`"$SignTool`" sign /fd SHA256 /sha1 $($ImportedPersonal.Thumbprint) /s My /v `$f"
    Push-Location $Rc003Root
    try {
        & $IsccPath "/DAppVersion=$Version" "/DRemoteMicSigning=1" "/Sremote_mic=$InnoSignCommand" "installer\RemoteMicRC003Setup.iss"
        Assert-LastExitCode "signed Inno Setup build"
    } finally {
        Pop-Location
    }

    $Installer = Join-Path $Rc003Root "dist\installer\RemoteMicRC003Setup-$Version.exe"
    foreach ($File in @($MainExe, $Installer)) {
        if (-not (Test-Path $File)) {
            throw "找不到待验证签名文件：$File"
        }
        & $SignTool verify /pa /v $File
        Assert-LastExitCode "SignTool verify $File"
    }

    $Sha256Bytes = $ImportedPersonal.GetCertHash([System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $Sha256Fingerprint = ($Sha256Bytes | ForEach-Object { $_.ToString("X2") }) -join ""
    $FingerprintPath = Join-Path $Rc003Root "dist\WINDOWS-CERTIFICATE-SHA256.txt"
    Set-Content -Path $FingerprintPath -Value $Sha256Fingerprint -Encoding ascii
    Write-Host "Windows 自签证书 SHA-256：$Sha256Fingerprint"
} finally {
    if ($ImportedRoot) {
        Remove-Item -Path ("Cert:\CurrentUser\Root\" + $ImportedRoot.Thumbprint) -Force -ErrorAction SilentlyContinue
    }
    if ($ImportedPersonal) {
        Remove-Item -Path ("Cert:\CurrentUser\My\" + $ImportedPersonal.Thumbprint) -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $TemporaryPfx) {
        Remove-Item -Path $TemporaryPfx -Force
    }
    $env:WINDOWS_CERTIFICATE_PFX_BASE64 = $null
    $env:WINDOWS_CERTIFICATE_PASSWORD = $null
}
