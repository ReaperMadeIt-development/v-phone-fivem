; ReaperLink Voice Tester - proper Windows setup wizard
; Builds ReaperLink-Voice-Tester-Setup.exe with Inno Setup 6.

#define MyAppName "ReaperLink Voice Tester"
#define MyAppVersion "0.1.0-preview"
#define MyAppPublisher "ReaperMadeIt"
#define MyAppURL "https://github.com/ReaperMadeIt-development/v-phone-fivem"

[Setup]
AppId={{D79F4B9C-0A15-4AE8-AB8C-576F34382526}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={tmp}\ReaperLinkVoiceTester
CreateAppDir=no
Uninstallable=no
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
WizardResizable=no
DisableProgramGroupPage=yes
DisableReadyMemo=no
LicenseFile=..\LICENSE
OutputDir=..\dist
OutputBaseFilename=ReaperLink-Voice-Tester-Setup
Compression=lzma2/ultra64
SolidCompression=yes
SetupLogging=yes
ShowLanguageDialog=no
VersionInfoVersion=0.1.0.0
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription=ReaperLink Voice FiveM Tester Installer
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}

[Files]
Source: "ReaperLink-InstallCore.ps1"; DestDir: "{tmp}\ReaperLinkSetup"; Flags: ignoreversion deleteafterinstall
Source: "README-TESTERS.txt"; DestDir: "{tmp}\ReaperLinkSetup"; Flags: ignoreversion deleteafterinstall
Source: "TEST-CHECKLIST.txt"; DestDir: "{tmp}\ReaperLinkSetup"; Flags: ignoreversion deleteafterinstall

Source: "..\fxmanifest.lua"; DestDir: "{tmp}\ReaperLinkSetup\resource\v-phone"; Flags: ignoreversion deleteafterinstall
Source: "..\config.lua"; DestDir: "{tmp}\ReaperLinkSetup\resource\v-phone"; Flags: ignoreversion deleteafterinstall
Source: "..\LICENSE"; DestDir: "{tmp}\ReaperLinkSetup\resource\v-phone"; Flags: ignoreversion deleteafterinstall
Source: "..\NOTICE"; DestDir: "{tmp}\ReaperLinkSetup\resource\v-phone"; Flags: ignoreversion deleteafterinstall
Source: "..\THIRD_PARTY_NOTICES.md"; DestDir: "{tmp}\ReaperLinkSetup\resource\v-phone"; Flags: ignoreversion deleteafterinstall
Source: "..\REAPERLINK_SETUP.md"; DestDir: "{tmp}\ReaperLinkSetup\resource\v-phone"; Flags: ignoreversion deleteafterinstall
Source: "..\REAPERLINK_VOICE_LIVE_TEST.md"; DestDir: "{tmp}\ReaperLinkSetup\resource\v-phone"; Flags: ignoreversion deleteafterinstall

Source: "..\apps\*"; DestDir: "{tmp}\ReaperLinkSetup\resource\v-phone\apps"; Flags: ignoreversion recursesubdirs createallsubdirs deleteafterinstall
Source: "..\bridge\*"; DestDir: "{tmp}\ReaperLinkSetup\resource\v-phone\bridge"; Flags: ignoreversion recursesubdirs createallsubdirs deleteafterinstall
Source: "..\client\*"; DestDir: "{tmp}\ReaperLinkSetup\resource\v-phone\client"; Flags: ignoreversion recursesubdirs createallsubdirs deleteafterinstall
Source: "..\compat\*"; DestDir: "{tmp}\ReaperLinkSetup\resource\v-phone\compat"; Flags: ignoreversion recursesubdirs createallsubdirs deleteafterinstall
Source: "..\docs\*"; DestDir: "{tmp}\ReaperLinkSetup\resource\v-phone\docs"; Flags: ignoreversion recursesubdirs createallsubdirs deleteafterinstall
Source: "..\html\*"; DestDir: "{tmp}\ReaperLinkSetup\resource\v-phone\html"; Flags: ignoreversion recursesubdirs createallsubdirs deleteafterinstall
Source: "..\locales\*"; DestDir: "{tmp}\ReaperLinkSetup\resource\v-phone\locales"; Flags: ignoreversion recursesubdirs createallsubdirs deleteafterinstall
Source: "..\server\*"; DestDir: "{tmp}\ReaperLinkSetup\resource\v-phone\server"; Flags: ignoreversion recursesubdirs createallsubdirs deleteafterinstall
Source: "..\sounds\*"; DestDir: "{tmp}\ReaperLinkSetup\resource\v-phone\sounds"; Flags: ignoreversion recursesubdirs createallsubdirs deleteafterinstall

