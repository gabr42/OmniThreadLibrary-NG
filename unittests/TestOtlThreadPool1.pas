unit TestOtlThreadPool1;

// Tests for IOmniThreadPool — pool lifecycle, scheduling, cancellation,
// worker recycling, and concurrent initialization of GlobalOmniThreadPool.

interface

uses
  DUnitX.TestFramework,
  TestOtlBase;

type
  [TestFixture]
  TestIOmniThreadPool = class(TOtlTestBase)
  public
    [Test] procedure TestGlobalPoolNotNil;
    [Test] procedure TestGlobalPoolIsSingleton;
    [Test] procedure TestGlobalPoolConcurrentFirstAccess;
    [Test] procedure TestCreateNamedPool;
    [Test] procedure TestScheduleTaskRuns;
    [Test] procedure TestScheduleManyTasks;
    [Test] procedure TestMaxExecutingLimitsConcurrency;
    [Test] procedure TestCountExecuting;
    [Test] procedure TestIsIdleAfterCompletion;
    [Test] procedure TestCancelAll;
    [Test] procedure TestCancelSingleTask;
    [Test] procedure TestWorkerRecycling;
    [Test] procedure TestIdleWorkerThreadTimeout;
    [Test] procedure TestForceKillStuckTask;
    [Test] procedure TestSetMinWorkers;
    [Test] procedure TestUniqueID;
  end;

implementation

uses
  System.Classes,
  System.SysUtils,
  System.Diagnostics,
  System.SyncObjs,
  OtlCommon,
  OtlHooks,
  OtlSync,
  OtlTask,
  OtlTaskControl,
  OtlThreadPool;

type
  // Counts thread create/destroy notifications for OTL thread-pool threads
  // (pool managers and workers). Lets a test verify that all threads it
  // spawned have actually exited before it returns — otherwise threads
  // pile up at later test boundaries and contend on the loader lock.
  TPoolThreadCounter = class
  strict private
    FLock      : TCriticalSection;
    FAliveNames: TStringList;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure Notify(notifyType: TThreadNotificationType; const threadName: string);
    function  Count: integer;
    function  AliveSummary: string;
  end;

const
  CTimeout_ms = 5000;

function WaitUntil(const predicate: TFunc<boolean>; timeout_ms: cardinal): boolean;
var
  sw: TStopwatch;
begin
  sw := TStopwatch.StartNew;
  while (not predicate()) and (sw.ElapsedMilliseconds < timeout_ms) do begin
    // Drain main-thread queued closures so OTL teardown work (e.g. the
    // TThread.Queue'd FinalizeUnobservedCommDispatcher drain that pins
    // a TaskControl until the main thread pumps) can complete. Without
    // this, those closures sit in the main thread's queue forever and
    // their captured TaskControl refs keep their owning pool alive.
    if TThread.CurrentThread.ThreadID = MainThreadID then
      CheckSynchronize(0);
    Sleep(5);
  end;
  Result := predicate();
end;

{ TPoolThreadCounter }

constructor TPoolThreadCounter.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FAliveNames := TStringList.Create;
  FAliveNames.Sorted := false;  // preserve insertion order
  FAliveNames.Duplicates := dupAccept;
end;

destructor TPoolThreadCounter.Destroy;
begin
  FreeAndNil(FAliveNames);
  FreeAndNil(FLock);
  inherited;
end;

procedure TPoolThreadCounter.Notify(notifyType: TThreadNotificationType;
  const threadName: string);
var
  idx: integer;
  tag: string;
begin
  // Match thread names emitted by OTL's pool plumbing:
  //   "OtlThreadPool worker"          (TOTPWorkerThread.Execute)
  //   "OmniThreadPool manager <name>" (TOmniWorker for pool, taskName)
  if (Pos('OtlThreadPool', threadName) = 0)
     and (Pos('OmniThreadPool manager', threadName) = 0)
  then
    Exit;
  // Disambiguate worker threads (which all share name "OtlThreadPool worker")
  // by appending TID so create/destroy match correctly.
  tag := Format('%s [TID %d]', [threadName, TThread.CurrentThread.ThreadID]);
  FLock.Enter;
  try
    if notifyType = tntCreate then
      FAliveNames.Add(tag)
    else begin
      idx := FAliveNames.IndexOf(tag);
      if idx >= 0 then
        FAliveNames.Delete(idx);
    end;
  finally FLock.Leave; end;
