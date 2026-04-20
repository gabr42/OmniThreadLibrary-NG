/// Basic stack/queue container tests.
/// Serious testing is done as a part of the stress test.

unit TestContainers;

interface

uses
  DUnitX.TestFramework,
  TestOtlBase;

type
  [TestFixture]
  TTestContainers = class(TOtlTestBase)
  public
    [Test]
    procedure TestBasicQueue;
    [Test]
    procedure TestBasicStack;
    [Test]
    procedure TestOneElementQueue;
    [Test]
    procedure TestOneElementStack;
    [Test]
    procedure TestQueueObserverNotification;
    [Test]
    procedure TestStackObserverNotification;
    [Test]
    procedure TestBoundedQueueLargeCapacity;
    [Test]
    procedure TestBoundedStackLargeCapacity;
    [Test]
    procedure TestBoundedQueueMPMC;
    [Test]
    procedure TestBoundedStackMPMC;
  end;

implementation

uses
  System.Classes, System.SysUtils, System.SyncObjs,
  OtlContainers, OtlContainerObserver, OtlSync;

// Helper functions for MPMC stress tests. Parameters are passed by value so
// each returned closure captures fresh per-iteration state (see CLAUDE.md on
// Delphi's for-loop closure-capture trap).
type
  TContainerProducer = reference to function(value: integer): boolean;
  TContainerConsumer = reference to function(var value: integer): boolean;

function MakeProducer(gate: IOmniEvent; startValue, endValue: integer;
  const produce: TContainerProducer; producedCounter: PInteger): TProc;
begin
  Result :=
    procedure
    var i: integer;
    begin
      gate.WaitFor(INFINITE);
      for i := startValue to endValue do
        while not produce(i) do
          TThread.Yield;
      TInterlocked.Add(producedCounter^, endValue - startValue + 1);
    end;
end;

function MakeConsumer(gate, doneProducing: IOmniEvent;
  const consume: TContainerConsumer;
  consumedCounter, consumedSum: PInteger): TProc;
begin
  Result :=
    procedure
    var
      value: integer;
      done : boolean;
    begin
      gate.WaitFor(INFINITE);
      done := false;
      while not done do begin
        if consume(value) then begin
          TInterlocked.Increment(consumedCounter^);
          TInterlocked.Add(consumedSum^, value);
        end
        else if doneProducing.WaitFor(0) = wrSignaled then begin
          // Producers finished. Drain once more to catch items enqueued
          // before the event was set but not yet visible at our first probe.
          while consume(value) do begin
            TInterlocked.Increment(consumedCounter^);
            TInterlocked.Add(consumedSum^, value);
          end;
          done := true;
        end
        else
          TThread.Yield;
      end;
    end;
end;

{ TestContainers }

procedure TTestContainers.TestBasicQueue;
var
  queue: TOmniBaseBoundedQueue;
  test : integer;
  value: integer;

  procedure Verify(isEmpty, isFull: boolean; tag: string);
  begin
    Assert.AreEqual(isEmpty, queue.IsEmpty, tag + '.Empty');
    Assert.AreEqual(isFull, queue.IsFull, tag + '.Full');
  end;

begin
  queue := TOmniBaseBoundedQueue.Create;
  try
    queue.Initialize(4, SizeOf(integer));
    Assert.AreEqual(SizeOf(integer), queue.ElementSize, 'ElementSize.1');
    Assert.AreEqual(4, queue.NumElements, 'NumElements.1');
    Verify(true, false, '#1');

    value := 1;
    Assert.IsTrue(queue.Enqueue(value), 'Enqueue.2');
    Verify(false, false, '#2');

    Assert.IsTrue(queue.Dequeue(value), 'Dequeue.3');
    Assert.AreEqual(1, value, 'value.3');
    Verify(true, false, '#3');

    Assert.IsFalse(queue.Dequeue(value), 'Dequeue.4');
    Verify(true, false, '#4');

    value := 1;
    Assert.IsTrue(queue.Enqueue(value), 'Enqueue.5');
    queue.Empty;
    Verify(true, false, '#5');

    for value := 1 to 4 do begin
      Assert.IsTrue(queue.Enqueue(value), 'Enqueue.6.' + value.ToString);
      Verify(false, value = 4, '#6.' + value.ToString);
    end;

    Assert.IsFalse(queue.Enqueue(value), 'Enqueue.7');
    Verify(false, true, '#7');

    for test := 1 to 4 do begin
      Assert.IsTrue(queue.Dequeue(value), 'Dequeue.8.' + test.ToString);
      Assert.AreEqual(test, value, 'value.8.' + test.ToString);
      Verify(test = 4, false, '#8.' + test.ToString);
    end;
  finally FreeAndNil(queue); end;
