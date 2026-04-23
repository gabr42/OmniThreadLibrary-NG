unit TestRegressions;

interface

uses
  DUnitX.TestFramework,
  TestOtlBase;

type
  [TestFixture]
  TestBugfixes = class(TOtlTestBase)
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
    procedure TestOmniValueCreateLeakOnInvalidType;
    [Test]
    procedure TestBgObserverOnTerminatedFromBgThread;
  end;

implementation

uses
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

end.
