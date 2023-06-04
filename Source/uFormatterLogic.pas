unit uFormatterLogic;

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Types, System.Masks, System.StrUtils, WinAPI.Windows,
  uConsoleHelper, uCustomExecFromMem;

type
  TSkipChunk = record
    StartPosition: Int64;
    EndPosition: Int64;
    Text: string;
  end;

  TFileSkipData = record
    FilePath: string;
    SkipChunks: array of TSkipChunk;
  end;

  TFormatterLogic = class(TObject)
  private
    fFilesSkipData: array of TFileSkipData;
    fStartSkipMarker: string;
    fEndSkipMarker: string;
    fConfigFileName: string;
    fFormatterFileName: string;
    fReadPipeHandle: THandle;
    fWritePipeHandle: THandle;

    function GetGUIDTempFileName: string;
    function GetWorkingFileList: TStringList;
    function PrepareSkipData(aFileList: TStringList): Boolean;
    function PrepareFormatterForExecution: Boolean;
    function ReplaceSkipData(const aFileName: string; out aConsoleOutput: string): Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    function DoFormat: Boolean;
  end;

implementation

uses
  uFormatterApp;

{ TFormatterLogic }

constructor TFormatterLogic.Create;
begin
  inherited Create;
  fReadPipeHandle := INVALID_HANDLE_VALUE;
  fWritePipeHandle := INVALID_HANDLE_VALUE;
end;

destructor TFormatterLogic.Destroy;
begin
  if FileExists(fConfigFileName) then
    System.SysUtils.DeleteFile(fConfigFileName);
  if FileExists(fFormatterFileName) then
    System.SysUtils.DeleteFile(fFormatterFileName);

  try
    if fReadPipeHandle <> INVALID_HANDLE_VALUE then
      CloseHandle(fReadPipeHandle);
  finally
    fReadPipeHandle := INVALID_HANDLE_VALUE;
  end;

  try
    if fWritePipeHandle <> INVALID_HANDLE_VALUE then
      CloseHandle(fWritePipeHandle);
  finally
    fWritePipeHandle := INVALID_HANDLE_VALUE;
  end;

  inherited Destroy;
end;

function TFormatterLogic.GetGUIDTempFileName: string;
var
  lTempPath: string;
  lFileHandle: THandle;
begin
  lTempPath := TPath.GetTempPath;
  lFileHandle := INVALID_HANDLE_VALUE;

  while lFileHandle = INVALID_HANDLE_VALUE do
  begin
    Result := lTempPath + TPath.GetGUIDFileName(True) + '.tmp';
    lFileHandle := FileCreate(Result);
    if lFileHandle <> INVALID_HANDLE_VALUE then
      FileClose(lFileHandle);
  end;
end;

function TFormatterLogic.GetWorkingFileList: TStringList;
var
  lSearchOption: TSearchOption;
  lFileNameMasks: TStringDynArray;
  lFileNameMasksList: TStringList;
  i: Integer;
  lFileSearchPredicate: TDirectory.TFilterPredicate;
  lMatchedFileArray: TStringDynArray;
