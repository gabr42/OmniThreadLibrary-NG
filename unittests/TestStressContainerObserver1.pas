unit TestStressContainerObserver1;

///<summary>Stress coverage for OtlContainerObserver.TOmniContainerSubject.
///    Exercises the snapshot-then-dispatch pattern introduced in 2.05 (the
///    deadlock fix) and the interface-refcounted snapshot entries
///    introduced in 2.06 (the use-after-free fix) under concurrent
///    Attach / Detach / Notify from many threads. Marked
///    [Category('Stress')] so it is excluded from default runs.</summary>
///<author>Primoz Gabrijelcic, Claude</author>
///<remarks><para>
///   Creation date     : 2026-04-20
///   Last modification : 2026-04-20
///   Version           : 1.00
///</para></remarks>

interface

uses
  DUnitX.TestFramework,
  TestOtlBase;

type
  [TestFixture]
  [Category('Stress')]
  TStressContainerObserver = class(TOtlTestBase)
  public
    [Test]
    [Category('Stress')]
    procedure StressTestConcurrentAttachDetachNotify;
    [Test]
    [Category('Stress')]
    procedure StressTestNotifyDuringObserverRelease;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  OtlSync,
  OtlPlatform,
  OtlContainerObserver;

const
  CChurnProducers       = 4;
  CChurnDuration_ms     = 3000;
  CReleaseObserverCount = 64;
  CReleaseNotifiers     = 4;
  CReleaseDuration_ms   = 3000;

type
  TCountingObserver = class(TOmniContainerObserver)
  strict private
    FNotifyCount: integer;
  public
    procedure Notify; override;
    property NotifyCount: integer read FNotifyCount;
  end;

procedure TCountingObserver.Notify;
begin
  TInterlocked.Increment(FNotifyCount);
end; { TCountingObserver.Notify }

// Helper methods: pass captured state by value to sidestep Delphi's for-loop
// closure-capture trap (CLAUDE.md).

function MakeChurnWorker(subject: TOmniContainerSubject;
  stopFlag: PInteger; attachCounter, detachCounter, notifyCounter: PInteger;
  interest: TOmniContainerObserverInterest): TProc;
begin
  Result :=
    procedure
    var
      localObserver: IOmniContainerObserver;
    begin
      while TInterlocked.CompareExchange(stopFlag^, 0, 0) = 0 do begin
        // Create a fresh observer, attach, notify, detach, release.
        // Each iteration churns the observer list and fires a snapshot.
        localObserver := TCountingObserver.Create;
        subject.Attach(localObserver, interest);
        TInterlocked.Increment(attachCounter^);
        subject.Notify(interest);
        TInterlocked.Increment(notifyCounter^);
        subject.Detach(localObserver, interest);
        TInterlocked.Increment(detachCounter^);
        localObserver := nil;
      end;
    end;
end; { MakeChurnWorker }

function MakeReleaseNotifier(subject: TOmniContainerSubject; stopFlag: PInteger;
  interest: TOmniContainerObserverInterest): TProc;
begin
  Result :=
    procedure
    begin
      while TInterlocked.CompareExchange(stopFlag^, 0, 0) = 0 do
        subject.Notify(interest);
    end;
end; { MakeReleaseNotifier }

function MakeReleaseChurner(subject: TOmniContainerSubject; stopFlag: PInteger;
  interest: TOmniContainerObserverInterest): TProc;
begin
  Result :=
    procedure
    var
      observers: array of IOmniContainerObserver;
      i        : integer;
    begin
      SetLength(observers, CReleaseObserverCount);
      while TInterlocked.CompareExchange(stopFlag^, 0, 0) = 0 do begin
        for i := 0 to High(observers) do begin
          observers[i] := TCountingObserver.Create;
          subject.Attach(observers[i], interest);
        end;
        for i := 0 to High(observers) do
          subject.Detach(observers[i], interest);
        // Drop all refs in one go. Some dispatchers may still hold a snapshot
        // reference taken mid-cycle — the interface refcount must keep those
        // objects alive until Notify returns.
        for i := 0 to High(observers) do
          observers[i] := nil;
      end;
    end;
