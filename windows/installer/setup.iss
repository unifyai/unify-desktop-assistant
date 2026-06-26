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
; Version: overridable via ISCC /DAppVersion=... (build.ps1 -Version / CI input).
; Must be guarded by #ifndef, otherwise an unconditional #define here would clobber
; the command-line value and the built installer would always report 1.0.0.
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppPublisher "Unify"
#define AppURL "https://unify.ai"
#define AppExeName "UnifyAssistant.vbs"

; Environment: "main" (production) or "staging" - passed via /DEnvironment=...
#ifndef Environment
  #define Environment "main"
#endif

#if Environment == "staging"
  #define OrchestraUrl "https://internal.example.com/v0"
  #define CommsUrl "https://service.a.run.app"
  #define EnvSuffix "-staging"
#else
  #define OrchestraUrl "https://api.unify.ai/v0"
  #define CommsUrl "https://service.a.run.app"
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

[Messages]
; Welcome / finish wording tailored to Unify (mirrors the macOS installer panes)
WelcomeLabel2=This will install [name] on your computer.%n%nUnify Desktop Assistant lets the Unify platform securely view and control this machine. You'll enter your Unify API key on a later screen.%n%nClick Next to continue.
FinishedHeadingLabel=Unify Desktop Assistant is installed
FinishedLabel=Setup has finished installing Unify Desktop Assistant.%n%nThe Unify icon appears in your system tray (near the clock) and turns green once services are running. On first install this can take a few minutes while dependencies download.%n%nYou can change your API key anytime from the tray icon's Settings.
FinishedLabelNoIcons=Setup has finished installing Unify Desktop Assistant.%n%nThe Unify icon appears in your system tray (near the clock) and turns green once services are running. On first install this can take a few minutes while dependencies download.%n%nYou can change your API key anytime from the tray icon's Settings.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Core application files
Source: "..\tools\*"; DestDir: "{app}\tools"; Excludes: "novnc,novnc\*,*.log"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\gui\*"; DestDir: "{app}\gui"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\magnitude\*"; DestDir: "{app}\magnitude"; Excludes: "node_modules,node_modules\*,.turbo,.turbo\*"; Flags: ignoreversion recursesubdirs createallsubdirs
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
Filename: "cmd.exe"; Parameters: "/c powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""{app}\tools\setup.ps1"" {code:GetSetupRunParams}"; StatusMsg: "Installing dependencies (this may take several minutes)..."; Flags: waituntilterminated
; Launch tray app after install
Filename: "wscript.exe"; Parameters: """{app}\{#AppExeName}"""; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent runhidden

[UninstallRun]
; Signal tray app to shut down gracefully (creates signal file, waits for tray to dispose its icon)
Filename: "cmd.exe"; Parameters: "/c echo.>""{app}\uninstall.signal"" && ping -n 7 127.0.0.1 >nul"; Flags: runhidden waituntilterminated; RunOnceId: "SignalTrayApp"
; Fallback: force-kill tray app if it didn't exit gracefully
Filename: "wmic.exe"; Parameters: "process where ""Name='powershell.exe' AND CommandLine LIKE '%UnifyAssistant%'"" call terminate"; Flags: runhidden waituntilterminated; RunOnceId: "KillTrayApp"
; Stop services, remove scheduled tasks, remove firewall rules
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\tools\setup.ps1"" -Uninstall"; Flags: runhidden waituntilterminated; RunOnceId: "UninstallCleanup"

[UninstallDelete]
; Remove entire install directory (includes node_modules, novnc, logs, etc.)
Type: filesandordirs; Name: "{app}"

[Code]
// =========================================================================
// Variables
// =========================================================================
var
  ConfigPage: TWizardPage;
  UnifyKeyEdit: TNewEdit;
  UpgradeNote: TNewStaticText;
  ConfigPagePrefilled: Boolean;

function TestComposeSelfHostPresent: Boolean;
begin
  Result := FileExists(ExpandConstant('{%USERPROFILE}\.unity\docker-compose.yml'));
end;

function GetSetupRunParams(Param: String): String;
begin
  Result := '-UnifyKey "' + UnifyKeyEdit.Text + '" -Force';
  if TestComposeSelfHostPresent then
    Result := Result + ' -SelfHost -LinkCoordinator'
  else
    Result := Result + ' -OrchestraUrl "{#OrchestraUrl}" -UnityCommsUrl "{#CommsUrl}"';
end;

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
    // Signal tray app to shut down gracefully (dispose icon, then exit)
    Exec('cmd.exe',
      '/c echo.>"' + ExpandConstant('{app}') + '\uninstall.signal"',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    // Wait ~6 seconds for the tray app to detect signal and exit cleanly
    Exec('cmd.exe', '/c ping -n 7 127.0.0.1 >nul', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    // Fallback: force-kill tray app if it didn't exit gracefully
    Exec('wmic.exe',
      'process where "Name=''powershell.exe'' AND CommandLine LIKE ''%UnifyAssistant%''" call terminate',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

    // Stop services gracefully via setup.ps1 -Stop
    Exec('powershell.exe',
      '-NoProfile -ExecutionPolicy Bypass -File "' + SetupScript + '" -Stop',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
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
  ExistingTunnelId: String;
  ExistingTunnelUrl: String;
  ExistingTunnelToken: String;
  ExistingDeviceId: String;
  AgentPort: String;
  OrchestraUrl: String;
  CommsUrl: String;
  SelfHostFlag: String;
begin
  if CurStep = ssPostInstall then
  begin
    EnvFile := ExpandConstant('{app}\agent-service\.env');
    SettingsFile := ExpandConstant('{app}\settings.json');

    // Preserve existing tunnel/device values on upgrade
    ExistingTunnelId := ReadEnvValue(EnvFile, 'TUNNEL_ID');
    ExistingTunnelUrl := ReadEnvValue(EnvFile, 'TUNNEL_URL');
    ExistingTunnelToken := ReadEnvValue(EnvFile, 'TUNNEL_TOKEN');
    ExistingDeviceId := ReadEnvValue(EnvFile, 'DEVICE_ID');

    if TestComposeSelfHostPresent then
    begin
      AgentPort := '13000';
      OrchestraUrl := 'http://127.0.0.1:8000/v0';
      CommsUrl := 'http://127.0.0.1:8001';
      SelfHostFlag := '1';
    end
    else
    begin
      AgentPort := '3000';
      OrchestraUrl := '{#OrchestraUrl}';
      CommsUrl := '{#CommsUrl}';
      SelfHostFlag := '0';
    end;

    // Always write .env (fresh install or upgrade)
    EnvContent := 'PORT=' + AgentPort + Chr(13) + Chr(10) +
                  'UNIFY_KEY=' + UnifyKeyEdit.Text + Chr(13) + Chr(10) +
                  'ORCHESTRA_URL=' + OrchestraUrl + Chr(13) + Chr(10) +
                  'UNITY_COMMS_URL=' + CommsUrl + Chr(13) + Chr(10) +
                  'SELF_HOST=' + SelfHostFlag + Chr(13) + Chr(10) +
                  'PLAYWRIGHT_BROWSERS_PATH=C:\ms-playwright' + Chr(13) + Chr(10) +
                  Chr(13) + Chr(10) +
                  'TUNNEL_ID=' + ExistingTunnelId + Chr(13) + Chr(10) +
                  'TUNNEL_URL=' + ExistingTunnelUrl + Chr(13) + Chr(10) +
                  'TUNNEL_TOKEN=' + ExistingTunnelToken + Chr(13) + Chr(10) +
                  'DEVICE_ID=' + ExistingDeviceId + Chr(13) + Chr(10);
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
