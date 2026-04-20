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
    [Test] procedure TestWorkerRecycling;
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
  OtlSync,
  OtlTask,
  OtlTaskControl,
  OtlThreadPool;

const
  CTimeout_ms = 5000;

function WaitUntil(const predicate: TFunc<boolean>; timeout_ms: cardinal): boolean;
var
  sw: TStopwatch;
begin
  sw := TStopwatch.StartNew;
  while (not predicate()) and (sw.ElapsedMilliseconds < timeout_ms) do
    Sleep(5);
  Result := predicate();
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
const
  CTaskCount = 20;
var
  started  : integer;
  finished : integer;
  release  : IOmniEvent;
  pool     : IOmniThreadPool;
  i        : integer;
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
