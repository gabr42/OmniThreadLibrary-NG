unit TestRegressions;

interface

uses
  DUnitX.TestFramework,
  TestOtlBase;

type
  [TestFixture]
  TestBugfixes = class(TOtlTestBase)
  {$IFDEF MSWINDOWS}
  strict private
    function  AllocatedBytes: NativeUInt;
    procedure RunBgObserverDeadTargetScenario(payloadSize: integer);
  {$ENDIF}
  public
    [Test]
    procedure TestTOmniValueArrayInt64Cast;
    [Test]
    procedure TestWaitForGateLeakRace;
    [Test]
    procedure TestTOmniValueUInt64HighBitRoundTrip;
    [Test]
    procedure TestPipelineClosureCapturePerStage;
    [Test]
    procedure TestPipelineCancelSignalsTokenBeforeFinalStageEmits;
    [Test]
    procedure TestUnobservedTaskInvokeDispatchesOnMainThread;
    [Test]
    procedure TestWaitForManyRawHandlesExternalSignal;
    [Test]
    procedure TestMsgWaitDeliversWMTimer;
    [Test]
    procedure TestOmniValueCreateLeakOnInvalidType;
    [Test]
    procedure TestBgObserverOnTerminatedFromBgThread;
    [Test]
    procedure TestBgObserverApcRefLeakOnDeadTarget;
    [Test]
    procedure TestTerminatedEventSurvivesControllerDestroy;
  end;

implementation

uses
  {$IFDEF MSWINDOWS}Winapi.Windows,{$ENDIF}
  System.Classes, System.SysUtils, System.SyncObjs, System.Diagnostics,
  System.Generics.Collections,
  OtlCommon, OtlSync, OtlParallel, OtlCollections, OtlTask, OtlTaskControl,
  OtlBackgroundObserver;

procedure TestBugfixes.TestTOmniValueArrayInt64Cast;
var
  arrIn : TArray<int64>;
  arrOut: TArray<int64>;
  ov    : TOmniValue;
begin
  // Issue #89

  arrIn := [1,2, $FFFFFFFF, $100000000, $FFFFFFFFFFFFFF];

  ov := TOmniValue.CastFrom<TArray<Int64>>(arrIn);

  arrOut := ov.CastTo<TArray<Int64>>;
end;

procedure TestBugfixes.TestWaitForGateLeakRace;
// Regression for commit ac3f364 (OtlSync.pas v3.02).
//
// TSynchroClient.EnterGate checked FController, called FController.FGate.Acquire
// which could block. While blocked, TWaitFor.Destroy could run Deref (nilling
// FController). When GetGate subsequently read FController it returned nil, so
// the finally block skipped releasing the lock — leaked forever, and the next
// SetEvent on the same synchro object would hang in EnterGate.
//
// The fix saves the gate reference to FAcquiredGate before acquiring, so
// GetGate returns it regardless of FController state.
//
// Reproduction: one thread cycles SetEvent/ResetEvent on an IOmniEvent (each
// goes through TOmniSynchroObject.PerformObservableAction, which enters the
// observer's gate). Another thread repeatedly creates and destroys a TWaitFor
// observing that event. The races between Destroy→Deref and EnterGate→Acquire
// hit the bug. Before the fix this stress run deadlocks within a few thousand
// iterations; with the fix it completes cleanly.
const
  CIterations  = 20000;
  CTimeout_ms  = 30000;
var
  event      : IOmniEvent;
  wfDone     : IOmniEvent;
  wfThread   : TThread;
  i          : integer;
begin
  event := CreateOmniEvent(true, false);
  wfDone := CreateOmniEvent(true, false);

  wfThread := TThread.CreateAnonymousThread(
    procedure
    var
      k: integer;
      wf: TWaitFor;
    begin
      try
        for k := 1 to CIterations do begin
          wf := TWaitFor.Create([event]);
          FreeAndNil(wf);
        end;
      finally wfDone.SetEvent; end;
    end);
  wfThread.FreeOnTerminate := false;
  wfThread.Start;
  try
    for i := 1 to CIterations do begin
      event.SetEvent;
      event.Reset;
    end;
    Assert.AreEqual(wrSignaled, wfDone.WaitFor(CTimeout_ms),
      'TWaitFor create/destroy thread deadlocked — gate-leak regression');
  finally
    wfThread.WaitFor;
    wfThread.Free;
  end;
end;

