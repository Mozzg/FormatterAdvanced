unit uCustomExecFromMem;

interface

uses
  WinAPI.Windows, System.SysUtils, System.Classes;

// aExecFile - Full path and filename to launch and replace executable. Usually it's the calling program path.
// aExecParams - parameters to lauch the program with. Each parameter must be separated by space. Function adds
// %1 to the start of parameters, so they are transferrend correctly to launched process.
function ExecFromMem(const aExecFile, aExecParams: string; aMemory: Pointer; var aExitCode: DWORD; var aConsoleOutput: string;
    var aReadPipeHandle, aWritePipeHandle: THandle; aCreateProcessFlags: DWORD = 0; aProcessTimeout: NativeUInt = 0): Boolean;

function ExecFromFile(const aExecFile, aExecParams: string; var aExitCode: DWORD; var aConsoleOutput: string;
    var aReadPipeHandle, aWritePipeHandle: THandle; aCreateProcessFlags: DWORD = 0; aProcessTimeout: NativeUInt = 0): Boolean;

implementation

const
  WAIT_INTERVAL = 20;

{ }

function GetAllignedContext(var Base: PContext; const aByteAlign: Byte): PContext;
begin
  Base := VirtualAlloc(nil, SizeOf(TContext) + aByteAlign, MEM_COMMIT, PAGE_READWRITE);
  Result := Base;
  if Base <> nil then
    while ((DWORD(Result) mod aByteAlign) <> 0) do
      Result := Pointer(DWORD(Result) + 1);
end;

procedure ReadFromPipeToBuffer(aPipeHandle: THandle; var aBuffer: TBytes);
var
  lBytesToRead, lBytesActuallyRead, lBufferSize: DWORD;
begin
  if PeekNamedPipe(aPipeHandle, nil, 0, nil, @lBytesToRead, nil) and (lBytesToRead > 0) then
  begin
    lBufferSize := Length(aBuffer);
    SetLength(aBuffer, lBufferSize + lBytesToRead);
    if ReadFile(aPipeHandle, aBuffer[lBufferSize], lBytesToRead, lBytesActuallyRead, nil) then
      if lBytesToRead <> lBytesActuallyRead then
        SetLength(aBuffer, lBufferSize + lBytesActuallyRead);
  end;
end;

function ExecFromMem(const aExecFile, aExecParams: string; aMemory: Pointer; var aExitCode: DWORD; var aConsoleOutput: string;
    var aReadPipeHandle, aWritePipeHandle: THandle; aCreateProcessFlags: DWORD = 0; aProcessTimeout: NativeUInt = 0): Boolean;
var
  lDosHeaderPointer: PImageDosHeader;
  lNTHeaderPointer: PImageNtHeaders;
  lTempExecFile, lTempExecParams, lTemp: string;
  lStartupInfo: TStartupInfo;
  lProcessInfo: TProcessInformation;
  lPipeSecurityAttr: TSecurityAttributes;
  lReadPipeHandle, lWritePipeHandle: THandle;
  lCreateNewPipeHandles: Boolean;
  lInitialContextPointer, lAllignedContextPointer: PContext;
  lImageBase, lReadWriteCount: SIZE_T;
  lImageBasePointer: Pointer;
  i: Integer;
  lSectionHeaderPointer: PImageSectionHeader;
  lExitCode, lWaitResult: DWORD;
  lMaxFinishTick: UInt64;
  lPipeReadBuffer: TBytes;
  lStringStream: TStringStream;
