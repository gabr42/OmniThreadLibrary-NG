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
  end;

implementation

uses
  System.Classes, System.SysUtils, System.SyncObjs,
  System.Generics.Collections,
  OtlCommon, OtlSync, OtlParallel, OtlCollections;

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

end.
