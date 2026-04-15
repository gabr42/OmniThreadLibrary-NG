unit TestOtlSync1;


interface

uses
  DUnitX.TestFramework,
  {$IFDEF MSWindows}
  Winapi.Windows,
  {$ENDIF}
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

  [TestFixture]
  TestCancellationToken = class
  public
    [Test]
    procedure TestCreateAndSignal;
    [Test]
    procedure TestClear;
    [Test]
    procedure TestEventProperty;
  end;

  [TestFixture]
  TestCountdownEvent = class
  public
    [Test]
    procedure TestCountdown;
    [Test]
    procedure TestReset;
  end;

  [TestFixture]
  TestLockedT = class
  public
    [Test]
    procedure TestCreateAndValue;
    [Test]
    procedure TestImplicitConversion;
    [Test]
    procedure TestInitializeWithFactory;
    [Test]
    procedure TestIsInitialized;
    [Test]
    procedure TestMREWAccess;
    [Test]
    procedure TestLockedCallback;
    [Test]
    procedure TestFree;
  end;

  [TestFixture]
  TestLightweightMREWEx = class
  public
    [Test]
    procedure TestNestedWrite;
    [Test]
    procedure TestReadBlockedByWrite;
  end;

  [TestFixture]
  TestLockManager = class
  public
    [Test]
    procedure TestLockUnlockByKey;
    [Test]
    procedure TestLockUnlockAutoRelease;
    [Test]
    procedure TestLockTimeoutFailure;
    [Test]
    procedure TestMultipleKeysIndependent;
  end;

  [TestFixture]
  TestSingleThreadUseChecker = class
  public
    [Test]
    procedure TestSameThreadOK;
    [Test]
    procedure TestDifferentThreadRaises;
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

{ TestCancellationToken }

procedure TestCancellationToken.TestCreateAndSignal;
var
  ct: IOmniCancellationToken;
begin
  ct := CreateOmniCancellationToken;
  Assert.IsFalse(ct.IsSignalled, 'initially not signalled');
  ct.Signal;
  Assert.IsTrue(ct.IsSignalled, 'signalled after Signal');
end;

procedure TestCancellationToken.TestClear;
var
  ct: IOmniCancellationToken;
begin
  ct := CreateOmniCancellationToken;
  ct.Signal;
  Assert.IsTrue(ct.IsSignalled, 'signalled');
  ct.Clear;
  Assert.IsFalse(ct.IsSignalled, 'cleared');
  ct.Signal;
  Assert.IsTrue(ct.IsSignalled, 're-signalled after clear');
end;

procedure TestCancellationToken.TestEventProperty;
var
  ct: IOmniCancellationToken;
begin
  ct := CreateOmniCancellationToken;
  Assert.IsTrue(wrTimeout = ct.Event.WaitFor(0), 'event not set initially');
  ct.Signal;
  Assert.IsTrue(wrSignaled = ct.Event.WaitFor(0), 'event set after signal');
  ct.Clear;
  Assert.IsTrue(wrTimeout = ct.Event.WaitFor(0), 'event cleared');
end;

{ TestCountdownEvent }

procedure TestCountdownEvent.TestCountdown;
var
  cde: IOmniCountdownEvent;
begin
  cde := CreateOmniCountdownEvent(3, 0);
  Assert.IsTrue(wrTimeout = cde.WaitFor(0), 'not signalled at count=3');
  cde.BaseCountdown.Signal;
  Assert.IsTrue(wrTimeout = cde.WaitFor(0), 'not signalled at count=2');
  cde.BaseCountdown.Signal;
  Assert.IsTrue(wrTimeout = cde.WaitFor(0), 'not signalled at count=1');
  cde.BaseCountdown.Signal;
  Assert.IsTrue(cde.IsSignalled, 'signalled at count=0');
end;

procedure TestCountdownEvent.TestReset;
var
  cde: IOmniCountdownEvent;
begin
  cde := CreateOmniCountdownEvent(1, 0);
  cde.BaseCountdown.Signal;
  Assert.IsTrue(cde.IsSignalled, 'signalled');
  cde.Reset;
  Assert.IsFalse(cde.IsSignalled, 'not signalled after reset');
  cde.BaseCountdown.Signal;
  Assert.IsTrue(cde.IsSignalled, 'signalled again');
end;

{ TestLockedT }

procedure TestLockedT.TestCreateAndValue;
var
  li: Locked<integer>;
begin
  li := Locked<integer>.Create(42);
  li.Acquire;
  try
    Assert.AreEqual<integer>(42, li.Value);
  finally li.Release; end;
end;

procedure TestLockedT.TestImplicitConversion;
var
  li: Locked<integer>;
  v: integer;
begin
  li := Locked<integer>.Create(17);
  li.Acquire;
  try
    v := li;
  finally li.Release; end;
  Assert.AreEqual<integer>(17, v);
end;

procedure TestLockedT.TestInitializeWithFactory;
var
  li: Locked<integer>;
  v: integer;
begin
  FillChar(li, SizeOf(li), 0);
  v := li.Initialize(
    function: integer begin Result := 99; end);
  Assert.AreEqual<integer>(99, v);
  li.Acquire;
  try
    Assert.AreEqual<integer>(99, li.Value);
  finally li.Release; end;
  // Second call returns same value without calling factory again
  v := li.Initialize(
    function: integer begin Result := 200; end);
  Assert.AreEqual<integer>(99, v, 'factory not called on second Initialize');
end;

procedure TestLockedT.TestIsInitialized;
var
  li: Locked<integer>;
