unit TestUnobserved;

// Tests for IOmniTaskControl.Unobserved — verifies task lifecycle management
// when the caller does not hold a reference to the task control.

interface

uses
  DUnitX.TestFramework,
  TestOtlBase;

type
  [TestFixture]
  TestUnobservedTask = class(TOtlTestBase)
  public
    // Basic completion tests
    [Test] procedure TestScheduleTaskRuns;
    [Test] procedure TestRunTaskRuns;

    // OnTerminated callback tests — task finishes before we wait
    [Test] procedure TestScheduleOnTerminatedFires_TaskFirst;
    [Test] procedure TestRunOnTerminatedFires_TaskFirst;
    // OnTerminated callback tests — we wait before task finishes
    [Test] procedure TestScheduleOnTerminatedFires_WaitFirst;
    [Test] procedure TestRunOnTerminatedFires_WaitFirst;
    [Test] procedure TestOnTerminatedReceivesValidTask;

    // Task control lifetime tests (ensures reference cycle is broken)
    [Test] procedure TestScheduleControlReleased;
    [Test] procedure TestRunControlReleased;

    // Stress tests (key regression for pool+Unobserved hang)
    [Test] procedure TestRepeatedSchedule;
    [Test] procedure TestRepeatedRun;
    [Test] procedure TestRepeatedScheduleWithOnTerminated;
    [Test] procedure TestRepeatedRunWithOnTerminated;

    // Edge cases
    [Test] procedure TestScheduleWithException;
    [Test] procedure TestRunWithException;
    [Test] procedure TestUnobservedCalledMultipleTimes;
  end;

implementation

uses
  System.Classes,
  System.SysUtils,
  System.Diagnostics,
  System.SyncObjs,
  OtlBackgroundObserver,
  OtlCommon,
  OtlSync,
  OtlTask,
  OtlTaskControl,
  {$IFDEF OTL_TRACE_PROBE}OtlTraceProbe,{$ENDIF}
  Winapi.Windows;

const
  CTimeout_ms         = 5000;
  // Diagnostic ceiling for the two-stage wait in TestRunControlReleased /
  // TestScheduleControlReleased. If the task control isn't released within
  // CTimeout_ms (the documented baseline) we still wait up to this longer
  // window so the failure message can report how long it actually took.
  // The test still fails when CTimeout_ms is missed — extending the wait
  // is purely for diagnostic value, not a soft pass.
  CExtendedTimeout_ms = 30000;
  CRepeatCount        = 50;

{ Sentinel for tracking task control lifetime.
  Increments a shared counter on creation, decrements on destruction.
  Optionally signals a destroy-event on destruction — the TestControl*
  tests wait on that event to observe destructor completion deterministically
  (polling the counter times out transiently under CPU load when the
  GUnobservedCleanup thread is backlogged or scheduler-delayed).
  Pass as a task parameter — the task control's parameter container holds
  a strong reference. When the task control is freed, the sentinel is
  released and the counter drops. }

type
  ISentinel = interface
    ['{3A7B2C1D-4E5F-6789-ABCD-EF0123456789}']
  end;

  TSentinel = class(TInterfacedObject, ISentinel)
  strict private
    FCount       : PInteger;
    FDestroyEvent: IOmniEvent;
  public
    constructor Create(count: PInteger; const destroyEvent: IOmniEvent = nil);
    destructor  Destroy; override;
  end;

constructor TSentinel.Create(count: PInteger; const destroyEvent: IOmniEvent);
begin
  inherited Create;
  FCount := count;
  FDestroyEvent := destroyEvent;
  TInterlocked.Increment(FCount^);
  {$IFDEF OTL_TRACE_PROBE}TraceMark('snt.create');{$ENDIF}
end;

destructor TSentinel.Destroy;
begin
  {$IFDEF OTL_TRACE_PROBE}TraceMark('snt.destroy.before');{$ENDIF}
  TInterlocked.Decrement(FCount^);
  if assigned(FDestroyEvent) then
    FDestroyEvent.SetEvent;
  {$IFDEF OTL_TRACE_PROBE}TraceMark('snt.destroy.after');{$ENDIF}
  inherited;
end;

