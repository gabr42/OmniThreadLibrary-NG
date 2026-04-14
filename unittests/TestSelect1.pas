unit TestSelect1;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TestParallelSelect = class
  public
    [Test] procedure TestBasicReceive;
    [Test] procedure TestDefaultWhenEmpty;
    [Test] procedure TestDefaultNotFiredWhenDataReady;
    [Test] procedure TestMultipleChannels;
    [Test] procedure TestRoundRobin;
    [Test] procedure TestAllClosedResult;
    [Test] procedure TestTimeoutResult;
    [Test] procedure TestSelectLoop;
    [Test] procedure TestFanIn;
    [Test] procedure TestSelectWithCrossThread;
    [Test] procedure TestSelectNoMissedWakeup;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Threading,
  OtlParallel;

procedure TestParallelSelect.TestBasicReceive;
var
  received: integer;
begin
  var ch := Parallel.Channel<integer>;
  ch.Sender.Send(42);

  received := 0;
  var sel := Parallel.Select([
    SelectCase.Receive<integer>(ch.Receiver,
      procedure(v: integer) begin received := v end)
  ]);
  var result := sel.Wait(1000);
  Assert.AreEqual<integer>(42, received);
  Assert.IsTrue(result = srHandled);
end;

procedure TestParallelSelect.TestDefaultWhenEmpty;
var
  defaultFired: boolean;
begin
  var ch := Parallel.Channel<integer>;
  defaultFired := false;

  var result := Parallel.Select([
    SelectCase.Receive<integer>(ch.Receiver,
      procedure(v: integer) begin end),
    SelectCase.Default(
      procedure begin defaultFired := true end)
  ]).Wait;

  Assert.IsTrue(defaultFired);
  Assert.IsTrue(result = srDefault);
end;

procedure TestParallelSelect.TestDefaultNotFiredWhenDataReady;
var
  received: integer;
  defaultFired: boolean;
begin
  var ch := Parallel.Channel<integer>;
  ch.Sender.Send(99);
  received := 0;
  defaultFired := false;

  var result := Parallel.Select([
    SelectCase.Receive<integer>(ch.Receiver,
      procedure(v: integer) begin received := v end),
    SelectCase.Default(
      procedure begin defaultFired := true end)
  ]).Wait;

  Assert.AreEqual<integer>(99, received);
  Assert.IsFalse(defaultFired);
  Assert.IsTrue(result = srHandled);
end;

procedure TestParallelSelect.TestMultipleChannels;
var
  source: string;
begin
  var ch1 := Parallel.Channel<integer>;
  var ch2 := Parallel.Channel<string>;
  ch2.Sender.Send('hello');
  source := '';

  var result := Parallel.Select([
    SelectCase.Receive<integer>(ch1.Receiver,
      procedure(v: integer) begin source := 'ch1' end),
    SelectCase.Receive<string>(ch2.Receiver,
      procedure(v: string) begin source := 'ch2:' + v end)
  ]).Wait(1000);

  Assert.AreEqual<string>('ch2:hello', source);
  Assert.IsTrue(result = srHandled);
end;

procedure TestParallelSelect.TestRoundRobin;
var
  counts: array[0..1] of integer;
begin
  var ch1 := Parallel.Channel<integer>;
  var ch2 := Parallel.Channel<integer>;
  counts[0] := 0;
  counts[1] := 0;

  // Put data in both channels
  for var i := 1 to 10 do begin
    ch1.Sender.Send(i);
    ch2.Sender.Send(i);
  end;

  var sel := Parallel.Select([
    SelectCase.Receive<integer>(ch1.Receiver,
      procedure(v: integer) begin Inc(counts[0]) end),
    SelectCase.Receive<integer>(ch2.Receiver,
      procedure(v: integer) begin Inc(counts[1]) end)
  ]);

  // Execute 20 waits — round-robin should distribute across both channels
  for var i := 1 to 20 do
    sel.Wait(1000);

  Assert.AreEqual<integer>(10, counts[0], 'ch1 count');
  Assert.AreEqual<integer>(10, counts[1], 'ch2 count');
end;

