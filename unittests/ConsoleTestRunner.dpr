program ConsoleTestRunner;

{$IFNDEF TESTINSIGHT}
{$APPTYPE CONSOLE}
{$ENDIF}
{$STRONGLINKTYPES ON}

{$DEFINE CONSOLE_TESTRUNNER}

uses
  {$IFDEF USE_MAD}
  madExcept,
  madLinkDisAsm,
  madListHardware,
  madListProcesses,
  madListModules,
  madStackTrace,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  Winapi.TlHelp32,
  {$ENDIF}
  System.Classes,
  System.SysUtils,
  System.DateUtils,
  System.Generics.Collections,
  System.SyncObjs,
  OtlHooks,
  OtlPlatform,
  {$IFDEF TESTINSIGHT}
  TestInsight.DUnitX,
  {$ELSE}
  DUnitX.Loggers.Console,
  DUnitX.AutoDetect.Console,
  {$ENDIF }
  DUnitX.TestFramework
  , TestOtlBase in 'TestOtlBase.pas'
  , SmokeTest in 'SmokeTest.pas'
  , TestRegressions in 'TestRegressions.pas'
  , TestBlockingCollection1 in 'TestBlockingCollection1.pas'
  , TestOtlDataManager1 in 'TestOtlDataManager1.pas'
  , TestOmniInterfaceDictionary in 'TestOmniInterfaceDictionary.pas'
  , TestOmniValue in 'TestOmniValue.pas'
  , TestValue in 'TestValue.pas'
  , TestPlatform in 'TestPlatform.pas'
  , TestInterlocked in 'TestInterlocked.pas'
  , TestContainers in 'TestContainers.pas'
  , TestOtlComm in 'TestOtlComm.pas'
  , TestOtlSync1 in 'TestOtlSync1.pas'
  , TestOtlCommon1 in 'TestOtlCommon1.pas'
  , TestContainerObserver1 in 'TestContainerObserver1.pas'
  , TestSyncUtils1 in 'TestSyncUtils1.pas'
  , TestBackgroundObserver1 in 'TestBackgroundObserver1.pas'
  , TestChannel1 in 'TestChannel1.pas'
  , TestSelect1 in 'TestSelect1.pas'
  , TestMergeRace1 in 'TestMergeRace1.pas'
  , TestHooks1 in 'TestHooks1.pas'
  , TestTask in 'TestTask.pas'
  , TestOtlParallel in 'TestOtlParallel.pas'
  , TestUnobserved in 'TestUnobserved.pas'
  , TestOtlThreadPool1 in 'TestOtlThreadPool1.pas'
  , TestOtlEventMonitor1 in 'TestOtlEventMonitor1.pas'
  , TestStressBlockingCollection1 in 'TestStressBlockingCollection1.pas'
  , TestStressOtlSync1 in 'TestStressOtlSync1.pas'
  , TestStressBackgroundObserver1 in 'TestStressBackgroundObserver1.pas'
  , TestStressContainerObserver1 in 'TestStressContainerObserver1.pas'
  , TestStressFutureInOmniTask in 'TestStressFutureInOmniTask.pas'
  , TestOtlLogger in 'TestOtlLogger.pas'
  , OtlThreadPool
  , OtlTaskControl
  ;

{$IFNDEF TESTINSIGHT}
var
  runner : ITestRunner;
  results: IRunResults;
  logger : ITestLogger;

//
// Thread-source registry: every OTL-created thread (pool worker or task
// thread) sends a tntCreate notification with its name. We hook that and
// record (TID, threadName, currentTest, destroyed-flag) so the Ctrl+Break
// dump can attribute each stuck thread back to the test that spawned it.
//
// The "current test" comes from a custom ITestLogger that updates
// GCurrentTestName at OnSetupTest / OnSetupFixture. Lock-free reads are
// unsafe for managed strings (refcount races), so all reads/writes go
// through GThreadRegistryLock.
//
type
  TThreadInfo = record
    TID       : TThreadID;
    ThreadName: string;
    SourceTest: string;
    Destroyed : boolean;
  end;