procedure TestBugfixes.TestTOmniValueUInt64HighBitRoundTrip;
// Regression for commit 24a5162 (OtlThreadPool TThreadID range-check fix).
//
// On POSIX `TThreadID = NativeUInt = uint64`, and on Android ARM64 the high
// bit is commonly set. TOTPWorkerThread.Execute used to send threadID via
// implicit TOmniValue conversion, which picks the int64 overload — with
// DCC_RangeChecking=true (as in OtlAndroidTests.dproj) this raised
// ERangeError for any high-bit value. The fix routes the value through
// TOmniValue.AsUInt64, which is bit-preserving.
//
// This test verifies that the chosen transport (AsUInt64 setter + getter)
// preserves all 64 bits including the high bit. {$R+} is enabled locally
// to catch any future regression where the property read path reintroduces
// a range-checked conversion.
//
// The actual pool-side bug is additionally regression-covered by the
// Android64 test run, where OtlAndroidTests.dproj sets DCC_RangeChecking=true
// and exercises the pool through TestOtlThreadPool1 and the many other
// tests that schedule work.
{$IFOPT R+}{$DEFINE OTL_RANGECHECK_WAS_ON}{$ENDIF}
{$R+}
const
  CHighBitPattern: uint64 = $FFFF000080000001;
var
  ov       : TOmniValue;
  roundTrip: uint64;
begin
  ov.AsUInt64 := CHighBitPattern;
  roundTrip := ov.AsUInt64;
  Assert.AreEqual(CHighBitPattern, roundTrip,
    'High-bit uint64 did not round-trip through TOmniValue');
end;
{$IFNDEF OTL_RANGECHECK_WAS_ON}{$R-}{$ENDIF}
{$UNDEF OTL_RANGECHECK_WAS_ON}

procedure TestBugfixes.TestPipelineClosureCapturePerStage;
// Regression for commit 579be5f (OtlParallel.pas v3.02).
//
// TOmniPipeline.Run had two closure-capture-in-loop bugs:
//
//   1. `outQueue` was a Run()-scope variable that the worker closure
//      captured by reference. The stage loop reassigned outQueue on
//      every iteration (to the current stage's output queue, or to
//      opOutput on the final iteration). By the time a worker
//      actually executed its except-block, outQueue held its final
//      value — always opOutput. A raising stage therefore routed its
//      exception directly to opOutput, bypassing all intermediate
//      stages' input queues.
//
//   2. `exc` was declared in Run()'s var block, above the closure, so
//      all worker closures shared the same variable. Two stages
//      raising concurrently would race on AcquireExceptionObject and
//      clobber each other's Exception pointer.
//
// Fix: moved `exc` inside the worker closure, and passed the
// per-stage outQueue through Task.Param['OutQueue'].
//
// Test design. The bug is observable only on stages that raise
// uncaught — simple-stage delegates catch internally, so this test
// uses TPipelineStageDelegate (input+output collections). Stage 1
// raises on input=5. Stage 2 is decorated with HandleExceptions so
// its input queue delivers exceptions as TOmniValue with
// IsException=true, and it converts them to a marker. Pipeline-level
// HandleExceptions prevents opOutput from re-raising so we can
// inspect any stray Exception values directly.
//
// Stage 1's delegate has no internal try/except, so the raise aborts
// its for-in loop after 4 successful outputs (x=1..4 → 2,4,6,8). The
// worker's except-block then adds the caught Exception to its output.
//
// Post-fix: Exception lands in stage 1's output (=stage 2's input);
// stage 2 sees it, frees it, emits one marker. Final opOutput: 4
// transformed values + 1 marker, no raw exceptions.
//
// Pre-fix: Exception lands in opOutput directly, bypassing stage 2.
// Stage 2 processes only 4 non-exception inputs. Final opOutput: 4
// transformed integers + 1 raw Exception value — detectable via
// IsException on TryTake results, with zero markers seen.
const
  CTimeout_ms   = 30000;
  CExceptMarker: int64 = -1;
var
  pipeline         : IOmniPipeline;
  i                : integer;
  markerSeen       : integer;
  exceptionsInOutput: integer;
  nonMarkerSum     : int64;
  valuesCount      : integer;
  ov               : TOmniValue;
begin
  pipeline := Parallel.Pipeline
    .HandleExceptions
    .Stage(
      procedure (const input, output: IOmniBlockingCollection)
      var
        value: TOmniValue;
      begin
        for value in input do begin
          if value.AsInt64 = 5 then
            raise Exception.Create('stage1-boom');
          output.Add(value.AsInt64 * 2);
        end;
      end)
    .Stage(
      procedure (const input, output: IOmniBlockingCollection)
      var
        value: TOmniValue;
      begin
        for value in input do begin
          if value.IsException then begin
            value.AsException.Free;
            output.Add(CExceptMarker);
          end
          else
            output.Add(value.AsInt64 * 3);
        end;
      end)
    .HandleExceptions
    .Run;

  for i := 1 to 10 do
    pipeline.Input.Add(int64(i));
  pipeline.Input.CompleteAdding;

  Assert.IsTrue(pipeline.WaitFor(CTimeout_ms),
    'Pipeline did not complete within timeout');

  markerSeen := 0;
  exceptionsInOutput := 0;
  nonMarkerSum := 0;
  valuesCount := 0;
  while pipeline.Output.TryTake(ov) do begin
    Inc(valuesCount);
    if ov.IsException then begin
      ov.AsException.Free;
      Inc(exceptionsInOutput);
    end
    else if ov.AsInt64 = CExceptMarker then
      Inc(markerSeen)
    else
      Inc(nonMarkerSum, ov.AsInt64);
  end;

  Assert.AreEqual(0, exceptionsInOutput,
    'Raw Exception reached opOutput — stage 1 bypassed stage 2 (outQueue closure-capture regression)');
  Assert.AreEqual(1, markerSeen,
    'Stage 2 did not observe stage 1''s exception via its input queue');
  Assert.AreEqual(5, valuesCount,
    'Pipeline output count wrong (expected 4 transformed values + 1 marker)');
  Assert.AreEqual(int64(6+12+18+24), nonMarkerSum,
    'Pipeline non-exception values did not transform through both stages');