end;

function TPoolThreadCounter.Count: integer;
begin
  FLock.Enter;
  try Result := FAliveNames.Count;
  finally FLock.Leave; end;
end;

function TPoolThreadCounter.AliveSummary: string;
begin
  FLock.Enter;
  try Result := FAliveNames.CommaText;
  finally FLock.Leave; end;
end;

procedure TestIOmniThreadPool.TestGlobalPoolNotNil;
begin
  Assert.IsNotNull(GlobalOmniThreadPool, 'GlobalOmniThreadPool returned nil');
end;

procedure TestIOmniThreadPool.TestGlobalPoolIsSingleton;
var
  pool1, pool2: IOmniThreadPool;
begin
  pool1 := GlobalOmniThreadPool;
  pool2 := GlobalOmniThreadPool;
  Assert.AreEqual(pool1.UniqueID, pool2.UniqueID,
    'GlobalOmniThreadPool returned different instances on consecutive calls');
end;

procedure TestIOmniThreadPool.TestGlobalPoolConcurrentFirstAccess;
// Regression test for the 3.04 lazy-init race. We can't force the pool to
// be uninitialized here (the suite has likely already touched it), but we
// can still hammer GlobalOmniThreadPool from many threads and assert that
// every caller sees the same UniqueID. A gate event ensures all threads
// race the call roughly simultaneously.
const
  CThreadCount = 32;
var
  gate        : IOmniEvent;
  firstID     : int64;
  mismatchSeen: integer;
  threads     : TArray<TThread>;
  i           : integer;
begin
  firstID := GlobalOmniThreadPool.UniqueID;
  mismatchSeen := 0;
  gate := CreateOmniEvent(true, false);
  SetLength(threads, CThreadCount);
  for i := 0 to CThreadCount - 1 do
    threads[i] := TThread.CreateAnonymousThread(
      procedure
      var seenID: int64;
      begin
        gate.WaitFor(CTimeout_ms);
        seenID := GlobalOmniThreadPool.UniqueID;
        if seenID <> firstID then
          TInterlocked.Increment(mismatchSeen);
      end);
  for i := 0 to CThreadCount - 1 do begin
    threads[i].FreeOnTerminate := false;
    threads[i].Start;
  end;
  gate.SetEvent;
  for i := 0 to CThreadCount - 1 do begin
    threads[i].WaitFor;
    threads[i].Free;
  end;
  Assert.AreEqual(0, mismatchSeen,
    'GlobalOmniThreadPool returned different instances to concurrent callers');
end;

procedure TestIOmniThreadPool.TestCreateNamedPool;
var
  pool: IOmniThreadPool;
begin
  pool := CreateThreadPool('TestCreateNamedPool');
  try
    Assert.IsNotNull(pool, 'CreateThreadPool returned nil');
    Assert.AreEqual('TestCreateNamedPool', pool.Name, 'Pool name mismatch');
    Assert.AreNotEqual(GlobalOmniThreadPool.UniqueID, pool.UniqueID,
      'Named pool should have a different UniqueID from the global pool');
  finally pool := nil; end;
end;

procedure TestIOmniThreadPool.TestScheduleTaskRuns;
var
  event: IOmniEvent;
  pool : IOmniThreadPool;
begin
  event := CreateOmniEvent(false, false);
  pool := CreateThreadPool('TestScheduleTaskRuns');
  try
    CreateTask(
      procedure (const task: IOmniTask)
      begin
        event.SetEvent;
      end)
    .Unobserved
    .Schedule(pool);
    Assert.AreEqual(wrSignaled, event.WaitFor(CTimeout_ms),
      'Scheduled task did not run within timeout');
  finally pool := nil; end;