var
  GThreadRegistryLock: TCriticalSection;
  GThreadRegistry    : TList<TThreadInfo>;
  GCurrentTestName   : string;

// Per-test timing log: every OnBeginTest fires a start record and every
// OnEndTest fires an end record with elapsed ms. Used to track down which
// tests cause "near-hangs" — full-suite runs that take ~30 s longer than
// baseline. Comparing timing logs across runs surfaces tests with
// occasional slow-paths (e.g. pool teardown timing out on
// WaitOnTerminate_sec). Written to ConsoleTestRunner.timing.<stamp>.log.
var
  GTimingLog        : TextFile;
  GTimingLogOpen    : boolean;
  GTimingLogLock    : TCriticalSection;
  GCurrentTestStart : TDateTime;

procedure TrackerThreadNotify(notifyType: TThreadNotificationType;
  const threadName: string);
var
  i  : integer;
  rec: TThreadInfo;
begin
  GThreadRegistryLock.Acquire;
  try
    if notifyType = tntCreate then begin
      rec.TID        := TThread.CurrentThread.ThreadID;
      rec.ThreadName := threadName;
      rec.SourceTest := GCurrentTestName;
      rec.Destroyed  := false;
      GThreadRegistry.Add(rec);
    end
    else if notifyType = tntDestroy then
      // Mark the most recent live entry for this TID as destroyed.
      // Searching backward handles TID reuse correctly: the OS may recycle
      // a TID after the previous owner exited, so the freshest record wins.
      for i := GThreadRegistry.Count - 1 downto 0 do
        if (GThreadRegistry[i].TID = TThread.CurrentThread.ThreadID)
           and (not GThreadRegistry[i].Destroyed) then
        begin
          rec := GThreadRegistry[i];
          rec.Destroyed := true;
          GThreadRegistry[i] := rec;
          break;
        end;
  finally GThreadRegistryLock.Release; end;
end;

function FindThreadSource(tid: TThreadID): string;
var
  i: integer;
begin
  Result := '';
  GThreadRegistryLock.Acquire;
  try
    // Walk backward — most recent record for this TID wins (handles
    // TID reuse).
    for i := GThreadRegistry.Count - 1 downto 0 do
      if GThreadRegistry[i].TID = tid then begin
        if GThreadRegistry[i].Destroyed then
          Result := Format('"%s" [created during "%s"; tntDestroy fired]',
            [GThreadRegistry[i].ThreadName, GThreadRegistry[i].SourceTest])
        else
          Result := Format('"%s" [created during "%s"]',
            [GThreadRegistry[i].ThreadName, GThreadRegistry[i].SourceTest]);
        break;
      end;
  finally GThreadRegistryLock.Release; end;
end;

type
  // Empty-stub logger that only updates GCurrentTestName. Chained alongside
  // the standard console logger.
  TTestNameTracker = class(TInterfacedObject, ITestLogger)
  strict private
    procedure SetCurrentTest(const name: string);
  public
    procedure OnTestingStarts(const threadId: TThreadID; testCount, testActiveCount: Cardinal);
    procedure OnStartTestFixture(const threadId: TThreadID; const fixture: ITestFixtureInfo);
    procedure OnSetupFixture(const threadId: TThreadID; const fixture: ITestFixtureInfo);
    procedure OnEndSetupFixture(const threadId: TThreadID; const fixture: ITestFixtureInfo);
    procedure OnBeginTest(const threadId: TThreadID; const Test: ITestInfo);
    procedure OnSetupTest(const threadId: TThreadID; const Test: ITestInfo);
    procedure OnEndSetupTest(const threadId: TThreadID; const Test: ITestInfo);
    procedure OnExecuteTest(const threadId: TThreadID; const Test: ITestInfo);
    procedure OnTestSuccess(const threadId: TThreadID; const Test: ITestResult);
    procedure OnTestError(const threadId: TThreadID; const Error: ITestError);
    procedure OnTestFailure(const threadId: TThreadID; const Failure: ITestError);
    procedure OnTestIgnored(const threadId: TThreadID; const AIgnored: ITestResult);
    procedure OnTestMemoryLeak(const threadId: TThreadID; const Test: ITestResult);
    procedure OnLog(const logType: TLogLevel; const msg: string);
    procedure OnTeardownTest(const threadId: TThreadID; const Test: ITestInfo);
    procedure OnEndTeardownTest(const threadId: TThreadID; const Test: ITestInfo);
    procedure OnEndTest(const threadId: TThreadID; const Test: ITestResult);
    procedure OnTearDownFixture(const threadId: TThreadID; const fixture: ITestFixtureInfo);
    procedure OnEndTearDownFixture(const threadId: TThreadID; const fixture: ITestFixtureInfo);
    procedure OnEndTestFixture(const threadId: TThreadID; const results: IFixtureResult);
    procedure OnTestingEnds(const RunResults: IRunResults);
  end;