begin
  Result := nil;
  try
    Result := TStringList.Create;

    // Check if we have to process directory or file list
    if MainApplication.AppParameters.SearchDirectoryPath = EmptyStr then
      Result.Assign(MainApplication.AppParameters.FileList)
    else
    begin
      // https://stackoverflow.com/questions/12726756/how-to-pass-multiple-file-extensions-to-tdirectory-getfiles
      if MainApplication.AppParameters.RecursiveDirectorySearch then
        lSearchOption := TSearchOption.soAllDirectories
      else
        lSearchOption := TSearchOption.soTopDirectoryOnly;
      lFileNameMasks := SplitString(MainApplication.AppParameters.SearchDirectoryMask, SEARCH_MASK_DELIMETER);

      if Length(lFileNameMasks) > 0 then
      begin
        lFileNameMasksList := TStringList.Create;
        try
          lFileNameMasksList.OwnsObjects := True;
          for i := Low(lFileNameMasks) to High(lFileNameMasks) do
            if lFileNameMasks[i] <> EmptyStr then
              lFileNameMasksList.AddObject(lFileNameMasks[i], TMask.Create(lFileNameMasks[i]));

          {$IFDEF DEBUG}
          WriteLn;
          WriteLn('Searching');
          {$ENDIF}

          lFileSearchPredicate := function(const Path: string; const SearchRec: TSearchRec): Boolean
          var
            lMatchesAnyMask: Boolean;
            j: Integer;
          begin
            {$IFDEF DEBUG}
            Write('Path=' + Path + ', Name=' + SearchRec.Name + ', Size=' + IntToStr(SearchRec.Size) + ', Attr=' + IntToStr(SearchRec.Attr));
            {$ENDIF}

            {$WARN SYMBOL_PLATFORM OFF}
            if (SearchRec.Size = 0) or ((SearchRec.Attr and faHidden) <> 0) or ((SearchRec.Attr and faReadOnly) <> 0) then
              Exit(False);
            {$WARN SYMBOL_PLATFORM ON}

            lMatchesAnyMask := False;
            for j := 0 to lFileNameMasksList.Count - 1 do
              if (lFileNameMasksList.Objects[j] as TMask).Matches(SearchRec.Name) then
              begin
                lMatchesAnyMask := True;
                Break;
              end;

            Result := lMatchesAnyMask;
            {$IFDEF DEBUG}
            WriteLn(', Matches=' + BoolToStr(Result, True));
            {$ENDIF}
          end;

          lMatchedFileArray := TDirectory.GetFiles(MainApplication.AppParameters.SearchDirectoryPath, '*', lSearchOption, lFileSearchPredicate);

          for i := Low(lMatchedFileArray) to High(lMatchedFileArray) do
            Result.Add(lMatchedFileArray[i]);
        finally
          lFileNameMasksList.Free;
        end;
      end;
    end;
  except
    FreeAndNil(Result);
    raise;
  end;
end;

function TFormatterLogic.PrepareSkipData(aFileList: TStringList): Boolean;
const
  PROGRESS_WIDTH = 8;
var
  lFileTextList: TStringList;
  i, j, k, lSkipSectionCount, lStartPos, lEndPos, lCurrentPos: Integer;
  lFileText: string;
  lNextStart: Boolean;
  lProgressCoords: TCoord;
begin
  WriteLn;
  Write('Checking files for skip sections...');
  lProgressCoords := MainApplication.ConsoleHelper.CurrentCursorCoord;

  // Reading found files, saving data and checking if all good
  SetLength(fFilesSkipData, 0);
  lFileTextList := TStringList.Create;
  try
    for i := 0 to aFileList.Count - 1 do
    begin
      // Write progress update
      MainApplication.ConsoleHelper.CurrentCursorCoord := lProgressCoords;
      MainApplication.ConsoleHelper.LogTextWithColor(Format('%4.2f%%', [(i / aFileList.Count) * 100]).PadRight(PROGRESS_WIDTH),
          ccYellow);

      lSkipSectionCount := 0;

      j := Length(fFilesSkipData);
      SetLength(fFilesSkipData, j + 1);
      fFilesSkipData[j].FilePath := aFileList[i];

      lFileTextList.Clear;
      lFileTextList.LoadFromFile(aFileList[i]);
      lFileText := lFileTextList.Text;

      lCurrentPos := 1;
      lStartPos := Pos(fStartSkipMarker, lFileText, lCurrentPos);
      lEndPos := Pos(fEndSkipMarker, lFileText, lCurrentPos);
      while (lStartPos <> 0) or (lEndPos <> 0) do
      begin
        lNextStart := (lStartPos <> 0) and (lStartPos < lEndPos);
        if ((lSkipSectionCount = 0) and (not lNextStart))
            or ((lSkipSectionCount = 1) and lNextStart)
        then
        begin
          // Write progress update
          MainApplication.ConsoleHelper.CurrentCursorCoord := lProgressCoords;
          MainApplication.ConsoleHelper.LogTextWithColor('FAIL'.PadRight(8), ccRed);
          WriteLn;
          Write('File ' + aFileList[i] + ' has wrong start and end skip markers');
          Exit(False);
        end;

        k := Length(fFilesSkipData[j].SkipChunks);
        if lNextStart then
        begin
          SetLength(fFilesSkipData[j].SkipChunks, k + 1);
          fFilesSkipData[j].SkipChunks[k].StartPosition := lStartPos;
          Inc(lSkipSectionCount);
          lCurrentPos := lStartPos + 1;
        end
        else
        begin
          fFilesSkipData[j].SkipChunks[k - 1].EndPosition := lEndPos;
          fFilesSkipData[j].SkipChunks[k - 1].Text := Copy(lFileText, fFilesSkipData[j].SkipChunks[k - 1].StartPosition,
              lEndPos - fFilesSkipData[j].SkipChunks[k - 1].StartPosition + Length(fEndSkipMarker));
          Dec(lSkipSectionCount);
          lCurrentPos := lEndPos + 1;
        end;

        lStartPos := Pos(fStartSkipMarker, lFileText, lCurrentPos);
        lEndPos := Pos(fEndSkipMarker, lFileText, lCurrentPos);
      end;
    end;
  finally
    lFileTextList.Free;
  end;

  // Write progress update
  MainApplication.ConsoleHelper.CurrentCursorCoord := lProgressCoords;
  MainApplication.ConsoleHelper.LogTextWithColor('DONE'.PadRight(8), ccGreen);

  Result := True;
