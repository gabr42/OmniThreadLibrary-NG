unit TestOtlComm;

interface

uses
  DUnitX.TestFramework,
  TestOtlBase;

type
  [TestFixture]
  TestOmniMessageQueue = class(TOtlTestBase)
  public
    [Test]
    procedure TestBasics;
    [Test]
    procedure TestNewMessageEvent;
    [Test]
    procedure TestDestroyReleasesOwnedObjects;
    [Test]
    procedure TestEmptyReleasesOwnedObjects;
  end;

  [TestFixture]
  TestOmniMessageQueueSize1 = class(TOtlTestBase)
  public
    [Test]
    procedure TestSize1Queue;
  end;

  [TestFixture]
  TestOmniMessageQueueOnMessage = class(TOtlTestBase)
  public
    [Test]
    procedure TestFiresOnEnqueue;
    [Test]
    procedure TestDrainsAllQueuedMessagesInOrder;
    [Test]
    procedure TestNotCalledBeforeDrain;
    [Test]
    procedure TestNilDetaches;
    [Test]
    procedure TestDestroyWithActiveHandlerDoesNotRaise;
  end;

  [TestFixture]
  TestIOmniTwoWayChannel = class(TOtlTestBase)
  public
    [Test]
    procedure TestSendReceive;
    [Test]
    procedure TestOtherEndpoint;
    [Test]
    procedure TestWait;
    [Test]
    procedure TestFIFOOrder;
  end;

  [TestFixture]
  TestIOmniMessageQueueTee = class(TOtlTestBase)
  public
    [Test]
    procedure TestBasicTee;
  end;

implementation

uses
  {$IFDEF MSWindows}
  Winapi.Windows,
  {$ENDIF}
  System.SysUtils, System.Types, System.Classes, System.Threading,
  System.SyncObjs,
  OtlSync, OtlSync.Utils,
  OtlCommon, OtlComm, OtlBackgroundObserver;

type
  TLeakCheckObj = class
  public
    constructor Create;
    destructor  Destroy; override;
  end;

var
  GLeakCheckObjCount: integer = 0;

constructor TLeakCheckObj.Create;
begin
  inherited Create;
  TInterlocked.Increment(GLeakCheckObjCount);
end;

destructor TLeakCheckObj.Destroy;
begin
  TInterlocked.Decrement(GLeakCheckObjCount);
  inherited;
end;

{ TestOmniMessageQueue }

procedure TestOmniMessageQueue.TestBasics;
var
  mq : TOmniMessageQueue;
  msg: TOmniMessage;

  procedure CheckDequeue(msgId: integer; const msgData: string; success: boolean);
  var
    msg: TOmniMessage;
  begin
    Assert.AreEqual<boolean>(success, mq.TryDequeue(msg), '#' + msgData + '.TryDequeue');
    if success then begin
      Assert.AreEqual<integer>(msgId, msg.MsgID, '#' + msgData + '.MsgID');
      Assert.AreEqual<string>(msgData, msg.MsgData.AsString, '#' + msgData + '.MsgData');
    end;
  end;

begin
  mq := TOmniMessageQueue.Create(3);
  try
    Assert.IsTrue(mq.Enqueue(TOmniMessage.Create(11, '11')));
    Assert.IsTrue(mq.Enqueue(TOmniMessage.Create(12, '12')));
    Assert.IsTrue(mq.Enqueue(TOmniMessage.Create(13, '13')));
    Assert.IsFalse(mq.Enqueue(TOmniMessage.Create(14, '14')));
    mq.Empty;
    Assert.IsTrue(mq.Enqueue(TOmniMessage.Create(1, '1')));
    Assert.IsTrue(mq.Enqueue(TOmniMessage.Create(2, '2')));
    Assert.IsTrue(mq.Enqueue(TOmniMessage.Create(3, '3')));
    Assert.IsFalse(mq.Enqueue(TOmniMessage.Create(4, '4')));
    CheckDequeue(1, '1', true);
    CheckDequeue(2, '2', true);
    CheckDequeue(3, '3', true);
    CheckDequeue(4, '4', false);
    Assert.IsTrue(mq.Enqueue(TOmniMessage.Create(9, '9')));
    msg := mq.Dequeue;
    Assert.AreEqual<integer>(9, msg.MsgID, 'MsgID');
    Assert.AreEqual<string>('9', msg.MsgData.AsString, 'MsgData');
  finally FreeAndNil(mq); end;
end;

