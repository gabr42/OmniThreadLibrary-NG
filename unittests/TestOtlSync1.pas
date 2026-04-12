unit TestOtlSync1;

{$I OtlOptions.Inc}

interface

uses
  DUnitX.TestFramework,
  System.SysUtils, System.SyncObjs, System.Classes, System.Threading, System.Diagnostics,
  OtlContainers,
  OtlContainerObserver, OtlCollections, OtlCommon, OtlSync, OtlSync.Utils,
  OtlPlatform;

type
  ISingleton = IInterface;

  TSingleton = class(TInterfacedObject, ISingleton)
  strict private class var
    FNumSingletons: TOmniAlignedInt32;
  strict protected
    class function GetNumSingletons: integer; static;
  public
    constructor Create;
    destructor Destroy; override;
    class property NumSingletons: integer read GetNumSingletons;
  end;

  [TestFixture]
  TestIEvent = class
  public
    [Test]
    procedure TestManualReset;
    [Test]
    procedure TestAutoReset;
    [Test]
    procedure TestInitialState;
    [Test]
    procedure TestWait;
  end;

  [TestFixture]
  TestWaitFor = class
  public
    [Test]
    procedure TestWaitAll;
    [Test]
    procedure TestWaitAny;
  end;

  // Test methods for basic synchronisation stuff
  [TestFixture]
  TestOtlSync = class
  strict private
    FUnalignedLock: packed record
      FFiller1   : byte;
      FSharedLock: TOmniCS;
      FFiller2   : word;
      FFiller3   : byte;
    end;
    FResourceCount: IOmniResourceCount;
    FSharedValue: int64;
    FSync: TOmniSynchronizer;
    {$IFDEF MSWindows}FSystemMutex: TMutex;{$ENDIF} // used only on MSWindows for parallel testing of all supported platforms
    FSingleton: TSingleton;
    FSingletonIntf: ISingleton;
  strict protected
    procedure Asy_AtomicInitIntf(const cancel: IOmniCancellationToken);
    procedure Asy_AtomicInit(const cancel: IOmniCancellationToken);
    procedure Asy_LockCS;
    procedure Asy_ResourceCount;
    function  NumRepeats: integer;
  public
    [Setup]
    procedure SetUp;
    [TearDown]
    procedure TearDown;
    [Test]
    procedure TestCSInitialization;
    [Test]
    procedure TestCSParallel;
    [Test]
    procedure TestCSLock;
    {$IFDEF MSWindows}
    [Test]
    procedure TestResourceCountBasic;
    {$ENDIF}
    [Test]
    procedure TestOptimisticInitialization;
    [Test]
    procedure TestOptimisticInitializationIntf;
    [Test]
    procedure TestMREWRead;
    [Test]
    procedure TestMREWReadInitalBlock;
    [Test]
    procedure TestMREWReadTimeout;
    [Test]
    procedure TestMREWReadTimeoutFail;
    [Test]
    procedure TestMREWWrite;
    [Test]
    procedure TestMREWWriteInitialBlock;
    [Test]
    procedure TestMREWWriteTimeout;
    [Test]
    procedure TestMREWWriteTimeoutFailR;
    [Test]
    procedure TestMREWWriteTimeoutFailW;
  end;

implementation

{ TestOtlSync }

procedure TestOtlSync.TestCSInitialization;
var
  cs: TOmniCS;
  i: integer;

  procedure AcquireRelease;
  var
    cs: TOmniCS;
  begin
    cs.Acquire;
    cs.Release;
  end;

begin
  cs.Initialize;
  cs.Acquire;
  cs.Release;
  for i := 1 to 1000 do
    AcquireRelease;
  Assert.IsTrue(true, 'ok');
end;

procedure Asy_InitializeCS;
var
  i: Integer;

  procedure AcquireRelease;
  var
    cs: TOmniCS;
  begin
    cs.Acquire;
    cs.Release;
  end;