[Code]
var
  ServerPage: TInputDirWizardPage;
  HttpsPage: TInputOptionWizardPage;
  PublicUrlPage: TInputQueryWizardPage;
  VoicePage: TInputQueryWizardPage;
  ReviewPage: TOutputMsgWizardPage;
  ServerDataPath: string;
  PublicUrlValue: string;
  InstallLogPath: string;
  InstallSucceeded: Boolean;

function JsonEscape(Value: string): string;
begin
  StringChangeEx(Value, '\', '\\', True);
  StringChangeEx(Value, '"', '\"', True);
  StringChangeEx(Value, #13#10, '\n', True);
  StringChangeEx(Value, #10, '\n', True);
  Result := Value;
end;

function IsValidServerData(Path: string): Boolean;
begin
  Result :=
    DirExists(Path) and
    FileExists(AddBackslash(Path) + 'server.cfg') and
    DirExists(AddBackslash(Path) + 'resources');
end;

procedure UpdateReview;
var
  ModeText: string;
  UrlText: string;
  VoiceText: string;
begin
  if HttpsPage.SelectedValueIndex = 0 then
  begin
    ModeText := 'Temporary Cloudflare HTTPS Quick Tunnel';
    UrlText := 'The installer will create the HTTPS address automatically.';
  end
  else
  begin
    ModeText := 'Existing HTTPS address';
    UrlText := PublicUrlPage.Values[0];
  end;

  VoiceText := 'Default / same-network settings';
  if (VoicePage.Values[0] <> '') or (VoicePage.Values[1] <> '') then
    VoiceText := 'Custom STUN/TURN settings';

  ReviewPage.Msg :=
    'Server data folder:' + #13#10 +
    '  ' + ServerPage.Values[0] + #13#10#13#10 +
    'HTTPS mode:' + #13#10 +
    '  ' + ModeText + #13#10 +
    '  ' + UrlText + #13#10#13#10 +
    'Voice networking:' + #13#10 +
    '  ' + VoiceText + #13#10#13#10 +
    'Safety:' + #13#10 +
    '  Existing v-phone and server.cfg will be backed up first.' + #13#10 +
    '  Existing v-phone config.lua will be preserved.' + #13#10 +
    '  A ReaperLink-Rollback.ps1 script will be created.' + #13#10#13#10 +
    'This is a TEST / PREVIEW build. Stop the FiveM server in txAdmin before clicking Install when possible.';
end;

procedure HttpsModeChanged(Sender: TObject);
begin
  PublicUrlPage.Edits[0].Enabled := HttpsPage.SelectedValueIndex = 1;
end;

procedure InitializeWizard;
begin
  WizardForm.Caption := 'ReaperLink Voice Tester Setup';

  ServerPage := CreateInputDirPage(
    wpSelectDir,
    'FiveM Server',
    'Choose the FiveM server-data folder',
    'Select the folder containing both server.cfg and the resources folder.' + #13#10 +
    'Example: E:\testserver\file'
  );
  ServerPage.Add('');
  if IsValidServerData('E:\testserver\file') then
    ServerPage.Values[0] := 'E:\testserver\file';

  HttpsPage := CreateInputOptionPage(
    ServerPage.ID,
    'Physical Phone HTTPS',
    'Choose how the real phone reaches ReaperLink',
    'Voice microphone access requires HTTPS. For testing, the automatic temporary tunnel is the easiest option.',
    True,
    False
  );
  HttpsPage.Add('Create a temporary Cloudflare HTTPS Quick Tunnel automatically');
  HttpsPage.Add('Use an existing public HTTPS address');
  HttpsPage.SelectedValueIndex := 0;
  HttpsPage.CheckListBox.OnClickCheck := @HttpsModeChanged;

  PublicUrlPage := CreateInputQueryPage(
    HttpsPage.ID,
    'Existing HTTPS Address',
    'Enter the public ReaperLink address',
    'Only used when "existing public HTTPS address" was selected. You may enter the site root or the full /v-phone/physical URL.'
  );
  PublicUrlPage.Add('HTTPS URL:', False);

  VoicePage := CreateInputQueryPage(
    PublicUrlPage.ID,
    'Voice Networking',
    'Optional STUN / TURN settings',
    'Leave these blank for initial same-network testing. For reliable cross-network testing, use server-operator-controlled STUN/TURN.'
  );
  VoicePage.Add('STUN URL:', False);
  VoicePage.Add('TURN URL:', False);
  VoicePage.Add('TURN username:', False);
  VoicePage.Add('TURN password:', True);

  ReviewPage := CreateOutputMsgPage(
    VoicePage.ID,
    'Ready to Install',
    'Review the ReaperLink tester setup',
    ''
  );

  InstallSucceeded := False;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if (PageID = PublicUrlPage.ID) and (HttpsPage.SelectedValueIndex = 0) then
    Result := True;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  P: string;
  U: string;
begin
  Result := True;

  if CurPageID = ServerPage.ID then
  begin
    P := ServerPage.Values[0];
    if not IsValidServerData(P) then
    begin
      MsgBox(
        'That folder does not contain both server.cfg and resources.' + #13#10#13#10 +
        'Choose the FiveM server-data folder, not the FXServer program folder.',
        mbError,
        MB_OK
      );
      Result := False;
      Exit;
    end;
  end;

  if CurPageID = PublicUrlPage.ID then
  begin
    U := Trim(PublicUrlPage.Values[0]);
    if Pos('https://', Lowercase(U)) <> 1 then
    begin
      MsgBox('The public ReaperLink address must begin with https://', mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;

  if CurPageID = VoicePage.ID then
    UpdateReview;
end;

function PrepareToInstall(var NeedsRestart: Boolean): string;
var
  OptionsPath: string;
  OptionsText: string;
  ModeText: string;
begin
  Result := '';
  ServerDataPath := ServerPage.Values[0];

  if HttpsPage.SelectedValueIndex = 0 then
  begin
    ModeText := 'quick';
    PublicUrlValue := '';
  end
  else
  begin
    ModeText := 'manual';
    PublicUrlValue := Trim(PublicUrlPage.Values[0]);
  end;

  ForceDirectories(ExpandConstant('{tmp}\ReaperLinkSetup'));
  OptionsPath := ExpandConstant('{tmp}\ReaperLinkSetup\install-options.json');
  InstallLogPath := AddBackslash(ServerDataPath) + 'reaperlink-installer.log';

  OptionsText :=
    '{' +
    '"serverData":"' + JsonEscape(ServerDataPath) + '",' +
    '"httpsMode":"' + ModeText + '",' +
    '"publicUrl":"' + JsonEscape(PublicUrlValue) + '",' +
    '"stun":"' + JsonEscape(VoicePage.Values[0]) + '",' +
    '"turnUrl":"' + JsonEscape(VoicePage.Values[1]) + '",' +
    '"turnUser":"' + JsonEscape(VoicePage.Values[2]) + '",' +
    '"turnPass":"' + JsonEscape(VoicePage.Values[3]) + '"' +
    '}';

  if not SaveStringToFile(OptionsPath, OptionsText, False) then
    Result := 'Could not write the temporary ReaperLink installer configuration.';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  PowerShellPath: string;
  CorePath: string;
  OptionsPath: string;
  PayloadPath: string;
  Params: string;
begin
  if CurStep = ssPostInstall then
  begin
    WizardForm.StatusLabel.Caption := 'Installing ReaperLink into the FiveM server...';

    PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
    CorePath := ExpandConstant('{tmp}\ReaperLinkSetup\ReaperLink-InstallCore.ps1');
    OptionsPath := ExpandConstant('{tmp}\ReaperLinkSetup\install-options.json');
    PayloadPath := ExpandConstant('{tmp}\ReaperLinkSetup\resource\v-phone');

    Params :=
      '-NoProfile -ExecutionPolicy Bypass -File "' + CorePath + '"' +
      ' -OptionsPath "' + OptionsPath + '"' +
      ' -PayloadRoot "' + PayloadPath + '"' +
      ' -LogPath "' + InstallLogPath + '"';

    if not Exec(PowerShellPath, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      RaiseException('Could not launch the ReaperLink installation engine.');

    if ResultCode <> 0 then
      RaiseException(
        'ReaperLink installation failed.' + #13#10#13#10 +
        'Log:' + #13#10 + InstallLogPath
      );

    InstallSucceeded := True;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
var
  ResultFile: string;
  ResultText: AnsiString;
  UrlLine: string;
begin
  if (CurPageID = wpFinished) and InstallSucceeded then
  begin
    UrlLine := '';
    ResultFile := AddBackslash(ServerDataPath) + 'reaperlink-install-result.txt';
    if LoadStringFromFile(ResultFile, ResultText) then
      UrlLine := String(ResultText);

    WizardForm.FinishedLabel.Caption :=
      'ReaperLink Voice Tester has been installed.' + #13#10#13#10 +
      'Next:' + #13#10 +
      '1. Start or restart the FiveM server.' + #13#10 +
      '2. Join the server.' + #13#10 +
      '3. Run /physicalpair.' + #13#10 +
      '4. Scan the QR code with the real phone.' + #13#10 +
      '5. For a solo hardware test run /reaperlinkvoicetest.' + #13#10#13#10 +
      'Rollback: ReaperLink-Rollback.ps1 was created in the server-data folder.' + #13#10#13#10 +
      UrlLine;
  end;
end;
