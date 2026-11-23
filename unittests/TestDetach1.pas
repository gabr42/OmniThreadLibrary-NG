unit TestDetach1;

// Tests for tasks that do not stop when they are cancelled or terminated. Such task is
// detached: its thread is not killed and everything the task can use must stay alive until
// the task exits.

interface

uses
  System.SysUtils, System.Classes,
  DUnitX.TestFramework,
  OtlCommon, OtlTask, OtlTaskControl, OtlThreadPool,
  TestOtlBase;

type
  [TestFixture]
  TestDetachedTask = class(TOtlTestBase)
  strict private
    FDataFinished: integer;
    FError   : string;
    FFinished: integer;
    FRelease : integer;
    FSentinel: integer;
    FStarted : integer;
  strict protected
    function  MakeTask: IOmniTaskControl;
    function  MakeThreadData: IInterface;
    procedure CheckTaskSurvived;
    procedure RunAndDrop(const pool: IOmniThreadPool; howToStop: integer);
    procedure WaitForStart;
  public
    procedure StuckBody(const task: IOmniTask);
    [Setup] procedure SetUp;
    [TearDown] procedure TearDown;
  public
    [Test] procedure TestTerminatePooledAndDrop;
    [Test] procedure TestTerminateThreadAndDrop;
    [Test] procedure TestTerminateAtOnceAndDrop;
    [Test] procedure TestCancelAndDrop;
    [Test] procedure TestCancelAllAndDrop;
    [Test] procedure TestTerminateUnobserved;
    [Test] procedure TestTerminateWorkerAndDrop;
    [Test] procedure TestCancelPoolStaysFunctional;
    [Test] procedure TestStuckThreadData;
  end;

  [TestFixture]
  TestDetachedParallel = class(TOtlTestBase)
  public
    [Test] procedure TestJoinDrop;
    [Test] procedure TestJoinNotStarted;
    [Test] procedure TestJoinNoNewTasks;
    [Test] procedure TestParallelTaskDrop;
    [Test] procedure TestTimedTaskDrop;
  end;

  [TestFixture]
  TestPoolCancelStress = class(TOtlTestBase)
  strict protected
    function  MakeSlowThreadData: IInterface;
  public
    [Test] procedure TestCancel;
    [Test] procedure TestCancelAndCancelAll;
    [Test] procedure TestCancelWhileCompleting;
    [Test] procedure TestCancelBusyWorker;
    [Test] procedure TestCancelDoesNotExecute;
    [Test] procedure TestCancelAllDoesNotExecute;
  end;

implementation

uses
  System.SyncObjs, System.Diagnostics,
  OtlSync, OtlComm, OtlParallel;

const
  CWait_ms = 5000;

function Now_ms: int64;
begin
  Result := TStopwatch.GetTimeStamp * 1000 div TStopwatch.Frequency;
end;

function Elapsed_ms(start: int64): int64;
begin
  Result := Now_ms - start;
end;

type
  // Decrements the counter when destroyed.
  TSentinel = class(TInterfacedObject)
  strict private
    FCount: PInteger;
  public
    constructor Create(count: PInteger);
    destructor  Destroy; override;
  end;

  TStuckWorker = class(TOmniWorker)
  strict private
    FTest: TestDetachedTask;
  protected
    function  Initialize: boolean; override;
  public
    constructor Create(test: TestDetachedTask);
    procedure MsgStuck(var msg: TOmniMessage); message 1;
  end;

  TStuckThreadData = class(TInterfacedObject)
  strict private
    FFinished: PInteger;
    FRelease : PInteger;
  public
    constructor Create(release, finished: PInteger);
    destructor  Destroy; override;
  end;

function WaitForValue(var value: integer; expected: integer; timeout_ms: integer = CWait_ms): boolean;
var
  start: int64;
begin
  start := Now_ms;
  while (value <> expected) and (Elapsed_ms(start) < timeout_ms) do begin
    if TThread.CurrentThread.ThreadID = MainThreadID then
      CheckSynchronize(0);
    Sleep(1);
  end;
  Result := (value = expected);
end;

{ TSentinel }

constructor TSentinel.Create(count: PInteger);
begin
  inherited Create;
  FCount := count;
  TInterlocked.Increment(FCount^);