end;

function TFormatterLogic.PrepareFormatterForExecution: Boolean;
var
  lProgressCoords: TCoord;
  lResource: TResourceStream;
  lFileStream: TFileStream;
  lPipeSecurityAttr: TSecurityAttributes;
begin
  WriteLn;
  Write('Preparing for formatting...');
  lProgressCoords := MainApplication.ConsoleHelper.CurrentCursorCoord;
  MainApplication.ConsoleHelper.LogTextWithColor('PROCESSING', ccYellow);

  fConfigFileName := GetGUIDTempFileName;
  if fConfigFileName = EmptyStr then
  begin
    MainApplication.ConsoleHelper.CurrentCursorCoord := lProgressCoords;
    MainApplication.ConsoleHelper.LogTextWithColor('FAIL      ', ccRed);
    raise Exception.Create('Failed to create temp config file');
  end;

  lFileStream := TFileStream.Create(fConfigFileName, fmCreate, fmShareExclusive);
  try
    lResource := TResourceStream.Create(hInstance, 'FormatterConfig', 'FORMATTERCFG');
    try
      lFileStream.WriteBuffer(lResource.Memory^, lResource.Size);
    finally
      lResource.Free;
    end;
  finally
    lFileStream.Free;
  end;

  fFormatterFileName := GetGUIDTempFileName;
  if fFormatterFileName = EmptyStr then
  begin
    MainApplication.ConsoleHelper.CurrentCursorCoord := lProgressCoords;
    MainApplication.ConsoleHelper.LogTextWithColor('FAIL      ', ccRed);
    raise Exception.Create('Failed to create temp config file');
  end;

  lFileStream := TFileStream.Create(fFormatterFileName, fmCreate, fmShareExclusive);
  try
    lResource := TResourceStream.Create(hInstance, 'FormatterExecutable', 'FORMATTEREXE');
    try
      lFileStream.WriteBuffer(lResource.Memory^, lResource.Size);
    finally
      lResource.Free;
    end;
  finally
    lFileStream.Free;
  end;

  // Prepare AnonymousPipe to capture console output from child process
  lPipeSecurityAttr.nLength := SizeOf(TSecurityAttributes);
  lPipeSecurityAttr.lpSecurityDescriptor := nil;
  lPipeSecurityAttr.bInheritHandle := True;
  // Creating pipes
  if not CreatePipe(fReadPipeHandle, fWritePipeHandle, @lPipeSecurityAttr, 0) then
    raise Exception.Create('CreatePipe failed: ' + SysErrorMessage(GetLastError));
  // Change inheritance to ReadPipeHandle, so it won't be inherited to child process
  if not SetHandleInformation(fReadPipeHandle, HANDLE_FLAG_INHERIT, 0) then
    raise Exception.Create('SetHandleInformation failed: ' + SysErrorMessage(GetLastError));

  MainApplication.ConsoleHelper.CurrentCursorCoord := lProgressCoords;
  MainApplication.ConsoleHelper.LogTextWithColor('DONE      ', ccGreen);

  Result := True;
