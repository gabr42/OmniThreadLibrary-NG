unit TestBackgroundObserver1;

interface

uses
  DUnitX.TestFramework,
  TestOtlBase;

type
  [TestFixture]
  TestBackgroundObserver = class(TOtlTestBase)
  public
    [Test] procedure TestCreateAndFree;
    [Test] procedure TestGetNotifyEvent;
    [Test] procedure TestNotifySignalsEvent;
    [Test] procedure TestNotifyCoalescing;
    [Test] procedure TestNotifyCallbackDelivery;
  end;

implementation

uses
  System.SysUtils,
  System.SyncObjs,
  System.Classes,
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  OtlSync,
  OtlBackgroundObserver;

{ TestBackgroundObserver }

procedure TestBackgroundObserver.TestCreateAndFree;
begin
  var observer := CreateContainerBackgroundObserver(
    TThread.Current.ThreadID,
    procedure begin end);
  Assert.IsNotNull(observer);
  observer := nil;
end;

procedure TestBackgroundObserver.TestGetNotifyEvent;
begin
  var observer := CreateContainerBackgroundObserver(
    TThread.Current.ThreadID,
    procedure begin end);
  try
    var evt := observer.GetNotifyEvent;
    Assert.IsNotNull(evt);
  finally observer := nil; end;
end;

procedure TestBackgroundObserver.TestNotifySignalsEvent;
begin
  var observer := CreateContainerBackgroundObserver(
    TThread.Current.ThreadID,
    procedure begin end);
  try
    var evt := observer.GetNotifyEvent;
    // Event should not be signaled initially
    Assert.IsFalse(evt.WaitFor(0) = wrSignaled, 'Initially not signaled');

    observer.Notify;
    // Event should be signaled after Notify
    Assert.IsTrue(evt.WaitFor(0) = wrSignaled, 'Signaled after Notify');
  finally observer := nil; end;
end;

procedure TestBackgroundObserver.TestNotifyCoalescing;
begin
  var observer := CreateContainerBackgroundObserver(
    TThread.Current.ThreadID,
    procedure begin end);
  try
    var evt := observer.GetNotifyEvent;

    // Multiple Notify calls before consuming
    observer.Notify;
    observer.Notify;
    observer.Notify;

    // Event is auto-reset, single WaitFor consumes it
    Assert.IsTrue(evt.WaitFor(0) = wrSignaled, 'First WaitFor');
    // After consuming, event should not be signaled
    Assert.IsFalse(evt.WaitFor(0) = wrSignaled, 'Second WaitFor');
  finally observer := nil; end;
end;

procedure TestBackgroundObserver.TestNotifyCallbackDelivery;
var
  callbackFired: integer;
begin
  callbackFired := 0;
  var observer := CreateContainerBackgroundObserver(
    TThread.Current.ThreadID,
    procedure begin TInterlocked.Increment(callbackFired); end);
  try
    observer.Notify;

    // On Windows, drain via SleepEx (alertable wait) to process queued APC
    {$IFDEF MSWINDOWS}
    SleepEx(0, True);
    {$ENDIF}

    Assert.AreEqual<integer>(1, callbackFired, 'Callback should have fired once');
  finally observer := nil; end;
end;

end.