begin
  for i := 1 to 1000 do
    AcquireRelease;
end;

procedure TestOtlSync.TestCSParallel;
var
  i: Integer;
  task: array [1..8] of ITask;
begin
  for i := Low(task) to High(task) do
    task[i] := TTask.Create(Asy_InitializeCS);

  for i := Low(task) to High(task) do
    task[i].Start;

  for i := Low(task) to High(task) do
    task[i].Wait(INFINITE);

  Assert.IsTrue(true, 'ok');
end;

procedure TestOtlSync.TestMREWRead;
var
  count  : TOmniAlignedInt32;
  i      : integer;
  mrew   : TOmniMREW;
  readers: array of ITask;
  time   : int64;
begin
  // Tests whether multiple readers can quire the lock at the same time

  count.Value := 0;

  SetLength(readers, 5);
  for i := Low(readers) to High(readers) do
    readers[i] := System.Threading.TTask.Run(
      procedure
      begin
        mrew.EnterReadLock;
        Sleep(500);
        mrew.ExitReadLock;
        if count.Increment = Length(readers) then
          FSync.Signal('done');
      end);

  time := GTimeSource.Timestamp_ms;
  Assert.IsTrue(FSync.WaitFor('done', 1000), 'Reader lock failed');
  time := GTimeSource.Elapsed_ms(time);

  Assert.IsTrue(time < 1000, 'Readers did not execute in parallel');
end;

procedure TestOtlSync.TestMREWReadTimeout;
var
  count  : TOmniAlignedInt32;
  i      : integer;
  mrew   : TOmniMREW;
  readers: array of ITask;
  time   : int64;
begin
  // Tests whether multiple readers can quire the lock at the same time

  count.Value := 0;

  SetLength(readers, 5);
  for i := Low(readers) to High(readers) do
    readers[i] := System.Threading.TTask.Run(
      procedure
      begin
        if not mrew.TryEnterReadLock(100) then
          Exit;
        Sleep(500);
        mrew.ExitReadLock;
        if count.Increment = Length(readers) then
          FSync.Signal('done');
      end);

  time := GTimeSource.Timestamp_ms;
  Assert.IsTrue(FSync.WaitFor('done', 1000), 'Reader lock failed');
  time := GTimeSource.Elapsed_ms(time);

  Assert.IsTrue(time < 1000, 'Readers did not execute in parallel');
end;

procedure TestOtlSync.TestMREWReadInitalBlock;
var
  count  : TOmniAlignedInt32;
  i      : integer;
  mrew   : TOmniMREW;
  readers: array of ITask;
begin
  // Tests whether a reader will acquire a lock if it is initially blocked

  count.Value := 0;

  mrew.EnterWriteLock;

  SetLength(readers, 5);
  for i := Low(readers) to High(readers) do
    readers[i] := System.Threading.TTask.Run(
      procedure
      begin
        if count.Increment = Length(readers) then
          FSync.Signal('go')
        else
          FSync.WaitFor('go');
        try
          if not mrew.TryEnterReadLock(2000) then begin
            FSync.Signal('fault');
            Exit;
          end;
          mrew.ExitReadLock;
        finally
          if count.Decrement = 0 then
            FSync.Signal('done');
        end;
      end);

  FSync.WaitFor('go');
  Sleep(500);
  mrew.ExitWriteLock;

  Assert.IsTrue(FSync.WaitFor('done', 1000), 'Reader lock failed');
  Assert.IsFalse(FSync.WaitFor('fault', 0), 'At least one reader failed to acquire the lock');
end;

procedure TestOtlSync.TestMREWReadTimeoutFail;
const
  CTImeout = 100;
