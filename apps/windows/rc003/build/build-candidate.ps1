#requires -Version 5.1
<#
.SYNOPSIS
    Builds an unsigned Open Voice Bridge · RC003 candidate on Windows.

    Steps: create/activate a virtual environment, install
    requirements-dev.txt, run the public-boundary scan, run the test suite
    (gated with ``-W error::ResourceWarning``, matching the CI workflow),
    invoke PyInstaller against OpenVoiceBridgeRC003.spec, then smoke-check
    the built executable with ``--dry-run`` (imports every module, touches
    no GUI/BLE/HID/audio, exits 0) so a broken build is caught here rather
    than only discovered on a real machine.

    Does NOT fetch Frida Gadget, does NOT touch VB-CABLE (out of scope), does
    NOT request elevation, and does NOT sign the resulting binary.

    Exit-code gating (XRBM-014 review RETRY P2 #3): PowerShell's
    ``$ErrorActionPreference = "Stop"`` only turns PowerShell-cmdlet errors
    into terminating errors - a NATIVE command (venv creation, pip, python,
    PyInstaller, the built .exe itself) can exit non-zero without PowerShell
    treating that as an error at all, letting the script silently continue
    past a real failure. Every native invocation below is followed by an
    explicit ``$LASTEXITCODE`` check via ``Assert-LastExitCode``.

.PARAMETER PythonExecutable
    Python interpreter to create the virtual environment with. Defaults to
    "py -3.12" if available, else "python".
#>

param(
    [string]$PythonExecutable = "python"
)

$ErrorActionPreference = "Stop"
$RC003Root = Resolve-Path (Join-Path $PSScriptRoot "..")

function Assert-LastExitCode {
    param([string]$Step)
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE"
    }
}

Write-Host "== Open Voice Bridge · RC003 candidate build =="

Push-Location $RC003Root
try {
    if (-not (Test-Path ".venv")) {
        & $PythonExecutable -m venv .venv
        Assert-LastExitCode "python -m venv"
    }
    $venvPython = Join-Path ".venv" "Scripts\python.exe"

    & $venvPython -m pip install --upgrade pip
    Assert-LastExitCode "pip install --upgrade pip"
    & $venvPython -m pip install -r requirements-dev.txt
    Assert-LastExitCode "pip install -r requirements-dev.txt"

    Write-Host "-- public boundary scan --"
    & powershell -ExecutionPolicy Bypass -File (Join-Path "build" "check-public-boundary.ps1")
    Assert-LastExitCode "check-public-boundary.ps1"

    Write-Host "-- test suite --"
    $env:PYTHONPATH = Join-Path $RC003Root "src"
    & $venvPython -W error::ResourceWarning -m unittest discover -s tests -t . -p "test_*.py"
    Assert-LastExitCode "python -m unittest discover"

    Write-Host "-- PyInstaller build (unsigned candidate) --"
    & $venvPython -m PyInstaller (Join-Path "build" "OpenVoiceBridgeRC003.spec") --distpath dist --workpath build\pyinstaller-work --noconfirm
    Assert-LastExitCode "PyInstaller"

    Write-Host "-- built-artifact dry-run smoke check (no GUI/BLE/HID/audio) --"
    $builtExe = Join-Path "dist" (Join-Path "OpenVoiceBridgeRC003" "OpenVoiceBridgeRC003.exe")
    if (-not (Test-Path $builtExe)) {
        throw "expected built executable not found: $builtExe"
    }
    & $builtExe --dry-run
    Assert-LastExitCode "$builtExe --dry-run"

    Write-Host "== build complete: dist\OpenVoiceBridgeRC003\ (unsigned) =="
} finally {
    Pop-Location
}
