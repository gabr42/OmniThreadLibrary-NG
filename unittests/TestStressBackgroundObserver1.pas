unit TestStressBackgroundObserver1;

///<summary>Stress coverage for OtlBackgroundObserver. Exercises the
///    observer lifetime under concurrent Notify storms from multiple
///    producer threads, rapid create/release churn, and cross-thread
///    lifecycle (observer targets a worker thread that drains then
///    exits, observer is released on the main thread). Marked
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
  TStressBackgroundObserver = class(TOtlTestBase)
  public
    [Test]
    [Category('Stress')]
    procedure StressTestNotifyStormCoalescing;
    [Test]
    [Category('Stress')]
    procedure StressTestConcurrentCreateRelease;
    [Test]
    [Category('Stress')]
    procedure StressTestCrossThreadLifecycle;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  OtlSync,
  OtlPlatform,
  OtlBackgroundObserver;

const
  CNotifyStormProducers   = 4;
  CNotifyStormDuration_ms = 3000;
  CCreateReleaseWorkers   = 4;
  CCreateReleaseIters     = 500;
  CCrossThreadProducers   = 4;
  CCrossThreadDuration_ms = 3000;

// Helper methods: each returns a TProc that owns its captured parameters
// by value, sidestepping Delphi's for-loop closure-capture trap.

function MakeNotifyProducer(const observer: IOmniContainerBackgroundObserver;
  stopFlag, notifyCounter: PInteger): TProc;
begin
  Result :=
    procedure
    begin
      while TInterlocked.CompareExchange(stopFlag^, 0, 0) = 0 do begin
        observer.Notify;
        TInterlocked.Increment(notifyCounter^);
      end;
    end;
end; { MakeNotifyProducer }

function MakeCreateReleaseWorker(iterations: integer;
  iterationCounter, errorCounter: PInteger): TProc;
begin
  Result :=
    procedure
    var
      i       : integer;
      observer: IOmniContainerBackgroundObserver;
      fired   : integer;
    begin
      for i := 1 to iterations do begin
        fired := 0;
        try
          observer := CreateContainerBackgroundObserver(
            TThread.Current.ThreadID,
            procedure begin TInterlocked.Increment(fired); end);
          try
            {$IFNDEF MSWINDOWS}
            RegisterBackgroundObserver(observer);
            try
            {$ENDIF}
              observer.Notify;
              DrainBackgroundObservers;
            {$IFNDEF MSWINDOWS}
            finally UnregisterBackgroundObserver(observer); end;
            {$ENDIF}
          finally observer := nil; end;
          TInterlocked.Increment(iterationCounter^);
        except
          TInterlocked.Increment(errorCounter^);
        end;
      end;
      {$IFNDEF MSWINDOWS}
      // Per-thread registry is a threadvar — must be released before the
      // worker exits or the TList<> it holds is leaked.
      CleanupBackgroundObserverRegistry;
      {$ENDIF}
    end;
end; { MakeCreateReleaseWorker }

{ TStressBackgroundObserver }

procedure TStressBackgroundObserver.StressTestNotifyStormCoalescing;
var
  observer     : IOmniContainerBackgroundObserver;
  producers    : TArray<TThread>;
  stopFlag     : integer;
  notifyCount  : integer;
  callbackCount: integer;
  startTime_ms : int64;
  i            : integer;
begin
  stopFlag      := 0;
  notifyCount   := 0;
  callbackCount := 0;
  observer := CreateContainerBackgroundObserver(
    TThread.Current.ThreadID,
    procedure begin TInterlocked.Increment(callbackCount); end);
  try
    {$IFNDEF MSWINDOWS}
    RegisterBackgroundObserver(observer);
    try
    {$ENDIF}
      SetLength(producers, CNotifyStormProducers);
      for i := 0 to High(producers) do begin
        producers[i] := TThread.CreateAnonymousThread(
          MakeNotifyProducer(observer, @stopFlag, @notifyCount));
        producers[i].FreeOnTerminate := false;
        producers[i].Start;
      end;

      startTime_ms := Time.Timestamp_ms;
      while not Time.HasElapsed(startTime_ms, CNotifyStormDuration_ms) do begin
        DrainBackgroundObservers;
        Sleep(1);
      end;
      TInterlocked.Exchange(stopFlag, 1);
      for i := 0 to High(producers) do begin
        producers[i].WaitFor;
        producers[i].Free;
      end;
      // Final drain catches any still-pending APCs / registry entries.
      DrainBackgroundObservers;

      Assert.IsTrue(notifyCount >= CNotifyStormProducers,
        Format('TStressBackgroundObserver.StressTestNotifyStormCoalescing: ' +
          'every producer must fire at least once (fired %d total across %d producers)',
          [notifyCount, CNotifyStormProducers]));
      Assert.IsTrue(callbackCount >= 1,
        Format('TStressBackgroundObserver.StressTestNotifyStormCoalescing: ' +
          'callback must fire at least once (fired %d times, %d notifies)',
          [callbackCount, notifyCount]));
      Assert.IsTrue(callbackCount <= notifyCount,
        Format('TStressBackgroundObserver.StressTestNotifyStormCoalescing: ' +
          'callback count (%d) must not exceed notify count (%d) — coalescing is lossy downward only',
          [callbackCount, notifyCount]));
    {$IFNDEF MSWINDOWS}
    finally UnregisterBackgroundObserver(observer); end;
    {$ENDIF}
  finally observer := nil; end;
