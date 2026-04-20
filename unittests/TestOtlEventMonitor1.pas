unit TestOtlEventMonitor1;

// Tests for TOmniEventMonitor — message and termination event delivery,
// ProcessTerminated drain filtering (2.0e regression), pool monitoring.
//
// TOmniEventMonitor.Create asserts it runs on the main thread. On runners
// that dispatch tests on a worker thread (Android FMX), every test here
// will call Assert.Pass with a skip message instead of failing.

interface

uses
  DUnitX.TestFramework,
  OtlCommon,
  OtlComm,
  OtlTaskControl,
  OtlThreadPool,
  OtlEventMonitor,
  TestOtlBase;

type
  [TestFixture]
  TestOmniEventMonitor = class(TOtlTestBase)
  strict private
    FMessageCount      : integer;
    FTerminatedCount   : integer;
    FLastMessageIntVal : integer;
    FSeenReservedMsgID : boolean;
    FPoolWorkItemCount : integer;
    FPoolThreadCreated : integer;
    procedure HandleTaskMessage(const task: IOmniTaskControl; const msg: TOmniMessage);
    procedure HandleTaskTerminated(const task: IOmniTaskControl);
    procedure HandlePoolWorkItemCompleted(const pool: IOmniThreadPool; taskID: int64);
    procedure HandlePoolThreadCreated(const pool: IOmniThreadPool; threadID: integer);
    procedure SkipIfNotMainThread;
  public
    [Setup] procedure SetupTest;
    [Test] procedure TestCreateDestroy;
    [Test] procedure TestCreateOnWorkerThreadRaises;
    [Test] procedure TestOnTaskMessageDelivered;
    [Test] procedure TestOnTaskTerminatedDelivered;
    [Test] procedure TestMultipleMessagesAllDelivered;
    [Test] procedure TestDetachStopsDelivery;
    [Test] procedure TestInternalMessagesFilteredFromOnTaskMessage;
    [Test] procedure TestAllMessagesDeliveredAroundTermination;
    [Test] procedure TestMonitorDestroyWhileTaskRunning;
    [Test] procedure TestMonitorPoolWorkItemCompleted;
  end;

implementation

uses
  System.Classes,
  System.SysUtils,
  System.Diagnostics,
  System.SyncObjs,
  OtlSync,
  OtlTask;

const
  CTimeout_ms = 5000;
  CMsgUser    = 1001;

function WaitUntil(const predicate: TFunc<boolean>; timeout_ms: cardinal): boolean;
var
  sw: TStopwatch;
begin
  sw := TStopwatch.StartNew;
  while (not predicate()) and (sw.ElapsedMilliseconds < timeout_ms) do begin
    CheckSynchronize(10);
  end;
  Result := predicate();
end;

{ TestOmniEventMonitor — fixture-owned event handlers }

procedure TestOmniEventMonitor.HandleTaskMessage(const task: IOmniTaskControl;
  const msg: TOmniMessage);
begin
  TInterlocked.Increment(FMessageCount);
  if msg.MsgID = CMsgUser then
    FLastMessageIntVal := msg.MsgData.AsInteger
  else if msg.MsgID = COtlReservedMsgID then
    FSeenReservedMsgID := true;
end;

procedure TestOmniEventMonitor.HandleTaskTerminated(const task: IOmniTaskControl);
begin
  TInterlocked.Increment(FTerminatedCount);
end;

procedure TestOmniEventMonitor.HandlePoolWorkItemCompleted(
  const pool: IOmniThreadPool; taskID: int64);
begin
  TInterlocked.Increment(FPoolWorkItemCount);
end;

procedure TestOmniEventMonitor.HandlePoolThreadCreated(
  const pool: IOmniThreadPool; threadID: integer);
begin
  TInterlocked.Increment(FPoolThreadCreated);
end;

procedure TestOmniEventMonitor.SkipIfNotMainThread;
begin
  if TThread.CurrentThread.ThreadID <> MainThreadID then
    Assert.Pass('TOmniEventMonitor requires main-thread ownership');
end;

procedure TestOmniEventMonitor.SetupTest;
begin
  FMessageCount := 0;
  FTerminatedCount := 0;
  FLastMessageIntVal := 0;
  FSeenReservedMsgID := false;
  FPoolWorkItemCount := 0;
  FPoolThreadCreated := 0;