end;

procedure TestBugfixes.TestPipelineCancelSignalsTokenBeforeFinalStageEmits;
// Regression for test_41_Pipeline / btnCancelPipe.
//
// TOmniPipeline.Cancel is a cascade: signal opCancelWith, CompleteAdding
// opInput, then CompleteAdding each opOutQueues entry in order (ending
// with opOutput). While Cancel works its way down the queue chain,
// worker threads keep running. A final stage whose loop exits as soon
// as its input is "drained AND completed" can leave the loop the
// moment Cancel marks that input, then race Cancel's CompleteAdding
// on opOutput. If the stage unconditionally emits after the loop, that
// final value lands in opOutput before Cancel can finalise it.
//
// test_41's StageSum hit this race: no CancellationToken.IsSignalled
// check around the post-loop output.TryAdd(sum), so after
// pipeline.Cancel the output sometimes contained a partial sum —
// surfacing as the demo's "*** ERROR *** there should be no data in
// the output pipe" log. The library's Cancel code is unchanged from
// the original OTL; timing shifts in OTL-NG simply made the race
// resolve against the demo more often.
//
// The invariant this test locks in: after pipeline.Cancel, every
// worker's task.CancellationToken is observably signalled, so a
// final stage that *does* guard its emission with
// `if not task.CancellationToken.IsSignalled then` will reliably
// leave the output empty.
//
// The test builds a 2-stage pipeline. Stage 1 generates a large,
// throttled stream so the pipeline cannot drain before Cancel fires.
// Stage 2 mirrors the fixed StageSum: reads until input is done,
// then emits only when CancellationToken is not signalled. After
// Sleep + Cancel + WaitFor, Output.TryTake must return false.
// Repeated to make a regression in the signal-propagation path
// detectable even on fast hardware.
const
  CIterations = 20;
  CTimeout_ms = 10000;
var
  k       : integer;
  pipeline: IOmniPipeline;
  value   : TOmniValue;
begin
  for k := 1 to CIterations do begin
    pipeline := Parallel.Pipeline
      .Throttle(102400)
      .Stage(
        procedure (const input, output: IOmniBlockingCollection; const task: IOmniTask)
        var
          i: integer;
        begin
          for i := 1 to 1000000 do begin
            if task.CancellationToken.IsSignalled then
              Exit;
            if not output.TryAdd(i) then
              Exit;
          end;
        end)
      .Stage(
        procedure (const input, output: IOmniBlockingCollection; const task: IOmniTask)
        var
          sum : integer;
          item: TOmniValue;
        begin
          sum := 0;
          for item in input do
            Inc(sum, item.AsInteger);
          if not task.CancellationToken.IsSignalled then
            output.TryAdd(sum);
        end)
      .Run;

    Sleep(50);
    pipeline.Cancel;
    Assert.IsTrue(pipeline.WaitFor(CTimeout_ms),
      Format('Iteration %d: pipeline.WaitFor timed out after Cancel', [k]));

    // Format must not read value.AsInteger eagerly: an empty TOmniValue on
    // Linux64 isn't guaranteed to land in ovtNull after a false TryTake and
    // the cast would raise before reaching the assert.
    Assert.IsFalse(pipeline.Output.TryTake(value),
      Format('Iteration %d: cancelled pipeline leaked data — ' +
             'CancellationToken was not signalled in final stage before its emission',
             [k]));
  end;
end;