end;

procedure TTestContainers.TestBasicStack;
var
  stack: TOmniBaseBoundedStack;
  test : integer;
  value: integer;

  procedure Verify(isEmpty, isFull: boolean; tag: string);
  begin
    Assert.AreEqual(isEmpty, stack.IsEmpty, tag + '.Empty');
    Assert.AreEqual(isFull, stack.IsFull, tag + '.Full');
  end;

begin
  stack := TOmniBaseBoundedStack.Create;
  try
    stack.Initialize(4, SizeOf(integer));
    Assert.AreEqual(SizeOf(integer), stack.ElementSize, 'ElementSize.1');
    Assert.AreEqual(4, stack.NumElements, 'NumElements.1');
    Verify(true, false, '#1');

    value := 1;
    Assert.IsTrue(stack.Push(value), 'Push.2');
    Verify(false, false, '#2');

    Assert.IsTrue(stack.Pop(value), 'Pop.3');
    Assert.AreEqual(1, value, 'value.3');
    Verify(true, false, '#3');

    Assert.IsFalse(stack.Pop(value), 'Pop.4');
    Verify(true, false, '#4');

    value := 1;
    Assert.IsTrue(stack.Push(value), 'Push.5');
    stack.Empty;
    Verify(true, false, '#5');

    for value := 1 to 4 do begin
      Assert.IsTrue(stack.Push(value), 'Push.6.' + value.ToString);
      Verify(false, value = 4, '#6.' + value.ToString);
    end;

    Assert.IsFalse(stack.Push(value), 'Push.7');
    Verify(false, true, '#7');

    for test := 4 downto 1 do begin
      Assert.IsTrue(stack.Pop(value), 'Pop.8.' + test.ToString);
      Assert.AreEqual(test, value, 'value.8.' + test.ToString);
      Verify(test = 1, false, '#8.' + test.ToString);
    end;
  finally FreeAndNil(stack); end;
end;

procedure TTestContainers.TestOneElementQueue;
var
  value: integer;
begin
  var queue := TOmniBaseBoundedQueue.Create;
  try
    queue.Initialize(1, SizeOf(integer));
    Assert.IsTrue(queue.IsEmpty);
    Assert.IsFalse(queue.IsFull);

    value := 42;
    Assert.IsTrue(queue.Enqueue(value), 'Enqueue first');
    Assert.IsFalse(queue.IsEmpty);
    Assert.IsTrue(queue.IsFull);

    // Second enqueue should fail
    value := 99;
    Assert.IsFalse(queue.Enqueue(value), 'Enqueue second');

    Assert.IsTrue(queue.Dequeue(value), 'Dequeue');
    Assert.AreEqual(42, value);
    Assert.IsTrue(queue.IsEmpty);
  finally FreeAndNil(queue); end;
end;

procedure TTestContainers.TestOneElementStack;
var
  value: integer;
begin
  var stack := TOmniBaseBoundedStack.Create;
  try
    stack.Initialize(1, SizeOf(integer));
    Assert.IsTrue(stack.IsEmpty);
    Assert.IsFalse(stack.IsFull);

    value := 42;
    Assert.IsTrue(stack.Push(value), 'Push first');
    Assert.IsFalse(stack.IsEmpty);
    Assert.IsTrue(stack.IsFull);

    // Second push should fail
    value := 99;
    Assert.IsFalse(stack.Push(value), 'Push second');

    Assert.IsTrue(stack.Pop(value), 'Pop');
    Assert.AreEqual(42, value);
    Assert.IsTrue(stack.IsEmpty);
  finally FreeAndNil(stack); end;
end;

procedure TTestContainers.TestBoundedQueueLargeCapacity;
// Fill a queue to a large capacity and drain it, asserting FIFO order.
// Exercises the queue's internal slot-addressing at scale.
const
  CCapacity = 65536;
var
  queue: TOmniBaseBoundedQueue;
  i    : integer;
  value: integer;