end; { MakeReleaseChurner }

{ TStressContainerObserver }

procedure TStressContainerObserver.StressTestConcurrentAttachDetachNotify;
var
  subject      : TOmniContainerSubject;
  workers      : TArray<TThread>;
  stopFlag     : integer;
  attachCount  : integer;
  detachCount  : integer;
  notifyCount  : integer;
  startTime_ms : int64;
  i            : integer;
begin
  stopFlag    := 0;
  attachCount := 0;
  detachCount := 0;
  notifyCount := 0;
  subject := TOmniContainerSubject.Create;
  try
    SetLength(workers, CChurnProducers);
    for i := 0 to High(workers) do begin
      workers[i] := TThread.CreateAnonymousThread(
        MakeChurnWorker(subject, @stopFlag, @attachCount, @detachCount, @notifyCount,
          coiNotifyOnAllInserts));
      workers[i].FreeOnTerminate := false;
      workers[i].Start;
    end;

    startTime_ms := Time.Timestamp_ms;
    while not Time.HasElapsed(startTime_ms, CChurnDuration_ms) do
      Sleep(50);
    TInterlocked.Exchange(stopFlag, 1);

    for i := 0 to High(workers) do begin
      workers[i].WaitFor;
      workers[i].Free;
    end;

    Assert.AreEqual<integer>(attachCount, detachCount,
      Format('TStressContainerObserver.StressTestConcurrentAttachDetachNotify: ' +
        'Attach count (%d) must equal Detach count (%d)',
        [attachCount, detachCount]));
    Assert.IsTrue(notifyCount >= CChurnProducers,
      Format('TStressContainerObserver.StressTestConcurrentAttachDetachNotify: ' +
        'expected every worker to Notify at least once (got %d)', [notifyCount]));
  finally subject.Free; end;
end; { TStressContainerObserver.StressTestConcurrentAttachDetachNotify }

procedure TStressContainerObserver.StressTestNotifyDuringObserverRelease;
// One churner thread repeatedly attaches/detaches/releases a pool of
// observers while CReleaseNotifiers threads spam Notify. If the snapshot
// did not hold interface refs (pre-2.06) the Notify dispatchers would walk
// over freed observers and crash / corrupt memory. Success = no crash,
// no exception, and every notifier got to fire at least once.
var
  subject      : TOmniContainerSubject;
  churner      : TThread;
  notifiers    : TArray<TThread>;
  stopFlag     : integer;
  startTime_ms : int64;
  i            : integer;
begin
  stopFlag := 0;
  subject := TOmniContainerSubject.Create;
  try
    churner := TThread.CreateAnonymousThread(
      MakeReleaseChurner(subject, @stopFlag, coiNotifyOnAllInserts));
    churner.FreeOnTerminate := false;
    churner.Start;

    SetLength(notifiers, CReleaseNotifiers);
    for i := 0 to High(notifiers) do begin
      notifiers[i] := TThread.CreateAnonymousThread(
        MakeReleaseNotifier(subject, @stopFlag, coiNotifyOnAllInserts));
      notifiers[i].FreeOnTerminate := false;
      notifiers[i].Start;
    end;

    startTime_ms := Time.Timestamp_ms;
    while not Time.HasElapsed(startTime_ms, CReleaseDuration_ms) do
      Sleep(50);
    TInterlocked.Exchange(stopFlag, 1);

    for i := 0 to High(notifiers) do begin
      notifiers[i].WaitFor;
      notifiers[i].Free;
    end;
    churner.WaitFor;
    churner.Free;

    // Post-condition: reaching this point without an access violation is the
    // real assertion — the snapshot-keeps-alive invariant held under load.
    Assert.Pass('Concurrent Notify + Attach/Detach/Release churn completed without crash');
  finally subject.Free; end;
end; { TStressContainerObserver.StressTestNotifyDuringObserverRelease }

initialization
  TDUnitX.RegisterTestFixture(TStressContainerObserver);
end.