procedure TestBugfixes.TestUnobservedTaskInvokeDispatchesOnMainThread;
// Regression for test_55_ForEachProgress / test_43_InvokeAnonymous behaviour
// after the Unobserved redesign (commit 153001d).
//
// The redesign stopped .Unobserved from calling CreateInternalMonitor,
// which eliminated the TaskControl<->EventMonitor ref cycle that leaked
// task controls in console apps. Side effect: Unobserved tasks no longer
// had any comm-queue dispatcher, so messages sent from the task body via
// task.Invoke(func) accumulated in the owner-side comm queue and func
// never fired on the owner thread — the demo progress bar stayed at 0%
// and OnStopInvoke-style closures never ran.
//
// Fix: .Unobserved installs a lightweight dispatcher (via
// InstallUnobservedCommDispatcher) that drains the comm queue without
// the ref cycle. For main-thread owners the observer posts drain
// callbacks to the main thread via TThread.ForceQueue; VCL's
// Application.Idle pumps CheckSynchronize automatically, console apps
// must drain it themselves (DUnitX's TOtlTestBase.TearDown does that,
// this test's spin loop also drains it during the wait).
//
// The test recreates the Parallel.ForEach(1..N).NoWait.OnStop.Execute
// pattern from test_55 with a main-thread owner. It asserts that both
// the per-iteration task.Invoke callback and the OnStop's task.Invoke
// callback run on the main thread.
const
  CNumLoop    = 200;
  CTimeout_ms = 15000;
var
  deadline_ms  : int64;
  dispatchedTID: TThreadID;
  invokedCount : integer;
  stopInvoked  : boolean;
  sw           : TStopwatch;
  worker       : IOmniParallelLoop<integer>;
begin
  if TThread.CurrentThread.ThreadID <> MainThreadID then begin
    // The FMX Android runner runs tests on a worker thread — it explicitly
    // cannot exercise TThread.ForceQueue's main-thread-pump semantics. The
    // ConsoleTestRunner on every other platform drives DUnitX from the
    // main thread where this test is meaningful.
    Assert.Pass('test runs only on the main thread; skipping on non-main-thread runner');
    Exit;
  end;

  invokedCount := 0;
  dispatchedTID := 0;
  stopInvoked := false;

  worker := Parallel.ForEach(1, CNumLoop)
    .NoWait
    .OnStop(
      procedure (const task: IOmniTask)
      begin
        task.Invoke(
          procedure
          begin
            stopInvoked := true;
          end);
      end);
  worker.Execute(
    procedure (const task: IOmniTask; const i: integer)
    begin
      // Small body work: let the main thread's drain catch up while the
      // tasks are still producing. Without this the pool workers race
      // through 200 trivial iterations and complete (and their TaskControls
      // are released by the Unobserved cleanup thread) before the main
      // thread gets to drain — any queued task.Invoke messages whose drain
      // closure hadn't fired yet then become no-ops (the dispatcher has
      // been cleared by Destroy). That is a latent tail-drain limitation
      // common to Unobserved + cheap bodies; it matches the real-world
      // test_55 demo which also sleeps per iter.
      Sleep(1);
      task.Invoke(
        procedure
        begin
          Inc(invokedCount);
          if dispatchedTID = 0 then
            dispatchedTID := TThread.CurrentThread.ThreadID;
        end);
    end);

  // Drive CheckSynchronize on the main thread until both the per-iteration
  // callbacks and the OnStop callback have all fired, or we time out.
  // Keep worker alive until after the assertions: once worker := nil the
  // TaskControls run Destroy, which clears their dispatchers and makes any
  // late main-thread drain closures no-ops.
  sw := TStopwatch.StartNew;
  deadline_ms := CTimeout_ms;
  while ((invokedCount < CNumLoop) or (not stopInvoked))
        and (sw.ElapsedMilliseconds < deadline_ms)
  do begin
    CheckSynchronize(10);
  end;

  try
    Assert.AreEqual(CNumLoop, invokedCount,
      Format('Only %d of %d per-iteration task.Invoke callbacks fired — ' +
             'Unobserved comm dispatcher is not draining the owner queue',
             [invokedCount, CNumLoop]));
    Assert.IsTrue(stopInvoked,
      'OnStop''s task.Invoke callback did not fire on the main thread');
    Assert.AreEqual(MainThreadID, dispatchedTID,
      'task.Invoke callback ran on a non-main-thread');
  finally
    worker := nil; // release after asserts so late callbacks aren't gated off
  end;
end;

procedure TestBugfixes.TestWaitForManyRawHandlesExternalSignal;
// Regression for test_59_TWaitFor (130 raw HANDLEs) after the CV-based
// TWaitFor rewrite. The old OTL v3 used WaitForMultipleObjects for
// <= 64 handles and RegisterWaitForSingleObject for > 64 handles.
// OTL-NG's initial rewrite kept only the WaitForMultipleObjects fast
// path and relied on an observer-based slow path for the > 64 case.
//
// That broke TWaitFor.Create(array of THandle) with > 64 raw HANDLEs:
// externally signalling one via Windows.SetEvent updates the kernel
// event but does NOT route through IOmniEvent.SetEvent, so none of
// OTL's observer/CV notifications ever fire and the slow path waits
// out the full timeout. Visible break in test_59's "second button"
// (`btnWaitForAnyClick` with 130 handles): the per-handle WaitAny(100)
// returned waTimeout (1) instead of waAwaited (0).
//
// Fix: TCondition.TryKernelLargeSet — when the handle count is above
// MAXIMUM_WAIT_OBJECTS and every synch object has a kernel HANDLE, use
// RegisterWaitForSingleObject to dispatch per-handle signals into a
// manual-reset shared event (WaitAny) or a resource count (WaitAll).
// Mirrors the v3 behaviour.
{$IFDEF MSWINDOWS}
const
  CHandleCount = 130;
  CTimeout_ms  = 2000;
