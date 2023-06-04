program FormatterAdvanced;

{$APPTYPE CONSOLE}

{$R *.res}

{$R 'StandardFormatter.res' 'Resources\StandardFormatter.rc'}

uses
  System.SysUtils,
  uFormatterApp in 'Source\uFormatterApp.pas',
  uConsoleHelper in 'Source\uConsoleHelper.pas',
  uFormatterLogic in 'Source\uFormatterLogic.pas',
  uCustomExecFromMem in 'Source\uCustomExecFromMem.pas';

begin
  try
    MainApplication := TFormatterApp.Create;
    try
      MainApplication.ConsoleHelper.LogAppHeader;
      if MainApplication.ParseAndFillApplicationParameters then
      begin
        if MainApplication.AppParameters.HelpOption then
          MainApplication.ConsoleHelper.LogUsage
        else
        begin
          if not MainApplication.DoFormat then
            MainApplication.ConsoleHelper.LogAndWaitAtExit;
        end;
      end
      else
        MainApplication.ConsoleHelper.LogAndWaitAtExit;

      {$IFDEF DEBUG}
      MainApplication.ConsoleHelper.LogAndWaitAtExit;
      {$ENDIF}
    finally
      MainApplication.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn('Exception in application with message: ' + E.Message);
      Halt(1);
    end;
  end;
end.
