# OtlParallel — High-Level Parallel Execution

`OtlParallel.pas` provides the `Parallel` class, the main entry point for
high-level parallel constructs in OmniThreadLibrary.

This document covers the **Channel** and **Select** constructs. For other
constructs (`ForEach`, `Join`, `Future`, `Pipeline`, `Map`, `Async`,
`BackgroundWorker`, `TimedTask`, `ParallelTask`), see the main OTL
documentation.

---

## Parallel.Channel&lt;T&gt;

Go-style typed, directional, bounded channel for producer/consumer
communication. Channels are the primary mechanism for passing data safely
between threads without shared mutable state.

### Creating a Channel

```pascal
// Bounded channel (default capacity = 128)
var ch := Parallel.Channel<integer>;

// Custom capacity
var ch := Parallel.Channel<string>(1024);

// Unbounded channel (capacity = 0, no back-pressure)
var ch := Parallel.Channel<TMyRecord>(0);
```

`Parallel.Channel<T>` returns an `IOmniChannel<T>` which provides access to
the sender and receiver ends.

### Interfaces

#### IOmniChannel&lt;T&gt;

| Method | Description |
|--------|-------------|
| `Sender: IOmniChannelSender<T>` | Returns the sender end |
| `Receiver: IOmniChannelReceiver<T>` | Returns the receiver end |
| `Close` | Closes the channel (no more sends allowed) |

#### IOmniChannelSender&lt;T&gt;

| Method | Description |
|--------|-------------|
| `Send(value: T)` | Blocks until the value is sent. Blocks if the channel is at capacity. |
| `TrySend(value: T; timeout_ms: cardinal = 0): boolean` | Non-blocking send. Returns `false` if the channel is full and timeout expires. |
| `Close` | Marks the channel as closed. No further sends are allowed. |
| `IsClosed: boolean` | Returns `true` if the channel has been closed. |

#### IOmniChannelReceiver&lt;T&gt;

| Method | Description |
|--------|-------------|
| `Receive: T` | Blocks until a value is available. Raises `ECollectionCompleted` if the channel is closed and empty. |
| `TryReceive(out value: T; timeout_ms: cardinal = 0): boolean` | Non-blocking receive. Returns `false` if no data is available within the timeout. Returns `false` (no exception) when the channel is closed and drained. |
| `IsClosed: boolean` | Returns `true` if the channel has been closed (no more sends). Items may still be available for reading. |
| `IsEmpty: boolean` | Returns `true` if no items are currently buffered. |
| `Count: integer` | Number of items currently buffered. |

### Directionality

The sender and receiver are separate interfaces, enabling directional typing:

```pascal
procedure Producer(const sender: IOmniChannelSender<integer>);
begin
  for var i := 1 to 100 do
    sender.Send(i);
  sender.Close;
end;

procedure Consumer(const receiver: IOmniChannelReceiver<integer>);
var
  value: integer;
begin
  while receiver.TryReceive(value, INFINITE) do
    ProcessItem(value);
end;
```

### Basic Producer/Consumer

```pascal
var ch := Parallel.Channel<integer>;

// Producer thread
TTask.Run(
  procedure
  begin
    for var i := 1 to 1000 do
      ch.Sender.Send(i);
    ch.Close;
  end);

// Consumer (main thread)
var value: integer;
while ch.Receiver.TryReceive(value, INFINITE) do
  Writeln(value);
```

### Bounded Channels and Back-Pressure

When a bounded channel is full, `Send` blocks until space becomes available.
This provides natural back-pressure:

```pascal
// Channel with capacity 4 — producer blocks when 4 items are buffered
var ch := Parallel.Channel<integer>(4);

ch.Sender.Send(1);  // immediate
ch.Sender.Send(2);  // immediate
ch.Sender.Send(3);  // immediate
ch.Sender.Send(4);  // immediate
ch.Sender.Send(5);  // blocks until a consumer calls Receive/TryReceive
```

Use `TrySend` with a timeout for non-blocking behavior:

```pascal
if not ch.Sender.TrySend(value, 0) then
  // channel is full, handle accordingly
```

### Close Semantics