end;

function TFormatterLogic.ReplaceSkipData(const aFileName: string; out aConsoleOutput: string): Boolean;
var
  lFileTextList: TStringList;
  lFileText: string;
  i, lCurrentPos, lStartPos, lEndPos, lCurrentChunkIndex: Integer;
  lFoundSkipData: Boolean;
begin
  if Length(fFilesSkipData) = 0 then Exit(True);

  lFoundSkipData := False;
  i := Low(fFilesSkipData);
  while i <= High(fFilesSkipData) do
  begin
    if fFilesSkipData[i].FilePath = aFileName then
    begin
      lFoundSkipData := True;
      Break;
    end;
    Inc(i);
  end;
  if not lFoundSkipData then Exit(True);
  if Length(fFilesSkipData[i].SkipChunks) = 0 then Exit(True);

  lFileTextList := TStringList.Create;
  try
    lFileTextList.LoadFromFile(aFileName);
    lFileText := lFileTextList.Text;

    lCurrentChunkIndex := Low(fFilesSkipData[i].SkipChunks);
    lCurrentPos := 1;
    lStartPos := Pos(fStartSkipMarker, lFileText, lCurrentPos);
    if lStartPos = 0 then
    begin
      aConsoleOutput := 'Failed to locate end skip marker in file ' + aFileName + ' on chunk index ' + IntToStr(lCurrentChunkIndex);
      Exit(False);
    end;

    while lStartPos <> 0 do
    begin
      lEndPos := Pos(fEndSkipMarker, lFileText, lCurrentPos);
      if lEndPos = 0 then
      begin
        aConsoleOutput := 'Failed to locate end skip marker in file ' + aFileName + ' on chunk index ' + IntToStr(lCurrentChunkIndex);
        Exit(False);
      end;

      Delete(lFileText, lStartPos, lEndPos - lStartPos + Length(fEndSkipMarker));
      Insert(fFilesSkipData[i].SkipChunks[lCurrentChunkIndex].Text, lFileText, lStartPos);

      Inc(lCurrentChunkIndex);
      lCurrentPos := lStartPos + 1;
      lStartPos := Pos(fStartSkipMarker, lFileText, lCurrentPos);

      if (lStartPos <> 0) and (lCurrentChunkIndex > High(fFilesSkipData[i].SkipChunks)) then
      begin
        aConsoleOutput := 'Skip chunk index out of range';
        Exit(False);
      end;
    end;

    lFileTextList.Text := lFileText;
    lFileTextList.SaveToFile(aFileName);
  finally
    lFileTextList.Free;
  end;

  Result := True;
end;

function TFormatterLogic.DoFormat: Boolean;
var
  lFileList: TStringList;
  lExecPath, lExecParameters, lTemp, lCurrentFilePath, lConsoleOutput, lSkipConsoleOutput: string;
  i{$IFDEF DEBUG}, j{$ENDIF}: Integer;
  lProgressCoords: TCoord;
  lExitCode: DWORD;
