unit TestPlatform;

interface

uses
  DUnitX.TestFramework;

type
  // Tests for the OtlPlatform unit and other platform-dependant stuff
  [TestFixture]
  TPlatformTest = class
  public
    [Test]
    procedure TestTimestamp;
    [Test]
    procedure TestEventWaitFor;
    [Test]
    procedure TestThreadID;
    {$IFDEF MSWINDOWS}
    [Test]
    procedure TestAffinityMaskRoundTrip;
    [Test]
    procedure TestThreadAffinity;
    {$ENDIF}
  end;

implementation

{$I OtlOptions.inc}

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
  Assert.IsTrue((time_ms >= 990) and (time_ms <= 1050) {allowed measurement error},
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
end;

procedure TPlatformTest.TestThreadAffinity;
begin
  var affinity := TPlatform.ThreadAffinity;
  Assert.IsFalse(affinity.IsEmpty, 'Thread affinity should not be empty');
end;
{$ENDIF}

end.
