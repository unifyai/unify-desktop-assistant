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

; Environment: "main" (production) or "staging" - passed via /DEnvironment=...
#ifndef Environment
  #define Environment "main"
#endif

#if Environment == "staging"
  #define OrchestraUrl "https://service.a.run.app/v0"
  #define CommsUrl "https://unity-comms-app-staging-000000000000.us-central1.run.app"
  #define EnvSuffix "-staging"
#else
  #define OrchestraUrl "https://api.unify.ai/v0"
  #define CommsUrl "https://unity-comms-app-000000000000.us-central1.run.app"
  #define EnvSuffix ""
#endif

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
DisableDirPage=auto
DisableProgramGroupPage=yes
DefaultGroupName={#AppName}
OutputDir=output
OutputBaseFilename=UnifyDesktopAssistant-Setup-{#AppVersion}{#EnvSuffix}
SetupIconFile=icon.ico
UninstallDisplayIcon={app}\assets\icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
UsedUserAreasWarning=no
MinVersion=10.0
RestartIfNeededByRun=no

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
Filename: "cmd.exe"; Parameters: "/k powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""{app}\tools\setup.ps1"" -UnifyKey ""{code:GetUnifyKey}"" -OrchestraUrl ""{#OrchestraUrl}"" -UnityCommsUrl ""{#CommsUrl}"" -Force"; StatusMsg: "Installing dependencies (this may take several minutes)..."; Flags: waituntilterminated
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
// =========================================================================
// Variables
// =========================================================================
var
  ConfigPage: TWizardPage;
  UnifyKeyEdit: TNewEdit;
  UpgradeNote: TNewStaticText;
  ConfigPagePrefilled: Boolean;

// =========================================================================
// Helper: Read a value from existing .env file
// =========================================================================
function ReadEnvValue(const EnvFile, Key: String): String;
var
  Lines: TArrayOfString;
  I: Integer;
  Line, Prefix: String;
begin
  Result := '';
  Prefix := Key + '=';
  if FileExists(EnvFile) then
  begin
    if LoadStringsFromFile(EnvFile, Lines) then
    begin
      for I := 0 to GetArrayLength(Lines) - 1 do
      begin
        Line := Trim(Lines[I]);
        if Pos(Prefix, Line) = 1 then
        begin
          Result := Copy(Line, Length(Prefix) + 1, Length(Line));
          Exit;
        end;
      end;
    end;
  end;
end;

// =========================================================================
// PrepareToInstall: Stop services before upgrading files
// =========================================================================
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  SetupScript: String;
  ResultCode: Integer;
begin
  Result := '';
  SetupScript := ExpandConstant('{app}\tools\setup.ps1');

  // Only run on upgrade (existing installation)
  if FileExists(SetupScript) then
  begin
    // Stop services gracefully via setup.ps1 -Stop
    Exec('powershell.exe',
      '-NoProfile -ExecutionPolicy Bypass -File "' + SetupScript + '" -Stop',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

    // Kill the tray app process if running (releases file locks)
    Exec('powershell.exe',
      '-NoProfile -Command "Get-Process -Name powershell, pwsh -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq '''' -and $_.CommandLine -match ''UnifyAssistant'' } | Stop-Process -Force -ErrorAction SilentlyContinue"',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

    // Also kill wscript.exe running the launcher
    Exec('taskkill.exe', '/F /IM wscript.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;

// =========================================================================
// InitializeWizard: Create the configuration page
// =========================================================================
procedure InitializeWizard();
begin
  ConfigPagePrefilled := False;

  // Create custom configuration page (after tasks page, before ready page)
  ConfigPage := CreateCustomPage(wpSelectTasks, 'Configuration', 'Enter your Unify API key');

  // --- Upgrade notice (hidden by default, shown if upgrade detected in CurPageChanged) ---
  UpgradeNote := TNewStaticText.Create(ConfigPage);
  with UpgradeNote do
  begin
    Parent := ConfigPage.Surface;
    Caption := 'Existing configuration detected - modify if needed.';
    Left := 0;
    Top := 0;
    Width := ConfigPage.SurfaceWidth;
    Font.Style := [fsBold];
    Visible := False;
  end;

  // --- Unify Key ---
  with TNewStaticText.Create(ConfigPage) do
  begin
    Parent := ConfigPage.Surface;
    Caption := 'Unify API Key:';
    Left := 0;
    Top := 28;
    Width := ConfigPage.SurfaceWidth;
  end;

  UnifyKeyEdit := TNewEdit.Create(ConfigPage);
  with UnifyKeyEdit do
  begin
    Parent := ConfigPage.Surface;
    Left := 0;
    Top := 48;
    Width := ConfigPage.SurfaceWidth;
  end;

  // --- Help text ---
  with TNewStaticText.Create(ConfigPage) do
  begin
    Parent := ConfigPage.Surface;
    Caption := 'You can change this later from the tray icon menu.';
    Left := 0;
    Top := 80;
    Width := ConfigPage.SurfaceWidth;
    Font.Style := [fsItalic];
  end;
end;

// =========================================================================
// CurPageChanged: Pre-fill config from existing .env on upgrade
// (called when each wizard page is shown - {app} is available by now)
// =========================================================================
procedure CurPageChanged(CurPageID: Integer);
var
  EnvFile: String;
  ExistingKey: String;
begin
  if (CurPageID = ConfigPage.ID) and (not ConfigPagePrefilled) then
  begin
    ConfigPagePrefilled := True;

    // Now {app} is safe to expand (dir page has been passed or auto-skipped)
    EnvFile := ExpandConstant('{app}\agent-service\.env');

    if FileExists(EnvFile) then
    begin
      // Show upgrade notice
      UpgradeNote.Visible := True;

      // Pre-fill API key
      ExistingKey := ReadEnvValue(EnvFile, 'UNIFY_KEY');
      if ExistingKey <> '' then
        UnifyKeyEdit.Text := ExistingKey;
    end;
  end;
end;

// =========================================================================
// Validate configuration before proceeding
// =========================================================================
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

// =========================================================================
// Save configuration after install
// =========================================================================
procedure CurStepChanged(CurStep: TSetupStep);
var
  EnvFile: String;
  EnvContent: String;
  SettingsFile: String;
begin
  if CurStep = ssPostInstall then
  begin
    EnvFile := ExpandConstant('{app}\agent-service\.env');
    SettingsFile := ExpandConstant('{app}\settings.json');

    // Always write .env (fresh install or upgrade)
    // URLs are baked in at build time via preprocessor defines
    EnvContent := 'PORT=3000' + Chr(13) + Chr(10) +
                  'UNIFY_KEY=' + UnifyKeyEdit.Text + Chr(13) + Chr(10) +
                  'ORCHESTRA_URL={#OrchestraUrl}' + Chr(13) + Chr(10) +
                  'UNITY_COMMS_URL={#CommsUrl}' + Chr(13) + Chr(10);
    SaveStringToFile(EnvFile, EnvContent, False);

    // Only create settings.json on fresh install (preserve existing user prefs)
    if not FileExists(SettingsFile) then
      SaveStringToFile(SettingsFile, '{"AutoStartServices": true}', False);
  end;
end;

// =========================================================================
// Scripted constant for [Run] section to pass Unify Key to setup.ps1
// =========================================================================
function GetUnifyKey(Param: String): String;
begin
  Result := UnifyKeyEdit.Text;
end;

// =========================================================================
// InitializeSetup
// =========================================================================
function InitializeSetup(): Boolean;
begin
  Result := True;
end;
