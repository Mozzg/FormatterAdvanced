unit uConsoleHelper;

interface

uses
  WinAPI.Windows, System.SysUtils;

type
  TConsoleColorAttribute = (
    ccaIntensify = 0,
    ccaRed = 1,
    ccaGreen = 2,
    ccaBlue = 3
  );
  TConsoleColorAttributes = set of TConsoleColorAttribute;

const
  ccYellow: TConsoleColorAttributes = [ccaRed, ccaGreen, ccaIntensify];
  ccOrange: TConsoleColorAttributes = [ccaRed, ccaGreen];
  ccRed: TConsoleColorAttributes = [ccaRed];
  ccGreen: TConsoleColorAttributes = [ccaGreen];

type
  TConsoleHelper = class(TObject)
  private
    fConsoleWindowHandle: THandle;
    fConsoleOutputHandle: THandle;
    fConsoleScreenBufferInfo: TConsoleScreenBufferInfo;
    fNeedToRestoreConsole: Boolean;

    function GetConsoleCursorCoord: TCoord;
    procedure SetConsoleCursorCoord(const aNewCoord: TCoord);

    function IsOwnsConsole: Boolean;
    procedure SetConsoleColors(aTextColor: TConsoleColorAttributes; aBackgroundColor: TConsoleColorAttributes = []);
    procedure ResetConsoleColorsToDefault;
  public
    constructor Create;
    destructor Destroy; override;

    procedure LogTextWithColor(const aText: string; aTextColor: TConsoleColorAttributes; aBackgroundColor: TConsoleColorAttributes = []);

    procedure LogAndWaitAtExit;
    procedure LogAppHeader;
    procedure LogUsage;

    procedure LogTest;

    property CurrentCursorCoord: TCoord read GetConsoleCursorCoord write SetConsoleCursorCoord;
  end;

implementation

{ TConsoleHelper }

constructor TConsoleHelper.Create;
begin
  inherited Create;

  fConsoleWindowHandle := GetConsoleWindow;
  if fConsoleWindowHandle = 0 then
    raise Exception.Create('Console window not found');

  fConsoleOutputHandle := GetStdHandle(STD_OUTPUT_HANDLE);
  if fConsoleOutputHandle = INVALID_HANDLE_VALUE then
    raise Exception.Create('Failed to retrieve console output handle');

  if not GetConsoleScreenBufferInfo(fConsoleOutputHandle, fConsoleScreenBufferInfo) then
    raise Exception.Create('Failed to retrieve console info');
  fNeedToRestoreConsole := True;
end;

destructor TConsoleHelper.Destroy;
begin
  if fNeedToRestoreConsole and (fConsoleOutputHandle <> INVALID_HANDLE_VALUE) then
    ResetConsoleColorsToDefault;

  inherited Destroy;
end;

function TConsoleHelper.GetConsoleCursorCoord: TCoord;
var
  lScreenBuffer: TConsoleScreenBufferInfo;
begin
  if not GetConsoleScreenBufferInfo(fConsoleOutputHandle, lScreenBuffer) then
    raise Exception.Create('Failed to retrieve console info when getting cursor coordinates');

  Result := lScreenBuffer.dwCursorPosition;
end;

procedure TConsoleHelper.SetConsoleCursorCoord(const aNewCoord: TCoord);
begin
  if not SetConsoleCursorPosition(fConsoleOutputHandle, aNewCoord) then
    raise Exception.Create('Failed to set new cursor coordinates');
end;

function TConsoleHelper.IsOwnsConsole: Boolean;
var
  lPID: DWORD;
begin
  if GetWindowThreadProcessId(fConsoleWindowHandle, lPID) = 0 then
    raise Exception.Create('Error retrieving console owner process ID');
  Result := (lPID = GetCurrentProcessId);
end;

procedure TConsoleHelper.SetConsoleColors(aTextColor: TConsoleColorAttributes; aBackgroundColor: TConsoleColorAttributes = []);
const
  TEXT_COLOR_ATTRIBUTE: array[TConsoleColorAttribute] of Word = (
    FOREGROUND_INTENSITY,
    FOREGROUND_RED,
    FOREGROUND_GREEN,
    FOREGROUND_BLUE
  );
  BACKGROUND_COLOR_ATTRIBUTE: array[TConsoleColorAttribute] of Word = (
    BACKGROUND_INTENSITY,
    BACKGROUND_RED,
    BACKGROUND_GREEN,
    BACKGROUND_BLUE
  );