var
  count  : TOmniAlignedInt32;
  i      : integer;
  mrew   : TOmniMREW;
  readers: array of ITask;
  times  : array of int64;

  function MakeTask(idx: integer): TProc;
  begin
    Result :=
      procedure
      var
        time: int64;
      begin
        FSync.WaitFor('go');
        try
          time := GTimeSource.Timestamp_ms;
          if not mrew.TryEnterReadLock(CTimeout) then begin
            times[idx] := GTimeSource.Elapsed_ms(time);
            Exit;
          end;

          times[idx] := -1;
          mrew.ExitReadLock;
        finally
          if count.Increment = Length(readers) then
            FSync.Signal('done');
        end;
      end;
  end;

begin
  // Tests whether MREW read timeout fails when a writer is acquired and whether both kind of locks can be acquired after that

  count.Value := 0;

  SetLength(times, 5);
  SetLength(readers, 5);
  for i := Low(readers) to High(readers) do
    readers[i] := System.Threading.TTask.Run(MakeTask(i));

  mrew.EnterWriteLock;
  try
    FSync.Signal('go');
    Assert.IsTrue(FSync.WaitFor('done', CTimeout * 10), 'Reader lock failed');
  finally mrew.ExitWriteLock; end;

  for i := Low(readers) to High(readers) do
    Assert.IsTrue((times[i] > (CTimeout * 0.8)) and (times[i] < (CTimeout * 3)),
      Format('Reader #%d waited %d ms instead of %d ms', [i, times[i], CTimeout]));

  if not mrew.TryEnterReadLock(0) then
    Assert.Fail('Failed to acquire read lock after timeouts')
  else
    mrew.ExitReadLock;
  if not mrew.TryEnterWriteLock(0) then
    Assert.Fail('Failed to acquire write lock after timeouts')
  else
    mrew.ExitWriteLock;
end;

procedure TestOtlSync.TestMREWWrite;
var
  count  : TOmniAlignedInt32;
  hwm    : TOmniAlignedInt32;
  i      : integer;
  mrew   : TOmniMREW;
  writers: array of ITask;
begin
  // Tests whether multiple writers cannot quire the lock at the same time

  count.Value := 0;
  hwm.Value := 0;

  SetLength(writers, 5);
  for i := Low(writers) to High(writers) do
    writers[i] := System.Threading.TTask.Run(
      procedure
      begin
        mrew.EnterWriteLock;
        if hwm.Increment > 1 then
          FSync.Signal('overflow');
        Sleep(500);
        hwm.Decrement;
        mrew.ExitWriteLock;
        if count.Increment = Length(writers) then
          FSync.Signal('done');
      end);

  Assert.IsTrue(FSync.WaitFor('done', Length(writers) * 1000), 'Writer lock failed');
  Assert.IsFalse(FSync.WaitFor('overflow', 0), 'More than one writer executed in parallel');
end;

procedure TestOtlSync.TestMREWWriteInitialBlock;
var
  count  : TOmniAlignedInt32;
  i      : integer;
  mrew   : TOmniMREW;
  writers: array of ITask;
begin
  // Tests whether a writer will acquire a lock if it is initially blocked

  count.Value := 0;

  mrew.EnterReadLock;

  SetLength(writers, 5);
  for i := Low(writers) to High(writers) do
    writers[i] := System.Threading.TTask.Run(
      procedure
      begin
        if count.Increment = Length(writers) then
          FSync.Signal('go')
        else
          FSync.WaitFor('go');
        try
          if not mrew.TryEnterWriteLock(2000) then begin
            FSync.Signal('fault');
            Exit;
          end;
          mrew.ExitWriteLock;
        finally
          if count.Decrement = 0 then
            FSync.Signal('done');
        end;
      end);

  FSync.WaitFor('go');
  Sleep(500);
  mrew.ExitReadLock;

  Assert.IsTrue(FSync.WaitFor('done', 1000), 'Writer lock failed');
  Assert.IsFalse(FSync.WaitFor('fault', 0), 'At least one writer failed to acquire the lock');
end;

procedure TestOtlSync.TestMREWWriteTimeout;
var
  count  : TOmniAlignedInt32;
  hwm    : TOmniAlignedInt32;
  i      : integer;
  mrew   : TOmniMREW;
  writers: array of ITask;
