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
    [Test] procedure TestRegisterCommDispatchesMessages;
    [Test] procedure TestUnregisterCommStopsDispatch;
    [Test] procedure TestMultipleAdditionalComms;
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
