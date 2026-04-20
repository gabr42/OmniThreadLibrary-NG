unit TestContainerObserver1;

interface

uses
  DUnitX.TestFramework,
  OtlContainerObserver, OtlSync, OtlCommon,
  TestOtlBase;

type
  [TestFixture]
  TestContainerSubject = class(TOtlTestBase)
  public
    [Test] procedure TestAttachAndNotify;
    [Test] procedure TestDetachStopsNotification;
    [Test] procedure TestNotifyOnceFiresOnce;
    [Test] procedure TestRearmAfterNotifyOnce;
    [Test] procedure TestNotifyAllowsDetachFromCallback;
    [Test] procedure TestNotifyAllowsAttachFromCallback;
    [Test] procedure TestSnapshotKeepsObserverAliveDuringDispatch;
  end;

  [TestFixture]
  TestContainerEventObserver = class(TOtlTestBase)
  public
    [Test] procedure TestCreateAndGetEvent;
    [Test] procedure TestNotifySignalsEvent;
    [Test] procedure TestDeactivatePreventsNotify;
  end;

  [TestFixture]
  TestObserverInterests = class(TOtlTestBase)
  public
    [Test] procedure TestInsertVsRemoveInterest;
  end;

implementation

uses
  System.SysUtils, System.SyncObjs;

type
  // Minimal observer for reentrancy / snapshot-lifetime tests. Each Notify
  // call increments the counter and optionally invokes a user callback, so
  // tests can assert fire-count and reentrant Attach/Detach behaviour from
  // within the dispatch.
  TCallbackObserver = class(TOmniContainerObserver)
  strict private
    FCallback   : TProc;
    FNotifyCount: integer;
  public
    constructor Create(const callback: TProc);
    procedure Notify; override;
    property NotifyCount: integer read FNotifyCount;
  end;

constructor TCallbackObserver.Create(const callback: TProc);
begin
  inherited Create;
  FCallback := callback;
end;

procedure TCallbackObserver.Notify;
begin
  TInterlocked.Increment(FNotifyCount);
  if assigned(FCallback) then
    FCallback();
end;

{ TestContainerSubject }

procedure TestContainerSubject.TestAttachAndNotify;
begin
  var subject := TOmniContainerSubject.Create;
  try
    var observer := CreateContainerEventObserver;
    try
      subject.Attach(observer, coiNotifyOnAllInserts);
      subject.Notify(coiNotifyOnAllInserts);
      // Observer's event should be signaled
      Assert.IsTrue(observer.GetEvent.WaitFor(0) = wrSignaled);
    finally observer := nil; end;
  finally subject.Free; end;
end;

procedure TestContainerSubject.TestDetachStopsNotification;
begin
  var subject := TOmniContainerSubject.Create;
  try
    var observer := CreateContainerEventObserver;
    try
      subject.Attach(observer, coiNotifyOnAllInserts);
      subject.Detach(observer, coiNotifyOnAllInserts);
      subject.Notify(coiNotifyOnAllInserts);
      // Observer's event should NOT be signaled after detach
      Assert.IsFalse(observer.GetEvent.WaitFor(0) = wrSignaled);
    finally observer := nil; end;
  finally subject.Free; end;
end;

procedure TestContainerSubject.TestNotifyOnceFiresOnce;
begin
  var subject := TOmniContainerSubject.Create;
  try
    var observer := CreateContainerEventObserver;
    try
      subject.Attach(observer, coiNotifyOnPartlyEmpty);

      // First NotifyOnce should fire (observer starts active) then deactivate it
      subject.NotifyOnce(coiNotifyOnPartlyEmpty);
      Assert.IsTrue(observer.GetEvent.WaitFor(0) = wrSignaled);

      // Second NotifyOnce should NOT fire (observer was deactivated by NotifyOnce)
      subject.NotifyOnce(coiNotifyOnPartlyEmpty);
      // Event is auto-reset, so WaitFor should timeout
      Assert.IsFalse(observer.GetEvent.WaitFor(0) = wrSignaled);
    finally observer := nil; end;
  finally subject.Free; end;
