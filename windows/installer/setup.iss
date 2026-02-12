; Unify Desktop Assistant - Inno Setup Script
; 
; This script creates a Windows installer that:
; - Installs all files to Program Files
; - Creates Start Menu entries
; - Launches the tray GUI app on install
; - Registers for auto-start on login
;
; Build:
;   iscc setup.iss
; Or use:
;   .\build.ps1

#define AppName "Unify Desktop Assistant"
#define AppVersion "1.0.0"
#define AppPublisher "Unify"
#define AppURL "https://unify.ai"
#define AppExeName "UnifyAssistant.vbs"

[Setup]
; Unique app identifier
AppId={{7E8A9F2D-3B4C-5D6E-8F9A-1B2C3D4E5F6A}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
DefaultGroupName={#AppName}
OutputDir=output
OutputBaseFilename=UnifyDesktopAssistant-Setup-{#AppVersion}
SetupIconFile=icon.ico
UninstallDisplayIcon={app}\assets\icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64
MinVersion=10.0

; Wizard appearance (optional - uses defaults if files missing)
; WizardImageFile=assets\wizard.bmp
; WizardSmallImageFile=assets\wizard-small.bmp
DisableWelcomePage=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Core application files
Source: "..\tools\*"; DestDir: "{app}\tools"; Excludes: "novnc,novnc\*,*.log"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\gui\*"; DestDir: "{app}\gui"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\magnitude\*"; DestDir: "{app}\magnitude"; Excludes: "node_modules,node_modules\*"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\agent-service\*"; DestDir: "{app}\agent-service"; Excludes: "node_modules,node_modules\*,*.log,.env"; Flags: ignoreversion recursesubdirs createallsubdirs

; Assets
Source: "icon.ico"; DestDir: "{app}\assets"; Flags: ignoreversion

; Launcher script (runs PowerShell GUI hidden)
Source: "launcher.vbs"; DestDir: "{app}"; DestName: "{#AppExeName}"; Flags: ignoreversion

[Icons]
; Start Menu
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\assets\icon.ico"; WorkingDir: "{app}"
Name: "{autoprograms}\{#AppName} Settings"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\gui\UnifyAssistant.ps1"""; IconFilename: "{app}\assets\icon.ico"; WorkingDir: "{app}"

; Desktop icon (optional)
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\assets\icon.ico"; WorkingDir: "{app}"; Tasks: desktopicon

[Registry]
; Auto-start on login (always enabled)
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "UnifyDesktopAssistant"; ValueData: """{app}\{#AppExeName}"""; Flags: uninsdeletevalue

[Run]
; Install all dependencies during setup (runs after .env is written by CurStepChanged)
Filename: "cmd.exe"; Parameters: "/k powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""{app}\tools\setup.ps1"" -UnifyKey ""{code:GetUnifyKey}"" -OrchestraUrl ""{code:GetOrchestraUrl}"" -UnityCommsUrl ""{code:GetUnityCommsUrl}"""; StatusMsg: "Installing dependencies (this may take several minutes)..."; Flags: waituntilterminated
; Launch tray app after install
Filename: "wscript.exe"; Parameters: """{app}\{#AppExeName}"""; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent runhidden

[UninstallRun]
; Stop services before uninstall
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\tools\setup.ps1"" -Stop"; Flags: runhidden waituntilterminated; RunOnceId: "StopServices"

[UninstallDelete]
; Clean up generated files
Type: filesandordirs; Name: "{app}\tools\novnc"
Type: filesandordirs; Name: "{app}\magnitude\node_modules"
Type: filesandordirs; Name: "{app}\magnitude\packages\magnitude-core\node_modules"
Type: filesandordirs; Name: "{app}\agent-service\node_modules"
Type: files; Name: "{app}\agent-service\.env"
Type: files; Name: "{app}\settings.json"

[Code]
// Configuration page variables
var
  ConfigPage: TWizardPage;
  UnifyKeyEdit: TNewEdit;
  OrchestraUrlEdit: TNewEdit;
  UnityCommsUrlEdit: TNewEdit;

// Initialize configuration page
procedure InitializeWizard();
begin
  // Create custom configuration page
  ConfigPage := CreateCustomPage(wpSelectTasks, 'Configuration', 'Enter your Unify API credentials');
  
  // Unify Key label
  with TNewStaticText.Create(ConfigPage) do
  begin
    Parent := ConfigPage.Surface;
    Caption := 'Unify API Key:';
    Left := 0;
    Top := 8;
    Width := ConfigPage.SurfaceWidth;
  end;
  
  // Unify Key edit
  UnifyKeyEdit := TNewEdit.Create(ConfigPage);
  with UnifyKeyEdit do
  begin
    Parent := ConfigPage.Surface;
    Left := 0;
    Top := 28;
    Width := ConfigPage.SurfaceWidth;
  end;
  
  // Orchestra URL label
  with TNewStaticText.Create(ConfigPage) do
  begin
    Parent := ConfigPage.Surface;
    Caption := 'Orchestra URL (optional):';
    Left := 0;
    Top := 68;
    Width := ConfigPage.SurfaceWidth;
  end;
  
  // Orchestra URL edit
  OrchestraUrlEdit := TNewEdit.Create(ConfigPage);
  with OrchestraUrlEdit do
  begin
    Parent := ConfigPage.Surface;
    Left := 0;
    Top := 88;
    Width := ConfigPage.SurfaceWidth;
    Text := 'https://api.unify.ai/v0';
  end;
  
  // Unity Comms URL label
  with TNewStaticText.Create(ConfigPage) do
  begin
    Parent := ConfigPage.Surface;
    Caption := 'Unity Comms URL (optional):';
    Left := 0;
    Top := 128;
    Width := ConfigPage.SurfaceWidth;
  end;
  
  // Unity Comms URL edit
  UnityCommsUrlEdit := TNewEdit.Create(ConfigPage);
  with UnityCommsUrlEdit do
  begin
    Parent := ConfigPage.Surface;
    Left := 0;
    Top := 148;
    Width := ConfigPage.SurfaceWidth;
    Text := 'https://unity-comms-app-000000000000.us-central1.run.app';
  end;
  
  // Help text
  with TNewStaticText.Create(ConfigPage) do
  begin
    Parent := ConfigPage.Surface;
    Caption := 'You can change these settings later from the tray icon menu.';
    Left := 0;
    Top := 190;
    Width := ConfigPage.SurfaceWidth;
    Font.Style := [fsItalic];
  end;
end;

// Validate configuration before proceeding
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  
  if CurPageID = ConfigPage.ID then
  begin
    if Trim(UnifyKeyEdit.Text) = '' then
    begin
      MsgBox('Please enter your Unify API Key.', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

// Save configuration after install
procedure CurStepChanged(CurStep: TSetupStep);
var
  EnvFile: String;
  EnvContent: String;
begin
  if CurStep = ssPostInstall then
  begin
    // Create .env file with user configuration
    EnvFile := ExpandConstant('{app}\agent-service\.env');
    EnvContent := 'PORT=3000' + Chr(13) + Chr(10) +
                  'UNIFY_KEY=' + UnifyKeyEdit.Text + Chr(13) + Chr(10) +
                  'ORCHESTRA_URL=' + OrchestraUrlEdit.Text + Chr(13) + Chr(10) +
                  'UNITY_COMMS_URL=' + UnityCommsUrlEdit.Text + Chr(13) + Chr(10);
    SaveStringToFile(EnvFile, EnvContent, False);
    
    // Also save settings.json for the GUI
    SaveStringToFile(ExpandConstant('{app}\settings.json'), '{"AutoStartServices": true}', False);
  end;
end;

// Scripted constants for [Run] section to pass config values to setup.ps1
function GetUnifyKey(Param: String): String;
begin
  Result := UnifyKeyEdit.Text;
end;

function GetOrchestraUrl(Param: String): String;
begin
  Result := OrchestraUrlEdit.Text;
end;

function GetUnityCommsUrl(Param: String): String;
begin
  Result := UnityCommsUrlEdit.Text;
end;

// Check if running as admin
function InitializeSetup(): Boolean;
begin
  Result := True;
end;