end;

procedure TestIOmniThreadPool.TestScheduleManyTasks;
const
  CTaskCount = 200;
var
  completed: integer;
  pool     : IOmniThreadPool;
  i        : integer;
begin
  completed := 0;
  pool := CreateThreadPool('TestScheduleManyTasks');
  try
    for i := 1 to CTaskCount do
      CreateTask(
        procedure (const task: IOmniTask)
        begin
          TInterlocked.Increment(completed);
        end)
      .Unobserved
      .Schedule(pool);
    Assert.IsTrue(
      WaitUntil(function: boolean begin Result := completed = CTaskCount; end,
        CTimeout_ms),
      Format('Only %d of %d tasks completed', [completed, CTaskCount]));
  finally pool := nil; end;
end;

procedure TestIOmniThreadPool.TestMaxExecutingLimitsConcurrency;
const
  CMaxExecuting = 2;
  CTaskCount    = 8;
var
  running    : integer;
  maxObserved: integer;
  completed  : integer;
  pool       : IOmniThreadPool;
  i          : integer;
begin
  running := 0;
  maxObserved := 0;
  completed := 0;
  pool := CreateThreadPool('TestMaxExecuting');
  try
    pool.MaxExecuting := CMaxExecuting;
    for i := 1 to CTaskCount do
      CreateTask(
        procedure (const task: IOmniTask)
        var current: integer;
        begin
          current := TInterlocked.Increment(running);
          try
            // TInterlocked has no atomic Max — small CAS loop.
            while true do begin
              var m := maxObserved;
              if current <= m then
                break;
              if TInterlocked.CompareExchange(maxObserved, current, m) = m then
                break;
            end;
            Sleep(100);
          finally
            TInterlocked.Decrement(running);
            TInterlocked.Increment(completed);
          end;
        end)
      .Unobserved
      .Schedule(pool);
    Assert.IsTrue(
      WaitUntil(function: boolean begin Result := completed = CTaskCount; end,
        CTimeout_ms * 2),
      Format('Only %d of %d tasks completed', [completed, CTaskCount]));
    Assert.IsTrue(maxObserved <= CMaxExecuting,
      Format('Observed %d concurrent tasks, MaxExecuting was %d',
        [maxObserved, CMaxExecuting]));
    Assert.IsTrue(maxObserved > 0, 'No task was observed running');
  finally pool := nil; end;
end;

procedure TestIOmniThreadPool.TestCountExecuting;
var
  release: IOmniEvent;
  started: IOmniEvent;
  pool   : IOmniThreadPool;
begin
  release := CreateOmniEvent(true, false);
  started := CreateOmniEvent(true, false);
  pool := CreateThreadPool('TestCountExecuting');
  try
    Assert.AreEqual(0, pool.CountExecuting, 'Pool should start with 0 executing');
    CreateTask(
      procedure (const task: IOmniTask)
      begin
        started.SetEvent;
        release.WaitFor(CTimeout_ms);
      end)
    .Unobserved
    .Schedule(pool);
    Assert.AreEqual(wrSignaled, started.WaitFor(CTimeout_ms),
      'Task did not start');
    Assert.IsTrue(
      WaitUntil(function: boolean begin Result := pool.CountExecuting >= 1; end,
        CTimeout_ms),
      'CountExecuting did not reach 1');
    release.SetEvent;
    Assert.IsTrue(
      WaitUntil(function: boolean begin Result := pool.CountExecuting = 0; end,
        CTimeout_ms),
      Format('CountExecuting did not return to 0 (still %d)',
        [pool.CountExecuting]));
  finally pool := nil; end;
end;

procedure TestIOmniThreadPool.TestIsIdleAfterCompletion;
var
  done: IOmniEvent;
  pool: IOmniThreadPool;