begin
  // Tests whether multiple writers cannot quire the lock at the same time

  count.Value := 0;
  hwm.Value := 0;

  SetLength(writers, 5);
  for i := Low(writers) to High(writers) do
    writers[i] := System.Threading.TTask.Run(
      procedure
      begin
        if not mrew.TryEnterWriteLock(Length(writers) * 1000) then begin
          FSync.Signal('failed');
          Exit;
        end;
        if hwm.Increment > 1 then
          FSync.Signal('overflow');
        Sleep(500);
        hwm.Decrement;
        mrew.ExitWriteLock;
        if count.Increment = Length(writers) then
          FSync.Signal('done');
      end);

  Assert.IsTrue(FSync.WaitFor('done', Length(writers) * 1000), 'Writer lock failed');
  Assert.IsFalse(FSync.WaitFor('failed', 0), 'At least one writer failed to acquire lock');
  Assert.IsFalse(FSync.WaitFor('overflow', 0), 'More than one writer executed in parallel');
end;

procedure TestOtlSync.TestMREWWriteTimeoutFailR;
const
  CTImeout = 100;
var
  count  : TOmniAlignedInt32;
  i      : integer;
  mrew   : TOmniMREW;
  writers: array of ITask;
  times  : array of int64;

  function MakeTask(idx: integer): TProc;
  begin
    Result :=
      procedure
      var
        time: int64;
      begin
        FSync.WaitFor('go');
        try
          time := GTimeSource.Timestamp_ms;
          if not mrew.TryEnterWriteLock(CTimeout) then begin
            times[idx] := GTimeSource.Elapsed_ms(time);
            Exit;
          end;

          times[idx] := -1;
          mrew.ExitWriteLock;
        finally
          if count.Increment = Length(writers) then
            FSync.Signal('done');
        end;
      end;
  end;

begin
  // Tests whether MREW write timeout fails when a reader is acquired and whether both kind of locks can be acquired after that

  count.Value := 0;

  SetLength(times, 5);
  SetLength(writers, 5);
  for i := Low(writers) to High(writers) do
    writers[i] := System.Threading.TTask.Run(MakeTask(i));

  mrew.EnterReadLock;
  try
    FSync.Signal('go');
    Assert.IsTrue(FSync.WaitFor('done', CTimeout * 10), 'Writer lock failed');
  finally mrew.ExitReadLock; end;

  for i := Low(writers) to High(writers) do
    Assert.IsTrue((times[i] > (CTimeout * 0.8)) and (times[i] < (CTimeout * 3)),
      Format('Writer #%d waited %d ms instead of %d ms', [i, times[i], CTimeout]));

  if not mrew.TryEnterReadLock(0) then
    Assert.Fail('Failed to acquire read lock after timeouts')
  else
    mrew.ExitReadLock;
  if not mrew.TryEnterWriteLock(0) then
    Assert.Fail('Failed to acquire write lock after timeouts')
  else
    mrew.ExitWriteLock;
end;

procedure TestOtlSync.TestMREWWriteTimeoutFailW;
const
  CTImeout = 100;
var
  count  : TOmniAlignedInt32;
  i      : integer;
  mrew   : TOmniMREW;
  writers: array of ITask;
  times  : array of int64;

  function MakeTask(idx: integer): TProc;
  begin
    Result :=
      procedure
      var
        time: int64;
      begin
        FSync.WaitFor('go');
        try
          time := GTimeSource.Timestamp_ms;
          if not mrew.TryEnterWriteLock(CTimeout) then begin
            times[idx] := GTimeSource.Elapsed_ms(time);
            Exit;
          end;

          times[idx] := -1;
          mrew.ExitWriteLock;
        finally
          if count.Increment = Length(writers) then
            FSync.Signal('done');
        end;
      end;
  end;

