; VyseTV's Windows installer (Inno Setup 6.3 or later).
;
; Made by scripts/make_release.py, which passes the version and where to write it:
;   ISCC /DAppVersion=1.0.0 /O<folder> windows\installer\vysetv.iss
;
; It installs for the current user only (no administrator prompt), into a folder VyseTV can
; write to. That is what lets the app update itself: it downloads the next installer, checks it
; against the signed release list, and runs it with /SILENT /relaunch=1.
;
; An update must never leave a copy that won't start. Three things see to that:
;   1. Before anything is changed, Setup waits for VyseTV to finish closing, closes it if it
;      doesn't, and checks that the files a running VyseTV holds are free. If they are not
;      (something else has them), it stops there: the old copy is still whole, and is started
;      again when the update was the app's own doing.
;   2. Those same files are replaced first, and Setup closes anything it finds holding any file.
;   3. Nothing is deleted ahead of the new files. (Deleting the old data folder first left a
;      copy without its assets when a later file turned out to be locked: found in a trial on
;      2026-11-14.)
;
; /DTrial builds a stand-in for testing updates: its own identity (so the real VyseTV on the PC
; is never touched), no shortcuts, a marker file where the real one would start the app, and
; its own name for "the app that may still be open" (scratch trials use a holder of that name).

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef Source
  #define Source "..\..\build\windows\x64\runner\Release"
#endif
; the program that may still be open when an update starts
#ifdef Trial
  #define Running "vysetv-trial-holder.exe"
#else
  #define Running "vyse_tv.exe"
#endif

[Setup]
#ifdef Trial
AppId={{F2A91D3C-0B77-4C1E-9D55-3A6E8B14C7D2}
AppName=VyseTV-Trial
DefaultDirName={autopf}\VyseTV-Trial
OutputBaseFilename=VyseTV-Trial-Setup
Compression=lzma2/fast
#else
; Never change this: it is how Windows knows a newer installer is the same app.
AppId={{7C1E5B0A-3D4F-4E86-9B2A-51F0C8D2A6E3}
AppName=VyseTV
AppVerName=VyseTV {#AppVersion}
DefaultDirName={autopf}\VyseTV
DefaultGroupName=VyseTV
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\vyse_tv.exe
UninstallDisplayName=VyseTV
OutputBaseFilename=VyseTV-Setup
Compression=lzma2/max
#endif
AppVersion={#AppVersion}
AppPublisher=VyseTV
AppSupportURL=https://discord.gg/dUJTGnUhz2
VersionInfoVersion={#AppVersion}
VersionInfoDescription=VyseTV Setup
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
WizardStyle=modern
SolidCompression=yes
LZMAUseSeparateProcess=yes
; An update finds VyseTV (and its torrent engine) still open now and then: close them, whatever
; kind of file they hold, and let the [Run] section below decide whether VyseTV starts again.
CloseApplications=force
CloseApplicationsFilter=*.*
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

#ifndef Trial
[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
#endif

[Files]
; First, the files a running VyseTV holds open. If one can't be replaced, Setup stops here and
; the copy on disk is still the old one, whole.
Source: "{#Source}\vyse_tv.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Source}\flutter_windows.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Source}\data\app.so"; DestDir: "{app}\data"; Flags: ignoreversion
; Then everything else.
Source: "{#Source}\*"; DestDir: "{app}"; Excludes: "*.lib,*.exp,*.pdb,*.ilk,\vyse_tv.exe,\flutter_windows.dll,\data\app.so"; Flags: ignoreversion recursesubdirs createallsubdirs

#ifndef Trial
[Icons]
; The same id the app gives Windows for its notifications, so they carry its name and icon.
Name: "{autoprograms}\VyseTV"; Filename: "{app}\vyse_tv.exe"; AppUserModelID: "Vyse.VyseTV"
Name: "{autodesktop}\VyseTV"; Filename: "{app}\vyse_tv.exe"; AppUserModelID: "Vyse.VyseTV"; Tasks: desktopicon
#endif

[Run]
#ifdef Trial
Filename: "{cmd}"; Parameters: "/c echo relaunched> ""{app}\relaunched.txt"""; Flags: runhidden; Check: RelaunchAsked
#else
; Installed by hand: the usual "Launch VyseTV" box on the last page.
Filename: "{app}\vyse_tv.exe"; Description: "{cm:LaunchProgram,VyseTV}"; Flags: nowait postinstall skipifsilent
; Run by VyseTV to update itself: start it again when the files are in place.
Filename: "{app}\vyse_tv.exe"; Flags: nowait; Check: RelaunchAsked
#endif

[Code]
function RelaunchAsked: Boolean;
begin
  Result := ExpandConstant('{param:relaunch|0}') = '1';
end;

// Whether nothing has the file open (it can be opened for writing, shared with nobody).
function IsFree(const Path: String): Boolean;
var
  Stream: TFileStream;
begin
  Result := True;
  if not FileExists(Path) then
    Exit;
  try
    Stream := TFileStream.Create(Path, fmOpenReadWrite or fmShareExclusive);
    Stream.Free;
  except
    Result := False;
  end;
end;

// The files a running VyseTV always has open.
function AppFilesFree: Boolean;
begin
  Result := IsFree(ExpandConstant('{app}\vyse_tv.exe'))
    and IsFree(ExpandConstant('{app}\flutter_windows.dll'))
    and IsFree(ExpandConstant('{app}\data\app.so'));
end;

function WaitForAppFiles(HalfSeconds: Integer): Boolean;
var
  Waited: Integer;
begin
  Waited := 0;
  while (Waited < HalfSeconds) and not AppFilesFree do
  begin
    Sleep(500);
    Waited := Waited + 1;
  end;
  Result := AppFilesFree;
end;

// Runs before anything is changed. An update is started by VyseTV itself, a moment before it
// closes: give it fifteen seconds to finish closing, close it if it hasn't, and if its files
// are still held after that (by something that isn't VyseTV), stop with the old copy whole.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Result := '';
  if WaitForAppFiles(30) then
    Exit;
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM {#Running}', '', SW_HIDE, ewWaitUntilTerminated, Code);
  if WaitForAppFiles(16) then
    Exit;
  Result := 'VyseTV''s files are in use by another program, so nothing was changed. Close it and run the update again.';
  if RelaunchAsked then
#ifdef Trial
    SaveStringToFile(ExpandConstant('{app}\old-copy-started-again.txt'), 'yes', False);
#else
    Exec(ExpandConstant('{app}\vyse_tv.exe'), '', '', SW_SHOWNORMAL, ewNoWait, Code);
#endif
end;