procedure TTestNameTracker.SetCurrentTest(const name: string);
begin
  GThreadRegistryLock.Acquire;
  try
    GCurrentTestName := name;
  finally GThreadRegistryLock.Release; end;
end;

procedure TTestNameTracker.OnTestingStarts(const threadId: TThreadID; testCount, testActiveCount: Cardinal);
begin SetCurrentTest('<before suite>'); end;

procedure TTestNameTracker.OnStartTestFixture(const threadId: TThreadID; const fixture: ITestFixtureInfo);
begin SetCurrentTest(fixture.FullName + '.<fixture>'); end;

procedure TTestNameTracker.OnSetupFixture(const threadId: TThreadID; const fixture: ITestFixtureInfo);
begin SetCurrentTest(fixture.FullName + '.SetupFixture'); end;

procedure TTestNameTracker.OnEndSetupFixture(const threadId: TThreadID; const fixture: ITestFixtureInfo);
begin end;

procedure TTestNameTracker.OnBeginTest(const threadId: TThreadID; const Test: ITestInfo);
var
  ts, line: string;
begin
  SetCurrentTest(Test.FullName);
  GTimingLogLock.Acquire;
  try
    GCurrentTestStart := Now;
    if GTimingLogOpen then begin
      ts := FormatDateTime('hh:nn:ss.zzz', GCurrentTestStart);
      line := '[' + ts + '] BEGIN ' + Test.FullName;
      System.Writeln(GTimingLog, line);
      System.Flush(GTimingLog);
    end;
  finally GTimingLogLock.Release; end;
end;

procedure TTestNameTracker.OnSetupTest(const threadId: TThreadID; const Test: ITestInfo);
begin SetCurrentTest(Test.FullName + '.SetUp'); end;

procedure TTestNameTracker.OnEndSetupTest(const threadId: TThreadID; const Test: ITestInfo);
begin SetCurrentTest(Test.FullName); end;

procedure TTestNameTracker.OnExecuteTest(const threadId: TThreadID; const Test: ITestInfo);
begin SetCurrentTest(Test.FullName); end;

procedure TTestNameTracker.OnTestSuccess(const threadId: TThreadID; const Test: ITestResult);
begin end;

procedure TTestNameTracker.OnTestError(const threadId: TThreadID; const Error: ITestError);
begin end;

procedure TTestNameTracker.OnTestFailure(const threadId: TThreadID; const Failure: ITestError);
begin end;

procedure TTestNameTracker.OnTestIgnored(const threadId: TThreadID; const AIgnored: ITestResult);
begin end;

procedure TTestNameTracker.OnTestMemoryLeak(const threadId: TThreadID; const Test: ITestResult);
begin end;

procedure TTestNameTracker.OnLog(const logType: TLogLevel; const msg: string);
begin end;

procedure TTestNameTracker.OnTeardownTest(const threadId: TThreadID; const Test: ITestInfo);
begin SetCurrentTest(Test.FullName + '.TearDown'); end;