end;

procedure TestOmniEventMonitor.TestCreateDestroy;
var
  monitor: TOmniEventMonitor;
begin
  SkipIfNotMainThread;
  monitor := TOmniEventMonitor.Create(nil);
  try
    Assert.IsNotNull(monitor);
    Assert.AreEqual(NativeUInt(MainThreadID), NativeUInt(monitor.ThreadID),
      'Monitor.ThreadID should be MainThreadID');
  finally FreeAndNil(monitor); end;
end;

procedure TestOmniEventMonitor.TestCreateOnWorkerThreadRaises;
var
  workerCaught: boolean;
  thread      : TThread;
begin
  SkipIfNotMainThread;
  workerCaught := false;
  thread := TThread.CreateAnonymousThread(
    procedure
    var m: TOmniEventMonitor;
    begin
      try
        m := TOmniEventMonitor.Create(nil);
        try
          // Should never get here.
        finally FreeAndNil(m); end;
      except
        on E: Exception do
          workerCaught := true;
      end;
    end);
  thread.FreeOnTerminate := false;
  thread.Start;
  thread.WaitFor;
  thread.Free;
  Assert.IsTrue(workerCaught,
    'Creating TOmniEventMonitor on a worker thread must raise an exception');
end;

procedure TestOmniEventMonitor.TestOnTaskMessageDelivered;
var
  monitor: TOmniEventMonitor;
  task   : IOmniTaskControl;
begin
  SkipIfNotMainThread;
  monitor := TOmniEventMonitor.Create(nil);
  try
    monitor.OnTaskMessage := HandleTaskMessage;
    task := CreateTask(
      procedure (const tsk: IOmniTask)
      begin
        tsk.Comm.Send(CMsgUser, 42);
      end, 'TestOnTaskMessageDelivered').MonitorWith(monitor).Run;
    try
      Assert.IsTrue(
        WaitUntil(function: boolean begin Result := FMessageCount >= 1; end,
          CTimeout_ms),
        'OnTaskMessage did not fire within timeout');
      Assert.AreEqual(1, FMessageCount, 'Expected exactly one user message');
      Assert.AreEqual(42, FLastMessageIntVal, 'Message payload mismatch');
    finally
      task.Terminate;
      task := nil;
    end;
  finally FreeAndNil(monitor); end;
end;

procedure TestOmniEventMonitor.TestOnTaskTerminatedDelivered;
var
  monitor: TOmniEventMonitor;
  task   : IOmniTaskControl;
begin
  SkipIfNotMainThread;
  monitor := TOmniEventMonitor.Create(nil);
  try
    monitor.OnTaskTerminated := HandleTaskTerminated;
    task := CreateTask(
      procedure (const tsk: IOmniTask)
      begin
        // Exit immediately.
      end, 'TestOnTaskTerminatedDelivered').MonitorWith(monitor).Run;
    try
      Assert.IsTrue(
        WaitUntil(function: boolean begin Result := FTerminatedCount >= 1; end,
          CTimeout_ms),
        'OnTaskTerminated did not fire within timeout');
      Assert.AreEqual(1, FTerminatedCount, 'OnTaskTerminated must fire exactly once');
    finally task := nil; end;
  finally FreeAndNil(monitor); end;
end;

procedure TestOmniEventMonitor.TestMultipleMessagesAllDelivered;
const
  CMessageCount = 25;
var
  monitor: TOmniEventMonitor;
  task   : IOmniTaskControl;
begin
  SkipIfNotMainThread;
  monitor := TOmniEventMonitor.Create(nil);
  try
    monitor.OnTaskMessage := HandleTaskMessage;
    task := CreateTask(
      procedure (const tsk: IOmniTask)
      var i: integer;
      begin
        for i := 1 to CMessageCount do
          tsk.Comm.Send(CMsgUser, i);
      end, 'TestMultipleMessagesAllDelivered').MonitorWith(monitor).Run;
    try
      Assert.IsTrue(
        WaitUntil(function: boolean
                  begin Result := FMessageCount >= CMessageCount; end,
          CTimeout_ms),
        Format('Only %d of %d messages delivered',
          [FMessageCount, CMessageCount]));
      Assert.AreEqual(CMessageCount, FMessageCount);
      Assert.AreEqual(CMessageCount, FLastMessageIntVal,
        'Last delivered message should hold the highest index');
    finally
      task.Terminate;
      task := nil;
    end;
  finally FreeAndNil(monitor); end;
