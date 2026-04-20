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
  end;

implementation

uses
  System.Classes, System.SysUtils, System.SyncObjs,
  System.Generics.Collections,
  OtlCommon, OtlSync;

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

end.
