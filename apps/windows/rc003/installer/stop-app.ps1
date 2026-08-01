#requires -Version 5.1
<#
.SYNOPSIS
    Force-stops any running RemoteMicRC003.exe under the given install
    path, so the installer/uninstaller can safely replace or remove files.
    Generic and product-path-driven; requests no elevation itself.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$AppPath
)

$ErrorActionPreference = "SilentlyContinue"

$normalizedAppPath = (Resolve-Path -LiteralPath $AppPath -ErrorAction SilentlyContinue)
if (-not $normalizedAppPath) {
    exit 0
}

Get-CimInstance Win32_Process |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($normalizedAppPath.Path, [System.StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

exit 0