begin
  done := CreateOmniEvent(false, false);
  pool := CreateThreadPool('TestIsIdle');
  try
    CreateTask(
      procedure (const task: IOmniTask)
      begin
        Sleep(50);
        done.SetEvent;
      end)
    .Unobserved
    .Schedule(pool);
    Assert.AreEqual(wrSignaled, done.WaitFor(CTimeout_ms),
      'Task did not finish');
    Assert.IsTrue(
      WaitUntil(function: boolean begin Result := pool.IsIdle; end, CTimeout_ms),
      'Pool did not become idle after task completion');
  finally pool := nil; end;
end;

procedure TestIOmniThreadPool.TestCancelAll;
// The pool-using portion is in a nested procedure so its hidden interface
// temps (from `pool := CreateThreadPool(...)` and from the fluent
// `CreateTask(...).Unobserved.Schedule(pool)` chain) get released on its
// return — not at the end of the outer procedure. Without this nesting,
// those temps keep the pool alive throughout the teardown wait, the wait
// times out, and the pool manager only dies as the outer procedure
// unwinds. Confirmed empirically: wrapping in a nested proc moves
// refcount-to-0 from "30 s after pool := nil" to "immediately on RunPool
// return".
const
  CTaskCount = 20;
var
  counter: TPoolThreadCounter;

  procedure RunPool;
  var
    started : integer;
    finished: integer;
    release : IOmniEvent;
    pool    : IOmniThreadPool;
    i       : integer;
  begin
    started := 0;
    finished := 0;
    release := CreateOmniEvent(true, false);
    pool := CreateThreadPool('TestCancelAll');
    try
      pool.MaxExecuting := 4;
      for i := 1 to CTaskCount do
        CreateTask(
          procedure (const task: IOmniTask)
          begin
            TInterlocked.Increment(started);
            // Spin waiting for either release or cancellation.
            while (not task.CancellationToken.IsSignalled)
                  and (release.WaitFor(20) <> wrSignaled) do
              ;
            TInterlocked.Increment(finished);
          end)
        .Unobserved
        .Schedule(pool);
      // Wait for at least the first batch to start.
      Assert.IsTrue(
        WaitUntil(function: boolean begin Result := started >= 1; end, CTimeout_ms),
        'No task started before CancelAll');
      pool.CancelAll(true);
      release.SetEvent;
      Assert.IsTrue(
        WaitUntil(function: boolean begin Result := pool.IsIdle; end,
          CTimeout_ms * 2),
        'Pool did not become idle after CancelAll');
    finally pool := nil; end;
  end;

begin
  // Track pool-thread create/destroy so we can verify FULL teardown
  // (manager + workers) before this test returns. Without this wait,
  // pool destruction is asynchronous: pool.IsIdle becomes true and
  // pool := nil drops the test's ref, but workers are still running
  // their stop sequence and the manager TOmniWorker hasn't yet exited.
  // Those threads leak into later tests and pile up at the loader lock.
  counter := TPoolThreadCounter.Create;
  RegisterThreadNotification(counter.Notify);
  try
    RunPool;
    // Wait for FULL teardown: every pool thread that fired tntCreate
    // during this test must also have fired tntDestroy. Counter goes
    // back to <= 0 once the pool manager and all its workers exit.
    Assert.IsTrue(
      WaitUntil(function: boolean begin Result := counter.Count <= 0; end,
        CTimeout_ms),
      Format('Pool teardown incomplete — %d OTL threads still alive: %s',
        [counter.Count, counter.AliveSummary]));
  finally
    UnregisterThreadNotification(counter.Notify);
    counter.Free;
  end;
end;

// Standalone helper — per CLAUDE.md, capturing a for-loop variable into an
// anonymous method is unsafe in Delphi (the compiler reuses the closure's
// captured-state interface across iterations, even for inline `var`). The
// helper's parameters are fresh copies per call, so the returned closure
// captures the iteration-specific values correctly.
function MakeCancelTestWorker(idx: integer;
  const startEvent, releaseEvent: IOmniEvent;
  const cancelledArr: TArray<boolean>; finished: PInteger): TOmniTaskDelegate;