end;

destructor TSentinel.Destroy;
begin
  TInterlocked.Decrement(FCount^);
  inherited;
end;

{ TStuckWorker }

constructor TStuckWorker.Create(test: TestDetachedTask);
begin
  inherited Create;
  FTest := test;
end;

function TStuckWorker.Initialize: boolean;
begin
  Result := inherited Initialize;
end;

procedure TStuckWorker.MsgStuck(var msg: TOmniMessage);
begin
  FTest.StuckBody(Task);
end;

{ TStuckThreadData }

constructor TStuckThreadData.Create(release, finished: PInteger);
begin
  inherited Create;
  FRelease := release;
  FFinished := finished;
end;

destructor TStuckThreadData.Destroy;
var
  start: int64;
begin
  start := Now_ms;
  while (FRelease^ = 0) and (Elapsed_ms(start) < 10000) do
    Sleep(10);
  TInterlocked.Increment(FFinished^);
  inherited;
end;

{ TestDetachedTask }

procedure TestDetachedTask.SetUp;
begin
  FDataFinished := 0;
  FError := '';
  FFinished := 0;
  FRelease := 0;
  FSentinel := 0;
  FStarted := 0;
end;

procedure TestDetachedTask.TearDown;
begin
  // don't leave a running thread behind if the test has failed
  TInterlocked.Increment(FRelease);
  WaitForValue(FFinished, FStarted);
  Sleep(100);
end;

procedure TestDetachedTask.StuckBody(const task: IOmniTask);
var
  start: int64;
begin
  TInterlocked.Increment(FStarted);
  start := Now_ms;
  while (FRelease = 0) and (Elapsed_ms(start) < 10000) do
    Sleep(1);
  Sleep(50); // the test has released its reference
  try
    if task.CancellationToken.IsSignalled then
      ;
    task.Comm.Send(1, 'still alive');
    if task.Name <> 'stuck' then
      FError := 'Name: ' + task.Name;
    if task.Param['value'].AsInteger <> 42 then
      FError := 'Param';
    if not task.Terminated then
      FError := 'Terminated';
    task.SetExitStatus(1, 'done');
  except
    on E: Exception do
      FError := E.ClassName + ': ' + E.Message;
  end;
  TInterlocked.Increment(FFinished);
end;

function TestDetachedTask.MakeTask: IOmniTaskControl;
var
  sentinel: IInterface;
begin
  sentinel := TSentinel.Create(@FSentinel);
  Result := CreateTask(
    procedure (const task: IOmniTask)
    begin
      StuckBody(task);
    end,
    'stuck').SetParameter('value', 42).SetParameter('sentinel', sentinel);
end;

procedure TestDetachedTask.WaitForStart;
begin
  Assert.IsTrue(WaitForValue(FStarted, 1), 'Task did not start');
end;

procedure TestDetachedTask.CheckTaskSurvived;
begin
  Sleep(100);
  Assert.AreEqual<integer>(0, FFinished, 'Task should be still running');
  Assert.AreEqual<integer>(1, FSentinel, 'Task parameters were destroyed while the task is running');
  TInterlocked.Increment(FRelease);
  Assert.IsTrue(WaitForValue(FFinished, 1), 'Task was killed');
  Assert.AreEqual('', FError);
  Assert.IsTrue(WaitForValue(FSentinel, 0), 'Task controller is leaked');
end;

procedure TestDetachedTask.RunAndDrop(const pool: IOmniThreadPool; howToStop: integer);
var
  ctrl : IOmniTaskControl;
  start: int64;
begin
  ctrl := MakeTask;
  if assigned(pool) then
    ctrl.Schedule(pool)
  else
    ctrl.Run;
  WaitForStart;
  start := Now_ms;
  case howToStop of
    0: Assert.IsFalse(ctrl.Terminate(200), 'Terminate');
    1: Assert.IsFalse(pool.Cancel(ctrl.UniqueID, true, 200), 'Cancel');
    2: pool.CancelAll(true);
  end;
  Assert.IsTrue(Elapsed_ms(start) < 4000, 'Waited for too long');
end; // ctrl is destroyed here

