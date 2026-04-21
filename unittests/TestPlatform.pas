unit TestPlatform;

interface

uses
  DUnitX.TestFramework,
  TestOtlBase;

type
  // Tests for the OtlPlatform unit and other platform-dependant stuff
  [TestFixture]
  TPlatformTest = class(TOtlTestBase)
  public
    [Test]
    procedure TestTimestamp;
    [Test]
    procedure TestTimestampIsMonotonic;
    [Test]
    procedure TestTimeReturnsGlobalInstance;
    [Test]
    procedure TestEventWaitFor;
    [Test]
    procedure TestThreadID;
    [Test]
    procedure TestThreadAffinityNotEmpty;
    {$IFDEF MSWINDOWS}
    [Test]
    procedure TestAffinityMaskRoundTrip;
    {$ELSE}
    [Test]
    procedure TestPosixThreadAffinityMatchesProcessorCount;
    [Test]
    procedure TestPosixSetThreadAffinityIsNoOp;
    {$ENDIF}
  end;

implementation


uses
  System.SysUtils,
  System.Classes,
  System.Diagnostics,
  OtlPlatform,
  OtlSync;

{ TPlatformTest }

procedure TPlatformTest.TestEventWaitFor;
var
  event  : IOmniEvent;
  time_ms: int64;
begin
  event := CreateOmniEvent(false, false);
  event.SetEvent;
  time_ms := Time.Timestamp_ms;
  event.WaitFor(1000);
  time_ms := Time.Elapsed_ms(time_ms);
  Assert.IsTrue(time_ms < 500 {allowed measurement error}, 'WaitFor(1000) took too long');

  event.Reset;
  time_ms := Time.Timestamp_ms;
  event.WaitFor(1000);
  time_ms := Time.Elapsed_ms(time_ms);
  // Upper bound is generous: under CPU-loaded CI runs (e.g. parallel
  // suites) OS wakeup latency on a reset auto-reset event can slip well
  // past 50 ms of jitter. We only want to verify that WaitFor blocks for
  // roughly the requested duration, not to measure scheduler fidelity.
  Assert.IsTrue((time_ms >= 990) and (time_ms <= 1500) {allowed measurement error},
    Format('WaitFor(1000) did not last around 1 s (actual: %d ms)', [time_ms]));
end;

procedure TPlatformTest.TestTimestamp;
var
  time_ms : int64;
  timeD_ms: int64;
  time1_ms: int64;
  time2_ms: int64;
begin
  time_ms := Time.Timestamp_ms;
  Sleep(1000);
  time1_ms := Time.Elapsed_ms(time_ms);
  timeD_ms := Time.Timestamp_ms - time_ms;
  time2_ms := Time.Elapsed_ms(time_ms);
  Assert.IsTrue(timeD_ms >= 1000, Format('Time too small: %d', [timeD_ms]));
  Assert.IsTrue(timeD_ms <= 1100, Format('Time too large: %d', [timeD_ms]));
  Assert.IsTrue((time1_ms = timeD_ms) or (time2_ms = timeD_ms),
    Format('Elapsed time invalid: %d, %d', [time1_ms, time2_ms]));

  Assert.IsTrue(Time.HasElapsed(time_ms, 100), 'Should have elapsed: 100');
  Assert.IsTrue(Time.HasElapsed(time_ms, 1000), 'Should have elapsed: 1000');
  Assert.IsFalse(Time.HasElapsed(time_ms, 2000), 'Should not have elapsed: 2000');
  Assert.IsTrue(Time.HasElapsed(time_ms + 1000, 0), 'Should have elapsed: 0');
  Assert.IsFalse(Time.HasElapsed(0, INFINITE), 'Should not have elapsed: INFINITE');
end;

procedure TPlatformTest.TestThreadID;
begin
  var id := TPlatform.ThreadID;
  Assert.AreEqual<TThreadID>(TThread.Current.ThreadID, id);
end;

procedure TPlatformTest.TestTimestampIsMonotonic;
var
  i      : integer;
  prev_ms: int64;
  cur_ms : int64;