procedure TTestNameTracker.OnEndTeardownTest(const threadId: TThreadID; const Test: ITestInfo);
begin end;

procedure TTestNameTracker.OnEndTest(const threadId: TThreadID; const Test: ITestResult);
var
  elapsed_ms: int64;
  ts, line  : string;
begin
  GTimingLogLock.Acquire;
  try
    if GTimingLogOpen and (GCurrentTestStart > 0) then begin
      elapsed_ms := System.DateUtils.MilliSecondsBetween(Now, GCurrentTestStart);
      ts := FormatDateTime('hh:nn:ss.zzz', Now);
      line := '[' + ts + '] END   ' + Test.Test.FullName +
              ' elapsed=' + IntToStr(elapsed_ms) + 'ms';
      System.Writeln(GTimingLog, line);
      System.Flush(GTimingLog);
    end;
  finally GTimingLogLock.Release; end;
  SetCurrentTest('<between tests>');
end;

procedure TTestNameTracker.OnTearDownFixture(const threadId: TThreadID; const fixture: ITestFixtureInfo);
begin SetCurrentTest(fixture.FullName + '.TearDownFixture'); end;

procedure TTestNameTracker.OnEndTearDownFixture(const threadId: TThreadID; const fixture: ITestFixtureInfo);
begin end;

procedure TTestNameTracker.OnEndTestFixture(const threadId: TThreadID; const results: IFixtureResult);
begin SetCurrentTest('<between fixtures>'); end;

procedure TTestNameTracker.OnTestingEnds(const RunResults: IRunResults);
begin SetCurrentTest('<after suite>'); end;

{$IFDEF USE_MAD}
const
  // OpenThread access flags - Winapi.Windows in modern Delphi doesn't expose these.
  THREAD_GET_CONTEXT       = $0008;
  THREAD_SUSPEND_RESUME    = $0002;
  THREAD_QUERY_INFORMATION = $0040;

  // ADDRESS_MODE values for STACKFRAME64.
  AddrModeFlat             = 3;

  // StackWalk64 machine-type values (from winnt.h).
  IMAGE_FILE_MACHINE_I386  = $014C;
  IMAGE_FILE_MACHINE_AMD64 = $8664;

type
  // Minimal STACKFRAME64 / ADDRESS64 / KDHELP64 layout from dbghelp.h.
  // Native (default) record alignment matches the C structs.
  TAddress64 = record
    Offset : UInt64;
    Segment: Word;
    Mode   : DWORD;  // ADDRESS_MODE enum, 4 bytes
  end;

  TKdHelp64 = record
    Thread          : UInt64;
    ThCallbackStack : DWORD;
    ThCallbackBStore: DWORD;
    NextCallback    : DWORD;
    FramePointer    : DWORD;
    KiCallUserMode  : UInt64;
    KeUserCallbackDispatcher : UInt64;
    SystemRangeStart: UInt64;
    KiUserExceptionDispatcher: UInt64;
    StackBase       : UInt64;
    StackLimit      : UInt64;
    BuildVersion    : DWORD;
    RetpolineStubFunctionTableSize: DWORD;
    RetpolineStubFunctionTable    : UInt64;
    RetpolineStubOffset           : DWORD;
    RetpolineStubSize             : DWORD;
    Reserved        : array[0..1] of UInt64;
  end;

  TStackFrame64 = record
    AddrPC        : TAddress64;
    AddrReturn    : TAddress64;
    AddrFrame     : TAddress64;
    AddrStack     : TAddress64;
    AddrBStore    : TAddress64;
    FuncTableEntry: Pointer;
    Params        : array[0..3] of UInt64;
    FarFlag       : BOOL;
    VirtualFlag   : BOOL;
    Reserved      : array[0..2] of UInt64;
    KdHelp        : TKdHelp64;
  end;

// Winapi.Windows declares OpenThreadToken but not OpenThread itself.
function OpenThread(dwDesiredAccess: DWORD; bInheritHandle: BOOL;
  dwThreadId: DWORD): THandle; stdcall; external kernel32 name 'OpenThread';