end; { TStressBackgroundObserver.StressTestNotifyStormCoalescing }

procedure TStressBackgroundObserver.StressTestConcurrentCreateRelease;
var
  workers         : TArray<TThread>;
  iterationCount  : integer;
  errorCount      : integer;
  i               : integer;
begin
  iterationCount := 0;
  errorCount     := 0;
  SetLength(workers, CCreateReleaseWorkers);
  for i := 0 to High(workers) do begin
    workers[i] := TThread.CreateAnonymousThread(
      MakeCreateReleaseWorker(CCreateReleaseIters, @iterationCount, @errorCount));
    workers[i].FreeOnTerminate := false;
    workers[i].Start;
  end;
  try
    for i := 0 to High(workers) do
      workers[i].WaitFor;
  finally
    for i := 0 to High(workers) do
      workers[i].Free;
  end;
  Assert.AreEqual<integer>(0, errorCount,
    Format('TStressBackgroundObserver.StressTestConcurrentCreateRelease: ' +
      'observer create/release must not raise (got %d exceptions)', [errorCount]));
  Assert.AreEqual<integer>(CCreateReleaseWorkers * CCreateReleaseIters, iterationCount,
    Format('TStressBackgroundObserver.StressTestConcurrentCreateRelease: ' +
      'expected %d completions, got %d',
      [CCreateReleaseWorkers * CCreateReleaseIters, iterationCount]));
end; { TStressBackgroundObserver.StressTestConcurrentCreateRelease }

procedure TStressBackgroundObserver.StressTestCrossThreadLifecycle;
// Observer is created on the main thread, its target thread is a worker
// that drains until told to stop; producer threads hammer Notify while the
// worker drains. After the worker exits, the observer is released on the
// main thread — exercising the observer's tolerance for a dead target.
var
  observer     : IOmniContainerBackgroundObserver;
  owner        : TThread;
  producers    : TArray<TThread>;
  stopProducers: integer;
  stopOwner    : integer;
  notifyCount  : integer;
  callbackCount: integer;
  ownerStarted : IOmniEvent;
  ownerTid     : TThreadID;
  startTime_ms : int64;
  i            : integer;
begin
  stopProducers := 0;
  stopOwner     := 0;
  notifyCount   := 0;
  callbackCount := 0;
  ownerStarted  := CreateOmniEvent(true, false);
  ownerTid      := 0;

  owner := TThread.CreateAnonymousThread(
    procedure
    begin
      ownerTid := TThread.Current.ThreadID;
      ownerStarted.SetEvent;
      while TInterlocked.CompareExchange(stopOwner, 0, 0) = 0 do begin
        DrainBackgroundObservers;
        Sleep(1);
      end;
      // One last drain before exit so late-queued APCs (Windows) or
      // registry entries (POSIX) are not orphaned.
      DrainBackgroundObservers;
    end);
  owner.FreeOnTerminate := false;
  owner.Start;
  try
    Assert.AreEqual(wrSignaled, ownerStarted.WaitFor(5000),
      'TStressBackgroundObserver.StressTestCrossThreadLifecycle: owner thread did not start');

    observer := CreateContainerBackgroundObserver(
      ownerTid,
      procedure begin TInterlocked.Increment(callbackCount); end);
    try
      SetLength(producers, CCrossThreadProducers);
      for i := 0 to High(producers) do begin
        producers[i] := TThread.CreateAnonymousThread(
          MakeNotifyProducer(observer, @stopProducers, @notifyCount));
        producers[i].FreeOnTerminate := false;
        producers[i].Start;
      end;

      startTime_ms := Time.Timestamp_ms;
      while not Time.HasElapsed(startTime_ms, CCrossThreadDuration_ms) do
        Sleep(50);

      TInterlocked.Exchange(stopProducers, 1);
      for i := 0 to High(producers) do begin
        producers[i].WaitFor;
        producers[i].Free;
      end;
      // Owner keeps draining until we tell it to stop so queued APCs
      // still have a live target while we wind down.
      TInterlocked.Exchange(stopOwner, 1);
      owner.WaitFor;

      Assert.IsTrue(notifyCount >= CCrossThreadProducers,
        Format('TStressBackgroundObserver.StressTestCrossThreadLifecycle: ' +
          'every producer must fire at least once (fired %d / %d)',
          [notifyCount, CCrossThreadProducers]));
    finally observer := nil; end; // release on the main thread, target is gone
  finally owner.Free; end;
end; { TStressBackgroundObserver.StressTestCrossThreadLifecycle }

initialization
  TDUnitX.RegisterTestFixture(TStressBackgroundObserver);
end.