var
  handles : array of THandle;
  i       : integer;
  waiter  : TWaitFor;
  target  : integer;
begin
  SetLength(handles, CHandleCount);
  for i := 0 to CHandleCount - 1 do
    handles[i] := Winapi.Windows.CreateEvent(nil, False {auto-reset}, False, nil);
  waiter := TWaitFor.Create(handles);
  try
    // A: nothing signalled — must time out within the timeout, not hang.
    Assert.AreEqual(Ord(TWaitFor.TWaitForResult.waTimeout),
      Ord(waiter.WaitAny(100)),
      'WaitAny with no signal should time out');

    // B: signal a specific handle in the middle of the set; WaitAny must
    //    wake and report exactly that index.
    target := 97;
    Winapi.Windows.SetEvent(handles[target]);
    Assert.AreEqual(Ord(TWaitFor.TWaitForResult.waAwaited),
      Ord(waiter.WaitAny(CTimeout_ms)),
      Format('WaitAny did not wake on external SetEvent of handle %d ' +
             '(> MAXIMUM_WAIT_OBJECTS path)', [target]));
    Assert.AreEqual(integer(1), integer(Length(waiter.Signalled)),
      'Signalled set should contain exactly one entry');
    Assert.AreEqual(integer(target), integer(waiter.Signalled[0].Index),
      Format('Wrong Signalled.Index (expected %d)', [target]));
  finally
    waiter.Free;
    for i := 0 to CHandleCount - 1 do
      Winapi.Windows.CloseHandle(handles[i]);
  end;
end;
{$ELSE}
begin
  Assert.Pass('Windows-only test: raw HANDLE array is not available on POSIX');
end;
{$ENDIF MSWINDOWS}

{$IFDEF MSWINDOWS}
type
  TMsgWaitTimerWorker = class(TOmniWorker)
  strict private
    FTimerID: UINT_PTR;
  protected
    function  Initialize: boolean; override;
    procedure Cleanup; override;
  end;

var
  GMsgWaitTimerFires: integer = 0;
  GMsgWaitTimerThreadID: cardinal = 0;

procedure MsgWaitTimerProc(hwnd: HWND; uMsg: UINT; idEvent: UINT_PTR; dwTime: DWORD); stdcall;
begin
  // Capture the thread we were dispatched on so the test can prove we weren't
  // piggy-backing on the main thread's message pump.
  TInterlocked.CompareExchange(integer(GMsgWaitTimerThreadID),
    integer(Winapi.Windows.GetCurrentThreadId), 0);
  TInterlocked.Increment(GMsgWaitTimerFires);
end;

function TMsgWaitTimerWorker.Initialize: boolean;
begin
  Result := inherited Initialize;
  if not Result then Exit;
  // Thread-owned WM_TIMER: hwnd=0 posts to the calling thread's queue. The
  // task's message loop must Translate/Dispatch for TimerProc to fire.
  FTimerID := Winapi.Windows.SetTimer(0, 0, 20, @MsgWaitTimerProc);
  Result := FTimerID <> 0;
end;

procedure TMsgWaitTimerWorker.Cleanup;
begin
  if FTimerID <> 0 then begin
    Winapi.Windows.KillTimer(0, FTimerID);
    FTimerID := 0;
  end;
  inherited Cleanup;
end;
{$ENDIF MSWINDOWS}

procedure TestBugfixes.TestMsgWaitDeliversWMTimer;
// Regression for the .MsgWait reinstatement.
//
// A TOmniWorker that uses Windows timers (TTimer / Win32 SetTimer) relies on
// the task's message loop pumping WM_TIMER. Without .MsgWait the task waits
// only on its comm/terminate handles and never drains the thread queue, so
// WM_TIMER never fires. Chaining .MsgWait routes the wait through
// MsgWaitForMultipleObjectsEx; on waMessage the task loop runs
// PeekMessage/Translate/Dispatch, which delivers WM_TIMER to the registered
// TimerProc.
//
// Test: SetTimer(hwnd=0) in the worker's Initialize, count callbacks via
// global atomic. Assert that several fire within the deadline and that the
// callback's thread is the task thread (not the test thread).
{$IFDEF MSWINDOWS}
const
  CDeadline_ms      = 3000;
  CMinExpectedFires = 3;
var
  task: IOmniTaskControl;
  sw  : TStopwatch;
