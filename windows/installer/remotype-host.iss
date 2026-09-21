; Remotype Host — Windows installer (Inno Setup 6.3+)
; Build:  ISCC.exe /DMyAppVersion=1.0.4 installer\remotype-host.iss
; Expects: installer\..\dist\remotype-host-amd64.exe  (and -arm64.exe, optional)

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#define MyAppName    "Remotype Host"
#define MyAppExeName "remotype-host.exe"
#define MyAppPublisher "Custavia"
#define MyAppURL     "https://custavia.com/remotype"
; Mutex the app creates at startup (see Go snippet). Lets Setup detect a
; running instance instead of failing on a locked .exe.
#define MyAppMutex   "RemotypeHostSingleton"

[Setup]
; NEVER change AppId — it is what makes every future build an in-place upgrade
; rather than a second entry in Add/Remove Programs.
AppId={{8E1B2C74-2E5C-4C1B-9E2B-3F6A0D9C4A11}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
VersionInfoVersion={#MyAppVersion}

; {autopf} = "C:\Program Files\..." in admin mode,
;            "%LOCALAPPDATA%\Programs\..." in non-admin mode.
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
DisableDirPage=auto

; Default to per-machine (needed for the firewall rule); "dialog" lets the user
; downgrade to a per-user, UAC-free install on the first wizard page.
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog

; 6.3+ syntax. Drop the arm64 tokens if you only ship amd64.
ArchitecturesAllowed=x64compatible arm64
ArchitecturesInstallIn64BitMode=x64compatible arm64

; Ask the running tray app to exit before we overwrite its .exe.
AppMutex={#MyAppMutex}
CloseApplications=force
RestartApplications=no

UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
SetupIconFile=..\tray.ico
WizardStyle=modern
; 130 % of Inno's default. Two reasons, and the second is a real bug: the wizard
; was reported as cramped on a 150 %-scaled laptop, AND the task checkboxes were
; drawn CLIPPED — Inno sizes those rows from the wizard metrics, so a bigger
; wizard is what gives the checkbox glyph room to draw whole.
WizardSizePercent=130
; Let people make it bigger still. Costs nothing and is the only recourse when a
; translation or a long path overflows a page.
WizardResizable=yes

; The MILLED gradient, behind the wizard. Inno cannot skin the page bodies —
; those are system-themed controls — but the full-screen backdrop is ours, and
; it is what makes the installer read as part of the same product rather than a
; generic setup. Colours are $BBGGRR: deck 0x0D1526 and 0x070C18, the same two
; the phone's home screen and the host's windows use.
WindowVisible=yes
WindowShowCaption=no
WindowResizable=no
BackColor=$26150D
BackColor2=$180C07

; --- Branding ----------------------------------------------------------------
; Both sizes of each image so the wizard stays sharp on the HiDPI laptops most
; people install on; Inno picks per display scaling. Generated, reproducibly, by
; installer\make-wizard-art.py from the same wordmarks and palette the apps use.
; WizardImageStretch was ALREADY off, so the artwork was never being distorted
; — it was a small dark-navy rectangle centred on Inno's default light panel.
; That is what "the image looks out of place" is: a sticker on a white page.
; Painting the panel the same deck colour the artwork uses makes the seam
; vanish, so the logo reads as sitting on one surface at any wizard size.
; $BBGGRR of 0x0D1526, and make-wizard-art.py fills to exactly that colour.
WizardImageBackColor=$26150D
WizardSmallImageBackColor=$26150D
WizardImageFile=wizard-large.bmp,wizard-large@2x.bmp
WizardSmallImageFile=wizard-small.bmp,wizard-small@2x.bmp
WizardImageAlphaFormat=none

; --- The flow ----------------------------------------------------------------
; Deliberately short: Enter, Space to accept, Enter, Enter, done. Every page
; that remains earns its place — the licence because it must be shown, the
; directory because people move installs off C:, the tasks because the firewall
; rule and start-at-login are decisions with consequences. Everything else is
; off: no component picker, no Start-menu-folder page (one shortcut, one name),
; no "read the readme now" prompt, no post-install nag.
DisableWelcomePage=no
LicenseFile=LICENSE.txt
AllowNoIcons=yes
ShowLanguageDialog=no
DisableReadyPage=yes
DisableFinishedPage=no
SetupLogging=no
Compression=lzma2/max
SolidCompression=yes
OutputDir=..\dist
OutputBaseFilename=RemotypeHost-{#MyAppVersion}-setup
; MinVersion 10.0.15063 = Windows 10 1703, the floor for the
; PER-MONITOR-AWARE-V2 DPI context the host sets in dpi_windows.go init().
MinVersion=10.0.15063

[LangOptions]
; The wizard's font, and the reason it is here is the CHECKBOXES. Inno derives
; the task list's row height from the dialog font, and at the default 8pt on a
; scaled display the row is shorter than the themed checkbox glyph Windows
; draws into it — so the glyph is clipped, which is exactly what the tasks page
; was showing. A larger font makes the row taller than the glyph. It also makes
; the whole wizard readable from a normal sitting distance, which was the other
; half of the complaint.
DialogFontSize=10
WelcomeFontSize=14
TitleFontSize=32
CopyrightFontSize=10

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
; The Ready page is disabled, so "Next" on the tasks page starts the install.
; Saying so removes the only ambiguity the shortened flow introduces.
WizardSelectTasks=Ready to install
SelectTasksDesc=Choose how Remotype Host should behave, then click Install.
SelectTasksLabel2=Setup will install Remotype Host with these options:
ButtonNext=&Next
WelcomeLabel1=Remotype Host
WelcomeLabel2=This is the companion for the Remotype app on your phone. It lets your phone act as this computer's keyboard, trackpad and remote.%n%nIt runs quietly in your system tray.
FinishedHeadingLabel=Remotype Host is installed
FinishedLabelNoIcons=Look for the Remotype icon in your system tray, near the clock. Open the Remotype app on your phone and this computer will appear.
FinishedLabel=Look for the Remotype icon in your system tray, near the clock. Open the Remotype app on your phone and this computer will appear.

[Tasks]
Name: "desktopicon";  Description: "Create a &desktop shortcut"; \
  GroupDescription: "Additional shortcuts:"; Flags: unchecked
Name: "startatlogin"; Description: "Start {#MyAppName} when I &sign in"; \
  GroupDescription: "Startup:"
Name: "firewall";     Description: "Allow {#MyAppName} through Windows Firewall (&all network types)"; \
  GroupDescription: "Network:"; Check: IsAdminInstallMode

[Files]
; A native arm64 build is shipped only when one has been produced. Without this
; guard the compile fails on a missing file — and worse, keeping `Check: not
; IsArm64` on the amd64 line while no arm64 binary exists would install NOTHING
; on an ARM machine. amd64 runs fine there under emulation, so when there is no
; arm64 build the x64 one is installed unconditionally.
#if FileExists(AddBackslash(SourcePath) + "..\dist\remotype-host-arm64.exe")
Source: "..\dist\remotype-host-amd64.exe"; DestDir: "{app}"; DestName: "{#MyAppExeName}"; \
  Flags: ignoreversion; Check: not IsArm64
Source: "..\dist\remotype-host-arm64.exe"; DestDir: "{app}"; DestName: "{#MyAppExeName}"; \
  Flags: ignoreversion; Check: IsArm64
#else
Source: "..\dist\remotype-host-amd64.exe"; DestDir: "{app}"; DestName: "{#MyAppExeName}"; \
  Flags: ignoreversion
#endif
Source: "..\README.md"; DestDir: "{app}"; DestName: "README.txt"; Flags: ignoreversion isreadme
; Apache-2.0 section 4(a) asks that every recipient of a binary gets a copy of
; the licence, so it is installed next to the program. The copy lives in this
; directory rather than at the repository root so that an installer kit holding
; only windows\ still compiles.
Source: "APACHE-LICENSE-2.0.txt"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}";  Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
; Run-at-login: ALWAYS HKCU, never HKLM. An HKLM Run value would launch a second
; host for every account that signs in; the loser of the race to TCP 50808 falls
; back to an ephemeral port and both advertise _hsbtk._tcp, so the phone sees two
; identical "Remotype Host (PC)" entries.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
  ValueType: string; ValueName: "RemotypeHost"; \
  ValueData: """{app}\{#MyAppExeName}"""; \
  Flags: uninsdeletevalue; Tasks: startatlogin
; Not selected -> make sure a value from a previous install is removed.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
  ValueType: none; ValueName: "RemotypeHost"; \
  Flags: deletevalue uninsdeletevalue; Tasks: not startatlogin
; Breadcrumb so a future installer/uninstaller can find this install.
Root: HKA; Subkey: "Software\Custavia\Remotype Host"; ValueType: string; \
  ValueName: "InstallPath"; ValueData: "{app}"; Flags: uninsdeletekey

[Run]
; --- Firewall -----------------------------------------------------------------
; PROGRAM-scoped, not port-scoped: main.go falls back to an ephemeral port when
; 50808 is taken, and mDNS needs inbound UDP 5353 as well. A localport=50808 rule
; would cover neither case. profile=any, deliberately: Windows classes every new
; Wi-Fi as Public, so a private/domain-only rule left the host "listening" but
; unreachable from the LAN the moment someone used it at a friend's place — the
; phone saw the mDNS advert, the connect timed out, and nothing said why. The
; app has no business working only on networks Windows already trusts.
; Delete-then-add makes re-running the installer idempotent.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Remotype Host (TCP-In)"""; \
  Flags: runhidden waituntilterminated; Check: WizardIsTaskSelected('firewall')
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Remotype Host (UDP-In)"""; \
  Flags: runhidden waituntilterminated; Check: WizardIsTaskSelected('firewall')
Filename: "{sys}\netsh.exe"; \
  Parameters: "advfirewall firewall add rule name=""Remotype Host (TCP-In)"" dir=in action=allow program=""{app}\{#MyAppExeName}"" protocol=TCP profile=any enable=yes"; \
  StatusMsg: "Adding Windows Firewall rules..."; \
  Flags: runhidden waituntilterminated; Check: WizardIsTaskSelected('firewall')
Filename: "{sys}\netsh.exe"; \
  Parameters: "advfirewall firewall add rule name=""Remotype Host (UDP-In)"" dir=in action=allow program=""{app}\{#MyAppExeName}"" protocol=UDP profile=any enable=yes"; \
  Flags: runhidden waituntilterminated; Check: WizardIsTaskSelected('firewall')

; --- Launch -------------------------------------------------------------------
; runasoriginaluser is REQUIRED. Without it the tray app inherits the elevated
; installer token and runs as admin for the rest of the session.
Filename: "{app}\{#MyAppExeName}"; Description: "Start {#MyAppName} now"; \
  Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM {#MyAppExeName}"; \
  Flags: runhidden waituntilterminated; RunOnceId: "KillHost"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Remotype Host (TCP-In)"""; \
  Flags: runhidden waituntilterminated; RunOnceId: "DelFwTcp"; Check: IsAdminInstallMode
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Remotype Host (UDP-In)"""; \
  Flags: runhidden waituntilterminated; RunOnceId: "DelFwUdp"; Check: IsAdminInstallMode

[UninstallDelete]
; os.UserConfigDir() -> %APPDATA%; initLog() writes RemotypeHost\host.log there.
Type: filesandordirs; Name: "{userappdata}\RemotypeHost"
; os.UserCacheDir() -> %LOCALAPPDATA%; identity.bin, devices.json (the paired
; phones) and the setup-shown marker live in "Remotype Host" there. A complete
; uninstall forgets the pairings; a reinstall starts as a new host.
Type: filesandordirs; Name: "{localappdata}\Remotype Host"

; ==============================================================================
[Code]
var
  StalePage: TInputOptionWizardPage;
  StalePaths: TStringList;

function IsOurExe(const Path: String): Boolean;
var S: String;
begin
  { Once a VERSIONINFO resource is embedded (goversioninfo), this becomes a
    real identity check. Until then it degrades to a name check. }
  Result := False;
  if not FileExists(Path) then Exit;
  { GetVersionNumbersString returns a Boolean and writes through a var param —
    it is not a string-returning function. }
  if GetVersionNumbersString(Path, S) then
    Result := True
  else
    Result := (Lowercase(ExtractFileName(Path)) = Lowercase('{#MyAppExeName}'));
end;

{ Deliberately does NOT compare against the app directory: this runs from
  InitializeWizard, where that constant is not initialized yet — expanding it
  there aborted Setup before the wizard drew a single page. The install target
  is Program Files or the per-user Programs folder, which none of the scanned
  directories can be, and CurStepChanged skips the installed path when it
  comes to delete. Note: braces are comment delimiters and do not nest, so a
  constant written in braces inside a comment ends it early. }
procedure AddIfStale(const Path: String);
begin
  if IsOurExe(Path) then
    StalePaths.Add(Path);
end;

{ Downloads is built from the profile path on purpose: Inno has no Downloads
  constant, and the one this originally used did not exist. It crashed
  InitializeWizard before the wizard ever drew, so a silent install exited 1
  having done nothing at all — the failure mode of a bad constant is total. }
procedure ScanForStaleCopies;
var FR: TFindRec; Dir: String; Dirs: TArrayOfString; I: Integer;
begin
  StalePaths := TStringList.Create;
  Dirs := [ 'C:\remotype',
            ExpandConstant('{userdesktop}'),
            ExpandConstant('{commondesktop}'),
            AddBackslash(ExpandConstant('{%USERPROFILE}')) + 'Downloads',
            ExpandConstant('{userstartup}') ];
  for I := 0 to GetArrayLength(Dirs) - 1 do begin
    Dir := Dirs[I];
    if Dir = '' then Continue;
    if FindFirst(AddBackslash(Dir) + '*.exe', FR) then try
      repeat
        if Pos('remotype', Lowercase(FR.Name)) > 0 then
          AddIfStale(AddBackslash(Dir) + FR.Name);
      until not FindNext(FR);
    finally FindClose(FR); end;
  end;
end;

{ Give every checkbox list room to draw its glyph whole.

  The themed checkbox Windows paints into a TNewCheckListBox row is drawn hard
  against the item's left edge, and on a scaled display its left few pixels were
  being cut off — reported four times now, so the mechanism is worth writing
  down.

  `Offset` is the lever. It is the per-level indent, and Inno's tasks page puts
  every checkbox at level 1 under a group heading ("Additional shortcuts:").
  With a small offset the glyph starts left of where the control will draw and
  loses its rounded edge; a real indent moves the whole item right and the glyph
  draws whole. Moving `Left` does NOT work — it shifts the control and the
  clipped glyph together.

  MinItemHeight is deliberately NOT touched. A taller row gets a larger themed
  glyph, and if the glyph is overflowing the space reserved for it then making
  it bigger is the wrong direction — that attempt is why the third try looked
  identical rather than better.

  And the timing matters as much as the property: Inno populates and lays the
  tasks list out AFTER InitializeWizard runs, so setting this there was silently
  discarded before the page ever drew. That is why three earlier attempts
  changed nothing on screen. It has to happen when the page is shown. }
procedure PadCheckList(List: TNewCheckListBox);
begin
  if List = nil then Exit;
  List.Offset := ScaleX(20);
end;

procedure InitializeWizard;
var I: Integer;
begin
  ScanForStaleCopies;
  if StalePaths.Count = 0 then Exit;
  StalePage := CreateInputOptionPage(wpSelectTasks,
    'Older copies found',
    'Setup found other copies of Remotype Host on this PC.',
    'Leaving them in place causes trouble: whichever copy starts first takes TCP port 50808,'
    + ' both advertise the same Bonjour name, and they share one log file. Uncheck anything'
    + ' you want to keep.',
    False, False);
  for I := 0 to StalePaths.Count - 1 do begin
    StalePage.Add(StalePaths[I]);
    StalePage.Values[I] := True;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var Code: Integer;
begin
  { AppMutex already offered a polite close; force it so the .exe is unlocked. }
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM {#MyAppExeName}', '',
       SW_HIDE, ewWaitUntilTerminated, Code);
  Result := '';
end;

{ See PadCheckList: this is the only moment the list has been laid out and has
  not yet been drawn. }
procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpSelectTasks then
    PadCheckList(WizardForm.TasksList)
  else if CurPageID = wpSelectComponents then
    PadCheckList(WizardForm.ComponentsList)
  else if (StalePage <> nil) and (CurPageID = StalePage.ID) then
    PadCheckList(StalePage.CheckListBox);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var I, Code: Integer; P: String;
begin
  if CurStep <> ssPostInstall then Exit;
  if StalePage = nil then Exit;
  for I := 0 to StalePaths.Count - 1 do begin
    if not StalePage.Values[I] then Continue;
    P := StalePaths[I];
    { Never delete the copy just installed; the app constant is valid by now. }
    if CompareText(P, ExpandConstant('{app}\{#MyAppExeName}')) = 0 then Continue;
    { Windows auto-generated firewall rules are keyed to the exe PATH, so a
      stale copy leaves behind its own allow -- or worse, block -- rules. }
    if IsAdminInstallMode then
      Exec(ExpandConstant('{sys}\netsh.exe'),
           'advfirewall firewall delete rule name=all program="' + P + '"',
           '', SW_HIDE, ewWaitUntilTerminated, Code);
    DeleteFile(P);
    { Startup-folder shortcut pointing at the stale copy. }
    DeleteFile(ExpandConstant('{userstartup}\') + ChangeFileExt(ExtractFileName(P), '.lnk'));
  end;
end;