end;

procedure TestOmniEventMonitor.TestDetachStopsDelivery;
// Monitor a task, receive one message, detach, send more messages from the
// task — subsequent messages must not fire OnTaskMessage.
var
  monitor: TOmniEventMonitor;
  task   : IOmniTaskControl;
  release: IOmniEvent;
  counted: integer;
begin
  SkipIfNotMainThread;
  release := CreateOmniEvent(true, false);
  monitor := TOmniEventMonitor.Create(nil);
  try
    monitor.OnTaskMessage := HandleTaskMessage;
    task := CreateTask(
      procedure (const tsk: IOmniTask)
      var i: integer;
      begin
        tsk.Comm.Send(CMsgUser, 1);
        // Wait for main thread to detach monitor before sending more.
        release.WaitFor(CTimeout_ms);
        for i := 2 to 10 do
          tsk.Comm.Send(CMsgUser, i);
      end, 'TestDetachStopsDelivery').MonitorWith(monitor).Run;
    try
      Assert.IsTrue(
        WaitUntil(function: boolean begin Result := FMessageCount >= 1; end,
          CTimeout_ms),
        'First message did not arrive');
      counted := FMessageCount;
      monitor.Detach(task);
      release.SetEvent;
      task.WaitFor(CTimeout_ms);
      // Drain any ForceQueue items that may be pending.
      CheckSynchronize(100);
      Assert.AreEqual(counted, FMessageCount,
        'OnTaskMessage fired after Detach');
    finally task := nil; end;
  finally FreeAndNil(monitor); end;
end;

procedure TestOmniEventMonitor.TestInternalMessagesFilteredFromOnTaskMessage;
// Regression for TOmniEventMonitor 2.0e. Messages carrying the reserved
// internal MsgID ($FFFF) must be filtered out by FilterMessage before
// reaching the user's OnTaskMessage handler. Pre-2.0e, ProcessTerminated
// drained Endpoint1 without calling FilterMessage, so any internal-ID
// message that arrived after ProcessNewMessage's last sweep leaked to
// OnTaskMessage at termination time.
var
  monitor: TOmniEventMonitor;
  task   : IOmniTaskControl;
begin
  SkipIfNotMainThread;
  monitor := TOmniEventMonitor.Create(nil);
  try
    monitor.OnTaskMessage := HandleTaskMessage;
    monitor.OnTaskTerminated := HandleTaskTerminated;
    task := CreateTask(
      procedure (const tsk: IOmniTask)
      var i: integer;
      begin
        // Interleave user and internal-ID messages. Whichever drain path
        // picks them up (ProcessNewMessage or ProcessTerminated), the
        // reserved-ID ones must never surface in OnTaskMessage.
        for i := 1 to 5 do begin
          tsk.Comm.Send(COtlReservedMsgID, i);
          tsk.Comm.Send(CMsgUser, i);
        end;
      end, 'TestInternalMessagesFiltered').MonitorWith(monitor).Run;
    try
      Assert.IsTrue(
        WaitUntil(function: boolean begin Result := FTerminatedCount >= 1; end,
          CTimeout_ms),
        'OnTaskTerminated did not fire within timeout');
      Assert.IsFalse(FSeenReservedMsgID,
        'Reserved-ID message leaked to OnTaskMessage (2.0e regression)');
      Assert.AreEqual(5, FMessageCount,
        'OnTaskMessage count mismatch — expected 5 user messages');
    finally task := nil; end;
  finally FreeAndNil(monitor); end;
end;

procedure TestOmniEventMonitor.TestAllMessagesDeliveredAroundTermination;
// Sanity check complementing TestInternalMessagesFilteredFromOnTaskMessage:
// user messages sent in a tight burst right before the task exits must all
// be delivered — whether ProcessNewMessage drains them or the drain in
// ProcessTerminated picks up the stragglers.
const
  CBurst = 50;
