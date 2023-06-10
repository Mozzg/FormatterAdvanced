unit uFormatterApp;

interface

uses
  System.SysUtils, System.Classes,
  uConsoleHelper, uFormatterLogic;

const
  SEARCH_MASK_DELIMETER = ';';

type
  TAppParameters = record
    HelpOption: Boolean;
    ConfigFilePath: string;
    ConfigExportFilePath: string;
    SearchDirectoryPath: string;
    SearchDirectoryMask: string;
    RecursiveDirectorySearch: Boolean;
    CreateBackupFiles: Boolean;
    StartSkipMarker: string;
    EndSkipMarker: string;
    FileList: TStringList;
  end;

  TFormatterApp = class(TObject)
  private
    fAppParameters: TAppParameters;
    fConsoleHelper: TConsoleHelper;
    fFormatterLogic: TFormatterLogic;
  public
    constructor Create;
    destructor Destroy; override;

    function ParseAndFillApplicationParameters: Boolean;
    function DoFormat: Boolean;

    property ConsoleHelper: TConsoleHelper read fConsoleHelper;
    property AppParameters: TAppParameters read fAppParameters;
  end;

var
  MainApplication: TFormatterApp;

implementation

const
  QUOTE_CHAR = '"';
  DEFAULT_FILE_MASK = '*.pas;*.dpr;*.dpk;*.inc';
  DEFAULT_START_MARKER = '{(*}';
  DEFAULT_END_MARKER = '{*)}';

{ }

function UnquoteStr(const aInput: string): string;
begin
  if (aInput[1] = QUOTE_CHAR) and (aInput[Length(aInput)] = QUOTE_CHAR) then
    Result := Copy(aInput, 2, Length(aInput) - 2)
  else
    Result := aInput;
end;

{ TFormatterApp }

constructor TFormatterApp.Create;
begin
  inherited Create;
  fAppParameters.FileList := TStringList.Create;
  fAppParameters.SearchDirectoryMask := DEFAULT_FILE_MASK;
  fAppParameters.StartSkipMarker := DEFAULT_START_MARKER;
  fAppParameters.EndSkipMarker := DEFAULT_END_MARKER;
  fConsoleHelper := TConsoleHelper.Create;
  fFormatterLogic := TFormatterLogic.Create;
end;

destructor TFormatterApp.Destroy;
begin
  FreeAndNil(fConsoleHelper);
  FreeAndNil(fFormatterLogic);
  inherited Destroy;
  FreeAndNil(fAppParameters.FileList);
end;

function TFormatterApp.ParseAndFillApplicationParameters: Boolean;
const
  STANDARD_PARAMETER_PREFIX = '-';
  SLASH_PARAMETER_PREFIX = '/';
var
  i, lParameterLength: Integer;
  lCurrentParameter, lTemp: string;