procedure TestDetachedTask.TestTerminatePooledAndDrop;
var
  pool: IOmniThreadPool;
begin
  pool := CreateThreadPool('TestDetach');
  RunAndDrop(pool, 0);
  CheckTaskSurvived;
end;

procedure TestDetachedTask.TestTerminateThreadAndDrop;
begin
  RunAndDrop(nil, 0);
  CheckTaskSurvived;
end;

procedure TestDetachedTask.TestTerminateAtOnceAndDrop;
// Terminate(0) is called when the thread may be not executing the task yet.
var
  iRound: integer;

  procedure RunOne;
  var
    ctrl: IOmniTaskControl;
  begin
    ctrl := MakeTask;
    ctrl.Run;
    ctrl.Terminate(0);
  end;

begin
  TInterlocked.Increment(FRelease);
  for iRound := 1 to 100 do
    RunOne;
  Assert.IsTrue(WaitForValue(FSentinel, 0, 10000), 'Task controller is leaked');
  Assert.AreEqual<integer>(FStarted, FFinished, 'Task was killed');
  Assert.AreEqual('', FError);
end;

procedure TestDetachedTask.TestCancelAndDrop;
var
  pool: IOmniThreadPool;
begin
  pool := CreateThreadPool('TestDetach');
  RunAndDrop(pool, 1);
  CheckTaskSurvived;
end;

procedure TestDetachedTask.TestCancelAllAndDrop;
var
  pool: IOmniThreadPool;
begin
  pool := CreateThreadPool('TestDetach');
  pool.WaitOnTerminate_sec := 1;
  RunAndDrop(pool, 2);
  CheckTaskSurvived;
end;

procedure TestDetachedTask.TestTerminateUnobserved;
var
  ctrl: IOmniTaskControl;
begin
  ctrl := MakeTask.Unobserved.Run;
  WaitForStart;
  Assert.IsFalse(ctrl.Terminate(200), 'Terminate');
  ctrl := nil;
  Sleep(100);
  Assert.AreEqual<integer>(0, FFinished, 'Task should be still running');
  TInterlocked.Increment(FRelease);
  Assert.IsTrue(WaitForValue(FFinished, 1), 'Task was killed');
  Assert.AreEqual('', FError);
end;

procedure TestDetachedTask.TestTerminateWorkerAndDrop;

  procedure Run;
  var
    ctrl    : IOmniTaskControl;
    sentinel: IInterface;
  begin
    sentinel := TSentinel.Create(@FSentinel);
    ctrl := CreateTask(TStuckWorker.Create(Self) as IOmniWorker, 'stuck')
      .SetParameter('value', 42).SetParameter('sentinel', sentinel).Run;
    sentinel := nil;
    ctrl.Comm.Send(1);
    WaitForStart;
    Assert.IsFalse(ctrl.Terminate(200), 'Terminate');
  end;

begin
  Run;
  CheckTaskSurvived;
end;

procedure TestDetachedTask.TestCancelPoolStaysFunctional;
var
  ctrl  : IOmniTaskControl;
  pool  : IOmniThreadPool;
  worked: integer;
begin
  pool := CreateThreadPool('TestDetach');
  pool.MaxExecuting := 1;
  ctrl := MakeTask.Schedule(pool);
  WaitForStart;
  Assert.IsFalse(pool.Cancel(ctrl.UniqueID, true, 200), 'Cancel');
  worked := 0;
  CreateTask(
    procedure (const task: IOmniTask)
    begin
      TInterlocked.Increment(worked);
    end).Unobserved.Schedule(pool);
  Assert.IsTrue(WaitForValue(worked, 1), 'Pool is not functional');
  Assert.AreEqual<integer>(0, FFinished, 'Task should be still running');
  TInterlocked.Increment(FRelease);
  Assert.IsTrue(WaitForValue(FFinished, 1), 'Task was killed');
  Assert.IsTrue(ctrl.WaitFor(CWait_ms), 'WaitFor');
  Assert.AreEqual('', FError);
end;

function TestDetachedTask.MakeThreadData: IInterface;
begin
  Result := TStuckThreadData.Create(@FRelease, @FDataFinished);
end;