begin
  queue := TOmniBaseBoundedQueue.Create;
  try
    queue.Initialize(CCapacity, SizeOf(integer));
    Assert.IsTrue(queue.IsEmpty, 'Queue should start empty');
    for i := 1 to CCapacity do
      Assert.IsTrue(queue.Enqueue(i), Format('Enqueue #%d failed', [i]));
    Assert.IsTrue(queue.IsFull, 'Queue should be full at capacity');
    value := -1;
    Assert.IsFalse(queue.Enqueue(value), 'Enqueue past capacity should fail');
    for i := 1 to CCapacity do begin
      Assert.IsTrue(queue.Dequeue(value), Format('Dequeue #%d failed', [i]));
      Assert.AreEqual(i, value, Format('FIFO violation at element %d', [i]));
    end;
    Assert.IsTrue(queue.IsEmpty, 'Queue should be empty after drain');
  finally FreeAndNil(queue); end;
end;

procedure TTestContainers.TestBoundedStackLargeCapacity;
// Fill a stack to a large capacity and drain it, asserting LIFO order.
const
  CCapacity = 65536;
var
  stack: TOmniBaseBoundedStack;
  i    : integer;
  value: integer;
begin
  stack := TOmniBaseBoundedStack.Create;
  try
    stack.Initialize(CCapacity, SizeOf(integer));
    Assert.IsTrue(stack.IsEmpty, 'Stack should start empty');
    for i := 1 to CCapacity do
      Assert.IsTrue(stack.Push(i), Format('Push #%d failed', [i]));
    Assert.IsTrue(stack.IsFull, 'Stack should be full at capacity');
    value := -1;
    Assert.IsFalse(stack.Push(value), 'Push past capacity should fail');
    for i := CCapacity downto 1 do begin
      Assert.IsTrue(stack.Pop(value), Format('Pop failed at element %d', [i]));
      Assert.AreEqual(i, value, Format('LIFO violation at element %d', [i]));
    end;
    Assert.IsTrue(stack.IsEmpty, 'Stack should be empty after drain');
  finally FreeAndNil(stack); end;
end;

procedure TTestContainers.TestBoundedQueueMPMC;
// Multiple producers push distinct non-overlapping integer ranges; multiple
// consumers drain concurrently. Verifies no items are lost or duplicated
// under contention by checking both the count and the summed values.
const
  CProducers         = 4;
  CConsumers         = 4;
  CItemsPerProducer  = 2500;
  CCapacity          = 128;  // deliberately smaller than total work set
  CTimeout_ms        = 10000;
var
  queue       : TOmniBaseBoundedQueue;
  gate        : IOmniEvent;
  doneProd    : IOmniEvent;
  produced    : integer;
  consumed    : integer;
  sum         : integer;
  prodThreads : TArray<TThread>;
  consThreads : TArray<TThread>;
  i           : integer;
  expectedSum : int64;
  startValue  : integer;
begin
  queue := TOmniBaseBoundedQueue.Create;
  try
    queue.Initialize(CCapacity, SizeOf(integer));
    gate := CreateOmniEvent(true, false);
    doneProd := CreateOmniEvent(true, false);
    produced := 0;
    consumed := 0;
    sum := 0;
    SetLength(prodThreads, CProducers);
    SetLength(consThreads, CConsumers);
    for i := 0 to CProducers - 1 do begin
      startValue := i * CItemsPerProducer + 1;
      prodThreads[i] := TThread.CreateAnonymousThread(
        MakeProducer(gate, startValue, startValue + CItemsPerProducer - 1,
          function(value: integer): boolean
          begin
            Result := queue.Enqueue(value);
          end,
          @produced));
      prodThreads[i].FreeOnTerminate := false;
      prodThreads[i].Start;
    end;
    for i := 0 to CConsumers - 1 do begin
      consThreads[i] := TThread.CreateAnonymousThread(
        MakeConsumer(gate, doneProd,
          function(var value: integer): boolean
          begin
            Result := queue.Dequeue(value);
          end,
          @consumed, @sum));
      consThreads[i].FreeOnTerminate := false;
      consThreads[i].Start;
    end;
    gate.SetEvent;
    for i := 0 to CProducers - 1 do begin
      prodThreads[i].WaitFor;
      prodThreads[i].Free;
    end;
    doneProd.SetEvent;
    for i := 0 to CConsumers - 1 do begin
      consThreads[i].WaitFor;
      consThreads[i].Free;
    end;
    expectedSum := int64(CProducers) * CItemsPerProducer * (CProducers * CItemsPerProducer + 1) div 2;
    Assert.AreEqual(CProducers * CItemsPerProducer, produced,
      'Producers did not produce expected item count');
    Assert.AreEqual(CProducers * CItemsPerProducer, consumed,
      Format('Consumer count mismatch: produced=%d consumed=%d',
        [produced, consumed]));
    Assert.AreEqual(expectedSum, int64(sum),
      Format('Sum mismatch: expected=%d got=%d — lost or duplicated items',
        [expectedSum, sum]));
    Assert.IsTrue(queue.IsEmpty, 'Queue should be empty after MPMC run');
  finally FreeAndNil(queue); end;
