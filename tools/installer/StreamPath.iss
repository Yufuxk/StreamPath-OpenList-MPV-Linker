[Setup]
AppId={{B71DF9AF-23E5-4C52-9ADB-D465BE79F50E}
AppName=StreamPath
AppVersion={#AppVersion}
AppVerName=StreamPath {#DisplayVersion}
AppPublisher=Yufuxk
AppPublisherURL=https://github.com/Yufuxk/StreamPath-OpenList-MPV-Linker
AppSupportURL=https://github.com/Yufuxk/StreamPath-OpenList-MPV-Linker/issues
DefaultDirName={localappdata}\Programs\StreamPath
DefaultGroupName=StreamPath
DisableProgramGroupPage=yes
AllowNoIcons=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
VersionInfoVersion={#WindowsVersion}
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\streampath.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no
AppMutex={code:ApplicationMutex}
Uninstallable=not IsStaging
CreateUninstallRegKey=not IsStaging
UninstallFilesDir={app}
UsePreviousAppDir=yes

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "zh_CN"; MessagesFile: "languages\ChineseSimplified.isl"
Name: "zh_TW"; MessagesFile: "languages\ChineseTraditional.isl"
Name: "ja"; MessagesFile: "compiler:Languages\Japanese.isl"

[CustomMessages]
en.EmptyDirectory=Choose an empty installation directory.
en.PortableDirectory=Choose a separate installation directory. This directory contains a portable StreamPath copy.
en.NewerInstalled=A newer StreamPath version is already installed. Downgrading is not supported.
en.MarkerFailure=Could not write the StreamPath installation marker.
zh_CN.EmptyDirectory=请选择空的安装目录。
zh_CN.PortableDirectory=此目录包含 StreamPath 便携版，请选择其他安装目录。
zh_CN.NewerInstalled=已安装更高版本的 StreamPath，不支持降级安装。
zh_CN.MarkerFailure=无法写入 StreamPath 安装标记。
zh_TW.EmptyDirectory=請選擇空的安裝目錄。
zh_TW.PortableDirectory=此目錄包含 StreamPath 可攜版，請選擇其他安裝目錄。
zh_TW.NewerInstalled=已安裝更高版本的 StreamPath，不支援降級安裝。
zh_TW.MarkerFailure=無法寫入 StreamPath 安裝標記。
ja.EmptyDirectory=空のインストール先を選択してください。
ja.PortableDirectory=このフォルダーには StreamPath のポータブル版があります。別のインストール先を選択してください。
ja.NewerInstalled=新しいバージョンの StreamPath がインストールされています。ダウングレードには対応していません。
ja.MarkerFailure=StreamPath のインストールマーカーを書き込めませんでした。

[Tasks]
Name: desktopicon; Description: "{cm:CreateDesktopIcon}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "*.pdb,streampath-installed,stream_path_data\*"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\StreamPath"; Filename: "{app}\streampath.exe"; WorkingDir: "{app}"; Check: not IsStaging and not WizardNoIcons
Name: "{autodesktop}\StreamPath"; Filename: "{app}\streampath.exe"; WorkingDir: "{app}"; Tasks: desktopicon; Check: not IsStaging

[Run]
Filename: "{app}\streampath.exe"; Description: "{cm:LaunchProgram,StreamPath}"; Flags: nowait postinstall skipifsilent; Check: not IsStaging

[Code]
function IsStaging: Boolean;
begin
  Result := ExpandConstant('{param:STREAMPATH-STAGE|0}') = '1';
end;

function ApplicationMutex(Param: String): String;
begin
  if IsStaging then Result := ''
  else Result := 'Local\StreamPath.SingleInstance';
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  AppDir, ExistingExe: String;
  OldMS, OldLS, NewMS, NewLS: Cardinal;
  Existing: TFindRec;
begin
  Result := '';
  if IsStaging then Exit;
  AppDir := ExpandConstant('{app}');
  ExistingExe := AppDir + '\streampath.exe';
  if not FileExists(ExistingExe) and DirExists(AppDir) then begin
    if FindFirst(AppDir + '\*', Existing) then begin
      try
        repeat
          if (Existing.Name <> '.') and (Existing.Name <> '..') then begin
            Result := CustomMessage('EmptyDirectory');
            Exit;
          end;
        until not FindNext(Existing);
      finally
        FindClose(Existing);
      end;
    end;
  end;
  if FileExists(ExistingExe) and not FileExists(AppDir + '\streampath-installed') then begin
    Result := CustomMessage('PortableDirectory');
    Exit;
  end;
  if FileExists(ExistingExe) and GetVersionNumbers(ExistingExe, OldMS, OldLS) then begin
    if GetVersionNumbers(ExpandConstant('{srcexe}'), NewMS, NewLS) then
      if (OldMS > NewMS) or ((OldMS = NewMS) and (OldLS > NewLS)) then
        Result := CustomMessage('NewerInstalled');
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and not IsStaging then
    if not SaveStringToFile(ExpandConstant('{app}\streampath-installed'), '', False) then
      RaiseException(CustomMessage('MarkerFailure'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    DeleteFile(ExpandConstant('{app}\streampath-installed'));
end;