procedure TestDetachedTask.TestStuckThreadData;
// Worker that does not stop (here: because of thread data) is detached in the maintenance timer.
var
  pool  : IOmniThreadPool;
  worked: integer;

  procedure RunOne;
  begin
    worked := 0;
    CreateTask(
      procedure (const task: IOmniTask)
      begin
        TInterlocked.Increment(worked);
      end).Unobserved.Schedule(pool);
    Assert.IsTrue(WaitForValue(worked, 1), 'Task was not executed');
  end;

begin
  pool := CreateThreadPool('TestDetach');
  pool.SetThreadDataFactory(MakeThreadData);
  pool.IdleWorkerThreadTimeout_sec := 1;
  pool.WaitOnTerminate_sec := 1;
  RunOne;
  Sleep(5000); // idle timeout, WaitOnTerminate_sec and maintenance timer granularity
  Assert.AreEqual<integer>(0, FDataFinished, 'Thread data should be still in destructor');
  TInterlocked.Increment(FRelease);
  Assert.IsTrue(WaitForValue(FDataFinished, 1), 'Worker thread was killed');
  RunOne;
end;

{ TestDetachedParallel }

procedure TestDetachedParallel.TestJoinDrop;
var
  finished: integer;
  release : integer;
  sentinel: integer;
  started : integer;
  stopped : integer;

  procedure Run;
  var
    captured: IInterface;
    join    : IOmniParallelJoin;

    function MakeStop(const captured: IInterface): TProc;
    begin
      Result :=
        procedure
        begin
          if assigned(captured) then
            TInterlocked.Increment(stopped);
        end;
    end;

    function MakeTask: TProc;
    begin
      Result :=
        procedure
        var
          start: int64;
        begin
          TInterlocked.Increment(started);
          start := Now_ms;
          while (release = 0) and (Elapsed_ms(start) < 10000) do
            Sleep(1);
          TInterlocked.Increment(finished);
        end;
    end;

  begin
    captured := TSentinel.Create(@sentinel);
    join := Parallel.Join(MakeTask(), MakeTask()).NoWait.OnStop(MakeStop(captured)).Execute;
    captured := nil;
    Assert.IsTrue(WaitForValue(started, 2), 'Tasks did not start');
    Assert.IsFalse(join.Terminate(200), 'Terminate');
  end;

begin
  finished := 0;
  release := 0;
  sentinel := 0;
  started := 0;
  stopped := 0;
  Run;
  Sleep(100);
  Assert.AreEqual<integer>(0, finished, 'Tasks should be still running');
  Assert.AreEqual<integer>(1, sentinel, 'Join was destroyed while tasks are running');
  TInterlocked.Increment(release);
  Assert.IsTrue(WaitForValue(finished, 2), 'Tasks were killed');
  Assert.IsTrue(WaitForValue(sentinel, 0), 'Join is leaked');
  Assert.AreEqual<integer>(1, stopped, 'OnStop');
end;

procedure TestDetachedParallel.TestJoinNotStarted;
// Second task is waiting in the thread pool queue when Join is terminated.
var
  finished: integer;
  pool    : IOmniThreadPool;
  release : integer;
  sentinel: integer;
  started : integer;
  stopped : integer;

  procedure Run;
  var
    captured: IInterface;
    join    : IOmniParallelJoin;

    function MakeStop(const captured: IInterface): TProc;
    begin
      Result :=
        procedure
        begin
          if assigned(captured) then
            TInterlocked.Increment(stopped);
        end;
    end;

    function MakeTask: TProc;
    begin
      Result :=
        procedure
        var
          start: int64;
        begin
          TInterlocked.Increment(started);
          start := Now_ms;
          while (release = 0) and (Elapsed_ms(start) < 10000) do
            Sleep(1);
          TInterlocked.Increment(finished);
        end;
    end;

  begin
    captured := TSentinel.Create(@sentinel);
    join := Parallel.Join(MakeTask(), MakeTask())
      .TaskConfig(Parallel.TaskConfig.ThreadPool(pool))
      .NumTasks(2).NoWait.OnStop(MakeStop(captured)).Execute;
    captured := nil;
    Assert.IsTrue(WaitForValue(started, 1), 'Task did not start');
    Assert.IsFalse(join.Terminate(200), 'Terminate');
  end;

