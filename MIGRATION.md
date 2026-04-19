# Migrating from OmniThreadLibrary v3 to OTL NG

This guide covers all breaking changes, removed features, new APIs, and behavioral
differences between OmniThreadLibrary v3.07.x (Windows-only) and OTL NG
(cross-platform).

## Minimum Requirements

| Aspect | OTL v3 | OTL NG |
|--------|--------|--------|
| Minimum Delphi | 2007 | **Delphi 11 Alexandria** |
| Platforms | Win32, Win64 | Win32, Win64 (full), Linux64 (near-full, 3 POSIX-specific skips); WinARM64/macOS/iOS/Android targeted but unverified |
| Test framework | DUnit | DUnitX |
| External dependencies | GpLists, GpStringHash, DSiWin32 | **None** (all inlined or replaced with RTL) |

---

## Quick Checklist

1. Remove `.Alertable` and `.MsgWait` calls from task chains
2. Replace `THandle`-based wait objects with `IOmniEvent`
3. Remove `Parallel.ForkJoin` usage (no replacement; use `Parallel.ForEach` or
   `TTask`)
4. Replace `CheckEquals` / `CheckTrue` with `Assert.AreEqual` / `Assert.IsTrue`
   in tests
5. Remove `GpLists`, `GpStringHash`, `DSiWin32` from uses clauses
6. Update package references to Delphi 11+ runtime package only
7. If owning OTL tasks from a plain `TThread`, add explicit `ProcessMessages` or
   `WaitForMessage` calls (see [Plain TThread Owners](#plain-tthread-owners))
8. On POSIX, stop relying on `Terminate(timeout)` to hard-kill stuck tasks —
   the timeout is advisory there (see
   [POSIX Has No Safe Force-Kill](#posix-has-no-safe-force-kill))

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

### NUMA Support

NUMA-related APIs (`Environment.NUMANodes`, `Environment.AffinitiesToNUMANodes`,
affinity/NUMA helpers in `DSiWin32`) have been removed. Thread affinity is still
available on Windows via `TPlatform.ThreadAffinity` in `OtlPlatform.pas`.

### Design-Time Packages

All design-time packages and component registration (`OtlRegister.pas`,
`OtlEventMonitor.dcr`) have been removed. Only the Delphi 11 runtime package is
retained.

### Windows Message-Based Observers

`TOmniContainerWindowsMessageObserver` and `TOmniContainerWindowsEventObserver` are
removed from `OtlContainerObserver.pas`.

**Replaced by:** Cross-platform observers:
- Main thread: `TThread.Queue`-based notification
- Background threads: `CreateContainerBackgroundObserver()` from
  `OtlBackgroundObserver.pas` (APC on Windows, CV-based on POSIX)

---

## Deprecated APIs

These methods still compile but are no-ops. Remove them from your code:

```pascal
// Remove these — they do nothing in OTL NG
CreateTask(worker)
  .Alertable           // deprecated: task loop uses CV-based waiting
  .MsgWait             // deprecated: task loop uses CV-based waiting
  .Run;

// Replace two-parameter SetTimer with three-parameter version
// Old:
task.SetTimer(1000);
task.SetTimer(1000, MSG_TIMER);
// New:
task.SetTimer(1000, MSG_TIMER, timerID);
```

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

New unit providing cross-platform background-thread notification:

```pascal
uses OtlBackgroundObserver;

var
  observer: TObject;
begin
  observer := CreateContainerBackgroundObserver(
    TThread.Current.ThreadID,
    procedure begin HandleNotification; end
  );
  // ...
  observer.Free;
end;
```

- **Windows:** Uses `QueueUserAPC` for zero-latency delivery during alertable
  waits
- **POSIX:** Uses atomic pending flag + thread-local registry; call
  `DrainBackgroundObservers` from your thread loop

---

## Behavioral Changes

### Task Loop Architecture

| Aspect | OTL v3 | OTL NG |
|--------|--------|--------|
| Wait mechanism | `MsgWaitForMultipleObjectsEx` | `TWaitFor.WaitAny` (CV-based) |
| Message dispatch | Windows message queue | Direct queue polling |
| `.Alertable` | Enables alertable wait | No-op (deprecated) |
| `.MsgWait` | Enables message waiting | No-op (deprecated) |
| Timer processing | Polling-based | Polling-based (unchanged) |

The task loop no longer processes Windows messages. If your `TOmniWorker` relied
on receiving `WM_*` messages inside the task thread, that no longer works. Use
OTL's own messaging (`task.Comm.Send`) instead.

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

In OTL v3, if you created and owned an OTL task from a background thread, Windows
APC delivery (via `SleepEx`) handled notification dispatch implicitly.

In OTL NG, background-thread owners must explicitly process messages:

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

`SuspendThread` / `ResumeThread` are no longer used in thread pool shutdown paths.
The pool now relies on `owtWorkItemLock` for safe work item stealing.
`TerminateThread` is still used on Windows as a last resort for stuck threads.
On POSIX, only cooperative termination (flag-based) is available.

### POSIX Has No Safe Force-Kill

On Windows, `IOmniParallelJoin.Terminate(timeout_ms)` and
`IOmniTaskControl.Terminate(maxWait_ms)` hard-kill stuck tasks via
`TerminateThread` once the timeout elapses. **On POSIX, this hard-kill path is a
no-op** — `FreeAndNil` simply `pthread_join`s until the thread exits on its own.

`pthread_cancel` is not a viable substitute: glibc's forced-unwind pseudo-
exception is absorbed by OTL's outer `except on E: Exception` handler in
`TOTPWorkerThread.Execute` without being re-raised, which leaves cancellation
incomplete and makes `pthread_join` block forever.

**User impact on POSIX:**
- `Terminate(timeout)` on a task that refuses to cooperate will wait until the
  task finishes (or forever). The timeout is advisory.
- Design tasks to check `task.CancellationToken` / `task.Stopped` at regular
  intervals and never rely on force-termination as a functional mechanism.

The three `TestJoin.TestTermination*` tests that exercise force-kill behavior
are `[Ignore]`d on non-Windows for this reason.

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
| `DSiGetThreadGroupAffinity` | `TPlatform.ThreadAffinity` |
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

// OTL NG
CreateTask(worker)
  .SetTimer(1000, MSG_TIMER, timerID)
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

// OTL NG
var
  waitFor: TWaitFor;
begin
  waitFor := TWaitFor.Create([event1, event2]);
  try
    case waitFor.WaitAny(1000) of
      waAwaited: begin
        if waitFor.Signalled[0] then HandleEvent1;
        if waitFor.Signalled[1] then HandleEvent2;
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
  collection.ContainerSubject.Attach(observer, cycNotify);

// OTL NG (cross-platform)
uses OtlBackgroundObserver;
var
  observer: TObject;
begin
  observer := CreateContainerBackgroundObserver(
    TThread.Current.ThreadID,
    procedure begin ProcessNewItems; end
  );
  collection.ContainerSubject.Attach(
    TOmniContainerObserver(observer), cycNotify);
```

---

## File Changes Summary

| File | Change |
|------|--------|
| `OtlSync.pas` | Removed inline assembly; unified `TOmniTransitionEvent` to `IOmniEvent`; removed `IOmniHandleObject`; added `TWaitFor` |
| `OtlContainers.pas` | Replaced asm pause with `TThread.SpinWait`; lock-free fallback on non-x86 |
| `OtlCollections.pas` | Replaced `WaitForMultipleObjects` with `TWaitFor.WaitAny` |
| `OtlContainerObserver.pas` | Removed Windows message/event observers; `IOmniEvent`-only |
| `OtlPlatform.pas` | New platform abstraction: `TTimeSource`, `TPlatform.ThreadAffinity` |
| `OtlCommon.pas` | Removed GpStringHash/DSiWin32 dependencies |
| `OtlComm.pas` | Removed hidden window; switched to `IOmniEvent` observers |
| `OtlTaskControl.pas` | CV-based task loop; new `ProcessMessages`/`WaitForMessage`/`COMInitialize` APIs; deprecated `Alertable`/`MsgWait` |
| `OtlThreadPool.pas` | Removed `SuspendThread`/`ResumeThread`; removed DSiWin32 |
| `OtlParallel.pas` | Removed `ForkJoin`; replaced hidden window with cross-platform observers |
| `OtlDataManager.pas` | Unified waiting with `TWaitFor` |
| `OtlBackgroundObserver.pas` | **New** — cross-platform APC/CV observer |
| `OtlOptions.inc` | Removed pre-Delphi 11 conditionals |
| `OtlEventMonitor.pas` | Removed unused DSiWin32 |