begin
  Result :=
    procedure (const task: IOmniTask)
    begin
      startEvent.SetEvent;
      while (not task.CancellationToken.IsSignalled)
            and (releaseEvent.WaitFor(20) <> wrSignaled) do
        ;
      if task.CancellationToken.IsSignalled then
        cancelledArr[idx] := true;
      TInterlocked.Increment(finished^);
    end;
end;

procedure TestIOmniThreadPool.TestCancelSingleTask;
// Schedules several concurrent tasks, then cancels one by its UniqueID and
// verifies that exactly that task received a cancellation signal while the
// others ran to completion normally.
const
  CTaskCount = 4;
var
  release     : IOmniEvent;
  started     : TArray<IOmniEvent>;
  cancelled   : TArray<boolean>;
  finished    : integer;
  taskControls: TArray<IOmniTaskControl>;
  pool        : IOmniThreadPool;
  i           : integer;
  cancelResult: boolean;
begin
  release := CreateOmniEvent(true, false);
  finished := 0;
  SetLength(started, CTaskCount);
  SetLength(cancelled, CTaskCount);
  SetLength(taskControls, CTaskCount);
  for i := 0 to CTaskCount - 1 do
    started[i] := CreateOmniEvent(true, false);
  pool := CreateThreadPool('TestCancelSingleTask');
  try
    pool.MaxExecuting := CTaskCount;
    for i := 0 to CTaskCount - 1 do
      taskControls[i] :=
        CreateTask(MakeCancelTestWorker(i, started[i], release, cancelled, @finished))
        .Unobserved
        .Schedule(pool);
    for i := 0 to CTaskCount - 1 do
      Assert.AreEqual(wrSignaled, started[i].WaitFor(CTimeout_ms),
        Format('Task %d did not start', [i]));
    cancelResult := pool.Cancel(taskControls[1].UniqueID, true, CTimeout_ms);
    Assert.IsTrue(cancelResult, 'Cancel returned false (force-kill was used)');
    release.SetEvent;
    Assert.IsTrue(
      WaitUntil(function: boolean begin Result := finished = CTaskCount; end,
        CTimeout_ms),
      Format('Only %d of %d tasks finished', [finished, CTaskCount]));
    Assert.IsTrue(cancelled[1],
      'Targeted task did not observe cancellation signal');
    for i := 0 to CTaskCount - 1 do
      if i <> 1 then
        Assert.IsFalse(cancelled[i],
          Format('Non-targeted task %d was unexpectedly cancelled', [i]));
  finally
    for i := 0 to CTaskCount - 1 do
      taskControls[i] := nil;
    pool := nil;
  end;
end;

procedure TestIOmniThreadPool.TestWorkerRecycling;
// Schedules several sequential tasks; with MaxExecuting=1 they must share
// a worker thread. Captures ThreadID from each run and asserts reuse.
const
  CRunCount = 10;
var
  threadIDs: TArray<NativeUInt>;
  done     : IOmniEvent;
  pool     : IOmniThreadPool;
  i        : integer;
  unique   : integer;
  j        : integer;
  seen     : boolean;
begin
  SetLength(threadIDs, CRunCount);
  pool := CreateThreadPool('TestWorkerRecycling');
  try
    pool.MaxExecuting := 1;
    pool.IdleWorkerThreadTimeout_sec := 60;
    for i := 0 to CRunCount - 1 do begin
      done := CreateOmniEvent(false, false);
      var idx := i;
      var localDone := done;
      CreateTask(
        procedure (const task: IOmniTask)
        begin
          threadIDs[idx] := TThread.CurrentThread.ThreadID;
          localDone.SetEvent;
        end)
      .Unobserved
      .Schedule(pool);
      Assert.AreEqual(wrSignaled, done.WaitFor(CTimeout_ms),
        Format('Task %d did not finish', [i]));
    end;
    unique := 0;
    for i := 0 to CRunCount - 1 do begin
      seen := false;
      for j := 0 to i - 1 do
        if threadIDs[j] = threadIDs[i] then begin
          seen := true;
          break;
        end;
      if not seen then
        Inc(unique);
    end;
    Assert.IsTrue(unique <= 2,
      Format('Expected worker reuse, observed %d distinct ThreadIDs across %d sequential tasks',
        [unique, CRunCount]));
  finally pool := nil; end;
