#ifndef AppVersion
  #define AppVersion "0.1.0-dev"
#endif

#define AppName "Remote Mic · RC003"
#define AppPublisher "Remote Mic contributors"
#define AppExeName "RemoteMicRC003.exe"
#define DistDir "..\dist\RemoteMicRC003"

[Setup]
AppId={{B6E8B6F0-7B9B-4B7C-9E7E-3B7B2C6B0F5C}}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\RemoteMic\RC003
DefaultGroupName=Remote Mic
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
OutputBaseFilename=RemoteMicRC003Setup-{#AppVersion}
OutputDir=..\dist\installer
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
CloseApplications=yes
RestartApplications=no
#ifdef RemoteMicSigning
SignTool=remote_mic
SignedUninstaller=yes
#endif

[Files]
Source: "{#DistDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "stop-app.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "readme-rc003.txt"; DestDir: "{app}"; Flags: isreadme ignoreversion
Source: "..\..\..\..\LICENSE.md"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "..\..\..\..\COPYRIGHT.md"; DestDir: "{app}"; DestName: "COPYRIGHT.txt"; Flags: ignoreversion
Source: "..\..\..\..\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\ATTRIBUTION.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Remote Mic · RC003 设置"; Filename: "{app}\{#AppExeName}"; Parameters: "--settings"
Name: "{group}\启动 RC003 麦克风桥接"; Filename: "{app}\{#AppExeName}"; Parameters: "--bridge"
Name: "{group}\停止 RC003 麦克风桥接"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\stop-app.ps1"""
Name: "{group}\卸载 Remote Mic · RC003"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\{#AppExeName}"; Parameters: "--settings"; Description: "打开 RC003 设置"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\stop-app.ps1"""; Flags: runhidden; RunOnceId: "StopRemoteMicRC003"
