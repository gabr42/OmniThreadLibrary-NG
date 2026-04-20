unit TestTask;

interface

uses
  DUnitX.TestFramework,
  OtlSync.Utils,
  TestOtlBase;

type
  [TestFixture]
  TestITaskControl = class(TOtlTestBase)
  strict private
    Synchronizer: IOmniSynchronizer<string>;
  public
    [Setup] procedure SetUp;
    [TearDown] procedure TearDown;
    [Test] procedure TestStartTask;
    [Test] procedure TestWait;
    [Test] procedure TestTerminate;
    [Test] procedure TestTerminateWhen;
    [Test] procedure TestWorkerInitialized;
    [Test] procedure TestRegisterWaitObject;
    [Test] procedure TestInvoke;
    [Test] procedure TestInvokeByPointerOverloads;
    [Test] procedure TestInvokeArrayOfConstPacking;
    [Test] procedure TestInvokeRemoteFunc;
    [Test] procedure TestInvokeRemoteFuncEx;
    [Test] procedure TestProcessorGroupValidIsAccepted;
    [Test] procedure TestProcessorGroupInvalidRaises;
    [Test] procedure TestNUMANodeValidIsAccepted;
    [Test] procedure TestNUMANodeInvalidRaises;
    [Test] procedure TestRegisterCommDispatchesMessages;
    [Test] procedure TestUnregisterCommStopsDispatch;
    [Test] procedure TestMultipleAdditionalComms;
    [Test] procedure TestFatalExceptionFromAnonymousTask;
    [Test] procedure TestFatalExceptionFromWorker;
    [Test] procedure TestDetachExceptionTransfersOwnership;
    [Test] procedure TestFatalExceptionFreedOnTaskDestroy;
    [Test] procedure TestNoExceptionMeansNilFatalException;
  end;

implementation

uses
  System.Classes, System.SysUtils, System.SyncObjs, System.Diagnostics,
  OtlTask, OtlTaskControl, OtlCommon, OtlSync, OtlComm;

type
  TSynchronizedOmniWorker = class(TOmniWorker)
  strict protected
    FSynchronizer: IOmniSynchronizer<string>;
  protected
    constructor Create(Synchronizer: IOmniSynchronizer<string>);
  end;

{ TestITaskControl }

procedure TestITaskControl.SetUp;
begin
  Synchronizer := TOmniSynchronizer<string>.Create;
end;

procedure TestITaskControl.TearDown;
begin
  Synchronizer := nil;
end;

procedure TestITaskControl.TestStartTask;
var
  didRun: boolean;
  sw    : TStopwatch;
  task  : IOmniTaskControl;
begin
  for var i := 1 to 100 do begin
    task := CreateTask(procedure (const task: IOmniTask) begin Sleep(Random(10)); end).Run;
    task.WaitFor(3000);
    task.Terminate(INFINITE);
  end;

  didRun := false;
  task := CreateTask(
    procedure (const task: IOmniTask)
    begin
      didRun := true;
    end,
    'Test task');

  task.Run;

  Assert.IsTrue(task.WaitFor(3000), 'Task did not terminate in 3 seconds');
  Assert.IsTrue(didRun, 'Task did not run');

  sw := TStopwatch.StartNew;
  task.Terminate;
  Assert.IsTrue(sw.ElapsedMilliseconds < 500, 'Task took long time to terminate');
  Sleep(0);
end;

procedure TestITaskControl.TestWait;
var
  sw  : TStopwatch;
  task: IOmniTaskControl;
begin
  task := CreateTask(
    procedure (const task: IOmniTask)
    begin
      Synchronizer.Signal('started');
      Synchronizer.WaitFor('stop', 5000);
    end,
    'Test task');

  task.Run;

  Assert.IsTrue(Synchronizer.WaitFor('started', 1000), 'Task did not start in 1 second');
  Assert.IsFalse(task.WaitFor(0), 'WaitFor(0) should not succeed');
  Assert.IsFalse(task.WaitFor(1000), 'WaitFor(100) should not succeed');

  Synchronizer.Signal('stop');

  Assert.IsTrue(task.WaitFor(3000), 'Task did not terminate in 3 seconds');

  sw := TStopwatch.StartNew;
  task.Terminate;
  Assert.IsTrue(sw.ElapsedMilliseconds < 500, 'Task took long time to terminate');
  Sleep(0);
