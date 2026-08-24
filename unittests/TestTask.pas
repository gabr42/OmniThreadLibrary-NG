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
    [Test] procedure TestRegisterWaitObjectProc;
    {$IFDEF MSWINDOWS}
    [Test] procedure TestRegisterWaitObjectHandle;
    [Test] procedure TestRegisterWaitObjectHandleProc;
    [Test] procedure TestRegisterWaitObjectHandleUnregisterInHandler;
    {$ENDIF MSWINDOWS}
    [Test] procedure TestInvoke;
    [Test] procedure TestInvokeByPointerOverloads;
    [Test] procedure TestInvokeArrayOfConstPacking;
    [Test] procedure TestInvokeRemoteFunc;
    [Test] procedure TestInvokeRemoteFuncEx;
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
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF MSWINDOWS}
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

type
  // Exercises the TOmniWaitObjectProc (anonymous method) overload, in the
  // "helper method returns a closure that captures its parameters by value"
  // shape required by CLAUDE.md's closure-capture guidance - real-world
  // usage is TTeletextGenerator.MakeCollectorEventHandler in
  // dvbTeletext.Generator.pas. MakeHandler is called twice with different
  // tags, so this also confirms each registration gets its own distinct
  // captured value rather than sharing one.
  TRegisterWaitObjectProcTask = class(TSynchronizedOmniWorker)
  strict private
    FWaitObject1: IOmniEvent;
    FWaitObject2: IOmniEvent;
  strict protected
    function  MakeHandler(const tag: string): TOmniWaitObjectProc;
  protected
    function  Initialize: boolean; override;
  public
    constructor Create(Synchronizer: IOmniSynchronizer<string>;
      const waitObject1, waitObject2: IOmniEvent);
  end;

constructor TRegisterWaitObjectProcTask.Create(Synchronizer: IOmniSynchronizer<string>;
  const waitObject1, waitObject2: IOmniEvent);
begin
  inherited Create(Synchronizer);
  FWaitObject1 := waitObject1;
  FWaitObject2 := waitObject2;
end;

function TRegisterWaitObjectProcTask.Initialize: boolean;
begin
  Result := inherited Initialize;
  if Result then begin
    Task.RegisterWaitObject(FWaitObject1, MakeHandler('signal1'));
    Task.RegisterWaitObject(FWaitObject2, MakeHandler('signal2'));
  end;
end;

function TRegisterWaitObjectProcTask.MakeHandler(const tag: string): TOmniWaitObjectProc;
begin
  Result :=
    procedure
    begin
      FSynchronizer.Signal(tag);
    end;
end;

procedure TestITaskControl.TestRegisterWaitObjectProc;
var
  event1: IOmniEvent;
  event2: IOmniEvent;
  sw    : TStopwatch;
  task  : IOmniTaskControl;
begin
  event1 := CreateOmniEvent(false, false);
  event2 := CreateOmniEvent(false, false);

  task := CreateTask(TRegisterWaitObjectProcTask.Create(Synchronizer, event1, event2), 'Test task');
  task.Run;

  event1.SetEvent;
  event2.SetEvent;
  Assert.IsTrue(Synchronizer.WaitFor('signal1', 3000), 'Wait object anon handler 1 was not triggered');
  Assert.IsTrue(Synchronizer.WaitFor('signal2', 3000), 'Wait object anon handler 2 was not triggered');

  sw := TStopwatch.StartNew;
  task.Terminate;
  Assert.IsTrue(sw.ElapsedMilliseconds < 500, 'Task took long time to terminate');
  Sleep(0);
end;

{$IFDEF MSWINDOWS}
type
  TRegisterWaitObjectHandleTask = class(TSynchronizedOmniWorker)
  strict private
    FHandle1          : THandle;
    FHandle2          : THandle;
    FUnregisterInEvent: boolean;
  strict protected
    procedure RespondToEvent1;
    procedure RespondToEvent2;
  protected
    function Initialize: boolean; override;
    procedure Cleanup; override;
  public
    constructor Create(Synchronizer: IOmniSynchronizer<string>;
      handle1, handle2: THandle; unregisterInEvent: boolean = false);
  end;

constructor TRegisterWaitObjectHandleTask.Create(
  Synchronizer: IOmniSynchronizer<string>; handle1, handle2: THandle;
  unregisterInEvent: boolean);
begin
  inherited Create(Synchronizer);
  FHandle1 := handle1;
  FHandle2 := handle2;
  FUnregisterInEvent := unregisterInEvent;
end;

function TRegisterWaitObjectHandleTask.Initialize: boolean;
begin
  Result := inherited Initialize;
  if Result then begin
    Task.RegisterWaitObject(FHandle1, RespondToEvent1);
    Task.RegisterWaitObject(FHandle2, RespondToEvent2);
  end;