begin
  prev_ms := Time.Timestamp_ms;
  for i := 1 to 10000 do begin
    cur_ms := Time.Timestamp_ms;
    Assert.IsTrue(cur_ms >= prev_ms,
      Format('Timestamp_ms went backwards at iteration %d: prev=%d cur=%d',
        [i, prev_ms, cur_ms]));
    prev_ms := cur_ms;
  end;
end;

procedure TPlatformTest.TestTimeReturnsGlobalInstance;
begin
  // Time() returns a pointer to the module-level GTimeSource and must be
  // stable across calls — OtlPlatform inlines .Timestamp_ms via this
  // pointer, so any change to the pointer identity would silently break
  // every inline caller.
  var firstPtr  := Time;
  var secondPtr := Time;
  Assert.IsTrue(firstPtr = secondPtr,
    Format('Time() returned different pointers: %p vs %p',
      [pointer(firstPtr), pointer(secondPtr)]));
  Assert.IsTrue(firstPtr <> nil, 'Time() returned nil');
end;

procedure TPlatformTest.TestThreadAffinityNotEmpty;
begin
  // On Windows the value reflects the actual process/thread affinity mask;
  // on POSIX it is a deterministic "all processors" fallback. Either way
  // the string must be non-empty.
  var affinity := TPlatform.ThreadAffinity;
  Assert.IsFalse(affinity.IsEmpty, 'Thread affinity should not be empty');
end;

{$IFDEF MSWINDOWS}
procedure TPlatformTest.TestAffinityMaskRoundTrip;
begin
  // Test single CPU
  var mask: NativeUInt := 1;
  var s := AffinityMaskToString(mask);
  Assert.AreEqual<NativeUInt>(mask, StringToAffinityMask(s));

  // Test multiple CPUs
  mask := 5; // CPUs 0 and 2
  s := AffinityMaskToString(mask);
  Assert.AreEqual<NativeUInt>(mask, StringToAffinityMask(s));

  // Empty mask round-trips through empty string.
  Assert.AreEqual('', AffinityMaskToString(0));
  Assert.AreEqual<NativeUInt>(0, StringToAffinityMask(''));

  // High bit (CPU 63) — exercises the full 64-char CCPUIDs alphabet.
  mask := NativeUInt(1) shl 63;
  s := AffinityMaskToString(mask);
  Assert.AreEqual(1, Length(s), Format('bit-63 mask should map to 1 char, got "%s"', [s]));
  Assert.AreEqual<NativeUInt>(mask, StringToAffinityMask(s));
end;
{$ELSE}
procedure TPlatformTest.TestPosixThreadAffinityMatchesProcessorCount;
begin
  // Documented POSIX fallback: GetThreadAffinity returns a prefix of the
  // CCPUIDs alphabet of exactly ProcessorCount characters (pthread_getaffinity_np
  // is not yet wired up). If the POSIX branch ever grows real affinity
  // support this test must be revisited.
  var affinity := TPlatform.ThreadAffinity;
  Assert.AreEqual(TThread.ProcessorCount, Length(affinity),
    Format('POSIX ThreadAffinity length (%d) must match ProcessorCount (%d); got "%s"',
      [Length(affinity), TThread.ProcessorCount, affinity]));
end;

procedure TPlatformTest.TestPosixSetThreadAffinityIsNoOp;
begin
  // pthread_setaffinity_np is not wired up yet, so SetThreadAffinity is a
  // documented no-op on POSIX. Writing an arbitrary (even nonsense) value
  // must not change what GetThreadAffinity later returns.
  var before := TPlatform.ThreadAffinity;
  TPlatform.ThreadAffinity := '0';               // request: CPU 0 only
  var after1 := TPlatform.ThreadAffinity;
  TPlatform.ThreadAffinity := 'not-a-real-mask'; // request: garbage
  var after2 := TPlatform.ThreadAffinity;
  Assert.AreEqual(before, after1,
    'SetThreadAffinity(''0'') must be a no-op on POSIX');
  Assert.AreEqual(before, after2,
    'SetThreadAffinity(garbage) must be a no-op on POSIX');
end;
{$ENDIF}

end.
