; Inno Setup source for Remote Mic · RC003 (Windows source/build
; candidate). Unsigned. Not yet real-device verified - see this
; subtree's top-level README.md "Known gaps" section before treating
; this as a supported release artifact.
;
; Hard boundaries enforced by this script:
;   - PrivilegesRequired=lowest (no admin elevation requested, ever).
;   - No [Tasks]/[Icons] entry adds a login-autostart shortcut.
;   - This INSTALLER SCRIPT never installs, configures, silently modifies,
;     or removes VB-CABLE or any other driver, and never elevates itself to
;     do so, during install OR uninstall (XRBM-031 RETRY 1 item 5 - this
;     comment previously and incorrectly claimed VB-CABLE was never
;     referenced anywhere in this project at all). The application frozen
;     under {#DistDir} (packaged wholesale by the [Files] entry below) DOES
;     carry the official, unmodified VB-CABLE Basic package as opaque
;     application data, and its OWN "检查与修复" settings page can
;     optionally launch the vendor's original setup UI, gated behind its
;     own in-app confirmation and a SEPARATE, real Windows UAC prompt -
;     never this installer, never silently, and only after the app is
;     already running and the user has explicitly clicked to do so. Voice
;     output itself is still chosen by the user inside the app.
;   - No Frida binary is included (none is ever bundled - see
;     ovb_rc003/frida_compat.py).

#define AppName "Remote Mic · RC003"
#define AppPublisher "Remote Mic contributors"
#define AppVersion "0.1.0-candidate"
#define AppExeName "RemoteMicRC003.exe"
#define AppFolder "RC003"
#define DistDir "..\dist\RemoteMicRC003"

[Setup]
AppId={{B6E8B6F0-7B9B-4B7C-9E7E-3B7B2C6B0F5C}}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\RemoteMic\{#AppFolder}
DefaultGroupName=Remote Mic
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
OutputBaseFilename=RemoteMicRC003Setup-{#AppVersion}-unsigned
OutputDir=..\dist\installer
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
CloseApplications=yes
RestartApplications=no

[Files]
Source: "{#DistDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "readme-rc003.txt"; DestDir: "{app}"; Flags: isreadme ignoreversion
Source: "..\..\..\..\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; DestName: "THIRD_PARTY_NOTICES.md"; Flags: ignoreversion
Source: "..\..\..\..\LICENSE.md"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "..\..\..\..\COPYRIGHT.md"; DestDir: "{app}"; DestName: "COPYRIGHT.txt"; Flags: ignoreversion
; stop-app.ps1 is shipped TWICE on purpose, for two different lifecycles:
;   - the "dontcopy" entry below makes it available to ExtractTemporaryFile
;     in PrepareToInstall, so an in-place upgrade can stop a running instance
;     BEFORE this run's [Files] have been (re)written to {app};
;   - this normally-installed entry puts a real, permanent copy at
;     {app}\stop-app.ps1, which [UninstallRun] and the "Stop" shortcut below
;     both depend on existing on disk AFTER install completes.
Source: "stop-app.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "stop-app.ps1"; DestDir: "{tmp}"; Flags: dontcopy

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标:"; Flags: unchecked
; Deliberately no "start on login" task here.

[Icons]
; Primary Start Menu and optional desktop shortcuts both open Settings -
; neither silently starts bridge mode (BLE/HID/audio) without the user
; having seen/confirmed configuration first. The exe's no-argument form
; already opens Settings; --settings is kept explicit for clarity.
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Parameters: "--settings"
Name: "{group}\{#AppName} 设置"; Filename: "{app}\{#AppExeName}"; Parameters: "--settings"
Name: "{group}\启动 {#AppName}"; Filename: "{app}\{#AppExeName}"; Parameters: "--bridge"
Name: "{group}\停止 {#AppName}"; Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\stop-app.ps1"" -AppPath ""{app}"""; WorkingDir: "{app}"; Flags: runminimized
Name: "{group}\卸载 {#AppName}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Parameters: "--settings"; Tasks: desktopicon
; Deliberately no {userstartup} icon anywhere in this file.

[Run]
; Post-install may open Settings, but must never silently start the
; bridge (that would touch BLE/HID/audio before the user has configured
; anything) - unchecked by default either way.
Filename: "{app}\{#AppExeName}"; Parameters: "--settings"; Description: "打开 {#AppName} 设置"; Flags: postinstall nowait skipifsilent unchecked

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\stop-app.ps1"" -AppPath ""{app}"""; Flags: runhidden

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';
  ExtractTemporaryFile('stop-app.ps1');
  Exec('powershell.exe',
    '-ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\stop-app.ps1') + '" -AppPath "' + ExpandConstant('{app}') + '"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;