begin
  finished := 0;
  release := 0;
  sentinel := 0;
  started := 0;
  stopped := 0;
  pool := CreateThreadPool('TestDetach');
  pool.MaxExecuting := 1;
  Run;
  Sleep(100);
  Assert.AreEqual<integer>(1, sentinel, 'Join was destroyed while a task is running');
  TInterlocked.Increment(release);
  Assert.IsTrue(WaitForValue(sentinel, 0), 'Join is leaked');
  Assert.AreEqual<integer>(started, finished, 'Task was killed');
end;

procedure TestDetachedParallel.TestJoinNoNewTasks;
// Detached Join worker must not start executing other Join tasks.
var
  finished: integer;
  release : integer;
  second  : integer;
  started : integer;

  procedure Run;
  var
    join: IOmniParallelJoin;
  begin
    join := Parallel.Join(
      procedure
      var
        start: int64;
      begin
        TInterlocked.Increment(started);
        start := Now_ms;
        while (release = 0) and (Elapsed_ms(start) < 10000) do
          Sleep(1);
        TInterlocked.Increment(finished);
      end,
      procedure
      begin
        TInterlocked.Increment(second);
      end).NumTasks(1).NoWait.Execute;
    Assert.IsTrue(WaitForValue(started, 1), 'Task did not start');
    Assert.IsFalse(join.Terminate(200), 'Terminate');
  end;

begin
  finished := 0;
  release := 0;
  second := 0;
  started := 0;
  Run;
  TInterlocked.Increment(release);
  Assert.IsTrue(WaitForValue(finished, 1), 'Task was killed');
  Sleep(200);
  Assert.AreEqual<integer>(0, second, 'Second task was started after Terminate');
end;

procedure TestDetachedParallel.TestParallelTaskDrop;
var
  error   : string;
  finished: integer;
  release : integer;
  started : integer;

  procedure Run;
  var
    task: IOmniParallelTask;
  begin
    task := Parallel.ParallelTask.NumTasks(2).NoWait.Execute(
      procedure (const task: IOmniTask)
      var
        start: int64;
      begin
        TInterlocked.Increment(started);
        start := Now_ms;
        while (release = 0) and (Elapsed_ms(start) < 10000) do
          Sleep(1);
        try
          if task.CancellationToken.IsSignalled then
            ;
        except
          on E: Exception do
            error := E.ClassName + ': ' + E.Message;
        end;
        TInterlocked.Increment(finished);
      end);
    Assert.IsTrue(WaitForValue(started, 2), 'Tasks did not start');
    Assert.IsFalse(task.Terminate(200), 'Terminate');
  end;

begin
  error := '';
  finished := 0;
  release := 0;
  started := 0;
  Run;
  Sleep(100);
  Assert.AreEqual<integer>(0, finished, 'Tasks should be still running');
  TInterlocked.Increment(release);
  Assert.IsTrue(WaitForValue(finished, 2), 'Tasks were killed');
  Assert.AreEqual('', error);
  Sleep(100);
end;

procedure TestDetachedParallel.TestTimedTaskDrop;
var
  error   : string;
  finished: integer;
  release : integer;
  started : integer;

  procedure Run;
  var
    timed: IOmniTimedTask;
  begin
    timed := Parallel.TimedTask.Every(10).Execute(
      procedure (const task: IOmniTask)
      var
        start: int64;
      begin
        if TInterlocked.Increment(started) > 1 then
          Exit;
        start := Now_ms;
        while (release = 0) and (Elapsed_ms(start) < 10000) do
          Sleep(1);
        try
          if task.CancellationToken.IsSignalled then
            ;
          task.Comm.Send(1);
        except
          on E: Exception do
            error := E.ClassName + ': ' + E.Message;
        end;
        TInterlocked.Increment(finished);
      end);
    Assert.IsTrue(WaitForValue(started, 1), 'Task did not start');
    Assert.IsFalse(timed.Terminate(200), 'Terminate');
  end;

begin
  error := '';
  finished := 0;
  release := 0;
  started := 0;
  Run;
  Sleep(100);
  Assert.AreEqual<integer>(0, finished, 'Task should be still running');
  TInterlocked.Increment(release);
  Assert.IsTrue(WaitForValue(finished, 1), 'Task was killed');
  Assert.AreEqual('', error);
  Sleep(100);