begin
  // Tests whether MREW write timeout fails when a writer is acquired and whether both kind of locks can be acquired after that

  count.Value := 0;

  SetLength(times, 5);
  SetLength(writers, 5);
  for i := Low(writers) to High(writers) do
    writers[i] := System.Threading.TTask.Run(MakeTask(i));

  mrew.EnterWriteLock;
  try
    FSync.Signal('go');
    Assert.IsTrue(FSync.WaitFor('done', CTimeout * 10), 'Writer lock failed');
  finally mrew.ExitWriteLock; end;

  for i := Low(writers) to High(writers) do
    Assert.IsTrue((times[i] > (CTimeout * 0.8)) and (times[i] < (CTimeout * 3)),
      Format('Writer #%d waited %d ms instead of %d ms', [i, times[i], CTimeout]));

  if not mrew.TryEnterReadLock(0) then
    Assert.Fail('Failed to acquire read lock after timeouts')
  else
    mrew.ExitReadLock;
  if not mrew.TryEnterWriteLock(0) then
    Assert.Fail('Failed to acquire write lock after timeouts')
  else
    mrew.ExitWriteLock;
end;

procedure TestOtlSync.Asy_LockCS;
var
  i: Integer;
begin
  for i := 1 to 10000 do begin
    FUnalignedLock.FSharedLock.Acquire;
    Inc(FSharedValue);
    FUnalignedLock.FSharedLock.Release;
    FUnalignedLock.FSharedLock.Acquire;
    Dec(FSharedValue);
    FUnalignedLock.FSharedLock.Release;
  end;
end;

procedure TestOtlSync.TestCSLock;
var
  i: Integer;
  task: array [1..8] of ITask;
begin
  for i := Low(task) to High(task) do
    task[i] := TTask.Create(Asy_LockCS);

  for i := Low(task) to High(task) do
    task[i].Start;

  for i := Low(task) to High(task) do
    task[i].Wait(INFINITE);

  Assert.AreEqual<integer>(0, FSharedValue);
end;

procedure TestOtlSync.Asy_AtomicInit(const cancel: IOmniCancellationToken);
begin
  cancel.Event.WaitFor(INFINITE);

  OtlSync.Atomic<TSingleton>.Initialize(FSingleton,
    function: TSingleton begin Result := TSingleton.Create; end);
end;

procedure TestOtlSync.TestOptimisticInitialization;
var
  i      : integer;
  iRepeat: integer;
  task   : array [1..8] of ITask;
  token  : IOmniCancellationToken;
begin
  for iRepeat := 1 to NumRepeats do begin
    FreeAndNil(FSingleton);

    token := CreateOmniCancellationToken;
    for i := Low(task) to High(task) do
      task[i] := System.Threading.TTask.Run(
                   procedure
                   begin
                     Asy_AtomicInit(token)
                   end);

    token.Signal;

    for i := Low(task) to High(task) do
      task[i].Wait(INFINITE);

    Assert.IsTrue(assigned(FSingleton), 'There is no singleton');
  end;
  Assert.AreEqual<integer>(1, TSingleton.NumSingletons);
  FreeAndNil(FSingleton);
end;

procedure TestOtlSync.Asy_AtomicInitIntf(const cancel: IOmniCancellationToken);
begin
  cancel.Event.WaitFor(INFINITE);
  OtlSync.Atomic<ISingleton>.Initialize(FSingletonIntf,
    function: ISingleton begin Result := TSingleton.Create; end);
end;

procedure TestOtlSync.TestOptimisticInitializationIntf;
var
  i      : integer;
  iRepeat: integer;
  task   : array [1..8] of ITask;
  token  : IOmniCancellationToken;