begin
  GMsgWaitTimerFires    := 0;
  GMsgWaitTimerThreadID := 0;

  task := CreateTask(TMsgWaitTimerWorker.Create() as IOmniWorker, 'msg-wait-timer')
          .MsgWait
          .Run;
  try
    sw := TStopwatch.StartNew;
    while (GMsgWaitTimerFires < CMinExpectedFires) and
          (sw.ElapsedMilliseconds < CDeadline_ms)
    do
      Sleep(10);

    Assert.IsTrue(GMsgWaitTimerFires >= CMinExpectedFires,
      Format('WM_TIMER not delivered via .MsgWait task loop ' +
             '(fires=%d, expected >= %d within %d ms)',
             [GMsgWaitTimerFires, CMinExpectedFires, CDeadline_ms]));
    Assert.AreNotEqual(cardinal(MainThreadID), GMsgWaitTimerThreadID,
      'TimerProc fired on the main thread instead of the task thread');
    Assert.AreNotEqual(cardinal(0), GMsgWaitTimerThreadID,
      'TimerProc thread-id capture did not run');
  finally
    task.Terminate(CDeadline_ms);
    task := nil;
  end;
end;
{$ELSE}
begin
  Assert.Pass('Windows-only test: .MsgWait is Windows-only');
end;
{$ENDIF MSWINDOWS}

procedure TestBugfixes.TestOmniValueCreateLeakOnInvalidType;
// Regression for commit 3210d64 (OtlCommon.pas v3.01).
//
// TOmniValue.Create(array of const) constructed a TOmniValueContainer
// and walked the args; on an unrecognised VType it raised an
// exception, leaking the half-populated container. Fix: wrap the
// loop in try/except and free the container on raise.
//
// To trigger, pass a vtClass arg (TClass reference) — that VType is
// not handled by the case statement and hits the `raise` branch.
// The test relies on DUnitX's per-test leak tracking (FastMM4) to
// detect the container leak; a pre-fix build would report a leaked
// TOmniValueContainer for this fixture.
var
  raised: boolean;
begin
  raised := false;
  try
    TOmniValue.Create([42, TObject]); // TObject is TClass -> vtClass
  except
    on E: Exception do
      raised := True;
  end;
  Assert.IsTrue(raised,
    'Expected TOmniValue.Create to raise on invalid data type');
end;

procedure TestBugfixes.TestBgObserverOnTerminatedFromBgThread;
// Regression for commit 24a5162 (OtlTaskControl.pas background-observer
// sync-delivery + UAF-safe dispatcher).
//
// When a task is created from a non-main thread, OnTerminated is wired via
// the bg-observer drain path on the owner thread. Two prior bugs:
//
//   1. Drop: the Unobserved cleanup thread could free the TaskControl before
//      the owner drained the observer, so OnTerminated was never invoked.
//      Fix: fire OnTerminated synchronously from the worker thread when a
//      bg observer is active (ForwardTaskTerminated is idempotent).
//
//   2. UAF: the observer's closure held a raw `Self` reference into the
//      TaskControl; if the control was freed while the observer still sat
//      in the owner's threadvar registry, the next drain touched freed
//      memory. Fix: wrap Self in a lock-serialized TOmniTaskControlDispatcher
//      whose Clear (called from Destroy) is mutually exclusive with Dispatch.
//
// Test: a background TThread creates N Unobserved tasks with OnTerminated
// and drains its observer registry. Asserts all N callbacks fire. On
// Win32/Win64/Linux64 the DUnitX runner itself executes on the main thread,
// so this is the only non-main-thread-owner coverage; on Android the whole
// suite already runs on a worker thread and exercises the path end-to-end.
const
  CIterations = 100;
  CTimeout_ms = 30000;
var
  bgDone    : IOmniEvent;
  fireCount : integer;
  bgThread  : TThread;
begin
  bgDone := CreateOmniEvent(true, false);
  fireCount := 0;

  bgThread := TThread.CreateAnonymousThread(
    procedure
    var
      k : integer;
      sw: TStopwatch;
    begin
      try
        for k := 1 to CIterations do begin
          CreateTask(
            procedure (const task: IOmniTask)
            begin
              // exits immediately
            end, 'bg-owner Unobserved')
          .Unobserved
          .OnTerminated(
            procedure (const task: IOmniTaskControl)
            begin
              TInterlocked.Increment(fireCount);
            end)
          .Run;
        end;

        sw := TStopwatch.StartNew;
        while (fireCount < CIterations) and (sw.ElapsedMilliseconds < CTimeout_ms) do begin
          DrainBackgroundObservers;
          Sleep(10);
        end;
      finally bgDone.SetEvent; end;
    end);
  bgThread.FreeOnTerminate := false;
  bgThread.Start;
  try
    Assert.AreEqual(wrSignaled, bgDone.WaitFor(CTimeout_ms + 5000),
      'Background owner thread did not finish in time');
  finally
    bgThread.WaitFor;
    bgThread.Free;
  end;

  Assert.AreEqual(CIterations, fireCount,
    'OnTerminated fire count mismatch — bg-observer drop regression');