end;

{ TestPoolCancelStress }

type
  TCancelStressThread = class(TThread)
  strict private
    FDuration_ms : integer;
    FPool        : IOmniThreadPool;
    FUseCancelAll: boolean;
    function  MakeTask: IOmniTaskControl;
  protected
    procedure Execute; override;
  public
    BadCancel    : integer;
    Error        : string;
    NotTerminated: integer;
    constructor Create(const pool: IOmniThreadPool; useCancelAll: boolean; duration_ms: integer);
  end;

constructor TCancelStressThread.Create(const pool: IOmniThreadPool; useCancelAll: boolean;
  duration_ms: integer);
begin
  FPool := pool;
  FUseCancelAll := useCancelAll;
  FDuration_ms := duration_ms;
  inherited Create(false);
end;

function TCancelStressThread.MakeTask: IOmniTaskControl;
begin
  Result := CreateTask(
    procedure (const task: IOmniTask)
    var
      n: integer;
    begin
      n := Random(4);
      while (n > 0) and (not task.CancellationToken.IsSignalled) and (not task.Terminated) do begin
        Sleep(1);
        Dec(n);
      end;
    end).Schedule(FPool);
end;

procedure TCancelStressThread.Execute;
const
  CBatch = 10;
var
  i    : integer;
  start: int64;
  tasks: array [1..CBatch] of IOmniTaskControl;
begin
  start := Now_ms;
  try
    while Elapsed_ms(start) < FDuration_ms do begin
      for i := 1 to CBatch do begin
        tasks[i] := MakeTask;
        if Random(3) = 0 then
          if not FPool.Cancel(tasks[i].UniqueID, true, 5000) then
            Inc(BadCancel);
      end;
      for i := 1 to 3 do
        if not FPool.Cancel(tasks[1 + Random(CBatch)].UniqueID, true, 5000) then
          Inc(BadCancel);
      if FUseCancelAll and (Random(10) = 0) then
        FPool.CancelAll(true);
      for i := 1 to CBatch do begin
        if not tasks[i].WaitFor(10000) then
          Inc(NotTerminated);
        tasks[i] := nil;
      end;
    end;
  except
    on E: Exception do
      Error := E.ClassName + ': ' + E.Message;
  end;
end;

procedure RunCancelStress(useCancelAll: boolean; duration_ms: integer);
const
  CThreads = 4;
var
  i      : integer;
  pool   : IOmniThreadPool;
  threads: array [1..CThreads] of TCancelStressThread;
begin
  pool := CreateThreadPool('cancel stress');
  pool.MaxExecuting := 4;
  for i := 1 to CThreads do
    threads[i] := TCancelStressThread.Create(pool, useCancelAll, duration_ms);
  try
    for i := 1 to CThreads do
      threads[i].WaitFor;
    Sleep(300);
    for i := 1 to CThreads do begin
      Assert.IsTrue(threads[i].Error = '', threads[i].Error);
      Assert.IsTrue(threads[i].NotTerminated = 0, 'Cancelled tasks did not terminate');
      Assert.IsTrue(threads[i].BadCancel = 0, 'Cancel returned False');
    end;
  finally
    for i := 1 to CThreads do
      FreeAndNil(threads[i]);
  end;
  Assert.IsTrue(pool.CountExecuting = 0, Format('CountExecuting = %d', [pool.CountExecuting]));
  Assert.IsTrue(pool.CountQueued = 0, Format('CountQueued = %d', [pool.CountQueued]));
  Assert.IsTrue(pool.IsIdle, 'Pool is not idle');
end;

procedure TestPoolCancelStress.TestCancel;
begin
  RunCancelStress(false, 3000);
end;

procedure TestPoolCancelStress.TestCancelAndCancelAll;
begin
  RunCancelStress(true, 3000);
end;

procedure TestPoolCancelStress.TestCancelWhileCompleting;
// Task is cancelled at the moment when it is completing. Timeout is 0 so a task can be also
// detached at that moment. Pool manager must survive that.
var
  ctrl  : IOmniTaskControl;
  iRound: integer;
  pool  : IOmniThreadPool;
  worked: integer;
