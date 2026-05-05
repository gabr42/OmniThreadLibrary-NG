# Migrating from OmniThreadLibrary v3 to OTL NG

This guide covers all breaking changes, removed features, new APIs, and behavioral
differences between OmniThreadLibrary v3.07.x (Windows-only) and OTL NG
(cross-platform).

## Minimum Requirements

| Aspect | OTL v3 | OTL NG |
|--------|--------|--------|
| Minimum Delphi | 2007 | **Delphi 11 Alexandria** |
| Platforms | Win32, Win64 | Win32, Win64 (313/313), Linux64 (308/311 + 3 POSIX skips), Android64 (308/311 + 3 POSIX skips, FMX runner on ARM64 device); WinARM64 compiles (no runtime); macOS/iOS targeted but unverified |
| Test framework | DUnit | DUnitX |
| External dependencies | GpLists, GpStringHash, DSiWin32 | **None** (all inlined or replaced with RTL) |

---

## Quick Checklist

1. Remove `.Alertable` calls from task chains (`.MsgWait` is back, see
   [.MsgWait Reinstated (Windows only)](#msgwait-reinstated-windows-only))
2. Replace `THandle`-based wait objects with `IOmniEvent`
3. Remove `Parallel.ForkJoin` usage (no replacement; use `Parallel.ForEach` or
   `TTask`)
4. Replace `CheckEquals` / `CheckTrue` with `Assert.AreEqual` / `Assert.IsTrue`
   in tests
5. Remove `GpLists`, `GpStringHash`, `DSiWin32` from uses clauses
6. Update package references to Delphi 11+ runtime package only
7. If owning OTL tasks from a plain `TThread`, add explicit `ProcessMessages` or
   `WaitForMessage` calls (see [Plain TThread Owners](#plain-tthread-owners))
8. Stop relying on `Terminate(timeout)` to hard-kill stuck tasks — both
   Windows and POSIX now detach instead of force-killing. The timeout is
   advisory; design tasks to honor `CancellationToken` / `Stopped` (see
   [No Safe Force-Kill — Detach Replaces TerminateThread](#no-safe-force-kill--detach-replaces-terminatethread))
9. If you attach `TOmniEventMonitor` to an `IOmniThreadPool` with
   `pool.MonitorWith(monitor)`, make sure the main thread pumps
   `CheckSynchronize` — required by all console apps (any platform),
   automatic in VCL / FMX (see
   [Thread Pool Monitor Callbacks Need CheckSynchronize](#thread-pool-monitor-callbacks-need-checksynchronize-console-apps))

---

## Removed Features

### Parallel.ForkJoin

The entire `Parallel.ForkJoin` / `Parallel.ForkJoin<T>` API has been removed.

**Removed types:** `TOmniForkJoinDelegate`, `TOmniForkJoinDelegateEx`,
`IOmniCompute<T>`, `IOmniForkJoin<T>`, `TOmniCompute<T>`, `TOmniForkJoin<T>`

**Migration:** Use `Parallel.ForEach`, `Parallel.Join`, or `System.Threading.TTask`
instead.

```pascal
// OTL v3 — ForkJoin
var
  fj: IOmniForkJoin<integer>;
begin
  fj := Parallel.ForkJoin<integer>;
  fj.Compute(function: integer begin Result := HeavyWork(1); end);
  fj.Compute(function: integer begin Result := HeavyWork(2); end);
  // collect results...

// OTL NG — use Parallel.Join or TTask
Parallel.Join([
  procedure begin resultA := HeavyWork(1); end,
  procedure begin resultB := HeavyWork(2); end
]).Execute;
```

### NUMA and Processor Groups

All NUMA and Windows processor-group APIs have been removed:

- `IOmniNUMANode` / `IOmniNUMANodes`, `Environment.NUMANodes`
- `IOmniProcessorGroup` / `IOmniProcessorGroups`, `Environment.ProcessorGroups`
- `TOmniGroupAffinity`, `IOmniThreadEnvironment.GroupAffinity`
- `IOmniTaskControl.NUMANode(n)`, `IOmniTaskControl.ProcessorGroup(n)`
- `IOmniThreadPool.NUMANodes`, `IOmniThreadPool.ProcessorGroups`, and the
  underlying `TOTPWorkerScheduler` cluster dispatcher

OTL NG worker threads now inherit the process default affinity. If you need
to restrict a task's CPUs on Windows, set single-group affinity directly via
`Winapi.Windows.SetThreadAffinityMask` from inside the task body, or — for
cross-platform scoping — keep using the process-wide `Affinity` mask.
Multi-group (>64-CPU) scheduling is no longer supported by the library.

### Design-Time Packages

All design-time packages and component registration (`OtlRegister.pas`,
`OtlEventMonitor.dcr`) have been removed. Only the Delphi 11 runtime package is
retained.

### Windows Message-Based Observers

`TOmniContainerWindowsMessageObserver` and `TOmniContainerWindowsEventObserver` are
removed from `OtlContainerObserver.pas`.

**Replaced by:** Cross-platform observers:
- Main thread: `CreateContainerMainThreadObserver()` from
  `OtlContainerObserver.pas` (dispatches a `TProc` callback via
  `TThread.ForceQueue`; multiple notifications coalesce into one).
- Background threads: `CreateContainerBackgroundObserver()` from
  `OtlBackgroundObserver.pas`. Windows uses `QueueUserAPC` into the
  target thread's alertable wait; POSIX uses an atomic pending flag +
  thread-local registry drained by `DrainBackgroundObservers`.

---

## Deprecated APIs

```pascal
// Remove — no-op in OTL NG
CreateTask(worker)
  .Alertable           // deprecated: task loop uses CV-based waiting
  .Run;

// Replace the old one/two-parameter SetTimer with the three-parameter
// overload: timerID first, then interval (ms), then the message.
// Old:
task.SetTimer(1000);
task.SetTimer(1000, MSG_TIMER);
// New:
task.SetTimer(timerID, 1000, MSG_TIMER);
```

### .MsgWait Reinstated (Windows only)

`.MsgWait(wakeMask: DWORD = QS_ALLEVENTS)` is back on `IOmniTaskControl`
for Windows targets. It is still absent on POSIX. Use it when the worker
relies on thread-owned Windows messages — most commonly `TTimer`, raw
`SetTimer`, window hooks, or legacy code that uses `PostThreadMessage`.

```pascal
// TTimer/WM_TIMER in a worker's Initialize needs this chain to fire:
CreateTask(MyTimerWorker).MsgWait.Run;
```

Internally the task's wait is routed through
`MsgWaitForMultipleObjectsEx` with the supplied `wakeMask`; on
`waMessage` the task loop calls `PeekMessage / TranslateMessage /
DispatchMessage` so `WM_TIMER`, posted messages, and window-message
callbacks reach their handlers on the task thread.

**Limit:** `MsgWaitForMultipleObjectsEx` accepts at most
`MAXIMUM_WAIT_OBJECTS - 1 = 63` wait handles. If a `.MsgWait` task's wait
set exceeds this at runtime (comm channels + terminate events +
`RegisterWaitObject` handles), `WaitForEvent` raises an exception rather
than silently stalling. For larger wait sets, drop `.MsgWait` and route
messages through a dedicated message pump.

---

## API Changes

### TOmniTransitionEvent Unified

In OTL v3, `TOmniTransitionEvent` was `THandle` on Windows and `IOmniEvent`
elsewhere. In OTL NG it is always `IOmniEvent`:

```pascal
// OTL v3 (Windows)
var evt: TOmniTransitionEvent;  // = THandle
WaitForSingleObject(evt, INFINITE);

// OTL NG (all platforms)
var evt: TOmniTransitionEvent;  // = IOmniEvent
evt.WaitFor(INFINITE);
```

If your code passed `TOmniTransitionEvent` to Windows API functions
(`WaitForSingleObject`, `WaitForMultipleObjects`), you must switch to
`IOmniEvent.WaitFor` or `TWaitFor.WaitAny`.

### WaitForMultipleObjects Replaced

All internal `WaitForMultipleObjects` / `MsgWaitForMultipleObjectsEx` calls are
replaced by `TWaitFor` (condition-variable-based, cross-platform).

```pascal
// OTL v3
handles: array of THandle;
WaitForMultipleObjects(Length(handles), @handles[0], False, timeout);

// OTL NG
var
  waitFor: TWaitFor;
  events: array of IOmniEvent;
begin
  waitFor := TWaitFor.Create(events);
  try
    case waitFor.WaitAny(timeout_ms) of
      waAwaited:  // signaled — check waitFor.Signalled
      waTimeout:  // timed out
    end;
  finally waitFor.Free; end;
end;
```

### IOmniCancellationToken.Handle

The `.Handle` property is now Windows-only (under `{$IFDEF MSWINDOWS}`). Use
`.Event` (type `IOmniEvent`) for cross-platform code:

```pascal
// OTL v3
WaitForSingleObject(token.Handle, INFINITE);

// OTL NG
token.Event.WaitFor(INFINITE);
```

---

## New Features

### ProcessMessages and WaitForMessage

New methods on `IOmniTaskControl` for non-OTL-task owners that need to process
OTL messages:

```pascal
// Process all pending messages without blocking
taskControl.ProcessMessages;

// Block until a message arrives, task terminates, or timeout
case taskControl.WaitForMessage(5000) of
  wmrMessage:    // message available — call ProcessMessages
  wmrTerminated: // task has stopped
  wmrTimeout:    // no message within 5 seconds
end;
```

**When to use:** If you own an OTL task from a plain `TThread` (not a VCL/FMX
main thread), you must call `ProcessMessages` or `WaitForMessage` to receive
`OnMessage` / `OnTerminated` callbacks. See
[Plain TThread Owners](#plain-tthread-owners) below.

### COMInitialize

Optional COM apartment initialization for worker threads:

```pascal
CreateTask(worker)
  .COMInitialize(citSTA)   // or citMTA, citNone
  .Run;
```

On Windows, calls `CoInitializeEx` in the worker thread. On other platforms this
is accepted but has no effect.

### OtlBackgroundObserver

New unit providing cross-platform background-thread notification. The
factory returns an `IOmniContainerBackgroundObserver` interface
(reference-counted — no explicit `Free` needed):

```pascal
uses OtlBackgroundObserver;

var
  observer: IOmniContainerBackgroundObserver;
begin
  observer := CreateContainerBackgroundObserver(
    TThread.Current.ThreadID,
    procedure begin HandleNotification; end);
  // ...use observer — release by letting it go out of scope.
end;
```

- **Windows:** Uses `QueueUserAPC` for zero-latency delivery into the
  target thread's alertable wait.
- **POSIX:** Uses atomic pending flag + thread-local registry; call
  `DrainBackgroundObservers` from your thread loop.

---

## Behavioral Changes

### Task Loop Architecture

| Aspect | OTL v3 | OTL NG |
|--------|--------|--------|
| Wait mechanism | `MsgWaitForMultipleObjectsEx` | `TWaitFor.WaitAny` (CV-based) by default; `TWaitFor.MsgWaitAny` when `.MsgWait` is set (Windows) |
| Message dispatch | Windows message queue | Direct queue polling; Windows message pump only when `.MsgWait` is set |
| `.Alertable` | Enables alertable wait | No-op (deprecated) |
| `.MsgWait` | Enables message waiting | Windows-only; wired through `TWaitFor.MsgWaitAny` + in-loop `PeekMessage/Translate/Dispatch` — see [.MsgWait Reinstated](#msgwait-reinstated-windows-only) |
| Timer processing | Polling-based | Polling-based (unchanged) |

The default task loop no longer processes Windows messages. If your
`TOmniWorker` relies on `WM_*` messages (e.g. `TTimer`, `SetTimer`, window
hooks) chain `.MsgWait` on Windows or switch to OTL's own messaging
(`task.Comm.Send`).

### Unobserved Task Lifetime

The `Unobserved` pattern (a task whose owner doesn't monitor its
termination) was reimplemented in OTL NG. In v3, `Unobserved` used
`CreateInternalMonitor` + `ForceQueue` to keep the task alive and dispatch its
termination callback. In NG it holds a self-reference in the shared info and
uses a dedicated cleanup thread — the external API is unchanged, but the
previous deadlock where a main-thread owner dropped the task reference during
shutdown is gone. No code changes required; existing `Unobserved` call sites
work as-is and are now safer.

### Plain TThread Owners

In OTL v3, `TOmniEventMonitor` dispatched `OnTaskMessage` / `OnTaskTerminated`
callbacks through Windows messages posted to a hidden window (created
via `AllocateHWnd`) — delivery required a Windows message pump on the
owner thread.

OTL NG removes the hidden-window infrastructure. Dispatch now uses an
APC-based path on Windows (`OtlBackgroundObserver` queues the callback
via `QueueUserAPC` into the owner thread's alertable wait) and a
manual-drain flag with thread-local observer registry on POSIX. Either
way, background-thread owners have to give OTL a chance to run
callbacks:

```pascal
// OTL NG — owning a task from a plain TThread
procedure TMyThread.Execute;
var
  task: IOmniTaskControl;
begin
  task := CreateTask(myWorker)
    .OnMessage(HandleMsg)
    .OnTerminated(HandleDone)
    .Run;

  // Option A: Polling loop
  while not Terminated do begin
    task.ProcessMessages;
    Sleep(10);
  end;

  // Option B: Blocking wait
  while not Terminated do begin
    case task.WaitForMessage(1000) of
      wmrMessage:    task.ProcessMessages;
      wmrTerminated: break;
      wmrTimeout:    ; // check Terminated, do other work
    end;
  end;
end;
```

**Main thread (VCL/FMX)** owners are unaffected — `TThread.Queue` still delivers
to the main thread's message loop.

### Thread Pool Force-Kill

`SuspendThread` / `ResumeThread` are no longer used in thread pool shutdown
paths. The pool now relies on `owtWorkItemLock` for safe work item stealing.
**`TerminateThread` is no longer used on Windows either** — see the next
section for details. Both platforms now detach stuck workers
(`FreeOnTerminate := true`) and let them keep running until they exit on
their own.

### No Safe Force-Kill — Detach Replaces TerminateThread

Earlier OTL NG versions used `TerminateThread` on Windows as a last resort to
hard-kill stuck workers (workers that ignored `CancellationToken` / `Stopped`
and didn't exit within the pool's `WaitOnTerminate_sec` window). That has been
removed. Per MSDN, `TerminateThread` is dangerous: if the killed thread held
the FastMM4 heap critical section (or any other process-wide lock) at the
moment of kill, the lock is leaked. Subsequent allocations across the entire
process then deadlock.

**New behavior, both Windows and POSIX:** when cooperative shutdown fails,
the worker is detached — the OS thread keeps running (or stays stuck) but is
no longer tracked by OTL. Leaking one worker thread is a far smaller problem
than process-wide heap corruption. Two diagnostic counters surface how often
this happens:

- `OtlThreadPool.GLeakedWorkerThreads` — incremented at the two pool detach
  sites (TOTPWorker.Cancel and the maintenance timer)
- `OtlTaskControl.GTaskControlLeakedThreads` — incremented at the
  TOmniTaskControl.Terminate fallback site

`pthread_cancel` was previously considered as a POSIX equivalent and rejected
for a similar reason: glibc's forced-unwind pseudo-exception is absorbed by
OTL's outer `except on E: Exception` handler in `TOTPWorkerThread.Execute`
without being re-raised, which leaves cancellation incomplete and makes
`pthread_join` block forever.

**User impact (all platforms):**
- `Terminate(timeout)` on a task that refuses to cooperate now returns
  `false` once the timeout elapses, but the underlying OS thread keeps
  running. The timeout is advisory.
- Design tasks to check `task.CancellationToken` / `task.Stopped` at regular
  intervals and never rely on force-termination as a functional mechanism.
- A test that previously asserted "stuck task did not reach line X because
  it was force-killed mid-Sleep" must now provide a release mechanism (e.g.
  a `release` event the test sets after its assertions) so the deliberately-
  stuck task can finish cleanly within the test boundary. Several
  `TestJoin.TestTermination*` and `TestForceKillStuckTask` cases in the
  OTL test suite have been updated this way; they're a good template.

### Thread Pool Monitor Callbacks Need CheckSynchronize (Console Apps)

`TOmniEventMonitor`'s pool-level events —

- `OnPoolThreadCreated`
- `OnPoolThreadDestroying`
- `OnPoolThreadKilled`
- `OnPoolWorkItemCompleted`

— dispatch through `TThread.ForceQueue` in OTL NG (v3 used a hidden
window + `PostMessage`). `ForceQueue` posts the handler to the main
thread's `TThread.Synchronize` queue, which only runs when something
calls `CheckSynchronize`. This is platform-independent:

- **GUI apps (VCL / FMX on Windows, Android, iOS, macOS, Linux):** the
  framework's idle loop calls `CheckSynchronize` automatically —
  callbacks fire without any extra work.
- **Console apps (Win32 / Win64 / Linux64):** the main thread must
  call `CheckSynchronize` (or `TThread.Synchronize` / `TThread.Queue`
  wrappers) periodically, otherwise pool callbacks queue and never
  run.

If your OTL v3 console app relied on the hidden-window pump, add a
periodic `CheckSynchronize(<timeout_ms>)` call on the main thread:

```pascal
// Typical console main-thread drain loop
while not Done do begin
  CheckSynchronize(100); // fires queued monitor callbacks
  // ...other main-thread work...
end;
```

Task-level events on the same monitor (`OnTaskMessage`,
`OnTaskTerminated`, `OnTaskUndeliveredMessage`) also route through
`TThread.ForceQueue` and follow the same rule.

### Lock-Free Containers on Non-x86/Non-Windows

`OtlContainers.pas` lock-free queue/stack rely on 128-bit compare-and-swap. On
Windows x64, this uses `InterlockedCompareExchange128` (CMPXCHG16B). On POSIX
and non-x86 targets, the implementation falls back to a global spinlock-
protected critical section. **Semantics are preserved** (the container is still
thread-safe and presents the same API), but throughput under contention is
lower than on Windows x64. If your design assumed wait-free progress, re-profile
on the new target.

---

## Removed Dependencies

### GpLists

All `TGpInt64List`, `TGpTMethodList`, etc. replaced with `TList<T>` from
`System.Generics.Collections`. No action needed unless you imported `GpLists`
specifically for OTL integration.

### GpStringHash

`TGpStringHash` replaced with `TObjectDictionary<string, T>`. The
`GpDelphiUnits` submodule is no longer required.

### DSiWin32

All `DSiWin32` calls replaced with direct RTL / WinAPI equivalents:

| Old (DSiWin32) | New |
|----------------|-----|
| `DSiTimeGetTime64` | `TStopwatch.ElapsedMilliseconds` |
| `DSiWaitForTwoObjects` | `TWaitFor.WaitAny` |
| `DSiAllocateHWnd` | Removed (no hidden windows) |
| `DSiGetThreadGroupAffinity` | Removed (no multi-group affinity); use `TPlatform.ThreadAffinity` for single-group |
| `IFF(cond, a, b)` | `IfThen(cond, a, b)` from `System.Math` |

Remove `DSiWin32` from your uses clauses if it was only there for OTL.

---

## Removed Compiler Defines

The following defines from `OtlOptions.inc` have been removed because they are
always true in Delphi 11+:

- `OTL_CountdownHasSpinCount`
- `OTL_NameThreadHasStringParameter`
- `OTL_TypeInfoHasTypeData`
- `OTL_VariantHasInt64`
- `OTL_StrPasInAnsiStrings`
- `OTL_HasVolatileAttribute`
- `OTL_FixedGenericIncompletelyDefined`
- `OTL_MobileSupport`
- `OTL_CanInlineOperators`
- `OTL_HasForceQueue`
- `OTL_HasLightweightMREW`

If your code tested these defines with `{$IFDEF}`, the guarded code will now
always compile (which is the correct behavior for Delphi 11+).

---

## Test Migration

Tests have been migrated from DUnit to DUnitX. If you maintain custom OTL tests:

| DUnit | DUnitX |
|-------|--------|
| `uses TestFramework` | `uses DUnitX.TestFramework` |
| `class(TTestCase)` | plain class with `[TestFixture]` |
| `published procedure` | `[Test] procedure` (public) |
| `procedure SetUp; override` | `[Setup] procedure SetUp` |
| `procedure TearDown; override` | `[TearDown] procedure TearDown` |
| `CheckEquals(a, b)` | `Assert.AreEqual(a, b)` |
| `CheckTrue(x)` | `Assert.IsTrue(x)` |
| `CheckFalse(x)` | `Assert.IsFalse(x)` |
| `Fail(msg)` | `Assert.Fail(msg)` |
| `RegisterTest(T.Suite)` | Remove (RTTI auto-discovery with `UseRTTI := True`) |

**Note:** DUnitX's `Assert.AreEqual` requires matching types. When comparing
different numeric types (e.g., `integer` vs `word`, `integer` vs `int64`), use
explicit generic parameters: `Assert.AreEqual<integer>(expected, actual)`.

---

## Common Migration Patterns

### Before/After: Creating a Task

```pascal
// OTL v3
CreateTask(worker)
  .Alertable
  .MsgWait
  .SetTimer(1000)
  .Run;

// OTL NG (most workers drop .Alertable/.MsgWait; SetTimer args are
// timerID, interval_ms, message)
CreateTask(worker)
  .SetTimer(timerID, 1000, MSG_TIMER)
  .Run;
```

### Before/After: Waiting on Multiple Events

```pascal
// OTL v3
var
  handles: array [0..1] of THandle;
begin
  handles[0] := event1.Handle;
  handles[1] := event2.Handle;
  case WaitForMultipleObjects(2, @handles[0], False, 1000) of
    WAIT_OBJECT_0:     HandleEvent1;
    WAIT_OBJECT_0 + 1: HandleEvent2;
    WAIT_TIMEOUT:      HandleTimeout;
  end;
end;

// OTL NG — WaitFor.Signalled is `array of THandleInfo` (record with
// `Index: integer`), NOT a boolean array. Iterate to see which
// IOmniEvents signalled in the winning slice.
var
  waitFor: TWaitFor;
  info   : TWaitFor.THandleInfo;
begin
  waitFor := TWaitFor.Create([event1, event2]);
  try
    case waitFor.WaitAny(1000) of
      waAwaited:
        for info in waitFor.Signalled do
          case info.Index of
            0: HandleEvent1;
            1: HandleEvent2;
          end;
      waTimeout: HandleTimeout;
    end;
  finally waitFor.Free; end;
end;
```

### Before/After: Container Observer

```pascal
// OTL v3 (Windows-only)
uses OtlContainerObserver;
var
  observer: TOmniContainerWindowsMessageObserver;
begin
  observer := CreateContainerWindowsMessageObserver(Handle, WM_USER + 1, 0, 0);
  collection.ContainerSubject.Attach(observer, coiNotifyOnAllInserts);

// OTL NG (cross-platform, main-thread owner)
uses OtlContainerObserver;
var
  observer: IOmniContainerMainThreadObserver;
begin
  observer := CreateContainerMainThreadObserver(
    procedure begin DrainQueue; end);
  collection.ContainerSubject.Attach(observer, coiNotifyOnAllInserts);
  // ...before tearing down anything the callback touches:
  observer.Shutdown;
  collection.ContainerSubject.Detach(observer, coiNotifyOnAllInserts);

// OTL NG (cross-platform, background-thread owner)
uses OtlBackgroundObserver;
var
  observer: IOmniContainerBackgroundObserver;
begin
  observer := CreateContainerBackgroundObserver(
    TThread.Current.ThreadID,
    procedure begin ProcessNewItems; end);
  collection.ContainerSubject.Attach(observer, coiNotifyOnAllInserts);
```

See `examples/TThread communication/tthreadCommMain.pas` for a complete
main-thread-observer example: a plain `TThread` worker delivers results to
its owning form via a `TOmniMessageQueue` whose inserts trigger a drain
on the main thread.

---

## File Changes Summary

| File | Change |
|------|--------|
| `OtlSync.pas` | Removed inline assembly; unified `TOmniTransitionEvent` to `IOmniEvent`; removed `IOmniHandleObject`; added `TWaitFor` |
| `OtlContainers.pas` | Replaced asm pause with `TThread.SpinWait`; lock-free fallback on non-x86 |
| `OtlCollections.pas` | Replaced `WaitForMultipleObjects` with `TWaitFor.WaitAny` |
| `OtlContainerObserver.pas` | Removed Windows message/event observers; `IOmniEvent`-only; added `CreateContainerMainThreadObserver` (TThread.Queue dispatch with coalescing + Shutdown gate) |
| `OtlPlatform.pas` | New platform abstraction: `TTimeSource`, `TPlatform.ThreadAffinity` |
| `OtlCommon.pas` | Removed GpStringHash/DSiWin32 dependencies |
| `OtlComm.pas` | Removed hidden window; switched to `IOmniEvent` observers |
| `OtlTaskControl.pas` | CV-based task loop; new `ProcessMessages`/`WaitForMessage`/`COMInitialize` APIs; deprecated `Alertable`; `.MsgWait(wakeMask)` reinstated on Windows for workers that need `WM_*` dispatch (see [.MsgWait Reinstated](#msgwait-reinstated-windows-only)) |
| `OtlThreadPool.pas` | Removed `SuspendThread`/`ResumeThread`; removed DSiWin32 |
| `OtlParallel.pas` | Removed `ForkJoin`; replaced hidden window with cross-platform observers |
| `OtlDataManager.pas` | Unified waiting with `TWaitFor` |
| `OtlBackgroundObserver.pas` | **New** — cross-platform APC/CV observer |
| `OtlOptions.inc` | Removed pre-Delphi 11 conditionals |
| `OtlEventMonitor.pas` | Removed unused DSiWin32; pool-level callbacks remain Windows-only (task-level callbacks are cross-platform) |