// DbgHelp imports for cross-thread stack walking. Pull these in directly so
// we don't need a separate Winapi.DbgHelp dependency.
function StackWalk64(MachineType: DWORD; hProcess, hThread: THandle;
  StackFrame: Pointer; ContextRecord: Pointer;
  ReadMemoryRoutine, FunctionTableAccessRoutine,
  GetModuleBaseRoutine, TranslateAddress: Pointer): BOOL;
  stdcall; external 'dbghelp.dll';

function SymFunctionTableAccess64(hProcess: THandle; AddrBase: UInt64): Pointer;
  stdcall; external 'dbghelp.dll';

function SymGetModuleBase64(hProcess: THandle; dwAddr: UInt64): UInt64;
  stdcall; external 'dbghelp.dll';

function SymInitializeW(hProcess: THandle; UserSearchPath: PWideChar;
  fInvadeProcess: BOOL): BOOL; stdcall; external 'dbghelp.dll';

//
// Ctrl+Break handler: when the user hits Ctrl+Break in the console window,
// Windows spins up a brand-new thread inside this process to run the handler
// below. That means we can dump every other thread's call stack regardless
// of whether the rest of the app is deadlocked, livelocked, or spinning.
//
// On laptop keyboards without a Break key, common substitutes are Fn+B,
// Ctrl+Fn+B, or Fn+Pause. The companion tool SendCtrlBreak.exe is the
// reliable way to trigger this through Remote Desktop.
//
// We walk each thread with DbgHelp's StackWalk64 (which works correctly
// against another thread's CONTEXT) and let madStackTrace.StackAddrToStr
// turn the resulting return addresses into Unit/Line/Function lines.
// madStackTrace.StackTrace itself ignores the supplied context and walks
// the calling thread, which is why we don't use it here.
//
procedure DumpThreadStackToFile(tid: DWORD; hThr: THandle; var f: TextFile);
var
  ctx      : CONTEXT;
  frame    : TStackFrame64;
  iFrame   : integer;
  machineTy: DWORD;
  s        : string;
begin
  Writeln(f);
  Writeln(f, Format('--- TID %d --- %s', [tid, FindThreadSource(tid)]));

  if SuspendThread(hThr) = DWORD(-1) then begin
    Writeln(f, Format('  SuspendThread failed: %d (%s)',
      [Winapi.Windows.GetLastError, SysErrorMessage(Winapi.Windows.GetLastError)]));
    Exit;
  end;
  try
    FillChar(ctx, SizeOf(ctx), 0);
    ctx.ContextFlags := CONTEXT_FULL;
    if not GetThreadContext(hThr, ctx) then begin
      Writeln(f, Format('  GetThreadContext failed: %d (%s)',
        [Winapi.Windows.GetLastError, SysErrorMessage(Winapi.Windows.GetLastError)]));
      Exit;
    end;

    FillChar(frame, SizeOf(frame), 0);
    frame.AddrPC.Mode    := AddrModeFlat;
    frame.AddrFrame.Mode := AddrModeFlat;
    frame.AddrStack.Mode := AddrModeFlat;
    {$IFDEF CPUX64}
    frame.AddrPC.Offset    := ctx.Rip;
    frame.AddrFrame.Offset := ctx.Rbp;
    frame.AddrStack.Offset := ctx.Rsp;
    machineTy := IMAGE_FILE_MACHINE_AMD64;
    {$ELSE}
    frame.AddrPC.Offset    := ctx.Eip;
    frame.AddrFrame.Offset := ctx.Ebp;
    frame.AddrStack.Offset := ctx.Esp;
    machineTy := IMAGE_FILE_MACHINE_I386;
    {$ENDIF}

    for iFrame := 0 to 63 do begin
      if not StackWalk64(machineTy, GetCurrentProcess, hThr, @frame, @ctx, nil,
                         @SymFunctionTableAccess64, @SymGetModuleBase64, nil)
      then
        break;
      if frame.AddrPC.Offset = 0 then
        break;
      try
        s := madStackTrace.StackAddrToStr(Pointer(NativeUInt(frame.AddrPC.Offset)));
      except
        on E: Exception do
          s := Format('%p  *** %s: %s',
            [Pointer(NativeUInt(frame.AddrPC.Offset)), E.ClassName, E.Message]);
      end;
      Writeln(f, '  ', s);
    end;
  finally
    ResumeThread(hThr);
  end;
