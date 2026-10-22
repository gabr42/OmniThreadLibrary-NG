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
    {$IFDEF MSWINDOWS}
    [Test] procedure TestPendingAPCReleasedWhenOwnerThreadExits;
    {$ENDIF}
  end;

implementation

uses
  System.SysUtils,
  System.SyncObjs,
  System.Classes,
  OtlSync,
  OtlTask,
  OtlTaskControl,
  OtlBackgroundObserver;

{$IFDEF MSWINDOWS}
type
  TLeakSentinel = class(TInterfacedObject)
  strict private
    FCount: PInteger;
  public
    constructor Create(count: PInteger);
    destructor  Destroy; override;
  end;

constructor TLeakSentinel.Create(count: PInteger);
begin
  inherited Create;
  FCount := count;
  TInterlocked.Increment(FCount^);
end;

destructor TLeakSentinel.Destroy;
begin
  TInterlocked.Decrement(FCount^);
  inherited;
end;

// The sentinel is held only by the observer's OnNotify closure.
function CreateSentinelObserver(count: PInteger): IOmniContainerBackgroundObserver;
begin
  var sentinel: IInterface := TLeakSentinel.Create(count);
  Result := CreateContainerBackgroundObserver(TThread.Current.ThreadID,
    procedure
    begin
      if sentinel = nil then
        raise Exception.Create('unreachable');
    end);
end;
{$ENDIF MSWINDOWS}

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
    {$IFNDEF MSWINDOWS}
    RegisterBackgroundObserver(observer);
    try
    {$ENDIF}
      observer.Notify;
      DrainBackgroundObservers;
      Assert.AreEqual<integer>(1, callbackFired, 'Callback should have fired once');
    {$IFNDEF MSWINDOWS}
    finally UnregisterBackgroundObserver(observer); end;
    {$ENDIF}
  finally observer := nil; end;
end;

{$IFDEF MSWINDOWS}
// Regression: an APC queued to an OTL thread that never enters an alertable
// wait again, with the observer destroyed while that thread is still alive,
// leaked TAPCState and everything OnNotify captured (found in SttwinService).
procedure TestBackgroundObserver.TestPendingAPCReleasedWhenOwnerThreadExits;
var
  created : TEvent;
  held    : IOmniContainerBackgroundObserver;
  leaked  : integer;
  released: TEvent;
begin
  leaked := 0;
  created := TEvent.Create;
  released := TEvent.Create;
  try
    var task := CreateTask(
      procedure (const task: IOmniTask)
      begin
        held := CreateSentinelObserver(@leaked);
        created.SetEvent;
        // plain (non-alertable) wait: the APC stays queued
        released.WaitFor(10000);
      end,
      'APCOwner').Run;
    Assert.IsTrue(created.WaitFor(10000) = wrSignaled, 'Owner did not start');
    held.Notify;   // queues an APC the owner will not run while waiting
    held := nil;   // destroy observer while the owner is alive
    released.SetEvent;
    Assert.IsTrue(task.WaitFor(10000), 'Owner did not terminate');
    task := nil;
  finally
    FreeAndNil(created);
    FreeAndNil(released);
  end;
  Assert.AreEqual<integer>(0, leaked, 'OnNotify closure leaked');
end;
{$ENDIF MSWINDOWS}

end.