var
  monitor: TOmniEventMonitor;
  task   : IOmniTaskControl;
begin
  SkipIfNotMainThread;
  monitor := TOmniEventMonitor.Create(nil);
  try
    monitor.OnTaskMessage := HandleTaskMessage;
    monitor.OnTaskTerminated := HandleTaskTerminated;
    task := CreateTask(
      procedure (const tsk: IOmniTask)
      var i: integer;
      begin
        for i := 1 to CBurst do
          tsk.Comm.Send(CMsgUser, i);
      end, 'TestAllMessagesDeliveredAroundTermination').MonitorWith(monitor).Run;
    try
      Assert.IsTrue(
        WaitUntil(function: boolean begin Result := FTerminatedCount >= 1; end,
          CTimeout_ms),
        'OnTaskTerminated did not fire within timeout');
      Assert.AreEqual(CBurst, FMessageCount,
        Format('Lost messages around termination: got %d of %d',
          [FMessageCount, CBurst]));
    finally task := nil; end;
  finally FreeAndNil(monitor); end;
end;

procedure TestOmniEventMonitor.TestMonitorDestroyWhileTaskRunning;
// Destroy the monitor while the task is still running. The monitor's
// destructor calls RemoveMonitor on every monitored task, so the task
// keeps running but no further events are delivered. The task must still
// terminate cleanly.
var
  monitor: TOmniEventMonitor;
  task   : IOmniTaskControl;
  release: IOmniEvent;
begin
  SkipIfNotMainThread;
  release := CreateOmniEvent(true, false);
  monitor := TOmniEventMonitor.Create(nil);
  try
    monitor.OnTaskMessage := HandleTaskMessage;
    monitor.OnTaskTerminated := HandleTaskTerminated;
    task := CreateTask(
      procedure (const tsk: IOmniTask)
      begin
        release.WaitFor(CTimeout_ms);
      end, 'TestMonitorDestroyWhileTaskRunning').MonitorWith(monitor).Run;
    try
      // Give task a moment to actually start running.
      Sleep(20);
    finally
      FreeAndNil(monitor);
    end;
    release.SetEvent;
    Assert.IsTrue(task.WaitFor(CTimeout_ms),
      'Task did not terminate after monitor was destroyed');
  finally
    task := nil;
  end;
end;

procedure TestOmniEventMonitor.TestMonitorPoolWorkItemCompleted;
const
  CTaskCount = 5;
var
  monitor: TOmniEventMonitor;
  pool   : IOmniThreadPool;
  i      : integer;
begin
  SkipIfNotMainThread;
  {$IFNDEF MSWINDOWS}
  // TOmniThreadPool.MonitorWith is guarded by {$IFDEF MSWINDOWS} in
  // OtlThreadPool.pas — pool monitoring is Windows-only for now. The test
  // would silently time out (no notifications ever arrive) on other targets.
  Assert.Pass('TOmniThreadPool.MonitorWith is MSWINDOWS-only');
  {$ENDIF}
  monitor := TOmniEventMonitor.Create(nil);
  try
    monitor.OnPoolThreadCreated := HandlePoolThreadCreated;
    monitor.OnPoolWorkItemCompleted := HandlePoolWorkItemCompleted;
    pool := CreateThreadPool('TestMonitorPoolWorkItemCompleted');
    try
      pool.MonitorWith(monitor);
      for i := 1 to CTaskCount do
        CreateTask(
          procedure (const tsk: IOmniTask)
          begin
            // Trivial work.
          end, 'poolWorkItem')
        .Unobserved
        .Schedule(pool);
      Assert.IsTrue(
        WaitUntil(function: boolean
                  begin Result := FPoolWorkItemCount >= CTaskCount; end,
          CTimeout_ms),
        Format('Expected %d OnPoolWorkItemCompleted calls, got %d (ThreadCreated=%d)',
          [CTaskCount, FPoolWorkItemCount, FPoolThreadCreated]));
      Assert.IsTrue(FPoolThreadCreated >= 1,
        'OnPoolThreadCreated was never called');
    finally
      monitor.Detach(pool);
      pool := nil;
    end;
  finally FreeAndNil(monitor); end;
end;

initialization
  TDUnitX.RegisterTestFixture(TestOmniEventMonitor);
end.
