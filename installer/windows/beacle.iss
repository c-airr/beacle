; Beacle installer for Windows — Inno Setup 6.1+
;
; NOT WIRED UP YET. Nothing builds this; scripts/build.ps1 does not know it
; exists. To try it: install Inno Setup and run
;     iscc installer\windows\beacle.iss
;
; This is a downloading installer, not a bundle. The payload lives on the
; GitHub release and is fetched at install time, which keeps the file people
; download small and means a new build needs a new release asset rather than a
; new installer.
;
; What it takes care of beyond copying files:
;   * a Start Menu entry, which is what makes Windows Search find "Beacle"
;   * an AppUserModelID on the shortcut, so pinning to the taskbar sticks to
;     the shortcut instead of spawning a second, unpinnable button
;   * an Apps & Features entry that removes the install cleanly
;   * leaving %AppData%\Beacle alone on uninstall, because that is where the
;     VPS registry and agent tokens live

#define AppName          "Beacle"
#define AppPublisher     "c-airr"
#define AppURL           "https://github.com/c-airr/beacle"
#define AppExeName       "beacle.exe"
#define AppUserModelID   "c-airr.Beacle"

; Bumped per release. The payload asset is looked up under this tag.
#define AppVersion       "0.1.0"
#define ReleaseTag       "v0.1.0"
#define PayloadAsset     "beacle-windows-x64.zip"
#define PayloadURL       "https://github.com/c-airr/beacle/releases/download/" + ReleaseTag + "/" + PayloadAsset

[Setup]
AppId={{8E4C9A61-2F7B-4D3E-9C15-BEAC1E000001}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
; Per-user install: no elevation prompt, and the app only ever writes under
; the user's own profile anyway.
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Beacle
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\..\dist\installer
OutputBaseFilename=beacle-setup-{#AppVersion}
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "polish"; MessagesFile: "compiler:Languages\Polish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "startup"; Description: "Start Beacle when I sign in"; GroupDescription: "Startup"; Flags: unchecked

[Files]
; Nothing is listed here on purpose. The payload arrives in [Code] via
; DownloadTemporaryFile and is unpacked in ssPostInstall — see below.

[Icons]
; The Start Menu shortcut is the one that matters: Windows Search indexes the
; Start Menu, so this is what makes the app findable by typing its name.
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; AppUserModelID: "{#AppUserModelID}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; AppUserModelID: "{#AppUserModelID}"; Tasks: desktopicon

[Registry]
; Same key the in-app Startup setting writes, so the two agree instead of
; fighting over the entry.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; \
    ValueName: "Beacle"; ValueData: """{app}\{#AppExeName}"""; Flags: uninsdeletevalue; Tasks: startup

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; \
    Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Files the app writes next to itself during updates; %AppData%\Beacle is
; deliberately left alone.
Type: filesandordirs; Name: "{app}\versions"
Type: files; Name: "{app}\apply-update.bat"
Type: files; Name: "{app}\rollback.bat"
Type: filesandordirs; Name: "{app}\data"

[Code]
var
  DownloadPage: TDownloadWizardPage;

procedure InitializeWizard;
begin
  DownloadPage := CreateDownloadPage(
    SetupMessage(msgWizardPreparing),
    'Beacle is being downloaded from GitHub.',
    nil);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID <> wpReady then
    Exit;

  DownloadPage.Clear;
  DownloadPage.Add('{#PayloadURL}', '{#PayloadAsset}', '');
  DownloadPage.Show;
  try
    try
      DownloadPage.Download;
    except
      // A failed download is worth saying out loud: the usual cause is a
      // release asset that was never uploaded, and a silent abort would send
      // the user hunting through their firewall instead.
      SuppressibleMsgBox(
        'Could not download Beacle from GitHub.' + #13#10 + #13#10 +
        GetExceptionMessage + #13#10 + #13#10 +
        'Check the connection, or download the archive by hand from' + #13#10 +
        '{#AppURL}/releases',
        mbCriticalError, MB_OK, IDOK);
      Result := False;
    end;
  finally
    DownloadPage.Hide;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  Archive: string;
begin
  if CurStep <> ssPostInstall then
    Exit;

  Archive := ExpandConstant('{tmp}\{#PayloadAsset}');

  // tar ships with Windows 10 1803 and later and reads zip, so unpacking needs
  // no bundled tool and no PowerShell execution policy argument.
  if not Exec(ExpandConstant('{sys}\tar.exe'), '-xf "' + Archive + '" -C "' +
              ExpandConstant('{app}') + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    SuppressibleMsgBox('Could not unpack the download: ' + SysErrorMessage(ResultCode),
      mbCriticalError, MB_OK, IDOK);
    Exit;
  end;
  if ResultCode <> 0 then
    SuppressibleMsgBox('Unpacking failed with code ' + IntToStr(ResultCode) + '.',
      mbCriticalError, MB_OK, IDOK);
end;