- `Close` (or `Sender.Close`) marks the channel as closed — no more sends.
- Items already in the buffer can still be received.
- `Receiver.TryReceive` returns `false` once the channel is closed AND drained.
- `Receiver.Receive` raises `ECollectionCompleted` in the same situation.

```pascal
ch.Sender.Send(1);
ch.Sender.Send(2);
ch.Close;

// Both items can still be received
Writeln(ch.Receiver.Receive);  // 1
Writeln(ch.Receiver.Receive);  // 2

// Channel is now closed and drained
var v: integer;
ch.Receiver.TryReceive(v, 0);  // returns false
ch.Receiver.Receive;            // raises ECollectionCompleted
```

### Multiple Consumers (Fan-Out)

Multiple threads can safely receive from the same channel. Each item is
delivered to exactly one consumer:

```pascal
var ch := Parallel.Channel<integer>(64);

// Two consumer threads
for var i := 1 to 2 do
  TTask.Run(
    procedure
    var value: integer;
    begin
      while ch.Receiver.TryReceive(value, INFINITE) do
        ProcessItem(value);
    end);

// Producer
for var i := 1 to 1000 do
  ch.Sender.Send(i);
ch.Close;
```

### Thread Safety

- Multiple producers and multiple consumers can use the same channel
  concurrently.
- The underlying `IOmniBlockingCollection` serializes access internally.
- The channel's condition variable (`TConditionVariableCS`) is used for
  efficient blocking/wakeup, not OS events.

### Supported Types

`Channel<T>` works with any Delphi type: integers, strings, records,
interfaces, classes. Values are stored via `TOmniValue` internally.

```pascal
var intCh := Parallel.Channel<integer>;
var strCh := Parallel.Channel<string>;
var recCh := Parallel.Channel<TPoint>;
```

---

## Parallel.Select

Go-style `select` for waiting on multiple channels simultaneously. Fires
exactly one handler per `Wait` call, enabling multiplexed channel dispatch.

### Creating a Select

```pascal
var sel := Parallel.Select([
  SelectCase.Receive<integer>(ch1.Receiver,
    procedure(v: integer) begin HandleInt(v) end),
  SelectCase.Receive<string>(ch2.Receiver,
    procedure(v: string) begin HandleStr(v) end)
]);
```

`Parallel.Select` takes an array of `IOmniSelectCase` values built with the
`SelectCase` helper record. It returns an `IOmniSelect` interface.

**Note:** `SelectCase` is a separate record rather than methods on `Parallel`
because adding generic methods to the `Parallel` class triggers a Delphi
compiler bug with overload resolution.

### Interfaces

#### IOmniSelect

| Method | Description |
|--------|-------------|
| `Wait(timeout_ms: cardinal = INFINITE): TOmniSelectResult` | Waits for one channel to be ready, fires its handler, and returns. |

#### SelectCase (record)

| Method | Description |
|--------|-------------|
| `Receive<T>(receiver, handler: TProc<T>): IOmniSelectCase` | Creates a receive case. When data arrives on this receiver, `handler` is called with the value. |
| `Default(handler: TProc): IOmniSelectCase` | Creates a default case. Fires immediately if no channel has data ready. |

#### TOmniSelectResult

| Value | Meaning |
|-------|---------|
| `srHandled` | A receive case fired — one value was consumed and its handler called. |
| `srTimeout` | No channel had data before the timeout expired. |
| `srAllClosed` | All receive channels are closed and drained. No more data will ever arrive. |
| `srDefault` | No channel had data ready; the default handler was called. |

### Basic Select

```pascal
var ch1 := Parallel.Channel<integer>;
var ch2 := Parallel.Channel<string>;

ch1.Sender.Send(42);

var result := Parallel.Select([
  SelectCase.Receive<integer>(ch1.Receiver,
    procedure(v: integer) begin Writeln('int: ', v) end),
  SelectCase.Receive<string>(ch2.Receiver,
    procedure(v: string) begin Writeln('str: ', v) end)
]).Wait(1000);

// Output: int: 42
// result = srHandled
```

### Select Loop

The most common pattern: call `Wait` in a loop until all channels close.
The `IOmniSelect` object is reusable.