begin
  for iRepeat := 1 to NumRepeats do begin
    FSingletonIntf := nil;

    token := CreateOmniCancellationToken;
    for i := Low(task) to High(task) do
      task[i] := System.Threading.TTask.Run(
                   procedure
                   begin
                     Asy_AtomicInitIntf(token)
                   end);

    token.Signal;

    for i := Low(task) to High(task) do
      task[i].Wait(INFINITE);

    Assert.IsTrue(assigned(FSingletonIntf), 'There is no singleton');
  end;
  Assert.AreEqual<integer>(1, TSingleton.NumSingletons);
  FSingletonIntf := nil;
end;

procedure TestOtlSync.Asy_ResourceCount;
begin
  FResourceCount.Allocate;
  FResourceCount.Release;
end;

function TestOtlSync.NumRepeats: integer;
begin
  {$WARN SYMBOL_PLATFORM OFF}
  if DebugHook <> 0 then
    Result := 10
  else
    Result := {$IFDEF CONSOLE_TESTRUNNER}100{$ELSE}10{$ENDIF};
  {$WARN SYMBOL_PLATFORM ON}
end;

procedure TestOtlSync.SetUp;
begin
  FSync := TOmniSynchronizer.Create;
  {$IFDEF MSWindows}
  FSystemMutex := TMutex.Create(nil, false, '/OmniThreadLibrary/TestOtlSync/A4EDD8C0-88D0-46A9-890B-8EAAF466C44A');
  FSystemMutex.Acquire
  {$ENDIF}
end;

procedure TestOtlSync.TearDown;
begin
  {$IFDEF MSWindows}
  FSystemMutex.Release;
  FreeAndNil(FSystemMutex);
  {$ENDIF}
  FreeAndNil(FSync);
end;

{$IFDEF MSWindows}
procedure TestOtlSync.TestResourceCountBasic;
var
  i   : integer;
  task: array [1..8] of ITask;
begin
  FResourceCount := CreateResourceCount(4);

  for i := Low(task) to High(task) do
    task[i] := TTask.Create(Asy_ResourceCount);

  for i := Low(task) to High(task) do
    task[i].Start;

  for i := Low(task) to High(task) do
    task[i].Wait(INFINITE);

  Assert.AreEqual<cardinal>(3, FResourceCount.Allocate);
end;
{$ENDIF}

{ TSingleton }

constructor TSingleton.Create;
begin
  inherited Create;
  FNumSingletons.Increment;
end;

destructor TSingleton.Destroy;
begin
  FNumSingletons.Decrement;
  inherited;
end;

class function TSingleton.GetNumSingletons: integer;
begin
  Result := FNumSingletons;
end;

{ TestIEvent }

procedure TestIEvent.TestAutoReset;
var
  event: IOmniEvent;
begin
  event := CreateOmniEvent(false, false);
  Assert.IsTrue(wrTimeout = event.WaitFor(0));
  Assert.IsTrue(wrTimeout = event.WaitFor(100));
  event.Signal;
  Assert.IsTrue(wrSignaled = event.WaitFor(0));
  Assert.IsTrue(wrTimeout = event.WaitFor(0));
  event.Signal;
  event.Reset;
  Assert.IsTrue(wrTimeout = event.WaitFor(0));
end;

procedure TestIEvent.TestInitialState;
var
  event: IOmniEvent;
begin
  event := CreateOmniEvent(false, true);
  Assert.IsTrue(wrSignaled = event.WaitFor(0));
end;

procedure TestIEvent.TestManualReset;
var
  event: IOmniEvent;
begin
  event := CreateOmniEvent(true, false);
  Assert.IsTrue(wrTimeout = event.WaitFor(0));
  Assert.IsTrue(wrTimeout = event.WaitFor(100));
  event.Signal;
  Assert.IsTrue(wrSignaled = event.WaitFor(0));
  Assert.IsTrue(wrSignaled = event.WaitFor(100));
  event.Reset;
  Assert.IsTrue(wrTimeout = event.WaitFor(0));
end;

procedure TestIEvent.TestWait;
var
  event: IOmniEvent;
  signal: ITask;
  synch: IOmniSynchronizer<string>;
  wait: ITask;