begin
  pool := CreateThreadPool('cancel while completing');
  for iRound := 1 to 3000 do begin
    ctrl := CreateTask(
      procedure (const task: IOmniTask)
      begin
      end).Schedule(pool);
    if Odd(iRound) then
      Sleep(0);
    if (iRound mod 3) = 0 then
      ctrl.Terminate(0)
    else
      pool.Cancel(ctrl.UniqueID, true, 0);
    ctrl := nil;
  end;
  worked := 0;
  CreateTask(
    procedure (const task: IOmniTask)
    begin
      TInterlocked.Increment(worked);
    end).Unobserved.Schedule(pool);
  Assert.IsTrue(WaitForValue(worked, 1), 'Pool manager is not working');
end;

procedure RunCancelDoesNotExecute(useCancelAll: boolean);
// Cancelling a task that was not started yet must not execute that task. (It was executed in
// the thread pool manager, which was then blocked until the task exited.)
const
  CRounds   = 100;
  CStuck_ms = 3000;
var
  ctrl   : IOmniTaskControl;
  iRound : integer;
  pool   : IOmniThreadPool;
  release: integer;
  running: integer;
  start  : int64;
begin
  release := 0;
  running := 0;
  for iRound := 1 to CRounds do begin
    pool := CreateThreadPool('cancel does not execute');
    pool.WaitOnTerminate_sec := 1;
    ctrl := CreateTask(
      procedure (const task: IOmniTask)
      var
        start: int64;
      begin
        TInterlocked.Increment(running);
        start := Now_ms;
        while (release = 0) and (Elapsed_ms(start) < CStuck_ms) do
          Sleep(1);
        TInterlocked.Decrement(running);
      end).Schedule(pool);
    start := Now_ms;
    if useCancelAll then
      pool.CancelAll(true)
    else
      pool.Cancel(ctrl.UniqueID, true, 10);
    Assert.IsTrue(Elapsed_ms(start) < 2500,
      Format('Round %d: Task was executed in the thread pool manager', [iRound]));
    TInterlocked.Increment(release); // task may have been started before it was cancelled
    Assert.IsTrue(ctrl.WaitFor(CWait_ms), 'WaitFor');
    WaitForValue(running, 0);
    TInterlocked.Decrement(release);
    ctrl := nil;
    pool := nil;
  end;
end;

function TestPoolCancelStress.MakeSlowThreadData: IInterface;
begin
  Sleep(1000);
  Result := TInterfacedObject.Create;
end;

procedure TestPoolCancelStress.TestCancelBusyWorker;
// Worker thread is slow to start. Tasks that are sent to it and cancelled in the meantime must
// not fill its message queue.
var
  ctrl  : IOmniTaskControl;
  iRound: integer;
  pool  : IOmniThreadPool;
  worked: integer;
begin
  pool := CreateThreadPool('cancel busy worker');
  pool.MaxExecuting := 1;
  pool.SetThreadDataFactory(MakeSlowThreadData);
  for iRound := 1 to 300 do begin
    ctrl := CreateTask(
      procedure (const task: IOmniTask)
      begin
      end).Schedule(pool);
    pool.Cancel(ctrl.UniqueID, true, 0);
    Assert.IsTrue(ctrl.WaitFor(CWait_ms), 'WaitFor');
    ctrl := nil;
  end;
  worked := 0;
  CreateTask(
    procedure (const task: IOmniTask)
    begin
      TInterlocked.Increment(worked);
    end).Unobserved.Schedule(pool);
  Assert.IsTrue(WaitForValue(worked, 1), 'Pool manager is not working');
end;

procedure TestPoolCancelStress.TestCancelDoesNotExecute;
begin
  RunCancelDoesNotExecute(false);
end;

procedure TestPoolCancelStress.TestCancelAllDoesNotExecute;
begin
  RunCancelDoesNotExecute(true);
end;


initialization
  TDUnitX.RegisterTestFixture(TestDetachedTask);
  TDUnitX.RegisterTestFixture(TestDetachedParallel);
  TDUnitX.RegisterTestFixture(TestPoolCancelStress);
end.