end;

{$IFDEF MSWINDOWS}
function TestBugfixes.AllocatedBytes: NativeUInt;
// Currently-allocated (in-use) heap bytes per the RTL's FastMM-derived
// manager. Counts only live blocks, so memory the manager keeps pooled after
// a Free is NOT counted — exactly what we want to isolate a true leak from
// allocator churn (e.g. transient thread allocations that are freed again).
var
  st: TMemoryManagerState;
  i : integer;
begin
  GetMemoryManagerState(st);
  Result := st.TotalAllocatedMediumBlockSize + st.TotalAllocatedLargeBlockSize;
  for i := Low(st.SmallBlockTypeStates) to High(st.SmallBlockTypeStates) do
    Result := Result +
      st.SmallBlockTypeStates[i].UseableBlockSize *
      st.SmallBlockTypeStates[i].AllocatedBlockCount;
end;

procedure TestBugfixes.RunBgObserverDeadTargetScenario(payloadSize: integer);
// One leak-scenario iteration. A worker parks in a NON-alertable wait
// (TEvent.WaitFor -> WaitForSingleObject) so a QueueUserAPC succeeds but can
// never be delivered; the worker then exits without ever going alertable,
// orphaning the queued APC. The observer's OnNotify closure captures a
// heap payload so a leaked TAPCState pins a measurable amount of memory.
var
  observer: IOmniContainerBackgroundObserver;
  worker  : TThread;
  started : TEvent;
  mayExit : TEvent;
  tid     : TThreadID;
  payload : TBytes;
begin
  SetLength(payload, payloadSize);
  started := TEvent.Create(nil, true, false, '');
  mayExit := TEvent.Create(nil, true, false, '');
  try
    tid := 0;
    worker := TThread.CreateAnonymousThread(
      procedure
      begin
        tid := TThread.Current.ThreadID;
        started.SetEvent;
        mayExit.WaitFor(INFINITE);
      end);
    worker.FreeOnTerminate := false;
    worker.Start;
    try
      started.WaitFor(5000);
      observer := CreateContainerBackgroundObserver(tid,
        procedure begin if Length(payload) < 0 then Abort; end); // capture payload
      // QueueUserAPC succeeds (worker alive, parked): RefCount -> 2.
      observer.Notify;
      // Worker leaves its non-alertable wait and exits without going
      // alertable, so the queued APC is never delivered.
      mayExit.SetEvent;
      worker.WaitFor;
    finally worker.Free; end;
    // Destroy on the main thread: pre-fix leaves TAPCState (and the captured
    // payload) allocated; the fixed code reclaims the orphaned APC ref.
    observer := nil;
  finally
    mayExit.Free;
    started.Free;
  end;
end;
{$ENDIF MSWINDOWS}

procedure TestBugfixes.TestBgObserverApcRefLeakOnDeadTarget;
// Regression for OtlBackgroundObserver.pas v1.04 — the OTL-NG analog of
// GpEventBus r41604/r41702 (orphaned APC-ref leak on a dead target thread).
//
// TOmniContainerAPCObserverImpl.Notify increments TAPCState.RefCount and
// QueueUserAPCs APCCallback to the target thread; APCCallback decrements that
// ref when it runs. If the target thread terminates without ever entering an
// alertable wait, the queued APC is never delivered, so the ref is never
// balanced. Destroy then drops only the observer's own ref (RefCount 2 -> 1)
// and leaves the TAPCState block (plus everything its OnNotify closure
// captures) allocated forever.
//
// This runner does not install FastMM4 as the memory manager, so DUnitX's
// per-test leak counter never sees these AllocMem blocks. Instead we measure
// live-heap growth directly across many iterations: a real leak grows the
// in-use byte count by ~iterations*payload; allocator churn from the transient
// worker threads is freed and therefore not counted.
{$IFDEF MSWINDOWS}
const
  CIterations  = 400;
  CPayload     = 16384;        // 16 KiB pinned per leaked TAPCState
  CMaxGrowth   = CIterations * CPayload div 4; // generous slack for noise
var
  i      : integer;
  before : NativeUInt;
  after  : NativeUInt;
  growth : int64;
begin
  // Warm up one iteration so first-touch lazy allocations don't count.
  RunBgObserverDeadTargetScenario(CPayload);

  before := AllocatedBytes;
  for i := 1 to CIterations do
    RunBgObserverDeadTargetScenario(CPayload);
  after := AllocatedBytes;

  growth := int64(after) - int64(before);
  Assert.IsTrue(growth < CMaxGrowth,
    Format('orphaned-APC-ref leak: live heap grew %d bytes over %d iterations ' +
           '(%.0f bytes/iter, payload=%d) — TAPCState is not reclaimed when the ' +
           'target thread dies with a pending APC',
           [growth, CIterations, growth / CIterations, CPayload]));
