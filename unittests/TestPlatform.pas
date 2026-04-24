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
    [Test]
    procedure TestAffinityMaskRoundTrip;
    {$IF Defined(LINUX) or Defined(ANDROID)}
    [Test]
    procedure TestPosixSetThreadAffinityRestrictsAndRestores;
    {$IFEND}
    {$IF Defined(MACOS) and not Defined(LINUX) and not Defined(ANDROID)}
    [Test]
    procedure TestMacOSThreadAffinityIsNoOp;
    {$IFEND}
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

{$IF Defined(LINUX) or Defined(ANDROID)}
procedure TPlatformTest.TestPosixSetThreadAffinityRestrictsAndRestores;
begin
  // Linux/Android now wire TPlatform.ThreadAffinity to pthread_getaffinity_np /
  // pthread_setaffinity_np. The behaviour should mirror Windows: setting a
  // narrower mask restricts the thread; reading back returns the current
  // (restricted) mask. Restore the original mask at the end so the test does
  // not leave the runner thread pinned for later tests.
  var before := TPlatform.ThreadAffinity;
  Assert.IsFalse(before.IsEmpty, 'baseline affinity should not be empty');

  // Skip the restrict-test on a 1-CPU runner — pinning to CPU 0 is a no-op
  // there and the assertion below would fire spuriously.
  if Length(before) < 2 then
    Exit;

  try
    TPlatform.ThreadAffinity := '0'; // restrict to CPU 0
    var restricted := TPlatform.ThreadAffinity;
    Assert.AreEqual('0', restricted,
      Format('SetThreadAffinity(''0'') should leave only CPU 0 active, got "%s"',
        [restricted]));
  finally
    // Best-effort restore; if pthread_setaffinity_np still rejects the
    // original mask (cgroup changes mid-test etc.) we let the exception
    // propagate so the failure is loud, not silent.
    TPlatform.ThreadAffinity := before;
  end;

  var after := TPlatform.ThreadAffinity;
  Assert.AreEqual(before, after,
    Format('Affinity was not restored (before="%s", after="%s")', [before, after]));
end;
{$IFEND}

{$IF Defined(MACOS) and not Defined(LINUX) and not Defined(ANDROID)}
procedure TPlatformTest.TestMacOSThreadAffinityIsNoOp;
begin
  // macOS has no pthread_setaffinity_np; OtlPlatform documents this branch
  // as a no-op. GetThreadAffinity returns a ProcessorCount-length prefix of
  // CCPUIDs; SetThreadAffinity does nothing and must not raise.
  var before := TPlatform.ThreadAffinity;
  TPlatform.ThreadAffinity := '0';
  Assert.AreEqual(before, TPlatform.ThreadAffinity,
    'macOS SetThreadAffinity must be a no-op');
end;
{$IFEND}

end.