end;

procedure TestITaskControl.TestTerminate;
var
  sw  : TStopwatch;
  task: IOmniTaskControl;
begin
  task := CreateTask(
    procedure (const task: IOmniTask)
    begin
      Synchronizer.Signal('started');
      while not task.Terminated do
        Sleep(0);
    end,
    'Test task');

  task.Run;

  Assert.IsTrue(Synchronizer.WaitFor('started', 1000), 'Task did not start in 1 second');
  Assert.IsFalse(task.WaitFor(1000), 'Task has terminated prematurely');
  task.Stop;
  Assert.IsTrue(task.WaitFor(3000), 'Task did not terminate in 3 seconds');

  sw := TStopwatch.StartNew;
  task.Terminate;
  Assert.IsTrue(sw.ElapsedMilliseconds < 500, 'Task took long time to terminate');
  Sleep(0);
end;

type
  TTerminateWhenTask = class(TSynchronizedOmniWorker)
  protected
    function Initialize: boolean; override;
  end;

function TTerminateWhenTask.Initialize: boolean;
begin
  Result := inherited Initialize;
  if Result then
    FSynchronizer.Signal('started');
end;

procedure TestITaskControl.TestTerminateWhen;
var
  event: IOmniEvent;
  sw   : TStopwatch;
  task : IOmniTaskControl;
begin
  event := CreateOmniEvent(false, false);

  task := CreateTask(TTerminateWhenTask.Create(Synchronizer), 'Test task');
  task.TerminateWhen(event).Run;

  Assert.IsTrue(Synchronizer.WaitFor('started', 1000), 'Task did not start in 1 second');
  Assert.IsFalse(task.WaitFor(1000), 'Task has terminated prematurely');
  event.SetEvent;
  Assert.IsTrue(task.WaitFor(3000), 'Task did not terminate in 3 seconds');

  sw := TStopwatch.StartNew;
  task.Terminate;
  Assert.IsTrue(sw.ElapsedMilliseconds < 500, 'Task took long time to terminate');
  Sleep(0);
end;

type
  TWorkerInitializedTask = class(TSynchronizedOmniWorker)
  protected
    function Initialize: boolean; override;
  end;

function TWorkerInitializedTask.Initialize: boolean;
begin
  Result := inherited Initialize;
  if Result then begin
    FSynchronizer.Signal('started');
    FSynchronizer.WaitFor('continue', 10000);
    Sleep(1000);
  end;
end;

procedure TestITaskControl.TestWorkerInitialized;
var
  await    : boolean;
  event    : IOmniEvent;
  stopwatch: TStopwatch;
  task     : IOmniTaskControl;
begin
  event := CreateOmniEvent(false, false);

  task := CreateTask(TWorkerInitializedTask.Create(Synchronizer), 'Test task');
  task.TerminateWhen(event).Run;

  Assert.IsTrue(Synchronizer.WaitFor('started', 1000), 'Task did not start in 1 second');
  stopwatch := TStopwatch.StartNew;
  Synchronizer.Signal('continue');
  await := task.WaitForInit;
  stopwatch.Stop;
  Assert.IsTrue(await, 'Task did not initialize correctly');
  Assert.IsTrue(stopwatch.ElapsedMilliseconds >= 1000, 'WaitForInit has returned too soon');

  stopwatch := TStopwatch.StartNew;
  task.Terminate;
  Assert.IsTrue(stopwatch.ElapsedMilliseconds < 500, 'Task took long time to terminate');
  Sleep(0);
end;

type
  TInvokeTask = class(TSynchronizedOmniWorker)
  strict private
    FInvoked: integer;
  strict protected
    procedure SignalDone;
  public
    procedure Method1;
    procedure Method2(const value: TOmniValue);
    procedure Method3(var obj: TOmniValueObj);
  end;

procedure TInvokeTask.Method1;
begin
  Inc(FInvoked, 1);
  SignalDone;
end;

procedure TInvokeTask.Method2(const value: TOmniValue);
begin
  if value = 42 then
    Inc(FInvoked, 2);
  SignalDone;
end;