end;

procedure TestContainerSubject.TestRearmAfterNotifyOnce;
begin
  var subject := TOmniContainerSubject.Create;
  try
    var observer := CreateContainerEventObserver;
    try
      subject.Attach(observer, coiNotifyOnPartlyEmpty);

      // Fire once — observer gets deactivated by NotifyOnce
      subject.NotifyOnce(coiNotifyOnPartlyEmpty);
      // Consume the auto-reset event
      observer.GetEvent.WaitFor(0);

      // Rearm re-activates observers for this interest
      subject.Rearm(coiNotifyOnPartlyEmpty);

      // Now NotifyOnce should fire again
      subject.NotifyOnce(coiNotifyOnPartlyEmpty);
      Assert.IsTrue(observer.GetEvent.WaitFor(0) = wrSignaled);
    finally observer := nil; end;
  finally subject.Free; end;
end;

procedure TestContainerSubject.TestNotifyAllowsDetachFromCallback;
// 2.05 fix: Notify snapshots the observer list under a read lock and then
// dispatches with the lock released, so a callback that calls Detach (which
// needs a write lock) must not deadlock.
begin
  var subject := TOmniContainerSubject.Create;
  try
    var callback: TCallbackObserver := nil;
    var observerRef: IOmniContainerObserver := nil;
    callback := TCallbackObserver.Create(
      procedure
      begin
        subject.Detach(observerRef, coiNotifyOnAllInserts);
      end);
    observerRef := callback;
    try
      subject.Attach(observerRef, coiNotifyOnAllInserts);
      // First Notify fires callback which self-detaches.
      subject.Notify(coiNotifyOnAllInserts);
      Assert.AreEqual<integer>(1, callback.NotifyCount,
        'Observer should have fired exactly once on the first Notify');
      // Second Notify must find no observers.
      subject.Notify(coiNotifyOnAllInserts);
      Assert.AreEqual<integer>(1, callback.NotifyCount,
        'Observer was detached from callback; second Notify must not fire it');
    finally observerRef := nil; end;
  finally subject.Free; end;
end;

procedure TestContainerSubject.TestNotifyAllowsAttachFromCallback;
// Companion to the detach test: a callback that attaches another observer
// must also not deadlock on the write lock, because dispatch happens outside
// the read lock. The newly-attached observer does not fire on this Notify
// (the snapshot was taken before the attach) but must fire on the next one.
begin
  var subject := TOmniContainerSubject.Create;
  try
    var late := TCallbackObserver.Create(nil);
    var lateRef: IOmniContainerObserver := late;
    var first: TCallbackObserver := nil;
    var firstRef: IOmniContainerObserver := nil;
    first := TCallbackObserver.Create(
      procedure
      begin
        subject.Attach(lateRef, coiNotifyOnAllInserts);
      end);
    firstRef := first;
    try
      subject.Attach(firstRef, coiNotifyOnAllInserts);
      subject.Notify(coiNotifyOnAllInserts);
      Assert.AreEqual<integer>(1, first.NotifyCount,
        'First Notify must fire the originally-attached observer');
      Assert.AreEqual<integer>(0, late.NotifyCount,
        'Late-attached observer must not be in the first snapshot');

      subject.Notify(coiNotifyOnAllInserts);
      Assert.AreEqual<integer>(2, first.NotifyCount,
        'Second Notify must fire the originally-attached observer again');
      Assert.AreEqual<integer>(1, late.NotifyCount,
        'Late-attached observer must be in the second snapshot');
    finally
      firstRef := nil;
      lateRef  := nil;
    end;
  finally subject.Free; end;
end;

