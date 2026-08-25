[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$AppRoot = Join-Path $ProjectRoot "apps\windows\rc003"
$VenvPython = Join-Path $AppRoot ".venv\Scripts\python.exe"

if (-not (Test-Path -LiteralPath $VenvPython)) {
    throw "Baseline environment is missing. Run scripts/setup-baseline.ps1 first."
}

$GitRoot = (& git -C $ProjectRoot rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0 -or -not $GitRoot) { throw "Git repository root was not found." }

$TempIndex = Join-Path ([System.IO.Path]::GetTempPath()) ("remotemic-index-" + [guid]::NewGuid().ToString("N"))
$ExpectedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$ResolvedIndex = [System.IO.Path]::GetFullPath($TempIndex)
if (-not $ResolvedIndex.StartsWith($ExpectedTempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Temporary Git index resolved outside the temporary directory."
}

$PreviousIndex = $env:GIT_INDEX_FILE
$PreviousPythonPath = $env:PYTHONPATH
$PreviousNoBytecode = $env:PYTHONDONTWRITEBYTECODE

try {
    $env:GIT_INDEX_FILE = $ResolvedIndex
    & git -C $GitRoot read-tree HEAD
    if ($LASTEXITCODE -ne 0) { throw "Preparing the temporary Git index failed." }
    & git -c core.autocrlf=false -C $GitRoot add --all -- "Windows"
    if ($LASTEXITCODE -ne 0) { throw "Populating the temporary Git index failed." }

    $env:PYTHONPATH = Join-Path $AppRoot "src"
    $env:PYTHONDONTWRITEBYTECODE = "1"
    & $VenvPython -W error::ResourceWarning -m unittest discover -s (Join-Path $AppRoot "tests") -t $AppRoot -p "test_*.py"
    if ($LASTEXITCODE -ne 0) { throw "Windows baseline tests failed." }
} finally {
    $env:GIT_INDEX_FILE = $PreviousIndex
    $env:PYTHONPATH = $PreviousPythonPath
    $env:PYTHONDONTWRITEBYTECODE = $PreviousNoBytecode
    if (Test-Path -LiteralPath $ResolvedIndex) {
        Remove-Item -LiteralPath $ResolvedIndex -Force
    }
}