procedure TInvokeTask.Method3(var obj: TOmniValueObj);
begin
  if obj.Value = '17' then
    Inc(FInvoked, 4);
  obj.Free;
  SignalDone;
end;

procedure TInvokeTask.SignalDone;
begin
  if FInvoked = 7 then
    FSynchronizer.Signal('done');
end;

procedure TestITaskControl.TestInvoke;
var
  task: IOmniTaskControl;
begin
  // Tests all the method signatures supported by Invoke (and other message dispatching functions).

  task := CreateTask(TInvokeTask.Create(Synchronizer), 'Test task');
  task.Run;

  task.Invoke('Method1');
  task.Invoke('Method2', 42);
  task.Invoke('Method3', TOmniValueObj.Create('17'));

  Assert.IsTrue(Synchronizer.WaitFor('done', 5000));

  task.Terminate;
  Sleep(0);
end;

type
  TInvokePointerWorker = class(TSynchronizedOmniWorker)
  strict private
    FFlags: integer;
  strict protected
    procedure SignalIfComplete;
  public
    procedure NoArgs;
    procedure OneOmniValue(const value: TOmniValue);
    procedure TwoItemArray(const value: TOmniValue);
  end;

procedure TInvokePointerWorker.SignalIfComplete;
begin
  if FFlags = 7 then
    FSynchronizer.Signal('ptr-done');
end;

procedure TInvokePointerWorker.NoArgs;
begin
  FFlags := FFlags or 1;
  SignalIfComplete;
end;

procedure TInvokePointerWorker.OneOmniValue(const value: TOmniValue);
begin
  if value = 42 then
    FFlags := FFlags or 2;
  SignalIfComplete;
end;

procedure TInvokePointerWorker.TwoItemArray(const value: TOmniValue);
begin
  // array-of-const [11, string('x')] packs into an array TOmniValue.
  if value.IsArray and (value.AsArray.Count = 2)
     and (value[0].AsInteger = 11) and (value[1].AsString = 'x')
  then
    FFlags := FFlags or 4;
  SignalIfComplete;
end;

procedure TestITaskControl.TestInvokeByPointerOverloads;
// Covers the three by-pointer Invoke overloads:
//   Invoke(msgMethod: pointer)
//   Invoke(msgMethod: pointer; msgData: array of const)
//   Invoke(msgMethod: pointer; msgData: TOmniValue)
// Dispatch goes through TOmniInternalAddressMsg.UnpackMessage which calls
// Implementor.MethodName(method) (OtlTaskControl.pas:2402) to resolve the
// method name — a different lookup path than the by-name overloads.
var
  ov  : TOmniValue;
  task: IOmniTaskControl;
begin
  task := CreateTask(TInvokePointerWorker.Create(Synchronizer), 'Invoke-by-ptr').Run;
  try
    task.Invoke(@TInvokePointerWorker.NoArgs);                   // overload 1
    ov := 42;
    task.Invoke(@TInvokePointerWorker.OneOmniValue, ov);         // overload 3 (TOmniValue)
    task.Invoke(@TInvokePointerWorker.TwoItemArray, [11, string('x')]);  // overload 2 (array of const)
    Assert.IsTrue(Synchronizer.WaitFor('ptr-done', 5000),
      'By-pointer Invoke dispatch did not reach all three methods');
  finally
    task.Terminate;
    task := nil;
  end;
end;

procedure TestITaskControl.TestInvokeArrayOfConstPacking;
// Multi-item array-of-const packs into an array TOmniValue. Verifies the
// Invoke(msgName, array of const) overload correctly delivers multiple
// values inside a single TOmniValue that the worker can unpack.
var
  task: IOmniTaskControl;
begin
  task := CreateTask(TInvokePointerWorker.Create(Synchronizer), 'Invoke-multi-arg').Run;
  try
    task.Invoke('NoArgs');
    task.Invoke('OneOmniValue', 42);
    task.Invoke('TwoItemArray', [11, string('x')]);
    Assert.IsTrue(Synchronizer.WaitFor('ptr-done', 5000),
      'Multi-item array-of-const dispatch failed');
  finally
    task.Terminate;
    task := nil;
  end;
end;

