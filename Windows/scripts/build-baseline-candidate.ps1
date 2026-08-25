[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$AppRoot = Join-Path $ProjectRoot "apps\windows\rc003"
$BuildScript = Join-Path $AppRoot "build\build-candidate.ps1"
$VenvPython = Join-Path $AppRoot ".venv\Scripts\python.exe"

if (-not (Test-Path -LiteralPath $VenvPython)) {
    throw "Baseline environment is missing. Run scripts/setup-baseline.ps1 first."
}

& $BuildScript -PythonExecutable $VenvPython -SkipDependencyInstall
if ($LASTEXITCODE -ne 0) {
    throw "Candidate build failed with exit code $LASTEXITCODE."
}