procedure TestOmniMessageQueue.TestNewMessageEvent;
var
  evt: IOmniEvent;
  mq: TOmniMessageQueue;
  msg: TOmniMessage;

  procedure CheckEvent(state: boolean; const tag: string);
  begin
    Assert.AreEqual<boolean>(state, evt.WaitFor(0) = wrSignaled, tag);
  end;

begin
  mq := TOmniMessageQueue.Create(3, true);
  try
    evt := mq.GetNewMessageEvent;
    Assert.AreNotEqual<NativeUInt>(0, NativeUInt(evt), 'assigned event');
    CheckEvent(false, '#1');
    Assert.IsTrue(mq.Enqueue(TOmniMessage.Create(1, '1')));
    CheckEvent(true, '#2');
    CheckEvent(false, '#3');
    msg := mq.Dequeue;
    CheckEvent(false, '#4');
  finally FreeAndNil(mq); end;
end;

// Helper confines the temporary object produced by TLeakCheckObj.Create to
// its own scope. Without this the compiler keeps a hidden refcounted temp
// alive until the caller's procedure exits — the same Delphi quirk that
// drives TestBlockingCollection1.FillOmniValueWithOwnedObject.
procedure EnqueueOwnedLeakObj(mq: TOmniMessageQueue; msgID: integer);
var
  msg: TOmniMessage;
begin
  msg.MsgID := msgID;
  msg.MsgData.AsOwnedObject := TLeakCheckObj.Create;
  Assert.IsTrue(mq.Enqueue(msg),
    Format('EnqueueOwnedLeakObj: Enqueue #%d failed', [msgID]));
end;

procedure TestOmniMessageQueue.TestDestroyReleasesOwnedObjects;
// Regression: undelivered messages carrying AsOwnedObject payloads must be
// released when the queue is destroyed. Destroy calls Empty, which dequeues
// every remaining TOmniMessage; each MsgData's TOmniValue destructor then
// frees the owned object.
const
  CMsgCount = 3;
var
  i: integer;
begin
  GLeakCheckObjCount := 0;
  var mq := TOmniMessageQueue.Create(CMsgCount);
  try
    for i := 1 to CMsgCount do
      EnqueueOwnedLeakObj(mq, i);
    Assert.AreEqual<integer>(CMsgCount, GLeakCheckObjCount,
      'owned objects should be alive while queued');
  finally FreeAndNil(mq); end;
  Assert.AreEqual<integer>(0, GLeakCheckObjCount,
    'owned objects leaked after queue destroy');
end;

procedure TestOmniMessageQueue.TestEmptyReleasesOwnedObjects;
// Explicit Empty path: same invariant as destroy, but while the queue is
// still alive. Confirms Empty isn't only discarding slot ownership.
const
  CMsgCount = 3;
var
  i: integer;
begin
  GLeakCheckObjCount := 0;
  var mq := TOmniMessageQueue.Create(CMsgCount);
  try
    for i := 1 to CMsgCount do
      EnqueueOwnedLeakObj(mq, i);
    Assert.AreEqual<integer>(CMsgCount, GLeakCheckObjCount,
      'owned objects should be alive while queued');
    mq.Empty;
    Assert.AreEqual<integer>(0, GLeakCheckObjCount,
      'owned objects leaked after Empty');
  finally FreeAndNil(mq); end;
end;

{ TestIOmniTwoWayChannel }

procedure TestIOmniTwoWayChannel.TestSendReceive;
var
  chan: IOmniTwoWayChannel;

  procedure CheckReceive(success: boolean; const endpoint: IOmniCommunicationEndpoint;
    msgID: integer; const msgData: string; const tag: string);
  var
    msg: TOmniMessage;
  begin
    Assert.AreEqual<boolean>(success, endpoint.Receive(msg), tag + '.Receive');
    if success then begin
      Assert.AreEqual<integer>(msgID, msg.MsgID, tag + '.MsgID');
      Assert.AreEqual<string>(msgData, msg.MsgData.AsString, tag + '.MsgData');
    end;
  end;

begin
  chan := CreateTwoWayChannel(3, nil);

  chan.Endpoint1.Send(TOmniMessage.Create(1, '1'));
  CheckReceive(false, chan.Endpoint1, 0, '', '1');
  CheckReceive(true, chan.Endpoint2, 1, '1', '2');
  CheckReceive(false, chan.Endpoint2, 0, '', '3');

  chan.Endpoint2.Send(TOmniMessage.Create(2, '2'));
  CheckReceive(false, chan.Endpoint2, 0, '', '4');
  CheckReceive(true, chan.Endpoint1, 2, '2', '5');
  CheckReceive(false, chan.Endpoint1, 0, '', '6');