begin
  Result := False;
  if (aReadPipeHandle = 0) or (aReadPipeHandle = INVALID_HANDLE_VALUE)
      or (aWritePipeHandle = 0) or (aWritePipeHandle = INVALID_HANDLE_VALUE)
  then
    lCreateNewPipeHandles := True
  else
    lCreateNewPipeHandles := False;

  lReadPipeHandle := INVALID_HANDLE_VALUE;
  lWritePipeHandle := INVALID_HANDLE_VALUE;

  try
    lDosHeaderPointer := aMemory;
    // Checking for correct PE signature
    if lDosHeaderPointer^.e_magic = IMAGE_DOS_SIGNATURE then
    begin
      lNTHeaderPointer := Pointer(NativeInt(aMemory) + lDosHeaderPointer^._lfanew);
      if lNTHeaderPointer^.Signature = IMAGE_NT_SIGNATURE then
      begin
        lTemp := '%1 ' + aExecParams;
        // Copy string to probably prevent AV. Don't know if this is needed.
        lTempExecFile := Copy(aExecFile, 0, Length(aExecFile));
        lTempExecParams := Copy(lTemp, 0, Length(lTemp));

        if not lCreateNewPipeHandles then
        begin
          lReadPipeHandle := aReadPipeHandle;
          lWritePipeHandle := aWritePipeHandle;
        end
        else
        begin
          // Prepare AnonymousPipe to capture console output from child process
          lPipeSecurityAttr.nLength := SizeOf(TSecurityAttributes);
          lPipeSecurityAttr.lpSecurityDescriptor := nil;
          lPipeSecurityAttr.bInheritHandle := True;

          if not CreatePipe(lReadPipeHandle, lWritePipeHandle, @lPipeSecurityAttr, 0) then
            raise Exception.Create('CreatePipe failed: ' + SysErrorMessage(GetLastError));

          // Change inheritance to ReadPipeHandle, so it won't be inherited to child process
          if not SetHandleInformation(lReadPipeHandle, HANDLE_FLAG_INHERIT, 0) then
            raise Exception.Create('SetHandleInformation failed: ' + SysErrorMessage(GetLastError));
        end;

        // Initialize CreateProcess structures
        ZeroMemory(@lProcessInfo, SizeOf(lProcessInfo));
        ZeroMemory(@lStartupInfo, SizeOf(lStartupInfo));
        lStartupInfo.cb := SizeOf(lStartupInfo);
        lStartupInfo.dwFlags := STARTF_USESTDHANDLES;
        lStartupInfo.hStdInput := INVALID_HANDLE_VALUE;
        lStartupInfo.hStdOutput := lWritePipeHandle;
        lStartupInfo.hStdError  := lWritePipeHandle;

        // Create suspended process
        if CreateProcess(PWideChar(lTempExecFile), PWideChar(lTempExecParams), nil, nil, True, CREATE_SUSPENDED or aCreateProcessFlags,
            nil, nil, lStartupInfo, lProcessInfo)
        then
        begin
          lAllignedContextPointer := GetAllignedContext(lInitialContextPointer, 16);
          if Assigned(lAllignedContextPointer) then
          try
            lAllignedContextPointer^.ContextFlags := CONTEXT_FULL;
            if GetThreadContext(lProcessInfo.hThread, lAllignedContextPointer^) then
            begin
              if not ReadProcessMemory(lProcessInfo.hProcess, Pointer(lAllignedContextPointer^.Ebx + 8),
                  @lImageBase, SizeOf(lImageBase), lReadWriteCount)
              then
                raise Exception.Create('ReadProcessMemory failed: ' + SysErrorMessage(GetLastError));

              lImageBasePointer := VirtualAllocEx(lProcessInfo.hProcess, {Pointer(lNTHeaderPointer^.OptionalHeader.ImageBase)}nil,
                  lNTHeaderPointer^.OptionalHeader.SizeOfImage, MEM_COMMIT or MEM_RESERVE, PAGE_EXECUTE_READWRITE);
              if not Assigned(lImageBasePointer) then
                raise Exception.Create('VirtualAllocEx failed: ' + SysErrorMessage(GetLastError));

              if not WriteProcessMemory(lProcessInfo.hProcess, lImageBasePointer, aMemory, lNTHeaderPointer^.OptionalHeader.SizeOfHeaders, lReadWriteCount) then
                raise Exception.Create('WriteProcessMemory failed: ' + SysErrorMessage(GetLastError));

              for i := 0 to lNTHeaderPointer^.FileHeader.NumberOfSections - 1 do
              begin
                lSectionHeaderPointer := Pointer(NativeInt(aMemory) + lDosHeaderPointer^._lfanew + 248 + (i * 40));
                if not WriteProcessMemory(lProcessInfo.hProcess, Pointer(NativeUInt(lImageBasePointer) + lSectionHeaderPointer^.VirtualAddress),
                    Pointer(NativeUInt(aMemory) + lSectionHeaderPointer^.PointerToRawData), lSectionHeaderPointer^.SizeOfRawData,
                    lReadWriteCount)
                then
                  raise Exception.Create('WriteProcessMemory failed: ' + SysErrorMessage(GetLastError));
              end;

              if not WriteProcessMemory(lProcessInfo.hProcess, Pointer(lAllignedContextPointer^.Ebx + 8),
                  @lImageBasePointer, SizeOf(Pointer), lReadWriteCount)
              then
                raise Exception.Create('WriteProcessMemory failed: ' + SysErrorMessage(GetLastError));

              lAllignedContextPointer^.Eax := NativeUInt(lImageBasePointer) + lNTHeaderPointer^.OptionalHeader.AddressOfEntryPoint;
              SetThreadContext(lProcessInfo.hThread, lAllignedContextPointer^);
              ResumeThread(lProcessInfo.hThread);

              if aProcessTimeout = 0 then
              begin
                lWaitResult := WaitForSingleObject(lProcessInfo.hProcess, INFINITE);
                if lWaitResult = WAIT_OBJECT_0 then
                begin
                  ReadFromPipeToBuffer(lReadPipeHandle, lPipeReadBuffer);
                  if not GetExitCodeProcess(lProcessInfo.hProcess, lExitCode) then
                    raise Exception.Create('GetExitCodeProcess faled: ' + SysErrorMessage(GetLastError));
                  Result := True;
                end;
              end
              else
              begin
                lMaxFinishTick := GetTickCount64 + aProcessTimeout;
                lExitCode := 1;
                SetLength(lPipeReadBuffer, 0);
                while GetTickCount64 < lMaxFinishTick do
                begin
                  lWaitResult := WaitForSingleObject(lProcessInfo.hProcess, WAIT_INTERVAL);
                  if (lWaitResult <> WAIT_OBJECT_0) and (lWaitResult <> WAIT_TIMEOUT) then
                    raise Exception.Create('WaitForSingleObject failed: ' + SysErrorMessage(GetLastError));

                  if lWaitResult = WAIT_OBJECT_0 then
                  begin
                    ReadFromPipeToBuffer(lReadPipeHandle, lPipeReadBuffer);
                    if not GetExitCodeProcess(lProcessInfo.hProcess, lExitCode) then
                      raise Exception.Create('GetExitCodeProcess faled: ' + SysErrorMessage(GetLastError));
                    Result := True;
                    Break;
                  end;
                  if lWaitResult = WAIT_TIMEOUT then
                    ReadFromPipeToBuffer(lReadPipeHandle, lPipeReadBuffer);
                end;
              end;

              if not Result then
                if not TerminateProcess(lProcessInfo.hProcess, 0) then
                  raise Exception.Create('TerminateProcess failed: ' + SysErrorMessage(GetLastError));

              CloseHandle(lProcessInfo.hProcess);
              CloseHandle(lProcessInfo.hThread);
              aExitCode := lExitCode;

              if Length(lPipeReadBuffer) <> 0 then
              begin
                ReadFromPipeToBuffer(lReadPipeHandle, lPipeReadBuffer);
                lStringStream := TStringStream.Create;
                try
                  lStringStream.Size := Length(lPipeReadBuffer);
                  Move(lPipeReadBuffer[0], lStringStream.Memory^, lStringStream.Size);
                  aConsoleOutput := lStringStream.DataString;
                finally
                  lStringStream.Free;
                end;
              end;
            end
            else
              raise Exception.Create('GetThreadContext failed: ' + SysErrorMessage(GetLastError));
          finally
            VirtualFree(lInitialContextPointer, 0, MEM_RELEASE);
          end
          else
            raise Exception.Create('VirtualAlloc failed: ' + SysErrorMessage(GetLastError));
        end
        else
          raise Exception.Create('CreateProcess failed: ' + SysErrorMessage(GetLastError));
      end;
    end;
  finally
    if lCreateNewPipeHandles and (lReadPipeHandle <> INVALID_HANDLE_VALUE) then
    begin
      CloseHandle(lReadPipeHandle);
      lReadPipeHandle := INVALID_HANDLE_VALUE;
    end;
    if lCreateNewPipeHandles and (lWritePipeHandle <> INVALID_HANDLE_VALUE) then
    begin
      CloseHandle(lWritePipeHandle);
      lWritePipeHandle := INVALID_HANDLE_VALUE;
    end;
  end;