{ Helper: wait for a boolean flag to become true, pumping the owner thread's
  delivery mechanism. On the main thread we call CheckSynchronize (which
  drains TThread.Queue/ForceQueue items). On a worker thread that owns a
  task (FMX runner dispatches tests on a worker), we call
  DrainBackgroundObservers to fire any OnTerminated/OnMessage callbacks the
  task has posted to this thread's bg-observer registry. }

function WaitForFlag(var flag: boolean; timeout_ms: cardinal): boolean;
var
  sw: TStopwatch;
  onMain: boolean;
begin
  onMain := TThread.CurrentThread.ThreadID = MainThreadID;
  sw := TStopwatch.StartNew;
  while (not flag) and (sw.ElapsedMilliseconds < timeout_ms) do begin
    if onMain then
      CheckSynchronize(10)
    else begin
      DrainBackgroundObservers;
      Sleep(10);
    end;
  end;
  Result := flag;
end;

{ Helper: wait for an integer to reach a target value. Same main-vs-worker
  dispatch discipline as WaitForFlag. }

function WaitForCount(var counter: integer; target: integer; timeout_ms: cardinal): boolean;
var
  sw: TStopwatch;
  onMain: boolean;
begin
  onMain := TThread.CurrentThread.ThreadID = MainThreadID;
  sw := TStopwatch.StartNew;
  while (counter <> target) and (sw.ElapsedMilliseconds < timeout_ms) do begin
    if onMain then
      CheckSynchronize(0)
    else
      DrainBackgroundObservers;
    Sleep(1);
  end;
  Result := counter = target;
end;

{ TestUnobservedTask }

procedure TestUnobservedTask.TestScheduleTaskRuns;
var
  event: IOmniEvent;
begin
  event := CreateOmniEvent(false, false);
  CreateTask(
    procedure (const task: IOmniTask)
    begin
      event.SetEvent;
    end, 'TestScheduleTaskRuns')
  .Unobserved
  .Schedule;
  Assert.IsTrue(event.WaitFor(CTimeout_ms) = wrSignaled,
    'Task did not run within timeout');
end;

procedure TestUnobservedTask.TestRunTaskRuns;
var
  event: IOmniEvent;
begin
  event := CreateOmniEvent(false, false);
  CreateTask(
    procedure (const task: IOmniTask)
    begin
      event.SetEvent;
    end, 'TestRunTaskRuns')
  .Unobserved
  .Run;
  Assert.IsTrue(event.WaitFor(CTimeout_ms) = wrSignaled,
    'Task did not run within timeout');
end;

procedure TestUnobservedTask.TestScheduleOnTerminatedFires_TaskFirst;
var
  terminated: boolean;
begin
  // Task finishes before we start waiting — ForceQueue already queued
  terminated := false;
  CreateTask(
    procedure (const task: IOmniTask)
    begin
      // minimal work — exits immediately
    end, 'TestScheduleOT_TaskFirst')
  .Unobserved
  .OnTerminated(
    procedure (const task: IOmniTaskControl)
    begin
      terminated := true;
    end)
  .Schedule;
  Sleep(500); // let task finish and ForceQueue fire before we pump
  Assert.IsTrue(WaitForFlag(terminated, CTimeout_ms),
    'OnTerminated was not called within timeout');
end;

procedure TestUnobservedTask.TestRunOnTerminatedFires_TaskFirst;
var
  terminated: boolean;
begin
  terminated := false;
  CreateTask(
    procedure (const task: IOmniTask)
    begin
      // minimal work — exits immediately
    end, 'TestRunOT_TaskFirst')
  .Unobserved
  .OnTerminated(
    procedure (const task: IOmniTaskControl)
    begin
      terminated := true;
    end)
  .Run;
  Sleep(500);
  Assert.IsTrue(WaitForFlag(terminated, CTimeout_ms),
    'OnTerminated was not called within timeout');
end;

procedure TestUnobservedTask.TestScheduleOnTerminatedFires_WaitFirst;
var
  terminated: boolean;
begin
  // We start pumping CheckSynchronize before the task finishes
  terminated := false;
  CreateTask(
    procedure (const task: IOmniTask)
    begin
      Sleep(500); // hold the task alive while test pumps
    end, 'TestScheduleOT_WaitFirst')
  .Unobserved
  .OnTerminated(
    procedure (const task: IOmniTaskControl)
    begin
      terminated := true;
    end)
  .Schedule;
  Assert.IsTrue(WaitForFlag(terminated, CTimeout_ms),
    'OnTerminated was not called within timeout');
end;

procedure TestUnobservedTask.TestRunOnTerminatedFires_WaitFirst;
var
  terminated: boolean;
begin
  terminated := false;
  CreateTask(
    procedure (const task: IOmniTask)
    begin
      Sleep(500);
    end, 'TestRunOT_WaitFirst')
  .Unobserved
  .OnTerminated(
    procedure (const task: IOmniTaskControl)
    begin
      terminated := true;
    end)
  .Run;
  Assert.IsTrue(WaitForFlag(terminated, CTimeout_ms),
    'OnTerminated was not called within timeout');
end;

procedure TestUnobservedTask.TestOnTerminatedReceivesValidTask;
var
  receivedTaskName: string;
  terminated      : boolean;
begin
  receivedTaskName := '';
  terminated := false;
  CreateTask(
    procedure (const task: IOmniTask)
    begin
      // minimal work
    end, 'NamedTestTask')
  .Unobserved
  .OnTerminated(
    procedure (const task: IOmniTaskControl)
    begin
      receivedTaskName := task.Name;
      terminated := true;
    end)
  .Schedule;
  Assert.IsTrue(WaitForFlag(terminated, CTimeout_ms),
    'OnTerminated was not called');
  Assert.AreEqual('NamedTestTask', receivedTaskName,
    'OnTerminated received wrong task');
end;

// Two-stage wait used by TestScheduleControlReleased / TestRunControlReleased.
// Stage 1 waits CTimeout_ms (5000 ms baseline). If the release event fires,
// returns silently. If not, marks an internal failure and proceeds to stage 2,
// which waits up to CExtendedTimeout_ms - CTimeout_ms more (25000 ms) purely
// to capture how long the release actually took. The test ALWAYS fails if
// stage 1 timed out — the extended wait just enriches the failure message
// with the real elapsed time, so we can decide whether the 5000 ms baseline
// is too tight on slow / loaded machines.
procedure AssertReleasedWithinBaseline(const releasedEvent: IOmniEvent;
  const sentinelCountP: PInteger; const opName: string);
{$IFDEF OTL_TRACE_PROBE}
var
  dumpFile: string;
{$ENDIF}
var
  elapsed_ms: int64;
  stopwatch : TStopwatch;
begin
  stopwatch := TStopwatch.StartNew;
  if releasedEvent.WaitFor(CTimeout_ms) = wrSignaled then
    Exit;
  // Stage 1 missed — diagnostic stage 2 waits longer to record the actual
  // release time, but the test fails either way.
  if releasedEvent.WaitFor(CExtendedTimeout_ms - CTimeout_ms) = wrSignaled then begin
    elapsed_ms := stopwatch.ElapsedMilliseconds;
    {$IFDEF OTL_TRACE_PROBE}
    dumpFile := Format('C:\Temp\otl_trace_%s_pid%d_%s.log',
      [opName, GetCurrentProcessId, FormatDateTime('hhnnss', Now)]);
    TraceDumpToFile(dumpFile);
    Assert.IsTrue(false,
      Format('Task control (%s) released after %d ms but missed the %d ms baseline (sentinel count=%d). Trace: %s',
        [opName, elapsed_ms, CTimeout_ms, sentinelCountP^, dumpFile]));
    {$ELSE}
    Assert.IsTrue(false,
      Format('Task control (%s) released after %d ms but missed the %d ms baseline (sentinel count=%d). Consider raising CTimeout_ms.',
        [opName, elapsed_ms, CTimeout_ms, sentinelCountP^]));
    {$ENDIF}
  end
  else begin
    {$IFDEF OTL_TRACE_PROBE}
    dumpFile := Format('C:\Temp\otl_trace_%s_pid%d_%s.log',
      [opName, GetCurrentProcessId, FormatDateTime('hhnnss', Now)]);
    TraceDumpToFile(dumpFile);
    Assert.IsTrue(false,
      Format('Task control (%s) was not released within %d ms (extended timeout, sentinel count=%d). Trace: %s',
        [opName, CExtendedTimeout_ms, sentinelCountP^, dumpFile]));
    {$ELSE}
    Assert.IsTrue(false,
      Format('Task control (%s) was not released within %d ms (extended timeout, sentinel count=%d)',
        [opName, CExtendedTimeout_ms, sentinelCountP^]));
    {$ENDIF}
  end;
end;

procedure ScheduleUnobservedWithSentinel(sentinel: IInterface; event: IOmniEvent);
begin
  CreateTask(
    procedure (const task: IOmniTask)
    begin
      event.SetEvent;
    end, 'TestScheduleControlReleased')
  .Unobserved
  .SetParameter('sentinel', sentinel)
  .Schedule;
end;

procedure TestUnobservedTask.TestScheduleControlReleased;
var
  sentinelCount : integer;
  sentinel      : IInterface;
  ranEvent      : IOmniEvent;
  releasedEvent : IOmniEvent;
begin
  // Deterministic: the sentinel destructor signals releasedEvent after
  // decrementing the counter, so we wait on that rather than polling. The
  // earlier polling version timed out transiently under full-suite CPU load
  // when the GUnobservedCleanup thread's scheduling was delayed — not a
  // real leak, just measurement-induced flake.
  {$IFDEF OTL_TRACE_PROBE}TraceEnable; try{$ENDIF}
  sentinelCount := 0;
  ranEvent      := CreateOmniEvent(false, false);
  releasedEvent := CreateOmniEvent(false, false);
  sentinel := TSentinel.Create(@sentinelCount, releasedEvent);
  ScheduleUnobservedWithSentinel(sentinel, ranEvent);
  sentinel := nil; // release our ref; task control holds it via parameters
  Assert.IsTrue(ranEvent.WaitFor(CTimeout_ms) = wrSignaled,
    'Task did not run');
  AssertReleasedWithinBaseline(releasedEvent, @sentinelCount, 'Schedule');
  Assert.AreEqual<integer>(0, sentinelCount,
    'Sentinel destructor signalled but counter was not zero');
  {$IFDEF OTL_TRACE_PROBE}finally TraceDisable; end;{$ENDIF}
end;

procedure RunUnobservedWithSentinel(sentinel: IInterface; event: IOmniEvent);
begin
  CreateTask(
    procedure (const task: IOmniTask)
    begin
      event.SetEvent;
    end, 'TestRunControlReleased')
  .Unobserved
  .SetParameter('sentinel', sentinel)
  .Run;
end;

procedure TestUnobservedTask.TestRunControlReleased;
var
  sentinelCount : integer;
  sentinel      : IInterface;
  ranEvent      : IOmniEvent;
  releasedEvent : IOmniEvent;
begin
  // See TestScheduleControlReleased for why this is event-driven rather
  // than polling.
  {$IFDEF OTL_TRACE_PROBE}TraceEnable; try{$ENDIF}
  sentinelCount := 0;
  ranEvent      := CreateOmniEvent(false, false);
  releasedEvent := CreateOmniEvent(false, false);
  sentinel := TSentinel.Create(@sentinelCount, releasedEvent);
  RunUnobservedWithSentinel(sentinel, ranEvent);
  sentinel := nil;
  Assert.IsTrue(ranEvent.WaitFor(CTimeout_ms) = wrSignaled,
    'Task did not run');
  AssertReleasedWithinBaseline(releasedEvent, @sentinelCount, 'Run');
  Assert.AreEqual<integer>(0, sentinelCount,
    'Sentinel destructor signalled but counter was not zero');
  {$IFDEF OTL_TRACE_PROBE}finally TraceDisable; end;{$ENDIF}
end;

procedure TestUnobservedTask.TestRepeatedSchedule;
var
  event: IOmniEvent;
  n    : integer;
begin
  // Key regression test: rapid-fire Unobserved+Schedule tasks must not
  // accumulate stale references and cause pool hangs.
  for n := 1 to CRepeatCount do begin
    event := CreateOmniEvent(false, false);
    CreateTask(
      procedure (const task: IOmniTask)
      begin
        event.SetEvent;
      end, 'TestRepeatedSchedule')
    .Unobserved
    .Schedule;
    Assert.IsTrue(event.WaitFor(CTimeout_ms) = wrSignaled,
      Format('Task %d did not run within timeout', [n]));
    if TThread.CurrentThread.ThreadID = MainThreadID then
      CheckSynchronize(0);
  end;
end;

procedure TestUnobservedTask.TestRepeatedRun;
var
  event: IOmniEvent;
  n    : integer;
begin
  for n := 1 to CRepeatCount do begin
    event := CreateOmniEvent(false, false);
    CreateTask(
      procedure (const task: IOmniTask)
      begin
        event.SetEvent;
      end, 'TestRepeatedRun')
    .Unobserved
    .Run;
    Assert.IsTrue(event.WaitFor(CTimeout_ms) = wrSignaled,
      Format('Task %d did not run within timeout', [n]));
    if TThread.CurrentThread.ThreadID = MainThreadID then
      CheckSynchronize(0);
  end;
end;

procedure TestUnobservedTask.TestRepeatedScheduleWithOnTerminated;
var
  terminatedCount: integer;
  n              : integer;
begin
  terminatedCount := 0;
  for n := 1 to CRepeatCount do begin
    CreateTask(
      procedure (const task: IOmniTask)
      begin
        // minimal work
      end, 'TestRepeatedScheduleOT')
    .Unobserved
    .OnTerminated(
      procedure (const task: IOmniTaskControl)
      begin
        TInterlocked.Increment(terminatedCount);
      end)
    .Schedule;
  end;
  Assert.IsTrue(WaitForCount(terminatedCount, CRepeatCount, CTimeout_ms * 2),
    Format('Expected %d OnTerminated calls, got %d', [CRepeatCount, terminatedCount]));
end;

procedure TestUnobservedTask.TestRepeatedRunWithOnTerminated;
var
  terminatedCount: integer;
  n              : integer;
begin
  terminatedCount := 0;
  for n := 1 to CRepeatCount do begin
    CreateTask(
      procedure (const task: IOmniTask)
      begin
        // minimal work
      end, 'TestRepeatedRunOT')
    .Unobserved
    .OnTerminated(
      procedure (const task: IOmniTaskControl)
      begin
        TInterlocked.Increment(terminatedCount);
      end)
    .Run;
  end;
  Assert.IsTrue(WaitForCount(terminatedCount, CRepeatCount, CTimeout_ms * 2),
    Format('Expected %d OnTerminated calls, got %d', [CRepeatCount, terminatedCount]));
end;

procedure TestUnobservedTask.TestScheduleWithException;
var
  event: IOmniEvent;
begin
  // Task raises an exception — must not hang or crash the runner.
  event := CreateOmniEvent(false, false);
  CreateTask(
    procedure (const task: IOmniTask)
    begin
      event.SetEvent;
      raise Exception.Create('intentional test exception');
    end, 'TestScheduleWithException')
  .Unobserved
  .Schedule;
  Assert.IsTrue(event.WaitFor(CTimeout_ms) = wrSignaled,
    'Task did not run within timeout');
end;

procedure TestUnobservedTask.TestRunWithException;
var
  event: IOmniEvent;
begin
  event := CreateOmniEvent(false, false);
  CreateTask(
    procedure (const task: IOmniTask)
    begin
      event.SetEvent;
      raise Exception.Create('intentional test exception');
    end, 'TestRunWithException')
  .Unobserved
  .Run;
  Assert.IsTrue(event.WaitFor(CTimeout_ms) = wrSignaled,
    'Task did not run within timeout');
end;

procedure TestUnobservedTask.TestUnobservedCalledMultipleTimes;
var
  event: IOmniEvent;
begin
  // Calling Unobserved multiple times must be idempotent.
  event := CreateOmniEvent(false, false);
  CreateTask(
    procedure (const task: IOmniTask)
    begin
      event.SetEvent;
    end, 'TestUnobservedIdempotent')
  .Unobserved
  .Unobserved
  .Unobserved
  .Schedule;
  Assert.IsTrue(event.WaitFor(CTimeout_ms) = wrSignaled,
    'Task did not run within timeout');
end;

{$IFDEF OTL_TRACE_PROBE}
initialization
  // Start a watchdog as soon as TestUnobserved is loaded — it dumps the
  // trace buffer every 2 seconds. If the test runner hangs and is killed
  // by the user, the most-recent snapshot survives. The dump file is
  // overwritten on every tick.
  TraceWatchdogStart(
    Format('C:\Temp\otl_trace_watchdog_pid%d.log', [GetCurrentProcessId]),
    2000);
{$ENDIF OTL_TRACE_PROBE}

end.