end;

procedure TestIOmniTwoWayChannel.TestOtherEndpoint;
var
  chan: IOmniTwoWayChannel;

  procedure CheckReceive(success: boolean; const endpoint: IOmniCommuniCationEndpoint;
    msgID: integer; const msgData: string; const tag: string);
  var
    msg: TOmniMessage;
  begin
    Assert.AreEqual<boolean>(success, endpoint.Receive(msg), tag + '.Receive');
    if success then begin
      Assert.AreEqual<integer>(msgID, msg.MsgID, tag + '.MsgID');
      Assert.AreEqual<string>(msgData, msg.MsgData.AsString, tag + '.MsgData');
    end;
  end;

begin
  chan := CreateTwoWayChannel(3, nil);

  chan.Endpoint1.Send(TOmniMessage.Create(1, '1'));
  CheckReceive(true, chan.Endpoint1.OtherEndpoint, 1, '1', '2');

  chan.Endpoint2.Send(TOmniMessage.Create(2, '2'));
  CheckReceive(true, chan.Endpoint2.OtherEndpoint, 2, '2', '5');
end;

procedure TestIOmniTwoWayChannel.TestWait;
var
  chan: IOmniTwoWayChannel;
  reader: IOmniCommunicationEndpoint;
  writer: IOmniCommunicationEndpoint;
  synch: IOmniSynchronizer<string>;
  readerTask: ITask;
  terminate: IOmniEvent;
  writerTask: ITask;
begin
  synch := TOmniSynchronizer<string>.Create;
  terminate := CreateOmniEvent(true, false);
  chan := CreateTwoWayChannel(3, terminate);
  reader:= chan.Endpoint1;
  writer := chan.Endpoint2;

  writerTask := System.Threading.TTask.Run(
    procedure
    begin
      synch.Signal('W');
      synch.WaitFor('start');
      synch.WaitFor('W:1');
      Assert.IsTrue(writer.SendWait(1, '1', 0));
      synch.WaitFor('W:2');
      Assert.IsTrue(writer.SendWait(21, '21', 0));
      Assert.IsTrue(writer.SendWait(22, '22', 0));
      Assert.IsTrue(writer.SendWait(23, '23', 0));
      Assert.IsFalse(writer.SendWait(24, '24', 0));
      synch.Signal('W:3');
      Assert.IsTrue(writer.SendWait(25, '25', 1000));
    end);

  readerTask := System.Threading.TTask.Run(
    procedure
    var
      i: integer;
      msg: TOmniMessage;
    begin
      synch.Signal('R');
      synch.WaitFor('start');
      Assert.IsFalse(reader.ReceiveWait(msg, 0), 'R:Receive.1');
      Assert.IsFalse(reader.ReceiveWait(msg, 100), 'R:Receive.2');
      synch.Signal('R:1');
      Assert.IsTrue(reader.ReceiveWait(msg, 3000), 'R:Receive.3');
      synch.Signal('R:2');
      Assert.AreEqual<integer>(1, msg.MsgID, 'R:MsgID.1');
      Assert.AreEqual<string>('1', msg.MsgData.AsString, 'R:MsgData.1');
      synch.WaitFor('W:3');
      for i := 1 to 3 do
        Assert.IsTrue(reader.ReceiveWait(msg, 500), 'R:Receive.4.' + i.ToString);
      Assert.IsTrue(reader.ReceiveWait(msg, 500), 'R:Receive.5');
      Assert.AreEqual<integer>(25, msg.MsgID, 'R:MsgID');
      Assert.AreEqual<string>('25', msg.MsgData.AsString, 'R:MsgData');
    end);

  synch.WaitFor('W');
  synch.WaitFor('R');
  synch.Signal('start');
  Assert.IsTrue(synch.WaitFor('R:1', 1000), 'WaitFor R:1');
  Sleep(100);
  synch.Signal('W:1');
  Assert.IsTrue(synch.WaitFor('R:2', 3000), 'WaitFor R:2');
  synch.Signal('W:2');

  try
    readerTask.Wait(5000);
  except
    on E: EAggregateException do
      Assert.Fail('Reader: ' + E.InnerExceptions[0].Message);
  end;
  try
    writerTask.Wait(5000);
  except
    on E: EAggregateException do
      Assert.Fail('Writer: ' + E.InnerExceptions[0].Message);
  end;
end;