var
  lAttr: TConsoleColorAttribute;
  lNewColorAttr: Word;
begin
  lNewColorAttr := 0;
  for lAttr := Low(TConsoleColorAttribute) to High(TConsoleColorAttribute) do
  begin
    if lAttr in aTextColor then
      lNewColorAttr := lNewColorAttr or TEXT_COLOR_ATTRIBUTE[lAttr];
    if lAttr in aBackgroundColor then
      lNewColorAttr := lNewColorAttr or BACKGROUND_COLOR_ATTRIBUTE[lAttr];
  end;

  SetConsoleTextAttribute(fConsoleOutputHandle, lNewColorAttr);
end;

procedure TConsoleHelper.ResetConsoleColorsToDefault;
begin
  SetConsoleTextAttribute(fConsoleOutputHandle, fConsoleScreenBufferInfo.wAttributes);
end;

procedure TConsoleHelper.LogTextWithColor(const aText: string; aTextColor: TConsoleColorAttributes; aBackgroundColor: TConsoleColorAttributes = []);
begin
  SetConsoleColors(aTextColor, aBackgroundColor);
  Write(aText);
  ResetConsoleColorsToDefault;
end;

procedure TConsoleHelper.LogAndWaitAtExit;
begin
  ResetConsoleColorsToDefault;
  if not IsOwnsConsole then Exit;

  WriteLn;
  Write('Press ENTER to continue');
  ReadLn;
end;

procedure TConsoleHelper.LogAppHeader;
const
  APPLICATION_HEADER: array[0..1] of string = (
    'Advanced Delphi formatter',
    'by Mozzg'
  );
var
  lOutputLine: string;
  i, lWindowWidth: Integer;
begin
  lWindowWidth := fConsoleScreenBufferInfo.srWindow.Right - fConsoleScreenBufferInfo.srWindow.Left + 1;

  SetConsoleColors(ccGreen);
  for i := Low(APPLICATION_HEADER) to High(APPLICATION_HEADER) do
  begin
    lOutputLine := APPLICATION_HEADER[i];
    lOutputLine := StringOfChar(' ', (lWindowWidth - Length(lOutputLine)) div 2) + lOutputLine;
    if i <> Low(APPLICATION_HEADER) then
      WriteLn;
    Write(lOutputLine);
  end;
  ResetConsoleColorsToDefault;
end;

procedure TConsoleHelper.LogUsage;
var
  lApplicationExe: string;
begin
  lApplicationExe := ChangeFileExt(ExtractFileName(ParamStr(0)), '');

  WriteLn;
  WriteLn;
  WriteLn('Usage: ' + lApplicationExe + ' [<options>] [<filename>]');
  WriteLn;
  SetConsoleColors(ccYellow);
  WriteLn('Options:');
  ResetConsoleColorsToDefault;
  WriteLn('  -h, -help         Show help message.');
  WriteLn('  -c<config file>   Configuration file name to use in formatting.');
  WriteLn('  -d<directory>     Directory for files to format. Directory option will take priority over individual files.');
  WriteLn('  -m<file mask>     File mask to match searched files when using -d option. You can define multiple masks by');
  WriteLn('                    using ; separator. Default file mask is: *.pas;*.dpr;*.dpk;*.inc');
  WriteLn('  -r                Format files recursively in the <directory> and all subdirectories.');
  WriteLn('  -b                Create .bak files before formatting');
  WriteLn('  -s<start marker>  Start marker to skip formatting of specified code fragment. Default start marker is: {(*}');
  WriteLn('  -e<end marker>    End marker to skip formatting of specified code fragment. Default end marker is: {*)}');
  WriteLn('  <filename>        Source file name to format. You can specify several <filename> separated by spaces.');
  WriteLn('                    To specify file with spaces in file path, use " to enclose whole path.');
  Write('                    Wild characters ''*'' and ''?'' can be used.');
end;

procedure TConsoleHelper.LogTest;
var
  lCoords: TCoord;
begin
  WriteLn;
  Write('Test eschange word: ');
  lCoords := GetConsoleCursorCoord;
  Write('TestWord');
  ReadLn;
  SetConsoleCursorCoord(lCoords);
  Write('Word2   ');
  ReadLn;

  //TDirectory.GetFiles
end;

end.