procedure TestITaskControl.TestInvokeRemoteFunc;
// Invoke(remoteFunc: TOmniTaskControlInvokeFunction) — anonymous proc runs
// on the task thread. Dispatch path is TOmniInternalFuncMsg, handled at
// OtlTaskControl.pas:2138-2139 via `func` without any method lookup.
var
  hasRun: boolean;
  task  : IOmniTaskControl;
begin
  hasRun := false;
  task := CreateTask(TInvokePointerWorker.Create(Synchronizer), 'Invoke-remoteFunc').Run;
  try
    task.Invoke(
      procedure
      begin
        hasRun := true;
        Synchronizer.Signal('remote-done');
      end);
    Assert.IsTrue(Synchronizer.WaitFor('remote-done', 5000),
      'Anonymous-proc Invoke did not execute');
    Assert.IsTrue(hasRun, 'Anonymous proc ran but did not set the flag');
  finally
    task.Terminate;
    task := nil;
  end;
end;

procedure TestITaskControl.TestInvokeRemoteFuncEx;
// Invoke(remoteFunc: TOmniTaskControlInvokeFunctionEx) — same as above but
// receives the IOmniTask. OtlTaskControl.pas:2140-2141 calls
// `funcEx(WorkerIntf.Task)`, so the closure must see the task that
// actually runs it.
var
  capturedUniqueID: int64;
  task            : IOmniTaskControl;
begin
  capturedUniqueID := 0;
  task := CreateTask(TInvokePointerWorker.Create(Synchronizer), 'Invoke-remoteFuncEx').Run;
  try
    task.Invoke(
      procedure (const tsk: IOmniTask)
      begin
        capturedUniqueID := tsk.UniqueID;
        Synchronizer.Signal('remote-ex-done');
      end);
    Assert.IsTrue(Synchronizer.WaitFor('remote-ex-done', 5000),
      'Anonymous-procEx Invoke did not execute');
    Assert.AreEqual(task.UniqueID, capturedUniqueID,
      'Task passed to Invoke lambda does not match task control UniqueID');
  finally
    task.Terminate;
    task := nil;
  end;
end;

procedure TestITaskControl.TestProcessorGroupValidIsAccepted;
// VerifyProcessorGroup(0) succeeds on every platform — the fake
// single-group environment CreateFakeNUMAInfo registers on
// non-Windows also has group 0. On Windows SetThreadGroupAffinity
// is actually called from the task thread; on other platforms the
// SetProcessorGroup body is a no-op after Verify passes.
var
  didRun: boolean;
  task  : IOmniTaskControl;
begin
  didRun := false;
  task := CreateTask(
    procedure (const tsk: IOmniTask)
    begin
      didRun := true;
    end, 'ProcGroup-valid').ProcessorGroup(0).Run;
  try
    Assert.IsTrue(task.WaitFor(5000), 'Task did not terminate');
    Assert.IsTrue(didRun, 'Task body did not run');
  finally task := nil; end;
end;

procedure TestITaskControl.TestProcessorGroupInvalidRaises;
// ProcessorGroup(n) raises synchronously from VerifyProcessorGroup
// for negative or out-of-range values — no task startup needed.
var
  task: IOmniTaskControl;
begin
  task := CreateTask(
    procedure (const tsk: IOmniTask) begin end, 'ProcGroup-invalid');
  try
    Assert.WillRaise(
      procedure begin task.ProcessorGroup(-1); end,
      Exception, 'Negative processor group must raise');
    Assert.WillRaise(
      procedure begin task.ProcessorGroup(999); end,
      Exception, 'Out-of-range processor group must raise');
  finally task := nil; end;
end;

procedure TestITaskControl.TestNUMANodeValidIsAccepted;
// Same as ProcessorGroup: node 0 always exists (real on Windows,
// faked on non-Windows).
var
  didRun: boolean;
  task  : IOmniTaskControl;
begin
  didRun := false;
  task := CreateTask(
    procedure (const tsk: IOmniTask)
    begin
      didRun := true;
    end, 'NUMANode-valid').NUMANode(0).Run;
  try
    Assert.IsTrue(task.WaitFor(5000), 'Task did not terminate');
    Assert.IsTrue(didRun, 'Task body did not run');
  finally task := nil; end;