end;

procedure TTestContainers.TestBoundedStackMPMC;
// Multiple producers push, multiple consumers pop. No ordering assertion
// (stack is LIFO and interleaved), just conservation: every pushed value
// appears in the consumed sum exactly once.
const
  CProducers         = 4;
  CConsumers         = 4;
  CItemsPerProducer  = 2500;
  CCapacity          = 128;
  CTimeout_ms        = 10000;
var
  stack       : TOmniBaseBoundedStack;
  gate        : IOmniEvent;
  doneProd    : IOmniEvent;
  produced    : integer;
  consumed    : integer;
  sum         : integer;
  prodThreads : TArray<TThread>;
  consThreads : TArray<TThread>;
  i           : integer;
  expectedSum : int64;
  startValue  : integer;
begin
  stack := TOmniBaseBoundedStack.Create;
  try
    stack.Initialize(CCapacity, SizeOf(integer));
    gate := CreateOmniEvent(true, false);
    doneProd := CreateOmniEvent(true, false);
    produced := 0;
    consumed := 0;
    sum := 0;
    SetLength(prodThreads, CProducers);
    SetLength(consThreads, CConsumers);
    for i := 0 to CProducers - 1 do begin
      startValue := i * CItemsPerProducer + 1;
      prodThreads[i] := TThread.CreateAnonymousThread(
        MakeProducer(gate, startValue, startValue + CItemsPerProducer - 1,
          function(value: integer): boolean
          begin
            Result := stack.Push(value);
          end,
          @produced));
      prodThreads[i].FreeOnTerminate := false;
      prodThreads[i].Start;
    end;
    for i := 0 to CConsumers - 1 do begin
      consThreads[i] := TThread.CreateAnonymousThread(
        MakeConsumer(gate, doneProd,
          function(var value: integer): boolean
          begin
            Result := stack.Pop(value);
          end,
          @consumed, @sum));
      consThreads[i].FreeOnTerminate := false;
      consThreads[i].Start;
    end;
    gate.SetEvent;
    for i := 0 to CProducers - 1 do begin
      prodThreads[i].WaitFor;
      prodThreads[i].Free;
    end;
    doneProd.SetEvent;
    for i := 0 to CConsumers - 1 do begin
      consThreads[i].WaitFor;
      consThreads[i].Free;
    end;
    expectedSum := int64(CProducers) * CItemsPerProducer * (CProducers * CItemsPerProducer + 1) div 2;
    Assert.AreEqual(CProducers * CItemsPerProducer, produced,
      'Producers did not produce expected item count');
    Assert.AreEqual(CProducers * CItemsPerProducer, consumed,
      Format('Consumer count mismatch: produced=%d consumed=%d',
        [produced, consumed]));
    Assert.AreEqual(expectedSum, int64(sum),
      Format('Sum mismatch: expected=%d got=%d — lost or duplicated items',
        [expectedSum, sum]));
    Assert.IsTrue(stack.IsEmpty, 'Stack should be empty after MPMC run');
  finally FreeAndNil(stack); end;
end;

procedure TTestContainers.TestQueueObserverNotification;
var
  value: integer;
begin
  var queue := TOmniBoundedQueue.Create(4, SizeOf(integer));
  try
    var observer := CreateContainerEventObserver;
    try
      queue.ContainerSubject.Attach(observer, coiNotifyOnAllInserts);

      value := 1;
      queue.Enqueue(value);
      Assert.IsTrue(observer.GetEvent.WaitFor(0) = wrSignaled,
        'Observer should be notified on enqueue');
    finally observer := nil; end;
  finally FreeAndNil(queue); end;
end;

procedure TTestContainers.TestStackObserverNotification;
var
  value: integer;
begin
  var stack := TOmniBoundedStack.Create(4, SizeOf(integer));
  try
    var observer := CreateContainerEventObserver;
    try
      stack.ContainerSubject.Attach(observer, coiNotifyOnAllInserts);

      value := 1;
      stack.Push(value);
      Assert.IsTrue(observer.GetEvent.WaitFor(0) = wrSignaled,
        'Observer should be notified on push');
    finally observer := nil; end;
  finally FreeAndNil(stack); end;
end;

end.