begin
  FillChar(li, SizeOf(li), 0);
  Assert.IsFalse(li.IsInitialized, 'not initialized initially');
  li := Locked<integer>.Create(1);
  Assert.IsTrue(li.IsInitialized, 'initialized after Create');
end;

procedure TestLockedT.TestMREWAccess;
var
  li: Locked<integer>;
  v: integer;
begin
  li := Locked<integer>.Create(10);
  v := li.BeginRead;
  Assert.AreEqual<integer>(10, v);
  li.EndRead;
  v := li.BeginWrite;
  Assert.AreEqual<integer>(10, v);
  li.EndWrite;
end;

procedure TestLockedT.TestLockedCallback;
var
  li: Locked<integer>;
  sum: integer;
begin
  li := Locked<integer>.Create(5);
  sum := 0;
  li.Locked(
    procedure(const value: integer)
    begin
      sum := value + 10;
    end);
  Assert.AreEqual<integer>(15, sum);
end;

procedure TestLockedT.TestFree;
var
  li: Locked<TStringList>;
  sl: TStringList;
begin
  sl := TStringList.Create;
  sl.Add('test');
  li := Locked<TStringList>.Create(sl, true);
  li.Acquire;
  try
    Assert.AreEqual<integer>(1, li.Value.Count);
  finally li.Release; end;
  li.Free;
end;

{ TestLightweightMREWEx }

procedure TestLightweightMREWEx.TestNestedWrite;
var
  mrew: TLightweightMREWEx;
begin
  mrew.BeginWrite;
  // Nested write from same thread should succeed
  mrew.BeginWrite;
  mrew.EndWrite;
  mrew.EndWrite;
  Assert.IsTrue(true, 'nested write succeeded');
end;

procedure TestLightweightMREWEx.TestReadBlockedByWrite;
var
  mrew: ILightweightMREWEx;
  synch: IOmniSynchronizer<string>;
  blocked: TOmniAlignedInt32;
begin
  mrew := TLightweightMREWExImpl.Create;
  synch := TOmniSynchronizer<string>.Create;
  blocked.Value := 0;

  mrew.BeginWrite;
  System.Threading.TTask.Run(
    procedure
    begin
      synch.Signal('started');
      blocked.Value := 1;
      mrew.BeginRead;
      blocked.Value := 2;
      mrew.EndRead;
    end);

  synch.WaitFor('started');
  Sleep(200);
  Assert.AreEqual<integer>(1, blocked.Value, 'reader is blocked');
  mrew.EndWrite;
  Sleep(200);
  Assert.AreEqual<integer>(2, blocked.Value, 'reader unblocked after EndWrite');
end;

{ TestLockManager }

procedure TestLockManager.TestLockUnlockByKey;
var
  lm: IOmniLockManager<string>;
begin
  lm := TOmniLockManager<string>.CreateInterface;
  Assert.IsTrue(lm.Lock('key1', 0), 'lock key1');
  lm.Unlock('key1');
  Assert.IsTrue(lm.Lock('key1', 0), 're-lock key1 after unlock');
  lm.Unlock('key1');
end;

procedure TestLockManager.TestLockUnlockAutoRelease;
var
  lm: IOmniLockManager<string>;
begin
  lm := TOmniLockManager<string>.CreateInterface;
  begin
    var autoUnlock := lm.LockUnlock('key1', 1000);
    Assert.IsNotNull(autoUnlock, 'auto-unlock acquired');
  end;
  // After autoUnlock goes out of scope, lock should be released
  Assert.IsTrue(lm.Lock('key1', 0), 'lock available after auto-unlock');
  lm.Unlock('key1');
end;

procedure TestLockManager.TestLockTimeoutFailure;
var
  lm: IOmniLockManager<string>;
  synch: IOmniSynchronizer<string>;
begin
  lm := TOmniLockManager<string>.CreateInterface;
  synch := TOmniSynchronizer<string>.Create;

  lm.Lock('key1', 0);

  System.Threading.TTask.Run(
    procedure
    begin
      Assert.IsFalse(lm.Lock('key1', 100), 'lock fails with short timeout');
      synch.Signal('done');
    end);

  synch.WaitFor('done');
  lm.Unlock('key1');
end;

procedure TestLockManager.TestMultipleKeysIndependent;
var
  lm: IOmniLockManager<string>;
begin
  lm := TOmniLockManager<string>.CreateInterface;
  Assert.IsTrue(lm.Lock('a', 0), 'lock a');
  Assert.IsTrue(lm.Lock('b', 0), 'lock b while a locked');
  lm.Unlock('a');
  lm.Unlock('b');
end;

{ TestSingleThreadUseChecker }

procedure TestSingleThreadUseChecker.TestSameThreadOK;
var
  checker: TOmniSingleThreadUseChecker;
begin
  checker.AttachToCurrentThread;
  checker.Check;
  Assert.IsTrue(true, 'Check from same thread OK');
end;

procedure TestSingleThreadUseChecker.TestDifferentThreadRaises;
var
  checker: TOmniSingleThreadUseChecker;
  synch: IOmniSynchronizer<string>;
  raised: TOmniAlignedInt32;
begin
  synch := TOmniSynchronizer<string>.Create;
  raised.Value := 0;
  checker.AttachToCurrentThread;

  System.Threading.TTask.Run(
    procedure
    begin
      try
        checker.Check;
      except
        raised.Value := 1;
      end;
      synch.Signal('done');
    end);

  synch.WaitFor('done');
  Assert.AreEqual<integer>(1, raised.Value, 'Check from different thread raised exception');
end;

end.
