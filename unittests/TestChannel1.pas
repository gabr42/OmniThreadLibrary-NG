unit TestChannel1;

interface

uses
  DUnitX.TestFramework,
  TestOtlBase;

type
  [TestFixture]
  TestParallelChannel = class(TOtlTestBase)
  public
    [Test] procedure TestBasicSendReceive;
    [Test] procedure TestTryReceiveEmpty;
    [Test] procedure TestTrySendTryReceive;
    [Test] procedure TestCloseAndIsClosed;
    [Test] procedure TestReceiveAfterClose;
    [Test] procedure TestReceiveRaisesWhenClosed;
    [Test] procedure TestForInEnumerator;
    [Test] procedure TestCountAndIsEmpty;
    [Test] procedure TestCapacityBlocking;
    [Test] procedure TestCrossThreadProducerConsumer;
    [Test] procedure TestFanOutMultipleConsumers;
    [Test] procedure TestStringChannel;
    [Test] procedure TestRecordChannel;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Threading,
  System.SyncObjs,
  OtlParallel,
  OtlSync;

type
  TPoint2D = record
    X, Y: integer;
  end;

{ TestParallelChannel }

procedure TestParallelChannel.TestBasicSendReceive;
begin
  var ch := Parallel.Channel<integer>;
  ch.Sender.Send(42);
  Assert.AreEqual<integer>(42, ch.Receiver.Receive);
end;

procedure TestParallelChannel.TestTryReceiveEmpty;
begin
  var ch := Parallel.Channel<integer>;
  var value: integer;
  Assert.IsFalse(ch.Receiver.TryReceive(value, 0));
end;

procedure TestParallelChannel.TestTrySendTryReceive;
begin
  var ch := Parallel.Channel<integer>(4);
  Assert.IsTrue(ch.Sender.TrySend(10));
  Assert.IsTrue(ch.Sender.TrySend(20));

  var value: integer;
  Assert.IsTrue(ch.Receiver.TryReceive(value, 0));
  Assert.AreEqual<integer>(10, value);
  Assert.IsTrue(ch.Receiver.TryReceive(value, 0));
  Assert.AreEqual<integer>(20, value);
  Assert.IsFalse(ch.Receiver.TryReceive(value, 0));
end;

procedure TestParallelChannel.TestCloseAndIsClosed;
begin
  var ch := Parallel.Channel<integer>;
  Assert.IsFalse(ch.Sender.IsClosed);
  Assert.IsFalse(ch.Receiver.IsClosed);
  ch.Close;
  Assert.IsTrue(ch.Sender.IsClosed);
  Assert.IsTrue(ch.Receiver.IsClosed);
end;

procedure TestParallelChannel.TestReceiveAfterClose;
begin
  var ch := Parallel.Channel<integer>;
  ch.Sender.Send(1);
  ch.Sender.Send(2);
  ch.Close;
  // Can still receive items that were sent before close
  Assert.AreEqual<integer>(1, ch.Receiver.Receive);
  Assert.AreEqual<integer>(2, ch.Receiver.Receive);
end;

procedure TestParallelChannel.TestReceiveRaisesWhenClosed;
begin
  var ch := Parallel.Channel<integer>;
  ch.Close;
  Assert.WillRaise(
    procedure begin ch.Receiver.Receive; end);
end;

procedure TestParallelChannel.TestForInEnumerator;
begin
  var ch := Parallel.Channel<integer>;
  ch.Sender.Send(10);
  ch.Sender.Send(20);
  ch.Sender.Send(30);
  ch.Close;

  var sum := 0;
  var count := 0;
  var value: integer;
  while ch.Receiver.TryReceive(value, INFINITE) do begin
    sum := sum + value;
    Inc(count);
  end;
  Assert.AreEqual<integer>(3, count);
  Assert.AreEqual<integer>(60, sum);
end;

procedure TestParallelChannel.TestCountAndIsEmpty;
begin
  var ch := Parallel.Channel<integer>;
  Assert.IsTrue(ch.Receiver.IsEmpty);
  Assert.AreEqual<integer>(0, ch.Receiver.Count);
  ch.Sender.Send(1);
  ch.Sender.Send(2);
  Assert.IsFalse(ch.Receiver.IsEmpty);
  Assert.AreEqual<integer>(2, ch.Receiver.Count);
end;

procedure TestParallelChannel.TestCapacityBlocking;
begin
  // Channel of capacity 2 — third send should block
  var ch := Parallel.Channel<integer>(2);
  Assert.IsTrue(ch.Sender.TrySend(1));
  Assert.IsTrue(ch.Sender.TrySend(2));
  // Channel is full — TrySend with 0 timeout should fail
  Assert.IsFalse(ch.Sender.TrySend(3, 0));

  // Consume one — now there's room
  ch.Receiver.Receive;
  Assert.IsTrue(ch.Sender.TrySend(3));
end;

procedure TestParallelChannel.TestCrossThreadProducerConsumer;
begin
  var ch := Parallel.Channel<integer>;

  const CCount = 1000;

  TTask.Run(
    procedure
    var i: integer;
    begin
      for i := 1 to CCount do
        ch.Sender.Send(i);
      ch.Close;
    end);

  var sum := 0;
  var value: integer;
  while ch.Receiver.TryReceive(value, INFINITE) do
    sum := sum + value;

  Assert.AreEqual<integer>(CCount * (CCount + 1) div 2, sum);
end;

procedure TestParallelChannel.TestFanOutMultipleConsumers;
begin
  var ch := Parallel.Channel<integer>(64);
  const CCount = 100;
  var totalReceived: integer := 0;

  var recv := ch.Receiver;
  var send := ch.Sender;

  // Two consumer tasks
  var t1 := System.Threading.TTask.Run(
    procedure
    var value: integer;
    begin
      while recv.TryReceive(value, INFINITE) do
        TInterlocked.Increment(totalReceived);
    end);

  var t2 := System.Threading.TTask.Run(
    procedure
    var value: integer;
    begin
      while recv.TryReceive(value, INFINITE) do
        TInterlocked.Increment(totalReceived);
    end);

  // Producer
  for var i := 1 to CCount do
    send.Send(i);
  ch.Close;

  t1.Wait(5000);
  t2.Wait(5000);
  Assert.AreEqual<integer>(CCount, totalReceived);
end;

procedure TestParallelChannel.TestStringChannel;
begin
  var ch := Parallel.Channel<string>;
  ch.Sender.Send('hello');
  ch.Sender.Send('world');
  Assert.AreEqual<string>('hello', ch.Receiver.Receive);
  Assert.AreEqual<string>('world', ch.Receiver.Receive);
end;

procedure TestParallelChannel.TestRecordChannel;
begin
  var ch := Parallel.Channel<TPoint2D>;
  var p: TPoint2D;
  p.X := 10;
  p.Y := 20;
  ch.Sender.Send(p);

  var p2 := ch.Receiver.Receive;
  Assert.AreEqual<integer>(10, p2.X);
  Assert.AreEqual<integer>(20, p2.Y);
end;

end.