end;

var
  GIdleTimeoutWorkerCount: integer;

function MakeIdleTimeoutWorkerData: IInterface;
begin
  TInterlocked.Increment(GIdleTimeoutWorkerCount);
  Result := nil;
end;

procedure TestIOmniThreadPool.TestIdleWorkerThreadTimeout;
// With IdleWorkerThreadTimeout_sec=1 and MinWorkers=0, a worker thread left
// idle for longer than the timeout must be torn down. The pool's maintenance
// timer fires every second, so we wait ~3s to be safe, then schedule a new
// task and assert the ThreadDataFactory was called a second time — proving
// the original worker was destroyed and a new one had to be created.
//
// Using ThreadDataFactory rather than ThreadID comparison because on POSIX
// pthread IDs can be recycled after a thread exits, making ThreadID an
// unreliable proxy for "same worker thread".
var
  done: IOmniEvent;
  pool: IOmniThreadPool;
  sw  : System.Diagnostics.TStopwatch;
begin
  GIdleTimeoutWorkerCount := 0;
  pool := CreateThreadPool('TestIdleWorkerThreadTimeout');
  try
    pool.MinWorkers := 0;
    pool.IdleWorkerThreadTimeout_sec := 1;
    pool.SetThreadDataFactory(MakeIdleTimeoutWorkerData);
    done := CreateOmniEvent(false, false);
    var localDone1 := done;
    CreateTask(
      procedure (const task: IOmniTask)
      begin
        localDone1.SetEvent;
      end)
    .Unobserved
    .Schedule(pool);
    Assert.AreEqual(wrSignaled, done.WaitFor(CTimeout_ms),
      'First task did not finish');
    Assert.IsTrue(
      WaitUntil(function: boolean begin Result := pool.IsIdle; end, CTimeout_ms),
      'Pool did not become idle after first task');
    Assert.AreEqual(1, GIdleTimeoutWorkerCount,
      'ThreadDataFactory should have been invoked exactly once for the first worker');
    // Wait longer than IdleWorkerThreadTimeout_sec + maintenance interval.
    sw := System.Diagnostics.TStopwatch.StartNew;
    while sw.ElapsedMilliseconds < 3000 do
      Sleep(50);
    done := CreateOmniEvent(false, false);
    var localDone2 := done;
    CreateTask(
      procedure (const task: IOmniTask)
      begin
        localDone2.SetEvent;
      end)
    .Unobserved
    .Schedule(pool);
    Assert.AreEqual(wrSignaled, done.WaitFor(CTimeout_ms),
      'Second task did not finish');
    Assert.AreEqual(2, GIdleTimeoutWorkerCount,
      Format('Expected 2 worker creations (idle worker should have been reaped), got %d',
        [GIdleTimeoutWorkerCount]));
  finally pool := nil; end;
end;

procedure TestIOmniThreadPool.TestForceKillStuckTask;
// A task that never checks CancellationToken and never returns cannot be
// stopped cleanly. Pool.Cancel(taskID, timeout) used to force-kill the worker
// on Windows via TerminateThread; that has been replaced with detach (the
// worker keeps running until its body exits naturally) because TerminateThread
// can leak the FastMM4 heap critical section and deadlock the entire process.
//
// On POSIX there's no safe force-kill either — pthread_cancel deadlocks
// inside pthread_join — so this test exists only on MSWINDOWS.
//
// New contract under test: Cancel(taskID, timeout) returns false (couldn't
// stop the task cleanly), AND the pool stays functional afterward.
//
// To avoid leaking the worker thread past this test (many leaked workers
// piling up at process/pool teardown contend on the Windows loader lock and
// can manifest as a process-wide hang), the "stuck" task now releases on a
// `release` event. The test sets that event AFTER its assertions and waits
// for the worker to actually finish, so the OS thread is gone by the time
// the next test starts.
{$IFNDEF MSWINDOWS}
begin
  Assert.Pass('Force-kill via TerminateThread is MSWINDOWS-only; POSIX has no safe equivalent');
