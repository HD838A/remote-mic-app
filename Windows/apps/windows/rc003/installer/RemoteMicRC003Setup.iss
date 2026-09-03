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
#define AppPayloadDir "app"
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
SetupIconFile=..\..\..\..\Resources\RemoteMic-AppIcon.ico
SetupLogging=yes
OutputBaseFilename=RemoteMicRC003Setup-{#AppVersion}-unsigned
OutputDir=..\dist\installer
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppPayloadDir}\{#AppExeName}
CloseApplications=yes
RestartApplications=no

[InstallDelete]
; Every versioned program file lives below one replaceable payload directory.
; Runtime data (config, mappings, statistics and logs) stays at {app}'s root,
; so an in-place upgrade can remove the old program without deleting user data.
Type: filesandordirs; Name: "{app}\{#AppPayloadDir}"
; One-time migration from the previous flat PyInstaller layout.
Type: files; Name: "{app}\{#AppExeName}"
Type: filesandordirs; Name: "{app}\_internal"

[Files]
Source: "{#DistDir}\*"; DestDir: "{app}\{#AppPayloadDir}"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "readme-rc003.txt"; DestDir: "{app}\{#AppPayloadDir}"; Flags: isreadme ignoreversion
Source: "..\..\..\..\THIRD_PARTY_NOTICES.md"; DestDir: "{app}\{#AppPayloadDir}"; DestName: "THIRD_PARTY_NOTICES.md"; Flags: ignoreversion
Source: "..\..\..\..\LICENSE.md"; DestDir: "{app}\{#AppPayloadDir}"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "..\..\..\..\COPYRIGHT.md"; DestDir: "{app}\{#AppPayloadDir}"; DestName: "COPYRIGHT.txt"; Flags: ignoreversion
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
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppPayloadDir}\{#AppExeName}"; Parameters: "--settings"
Name: "{group}\{#AppName} 设置"; Filename: "{app}\{#AppPayloadDir}\{#AppExeName}"; Parameters: "--settings"
Name: "{group}\启动 {#AppName}"; Filename: "{app}\{#AppPayloadDir}\{#AppExeName}"; Parameters: "--bridge"
Name: "{group}\停止 {#AppName}"; Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\stop-app.ps1"" -AppPath ""{app}"""; WorkingDir: "{app}"; Flags: runminimized
Name: "{group}\卸载 {#AppName}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#AppName}"; Filename: "{app}\{#AppPayloadDir}\{#AppExeName}"; Parameters: "--settings"; Tasks: desktopicon
; Deliberately no {userstartup} icon anywhere in this file.

[Run]
; Post-install may open Settings, but must never silently start the
; bridge (that would touch BLE/HID/audio before the user has configured
; anything) - unchecked by default either way.
Filename: "{app}\{#AppPayloadDir}\{#AppExeName}"; Parameters: "--settings"; Description: "打开 {#AppName} 设置"; Flags: postinstall nowait skipifsilent unchecked

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