end;

procedure TRegisterWaitObjectHandleTask.Cleanup;
begin
  // Leave unregistration to executor teardown; exercises that path too.
  inherited Cleanup;
end;

procedure TRegisterWaitObjectHandleTask.RespondToEvent1;
begin
  FSynchronizer.Signal('handle1');
  if FUnregisterInEvent then
    Task.UnregisterWaitObject(FHandle1);
end;

procedure TRegisterWaitObjectHandleTask.RespondToEvent2;
begin
  FSynchronizer.Signal('handle2');
end;

procedure TestITaskControl.TestRegisterWaitObjectHandle;
var
  handle1: THandle;
  handle2: THandle;
  sw     : TStopwatch;
  task   : IOmniTaskControl;
begin
  // Auto-reset kernel events, externally signalled via Win32 SetEvent.
  // Verifies the pool-callback bridge wakes the CV-based task waiter.
  handle1 := Winapi.Windows.CreateEvent(nil, false, false, nil);
  handle2 := Winapi.Windows.CreateEvent(nil, false, false, nil);
  Assert.AreNotEqual(THandle(0), handle1, 'Failed to create handle1');
  Assert.AreNotEqual(THandle(0), handle2, 'Failed to create handle2');
  try
    task := CreateTask(TRegisterWaitObjectHandleTask.Create(Synchronizer, handle1, handle2),
      'TestRegisterWaitObjectHandle');
    task.Run;

    Winapi.Windows.SetEvent(handle1);
    Winapi.Windows.SetEvent(handle2);
    Assert.IsTrue(Synchronizer.WaitFor('handle1', 3000), 'Handle 1 callback was not triggered');
    Assert.IsTrue(Synchronizer.WaitFor('handle2', 3000), 'Handle 2 callback was not triggered');

    // Synchronizer uses manual-reset TEvent; reset so WaitFor below actually
    // blocks on a fresh Signal, otherwise the prior set state makes the
    // re-fire assertion pass vacuously.
    Synchronizer.Reset('handle1');

    // Signal handle1 again — auto-reset kernel events should re-fire the callback.
    Winapi.Windows.SetEvent(handle1);
    Assert.IsTrue(Synchronizer.WaitFor('handle1', 3000),
      'Handle 1 callback did not re-fire on second signal');

    sw := TStopwatch.StartNew;
    task.Terminate;
    Assert.IsTrue(sw.ElapsedMilliseconds < 500,
      'Task took too long to terminate after HANDLE registrations');
    task := nil;
  finally
    Winapi.Windows.CloseHandle(handle1);
    Winapi.Windows.CloseHandle(handle2);
  end;
end;

type
  // THandle counterpart to TRegisterWaitObjectProcTask: exercises
  // RegisterWaitObject(THandle, TOmniWaitObjectProc), i.e. the bridge path
  // (RegisterWaitForSingleObject -> proxy IOmniEvent) with an anonymous
  // handler built by a by-value-capturing helper method.
  TRegisterWaitObjectHandleProcTask = class(TSynchronizedOmniWorker)
  strict private
    FHandle1: THandle;
    FHandle2: THandle;
  strict protected
    function  MakeHandler(const tag: string): TOmniWaitObjectProc;
  protected
    function  Initialize: boolean; override;
  public
    constructor Create(Synchronizer: IOmniSynchronizer<string>; handle1, handle2: THandle);
  end;

constructor TRegisterWaitObjectHandleProcTask.Create(
  Synchronizer: IOmniSynchronizer<string>; handle1, handle2: THandle);
begin
  inherited Create(Synchronizer);
  FHandle1 := handle1;
  FHandle2 := handle2;
end;

function TRegisterWaitObjectHandleProcTask.Initialize: boolean;
begin
  Result := inherited Initialize;
  if Result then begin
    Task.RegisterWaitObject(FHandle1, MakeHandler('handle1'));
    Task.RegisterWaitObject(FHandle2, MakeHandler('handle2'));
  end;
end;

function TRegisterWaitObjectHandleProcTask.MakeHandler(const tag: string): TOmniWaitObjectProc;
begin
  Result :=
    procedure
    begin
      FSynchronizer.Signal(tag);
    end;
end;

procedure TestITaskControl.TestRegisterWaitObjectHandleProc;
var
  handle1: THandle;
  handle2: THandle;
  sw     : TStopwatch;
  task   : IOmniTaskControl;