end;

procedure TestITaskControl.TestNUMANodeInvalidRaises;
// VerifyNUMANode raises when FindNode returns nil. Unlike
// VerifyProcessorGroup (range check), it uses dictionary lookup,
// so a nonexistent positive number also raises.
var
  task: IOmniTaskControl;
begin
  task := CreateTask(
    procedure (const tsk: IOmniTask) begin end, 'NUMANode-invalid');
  try
    Assert.WillRaise(
      procedure begin task.NUMANode(-1); end,
      Exception, 'Negative NUMA node must raise');
    Assert.WillRaise(
      procedure begin task.NUMANode(999); end,
      Exception, 'Nonexistent NUMA node must raise');
  finally task := nil; end;
end;

type
  TRegisterWaitObjectTask = class(TSynchronizedOmniWorker)
  strict private
    FWaitObject1: IOmniEvent;
    FWaitObject2: IOmniEvent;
  strict protected
    procedure RespondToEvent1;
    procedure RespondToEvent2;
  protected
    function Initialize: boolean; override;
  public
    constructor Create(Synchronizer: IOmniSynchronizer<string>;
      const waitObject1, waitObject2: IOmniEvent);
  end;

constructor TRegisterWaitObjectTask.Create(Synchronizer: IOmniSynchronizer<string>;
  const waitObject1, waitObject2: IOmniEvent);
begin
  inherited Create(Synchronizer);
  FWaitObject1 := waitObject1;
  FWaitObject2 := waitObject2;
end;

function TRegisterWaitObjectTask.Initialize: boolean;
begin
  Result := inherited Initialize;
  if Result then begin
    Task.RegisterWaitObject(FWaitObject1, RespondToEvent1);
    Task.RegisterWaitObject(FWaitObject2, RespondToEvent2);
  end;
end;

procedure TRegisterWaitObjectTask.RespondToEvent1;
begin
  FSynchronizer.Signal('signal1');
end;

procedure TRegisterWaitObjectTask.RespondToEvent2;
begin
  FSynchronizer.Signal('signal2');
end;

procedure TestITaskControl.TestRegisterWaitObject;
var
  event1: IOmniEvent;
  event2: IOmniEvent;
  sw    : TStopwatch;
  task  : IOmniTaskControl;
begin
  event1 := CreateOmniEvent(false, false);
  event2 := CreateOmniEvent(false, false);

  task := CreateTask(TRegisterWaitObjectTask.Create(Synchronizer, event1, event2), 'Test task');
  task.Run;

  event1.SetEvent;
  event2.SetEvent;
  Assert.IsTrue(Synchronizer.WaitFor('signal1', 3000), 'Wait object handler 1 was not triggered');
  Assert.IsTrue(Synchronizer.WaitFor('signal2', 3000), 'Wait object handler 2 was not triggered');

  sw := TStopwatch.StartNew;
  task.Terminate;
  Assert.IsTrue(sw.ElapsedMilliseconds < 500, 'Task took long time to terminate');
  Sleep(0);
end;

{ TSynchronizedOmniWorker }

constructor TSynchronizedOmniWorker.Create(Synchronizer: IOmniSynchronizer<string>);
begin
  inherited Create;
  FSynchronizer := Synchronizer;
end;

{ Task.RegisterComm / UnregisterComm coverage }

const
  MSG_EXT_A = 2001;
  MSG_EXT_B = 2002;

type
  TCommCounter = class
  strict private
    FCountA: integer;
    FCountB: integer;
  public
    procedure IncA; inline;
    procedure IncB; inline;
    function  CountA: integer;
    function  CountB: integer;
  end;

procedure TCommCounter.IncA;
begin
  TInterlocked.Increment(FCountA);
end;

procedure TCommCounter.IncB;
begin
  TInterlocked.Increment(FCountB);
end;

function TCommCounter.CountA: integer;
begin
  Result := TInterlocked.CompareExchange(FCountA, 0, 0);
end;

function TCommCounter.CountB: integer;
begin
  Result := TInterlocked.CompareExchange(FCountB, 0, 0);
end;