end;

function CtrlBreakHandler(ctrlType: DWORD): BOOL; stdcall;
var
  exeDir  : string;
  f       : TextFile;
  filename: string;
  hThr    : THandle;
  myTid   : DWORD;
  pid     : DWORD;
  snap    : THandle;
  te      : TThreadEntry32;
begin
  Result := false;
  if ctrlType <> CTRL_BREAK_EVENT then
    Exit;

  pid   := GetCurrentProcessId;
  myTid := TThread.CurrentThread.ThreadID;

  exeDir := ExtractFilePath(ParamStr(0));
  filename := Format('%sConsoleTestRunner.stacks.%s.txt',
    [exeDir, FormatDateTime('yyyymmdd-hhnnss', Now)]);

  AssignFile(f, filename);
  try
    Rewrite(f);
  except
    on E: Exception do begin
      Writeln(ErrOutput, Format('Ctrl+Break: failed to create %s: %s: %s',
        [filename, E.ClassName, E.Message]));
      Flush(ErrOutput);
      Exit(true);
    end;
  end;

  try
    Writeln(f, '====== Ctrl+Break stack dump ======');
    Writeln(f, 'Process : ', ParamStr(0));
    Writeln(f, 'PID     : ', pid);
    Writeln(f, 'Time    : ', FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now));

    // Make sure DbgHelp's symbol engine can resolve every loaded module.
    // Returns FALSE if already initialized (e.g. by madExcept) — harmless.
    SymInitializeW(GetCurrentProcess, nil, true);

    snap := CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if snap = INVALID_HANDLE_VALUE then
      Writeln(f, Format('CreateToolhelp32Snapshot failed: %d (%s)',
        [Winapi.Windows.GetLastError, SysErrorMessage(Winapi.Windows.GetLastError)]))
    else
      try
        te.dwSize := SizeOf(te);
        if Thread32First(snap, te) then
          repeat
            if (te.th32OwnerProcessID <> pid) or (te.th32ThreadID = myTid) then
              continue;

            hThr := OpenThread(THREAD_GET_CONTEXT or THREAD_QUERY_INFORMATION
                               or THREAD_SUSPEND_RESUME, false, te.th32ThreadID);
            if hThr = 0 then begin
              Writeln(f);
              Writeln(f, Format('--- TID %d: OpenThread failed: %d (%s)',
                [te.th32ThreadID, Winapi.Windows.GetLastError,
                 SysErrorMessage(Winapi.Windows.GetLastError)]));
              continue;
            end;
            try
              DumpThreadStackToFile(te.th32ThreadID, hThr, f);
            finally
              CloseHandle(hThr);
            end;
          until not Thread32Next(snap, te);
      finally
        CloseHandle(snap);
      end;

    Writeln(f);
    Writeln(f, '====== End of stack dump ======');
  finally
    CloseFile(f);
  end;

  Writeln(ErrOutput);
  Writeln(ErrOutput, 'Ctrl+Break: stack dump written to ', filename);
  Flush(ErrOutput);

  Result := true; // handled - keep running
end;
{$ENDIF}

function HasAnyDUnitXFilterSwitch: boolean;
// Returns True if the command line contains any DUnitX filter flag
// (--run, --runlist, --include, --exclude, or their short forms).
// System.SysUtils.FindCmdLineSwitch only strips a single '-' or '/',
// so it misses DUnitX's double-dash form (`--include:Stress`).
const
  CFilters: array[0..7] of string = (
    'run', 'r', 'runlist', 'rl', 'include', 'i', 'exclude', 'e');
var
  body: string;
  colonPos: integer;
  filter: string;
  iParam: integer;
  param: string;