```pascal
var ch := Parallel.Channel<integer>;

// Producer
TTask.Run(
  procedure
  begin
    for var i := 1 to 100 do
      ch.Sender.Send(i);
    ch.Close;
  end);

// Select loop
var sum := 0;
var sel := Parallel.Select([
  SelectCase.Receive<integer>(ch.Receiver,
    procedure(v: integer) begin sum := sum + v end)
]);
while sel.Wait = srHandled do
  ;
// sum = 5050
```

### Non-Blocking Select (Default Case)

Add a `SelectCase.Default` to make `Wait` return immediately when no
channel is ready:

```pascal
var result := Parallel.Select([
  SelectCase.Receive<integer>(ch.Receiver,
    procedure(v: integer) begin ProcessItem(v) end),
  SelectCase.Default(
    procedure begin DoOtherWork end)
]).Wait;

case result of
  srHandled: ; // processed a channel item
  srDefault: ; // no data — did other work
end;
```

When a default case is present:
- If any channel has data, its handler fires (`srHandled`).
- If no channel has data, the default handler fires immediately (`srDefault`).
- `Wait` never blocks.

### Timeout

```pascal
var result := sel.Wait(5000);
if result = srTimeout then
  Writeln('No channel activity for 5 seconds');
```

### Fan-In (Merge Multiple Channels)

Select is the natural way to merge multiple channels into one:

```pascal
var ch1 := Parallel.Channel<integer>;
var ch2 := Parallel.Channel<integer>;
var output := Parallel.Channel<integer>;

// Two producers
TTask.Run(procedure begin
  for var i := 1 to 50 do ch1.Sender.Send(i);
  ch1.Close;
end);
TTask.Run(procedure begin
  for var i := 51 to 100 do ch2.Sender.Send(i);
  ch2.Close;
end);

// Fan-in: merge ch1 and ch2 into output
TTask.Run(procedure begin
  var sel := Parallel.Select([
    SelectCase.Receive<integer>(ch1.Receiver,
      procedure(v: integer) begin output.Sender.Send(v) end),
    SelectCase.Receive<integer>(ch2.Receiver,
      procedure(v: integer) begin output.Sender.Send(v) end)
  ]);
  while sel.Wait(5000) <> srAllClosed do ;
  output.Close;
end);

// Consumer reads merged stream
var value: integer;
while output.Receiver.TryReceive(value, 5000) do
  ProcessItem(value);
```

### Quit Channel Pattern

Use a separate "quit" channel to signal loop termination:

```pascal
var work := Parallel.Channel<integer>;
var quit := Parallel.Channel<boolean>;

// Worker
TTask.Run(procedure begin
  var done := false;
  var sel := Parallel.Select([
    SelectCase.Receive<integer>(work.Receiver,
      procedure(v: integer) begin ProcessItem(v) end),
    SelectCase.Receive<boolean>(quit.Receiver,
      procedure(v: boolean) begin done := true end)
  ]);
  while (not done) and (sel.Wait = srHandled) do ;
end);

// Later: signal the worker to stop
quit.Sender.Send(true);
quit.Close;
```

### Round-Robin Fairness

When multiple channels have data ready simultaneously, Select uses
round-robin scheduling. Each `Wait` call starts scanning from the index
after the last fired case, preventing starvation:

```pascal
var ch1 := Parallel.Channel<integer>;
var ch2 := Parallel.Channel<integer>;

// Both channels have 10 items
for var i := 1 to 10 do begin
  ch1.Sender.Send(i);
  ch2.Sender.Send(i);
end;

var sel := Parallel.Select([
  SelectCase.Receive<integer>(ch1.Receiver,
    procedure(v: integer) begin end),
  SelectCase.Receive<integer>(ch2.Receiver,
    procedure(v: integer) begin end)
]);

// 20 Wait calls will consume 10 from each channel
for var i := 1 to 20 do
  sel.Wait(1000);
```

### How It Works

1. **Notification registration**: On creation, Select registers an
   `IOmniSelectNotifier` on each channel's `IOmniChannelState`. When any
   channel receives data (or is closed), it calls `Notify` on all registered
   notifiers.

2. **Wait loop**: `Wait` polls all cases via `TryReceive(0)` in round-robin
   order. If any succeeds, the handler fires and `Wait` returns `srHandled`.

