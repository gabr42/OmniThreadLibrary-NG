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
  end;

  [TestFixture]
  TestOmniMessageQueueSize1 = class(TOtlTestBase)
  public
    [Test]
    procedure TestSize1Queue;
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
  OtlSync, OtlSync.Utils,
  OtlCommon, OtlComm;

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