begin
  lFileList := GetWorkingFileList;
  try
    {$IFDEF DEBUG}
    WriteLn;
    WriteLn('Found files:');
    for i := 0 to lFileList.Count - 1 do
      WriteLn(lFileList[i]);
    {$ENDIF}

    // If we don't have files to work with, exit
    if lFileList.Count = 0 then
    begin
      WriteLn;
      Write('Nothing to format');
      Exit(False);
    end;

    fStartSkipMarker := MainApplication.AppParameters.StartSkipMarker;
    fEndSkipMarker := MainApplication.AppParameters.EndSkipMarker;

    if not PrepareSkipData(lFileList) then
      Exit(False);

    {$IFDEF DEBUG}
    WriteLn;
    WriteLn('Found sections:');
    for i := Low(fFilesSkipData) to High(fFilesSkipData) do
      if Length(fFilesSkipData[i].SkipChunks) > 0 then
      begin
        WriteLn('File: ' + fFilesSkipData[i].FilePath);
        for j := Low(fFilesSkipData[i].SkipChunks) to High(fFilesSkipData[i].SkipChunks) do
          WriteLn('Section#' + IntToStr(j) + ' Start=' + IntToStr(fFilesSkipData[i].SkipChunks[j].StartPosition)
              + ', End=' + IntToStr(fFilesSkipData[i].SkipChunks[j].EndPosition));
      end;
    {$ENDIF}

    if not PrepareFormatterForExecution then
      Exit(False);

    {$IFDEF DEBUG}
    WriteLn;
    Write('Config file: ' + fConfigFileName);
    {$ENDIF}

    // Preparing parameters
    lExecPath := fFormatterFileName;
    lExecParameters := EmptyStr;
    if MainApplication.AppParameters.CreateBackupFiles then
      lExecParameters := IfThen(lExecParameters = EmptyStr, '-b', lExecParameters + ' -b');

    if MainApplication.AppParameters.ConfigFilePath <> EmptyStr then
      lTemp := '-config "' + MainApplication.AppParameters.ConfigFilePath + '"'
    else
      lTemp := '-config "' + fConfigFileName + '"';
    lExecParameters := IfThen(lExecParameters = EmptyStr, lTemp, lExecParameters + ' ' + lTemp);

    if lExecParameters <> EmptyStr then
      lExecParameters := lExecParameters + ' ';

    WriteLn;
    Write('Formatting files:');

    for i := 0 to lFileList.Count - 1 do
    begin
      lCurrentFilePath := lFileList[i];
      lTemp := lExecParameters + '"' + lCurrentFilePath + '"';

      {$IFDEF DEBUG}
      WriteLn;
      Write('Executing: ' + lExecPath + ' ' + lTemp);
      {$ENDIF}

      WriteLn;
      Write(lCurrentFilePath + '...');
      lProgressCoords := MainApplication.ConsoleHelper.CurrentCursorCoord;
      MainApplication.ConsoleHelper.LogTextWithColor('PROCESSING', ccYellow);

      if not ExecFromFile(lExecPath, lTemp, lExitCode, lConsoleOutput, fReadPipeHandle, fWritePipeHandle, CREATE_NO_WINDOW, 5000) then
      begin
        MainApplication.ConsoleHelper.CurrentCursorCoord := lProgressCoords;
        MainApplication.ConsoleHelper.LogTextWithColor('FAIL      ', ccRed);
        WriteLn;
        Write(lConsoleOutput);
      end
      else
      begin
        if lExitCode <> 0 then
        begin
          MainApplication.ConsoleHelper.CurrentCursorCoord := lProgressCoords;
          MainApplication.ConsoleHelper.LogTextWithColor('FAIL      ', ccRed);
          WriteLn;
          Write(lConsoleOutput);
        end
        else
        begin
          if not ReplaceSkipData(lCurrentFilePath, lSkipConsoleOutput) then
          begin
            MainApplication.ConsoleHelper.CurrentCursorCoord := lProgressCoords;
            MainApplication.ConsoleHelper.LogTextWithColor('FAIL      ', ccRed);
            WriteLn;
            Write(lSkipConsoleOutput);
          end
          else
          begin
            MainApplication.ConsoleHelper.CurrentCursorCoord := lProgressCoords;
            MainApplication.ConsoleHelper.LogTextWithColor('DONE      ', ccGreen);
          end;
        end;
        {$IFDEF DEBUG}
        WriteLn;
        Write(lConsoleOutput);
        {$ENDIF}
      end;
    end;

    WriteLn;
    MainApplication.ConsoleHelper.LogTextWithColor('Formatting complete', ccGreen);
  finally
    lFileList.Free;
  end;

  Result := True;
end;

end.
