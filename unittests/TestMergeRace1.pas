unit TestMergeRace1;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TestParallelMerge = class
  public
    [Test] procedure TestMergeTwoChannels;
    [Test] procedure TestMergePreservesAllValues;
    [Test] procedure TestMergeClosesOnAllInputsClosed;
    [Test] procedure TestMergeSingleChannel;
    [Test] procedure TestMergeStringChannels;
  end;

  [TestFixture]
  TestParallelRace = class
  public
    [Test] procedure TestRaceReturnsFirst;
    [Test] procedure TestRaceWithTimeout;
    [Test] procedure TestTryRaceSuccess;
    [Test] procedure TestTryRaceTimeout;
    [Test] procedure TestTryRaceAllClosed;
    [Test] procedure TestRaceRaisesOnAllClosed;
    [Test] procedure TestRaceCrossThread;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Threading,
  System.Generics.Collections,
  OtlParallel,
  OtlCollections;

{ TestParallelMerge }

procedure TestParallelMerge.TestMergeTwoChannels;
var
  count: integer;
  value: integer;
begin
  var ch1 := Parallel.Channel<integer>;
  var ch2 := Parallel.Channel<integer>;

  ch1.Sender.Send(1);
  ch1.Sender.Send(2);
  ch2.Sender.Send(3);
  ch1.Close;
  ch2.Close;

  var merged := Parallel.Merge<integer>([ch1.Receiver, ch2.Receiver]);
  count := 0;
  while merged.TryReceive(value, 5000) do
    Inc(count);

  Assert.AreEqual<integer>(3, count);
end;

procedure TestParallelMerge.TestMergePreservesAllValues;
var
  received: TList<integer>;
  value   : integer;
begin
  var ch1 := Parallel.Channel<integer>;
  var ch2 := Parallel.Channel<integer>;

  for var i := 1 to 50 do
    ch1.Sender.Send(i);
  for var i := 51 to 100 do
    ch2.Sender.Send(i);
  ch1.Close;
  ch2.Close;

  var merged := Parallel.Merge<integer>([ch1.Receiver, ch2.Receiver]);
  received := TList<integer>.Create;
  try
    while merged.TryReceive(value, 5000) do
      received.Add(value);
    Assert.AreEqual<integer>(100, received.Count);

    // Verify all values present (sort and check)
    received.Sort;
    for var i := 0 to 99 do
      Assert.AreEqual<integer>(i + 1, received[i]);
  finally
    received.Free;
  end;
end;

procedure TestParallelMerge.TestMergeClosesOnAllInputsClosed;
var
  value: integer;
begin
  var ch1 := Parallel.Channel<integer>;
  var ch2 := Parallel.Channel<integer>;
  var merged := Parallel.Merge<integer>([ch1.Receiver, ch2.Receiver]);

  ch1.Sender.Send(1);
  ch1.Close;
  ch2.Close;

  // Should receive the one value then close
  Assert.IsTrue(merged.TryReceive(value, 5000));
  Assert.AreEqual<integer>(1, value);
  Assert.IsFalse(merged.TryReceive(value, 2000));
end;

procedure TestParallelMerge.TestMergeSingleChannel;
var
  value: integer;
begin
  var ch := Parallel.Channel<integer>;
  ch.Sender.Send(42);
  ch.Close;

  var merged := Parallel.Merge<integer>([ch.Receiver]);
  Assert.IsTrue(merged.TryReceive(value, 5000));
  Assert.AreEqual<integer>(42, value);
  Assert.IsFalse(merged.TryReceive(value, 1000));
end;

procedure TestParallelMerge.TestMergeStringChannels;
var
  value: string;
begin
  var ch1 := Parallel.Channel<string>;
  var ch2 := Parallel.Channel<string>;
  ch1.Sender.Send('hello');
  ch2.Sender.Send('world');
  ch1.Close;
  ch2.Close;

  var merged := Parallel.Merge<string>([ch1.Receiver, ch2.Receiver]);
  var count := 0;
  while merged.TryReceive(value, 5000) do
    Inc(count);
  Assert.AreEqual<integer>(2, count);
end;

{ TestParallelRace }

procedure TestParallelRace.TestRaceReturnsFirst;
begin
  var ch1 := Parallel.Channel<integer>;
  var ch2 := Parallel.Channel<integer>;
  ch2.Sender.Send(99);

  var value := Parallel.Race<integer>([ch1.Receiver, ch2.Receiver], 5000);
  Assert.AreEqual<integer>(99, value);
end;

procedure TestParallelRace.TestRaceWithTimeout;
begin
  var ch1 := Parallel.Channel<integer>;
  var ch2 := Parallel.Channel<integer>;

  Assert.WillRaise(
    procedure
    begin
      Parallel.Race<integer>([ch1.Receiver, ch2.Receiver], 50);
    end,
    ESelectTimeout);
end;

procedure TestParallelRace.TestTryRaceSuccess;
var
  value: integer;
begin
  var ch1 := Parallel.Channel<integer>;
  var ch2 := Parallel.Channel<integer>;
  ch1.Sender.Send(42);

  Assert.IsTrue(Parallel.TryRace<integer>([ch1.Receiver, ch2.Receiver], value, 5000));
  Assert.AreEqual<integer>(42, value);
end;

procedure TestParallelRace.TestTryRaceTimeout;
var
  value: integer;
begin
  var ch := Parallel.Channel<integer>;
  Assert.IsFalse(Parallel.TryRace<integer>([ch.Receiver], value, 50));
end;

procedure TestParallelRace.TestTryRaceAllClosed;
var
  value: integer;
begin
  var ch1 := Parallel.Channel<integer>;
  var ch2 := Parallel.Channel<integer>;
  ch1.Close;
  ch2.Close;

  Assert.IsFalse(Parallel.TryRace<integer>([ch1.Receiver, ch2.Receiver], value, 1000));
end;

procedure TestParallelRace.TestRaceRaisesOnAllClosed;
begin
  var ch := Parallel.Channel<integer>;
  ch.Close;

  Assert.WillRaise(
    procedure
    begin
      Parallel.Race<integer>([ch.Receiver], 1000);
    end,
    ESelectTimeout);
end;

procedure TestParallelRace.TestRaceCrossThread;
begin
  var ch1 := Parallel.Channel<integer>;
  var ch2 := Parallel.Channel<integer>;

  TTask.Run(
    procedure
    begin
      Sleep(50);
      ch1.Sender.Send(123);
    end);

  var value := Parallel.Race<integer>([ch1.Receiver, ch2.Receiver], 5000);
  Assert.AreEqual<integer>(123, value);
end;

end.
