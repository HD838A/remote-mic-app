param(
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..\..')).Path
$pythonExe = Join-Path $repoRoot 'apps\windows\rc003\.venv\Scripts\python.exe'
$sourceRoot = Join-Path $repoRoot 'apps\windows\rc003\src'
$mainModule = Join-Path $sourceRoot 'ovb_rc003\__main__.py'

foreach ($requiredPath in @($pythonExe, $mainModule)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "最新源码入口缺少必需文件：$requiredPath"
    }
}

if ($VerifyOnly) {
    Write-Host "入口校验通过：将从当前工作区源码启动，不使用 dist、安装目录或旧打包文件。"
    Write-Host $mainModule
    exit 0
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class RemoteMicWindowProbe {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

    public static bool SettingsWindowExists() {
        bool found = false;
        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            var text = new StringBuilder(256);
            GetWindowText(hWnd, text, text.Capacity);
            if (text.ToString() == "Remote Mic 设置") {
                found = true;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@

if ([RemoteMicWindowProbe]::SettingsWindowExists()) {
    Write-Error "检测到已经打开的 Remote Mic 设置窗口。为避免单实例机制把旧窗口带到前台，请先关闭它，再重新使用本入口。桥接进程无需关闭。"
    exit 2
}

$env:PYTHONPATH = $sourceRoot
& $pythonExe -m ovb_rc003 --settings
exit $LASTEXITCODE