type
  TRegisterCommWorker = class(TSynchronizedOmniWorker)
  strict private
    FChannelA: IOmniCommunicationEndpoint;
    FChannelB: IOmniCommunicationEndpoint;
    FCounter : TCommCounter;
  protected
    function  Initialize: boolean; override;
  public
    constructor Create(Synchronizer: IOmniSynchronizer<string>;
      const channelA, channelB: IOmniCommunicationEndpoint;
      counter: TCommCounter);
    procedure UnregisterChannelA;
    procedure HandleMsgA(var msg: TOmniMessage); message MSG_EXT_A;
    procedure HandleMsgB(var msg: TOmniMessage); message MSG_EXT_B;
  end;

constructor TRegisterCommWorker.Create(Synchronizer: IOmniSynchronizer<string>;
  const channelA, channelB: IOmniCommunicationEndpoint; counter: TCommCounter);
begin
  inherited Create(Synchronizer);
  FChannelA := channelA;
  FChannelB := channelB;
  FCounter := counter;
end;

function TRegisterCommWorker.Initialize: boolean;
begin
  Result := inherited Initialize;
  if Result then begin
    if assigned(FChannelA) then Task.RegisterComm(FChannelA);
    if assigned(FChannelB) then Task.RegisterComm(FChannelB);
  end;
end;

procedure TRegisterCommWorker.HandleMsgA(var msg: TOmniMessage);
begin
  FCounter.IncA;
  FSynchronizer.Signal('A');
end;

procedure TRegisterCommWorker.HandleMsgB(var msg: TOmniMessage);
begin
  FCounter.IncB;
  FSynchronizer.Signal('B');
end;

procedure TRegisterCommWorker.UnregisterChannelA;
begin
  if assigned(FChannelA) then begin
    Task.UnregisterComm(FChannelA);
    FChannelA := nil;
  end;
  FSynchronizer.Signal('unreg-done');
end;

function WaitForCountAtLeast(counter: TCommCounter; readA: boolean;
  target: integer; timeout_ms: cardinal): boolean;
var
  sw: TStopwatch;

  function Current: integer;
  begin
    if readA then Result := counter.CountA else Result := counter.CountB;
  end;

begin
  sw := TStopwatch.StartNew;
  while (Current < target) and (sw.ElapsedMilliseconds < timeout_ms) do
    Sleep(5);
  Result := Current >= target;
end;

procedure TestITaskControl.TestRegisterCommDispatchesMessages;
const
  CMsgCount = 10;
var
  chan   : IOmniTwoWayChannel;
  counter: TCommCounter;
  i      : integer;
  task   : IOmniTaskControl;
begin
  chan := CreateTwoWayChannel(CMsgCount + 2, nil);
  counter := TCommCounter.Create;
  try
    task := CreateTask(
      TRegisterCommWorker.Create(Synchronizer, chan.Endpoint1, nil, counter),
      'RegisterComm-dispatch').Run;
    try
      for i := 1 to CMsgCount do
        chan.Endpoint2.Send(MSG_EXT_A, i);

      Assert.IsTrue(WaitForCountAtLeast(counter, true, CMsgCount, 5000),
        Format('Only %d of %d messages dispatched via registered comm',
          [counter.CountA, CMsgCount]));
      Assert.AreEqual(CMsgCount, counter.CountA,
        'CountA mismatch after dispatch');
      Assert.AreEqual(0, counter.CountB, 'CountB must be 0 — no channel B');
    finally
      task.Terminate;
      task := nil;
    end;
  finally FreeAndNil(counter); end;
end;

procedure TestITaskControl.TestUnregisterCommStopsDispatch;
var
  chan   : IOmniTwoWayChannel;
  counter: TCommCounter;
  task   : IOmniTaskControl;
begin
  chan := CreateTwoWayChannel(8, nil);
  counter := TCommCounter.Create;
  try
    task := CreateTask(
      TRegisterCommWorker.Create(Synchronizer, chan.Endpoint1, nil, counter),
      'RegisterComm-unregister').Run;
    try
      chan.Endpoint2.Send(MSG_EXT_A, 1);
      Assert.IsTrue(Synchronizer.WaitFor('A', 3000),
        'First dispatch never fired');
      Assert.AreEqual(1, counter.CountA, 'Expected exactly one dispatch pre-unregister');

      task.Invoke('UnregisterChannelA');
      Assert.IsTrue(Synchronizer.WaitFor('unreg-done', 3000),
        'UnregisterChannelA did not complete');

      chan.Endpoint2.Send(MSG_EXT_A, 2);
      chan.Endpoint2.Send(MSG_EXT_A, 3);
      Sleep(200);
      Assert.AreEqual(1, counter.CountA,
        'Messages after UnregisterComm must NOT dispatch');
    finally
      task.Terminate;
      task := nil;
    end;
  finally FreeAndNil(counter); end;
