#requires -Version 5.1
param(
    [string]$PythonExecutable = "python",
    [string]$Version = "0.1.0-dev",
    [switch]$SkipDependencyInstall,
    [switch]$SkipPackage
)

$ErrorActionPreference = "Stop"
$Rc003Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Assert-LastExitCode {
    param([string]$Step)
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE"
    }
}

function Find-Iscc {
    $Candidates = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )
    foreach ($Candidate in $Candidates) {
        if ($Candidate -and (Test-Path $Candidate)) {
            return $Candidate
        }
    }
    throw "未找到 Inno Setup 6 ISCC.exe"
}

Push-Location $Rc003Root
try {
    if (-not (Test-Path ".venv\Scripts\python.exe")) {
        & $PythonExecutable -m venv .venv
        Assert-LastExitCode "python -m venv"
    }
    $Python = (Resolve-Path ".venv\Scripts\python.exe").Path

    if (-not $SkipDependencyInstall) {
        & $Python -m pip install --upgrade pip
        Assert-LastExitCode "pip upgrade"
        & $Python -m pip install -r requirements-dev.txt
        Assert-LastExitCode "dependency install"
    }

    & $Python -m compileall -q src tests
    Assert-LastExitCode "compileall"

    $env:PYTHONPATH = Join-Path $Rc003Root "src"
    & $Python -m unittest discover -s tests -t . -p "test_*.py" -v
    Assert-LastExitCode "unit tests"

    & $Python -m PyInstaller build\RemoteMicRC003.spec --distpath dist --workpath build\pyinstaller-work --noconfirm --clean
    Assert-LastExitCode "PyInstaller"

    $BuiltExe = Join-Path $Rc003Root "dist\RemoteMicRC003\RemoteMicRC003.exe"
    if (-not (Test-Path $BuiltExe)) {
        throw "PyInstaller 未生成预期文件：$BuiltExe"
    }
    & $BuiltExe --dry-run
    Assert-LastExitCode "built executable dry-run"

    $Iscc = Find-Iscc
    & $Iscc "/DAppVersion=$Version" "installer\RemoteMicRC003Setup.iss"
    Assert-LastExitCode "Inno Setup"

    if (-not $SkipPackage) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File "build\package-windows.ps1" -Version $Version
        Assert-LastExitCode "package-windows.ps1"
    }
} finally {
    Pop-Location
}
