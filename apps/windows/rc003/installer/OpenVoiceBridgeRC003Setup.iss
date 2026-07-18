; Inno Setup source for Open Voice Bridge · RC003 (Windows source/build
; candidate). Unsigned. Not yet real-device verified - see this
; subtree's top-level README.md "Known gaps" section before treating
; this as a supported release artifact.
;
; Hard boundaries enforced by this script:
;   - PrivilegesRequired=lowest (no admin elevation requested, ever).
;   - No [Tasks]/[Icons] entry adds a login-autostart shortcut.
;   - No VB-CABLE or any other driver package is installed, configured, or
;     referenced. Voice output is chosen by the user inside the app itself.
;   - No Frida binary is included (none is ever bundled - see
;     ovb_rc003/frida_compat.py).

#define AppName "Open Voice Bridge · RC003"
#define AppPublisher "Open Voice Bridge contributors"
#define AppVersion "0.1.0-candidate"
#define AppExeName "OpenVoiceBridgeRC003.exe"
#define AppFolder "RC003"
#define DistDir "..\dist\OpenVoiceBridgeRC003"

[Setup]
AppId={{B6E8B6F0-7B9B-4B7C-9E7E-3B7B2C6B0F5C}}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\OpenVoiceBridge\{#AppFolder}
DefaultGroupName=Open Voice Bridge
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
OutputBaseFilename=OpenVoiceBridgeRC003Setup-{#AppVersion}-unsigned
OutputDir=..\dist\installer
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
CloseApplications=yes
RestartApplications=no

[Files]
Source: "{#DistDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "readme-rc003.txt"; DestDir: "{app}"; Flags: isreadme ignoreversion
Source: "..\..\..\..\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; DestName: "THIRD_PARTY_NOTICES.md"; Flags: ignoreversion
Source: "..\..\..\..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "..\..\..\..\COPYRIGHT"; DestDir: "{app}"; DestName: "COPYRIGHT.txt"; Flags: ignoreversion
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
; having seen/confirmed configuration first.
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Parameters: "--settings"
Name: "{group}\{#AppName} 设置"; Filename: "{app}\{#AppExeName}"; Parameters: "--settings"
Name: "{group}\启动 {#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\停止 {#AppName}"; Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\stop-app.ps1"" -AppPath ""{app}"""; WorkingDir: "{app}"; Flags: runminimized
Name: "{group}\卸载 {#AppName}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Parameters: "--settings"; Tasks: desktopicon
; Deliberately no {userstartup} icon anywhere in this file.

[Run]
; Post-install may open Settings, but must never silently start the
; no-argument bridge (that would touch BLE/HID/audio before the user has
; configured anything) - unchecked by default either way.
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