end;

{ FatalException / DetachException coverage }

const
  MSG_RAISE = 3001;

type
  EWorkerTestException = class(Exception);

  ECountedWorkerException = class(Exception)
  public
    constructor Create(const msg: string);
    destructor  Destroy; override;
  end;

  TRaisingWorker = class(TOmniWorker)
  public
    constructor Create;
    procedure HandleRaise(var msg: TOmniMessage); message MSG_RAISE;
  end;

var
  GCountedWorkerExceptionCount: integer = 0;

constructor ECountedWorkerException.Create(const msg: string);
begin
  inherited Create(msg);
  TInterlocked.Increment(GCountedWorkerExceptionCount);
end;

destructor ECountedWorkerException.Destroy;
begin
  TInterlocked.Decrement(GCountedWorkerExceptionCount);
  inherited;
end;

constructor TRaisingWorker.Create;
begin
  inherited Create;
end;

procedure TRaisingWorker.HandleRaise(var msg: TOmniMessage);
begin
  raise EWorkerTestException.Create('boom from worker message handler');
end;

procedure TestITaskControl.TestFatalExceptionFromAnonymousTask;
const
  CExceptionMsg = 'boom from anonymous task body';
var
  task: IOmniTaskControl;
begin
  task := CreateTask(
    procedure (const tsk: IOmniTask)
    begin
      raise EWorkerTestException.Create(CExceptionMsg);
    end, 'FatalException-anon').Run;
  try
    Assert.IsTrue(task.WaitFor(5000), 'Task did not terminate');
    Assert.IsNotNull(task.FatalException,
      'FatalException must be set after task raises');
    Assert.IsTrue(task.FatalException is EWorkerTestException,
      Format('FatalException class mismatch — got %s',
        [task.FatalException.ClassName]));
    Assert.AreEqual(CExceptionMsg, task.FatalException.Message,
      'FatalException message mismatch');
  finally task := nil; end;
end;

procedure TestITaskControl.TestFatalExceptionFromWorker;
// TOmniWorker message handler raises — the exception must propagate
// out of DispatchMessages, be caught by TOmniTask.Execute, and
// surface as task.FatalException. Covers the etWorker executor path
// (the anonymous-proc test above exercises etProcedure).
var
  task: IOmniTaskControl;
begin
  task := CreateTask(TRaisingWorker.Create, 'FatalException-worker').Run;
  try
    task.Comm.Send(MSG_RAISE, 0);
    Assert.IsTrue(task.WaitFor(5000), 'Task did not terminate');
    Assert.IsNotNull(task.FatalException,
      'FatalException must be set after worker raises');
    Assert.IsTrue(task.FatalException is EWorkerTestException,
      Format('FatalException class mismatch — got %s',
        [task.FatalException.ClassName]));
    Assert.AreEqual('boom from worker message handler',
      task.FatalException.Message);
  finally task := nil; end;
end;

procedure TestITaskControl.TestDetachExceptionTransfersOwnership;
// DetachException returns the exception and nils the executor's store,
// transferring ownership to the caller. Subsequent FatalException
// reads return nil. Caller must Free the returned exception —
// FastMM4's leak tracker will catch a miss.
var
  detached: Exception;
  task    : IOmniTaskControl;
begin
  task := CreateTask(
    procedure (const tsk: IOmniTask)
    begin
      raise EWorkerTestException.Create('detachable');
    end, 'DetachException').Run;
  try
    Assert.IsTrue(task.WaitFor(5000), 'Task did not terminate');
    Assert.IsNotNull(task.FatalException, 'Pre-detach FatalException nil');

    detached := task.DetachException;
    try
      Assert.IsNotNull(detached, 'DetachException returned nil');
      Assert.IsTrue(detached is EWorkerTestException,
        'DetachException class mismatch');
      Assert.AreEqual('detachable', detached.Message);
      Assert.IsNull(task.FatalException,
        'FatalException must be nil after DetachException');
    finally FreeAndNil(detached); end;
  finally task := nil; end;
