[CmdletBinding()]
param(
    [string]$PythonExecutable = "",
    [string]$IndexUrl = "https://pypi.tuna.tsinghua.edu.cn/simple"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$AppRoot = Join-Path $ProjectRoot "apps\windows\rc003"
$VenvPython = Join-Path $AppRoot ".venv\Scripts\python.exe"

if (-not $PythonExecutable) {
    $UvCommand = Get-Command uv -ErrorAction SilentlyContinue
    if ($UvCommand) {
        $Candidate = (& $UvCommand.Source python find 3.11 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and $Candidate -and (Test-Path -LiteralPath $Candidate)) {
            $PythonExecutable = $Candidate
        }
    }
}

if (-not $PythonExecutable) {
    $PyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($PyLauncher) {
        $Candidate = (& $PyLauncher.Source -3.11 -c "import sys; print(sys.executable)" 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and $Candidate -and (Test-Path -LiteralPath $Candidate)) {
            $PythonExecutable = $Candidate
        }
    }
}

if (-not $PythonExecutable) {
    $PythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if (-not $PythonCommand) {
        throw "Python 3.10 or newer was not found."
    }
    $PythonExecutable = $PythonCommand.Source
}

if (-not (Test-Path -LiteralPath $VenvPython)) {
    & $PythonExecutable -m venv (Join-Path $AppRoot ".venv")
    if ($LASTEXITCODE -ne 0) { throw "Creating the baseline virtual environment failed." }
}

$UvCommand = Get-Command uv -ErrorAction SilentlyContinue
if ($UvCommand) {
    & $UvCommand.Source pip install --python $VenvPython --index-url $IndexUrl -r (Join-Path $AppRoot "requirements-dev.txt")
} else {
    & $VenvPython -m pip install --index-url $IndexUrl -r (Join-Path $AppRoot "requirements-dev.txt")
}
if ($LASTEXITCODE -ne 0) { throw "Installing baseline dependencies failed." }

Write-Host "Baseline environment ready: $VenvPython"
