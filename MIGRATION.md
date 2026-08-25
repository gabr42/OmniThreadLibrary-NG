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
10. Replace `CreateContainerWindowsEventObserver(handle)` with
    `CreateContainerEventObserver(CreateOmniEvent(handle, false))`, and
    `CreateContainerWindowsMessageObserver(hwnd, ...)` with
    `CreateContainerMainThreadObserver(callback)` (main-thread owners
    only). Change any `TOmniContainerObserver`-typed field holding the
    result to an interface type, `FreeAndNil` to `:= nil`, and call
    `.Shutdown` before `Detach` for a main-thread observer (see
    [Windows Message-Based Observers](#windows-message-based-observers))
11. If your code uses `IOmniCommDispatchingObserver` /
    `CreateDispatchingObserver` (`OtlComm.pas`), it's gone with no
    replacement — reconstruct it yourself (see
    [IOmniCommDispatchingObserver — Removed, No Replacement](#iomnicommdispatchingobserver--removed-no-replacement))

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

**`CreateContainerWindowsEventObserver(handle: THandle)` specifically:**
there is no `THandle`-based replacement. Wrap the existing handle in an
`IOmniEvent` first (`CreateOmniEvent(AExternalEvent: THandle; ATakeOwnership:
boolean = false): IOmniEvent`, `OtlSync.pas`), then pass that to the
platform-independent factory:

```pascal
// OTL v3
wpoCommObserver := CreateContainerWindowsEventObserver(wpoOnMessageEvent);

// OTL NG — wrap the raw handle, don't transfer ownership if the handle
// is still owned/closed elsewhere (e.g. by the code that created it)
wpoCommObserver := CreateContainerEventObserver(
  CreateOmniEvent(wpoOnMessageEvent, false));
```

Use `ATakeOwnership := true` only if you want the `IOmniEvent` to
`CloseHandle` the wrapped handle when its last reference is released —
otherwise a double-close (once by your own cleanup code, once by the
`IOmniEvent`) will raise or corrupt the handle table.

**`CreateContainerWindowsMessageObserver(hwnd, msg, wParam, lParam)`
specifically:** typically used as the "no external event supplied"
fallback — a hidden window (`AllocateHWnd`/`DSiAllocateHWnd`) posts a
window message on every container notification, and the owning code's
`WndProc` reacts by draining the queue. The hidden window binds to
*whichever thread created it*, which in practice is almost always the
thread that owns/pumps the message loop the rest of the code already
assumes — most commonly the main VCL/FMX thread. If that assumption
holds for your call site, `CreateContainerMainThreadObserver` is the
direct replacement — same "notify → drain" shape, no window needed:

```pascal
// OTL v3
wpoMessageWindow := DSiAllocateHWnd(WndProc);
wpoCommObserver := CreateContainerWindowsMessageObserver(wpoMessageWindow, WM_QUEUE_MESSAGE, 0, 0);
// ...WndProc calls ProcessMessages on WM_QUEUE_MESSAGE...

// OTL NG — main-thread owner
wpoCommObserver := CreateContainerMainThreadObserver(
  procedure begin ProcessMessages; end);
```

This drops the hidden-window machinery entirely (`AllocateHWnd`/
`DeallocateHWnd`, the `WM_QUIT`-based teardown, the custom `WndProc`).
Two things to watch:

- **It only targets the main thread.** The old hidden window could be
  created from (and thus pumped by) any thread with a message loop. If
  a call site creates its owner off the main thread while relying on
  *that* thread's own window pump, there is no direct replacement —
  route that case through `CreateContainerEventObserver` +
  `CreateOmniEvent` instead (a dedicated pump thread waiting on an
  `IOmniEvent`, independent of window messages), or move ownership to
  the main thread.
- **Console apps need `CheckSynchronize`.** Same rule as
  [Thread Pool Monitor Callbacks Need CheckSynchronize](#thread-pool-monitor-callbacks-need-checksynchronize-console-apps) —
  `TThread.ForceQueue` only runs once something pumps it.

**Two knock-on changes are usually needed at the same time** for
either factory, because both return an interface, not a class
instance (containers are interface-refcounted since v2.06 — see
[Container Observer Lifetime Is Interface-Refcounted](#container-observer-lifetime-is-interface-refcounted)):

1. Any field/variable declared as `TOmniContainerObserver` (or the
   removed `TOmniContainerWindowsEventObserver` /
   `TOmniContainerWindowsMessageObserver`) must become an interface
   type — `IOmniContainerObserver` covers both the event- and
   main-thread-observer factories if the same field can hold either
   one, depending on which branch of your code ran.
2. Any `FreeAndNil(observer)` must become `observer := nil` — you
   cannot `FreeAndNil` an interface reference; releasing the last
   reference frees the underlying object automatically. If the field
   might hold a main-thread observer, call `.Shutdown` on it (via
   `Supports(observer, IOmniContainerMainThreadObserver, obs)`) before
   `Detach`, so a callback already queued on the main thread becomes a
   no-op instead of running after your teardown starts.

---

### Container Observer Lifetime Is Interface-Refcounted

`OtlContainerObserver.pas` v2.06 made all container observers
`TInterfacedObject`-based and refcounted, so `TOmniContainerSubject`
can snapshot its observer list under a read lock and dispatch outside
the lock without holding a class reference that another thread might
free mid-dispatch. The practical effect at call sites:

- Factories (`CreateContainerEventObserver`,
  `CreateContainerMainThreadObserver`,
  `CreateContainerBackgroundObserver`, ...) return interfaces
  (`IOmniContainerObserver` or a descendant), never class instances.
- Store them in interface-typed fields, not `TOmniContainerObserver`
  (the class still exists as the base implementation, but you should
  not hold a bare class reference to an instance you didn't create
  yourself).
- Release with `observer := nil` (or just let the variable go out of
  scope), not `FreeAndNil`. `Detach` from `TOmniContainerSubject`
  before releasing your reference if the subject might otherwise be
  the last thing keeping the observer alive mid-dispatch.

---

### IOmniCommDispatchingObserver — Removed, No Replacement

Unlike the observers above, `IOmniCommDispatchingObserver` /
`CreateDispatchingObserver` (`OtlComm.pas`) were dropped from OTL NG
with no replacement and no `MIGRATION.md` entry until this one — the
only trace left in the source is a changelog line ("Implemented
TOmniMessageQueueTee and IOmniCommDispatchingObserver", v1.06, 2010).
If your code still references either name, you're on your own to
reconstruct it; there is no OTL NG equivalent to call.

In OTL v3 it was a composition of a hidden window + a
`TOmniContainerWindowsMessageObserver`, bound to whichever thread
created it, whose `WndProc` drained the target `TOmniMessageQueue` and
called classic `TObject.Dispatch` on a caller-supplied `dispatchTo`
object for each message:

```pascal
// OTL v3 (OtlComm.pas)
constructor TOmniCommDispatchingObserverImpl.Create(queue: TOmniMessageQueue; dispatchTo: TObject);
begin
  cdoDispatchWnd := DSiAllocateHWnd(WndProc);
  cdoObserver := CreateContainerWindowsMessageObserver(cdoDispatchWnd, WM_USER, 0, 0);
  cdoQueue.ContainerSubject.Attach(cdoObserver, coiNotifyOnAllInserts);
end;

procedure TOmniCommDispatchingObserverImpl.WndProc(var msg: TMessage);
begin
  if msg.msg = WM_USER then
    while cdoQueue.TryDequeue(omsg) do
      cdoDispatchTo.Dispatch(omsg);
end;
```

If the owner is reliably the main thread, port it the same way as
[`CreateContainerWindowsMessageObserver`](#windows-message-based-observers)
above: `CreateContainerMainThreadObserver`, callback drains the queue
and calls `Dispatch`.

If the owner thread is **not** guaranteed to be the main thread (the
general case — v3's hidden window worked from any thread with a
message pump, which OTL NG has no equivalent for), use
`CreateContainerBackgroundObserver` bound to the creating thread's ID
instead:

```pascal
// OTL NG — owner thread not guaranteed to be main
observer := CreateContainerBackgroundObserver(TThread.Current.ThreadID,
  procedure
  var
    omsg: TOmniMessage;
  begin
    while queue.TryDequeue(omsg) do
      dispatchTo.Dispatch(omsg);
  end);
queue.ContainerSubject.Attach(observer, coiNotifyOnAllInserts);
```

Whether this is a drop-in behaviorally depends on what kind of thread
owns it:

- **OTL task/worker owner** (the observer is created from code running
  on a task started via `CreateTask(...).Run`, e.g. inside a
  `TOmniWorker` method): delivery is automatic and needs no extra
  code. `TOmniTaskExecutor.WaitForEvent` (`OtlTaskControl.pas`) calls
  `OtlBackgroundObserver.DrainBackgroundObservers` unconditionally on
  *every* task-loop iteration — regardless of whether the wait that
  just completed was alertable, timed out, or was satisfied by a
  handle/message — so any OTL task already drains its background
  observers as a side effect of its own message loop. Latency is
  bounded by how often the loop cycles (timers, comm-channel traffic,
  etc.), not by anything you need to add.
- **Plain, non-OTL `TThread` owner** (never calls into an OTL task
  loop): delivery is *not* automatic — v3's hidden window delivered to
  any window-message pump on the owner thread, but OTL NG's background
  observer only fires via `QueueUserAPC`, which needs either an
  alertable wait or an explicit `OtlBackgroundObserver.
  DrainBackgroundObservers` call added somewhere in that thread's own
  loop.

`X:\gp\dvb\DVBDriver.Common.pas`'s only current owner
(`TDVBMixerEngine`, `dvbMixerEngine.pas`) is itself an OTL task, so it
needed no changes beyond `CreateObserver`/`DetachObserver` — don't
assume that's true for every consumer without checking what kind of
thread constructs the observer.

Also unlike v3, `IOmniContainerObserver` has no self-detaching
destructor to rely on — `observer := nil` alone does **not** detach it
from `ContainerSubject`. `Detach` explicitly before freeing the queue,
or you'll get exactly the use-after-free the observer pattern exists
to avoid. See `X:\gp\dvb\DVBDriver.Common.pas` (`CreateObserver`/
`DetachObserver`, v3.06) for a worked example, including the paired
teardown at every call site that used to say `observer := nil; //
will detach automatically`.

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

**More generally:** wherever an OTL NG API now expects an `IOmniEvent`
parameter but your existing code only has a raw `THandle` (a
`CreateEvent` result, a handle stored on some legacy object, etc.),
don't rewrite that code to create/own an `IOmniEvent` from scratch —
wrap the existing handle instead:

```pascal
function CreateOmniEvent(AExternalEvent: THandle; ATakeOwnership: boolean = false): IOmniEvent; overload;
```

`ATakeOwnership` defaults to `false`, so the wrapped `IOmniEvent` will
`WaitFor`/`SetEvent`/`Reset` through the handle without closing it —
pass `true` only if you want the `IOmniEvent` to `CloseHandle` it when
the last reference is released (and make sure nothing else still
closes that same handle, or you get a double-close). This is the same
helper used to port
[`CreateContainerWindowsEventObserver`](#windows-message-based-observers)
above; it applies to any THandle-to-IOmniEvent conversion, not just
that one call site.

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

### New: OTL_NG

`OtlOptions.inc` now unconditionally defines `OTL_NG`. If a project needs to
support both OTL v3 and OTL NG side by side (e.g. a shared unit compiled
against either library, or a transitional codebase migrating incrementally),
guard the version-specific code with `{$IFDEF OTL_NG} ... {$ELSE} ... {$ENDIF}`.
OTL v3's `OtlOptions.inc` does not define `OTL_NG`, so the same source
compiles correctly against either library.

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