procedure TestParallelSelect.TestAllClosedResult;
begin
  var ch := Parallel.Channel<integer>;
  ch.Sender.Send(1);
  ch.Close;

  var sel := Parallel.Select([
    SelectCase.Receive<integer>(ch.Receiver,
      procedure(v: integer) begin end)
  ]);

  // First wait should consume the item
  Assert.IsTrue(sel.Wait(1000) = srHandled);
  // Second wait — channel is closed and drained
  Assert.IsTrue(sel.Wait(1000) = srAllClosed);
end;

procedure TestParallelSelect.TestTimeoutResult;
begin
  var ch := Parallel.Channel<integer>;
  var result := Parallel.Select([
    SelectCase.Receive<integer>(ch.Receiver,
      procedure(v: integer) begin end)
  ]).Wait(50);

  Assert.IsTrue(result = srTimeout);
end;

procedure TestParallelSelect.TestSelectLoop;
var
  sum: integer;
begin
  var ch := Parallel.Channel<integer>;
  for var i := 1 to 5 do
    ch.Sender.Send(i * 10);
  ch.Close;

  sum := 0;
  var sel := Parallel.Select([
    SelectCase.Receive<integer>(ch.Receiver,
      procedure(v: integer) begin sum := sum + v end)
  ]);

  while sel.Wait(1000) = srHandled do
    ;

  Assert.AreEqual<integer>(150, sum);
end;

procedure TestParallelSelect.TestFanIn;
var
  sum: integer;
begin
  var ch1 := Parallel.Channel<integer>;
  var ch2 := Parallel.Channel<integer>;
  var output := Parallel.Channel<integer>;

  // Two producers
  TTask.Run(
    procedure
    begin
      for var i := 1 to 50 do
        ch1.Sender.Send(i);
      ch1.Close;
    end);

  TTask.Run(
    procedure
    begin
      for var i := 51 to 100 do
        ch2.Sender.Send(i);
      ch2.Close;
    end);

  // Fan-in select loop in a thread
  var fanIn := TTask.Run(
    procedure
    var
      sel: IOmniSelect;
    begin
      sel := Parallel.Select([
        SelectCase.Receive<integer>(ch1.Receiver,
          procedure(v: integer) begin output.Sender.Send(v) end),
        SelectCase.Receive<integer>(ch2.Receiver,
          procedure(v: integer) begin output.Sender.Send(v) end)
      ]);
      while sel.Wait(5000) <> srAllClosed do
        ;
      output.Close;
    end);

  // Consumer
  sum := 0;
  var value: integer;
  while output.Receiver.TryReceive(value, 5000) do
    sum := sum + value;

  fanIn.Wait(5000);
  Assert.AreEqual<integer>(5050, sum);
end;

procedure TestParallelSelect.TestSelectWithCrossThread;
var
  received: integer;
begin
  var ch := Parallel.Channel<integer>;
  received := 0;

  // Producer in another thread sends after a delay
  TTask.Run(
    procedure
    begin
      Sleep(50);
      ch.Sender.Send(123);
    end);

  // Select should block until data arrives
  var result := Parallel.Select([
    SelectCase.Receive<integer>(ch.Receiver,
      procedure(v: integer) begin received := v end)
  ]).Wait(5000);

  Assert.AreEqual<integer>(123, received);
  Assert.IsTrue(result = srHandled);
end;

procedure TestParallelSelect.TestSelectNoMissedWakeup;
// Stress test: producer sends immediately after select starts waiting.
// With the condvar-based notifier, there's a window between the poll
// and the wait where a signal can be lost. This test catches that by
// running many iterations with tight timing.
const
  CIterations = 200;
var
  count: integer;
begin
  count := 0;
  for var iteration := 1 to CIterations do begin
    var ch := Parallel.Channel<integer>;
    var received := false;

    // Producer sends with minimal delay — maximizes chance of hitting
    // the window between poll and wait
    TTask.Run(
      procedure
      begin
        ch.Sender.Send(iteration);
      end);

    var sel := Parallel.Select([
      SelectCase.Receive<integer>(ch.Receiver,
        procedure(v: integer) begin received := true end)
    ]);

    // Use a finite timeout so we don't hang on missed wakeup
    var result := sel.Wait(500);
    if (result = srHandled) and received then
      Inc(count);
  end;

  // All iterations must succeed — even one miss indicates a wakeup bug
  Assert.AreEqual<integer>(CIterations, count,
    'Missed wakeup detected: not all Select.Wait calls received data');
end;

end.