3. **Efficient blocking**: If no channel has data and there is no default
   case, `Wait` blocks on a condition variable (`TConditionVariableCS`). The
   notifier wakes it when any channel signals.

4. **Cleanup**: When the `IOmniSelect` is released, it unregisters its
   notifier from all channels.

### Thread Safety

- `Wait` should be called from a single thread. The handler callbacks
  execute on the calling thread (the thread that calls `Wait`).
- The channels themselves are thread-safe: producers can `Send` from any
  thread while the select loop runs in another.
- Multiple `IOmniSelect` instances can watch the same channel concurrently
  (each registers its own notifier).

---

## Parallel.Merge&lt;T&gt;

Convenience wrapper around `Select` that merges multiple channels of the same
type into a single output channel. A background thread runs a select loop,
forwarding every received value to the output. When all input channels are
closed and drained, the output channel is closed automatically.

### API

```pascal
class function Parallel.Merge<T>(
  const receivers: array of IOmniChannelReceiver<T>;
  capacity: integer = 128): IOmniChannelReceiver<T>;
```

| Parameter | Description |
|-----------|-------------|
| `receivers` | Input channels to merge. All must be the same type `T`. |
| `capacity` | Buffer size for the output channel (default 128). |
| **Returns** | The receiver end of the merged output channel. |

### Example — Fan-In

```pascal
var ch1 := Parallel.Channel<integer>;
var ch2 := Parallel.Channel<integer>;

// Two producers
TTask.Run(procedure begin
  for var i := 1 to 50 do ch1.Sender.Send(i);
  ch1.Close;
end);
TTask.Run(procedure begin
  for var i := 51 to 100 do ch2.Sender.Send(i);
  ch2.Close;
end);

// Merge into a single stream
var merged := Parallel.Merge<integer>([ch1.Receiver, ch2.Receiver]);

// Read the merged stream
var value: integer;
while merged.TryReceive(value, 5000) do
  ProcessItem(value);
// All 100 values received in arrival order
```

### Lifecycle

- A background thread is created to run the select loop. It terminates
  automatically when all input channels are closed and drained.
- The output channel is closed when the background thread exits.
- If the consumer drops the output receiver, the background thread continues
  until all inputs close (same behavior as Go).
- Works with any type: integers, strings, records, interfaces.

---

## Parallel.Race&lt;T&gt;

Returns the first value received from any of the given channels. This is
a single-shot operation — it consumes one value and returns.

### API

```pascal
// Blocking — raises on timeout or all-closed
class function Parallel.Race<T>(
  const receivers: array of IOmniChannelReceiver<T>;
  timeout_ms: cardinal = INFINITE): T;

// Non-raising — returns false on timeout or all-closed
class function Parallel.TryRace<T>(
  const receivers: array of IOmniChannelReceiver<T>;
  out value: T;
  timeout_ms: cardinal = INFINITE): boolean;
```

| Method | On success | On timeout | On all closed |
|--------|-----------|-----------|---------------|
| `Race<T>` | Returns value | Raises `ESelectTimeout` | Raises `ESelectTimeout` |
| `TryRace<T>` | Returns `true`, sets `value` | Returns `false` | Returns `false` |

### Example — First Response Wins

```pascal
var fast := Parallel.Channel<string>;
var slow := Parallel.Channel<string>;

TTask.Run(procedure begin Sleep(10);  fast.Sender.Send('fast') end);
TTask.Run(procedure begin Sleep(200); slow.Sender.Send('slow') end);

var winner := Parallel.Race<string>([fast.Receiver, slow.Receiver], 5000);
// winner = 'fast'
```

### Example — Timeout

```pascal
var ch := Parallel.Channel<integer>;

var value: integer;
if Parallel.TryRace<integer>([ch.Receiver], value, 100) then
  Writeln('Got: ', value)
else
  Writeln('No data within 100ms');
```

### Notes

- `Race` internally creates a `Parallel.Select`, calls `Wait` once, and
  returns the result. No background threads are created.
- Only one value is consumed. Other channels are not drained.
- For repeated racing, use `Parallel.Select` directly in a loop.