end;

function ExecFromFile(const aExecFile, aExecParams: string; var aExitCode: DWORD; var aConsoleOutput: string;
    var aReadPipeHandle, aWritePipeHandle: THandle; aCreateProcessFlags: DWORD = 0; aProcessTimeout: NativeUInt = 0): Boolean;
var
  lCreateNewPipeHandles: Boolean;
  lReadPipeHandle, lWritePipeHandle: THandle;
  lTempExecFile, lTempExecParams, lTemp: string;
  lPipeSecurityAttr: TSecurityAttributes;
  lStartupInfo: TStartupInfo;
  lProcessInfo: TProcessInformation;
  lExitCode, lWaitResult: DWORD;
  lPipeReadBuffer: TBytes;
  lMaxFinishTick: UInt64;
  lStringStream: TStringStream;
begin
  Result := False;
  if (aReadPipeHandle = 0) or (aReadPipeHandle = INVALID_HANDLE_VALUE)
      or (aWritePipeHandle = 0) or (aWritePipeHandle = INVALID_HANDLE_VALUE)
  then
    lCreateNewPipeHandles := True
  else
    lCreateNewPipeHandles := False;

  lReadPipeHandle := INVALID_HANDLE_VALUE;
  lWritePipeHandle := INVALID_HANDLE_VALUE;

  try
    lTemp := '%1 ' + aExecParams;
    // Copy string to probably prevent AV. Don't know if this is needed.
    lTempExecFile := Copy(aExecFile, 0, Length(aExecFile));
    lTempExecParams := Copy(lTemp, 0, Length(lTemp));

    if not lCreateNewPipeHandles then
    begin
      lReadPipeHandle := aReadPipeHandle;
      lWritePipeHandle := aWritePipeHandle;
    end
    else
    begin
      // Prepare AnonymousPipe to capture console output from child process
      lPipeSecurityAttr.nLength := SizeOf(TSecurityAttributes);
      lPipeSecurityAttr.lpSecurityDescriptor := nil;
      lPipeSecurityAttr.bInheritHandle := True;

      if not CreatePipe(lReadPipeHandle, lWritePipeHandle, @lPipeSecurityAttr, 0) then
        raise Exception.Create('CreatePipe failed: ' + SysErrorMessage(GetLastError));

      // Change inheritance to ReadPipeHandle, so it won't be inherited to child process
      if not SetHandleInformation(lReadPipeHandle, HANDLE_FLAG_INHERIT, 0) then
        raise Exception.Create('SetHandleInformation failed: ' + SysErrorMessage(GetLastError));
    end;

    // Initialize CreateProcess structures
    ZeroMemory(@lProcessInfo, SizeOf(lProcessInfo));
    ZeroMemory(@lStartupInfo, SizeOf(lStartupInfo));
    lStartupInfo.cb := SizeOf(lStartupInfo);
    lStartupInfo.dwFlags := STARTF_USESTDHANDLES;
    lStartupInfo.hStdInput := INVALID_HANDLE_VALUE;
    lStartupInfo.hStdOutput := lWritePipeHandle;
    lStartupInfo.hStdError  := lWritePipeHandle;

    // Create suspended process
    if CreateProcess(PWideChar(lTempExecFile), PWideChar(lTempExecParams), nil, nil, True, aCreateProcessFlags,
        nil, nil, lStartupInfo, lProcessInfo)
    then
    begin
      if aProcessTimeout = 0 then
      begin
        lWaitResult := WaitForSingleObject(lProcessInfo.hProcess, INFINITE);
        if lWaitResult = WAIT_OBJECT_0 then
        begin
          ReadFromPipeToBuffer(lReadPipeHandle, lPipeReadBuffer);
          if not GetExitCodeProcess(lProcessInfo.hProcess, lExitCode) then
            raise Exception.Create('GetExitCodeProcess faled: ' + SysErrorMessage(GetLastError));
          Result := True;
        end;
      end
      else
      begin
        lMaxFinishTick := GetTickCount64 + aProcessTimeout;
        lExitCode := 1;
        SetLength(lPipeReadBuffer, 0);
        while GetTickCount64 < lMaxFinishTick do
        begin
          lWaitResult := WaitForSingleObject(lProcessInfo.hProcess, WAIT_INTERVAL);
          if (lWaitResult <> WAIT_OBJECT_0) and (lWaitResult <> WAIT_TIMEOUT) then
            raise Exception.Create('WaitForSingleObject failed: ' + SysErrorMessage(GetLastError));

          if lWaitResult = WAIT_OBJECT_0 then
          begin
            ReadFromPipeToBuffer(lReadPipeHandle, lPipeReadBuffer);
            if not GetExitCodeProcess(lProcessInfo.hProcess, lExitCode) then
              raise Exception.Create('GetExitCodeProcess faled: ' + SysErrorMessage(GetLastError));
            Result := True;
            Break;
          end;
          if lWaitResult = WAIT_TIMEOUT then
            ReadFromPipeToBuffer(lReadPipeHandle, lPipeReadBuffer);
        end;
      end;

      if not Result then
        if not TerminateProcess(lProcessInfo.hProcess, 0) then
          raise Exception.Create('TerminateProcess failed: ' + SysErrorMessage(GetLastError));

      CloseHandle(lProcessInfo.hProcess);
      CloseHandle(lProcessInfo.hThread);
      aExitCode := lExitCode;

      if Length(lPipeReadBuffer) <> 0 then
      begin
        ReadFromPipeToBuffer(lReadPipeHandle, lPipeReadBuffer);
        lStringStream := TStringStream.Create;
        try
          lStringStream.Size := Length(lPipeReadBuffer);
          Move(lPipeReadBuffer[0], lStringStream.Memory^, lStringStream.Size);
          aConsoleOutput := lStringStream.DataString;
        finally
          lStringStream.Free;
        end;
      end;
    end
    else
      raise Exception.Create('CreateProcess failed: ' + SysErrorMessage(GetLastError));
  finally
    if lCreateNewPipeHandles and (lReadPipeHandle <> INVALID_HANDLE_VALUE) then
    begin
      CloseHandle(lReadPipeHandle);
      lReadPipeHandle := INVALID_HANDLE_VALUE;
    end;
    if lCreateNewPipeHandles and (lWritePipeHandle <> INVALID_HANDLE_VALUE) then
    begin
      CloseHandle(lWritePipeHandle);
      lWritePipeHandle := INVALID_HANDLE_VALUE;
    end;
  end;
end;

end.
