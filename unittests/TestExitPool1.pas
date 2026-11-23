unit TestExitPool1;

// Program must be able to exit while thread pool tasks are running. Tests start another copy of the
// test runner, which schedules tasks and exits; ExitPoolCheck then sets the exit code.

interface

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows, // before OTL units; also exports CreateThreadPool
  {$ENDIF MSWINDOWS}
  System.SysUtils, System.Classes, System.SyncObjs,
  DUnitX.TestFramework,
  ExitPoolCheck, OtlCommon, OtlSync, OtlTask, OtlTaskControl, OtlThreadPool, TestOtlBase;

type
  [TestFixture]
  TestExitPool = class(TOtlTestBase)
  strict private
    procedure RunChild(const mode: string);
  public
    [Test] procedure TestGlobalPool;
    [Test] procedure TestPrivatePool;
    [Test] procedure TestQueuedTasks;
    [Test] procedure TestScheduleWhileStopping;
  end;

implementation



const
  CChildSwitch = 'otlexitpool';

  CErrException    = 50;
  CErrQueuedRun    = 51;
  CErrNotCancelled = 52;

var
  GStarted: TEvent; // not an interface; must survive finalization of this unit
  GNumRun : integer;

procedure SlowTask(const task: IOmniTask);
var
  i: integer;
begin
  TInterlocked.Increment(GExitPoolRunning);
  try
    if TInterlocked.Increment(GNumRun) > 1 then
      if FindCmdLineSwitch('queued') then
        GExitPoolError := CErrQueuedRun;
    GStarted.SetEvent;
    for i := 1 to 20 do begin
      Sleep(10);
      if task.Name <> 'slow' then // accesses task controller
        raise Exception.Create('Invalid name');
    end;
  except
    GExitPoolError := CErrException;
  end;
  TInterlocked.Decrement(GExitPoolRunning);
end;

procedure SchedulingTask(const task: IOmniTask);
var
  i    : integer;
  inner: IOmniTaskControl;
  pool : IOmniThreadPool;
begin
  TInterlocked.Increment(GExitPoolRunning);
  try
    pool := task.Param['pool'].AsInterface as IOmniThreadPool;
    GStarted.SetEvent;
    i := 0;
    while (i < 500) and (not task.Terminated) do begin
      Sleep(10);
      Inc(i);
    end;
    // thread pool is being stopped
    inner := CreateTask(SlowTask, 'slow').Schedule(pool);
    if not inner.WaitFor(5000) then
      GExitPoolError := CErrNotCancelled
    else if inner.ExitCode <> EXIT_THREADPOOL_CANCELLED then
      GExitPoolError := CErrNotCancelled;
    pool.Cancel(inner.UniqueID);
    inner := nil;
    pool := nil;
  except
    GExitPoolError := CErrException;
  end;
  TInterlocked.Decrement(GExitPoolRunning);
end;

procedure RunInChild;
var
  i   : integer;
  pool: IOmniThreadPool;
begin
  GExitPoolActive := true;
  GStarted := TEvent.Create(nil, true, false, '');
  if FindCmdLineSwitch('global') then
    pool := GlobalOmniThreadPool
  else
    pool := OtlThreadPool.CreateThreadPool('exit pool');
  if FindCmdLineSwitch('queued') then
    pool.MaxExecuting := 1
  else
    pool.MaxExecuting := 4;
  if FindCmdLineSwitch('schedule') then
    CreateTask(SchedulingTask, 'scheduling').SetParameter('pool', pool).Unobserved.Schedule(pool)
  else
    for i := 1 to 4 do
      CreateTask(SlowTask, 'slow').Unobserved.Schedule(pool);
  GStarted.WaitFor(5000);
  pool := nil;
end;

{ TestExitPool }

procedure TestExitPool.RunChild(const mode: string);
{$IFDEF MSWINDOWS}
var
  exitCode: DWORD;
  cmdLine : string;
  procInfo: TProcessInformation;
  startup : TStartupInfo;
begin
  if not IsConsole then
   
    Exit;
  FillChar(startup, SizeOf(startup), 0);
  startup.cb := SizeOf(startup);
  cmdLine := Format('"%s" /%s /%s', [ParamStr(0), CChildSwitch, mode]);
  UniqueString(cmdLine);
  if not CreateProcess(nil, PChar(cmdLine), nil, nil, false, CREATE_NO_WINDOW, nil, nil, startup, procInfo) then
    RaiseLastOSError;
  try
    if WaitForSingleObject(procInfo.hProcess, 20000) <> WAIT_OBJECT_0 then begin
      TerminateProcess(procInfo.hProcess, 99);
      Assert.Fail('Child process did not exit');
    end;
    if not GetExitCodeProcess(procInfo.hProcess, exitCode) then
      RaiseLastOSError;
    Assert.AreEqual<integer>(CExitPoolOK, integer(exitCode), 'exit code');
  finally
    CloseHandle(procInfo.hThread);
    CloseHandle(procInfo.hProcess);
  end;
end;
{$ELSE}
begin
  Assert.Pass('Windows-only test');
end;
{$ENDIF MSWINDOWS}

procedure TestExitPool.TestGlobalPool;
begin
  RunChild('global');
end;

procedure TestExitPool.TestPrivatePool;
begin
  RunChild('private');
end;

procedure TestExitPool.TestQueuedTasks;
begin
  RunChild('queued');
end;

procedure TestExitPool.TestScheduleWhileStopping;
begin
  RunChild('schedule');
end;

initialization
  if FindCmdLineSwitch(CChildSwitch) then begin
    RunInChild;
    Halt(0);
  end;
  TDUnitX.RegisterTestFixture(TestExitPool);
end.
