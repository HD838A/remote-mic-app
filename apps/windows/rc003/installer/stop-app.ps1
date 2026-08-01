#requires -Version 5.1
$ErrorActionPreference = "Stop"

Get-Process -Name "RemoteMicRC003" -ErrorAction SilentlyContinue |
    Where-Object { $_.SessionId -eq (Get-Process -Id $PID).SessionId } |
    Stop-Process -Force
