program SendCtrlBreak;
//
// Companion tool for ConsoleTestRunner: sends CTRL_BREAK_EVENT to a target
// console process so its installed Ctrl+Break handler dumps every thread's
// stack. Useful when you can't physically type Ctrl+Break (e.g. through
// Remote Desktop from a laptop without a Break key).
//
// Usage:
//   SendCtrlBreak.exe                       -> targets ConsoleTestRunner.exe
//   SendCtrlBreak.exe <pid>                 -> targets a specific PID
//   SendCtrlBreak.exe <process-name.exe>    -> finds by exe name (case-insensitive)
//
// The mechanic:
//   FreeConsole          -> detach from our own console
//   AttachConsole(pid)   -> attach to the target's console
//   SetConsoleCtrlHandler(nil, true) -> ignore the break we're about to send
//   GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, 0) -> broadcast to console group
//
// Caveat: every process attached to the target's console receives the event.
// If you launched ConsoleTestRunner from cmd.exe / PowerShell that share a
// console, the parent shell also gets the break — usually harmless (cmd just
// ignores it; PowerShell may print a "^C" line).
//

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  Winapi.TlHelp32,
  System.SysUtils;

function FindProcessByName(const exeName: string): DWORD;
var
  pe  : TProcessEntry32W;
  snap: THandle;
begin
  Result := 0;
  snap := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if snap = INVALID_HANDLE_VALUE then
    raise Exception.CreateFmt(
      'CreateToolhelp32Snapshot failed: %d (%s)',
      [GetLastError, SysErrorMessage(GetLastError)]);
  try
    pe.dwSize := SizeOf(pe);
    if Process32FirstW(snap, pe) then
      repeat
        if SameText(pe.szExeFile, exeName) then
          Exit(pe.th32ProcessID);
      until not Process32NextW(snap, pe);
  finally
    CloseHandle(snap);
  end;
end;

procedure ReportError(const what: string);
var
  err: DWORD;
begin
  err := GetLastError;
  // We may have detached our console partway through; try to reattach
  // to the parent so the error message has somewhere to land.
  AttachConsole(ATTACH_PARENT_PROCESS);
  Writeln(ErrOutput, Format('%s failed: %d (%s)',
                            [what, err, SysErrorMessage(err)]));
  Flush(ErrOutput);
  ExitCode := 1;
end;

var
  arg     : string;
  pid     : Cardinal;
  resolved: string;
begin
  try
    if ParamCount = 0 then begin
      pid := FindProcessByName('ConsoleTestRunner.exe');
      resolved := 'ConsoleTestRunner.exe';
      if pid = 0 then begin
        Writeln(ErrOutput, 'ConsoleTestRunner.exe not found. Pass a PID or a process name.');
        ExitCode := 1;
        Exit;
      end;
    end
    else begin
      arg := ParamStr(1);
      if not TryStrToUInt(arg, pid) then begin
        pid := FindProcessByName(arg);
        if pid = 0 then begin
          Writeln(ErrOutput, Format('Process "%s" not found.', [arg]));
          ExitCode := 1;
          Exit;
        end;
      end;
      resolved := arg;
    end;

    Writeln(Format('Sending CTRL_BREAK_EVENT to PID %d (%s)...', [pid, resolved]));
    Flush(Output);

    if not FreeConsole then begin
      ReportError('FreeConsole');
      Exit;
    end;
    if not AttachConsole(pid) then begin
      ReportError(Format('AttachConsole(%d)', [pid]));
      Exit;
    end;

    // Don't let the Ctrl+Break we're about to broadcast terminate us.
    SetConsoleCtrlHandler(nil, true);

    if not GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, 0) then begin
      ReportError('GenerateConsoleCtrlEvent');
      Exit;
    end;

    // Give the target's handler time to start before we vanish.
    Sleep(250);
  except
    on E: Exception do begin
      AttachConsole(ATTACH_PARENT_PROCESS);
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      Flush(ErrOutput);
      ExitCode := 1;
    end;
  end;
end.