begin
  synch := TOmniSynchronizer<string>.Create;
  event := CreateOmniEvent(true, false);

  signal := System.Threading.TTask.Run(
    procedure
    begin
      synch.Signal('S:ready');
      synch.WaitFor('start');
      synch.WaitFor('S:signal');
      event.Signal;
    end);

  wait := System.Threading.TTask.Run(
    procedure
    begin
      synch.Signal('W:ready');
      synch.WaitFor('start');
      Assert.IsTrue(wrTimeout = event.WaitFor(0));
      Assert.IsTrue(wrTimeout = event.WaitFor(100));
      Assert.IsTrue(wrSignaled = event.WaitFor(1000));
    end);

  synch.WaitFor('S:ready');
  synch.WaitFor('W:ready');
  synch.Signal('start');
  Sleep(200);
  Synch.Signal('S:signal');

  signal.Wait(INFINITE);
  wait.Wait(INFINITE);
end;

{ TestWaitFor }

procedure TestWaitFor.TestWaitAll;
var
  event1: IOmniEvent;
  event2: IOmniEvent;
  synch: IOmniSynchronizer<string>;
  waiter: ITask;
  wf: TWaitFor;
begin
  event1 := CreateOmniEvent(true, false);
  event2 := CreateOmniEvent(true, false);
  wf := TWaitFor.Create([event1, event2]);
  try
    synch := TOmniSynchronizer<string>.Create;
    waiter := System.Threading.TTask.Run(
      procedure
      var
        time: int64;
      begin
        synch.Signal('W:ready');
        synch.WaitFor('start');
        Assert.IsTrue(waTimeout = wf.WaitAll(0));
        Assert.IsTrue(waTimeout = wf.WaitAll(100));
        Assert.IsTrue(waAwaited = wf.WaitAll(2000));
        time := GTimeSource.Timestamp_ms;
        Assert.IsTrue(waAwaited = wf.WaitAll(2000));
        Assert.IsFalse(GTimeSource.HasElapsed(time, 1000));
      end);

    Assert.IsTrue(waTimeout = wf.WaitAll(0));
    Assert.IsTrue(waTimeout = wf.WaitAll(100));
    event1.Signal;
    Assert.IsTrue(waTimeout = wf.WaitAll(0));

    synch.WaitFor('W:ready');
    synch.Signal('start');
    Sleep(500);
    event2.Signal;
    waiter.Wait(INFINITE);
  finally FreeAndNil(wf); end;
end;

procedure TestWaitFor.TestWaitAny;
var
  event1: IOmniEvent;
  event2: IOmniEvent;
  synch: IOmniSynchronizer<string>;
  waiter: ITask;
  wf: TWaitFor;
begin
  event1 := CreateOmniEvent(true, false);
  event2 := CreateOmniEvent(true, false);
  wf := TWaitFor.Create([event1, event2]);
  try
    synch := TOmniSynchronizer<string>.Create;
    waiter := System.Threading.TTask.Run(
      procedure
      var
        time: int64;
      begin
        synch.Signal('W:ready');
        synch.WaitFor('start');
        Assert.IsTrue(waTimeout = wf.WaitAny(0));
        Assert.IsTrue(waTimeout = wf.WaitAny(100));
        Assert.IsTrue(waAwaited = wf.WaitAny(2000));
        time := GTimeSource.Timestamp_ms;
        Assert.IsTrue(waAwaited = wf.WaitAny(2000));
        Assert.IsFalse(GTimeSource.HasElapsed(time, 1000));
      end);

    Assert.IsTrue(waTimeout = wf.WaitAll(0));
    Assert.IsTrue(waTimeout = wf.WaitAll(100));

    synch.WaitFor('W:ready');
    synch.Signal('start');
    Sleep(500);
    event2.Signal;
    waiter.Wait(INFINITE);
  finally FreeAndNil(wf); end;
end;

end.