end;
{$ELSE}
var
  started     : IOmniEvent;
  release     : IOmniEvent;
  finished    : IOmniEvent;
  afterKill   : IOmniEvent;
  taskControl : IOmniTaskControl;
  pool        : IOmniThreadPool;
  cancelResult: boolean;
begin
  started   := CreateOmniEvent(true, false);
  release   := CreateOmniEvent(true, false);  // manual-reset
  finished  := CreateOmniEvent(true, false);
  afterKill := CreateOmniEvent(false, false);
  pool := CreateThreadPool('TestForceKillStuckTask');
  try
    pool.WaitOnTerminate_sec := 1;
    pool.MaxExecuting := 4;
    taskControl :=
      CreateTask(
        procedure (const task: IOmniTask)
        begin
          started.SetEvent;
          // Deliberately ignores CancellationToken/Terminate so Cancel must
          // detach (was: force-kill). Stays "stuck" until the test sets
          // `release` post-assertion, then exits cleanly.
          while release.WaitFor(50) <> wrSignaled do
            ;
          finished.SetEvent;
        end)
      .Unobserved
      .Schedule(pool);
    Assert.AreEqual(wrSignaled, started.WaitFor(CTimeout_ms),
      'Stuck task did not start');
    // timeout_ms=200 — well below the WaitFor(50) cycle, forcing the pool
    // to give up cooperative-stop and detach the worker.
    cancelResult := pool.Cancel(taskControl.UniqueID, true, 200);
    Assert.IsFalse(cancelResult,
      'Cancel returned true — expected detach (false) for unresponsive task');
    // Pool.IsIdle is NOT checked: CountRunning is not decremented after the
    // worker is detached. Instead, verify the pool is still functional by
    // scheduling a new task.
    CreateTask(
      procedure (const task: IOmniTask)
      begin
        afterKill.SetEvent;
      end)
    .Unobserved
    .Schedule(pool);
    Assert.AreEqual(wrSignaled, afterKill.WaitFor(CTimeout_ms),
      'Pool no longer accepts work after detach');
    // Release the detached worker and wait for it to finish so it doesn't
    // linger past this test boundary.
    release.SetEvent;
    Assert.AreEqual(wrSignaled, finished.WaitFor(CTimeout_ms),
      'Detached task did not finish after release');
    // `finished` is set from user code, before OTL's task-wrapper epilogue
    // runs and before the OS thread leaves EndThread. Margin so the OS
    // thread has actually finished its DLL_THREAD_DETACH by the time the
    // next test starts.
    Sleep(200);
  finally
    taskControl := nil;
    pool := nil;
  end;
end;
{$ENDIF}

procedure TestIOmniThreadPool.TestSetMinWorkers;
var
  pool: IOmniThreadPool;
begin
  pool := CreateThreadPool('TestSetMinWorkers');
  try
    pool.MinWorkers := 2;
    Assert.AreEqual(2, pool.MinWorkers, 'MinWorkers round-trip failed');
    pool.MinWorkers := 0;
    Assert.AreEqual(0, pool.MinWorkers, 'MinWorkers=0 round-trip failed');
  finally pool := nil; end;
end;

procedure TestIOmniThreadPool.TestUniqueID;
var
  pool1, pool2: IOmniThreadPool;
begin
  pool1 := CreateThreadPool('TestUniqueID-1');
  pool2 := CreateThreadPool('TestUniqueID-2');
  try
    Assert.AreNotEqual(pool1.UniqueID, pool2.UniqueID,
      'Two pools should have distinct UniqueIDs');
    Assert.IsTrue(pool1.UniqueID > 0, 'UniqueID should be positive');
    Assert.IsTrue(pool2.UniqueID > 0, 'UniqueID should be positive');
  finally
    pool1 := nil;
    pool2 := nil;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TestIOmniThreadPool);
end.