begin
  if ParamCount <= 0 then
  begin
    fAppParameters.HelpOption := True;
    Exit(True);
  end;

  for i := 1 to ParamCount do
  begin
    lCurrentParameter := ParamStr(i);
    lParameterLength := Length(lCurrentParameter);
    if lParameterLength < 2 then
    begin
      Write('Error parsing argument "' + lCurrentParameter +'", argument is too short');
      Exit(False);
    end;

    if CharInSet(lCurrentParameter[1], [STANDARD_PARAMETER_PREFIX, SLASH_PARAMETER_PREFIX]) then
    begin
      case AnsiLowerCase(lCurrentParameter[2])[1] of
        '-':
        begin
          lTemp := Copy(lCurrentParameter, 2, lParameterLength);
          if (lTemp = '-help') or (lTemp = '-h') then
            fAppParameters.HelpOption := True
          else
          begin
            Write('Error parsing argument "' + lCurrentParameter + '", unknown argument');
            Exit(False);
          end;
        end;
        'h':
          fAppParameters.HelpOption := True;
        'c':
        begin
          if lParameterLength = 2 then
          begin
            Write('Error parsing argument "' + lCurrentParameter + '", no config file specified');
            Exit(False);
          end;
          lCurrentParameter := Copy(lCurrentParameter, 3, lParameterLength);
          fAppParameters.ConfigFilePath := UnquoteStr(lCurrentParameter);
        end;
        'x':
        begin
          if lParameterLength = 2 then
          begin
            Write('Error parsing argument "' + lCurrentParameter + '", no path specified');
            Exit(False);
          end;
          lCurrentParameter := Copy(lCurrentParameter, 3, lParameterLength);
          fAppParameters.ConfigExportFilePath := UnquoteStr(lCurrentParameter);
        end;
        'd':
        begin
          if lParameterLength = 2 then
          begin
            Write('Error parsing argument "' + lCurrentParameter + '", no directory specified');
            Exit(False);
          end;
          lCurrentParameter := Copy(lCurrentParameter, 3, lParameterLength);
          fAppParameters.SearchDirectoryPath := IncludeTrailingPathDelimiter(UnquoteStr(lCurrentParameter));
        end;
        'm':
        begin
          if lParameterLength = 2 then
          begin
            Write('Error parsing argument "' + lCurrentParameter + '", no mask specified');
            Exit(False);
          end;
          lCurrentParameter := Copy(lCurrentParameter, 3, lParameterLength);
          fAppParameters.SearchDirectoryMask := UnquoteStr(lCurrentParameter);
        end;
        'r':
          fAppParameters.RecursiveDirectorySearch := True;
        'b':
          fAppParameters.CreateBackupFiles := True;
        's':
        begin
          if lParameterLength = 2 then
          begin
            Write('Error parsing argument "' + lCurrentParameter + '", no start marker specified');
            Exit(False);
          end;
          lCurrentParameter := Copy(lCurrentParameter, 3, lParameterLength);
          fAppParameters.StartSkipMarker := UnquoteStr(lCurrentParameter);
        end;
        'e':
        begin
          if lParameterLength = 2 then
          begin
            Write('Error parsing argument "' + lCurrentParameter + '", no end marker specified');
            Exit(False);
          end;
          lCurrentParameter := Copy(lCurrentParameter, 3, lParameterLength);
          fAppParameters.EndSkipMarker := UnquoteStr(lCurrentParameter);
        end;
      else
        begin
          Write('Error parsing argument "' + lCurrentParameter + '", unknown argument');
          Exit(False);
        end;
      end;
    end
    else
    begin
      lCurrentParameter := UnquoteStr(lCurrentParameter);

      if lCurrentParameter = EmptyStr then
      begin
        Write('Error parsing argument number ' + IntToStr(i) + ', argument is empty');
        Exit(False);
      end;

      fAppParameters.FileList.Add(lCurrentParameter);
    end;
  end;

  if fAppParameters.HelpOption then Exit(True);

  // Checking if all paths exists
  if (fAppParameters.ConfigFilePath <> EmptyStr) and (not FileExists(fAppParameters.ConfigFilePath)) then
  begin
    Write('Error, config file ' + fAppParameters.ConfigFilePath + ' does not exists');
    Exit(False);
  end;
  if (fAppParameters.SearchDirectoryPath <> EmptyStr) and (not DirectoryExists(fAppParameters.SearchDirectoryPath)) then
  begin
    Write('Error, directory ' + fAppParameters.SearchDirectoryPath + ' does not exists');
    Exit(False);
  end;
  for i := 0 to fAppParameters.FileList.Count - 1 do
    if not FileExists(fAppParameters.FileList[i]) then
    begin
      Write('Error, file ' + fAppParameters.FileList[i] + ' does not exists');
      Exit(False);
    end;
  // Checking if any paths are present in parameters
  if (fAppParameters.SearchDirectoryPath = EmptyStr) and (fAppParameters.FileList.Count = 0) then
    fAppParameters.HelpOption := True;

  Result := True;
end;

function TFormatterApp.DoFormat: Boolean;
begin
  Result := fFormatterLogic.DoFormat;
end;

end.