begin
  for iParam := 1 to ParamCount do begin
    param := ParamStr(iParam);
    if (param = '') or (not CharInSet(param[1], ['-', '/'])) then
      continue;
    body := param.Substring(1);
    if body.StartsWith('-') then
      body := body.Substring(1);
    colonPos := Pos(':', body);
    if colonPos > 0 then
      body := Copy(body, 1, colonPos - 1);
    for filter in CFilters do
      if SameText(body, filter) then
        Exit(True);
  end;
  Result := False;
end;
{$ENDIF}
begin
{$IFDEF TESTINSIGHT}
  TestInsight.DUnitX.RunRegisteredTests;
{$ELSE}
  try
    {$IFDEF USE_MAD}
    // Hit Ctrl+Break in the console (or Fn+B / Ctrl+Fn+B on laptops without
    // a Break key) to dump every thread's stack. Useful for diagnosing hangs
    // where it's not clear whether you're looking at a deadlock or livelock.
    SetConsoleCtrlHandler(@CtrlBreakHandler, true);
    {$ENDIF}

    // Thread-source registry: hook OTL thread create/destroy notifications
    // and chain a custom DUnitX logger that tracks the active test name.
    // The Ctrl+Break dump uses this to attribute each stuck thread back to
    // the test that spawned it.
    GThreadRegistryLock := TCriticalSection.Create;
    GThreadRegistry := TList<TThreadInfo>.Create;
    GCurrentTestName := '<startup>';
    OtlHooks.RegisterThreadNotification(TrackerThreadNotify);

    // Per-test timing log so post-mortem analysis of slow runs ("near-hangs")
    // can identify which specific test is the slow one without re-running.
    GTimingLogLock := TCriticalSection.Create;
    AssignFile(GTimingLog,
      Format('%sConsoleTestRunner.timing.%s.log',
        [ExtractFilePath(ParamStr(0)),
         FormatDateTime('yyyymmdd-hhnnss', Now)]));
    try
      Rewrite(GTimingLog);
      GTimingLogOpen := true;
    except GTimingLogOpen := false; end;

    // Default-exclude the Stress category so the standard run stays fast.
    // Any explicit filter flag (--run/--runlist/--include/--exclude or their
    // short forms) bypasses the default — otherwise the filter would AND with
    // it and still drop stress tests the caller asked for.
    if not HasAnyDUnitXFilterSwitch then
      TDUnitX.Options.Exclude := 'Stress';
    TDUnitX.CheckCommandLine;
    runner := TDUnitX.CreateRunner;
    runner.UseRTTI := True;
    logger := TDUnitXConsoleLogger.Create(false);
    runner.AddLogger(logger);
    runner.AddLogger(TTestNameTracker.Create as ITestLogger);
    results := runner.Execute;
    if not results.AllPassed then
      System.ExitCode := EXIT_ERRORS;

    // Diagnostic counters: report any thread leaks / risky sync paths so
    // they're visible without grepping logs.
    Writeln;
    Writeln('Diagnostic counters:');
    Writeln(Format('  GLeakedWorkerThreads                 = %d',
      [OtlThreadPool.GLeakedWorkerThreads]));
    Writeln(Format('  GTaskControlLeakedThreads            = %d',
      [OtlTaskControl.GTaskControlLeakedThreads]));
    Writeln(Format('  GUnobservedSelfDestroyCount          = %d',
      [OtlTaskControl.GUnobservedSelfDestroyCount]));
    Writeln(Format('  GUnobservedDispatcherSyncFromNonMain = %d',
      [OtlTaskControl.GUnobservedDispatcherSyncFromNonMain]));
    {$WARN SYMBOL_PLATFORM OFF}
    if DebugHook <> 0 then begin
      Write('> ');
      Readln;
    end;
    {$WARN SYMBOL_PLATFORM ON}
  except
    on E: Exception do
      System.Writeln(E.ClassName, ': ', E.Message);
  end;
{$ENDIF}
end.