{ TMessageCollector }

type
  // Collects OnMessage deliveries. TOmniMessageQueueMessageEvent is "of
  // object", so it needs a real instance to bind to (nested procedures /
  // anonymous methods don't have the right calling convention for it).
  TMessageCollector = class
  strict private
    FMsgIDs: TArray<integer>;
    FSender: TObject;
  public
    procedure HandleMessage(Sender: TObject; const msg: TOmniMessage);
    property MsgIDs: TArray<integer> read FMsgIDs;
    property Sender: TObject read FSender;
    function Count: integer;
  end;

procedure TMessageCollector.HandleMessage(Sender: TObject; const msg: TOmniMessage);
begin
  FSender := Sender;
  SetLength(FMsgIDs, Length(FMsgIDs) + 1);
  FMsgIDs[High(FMsgIDs)] := msg.MsgID;
end;

function TMessageCollector.Count: integer;
begin
  Result := Length(FMsgIDs);
end;

{ TestOmniMessageQueueOnMessage }

procedure TestOmniMessageQueueOnMessage.TestFiresOnEnqueue;
begin
  var collector := TMessageCollector.Create;
  try
    var mq := TOmniMessageQueue.Create(3);
    try
      mq.OnMessage := collector.HandleMessage;
      Assert.IsTrue(mq.Enqueue(TOmniMessage.Create(42, 'hello')));
      DrainBackgroundObservers;
      Assert.AreEqual<integer>(1, collector.Count, 'handler should have fired once');
      Assert.AreEqual<integer>(42, collector.MsgIDs[0], 'MsgID');
      Assert.IsTrue(collector.Sender = mq, 'Sender should be the queue itself');
      // OnMessage already dequeued the message
      var msg: TOmniMessage;
      Assert.IsFalse(mq.TryDequeue(msg), 'message should already be drained');
    finally FreeAndNil(mq); end;
  finally FreeAndNil(collector); end;
end;

procedure TestOmniMessageQueueOnMessage.TestDrainsAllQueuedMessagesInOrder;
begin
  var collector := TMessageCollector.Create;
  try
    var mq := TOmniMessageQueue.Create(5);
    try
      mq.OnMessage := collector.HandleMessage;
      // Multiple Enqueues before a single drain: Notify coalesces internally
      // (one APC queued, not three), but the handler drains the whole queue
      // in a loop, so all three must still be delivered, in FIFO order.
      Assert.IsTrue(mq.Enqueue(TOmniMessage.Create(1, '1')));
      Assert.IsTrue(mq.Enqueue(TOmniMessage.Create(2, '2')));
      Assert.IsTrue(mq.Enqueue(TOmniMessage.Create(3, '3')));
      DrainBackgroundObservers;
      Assert.AreEqual<integer>(3, collector.Count, 'all three messages should have been delivered');
      Assert.AreEqual<integer>(1, collector.MsgIDs[0], 'FIFO order #1');
      Assert.AreEqual<integer>(2, collector.MsgIDs[1], 'FIFO order #2');
      Assert.AreEqual<integer>(3, collector.MsgIDs[2], 'FIFO order #3');
    finally FreeAndNil(mq); end;
  finally FreeAndNil(collector); end;
end;

procedure TestOmniMessageQueueOnMessage.TestNotCalledBeforeDrain;
begin
  var collector := TMessageCollector.Create;
  try
    var mq := TOmniMessageQueue.Create(3);
    try
      mq.OnMessage := collector.HandleMessage;
      Assert.IsTrue(mq.Enqueue(TOmniMessage.Create(1, '1')));
      // No DrainBackgroundObservers call: delivery goes through a queued APC
      // (Windows) / pending flag (POSIX), not a synchronous call from Enqueue.
      Assert.AreEqual<integer>(0, collector.Count,
        'handler must not fire synchronously from Enqueue');
    finally FreeAndNil(mq); end;
  finally FreeAndNil(collector); end;
end;

procedure TestOmniMessageQueueOnMessage.TestNilDetaches;
begin
  var collector := TMessageCollector.Create;
  try
    var mq := TOmniMessageQueue.Create(3);
    try
      mq.OnMessage := collector.HandleMessage;
      mq.OnMessage := nil;
      Assert.IsTrue(mq.Enqueue(TOmniMessage.Create(1, '1')));
      DrainBackgroundObservers;
      Assert.AreEqual<integer>(0, collector.Count, 'detached handler must not fire');
      // Message is still there — nobody drained it
      var msg: TOmniMessage;
      Assert.IsTrue(mq.TryDequeue(msg), 'message should still be queued');
      Assert.AreEqual<integer>(1, msg.MsgID);
    finally FreeAndNil(mq); end;
  finally FreeAndNil(collector); end;
