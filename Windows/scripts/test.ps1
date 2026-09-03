[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$CMakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
$CMakePath = if ($CMakeCommand) { $CMakeCommand.Source } else { $null }

if (-not $CMakePath) {
    $BundledCMake = "C:\VSBuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
    if (Test-Path -LiteralPath $BundledCMake) {
        $CMakePath = $BundledCMake
    }
}

if (-not $CMakePath) {
    throw "CMake was not found. Run scripts/build.ps1 after installing the C++ CMake tools."
}

& $CMakePath --build (Join-Path $ProjectRoot "build") --config $Configuration --parallel
if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE." }

& $CMakePath --build (Join-Path $ProjectRoot "build") --target RUN_TESTS --config $Configuration
if ($LASTEXITCODE -ne 0) { throw "Tests failed with exit code $LASTEXITCODE." }