procedure TestContainerSubject.TestSnapshotKeepsObserverAliveDuringDispatch;
// 2.06 fix: the Notify snapshot is TArray<IOmniContainerObserver> which
// holds interface references, so an observer released by another thread
// during dispatch must remain alive until Notify returns. Simulated here
// single-threaded: the callback drops the only external ref to the
// *second* observer; without the snapshot's interface hold that would free
// the object before its Notify runs and blow up.
var
  second     : TCallbackObserver;
  secondRef  : IOmniContainerObserver;
  first      : TCallbackObserver;
  firstRef   : IOmniContainerObserver;
  secondFired: boolean;
begin
  secondFired := false;
  second := TCallbackObserver.Create(
    procedure
    begin
      secondFired := true;
    end);
  secondRef := second;

  var subject := TOmniContainerSubject.Create;
  try
    first := TCallbackObserver.Create(
      procedure
      begin
        // Drop the external reference. Only the snapshot ref is left.
        // If the snapshot held a raw pointer (pre-2.06) the later dispatch
        // call would crash / leak / read freed memory.
        subject.Detach(secondRef, coiNotifyOnAllInserts);
        secondRef := nil;
      end);
    firstRef := first;
    try
      subject.Attach(firstRef,  coiNotifyOnAllInserts);
      subject.Attach(secondRef, coiNotifyOnAllInserts);
      subject.Notify(coiNotifyOnAllInserts);
      Assert.IsTrue(secondFired,
        'Second observer must fire even after its external ref was dropped mid-dispatch');
    finally
      firstRef  := nil;
      secondRef := nil;
    end;
  finally subject.Free; end;
end;

{ TestContainerEventObserver }

procedure TestContainerEventObserver.TestCreateAndGetEvent;
begin
  var observer := CreateContainerEventObserver;
  try
    Assert.IsNotNull(observer);
    var evt := observer.GetEvent;
    Assert.IsNotNull(evt);
  finally observer := nil; end;
end;

procedure TestContainerEventObserver.TestNotifySignalsEvent;
begin
  var observer := CreateContainerEventObserver;
  try
    // Event should not be signaled initially
    Assert.IsFalse(observer.GetEvent.WaitFor(0) = wrSignaled);

    observer.Notify;
    Assert.IsTrue(observer.GetEvent.WaitFor(0) = wrSignaled);
  finally observer := nil; end;
end;

procedure TestContainerEventObserver.TestDeactivatePreventsNotify;
begin
  // Deactivate prevents NotifyOnce from firing (not direct Notify)
  var subject := TOmniContainerSubject.Create;
  try
    var observer := CreateContainerEventObserver;
    try
      subject.Attach(observer, coiNotifyOnPartlyEmpty);
      // Explicitly deactivate — observer starts active from Create
      observer.Deactivate;
      subject.NotifyOnce(coiNotifyOnPartlyEmpty);
      Assert.IsFalse(observer.GetEvent.WaitFor(0) = wrSignaled);
    finally observer := nil; end;
  finally subject.Free; end;
end;

{ TestObserverInterests }

procedure TestObserverInterests.TestInsertVsRemoveInterest;
begin
  var subject := TOmniContainerSubject.Create;
  try
    var insertObserver := CreateContainerEventObserver;
    try
      var removeObserver := CreateContainerEventObserver;
      try
        subject.Attach(insertObserver, coiNotifyOnAllInserts);
        subject.Attach(removeObserver, coiNotifyOnAllRemoves);

        // Notify inserts only
        subject.Notify(coiNotifyOnAllInserts);
        Assert.IsTrue(insertObserver.GetEvent.WaitFor(0) = wrSignaled);
        Assert.IsFalse(removeObserver.GetEvent.WaitFor(0) = wrSignaled);

        insertObserver.GetEvent.Reset;

        // Notify removes only
        subject.Notify(coiNotifyOnAllRemoves);
        Assert.IsFalse(insertObserver.GetEvent.WaitFor(0) = wrSignaled);
        Assert.IsTrue(removeObserver.GetEvent.WaitFor(0) = wrSignaled);
      finally removeObserver := nil; end;
    finally insertObserver := nil; end;
  finally subject.Free; end;
end;

end.