begin
  handle1 := Winapi.Windows.CreateEvent(nil, false, false, nil);
  handle2 := Winapi.Windows.CreateEvent(nil, false, false, nil);
  Assert.AreNotEqual(THandle(0), handle1, 'Failed to create handle1');
  Assert.AreNotEqual(THandle(0), handle2, 'Failed to create handle2');
  try
    task := CreateTask(TRegisterWaitObjectHandleProcTask.Create(Synchronizer, handle1, handle2),
      'TestRegisterWaitObjectHandleProc');
    task.Run;

    Winapi.Windows.SetEvent(handle1);
    Winapi.Windows.SetEvent(handle2);
    Assert.IsTrue(Synchronizer.WaitFor('handle1', 3000), 'Handle 1 anon handler was not triggered');
    Assert.IsTrue(Synchronizer.WaitFor('handle2', 3000), 'Handle 2 anon handler was not triggered');

    sw := TStopwatch.StartNew;
    task.Terminate;
    Assert.IsTrue(sw.ElapsedMilliseconds < 500,
      'Task took too long to terminate after HANDLE+Proc registrations');
    task := nil;
  finally
    Winapi.Windows.CloseHandle(handle1);
    Winapi.Windows.CloseHandle(handle2);
  end;
end;

procedure TestITaskControl.TestRegisterWaitObjectHandleUnregisterInHandler;
var
  handle1: THandle;
  handle2: THandle;
  sw     : TStopwatch;
  task   : IOmniTaskControl;
begin
  // Handler unregisters its own handle. After that, further signals on
  // handle1 must NOT re-trigger the handler. handle2 remains live.
  handle1 := Winapi.Windows.CreateEvent(nil, true, false, nil); // manual-reset
  handle2 := Winapi.Windows.CreateEvent(nil, false, false, nil);
  Assert.AreNotEqual(THandle(0), handle1, 'Failed to create handle1');
  Assert.AreNotEqual(THandle(0), handle2, 'Failed to create handle2');
  try
    task := CreateTask(
      TRegisterWaitObjectHandleTask.Create(Synchronizer, handle1, handle2,
        {unregisterInEvent=} true),
      'TestRegisterWaitObjectHandleUnregisterInHandler');
    task.Run;

    Winapi.Windows.SetEvent(handle1);
    Assert.IsTrue(Synchronizer.WaitFor('handle1', 3000),
      'Handle 1 callback was not triggered on first signal');

    // Synchronizer uses manual-reset TEvent internally; reset so the next
    // WaitFor blocks until a new Signal(handle1) actually arrives.
    Synchronizer.Reset('handle1');

    // Handler unregistered handle1 — the manual-reset kernel HANDLE is
    // still signalled but the task must no longer receive any new
    // 'handle1' signal from the response handler.
    Assert.IsFalse(Synchronizer.WaitFor('handle1', 200),
      'Handle 1 callback fired after UnregisterWaitObject');

    // handle2 must still work.
    Winapi.Windows.SetEvent(handle2);
    Assert.IsTrue(Synchronizer.WaitFor('handle2', 3000),
      'Handle 2 callback was not triggered after handle1 unregister');

    sw := TStopwatch.StartNew;
    task.Terminate;
    Assert.IsTrue(sw.ElapsedMilliseconds < 500,
      'Task took too long to terminate after handler-driven unregister');
    task := nil;
  finally
    Winapi.Windows.CloseHandle(handle1);
    Winapi.Windows.CloseHandle(handle2);
  end;
end;
{$ENDIF MSWINDOWS}

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
  task  : IOmniTaskControl;
  worker: IOmniWorker;
begin
  // D11/D12 won't auto-cast a TOmniWorker class instance to IOmniWorker
  // inside CreateTask's overload set; assign through a typed local first.
  worker := TRaisingWorker.Create;
  task := CreateTask(worker, 'FatalException-worker').Run;
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
  delegate: TOmniTaskDelegate;
  detached: Exception;
  task    : IOmniTaskControl;
begin
  // D11/D12 fail overload resolution when an inline anonymous procedure is
  // passed directly to CreateTask; bind to a typed local first.
  delegate := procedure (const tsk: IOmniTask)
              begin
                raise EWorkerTestException.Create('detachable');
              end;
  task := CreateTask(delegate, 'DetachException').Run;
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
  delegate: TOmniTaskDelegate;
  task    : IOmniTaskControl;
begin
  delegate := procedure (const tsk: IOmniTask)
              begin
                raise ECountedWorkerException.Create('auto-freed');
              end;
  task := CreateTask(delegate, 'FatalException-autofree').Run;
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
  delegate: TOmniTaskDelegate;
  task    : IOmniTaskControl;
begin
  delegate := procedure (const tsk: IOmniTask)
              begin
                // Normal exit — no raise.
              end;
  task := CreateTask(delegate, 'NoFatal').Run;
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