end;
{$ELSE}
begin
  Assert.Pass('Windows-only test: QueueUserAPC orphaned-ref leak is Windows-only');
end;
{$ENDIF MSWINDOWS}

procedure TestBugfixes.TestTerminatedEventSurvivesControllerDestroy;
// Regression guard for OTL issue #216 (data race on the task's TerminatedEvent handle),
// ensuring OTL-NG never reintroduces the raw-handle ownership that made classic OTL
// vulnerable.
//
// Classic OTL stored TerminatedEvent as a bare THandle. TOmniTask.InternalExecute
// captured the handle, released MonitorLock, then SetEvent'd it - but for a pooled task
// TOmniTaskControl.Destroy (running on another thread) closed that handle with
// CloseHandle in the window before the SetEvent, so the worker signalled a closed,
// possibly OS-recycled handle and corrupted unrelated state.
//
// OTL-NG is immune by construction: TerminatedEvent is a refcounted IOmniEvent, and
// Destroy disposes it by releasing its reference (`TerminatedEvent := nil`), never by
// closing a handle. Anyone holding a captured reference - including the worker's own
// IOmniEvent local in InternalExecute - keeps the underlying event (and its OS handle)
// alive; the handle is closed only by TOmniEvent's destructor at refcount zero. There is
// therefore no destructive teardown step for a second thread to race against.
//
// Because that immunity is a type/ownership property rather than a timing one, this test
// locks it in directly instead of trying to race a (non-existent) handle close:
//   * Compile-time: capturing TerminatedEvent into an IOmniEvent only compiles while it
//     stays a refcounted event - a revert to a bare THandle breaks this test's build.
//   * Runtime: after releasing the caller's task-control reference, the captured event
//     must still own a live, operable handle (Reset/SetEvent cycle, and on Windows a
//     still-valid OS handle). This proves the terminated event's lifetime is governed by
//     the IOmniEvent refcount, not by the task control - the property that removes the
//     race entirely.
//
// (The full teardown cannot be driven on demand - a running task control keeps
// additional internal references, so releasing the caller's reference does not by itself
// run Destroy; and mutating the shared info from the test thread would race the worker's
// own in-flight SetEvent. Hence this asserts the ownership invariant rather than trying
// to reproduce the classic timing window, which cannot exist in NG.)
const
  CTimeout_ms = 10000;
var
  evt    : IOmniEvent;
  taskCtl: IOmniTaskControl;
  {$IFDEF MSWINDOWS}
  flags  : DWORD;
  handle : THandle;
  {$ENDIF}
begin
  taskCtl := CreateTask(
    procedure (const task: IOmniTask)
    begin
      // exits immediately
    end, 'issue216-terminated-event')
    .Run;

  // Our own reference to the terminated event, captured while the task runs. This line
  // only compiles while TerminatedEvent is an IOmniEvent (not a raw THandle).
  evt := (taskCtl as IOmniTaskControlInternals).TerminatedEvent;
  Assert.IsNotNull(evt, 'TerminatedEvent should be assigned');
  {$IFDEF MSWINDOWS}
  handle := (evt as IOmniSynchro).Handle;
  {$ENDIF}

  // Wait for the task to finish; TerminatedEvent becomes signalled.
  Assert.IsTrue(taskCtl.WaitFor(CTimeout_ms), 'Task did not terminate in time');

  // Release the caller's reference to the task control. With the refcounted IOmniEvent
  // design the terminated event's lifetime is independent of the control: `evt` keeps it
  // (and its OS handle) alive. With classic OTL's raw handle it was owned by the control
  // and closed during teardown, so a captured value could go stale.
  taskCtl := nil;

  {$IFDEF MSWINDOWS}
  // The underlying OS handle must still be valid - it is owned by the IOmniEvent we hold,
  // not by the (now-released) task control.
  Assert.IsTrue(GetHandleInformation(handle, flags),
    Format('TerminatedEvent OS handle is no longer valid after releasing the task ' +
           'control (GetLastError=%d) - issue #216 raw-handle regression', [GetLastError]));
  {$ENDIF}

  // The captured event must still be signalled and fully operable.
  Assert.AreEqual(wrSignaled, evt.WaitFor(0),
    'Captured TerminatedEvent lost its signalled state after releasing the task control');
  evt.Reset;
  Assert.AreEqual(wrTimeout, evt.WaitFor(0),
    'Captured TerminatedEvent could not be reset');
  evt.SetEvent;
  Assert.AreEqual(wrSignaled, evt.WaitFor(0),
    'Captured TerminatedEvent could not be signalled - the captured reference did not ' +
    'keep the event alive (issue #216 invariant broken)');
end;

end.