end;

procedure TestOmniMessageQueueOnMessage.TestDestroyWithActiveHandlerDoesNotRaise;
// Regression: Destroy must detach OnMessage (observer := nil) before tearing
// down the queue underneath it. Destroy does `OnMessage := nil` first for
// exactly this reason - this test just confirms it doesn't raise/AV even
// with a message still pending and undelivered.
begin
  var collector := TMessageCollector.Create;
  try
    var mq := TOmniMessageQueue.Create(3);
    mq.OnMessage := collector.HandleMessage;
    Assert.IsTrue(mq.Enqueue(TOmniMessage.Create(1, '1')));
    FreeAndNil(mq); // must not raise
  finally FreeAndNil(collector); end;
end;

{ TestOmniMessageQueueSize1 }

procedure TestOmniMessageQueueSize1.TestSize1Queue;
var
  msg: TOmniMessage;
begin
  var mq := TOmniMessageQueue.Create(1);
  try
    // Empty dequeue fails
    Assert.IsFalse(mq.TryDequeue(msg), 'Empty dequeue');

    // Enqueue 1 succeeds
    Assert.IsTrue(mq.Enqueue(TOmniMessage.Create(1, 'first')), 'Enqueue.1');

    // Second enqueue fails (full)
    Assert.IsFalse(mq.Enqueue(TOmniMessage.Create(2, 'second')), 'Enqueue.2');

    // Dequeue succeeds
    Assert.IsTrue(mq.TryDequeue(msg), 'Dequeue.1');
    Assert.AreEqual<integer>(1, msg.MsgID);
    Assert.AreEqual<string>('first', msg.MsgData.AsString);

    // Empty again
    Assert.IsFalse(mq.TryDequeue(msg), 'Dequeue.2');
  finally FreeAndNil(mq); end;
end;

{ TestIOmniTwoWayChannel - additional tests }

procedure TestIOmniTwoWayChannel.TestFIFOOrder;
var
  msg: TOmniMessage;
begin
  var chan := CreateTwoWayChannel(10, nil);

  // Send multiple messages
  chan.Endpoint1.Send(TOmniMessage.Create(1, 'a'));
  chan.Endpoint1.Send(TOmniMessage.Create(2, 'b'));
  chan.Endpoint1.Send(TOmniMessage.Create(3, 'c'));

  // Receive in FIFO order
  Assert.IsTrue(chan.Endpoint2.Receive(msg), 'Receive.1');
  Assert.AreEqual<integer>(1, msg.MsgID);
  Assert.IsTrue(chan.Endpoint2.Receive(msg), 'Receive.2');
  Assert.AreEqual<integer>(2, msg.MsgID);
  Assert.IsTrue(chan.Endpoint2.Receive(msg), 'Receive.3');
  Assert.AreEqual<integer>(3, msg.MsgID);
  Assert.IsFalse(chan.Endpoint2.Receive(msg), 'Receive.4');
end;

{ TestIOmniMessageQueueTee }

procedure TestIOmniMessageQueueTee.TestBasicTee;
var
  msg1, msg2: TOmniMessage;
begin
  var tee := TOmniMessageQueueTee.Create;
  var q1 := TOmniMessageQueue.Create(3);
  var q2 := TOmniMessageQueue.Create(3);
  try
    tee.Attach(q1);
    tee.Attach(q2);

    // Enqueue via tee — both queues should receive copy
    Assert.IsTrue(tee.Enqueue(TOmniMessage.Create(42, 'hello')));

    Assert.IsTrue(q1.TryDequeue(msg1), 'q1.Dequeue');
    Assert.AreEqual<integer>(42, msg1.MsgID, 'q1.MsgID');
    Assert.AreEqual<string>('hello', msg1.MsgData.AsString, 'q1.MsgData');

    Assert.IsTrue(q2.TryDequeue(msg2), 'q2.Dequeue');
    Assert.AreEqual<integer>(42, msg2.MsgID, 'q2.MsgID');
    Assert.AreEqual<string>('hello', msg2.MsgData.AsString, 'q2.MsgData');

    tee.Detach(q1);
    tee.Detach(q2);
  finally
    FreeAndNil(q2);
    FreeAndNil(q1);
    // tee is ref-counted (TInterfacedObject)
  end;
end;

end.