end;

procedure RunRaisingTaskAndWait;
// Bounding the IOmniTaskControl to this helper's scope ensures that when
// RunRaisingTaskAndWait returns, the only ref is the one released by the
// `task := nil` inside the finally. A local IOmniTaskControl in the test
// procedure would be kept alive by compiler-generated expression temps until
// the test procedure exits (same quirk documented in
// TestBlockingCollection1.FillOmniValueWithOwnedObject).
var
  task: IOmniTaskControl;
begin
  task := CreateTask(
    procedure (const tsk: IOmniTask)
    begin
      raise ECountedWorkerException.Create('auto-freed');
    end, 'FatalException-autofree').Run;
  try
    Assert.IsTrue(task.WaitFor(5000), 'Task did not terminate');
    Assert.IsNotNull(task.FatalException,
      'FatalException must be set before task destroy');
    Assert.AreEqual<integer>(1,
      TInterlocked.CompareExchange(GCountedWorkerExceptionCount, 0, 0),
      'Exception instance should be alive while held by FatalException');
  finally task := nil; end;
end;

procedure TestITaskControl.TestFatalExceptionFreedOnTaskDestroy;
// Counter-backed regression: when no one calls DetachException, the
// exception object attached to FatalException must be freed as part of
// task-control teardown. Relies on an explicit instance counter in
// ECountedWorkerException so the check fails at a specific spot rather
// than as an end-of-run FastMM4 leak report.
begin
  TInterlocked.Exchange(GCountedWorkerExceptionCount, 0);
  RunRaisingTaskAndWait;
  if TThread.CurrentThread.ThreadID = MainThreadID then
    CheckSynchronize(0);
  Assert.AreEqual<integer>(0,
    TInterlocked.CompareExchange(GCountedWorkerExceptionCount, 0, 0),
    'ECountedWorkerException leaked — FatalException not freed by task destroy');
end;

procedure TestITaskControl.TestNoExceptionMeansNilFatalException;
var
  task: IOmniTaskControl;
begin
  task := CreateTask(
    procedure (const tsk: IOmniTask)
    begin
      // Normal exit — no raise.
    end, 'NoFatal').Run;
  try
    Assert.IsTrue(task.WaitFor(5000), 'Task did not terminate');
    Assert.IsNull(task.FatalException,
      'FatalException must be nil after normal termination');
  finally task := nil; end;
end;

procedure TestITaskControl.TestMultipleAdditionalComms;
const
  CCountA = 4;
  CCountB = 3;
var
  chanA  : IOmniTwoWayChannel;
  chanB  : IOmniTwoWayChannel;
  counter: TCommCounter;
  i      : integer;
  task   : IOmniTaskControl;
begin
  chanA := CreateTwoWayChannel(8, nil);
  chanB := CreateTwoWayChannel(8, nil);
  counter := TCommCounter.Create;
  try
    task := CreateTask(
      TRegisterCommWorker.Create(Synchronizer,
        chanA.Endpoint1, chanB.Endpoint1, counter),
      'RegisterComm-multi').Run;
    try
      for i := 1 to CCountA do
        chanA.Endpoint2.Send(MSG_EXT_A, i);
      for i := 1 to CCountB do
        chanB.Endpoint2.Send(MSG_EXT_B, i);

      Assert.IsTrue(WaitForCountAtLeast(counter, true, CCountA, 5000),
        Format('Channel A: only %d of %d dispatched',
          [counter.CountA, CCountA]));
      Assert.IsTrue(WaitForCountAtLeast(counter, false, CCountB, 5000),
        Format('Channel B: only %d of %d dispatched',
          [counter.CountB, CCountB]));
      Assert.AreEqual(CCountA, counter.CountA, 'CountA final');
      Assert.AreEqual(CCountB, counter.CountB, 'CountB final');
    finally
      task.Terminate;
      task := nil;
    end;
  finally FreeAndNil(counter); end;
end;

end.
