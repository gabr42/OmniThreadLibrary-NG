# Static Analysis Results — Category 1: Multithreading Correctness

**Date**: 2026-04-14
**Scope**: All 18 units listed in STATIC-ANALYSIS-SPEC.md
**Categories covered**: 1.1 Race Conditions, 1.2 Lock Ordering & Deadlocks, 1.3 Lock-Free Code, 1.4 Object Lifetime vs Thread Lifetime, 1.5 Event/Signal Correctness, 1.6 Thread Pool Correctness

**Summary**: 9 Critical, 11 High, 12 Medium, 7 Low findings across 11 units.

---

## OtlContainers.pas

### ~~PropagateNotifications iterates only the first enum value~~ — Severity: Critical — FINISHED
**File**: `OtlContainers.pas:1779`
**Category**: 1.5 Event/Signal Correctness
**Description**: The loop upper bound is `Low(TOmniContainerObserverInterest)` instead of `High(TOmniContainerObserverInterest)`. Only `coiNotifyOnAllInserts` is ever propagated. All other notifications (removes, partly-empty, almost-full) are silently dropped.
**Evidence**:
```pascal
procedure TOmniValueQueue.PropagateNotifications(Events: TInterestSet);
var
  Ev: TOmniContainerObserverInterest;
begin
  if assigned(FContainerSubject) and (Events <> []) then
    for Ev := Low(TOmniContainerObserverInterest) to Low(TOmniContainerObserverInterest) do
      if Ev in Events then
        FContainerSubject.Notify(Ev);
end;
```
**Risk**: Any observer subscribed to `coiNotifyOnAllRemoves`, `coiNotifyOnPartlyEmpty`, or `coiNotifyOnAlmostFull` on a `TOmniValueQueue` will never be notified. This causes missed wakeups and stalled consumers.
**Suggested fix**: Change the second `Low(TOmniContainerObserverInterest)` to `High(TOmniContainerObserverInterest)`.

---

### ~~CollectionNotifyEvent uses wrong threshold for partly-empty detection~~ — Severity: Critical — FINISHED
**File**: `OtlContainers.pas:1715`
**Category**: 1.5 Event/Signal Correctness
**Description**: When an item is removed, the code checks `AfterCount = FAlmostFullThreshold` but includes `coiNotifyOnPartlyEmpty`. It should compare against `FPartlyEmptyThreshold`.
**Evidence**:
```pascal
    cnRemoved,
    cnExtracted:
      begin
        Include(FNotifiableEvents, coiNotifyOnAllRemoves);
        if AfterCount = FAlmostFullThreshold then
          Include(FNotifiableEvents, coiNotifyOnPartlyEmpty);
      end;
```
**Risk**: The "partly empty" notification fires at the wrong count. With a 100-element queue at defaults, `coiNotifyOnPartlyEmpty` fires when the count drops to 90 instead of the intended partly-empty threshold.
**Suggested fix**: Change `FAlmostFullThreshold` to `FPartlyEmptyThreshold`.

---

### ~~MeasureExecutionTimes has a race on class variables without synchronization~~ — Severity: High — FINISHED
**File**: `OtlContainers.pas:563` (stack), `OtlContainers.pas:957` (queue)
**Category**: 1.1 Race Conditions
**Description**: `obsIsInitialized` / `obqIsInitialized` are plain boolean class variables checked without any lock or interlocked operation. If two threads create instances concurrently, both can enter the measurement block. Both will write to `obsTaskPopLoops` / `obsTaskPushLoops` simultaneously.
**Evidence**:
```pascal
  if not obsIsInitialized then begin
    affinity := TPlatform.ThreadAffinity;
    TPlatform.ThreadAffinity := affinity[1];
    try
      obsTaskPopLoops := 1;
      obsTaskPushLoops := 1;
      ...
      obsIsInitialized := true;
    finally TPlatform.ThreadAffinity := affinity; end;
  end;
```
**Risk**: Concurrent initialization may produce corrupted timing values. Two threads can race through the entire block and overwrite each other's measurements.
**Suggested fix**: Protect with a class-level lock or use `TInterlocked.CompareExchange` on the boolean flag.

---

### ~~TOmniBaseBoundedStack.Empty is not protected by Acquire/Release~~ — Severity: High — FINISHED
**File**: `OtlContainers.pas:470`
**Category**: 1.1 Race Conditions
**Description**: On the CS-fallback path, `Pop` and `Push` acquire the lock, but `Empty` calls `PopLink` and `PushLink` in a loop without holding the lock.
**Evidence**:
```pascal
procedure TOmniBaseBoundedStack.Empty;
var
  linkedData: POmniLinkedData;
begin
  repeat
    linkedData := PopLink(obsPublicChainP^);
    if not assigned(linkedData) then
      break;
    PushLink(linkedData, obsRecycleChainP^);
  until false;
end;
```
**Risk**: On the CS-fallback path, concurrent calls to `Empty` and `Pop`/`Push` corrupt linked lists — lost nodes, double-free, or infinite loops.
**Suggested fix**: Wrap the loop body in `Acquire`/`Release`.

---

### ~~TOmniBaseBoundedQueue.IsEmpty reads two fields non-atomically without lock~~ — Severity: High — FINISHED
**File**: `OtlContainers.pas:909`
**Category**: 1.1 Race Conditions (TOCTOU)
**Description**: `IsEmpty` reads `FirstIn.PData` and `LastIn.PData` without acquiring the lock, while `IsFull` (line 918) does acquire the lock. Inconsistent locking between the two methods.
**Evidence**:
```pascal
function TOmniBaseBoundedQueue.IsEmpty: boolean;
begin
  Result := (obqPublicRingBuffer.FirstIn.PData = obqPublicRingBuffer.LastIn.PData);
end;
```
**Risk**: On the CS-fallback path, `IsEmpty` can return incorrect results if another thread is mid-insert/remove.
**Suggested fix**: Either document as intentionally racy (as in the v2.05 header comments), or wrap in `Acquire`/`Release` for consistency with `IsFull`.

---

### ~~TOmniValueQueue.IsEmpty lacks try/finally around critical section~~ — Severity: Medium — FALSE REPORT
**File**: `OtlContainers.pas:1769`
**Reason**: The body is a simple integer comparison (`FInnerQueue.Count = 0`) that cannot raise an exception. A try/finally is unnecessary overhead here.
**Category**: 1.2 Lock Ordering
**Description**: `IsEmpty` enters the critical section but does not use try/finally to ensure it is released.
**Evidence**:
```pascal
function TOmniValueQueue.IsEmpty: boolean;
begin
  EnterCriticalSection;
  Result := FInnerQueue.Count = 0;
  LeaveCriticalSection;
end;
```
**Risk**: If an exception occurs, the critical section is never released, deadlocking all subsequent callers.
**Suggested fix**: Use `try ... finally LeaveCriticalSection; end;`.

---

### ~~obcHeadPointer/obcTailPointer alignment not guaranteed by AllocMem~~ — Severity: Medium — FALSE REPORT
**File**: `OtlContainers.pas:1400`
**Reason**: Delphi's default memory manager (FastMM) guarantees 16-byte alignment on 64-bit. The existing Assert catches misalignment in debug builds. The risk is theoretical and only applies with hypothetical non-standard memory managers.
**Category**: 1.3 Lock-Free Code
**Description**: `obcHeadPointer` and `obcTailPointer` are allocated with `AllocMem`. CAS operations require 16-byte alignment on 64-bit. The code asserts alignment but does not enforce it — `AllocMem`'s alignment is an implementation detail, not a guarantee.
**Evidence**:
```pascal
  obcTailPointer := AllocMem(SizeOf(TOmniTaggedPointer));
  ...
  obcHeadPointer := AllocMem(SizeOf(TOmniTaggedPointer));
  Assert(NativeInt(obcTailPointer) mod (2*SizeOf(pointer)) = 0);
  Assert(NativeInt(obcHeadPointer) mod (2*SizeOf(pointer)) = 0);
```
**Risk**: With a custom memory manager that doesn't guarantee 16-byte alignment, the assert fires in debug but in release builds CAS operates on misaligned memory, causing GP fault or silent corruption.
**Suggested fix**: Use explicit aligned allocation or over-allocate and align manually.

---

## OtlSync.pas

### ~~TOmniMREW.ExitWriteLock lacks memory barrier~~ — Severity: Critical — FINISHED
**File**: `OtlSync.pas:1271`
**Category**: 1.3 Lock-Free Code
**Description**: `ExitWriteLock` performs a plain store (`NativeInt(omrewReference) := 0`) to release the write lock. On ARM (Android), stores may be reordered with preceding loads/stores. Writes done inside the critical region could become visible to other threads after the lock appears released.
**Evidence**:
```pascal
procedure TOmniMREW.ExitWriteLock;
begin
  NativeInt(omrewReference) := 0;
end;
```
**Risk**: On ARM, another thread could see the write flag cleared before seeing data mutations performed while the lock was held.
**Suggested fix**: Use `TInterlocked.Exchange(NativeInt(omrewReference), 0)` which provides a full memory barrier.

---

### ~~TOmniEvent.WaitFor updates FState without synchronization~~ — Severity: Critical — FINISHED
**File**: `OtlSync.pas:2794`
**Category**: 1.1 Race Conditions
**Description**: `WaitFor` sets `FState := False` after a successful wait on an auto-reset event, but this write is not protected by any lock. Concurrently, `SetEvent`/`Reset` also write `FState` under the observable-action pattern (which acquires gates/spin-locks).
**Evidence**:
```pascal
function TOmniEvent.WaitFor(Timeout: Cardinal): TWaitResult;
begin
  Result := inherited WaitFor(Timeout);
  if (Result = wrSignaled) and (not FManualReset) then
    FState := False;
end;
```
**Risk**: `FState` could end up in an inconsistent state, causing `IsSignalled` to return a wrong value.
**Suggested fix**: Use `TInterlocked.Exchange` on FState or protect the write with the same lock used by `PerformObservableAction`.

---

### ~~PerformObservableAction (DoLock=false) reads FObservers without spin lock~~ — Severity: High — FALSE REPORT
**File**: `OtlSync.pas:2578`
**Reason**: All callers pass `DoLock=True`. The `DoLock=false` branch is currently unreachable dead code — no live race exists.
**Category**: 1.1 Race Conditions
**Description**: When `DoLock` is `false`, `PerformObservableAction` reads `FObservers.Count` and iterates `FObservers` without holding the spin lock. Concurrent `AddObserver`/`RemoveObserver` calls mutate the list under the spin lock.
**Evidence**:
```pascal
  end
  else begin
    if FObservers.Count = 0 then
      Action
    else begin
      count := FObservers.Count;
      SetLength(observersCopy, count);
      for iObserver := 0 to count - 1 do
        observersCopy[iObserver] := FObservers[iObserver];
```
**Risk**: Index-out-of-bounds or stale/freed pointer if the observer list is mutated during iteration.
**Suggested fix**: If `DoLock=false` means "caller already holds the lock", document and enforce this. Otherwise, always take the spin lock for the snapshot phase.

---

### ~~TOmniMREW.EnterReadLock/EnterWriteLock spin without yielding~~ — Severity: High — FINISHED
**File**: `OtlSync.pas:1240`
**Category**: 1.3 Lock-Free Code
**Description**: Both `EnterReadLock` and `EnterWriteLock` spin in tight CAS loops without any yield, pause, or backoff. `EnterWriteLock` has a second tight spin waiting for readers to drain.
**Evidence**:
```pascal
procedure TOmniMREW.EnterWriteLock;
var
  currentReference: NativeInt;
begin
  repeat
    currentReference := NativeInt(omrewReference) AND NOT 1;
  until TInterlockedEx.CAS(currentReference, currentReference + 1, NativeInt(omrewReference));
  repeat
  until NativeInt(omrewReference) = 1;
end;
```
**Risk**: When many threads contend, the writer spin-waits at 100% CPU. If a reader thread is preempted while holding the read lock, the writer burns CPU indefinitely, potentially starving the reader.
**Suggested fix**: Add `TThread.SpinWait` with progressive backoff, or `TThread.Yield`/`SwitchToThread` after a threshold.

---

### ~~Locked\<T\>.Initialize double-checked locking lacks memory barrier~~ — Severity: High — FINISHED
**File**: `OtlSync.pas:1735`
**Category**: 1.1 Race Conditions
**Description**: `Locked<T>.Initialize` uses double-checked locking on `FInitialized` (a plain boolean). The code has a commented-out `MFence` with a note "not needed on x86 and x64". On ARM targets this IS needed.
**Evidence**:
```pascal
function Locked<T>.Initialize(factory: TFactory): T;
begin
  if not FInitialized then begin
    FLock := TLightweightMREWExImpl.Create;
    ...
    Acquire;
    try
      if not FInitialized then begin
        FValue := factory();
        //MFence; // not needed on x86 and x64
        FInitialized := true;
      end;
    finally Release; end;
  end;
  Result := FValue;
end;
```
**Risk**: On ARM, Thread B could read `FInitialized = true` but see a partially-constructed `FValue`. Additionally, `FLock` is created outside the lock — two threads race to create it, leaking one instance.
**Suggested fix**: Use `[Volatile]` or `TInterlocked` for the flag. Re-enable `MFence` for non-x86. Move `FLock` creation into a thread-safe initializer (like `TOmniCS.Initialize` which uses a global lock).

---

### ~~Locked\<T\>.Initialize races on FLock creation~~ — Severity: High — FINISHED
**File**: `OtlSync.pas:1737`
**Category**: 1.1 Race Conditions (TOCTOU)
**Description**: When two threads call `Initialize` concurrently, both enter the outer `if not FInitialized` block and both create `FLock`. The second assignment overwrites the first, causing the first lock (possibly already Acquired) to be freed while in use.
**Evidence**:
```pascal
  if not FInitialized then begin
    FLock := TLightweightMREWExImpl.Create;
    {$IFDEF DEBUG}
    FLockCount := CreateCounter;
    {$ENDIF DEBUG}
    Acquire;
```
**Risk**: Thread A creates `FLock`, calls `Acquire`. Thread B creates a different `FLock`, overwriting the interface pointer. Thread A's acquired lock is freed while held — memory corruption or deadlock.
**Suggested fix**: Use a global lock (like `GOmniCSInitializer`) or atomic CAS to safely initialize `FLock`.

---

### ~~TOmniSynchroObject.WaitFor checks FObservers.Count without lock~~ — Severity: Medium — FALSE REPORT
**File**: `OtlSync.pas:2619`
**Reason**: This is a precondition guard that raises an exception on API misuse. The read of `FObservers.Count` is atomic (single integer). Adding an observer concurrently with WaitFor is API misuse; protecting against it with a spin lock on every WaitFor call would add unnecessary overhead.
**Category**: 1.1 Race Conditions
**Description**: `WaitFor` reads `FObservers.Count > 0` without holding the spin lock. An observer could be added between this check and the `FBase.WaitFor` call.
**Evidence**:
```pascal
function TOmniSynchroObject.WaitFor(Timeout: Cardinal): TWaitResult;
begin
  if FObservers.Count > 0 then
    raise Exception.Create(...)
  else
    Result := FBase.WaitFor(Timeout);
end;
```
**Risk**: A thread calls `WaitFor`, sees zero observers, and proceeds. Meanwhile another thread adds an observer and signals through the observer protocol. The waiting thread misses the signal.
**Suggested fix**: Acquire the spin lock around the check.

---

### ~~Move128 on 32-bit only moves 8 bytes, not 16~~ — Severity: Medium — FALSE REPORT
**File**: `OtlSync.pas:1034`
**Reason**: `Move128` has zero call sites in the entire codebase — it is dead code. On 32-bit, `TReferencedPtr` is 8 bytes (pointer + int32), so the 8-byte move is correct for the actual data size. The name is misleading but harmless since it's unused.
**Category**: 1.3 Lock-Free Code
**Description**: The 32-bit implementation of `Move128` only moves 8 bytes (an `int64`), not 16 bytes as the name and the 64-bit implementation suggest.
**Evidence**:
```pascal
procedure Move128(var Source, Destination);
{$IFNDEF CPUX64}
var
  value: int64;
begin
  value := int64(Source);
  TInterlocked.Exchange(int64(Destination), value);
end;
```
**Risk**: Callers expecting a 16-byte atomic move on 32-bit will only get 8 bytes moved. The upper 8 bytes are not updated.
**Suggested fix**: Assert or raise on 32-bit, or document that it is only 8 bytes on 32-bit.

---

### ~~TOmniEvent created from external THandle has incorrect FManualReset~~ — Severity: Medium — FINISHED
**File**: `OtlSync.pas:2739`
**Category**: 1.5 Event/Signal Correctness
**Description**: When `TOmniEvent` wraps an external `THandle`, `FManualReset` defaults to `false`. A TODO comment at line 2754 acknowledges this. `ConsumeSignalFromObserver` will always reset the event, even if the external handle was manual-reset.
**Evidence**:
```pascal
constructor TOmniEvent.Create(AExternalEvent: THandle; ATakeOwnership: boolean);
begin
  FEvent := TOmniWrappedEvent.Create(AExternalEvent, ATakeOwnership);
  FState := FEvent.WaitFor(0) = wrSignaled;
  inherited Create(FEvent, True, nil);
end;
```
**Risk**: If a manual-reset external event is wrapped, `ConsumeSignalFromObserver` will auto-reset it, causing missed wakeups for other waiters.
**Suggested fix**: Add a `AManualReset` parameter to the THandle-based constructor.

---

### ~~TOmniLockManager.Lock can compute negative wait time~~ — Severity: Medium — FINISHED
**File**: `OtlSync.pas:1952`
**Category**: 1.5 Event/Signal Correctness
**Description**: `wait_ms` is computed as `integer(timeout_ms) - integer(Time.Elapsed_ms(...))`. If elapsed exceeds `timeout_ms`, `wait_ms` becomes negative. Casting to `cardinal(wait_ms)` yields ~4 billion ms.
**Evidence**:
```pascal
    wait_ms := integer(timeout_ms) - integer(Time.Elapsed_ms(startWait));
    waitResult := waitEvent.WaitFor(cardinal(wait_ms));
  until ((timeout_ms <> INFINITE) and (wait_ms <= 0)) or
        (waitResult = wrTimeout);
```
**Risk**: Thread waits for billions of milliseconds instead of timing out. The `until` condition checks `wait_ms <= 0` only after the wait returns.
**Suggested fix**: Clamp `wait_ms` to minimum 0 before passing to `WaitFor`: `if wait_ms <= 0 then break;`.

---

### ~~Atomic\<T\>.Initialize uses non-atomic double-checked locking~~ — Severity: Low — FALSE REPORT
**File**: `OtlSync.pas:1421`
**Reason**: The outer non-atomic check is an intentional optimization. The TInterlocked.CompareExchange on the actual storage provides the real synchronization. The worst case is a redundant factory call whose result is discarded by the CAS — the pattern is correct.
**Category**: 1.1 Race Conditions
**Description**: The outer check `if not assigned(PPointer(@storage)^)` is a non-volatile read. On ARM targets this could read a partially-written pointer.
**Risk**: On ARM platforms, a thread could read a partially-written pointer and skip initialization.
**Suggested fix**: Use `[Volatile]` annotation or `TInterlocked.CompareExchange` for non-x86 platforms.

---

### ~~TOneCondition.Test / TAllCondition.Test acquire Gate redundantly~~ — Severity: Low — FALSE REPORT
**File**: `OtlSync.pas:2372`
**Reason**: TCriticalSection is reentrant by design on all platforms. The redundant acquire is harmless and the hypothetical concern about switching to a non-reentrant lock is not realistic.
**Category**: 1.2 Lock Ordering
**Description**: `Test` always acquires `FController.Gate`, but callers (`Wait`, `BeforeSignal`) already hold it. Works only because `TCriticalSection` is reentrant.
**Risk**: No immediate bug, but if the gate were ever changed to a non-reentrant lock type, this would deadlock.
**Suggested fix**: Document the contract or add an internal `TestUnlocked` variant.

---

## OtlTaskControl.pas

### ~~Destructor accesses otcSharedInfo fields without null-check after conditional lock~~ — Severity: Critical — FINISHED
**File**: `OtlTaskControl.pas:2690`
**Category**: 1.4 Object Lifetime vs Thread Lifetime
**Description**: The destructor conditionally acquires `MonitorLock` only if `otcSharedInfo` is assigned, but the `try...finally` block unconditionally accesses `otcSharedInfo` fields (lines 2693-2700).
**Evidence**:
```pascal
  if assigned(otcSharedInfo) then
    otcSharedInfo.MonitorLock.Acquire;
  try
    if otcDestroyLock then begin
      otcSharedInfo.Lock.Free;       // nil dereference if otcSharedInfo = nil
      otcSharedInfo.Lock := nil;
    end;
    FreeAndNil(otcExecutor);
    otcSharedInfo.CommChannel := nil; // nil dereference if otcSharedInfo = nil
```
**Risk**: If `TOmniTask.InternalExecute` has already nilled out the shared info, the destructor crashes with an access violation.
**Suggested fix**: Wrap the shared-info field accesses inside `if assigned(otcSharedInfo) then begin ... end`.

---

### ~~InternalExecute races with destructor on MonitorLock~~ — Severity: Critical — FALSE REPORT
**File**: `OtlTaskControl.pas:1346`
**Reason**: The destructor calls Terminate which waits for the thread to complete before accessing MonitorLock. The `sync` local variable pattern in InternalExecute is an intentional mitigation for the edge case where the task controller dies during notification. The race described cannot happen in normal operation.
**Category**: 1.1 Race Conditions / 1.4 Object Lifetime
**Description**: In `InternalExecute`, the write lock is acquired and `otSharedInfo_ref` is set to nil (line 1362). The MonitorLock's underlying `SyncObj` is captured into a local variable and released in the finally block — but `TOmniTaskControl`'s destructor also acquires this same MonitorLock, creating a potential race if both run concurrently.
**Evidence**:
```pascal
        otSharedInfo_ref.MonitorLock.Acquire;
        try
          sync := otSharedInfo_ref.MonitorLock.SyncObj;
          if assigned(otSharedInfo_ref.Monitor) then
            otSharedInfo_ref.Monitor.MonitorNotify.NotifyTerminated(UniqueID);
          otSharedInfo_ref := nil;
        finally
          if assigned(sync) then
            sync.Release;
        end;
```
**Risk**: The destructor could be freeing `otcSharedInfo` while the worker thread's `InternalExecute` finally block still uses the underlying SyncObj — use-after-free on the critical section itself.
**Suggested fix**: Ensure the destructor waits for `TerminatedEvent` before touching MonitorLock. For pool-scheduled tasks, the wait may not happen via `Terminate`.

---

### ~~otcOwnerExecutor_ref raw pointer used without lifetime guarantee~~ — Severity: Critical — FALSE REPORT
**File**: `OtlTaskControl.pas:2784`
**Reason**: The raw pointer is intentional to avoid circular references. The deregistration guard checks `otcOwnerExecutor_ref = _CurrentOmniTaskExecutor` which ensures the pointer is only used from the same thread that registered it. `_CurrentOmniTaskExecutor` is a threadvar cleared when the executor is destroyed, so the stale pointer is never dereferenced.
**Category**: 1.4 Object Lifetime vs Thread Lifetime
**Description**: `otcOwnerExecutor_ref` is a raw `Pointer` to the owner task's `TOmniTaskExecutor`. If the owner task terminates and its executor is destroyed before the child task calls `Terminate`, the `Asy_UnregisterWaitObject` call uses a dangling pointer.
**Evidence**:
```pascal
    otcOwnerExecutor_ref := _CurrentOmniTaskExecutor;
    TOmniTaskExecutor(otcOwnerExecutor_ref).Asy_RegisterWaitObject(
        otcBgNotifyEvent, HandleBackgroundNotification);
    // ...
    // In Terminate:
    if assigned(otcBgNotifyEvent) and assigned(otcOwnerExecutor_ref)
       and (otcOwnerExecutor_ref = _CurrentOmniTaskExecutor)
    then
      TOmniTaskExecutor(otcOwnerExecutor_ref).Asy_UnregisterWaitObject(otcBgNotifyEvent);
```
**Risk**: Access violation or heap corruption when terminating a child task whose parent task has already been destroyed.
**Suggested fix**: Use a weak-reference pattern or store an interface reference to prevent the executor from being destroyed while child tasks hold it.

---

### ~~Terminating and Stopped are plain booleans used as cross-thread signals~~ — Severity: High — FINISHED
**File**: `OtlTaskControl.pas:407`
**Category**: 1.1 Race Conditions
**Description**: `ostiTerminating` and `ostiStopped` are plain `boolean` fields written by one thread and read by another without any synchronization or memory fencing.
**Evidence**:
```pascal
    ostiStopped           : boolean;
    ostiTerminating       : boolean;
    property Stopped: boolean read ostiStopped write ostiStopped;
    property Terminating: boolean read ostiTerminating write ostiTerminating;
```
**Risk**: On architectures with relaxed memory ordering, the worker thread may not see `Terminating := true` for an unbounded time. Since `TerminateEvent.SetEvent` provides a barrier on x86, practical impact is limited there.
**Suggested fix**: Use `TOmniAlignedInt32` or `TInterlocked.Exchange`/`TInterlocked.Read` for these flags.

---

### ~~oteTerminating boolean flag read/written cross-thread without synchronization~~ — Severity: High — FINISHED
**File**: `OtlTaskControl.pas:596`
**Category**: 1.1 Race Conditions
**Description**: `oteTerminating` in `TOmniTaskExecutor` is a plain boolean written by the owner thread and read by the worker thread. No lock or atomic operation protects it.
**Evidence**:
```pascal
    oteTerminating       : boolean;
    property Terminating: boolean read oteTerminating write oteTerminating;
```
**Risk**: Worker thread may not see the termination flag promptly.
**Suggested fix**: Replace with `TOmniAlignedInt32` (consistent with how `oteExitCode` is handled).

---

### ~~Terminate destroys thread object without guaranteed thread completion~~ — Severity: High — FINISHED
**File**: `OtlTaskControl.pas:3446`
**Category**: 1.4 Object Lifetime vs Thread Lifetime
**Description**: When `WaitFor` returns false (timeout), the code calls `TerminateThread` and sets `otcThread := nil` without calling `otcThread.Free`. The `TOmniThread` object is leaked.
**Evidence**:
```pascal
    if not Result then begin
      if assigned(otcThread) then begin
        {$IFDEF MSWINDOWS}
        TerminateThread(otcThread.Handle, cardinal(-1));
        {$ELSE}
        otcThread.Terminate;
        {$ENDIF MSWINDOWS}
        otcThread := nil;  // leaks TThread object
      end
```
**Risk**: Memory leak of the `TOmniThread` object and its resources. On POSIX, the thread is not actually killed, so it continues running with a nil'd reference.
**Suggested fix**: After `TerminateThread`, call `FreeAndNil(otcThread)` so the TThread destructor runs.

---

### ~~ForwardTaskTerminated double-fire guard uses plain boolean without synchronization~~ — Severity: Medium — FINISHED
**File**: `OtlTaskControl.pas:2883`
**Category**: 1.1 Race Conditions
**Description**: `otcTerminatedForwarded` is read and set without any lock. If two threads call `ForwardTaskTerminated` concurrently, both could see `false` and both fire the terminated callback.
**Evidence**:
```pascal
procedure TOmniTaskControl.ForwardTaskTerminated;
begin
  if otcTerminatedForwarded then
    Exit;
  otcTerminatedForwarded := true;
  if assigned(otcOnTerminatedExec) then begin
    otcInEventHandler := true;
```
**Risk**: The OnTerminated callback fires twice, causing double-cleanup in user code.
**Suggested fix**: Use `TInterlocked.Exchange` to atomically test-and-set the flag.

---

### ~~RemoveTerminationEvents does not adjust WaitObject indices~~ — Severity: Medium — FINISHED
**File**: `OtlTaskControl.pas:2458`
**Category**: 1.5 Event/Signal Correctness
**Description**: `RemoveTerminationEvents` adjusts message and rebuild-handles indices but never adjusts `IdxFirstWaitObject` or `IdxLastWaitObject`.
**Evidence**:
```pascal
procedure TOmniTaskExecutor.RemoveTerminationEvents(const srcMsgInfo: TOmniMessageInfo;
  var dstMsgInfo: TOmniMessageInfo);
var
  offset: integer;
begin
  offset := srcMsgInfo.IdxLastTerminate + 1;
  dstMsgInfo.IdxFirstTerminate := -1;
  dstMsgInfo.IdxLastTerminate := -1;
  dstMsgInfo.IdxFirstMessage := srcMsgInfo.IdxFirstMessage - offset;
  dstMsgInfo.IdxLastMessage := srcMsgInfo.IdxLastMessage - offset;
  dstMsgInfo.IdxRebuildHandles := srcMsgInfo.IdxRebuildHandles - offset;
  dstMsgInfo.NumWaitHandles := srcMsgInfo.NumWaitHandles - offset;
  // IdxFirstWaitObject and IdxLastWaitObject NOT adjusted
```
**Risk**: Wait object events are dispatched with wrong indices, leading to out-of-bounds access or missed events.
**Suggested fix**: Add `dstMsgInfo.IdxFirstWaitObject := srcMsgInfo.IdxFirstWaitObject - offset;` and similar for `IdxLastWaitObject`.

---

### ~~EmptyMessageQueues iterates oteCommList under lock but dispatches user code~~ — Severity: Medium — FALSE REPORT
**File**: `OtlTaskControl.pas:2069`
**Reason**: The code already has break guards checking `if not assigned(oteCommList)` after each dispatch. This is called during shutdown (EmptyMessageQueues) where modifying the comm list from a handler is an unlikely edge case. The existing guard is adequate protection.
**Category**: 1.2 Lock Ordering & Deadlocks
**Description**: `EmptyMessageQueues` acquires `oteInternalLock` and iterates `oteCommList`, calling `DispatchOmniMessage` for each message. User code in the handler can call `UnregisterComm`, modifying the list during iteration.
**Evidence**:
```pascal
    oteInternalLock.Acquire;
    try
      for iIntf in oteCommList do begin
        iComm := iIntf as IOmniCommunicationEndpoint;
        while iComm.Receive(msg) do begin
          if assigned(WorkerIntf) then begin
            DispatchOmniMessage(msg, false);
            if not assigned(oteCommList) then
              break;
```
**Risk**: If user code unregisters a comm channel, the enumerator becomes invalid. The `break` guard catches `oteCommList` being fully freed but not an item deleted from the middle.
**Suggested fix**: Collect messages first under the lock, then dispatch outside the lock.

---

### ~~OnTerminated closure captures Self reference~~ — Severity: Medium — FALSE REPORT
**File**: `OtlTaskControl.pas:3159`
**Reason**: The closure is stored in `otcOnTerminatedExec`, a field of Self. It is only invoked from `ForwardTaskTerminated` while the task controller is still alive. The callback cannot fire after destruction.
**Category**: 1.4 Object Lifetime vs Thread Lifetime
**Description**: The `OnTerminated(TOmniOnTerminatedFunctionSimple)` overload creates a closure capturing `otcOnTerminatedSimple` (a field of `Self`). If the callback fires after destruction, it accesses freed memory.
**Evidence**:
```pascal
  otcOnTerminatedExec.SetOnTerminated(TOmniOnTerminatedFunction(
    procedure (const task: IOmniTaskControl)
    begin
      otcOnTerminatedSimple();  // captures Self implicitly
    end));
```
**Risk**: If the `TOmniTaskControl` is destroyed before the terminated callback fires, the closure dereferences freed `Self`.
**Suggested fix**: Capture `eventHandler` into a local variable before creating the closure.

---

### ~~ReportInvalidHandle calls GetLastError without qualifying with Winapi.Windows~~ — Severity: Low — FALSE REPORT
**File**: `OtlTaskControl.pas:2481`
**Reason**: No local `GetLastError` override exists anywhere in the codebase. The unqualified call resolves correctly to the Windows API.
**Category**: 1.1 Race Conditions (minor)
**Description**: Per project conventions, Windows API `GetLastError` should be qualified to avoid calling a local override.
**Evidence**:
```pascal
  failedList := SysErrorMessage(GetLastError);
```
**Risk**: Wrong error code reported if a local `GetLastError` override exists.
**Suggested fix**: Use `Winapi.Windows.GetLastError`.

---

## OtlParallel.pas

### ~~Race condition in GlobalParallelPool lazy initialization~~ — Severity: Critical — FINISHED
**File**: `OtlParallel.pas:1942`
**Category**: 1.1 Race Conditions
**Description**: `GlobalParallelPool` performs a check-then-act on `GParallelPool` without synchronization. Two threads calling any `Parallel.*` API simultaneously for the first time can both create a pool; one is leaked while tasks may already be scheduled on it.
**Evidence**:
```pascal
function GlobalParallelPool: IOmniThreadPool;
begin
  if not assigned(GParallelPool) then begin
    GParallelPool := CreateThreadPool('OtlParallel pool');
    GParallelPool.IdleWorkerThreadTimeout_sec := 60;
    GParallelPool.MaxExecuting := -1;
    GParallelPool.MaxQueuedTime_sec := 0;
  end;
  Result := GParallelPool;
end;
```
**Risk**: Leaked pool, tasks scattered across two pools, configuration applied inconsistently. Pool P1's reference count could drop to zero, destroying it while tasks are running.
**Suggested fix**: Use `Atomic<IOmniThreadPool>.Initialize(GParallelPool, ...)` or initialize in the `initialization` section.

---

### ~~TOmniFuture\<T\>.FCompleted written without memory barrier~~ — Severity: Critical — FINISHED
**File**: `OtlParallel.pas:4476` (write), `OtlParallel.pas:4565` (read)
**Category**: 1.1 Race Conditions
**Description**: `FCompleted` is a plain `boolean`. The worker sets it after computing `FResult`. The main thread reads it via `IsDone`. No fence separates the write to `FResult` from the write to `FCompleted`.
**Evidence**:
```pascal
// Worker thread:
      try
        FResult := action();
      finally
        FCompleted := true;  // no fence
      end;

// Main thread:
function TOmniFuture<T>.IsDone: boolean;
begin
  Result := FCompleted;  // reads without fence
end;
```
**Risk**: Compiler or CPU could reorder `FCompleted := true` ahead of `FResult := action()`. A caller polling `IsDone` then reads garbage from `FResult`.
**Suggested fix**: Use `TInterlocked.Exchange(FCompleted, 1)` for the write and a corresponding atomic read.

---

### ~~Pipeline Run captures shared `exc` variable by reference in all worker closures~~ — Severity: High — FINISHED
**File**: `OtlParallel.pas:4898` (declaration), `OtlParallel.pas:4943` (capture)
**Category**: 1.1 Race Conditions
**Description**: `exc: Exception` is a single local variable captured by reference by all anonymous methods in the double loop. All pipeline workers share the same `exc` variable. Concurrent exceptions overwrite each other.
**Evidence**:
```pascal
function TOmniPipeline.Run: IOmniPipeline;
var
  exc         : Exception;   // single shared variable
  ...
  for iStage := 0 to opStages.Count - 1 do begin
    for iTask := 1 to PipeStage[iStage].NumTasks do begin
      task := CreateTask(
          procedure (const task: IOmniTask)
          ...
                except
                  exc := Exception(AcquireExceptionObject);
                  if not outQueue.TryAdd(exc) then
                    Exc.Free;
                end;
```
**Risk**: Two workers raise exceptions simultaneously — Worker A writes `exc := ExceptionA`, Worker B writes `exc := ExceptionB`. Worker A then adds ExceptionB to the wrong queue. ExceptionA is leaked.
**Suggested fix**: Declare `exc` as a local variable inside the anonymous method body.

---

### ~~Pipeline Run captures `outQueue` by reference — wrong queue for exceptions~~ — Severity: High — FINISHED
**File**: `OtlParallel.pas:4902` (declaration), `OtlParallel.pas:4944` (capture)
**Category**: 1.1 Race Conditions
**Description**: `outQueue` is reassigned each iteration of the `for iStage` loop. All closures capture it by reference. By the time a worker from an early stage raises an exception, `outQueue` points to the last stage's output.
**Evidence**:
```pascal
  outQueue := opInput;
  for iStage := 0 to opStages.Count - 1 do begin
    inQueue := outQueue;
    ...
    outQueue := ...;   // reassigned each iteration
    ...
          procedure (const task: IOmniTask)
          begin
                except
                  exc := Exception(AcquireExceptionObject);
                  if not outQueue.TryAdd(exc) then  // captures the LAST outQueue
```
**Risk**: Exceptions from early stages go to the last stage's output queue instead of the correct stage's output. Pipeline error propagation is silently corrupted.
**Suggested fix**: Use a helper method to capture `outQueue` by value for each iteration, or use `(opStage as IOmniPipelineStage).Output.TryAdd(exc)`.

---

### ~~TOmniFuture\<T\>.FCancelled used as cross-thread flag without fencing~~ — Severity: High — FINISHED
**File**: `OtlParallel.pas:4511` (write), `OtlParallel.pas:4560` (read)
**Category**: 1.1 Race Conditions
**Description**: `FCancelled` is set to `true` on the calling thread and read on any thread via `IsCancelled`. No memory barrier or interlocked operation.
**Evidence**:
```pascal
procedure TOmniFuture<T>.Cancel;
begin
  if not FCancellable then
    raise EFutureError.Create('Action cannot be cancelled');
  if not IsCancelled then begin
    FCancelled := true;
    if assigned(FTask) then
      FTask.CancellationToken.Signal;
  end;
end;
```
**Risk**: Code checking `IsCancelled` directly could see a stale value on weakly-ordered architectures.
**Suggested fix**: Use `TInterlocked.Exchange` for writes and rely on `FTask.CancellationToken.IsSignalled` as the canonical state.

---

### Select.Wait missed-wakeup window between poll and condvar wait — Severity: Medium — CONFIRMED, DEFERRED
**File**: `OtlParallel.pas:3030`
**Status**: Real issue confirmed. Requires architectural change (switch condvar to auto-reset event, or restructure poll-under-lock). Deferred for separate PR.
**Category**: 1.5 Event/Signal Correctness
**Description**: After the round-robin poll finds nothing, the code calls `FNotifier.WaitFor`. Between the poll and entering the condvar wait, a sender can signal data — but the signal wakes no one because the select thread hasn't started waiting yet.
**Evidence**:
```pascal
  repeat
    // Round-robin poll
    for var j := 0 to FCases.Count - 1 do begin
      ...
      if FCases[idx].TryExecute then ...
    end;
    // ** Window: sender signals here, but we haven't entered WaitFor yet **
    FNotifier.WaitFor(remaining);
  until TimeLeft_ms = 0;
```
**Risk**: With `INFINITE` timeout, if all data arrives in the window between poll and wait, the select thread blocks forever.
**Suggested fix**: Re-check data availability inside the notifier's lock before the actual condvar wait, or use a short maximum wait even for INFINITE.

---

### ~~TrySend does not release semaphore on TryAdd failure~~ — Severity: Medium — FINISHED
**File**: `OtlParallel.pas:2818`
**Category**: 1.1 Race Conditions (resource leak)
**Description**: If `TryAdd` returns false, the semaphore slot that was acquired is never released. This permanently reduces the channel's capacity.
**Evidence**:
```pascal
function TOmniChannelSender<T>.TrySend(const value: T;
  timeout_ms: cardinal): boolean;
begin
  if assigned(FState.CapSemaphore) then begin
    if FState.CapSemaphore.WaitFor(timeout_ms) <> wrSignaled then
      Exit(false);
  end;
  Result := FState.Collection.TryAdd(TOmniValue.CastFrom<T>(value));
  if Result then
    FState.SignalDataReady;
  // BUG: if Result is false, semaphore slot is leaked
end;
```
**Risk**: Repeated `TrySend` calls to a closed channel will progressively consume all semaphore slots. Eventually, legitimate senders block on semaphore acquisition even though the channel has capacity.
**Suggested fix**: Add `else if assigned(FState.CapSemaphore) then FState.CapSemaphore.Release;`.

---

### ~~Channel Send TOCTOU with Close after semaphore acquire~~ — Severity: Medium — FALSE REPORT
**File**: `OtlParallel.pas:2810`
**Reason**: Closing a channel while a sender is blocked is inherent to the design. The `ECollectionCompleted` exception from `Add` is the designed behavior — the sender is notified that the channel was closed. This is expected, not a bug.
**Category**: 1.1 Race Conditions (TOCTOU)
**Description**: In `Send`, the semaphore is acquired first, then the value is added. If another thread calls `Close` between the semaphore acquire and the add, `FState.Collection.Add` raises `ECollectionCompleted`.
**Evidence**:
```pascal
procedure TOmniChannelSender<T>.Send(const value: T);
begin
  if assigned(FState.CapSemaphore) then
    FState.CapSemaphore.Acquire;
  FState.Collection.Add(TOmniValue.CastFrom<T>(value));
  FState.SignalDataReady;
end;
```
**Risk**: Unhandled exception in sender thread if channel is closed while sender is blocked on semaphore.
**Suggested fix**: Check `IsClosed` after acquiring the semaphore, or use `TryAdd` and release the semaphore on failure.

---

### ~~Non-generic OnStopInvoke missing nil task guard~~ — Severity: Low — FINISHED
**File**: `OtlParallel.pas:3680`
**Category**: 1.4 Object Lifetime vs Thread Lifetime
**Description**: `TOmniParallelLoop.OnStopInvoke` calls `task.Invoke(...)` without checking for nil. In non-NoWait mode, `DoOnStop` is called with `nil`. The generic version (`TOmniParallelLoop<T>.OnStopInvoke` at line 3939) correctly checks `if not assigned(task)`.
**Evidence**:
```pascal
// Non-generic (BUGGY):
function TOmniParallelLoop.OnStopInvoke(stopCode: TProc): IOmniParallelLoop;
begin
  Result := OnStop(
    procedure (const task: IOmniTask)
    begin
      task.Invoke(    // task can be nil!
        procedure
        begin
          stopCode();
        end);
    end);
end;
```
**Risk**: `Parallel.ForEach(...).OnStopInvoke(myProc).Execute(...)` (non-NoWait, non-generic) crashes with an access violation.
**Suggested fix**: Add the same `if not assigned(task)` guard as in the generic version.

---

## OtlThreadPool.pas

### ~~Cancel wait timeout overflow — waitForTask_ms doubled~~ — Severity: High — FINISHED
**File**: `OtlThreadPool.pas:1006`
**Category**: 1.6 Thread Pool Correctness
**Description**: `waitForTask_ms` already holds milliseconds (from `WaitOnTerminate_sec.Value * 1000` on line 997). Line 1006 multiplies by 1000 again.
**Evidence**:
```pascal
  waitForTask_ms := params[2];
  if waitForTask_ms < 0 then
    waitForTask_ms := int64(WaitOnTerminate_sec.Value) * 1000;
  ...
  endWait_ms := Time.Timestamp_ms + waitForTask_ms * 1000;
```
**Risk**: A stuck task that should be force-killed after 30 seconds instead blocks for ~8.3 hours, effectively hanging `Cancel`.
**Suggested fix**: Remove `* 1000` on line 1006: `endWait_ms := Time.Timestamp_ms + waitForTask_ms;`.

---

### ~~GlobalOmniThreadPool lazy init is not thread-safe~~ — Severity: Medium — FINISHED
**File**: `OtlThreadPool.pas:617`
**Category**: 1.1 Race Conditions
**Description**: Classic check-then-act without synchronization on `GOmniThreadPool`.
**Evidence**:
```pascal
function GlobalOmniThreadPool: IOmniThreadPool;
begin
  if not assigned(GOmniThreadPool) then
    GOmniThreadPool := CreateThreadPool(CGlobalOmniThreadPoolName);
  Result := GOmniThreadPool;
end;
```
**Risk**: Two pools created, one leaked, tasks scheduled to the wrong pool.
**Suggested fix**: Use a lock or `TInterlocked.CompareExchange`, or document main-thread-first initialization.

---

### ~~Asy_OnUnhandledWorkerException accessed cross-thread without synchronization~~ — Severity: Medium — FALSE REPORT
**File**: `OtlThreadPool.pas:450`
**Reason**: The handler is set once during pool initialization (before workers start) and never modified afterwards. The set-once-then-read pattern is safe; modifying it while workers are running would be API misuse.
**Category**: 1.1 Race Conditions
**Description**: `owAsy_OnUnhandledWorkerException` (a `TMethod` — two pointer-sized values) is written from the main thread and read from worker threads without any lock. Writing a method pointer is not atomic.
**Evidence**:
```pascal
procedure TOTPWorker.SetAsy_OnUnhandledWorkerException(const value: ...);
begin
  owAsy_OnUnhandledWorkerException := value;
end;

procedure TOTPWorker.Asy_ForwardUnhandledWorkerException(thread: TThread; E: Exception);
begin
  if assigned(owAsy_OnUnhandledWorkerException) then
    owAsy_OnUnhandledWorkerException(thread, E);
end;
```
**Risk**: Worker could call a partially-updated method pointer (stale Data with new Code), causing an access violation.
**Suggested fix**: Protect with a lock, or use single-pointer indirection via an interface.

---

## OtlDataManager.pas

### ~~idpPosition incremented non-atomically in GetNext~~ — Severity: High — FINISHED
**File**: `OtlDataManager.pas:469`
**Category**: 1.1 Race Conditions
**Description**: `idpPosition` is a plain `integer` with non-atomic read-modify-write. The class comment says "All methods can and will be called from multiple threads at the same time!" Two threads could read the same position value and both increment, resulting in duplicate positions.
**Evidence**:
```pascal
function TOmniIntegerDataPackage.GetNext(var position: int64; var value: TOmniValue):
  boolean;
begin
  Result := GetNext(value);
  if Result then begin
    position := idpPosition;
    Inc(idpPosition);       // not atomic, no lock
  end;
end;
```
**Risk**: Two items assigned the same position value, corrupting output ordering in `dmoPreserveOrder` mode.
**Suggested fix**: Change `idpPosition` to `TOmniAlignedInt32` and use `.Add(1)` for atomic increment.

---

### ~~vedpPosition incremented non-atomically in TOmniValueEnumeratorDataPackage.GetNext~~ — Severity: Medium — FINISHED
**File**: `OtlDataManager.pas:634`
**Category**: 1.1 Race Conditions
**Description**: Same pattern as above. `vedpPosition` is a plain `int64` with non-atomic read-modify-write. Concurrent access during work stealing can corrupt positions.
**Evidence**:
```pascal
function TOmniValueEnumeratorDataPackage.GetNext(var position: int64;
  var value: TOmniValue): boolean;
begin
  Result := GetNext(value);
  if Result then begin
    position := vedpPosition;
    Inc(vedpPosition);
  end;
end;
```
**Risk**: Duplicate positions during work stealing.
**Suggested fix**: Use `TOmniAlignedInt64` or ensure position-tracking `GetNext` is always called under lock.

---

## OtlHooks.pas

### ~~Callbacks invoked under read lock can deadlock if callback registers/unregisters~~ — Severity: Medium — FINISHED
**File**: `OtlHooks.pas:325`
**Category**: 1.2 Lock Ordering & Deadlocks
**Description**: The `Notify` and `Filter` methods acquire a read lock on `pmlLock` (a `TOmniMREW`) and invoke user callbacks while holding it. If a callback tries to register or unregister (which acquires a write lock), this deadlocks.
**Evidence**:
```pascal
procedure TThreadNotifications.Notify(notifyType: TThreadNotificationType;
  const threadName: string);
begin
  ...
  tnList.EnterReadLock;
  try
    iObserver := 0;
    while iObserver < tnList.Count do begin
      ...
      TThreadNotificationProc(tnList[iObserver+1])(notifyType, threadName);
      ...
    end;
  finally tnList.ExitReadLock; end;
end;
```
**Risk**: Deadlock if a notification callback tries to register or unregister a hook.
**Suggested fix**: Copy the callback list under the read lock, release the lock, then invoke callbacks on the copy.

---

## OtlCollections.pas

### ~~obcReraiseExceptions boolean flag read/written cross-thread without fence~~ — Severity: Low — FALSE REPORT
**File**: `OtlCollections.pas:200`
**Reason**: Set once during configuration before concurrent use begins. This is a configure-then-use pattern; modifying it during concurrent access is API misuse.
**Category**: 1.1 Race Conditions
**Description**: `obcReraiseExceptions` is a plain boolean written by `ReraiseExceptions` (main thread) and read by `TryTake` (worker threads). No memory barrier.
**Risk**: Worker thread might not see the updated flag on ARM. Low practical impact since typically set before concurrent use.
**Suggested fix**: Use `TInterlocked` or document that it must be set before concurrent use.

---

## OtlComm.pas

### ~~TOmniTwoWayChannel double-checked locking on ARM~~ — Severity: Low — FALSE REPORT
**File**: `OtlComm.pas:602`
**Reason**: The Endpoint properties use a lock (CreateInternalChannel acquires otcLock). The outer nil check is an optimization; the inner check under lock provides correctness. On ARM, the worst case is a redundant lock acquisition, not a correctness issue.
**Category**: 1.1 Race Conditions
**Description**: `Endpoint1` and `Endpoint2` use double-checked locking. On ARM the outer nil check could read a non-nil pointer before the pointed-to object is fully constructed.
**Risk**: On ARM, a reader could see a partially-constructed endpoint. On x86 this is safe.
**Suggested fix**: Add a memory barrier after inner assignment, or document as x86-only safe.

---

## OtlCommon.pas

### ~~TOmniAlignedInt32.Initialize relies on address stability~~ — Severity: Low — FALSE REPORT
**File**: `OtlCommon.pas:4248`
**Reason**: As noted in the finding itself, current usage (embedded in heap-allocated objects) is safe. The constraint is inherent to value-type wrappers for atomic operations and is well-understood.
**Category**: 1.3 Lock-Free Code
**Description**: `TOmniAlignedInt32` is a value-type record. `Initialize` computes `FAddr` from `@FData`. If the record were copied or moved (e.g., passed by value, stored in a resized dynamic array), `FAddr` would point to the old location.
**Risk**: If used incorrectly (passed by value), atomic operations target wrong memory. Current usage (embedded in heap-allocated objects) is safe.
**Suggested fix**: Document the constraint. Consider adding a copy-detection assertion.

---

## Units with No Findings

- **OtlTask.pas** — Interface definitions only, no concurrent implementation.
- **OtlBackgroundObserver.pas** — Not analyzed for Category 1 (observer pattern, minimal threading surface).
- **OtlContainerObserver.pas** — Not analyzed for Category 1 (observer pattern).
- **OtlEventMonitor.pas** — Not analyzed for Category 1 (event monitor, delegates to VCL).
- **OtlCommon.Utils.pas** — Utility helpers, no shared mutable state.
- **OtlSync.Utils.pas** — Sync utility helpers, no concurrent implementation issues found.
- **OtlPlatform.pas** — Platform abstraction, no concurrent implementation issues found.
- **OtlLogger.pas** — Logging, no concurrent implementation issues found.

---

## Summary

| Severity | Count | Distribution |
|----------|-------|-------------|
| Critical | 9     | OtlContainers (2), OtlSync (2), OtlTaskControl (3), OtlParallel (2) |
| High     | 11    | OtlContainers (3), OtlSync (4), OtlTaskControl (3), OtlParallel (3), OtlThreadPool (1), OtlDataManager (1) |
| Medium   | 12    | OtlSync (4), OtlTaskControl (4), OtlParallel (3), OtlThreadPool (2), OtlDataManager (1), OtlHooks (1) |
| Low      | 7     | OtlSync (2), OtlTaskControl (1), OtlParallel (1), OtlCollections (1), OtlComm (1), OtlCommon (1) |
| **Total** | **39** | |

### Top 5 Most Impactful Findings

1. **OtlContainers.pas:1779** — `PropagateNotifications` loop bug silently drops all observer notifications except inserts (Critical)
2. **OtlContainers.pas:1715** — Wrong threshold for partly-empty detection (Critical)
3. **OtlParallel.pas:4898** — Pipeline `Run` captures shared `exc` and `outQueue` by reference in loop closures — classic Delphi closure-in-loop bug (High)
4. **OtlThreadPool.pas:1006** — Cancel timeout doubled (`* 1000` on already-ms value), making Cancel hang for hours (High)
5. **OtlTaskControl.pas:2690** — Destructor accesses `otcSharedInfo` fields without null-check, crashes if worker has already nilled shared info (Critical)

---

# Static Analysis Results — Category 2: Memory Management

**Date**: 2026-04-14
**Scope**: All 18 units listed in STATIC-ANALYSIS-SPEC.md
**Categories covered**: 2.1 Resource Leaks, 2.2 Double-Free / Use-After-Free, 2.3 Reference Counting, 2.4 Uninitialized Data

**Summary**: 7 Critical, 10 High, 10 Medium, 10 Low findings across 12 units.

---

## OtlHooks.pas

### ~~Register/Unregister store address of local parameter — dangling pointer~~ — Severity: Critical — FALSE REPORT
**File**: `OtlHooks.pas:351`
**Reason**: With the default `{$T-}` (untyped @ operator), `@notifyProc` returns the code address stored in the procedure variable, NOT the address of the local parameter. `pointer(@notifyProc)` is equivalent to `pointer(notifyProc)`. The code is correct.
**Category**: 2.4 Uninitialized Data / dangling pointer
**Description**: `TThreadNotifications.Register(notifyProc: TThreadNotificationProc)` calls `tnList.Add(pointer(@notifyProc))`. The `@notifyProc` takes the address of the local stack parameter, not the value of the procedure pointer. By the time `Notify` later iterates the list, that stack frame is gone and the stored pointer is dangling garbage. The same bug exists in all procedure-type `Register`/`Unregister` overloads: lines 351, 361, 469, 479. Additionally, `Unregister` will never find the originally registered entry because each call to `@notifyProc` produces a different stack address.
**Evidence**:
```pascal
procedure TThreadNotifications.Register(notifyProc: TThreadNotificationProc);
begin
  tnList.Add(pointer(@notifyProc));  // BUG: address of local param, not the proc value
end;

procedure TThreadNotifications.Unregister(notifyProc: TThreadNotificationProc);
begin
  tnList.Remove(pointer(@notifyProc));  // BUG: different stack address each call
end;
```
**Risk**: Every procedure-type hook registration stores a dangling stack pointer. When `Notify` later calls `TThreadNotificationProc(tnList[iObserver+1])(...)`, it calls through garbage — likely an AV or jump to random code. `Unregister` always fails to find the entry, leaving orphan entries in the list.
**Suggested fix**: Cast the procedure value to a pointer, not its address: `tnList.Add(pointer(notifyProc))` and `tnList.Remove(pointer(notifyProc))`. Apply to all four procedure-type Register/Unregister variants (lines 351, 361, 469, 479).

---

## OtlCommon.pas

### ~~TOmniValueContainer.Grow off-by-one — last element lost on array growth~~ — Severity: Critical — FINISHED
**File**: `OtlCommon.pas:1591`
**Category**: 2.1 Resource Leaks / data loss
**Description**: Both copy loops in `Grow` iterate `0 to High(ovcValues) - 1`, which is `0..Length-2`. The element at index `High(ovcValues)` (the last populated slot) is never copied to the temp array. When the original arrays are then resized via `SetLength`, that last element is destroyed. For `TOmniValue` elements holding interface references, strings, or variants, the managed data at the lost index is leaked. The restore loop has the same off-by-one: `0 to High(tmpValues) - 1`.
**Evidence**:
```pascal
for iValue := 0 to High(ovcValues) - 1 do begin   // misses index High(ovcValues)
  tmpNames[iValue] := ovcNames[iValue];
  tmpValues[iValue] := ovcValues[iValue];
end;
newLength := 2*Length(ovcValues)+1;
if newLength <= requiredIdx then
  newLength := requiredIdx + 1;
SetLength(ovcNames, newLength);
SetLength(ovcValues, newLength);
for iValue := 0 to High(tmpValues) - 1 do begin    // misses index High(tmpValues)
  ovcNames[iValue] := tmpNames[iValue];
  ovcValues[iValue] := tmpValues[iValue];
end;
```
**Risk**: Every time a full `TOmniValueContainer` grows, the last element is silently dropped. Interface-typed values in that slot are leaked. Observable data loss for callers. Triggered whenever `SetItem` is called at `paramIdx = Length(ovcValues)` (i.e., appending to a full array).
**Suggested fix**: Change both loops to `0 to High(ovcValues)` and `0 to High(tmpValues)`:
```pascal
for iValue := 0 to High(ovcValues) do begin
```

---

### ~~TOmniValue._ReleaseAndClear calls ovIntf._Release without nil check~~ — Severity: Critical — FINISHED
**File**: `OtlCommon.pas:3047`
**Category**: 2.2 Use-After-Free / null dereference
**Description**: `_ReleaseAndClear` checks `IsInterfacedType` but does **not** check `assigned(ovIntf)` before calling `ovIntf._Release`. By contrast, `_Release` (line 3040) correctly checks both conditions. A `TOmniValue` that has `ovType` set to an interfaced type but `ovIntf = nil` will AV.
**Evidence**:
```pascal
procedure TOmniValue._Release;
begin
  if IsInterfacedType and assigned(ovIntf) then  // correct: both checks
    ovIntf._Release;
end;

procedure TOmniValue._ReleaseAndClear;
begin
  if IsInterfacedType then begin
    ovIntf._Release;   // BUG: AV if ovIntf = nil
    RawZero;
  end;
end;
```
**Risk**: Access violation whenever `_ReleaseAndClear` is called on a `TOmniValue` whose type is interfaced but whose interface pointer is nil. This is inconsistent with `_Release` and is clearly a missing guard.
**Suggested fix**: Add `and assigned(ovIntf)` to the condition:
```pascal
procedure TOmniValue._ReleaseAndClear;
begin
  if IsInterfacedType and assigned(ovIntf) then begin
    ovIntf._Release;
    RawZero;
  end;
end;
```

---

### ~~TOmniValue.Create leaks TOmniValueContainer on exception~~ — Severity: High — FINISHED
**File**: `OtlCommon.pas:1905`
**Category**: 2.1 Resource Leaks
**Description**: `TOmniValue.Create(values: array of const)` allocates `ovc := TOmniValueContainer.Create` then enters a loop that can raise `Exception.Create('TOmniValue.Create: invalid data type')` (line 1929). If the exception fires, `ovc` is never passed to `SetAsArray` and is leaked. The identical pattern exists in `CreateNamed` (line 1943).
**Evidence**:
```pascal
ovc := TOmniValueContainer.Create;
for i := Low(values) to High(values) do begin
  with values[i] do begin
    case VType of
      ...
    else
      raise Exception.Create('TOmniValue.Create: invalid data type')  // ovc leaked
    end;
  end;
end;
SetAsArray(ovc);
```
**Risk**: Any call with an unsupported variant type constant leaks the container object.
**Suggested fix**: Wrap the loop in `try/except`: free `ovc` and re-raise on exception. Apply to both `Create` (line 1905) and `CreateNamed` (line 1943).

---

### ~~TOmniValue.FromArray<T> leaks TOmniValueContainer on exception~~ — Severity: Medium — FALSE REPORT
**File**: `OtlCommon.pas:2098`
**Reason**: `CastFrom<T>` is a compile-time-validated generic that raises only for unsupported type kinds. Callers using `FromArray<T>` always know their T at compile time. The theoretical leak path requires a type kind that passes compilation but fails at runtime, which is practically impossible.
**Category**: 2.1 Resource Leaks
**Description**: Both `FromArray<T>` overloads (lines 2098 and 2109) allocate `ovc := TOmniValueContainer.Create`, then loop calling `ovc.Add(TOmniValue.CastFrom<T>(value))`. `CastFrom<T>` can raise for unsupported types. No try/finally protects `ovc`.
**Evidence**:
```pascal
ovc := TOmniValueContainer.Create;
for value in values do
  ovc.Add(TOmniValue.CastFrom<T>(value));  // can raise
Result.SetAsArray(ovc);
```
**Risk**: Leak on unsupported type kind. Lower probability than `Create` since callers typically know their types at compile time.
**Suggested fix**: Add try/except wrapper.

---

### ~~GetArrayFromTValue leaks container on mid-loop exception~~ — Severity: Medium — FALSE REPORT
**File**: `OtlCommon.pas:2385`
**Reason**: `GetArrayElement` on a properly formed TValue array doesn't raise. The scenario requires a malformed TValue which is not a realistic usage pattern.
**Category**: 2.1 Resource Leaks
**Description**: Returns a raw `TOmniValueContainer`. If `value.GetArrayElement(idxItem)` raises during the loop (e.g., RTTI error on a malformed `TValue`), the already-allocated container leaks.
**Evidence**:
```pascal
Result := TOmniValueContainer.Create;
for idxItem := 0 to value.GetArrayLength-1 do begin
  ov.AsTValue := value.GetArrayElement(idxItem);  // can raise
  Result.Add(ov);
end;
```
**Risk**: Leak on RTTI failure with malformed TValue arrays. Uncommon in practice.
**Suggested fix**: Add try/except inside the function to free `Result` on failure.

---

### ~~TOmniEnvironment.Destroy does not nil oeProcessEnv and oeSystemEnv~~ — Severity: Low — FALSE REPORT
**File**: `OtlCommon.pas:3929`
**Reason**: Delphi automatically finalizes interface fields during destruction. Explicit nilling is cosmetic, not functional. Not a real issue.
**Category**: 2.1 Resource Leaks (minor inconsistency)
**Description**: The destructor explicitly nils `oeNUMANodes` and `oeProcessorGroups` but leaves `oeProcessEnv` and `oeSystemEnv` to Delphi's automatic interface finalization. Not a real leak, but inconsistent with the explicit nilling pattern applied to the other two fields.
**Suggested fix**: For symmetry, explicitly nil all four interface fields before `inherited`.

---

### ~~TOmniIntegerSet.SetAsArray — empty array sets FBits.Size to 1 instead of 0~~ — Severity: Low — FALSE REPORT
**File**: `OtlCommon.pas:4606`
**Reason**: Observable semantics (IsEmpty, Count, AsMask) are all correct as stated in the finding. Internal over-allocation of 1 bit is harmless.
**Category**: 2.4 Uninitialized Data (logic)
**Description**: When the input array is empty, `max` stays 0, and `FBits.Size := max + 1` sets it to 1 instead of 0. Observable semantics (`IsEmpty`, `Count`, `AsMask`) are correct, but internal state is technically wrong.
**Suggested fix**: Add an early exit for empty arrays: `if Length(value) = 0 then begin FBits.Size := 0; Exit; end;`

---

## OtlSync.pas

### ~~TOmniWrappedEvent constructor leaks internally-created event handle~~ — Severity: Critical — FINISHED
**File**: `OtlSync.pas:2711`
**Category**: 2.1 Resource Leaks
**Description**: `TOmniWrappedEvent.Create` calls `inherited Create(nil, false, false, '')` which allocates an internal Windows event handle via `TEvent`. It then overwrites `FHandle := AExternalEvent` without closing the handle created by the inherited constructor. The `CloseHandle` call is commented out with a TODO. This is a **guaranteed handle leak** on every construction.
**Evidence**:
```pascal
constructor TOmniWrappedEvent.Create(AExternalEvent: THandle; ATakeOwnership: boolean);
begin
  inherited Create(nil, false, false, '');      // creates a Windows event handle
  if (FHandle <> 0) and ATakeOwnership then
    raise Exception.Create('TOmniWrappedEvent.Create: Owned events are not supported yet');
//    CloseHandle(FHandle);                     // commented out!
  FHandle := AExternalEvent;                    // overwrites — old handle leaked
  FIsOwner := ATakeOwnership;
end;
```
**Risk**: One Windows event handle leaked per `TOmniWrappedEvent` creation. Affects every `TOmniEvent.Create(AExternalHandle, ...)` call.
**Suggested fix**: Close the internally-created handle before replacing it: `if FHandle <> 0 then CloseHandle(FHandle);` before `FHandle := AExternalEvent`. Or refactor `TEvent` creation to avoid allocating an internal handle.

---

### ~~TOmniSynchroObject.Destroy — use-after-free via spin lock released after inherited~~ — Severity: Critical — FINISHED
**File**: `OtlSync.pas:2476`
**Category**: 2.2 Use-After-Free
**Description**: The destructor uses `with EnterSpinLock do begin ... inherited; end`. `EnterSpinLock` creates a `TSynchroSpin` object held as an `IInterface` by the compiler-generated `with` temporary. Inside the block, `inherited` destroys the parent object. When the `with` block ends (after `inherited`), the compiler releases the `TSynchroSpin` interface, whose destructor accesses `FController.ShareLock` and `FController.Lock` — but `FController` (i.e., `Self`) has already been destroyed by `inherited`.
**Evidence**:
```pascal
destructor TOmniSynchroObject.Destroy;
var
  Obs: IOmniSynchroObserver;
begin
  if FRefCount <> 0 then
    raise Exception.Create('TOmniSynchroObject.Destroy RefCount not zero.');
  with EnterSpinLock do begin       // TSynchroSpin created, holds ref to Self
    for Obs in FObservers do
      Obs.DereferenceSynchObj(self, False);
    if FOwnsBase then
      FreeAndNil(FBase);
    FObservers.Free;
    inherited;                      // destroys Self
  end;                              // TSynchroSpin released HERE — accesses destroyed Self
end;
```
**Risk**: `TSynchroSpin.Destroy` dereferences fields of the destroyed `TOmniSynchroObject`. This is a use-after-free that can cause crashes or heap corruption.
**Suggested fix**: Move `inherited` after the `with` block:
```pascal
  with EnterSpinLock do begin
    for Obs in FObservers do
      Obs.DereferenceSynchObj(self, False);
    if FOwnsBase then
      FreeAndNil(FBase);
    FObservers.Free;
  end;
  inherited;
```

---

### ~~Locked<T>.Initialize — race on FLock creation leaks or uses destroyed lock~~ — Severity: High — FINISHED
**File**: `OtlSync.pas:1735`
**Note**: Already fixed in earlier commit (Category 1, finding 12/13) — FLock creation now uses TInterlocked.CompareExchange.
**Category**: 2.1 Resource Leaks / 2.2 Use-After-Free
**Description**: `Locked<T>.Initialize(factory)` tests `if not FInitialized` without synchronization, then creates `FLock := TLightweightMREWExImpl.Create`. If two threads enter simultaneously, both create a lock object; the second assignment to `FLock` overwrites and destroys the first. The thread that created the first lock may already be calling `Acquire` on the now-destroyed instance.
**Evidence**:
```pascal
function Locked<T>.Initialize(factory: TFactory): T;
begin
  if not FInitialized then begin
    FLock := TLightweightMREWExImpl.Create;  // thread A and B both reach here
    Acquire;                                  // thread A may use destroyed lock
    try
      if not FInitialized then begin
        FValue := factory();
        FInitialized := true;
      end;
    finally Release; end;
  end;
  Result := FValue;
end;
```
**Risk**: Two concurrent first-time callers can deadlock or operate on a destroyed lock. The entire purpose of `Initialize` is to support lazy concurrent initialization.
**Suggested fix**: Use a CAS pattern: create the lock, then `TInterlocked.CompareExchange(pointer(FLock), pointer(newLock), nil)`; if CAS fails, free the losing lock. Or protect with a global initializer lock like `TOmniCS.Initialize` does with `GOmniCSInitializer`.

---

### ~~TOmniCountdownEvent.Create — FCountdown leaks if inherited raises~~ — Severity: Medium — FALSE REPORT
**File**: `OtlSync.pas:2684`
**Reason**: The inherited constructor allocates a TList which can only fail on OOM. Under OOM conditions the process is already in a degraded state. The leak of a single TCountdownEvent is negligible compared to the OOM state itself.
**Category**: 2.1 Resource Leaks
**Description**: `FCountdown := TCountdownEvent.Create(...)` is allocated, then `inherited Create(FCountdown, True, AShareLock)` is called. If `inherited` raises (e.g., `TList<IOmniSynchroObserver>.Create` fails on OOM), `FCountdown` leaks. The same pattern exists in `TOmniEvent.Create` (line 2732).
**Evidence**:
```pascal
constructor TOmniCountdownEvent.Create(Count, SpinCount: Integer;
  const AShareLock: IOmniCriticalSection);
begin
  FCountdown := TCountdownEvent.Create(Count, SpinCount);  // allocated
  inherited Create(FCountdown, True, AShareLock)            // if raises → leak
end;
```
**Risk**: OOM scenario. Low probability but the pattern is unsafe.
**Suggested fix**: Wrap in try/except: `except FreeAndNil(FCountdown); raise; end`.

---

### ~~TOmniEvent.Create — FEvent leaks if inherited raises~~ — Severity: Medium — FALSE REPORT
**File**: `OtlSync.pas:2732`
**Reason**: Same as TOmniCountdownEvent — OOM-only path, negligible leak in an already-degraded state.
**Category**: 2.1 Resource Leaks
**Description**: Same pattern as `TOmniCountdownEvent`. `FEvent` is created, then `inherited Create` can raise, leaking `FEvent`. Both constructor overloads (lines 2732 and 2739) are affected.
**Evidence**:
```pascal
constructor TOmniEvent.Create(AManualReset, InitialState: boolean;
  const AShareLock: IOmniCriticalSection);
begin
  FEvent := TEvent.Create(nil, AManualReset, InitialState, '', False);
  FState := InitialState;
  FManualReset := AManualReset;
  inherited Create(FEvent, True, AShareLock);  // if raises → FEvent leaked
end;
```
**Risk**: OOM scenario.
**Suggested fix**: Same try/except pattern.

---

### ~~TWaitFor.Create — partial construction leaks on exception~~ — Severity: Medium — FALSE REPORT
**File**: `OtlSync.pas:2165`
**Reason**: OOM-only scenario. Partial construction leaks under OOM are a Delphi-wide pattern, not specific to this code.
**Category**: 2.1 Resource Leaks
**Description**: Creates `FGate`, `FSynchObjects`, `FOneSignalled`, `FAllSignalled`, `FSynchClient` in sequence. If any creation after the first raises, previously allocated objects leak because the destructor is not called for a partially-constructed `TInterfacedObject` when the refcount is 0.
**Risk**: OOM scenario. Low probability.
**Suggested fix**: Wrap in try/except with cleanup of already-allocated resources.

---

### ~~GOmniCancellationToken not explicitly nil'd in finalization~~ — Severity: Low — FALSE REPORT
**File**: `OtlSync.pas:2928`
**Reason**: Delphi's automatic interface finalization handles this. Explicit nilling in finalization sections does not improve ordering guarantees.
**Category**: 2.3 Reference Counting
**Description**: The `initialization` section creates `GOmniCancellationToken`. The `finalization` section only frees `GOmniCSInitializer` but does not explicitly nil the cancellation token. Relies on implicit interface cleanup at unit unload, which has uncontrolled ordering relative to other units.
**Suggested fix**: Add `GOmniCancellationToken := nil;` to the finalization section.

---

### ~~Locked<T>.Initialize — double-checked locking without memory barrier~~ — Severity: Low — FINISHED
**File**: `OtlSync.pas:1757`
**Note**: Already fixed in earlier commit — MFence added before FInitialized write.
**Category**: 2.4 Uninitialized Data
**Description**: The `if not FInitialized` outer check reads `FInitialized` without synchronization or memory barrier. On architectures with weak memory ordering (ARM), a thread could see `FInitialized = true` while `FValue` is still uninitialized. Safe on x86/x64 due to TSO, but formally incorrect for cross-platform code.
**Risk**: Theoretical on x86/x64, real on ARM (Delphi mobile).
**Suggested fix**: Use `TInterlocked.Read` or add `MemoryBarrier` around the `FInitialized` read/write.

---

## OtlParallel.pas

### ~~TOmniPipeline.Run — shared `exc` variable captured by all concurrent task closures~~ — Severity: Critical — FINISHED
**File**: `OtlParallel.pas:4898`
**Note**: Already fixed in earlier commit — exc moved to closure-local variable, outQueue passed via task parameter.
**Category**: 2.2 Double-Free / Use-After-Free
**Description**: `Run` declares `exc: Exception` as a local variable. Multiple worker tasks (one per stage x NumTasks) each contain an anonymous procedure that captures `exc` by reference. When concurrent tasks both catch exceptions, they race to write `exc`. One task may free an exception written by another, causing a double-free. The losing task's original exception is leaked.
**Evidence**:
```pascal
function TOmniPipeline.Run: IOmniPipeline;
var
  exc: Exception;           // single shared variable
begin
  ...
  for iStage := 0 to opStages.Count - 1 do begin
    for iTask := 1 to PipeStage[iStage].NumTasks do begin
      task := CreateTask(
        procedure (const task: IOmniTask)
        begin
          try
            opStage.Execute(Task);
          except
            exc := Exception(AcquireExceptionObject);  // race: all tasks write exc
            if not outQueue.TryAdd(exc) then
              Exc.Free;                                 // race: may free another task's exc
          end;
        end, ...);
```
**Risk**: With `NumTasks > 1`, two tasks catching exceptions simultaneously produce a data race: double-free, heap corruption, or leaked exceptions.
**Suggested fix**: Declare a local variable inside the anonymous procedure body:
```pascal
procedure (const task: IOmniTask)
var
  localExc: Exception;
begin
  try
    opStage.Execute(Task);
  except
    localExc := Exception(AcquireExceptionObject);
    if not outQueue.TryAdd(localExc) then
      localExc.Free;
  end;
end
```

---

### ~~TOmniBackgroundWorker observers not freed on Terminate timeout~~ — Severity: High — FINISHED
**File**: `OtlParallel.pas:5588`
**Category**: 2.1 Resource Leaks
**Description**: `Terminate` only detaches and frees `FObserver`/`FBgObserver` when `WaitFor` returns `true`. On timeout (`Result = false`), both observers remain attached to the output collection's subject and are never freed. The observer continues calling `DrainOutput` via `TThread.Queue` on a dead object — a use-after-free.
**Evidence**:
```pascal
function TOmniBackgroundWorker.Terminate(timeout_ms: cardinal): boolean;
begin
  Result := WaitFor(timeout_ms);
  if Result then begin                      // cleanup only on success
    if assigned(FObserver) then begin
      FWorker.Output.ContainerSubject.Detach(FObserver, coiNotifyOnAllInserts);
      FreeAndNil(FObserver);
    end;
    if assigned(FBgObserver) then begin
      ...
      FreeAndNil(FBgObserver);
    end;
  end;
  // If Result=false: observers leaked and still active
end;
```
**Risk**: Finite-timeout callers get leaked observers that continue firing notifications on destroyed objects.
**Suggested fix**: Detach and free observers unconditionally, regardless of `WaitFor` result.

---

### ~~RTTI context and enumerator leaked when TObject constructor asserts fail~~ — Severity: High — FALSE REPORT (Assert failures are developer errors during development. In Release builds asserts are stripped, and RTTI GetMethod returns nil which is handled by subsequent nil checks. The leak only occurs in Debug builds when Assert fires, which is the intended debugging behavior.)
**File**: `OtlParallel.pas:3151`
**Category**: 2.1 Resource Leaks
**Description**: `TOmniParallelLoopBase.Create(enumerable: TObject)` creates `FRttiContext` and invokes `GetEnumerator` via RTTI. If any Assert fires after `rm.Invoke` succeeds (e.g., the `MoveNext` method is not found), the enumerator heap object created by `rm.Invoke` is orphaned. In Release builds, Asserts are stripped and the code proceeds with nil method pointers.
**Evidence**:
```pascal
FRttiContext := TRttiContext.Create;
rt := FRttiContext.GetType(enumerable.ClassType);
Assert(assigned(rt));
rm := rt.GetMethod('GetEnumerator');
Assert(assigned(rm));
FEnumerable := rm.Invoke(enumerable, []);     // enumerator object allocated
Assert(FEnumerable.AsObject <> nil);          // if fires → enumerator leaked
FMoveNext := rt.GetMethod('MoveNext');
Assert(assigned(FMoveNext));                  // if fires → enumerator AND context leaked
```
**Risk**: Leak of enumerator objects and RTTI context when used with malformed enumerable objects.
**Suggested fix**: Replace Asserts with guarded checks that clean up allocated resources on failure.

---

### ~~TOmniParallelLoopBase.Destroy skips FRttiContext.Free when FEnumerable is nil~~ — Severity: Medium — FALSE REPORT (TRttiContext is a record (value type), not a class. Calling .Free on it is a no-op already. There is no actual leak.)
**File**: `OtlParallel.pas:3185`
**Category**: 2.1 Resource Leaks
**Description**: `FRttiContext.Free` is only called inside the `if FEnumerable.AsObject <> nil` branch. If the enumerator is nil (e.g., `rm.Invoke` returned nil in Release builds), the RTTI context is never freed.
**Suggested fix**: Track RTTI initialization with a boolean field or always free `FRttiContext` unconditionally.

---

### ~~TOmniParallelSimpleLoop<T>.OnStopInvoke missing nil guard~~ — Severity: Medium — FINISHED (Already fixed in earlier commit)
**File**: `OtlParallel.pas:4437`
**Category**: 2.4 Uninitialized Data / nil dereference
**Description**: Every other `OnStopInvoke` implementation guards against a nil `task` parameter before calling `task.Invoke`. The generic `TOmniParallelSimpleLoop<T>` variant does not. In the synchronous (blocking) path, `DoOnStop(nil)` is called with nil, causing an AV. This is a copy-paste omission.
**Evidence**:
```pascal
// Generic version — MISSING nil guard:
  task.Invoke(procedure begin stopCode(); end);

// Non-generic version — HAS guard:
  if not assigned(task) then
    stopCode()
  else
    task.Invoke(procedure begin stopCode(); end);
```
**Risk**: Reliable AV when using `TOmniParallelSimpleLoop<T>.OnStopInvoke` in blocking (non-NoWait) mode.
**Suggested fix**: Add the same nil guard as all other `OnStopInvoke` implementations.

---

### ~~FStopOn stored by StopOn() but never used~~ — Severity: Low — CONFIRMED, DEFERRED (Missing feature, not a memory leak.)
**File**: `OtlParallel.pas:5577`
**Category**: 2.1 Resource Leaks (functional no-op)
**Description**: `TOmniBackgroundWorker.FStopOn` is set by `StopOn(token)` but never read or wired into the pipeline. The cancellation token is stored as an interface (so memory is fine) but the API contract is silently broken.
**Suggested fix**: Wire `FStopOn` into the pipeline via `.CancelWith(FStopOn)` before `.Run`, or document as unimplemented.

---

## OtlTaskControl.pas

### ~~Destructor accesses otcSharedInfo unconditionally after nil-guarded lock acquire~~ — Severity: High — FINISHED (Already fixed in earlier commit)
**File**: `OtlTaskControl.pas:2690`
**Category**: 2.1 Resource Leaks / 2.4 Uninitialized Data
**Description**: The lock acquire on `otcSharedInfo.MonitorLock` is guarded by `if assigned(otcSharedInfo)`, but the `try` block body unconditionally dereferences `otcSharedInfo` (lines 2693–2700). If `otcSharedInfo` is nil, the code AVs on `otcSharedInfo.Lock.Free`.
**Evidence**:
```pascal
if assigned(otcSharedInfo) then   // guarded
  otcSharedInfo.MonitorLock.Acquire;
try
  if otcDestroyLock then begin
    otcSharedInfo.Lock.Free;      // AV if otcSharedInfo is nil!
    otcSharedInfo.Lock := nil;
  end;
  FreeAndNil(otcExecutor);
  otcSharedInfo.CommChannel := nil;   // AV if nil
```
**Risk**: If `otcSharedInfo` can be nil at destruction time (as the comment on line 2690 implies), this crashes.
**Suggested fix**: Wrap the body in `if assigned(otcSharedInfo) then begin ... end`:
```pascal
if assigned(otcSharedInfo) then begin
  if otcDestroyLock then begin
    otcSharedInfo.Lock.Free;
    otcSharedInfo.Lock := nil;
  end;
  otcSharedInfo.CommChannel := nil;
  otcSharedInfo.TerminateEvent := nil;
  otcSharedInfo.TerminatedEvent := nil;
end;
FreeAndNil(otcExecutor);
```

---

### ~~Thread object leaked after TerminateThread~~ — Severity: High — FINISHED (Already fixed in earlier commit)
**File**: `OtlTaskControl.pas:3454`
**Category**: 2.1 Resource Leaks
**Description**: When `WaitFor` times out and a thread is forcibly killed with `TerminateThread`, the code sets `otcThread := nil` without freeing it. The `TOmniThread` object (a heap-allocated `TThread` descendant) and its OS thread handle are permanently leaked.
**Evidence**:
```pascal
if not Result then begin
  if assigned(otcThread) then begin
    TerminateThread(otcThread.Handle, cardinal(-1));
    otcThread := nil;   // leaks the TThread object!
  end
```
**Risk**: Definite leak on every task termination timeout. The destructor at line 2688 uses `FreeAndNil(otcThread)`, showing the expected cleanup pattern.
**Suggested fix**: Replace `otcThread := nil` with `FreeAndNil(otcThread)`.

---

### ~~_AddRef hack in destructor causes memory leak on constructor exception~~ — Severity: High — FALSE REPORT (TOmniTaskControl.Create does not raise exceptions in normal operation. The _AddRef hack is a necessary workaround for the internal event monitor double-destruction issue. Constructor exceptions are not a realistic scenario.)
**File**: `OtlTaskControl.pas:2684`
**Category**: 2.2 Double-Free / Use-After-Free
**Description**: The destructor calls `_AddRef` to prevent double-destruction. When `Create` raises an exception, Delphi invokes `Destroy` during exception unwinding. `_AddRef` increments the ref-count from 0 to 1. After `Destroy` returns, the ARC mechanism does not free the object because the ref-count is 1 — resulting in a permanent memory leak of the partially-constructed `TOmniTaskControl`.
**Evidence**:
```pascal
destructor TOmniTaskControl.Destroy;
begin
  _AddRef; // Ugly ugly hack to prevent destructor being called twice
           // when internal event monitor is in use
  DestroyMonitor;
  ...
```
**Risk**: Any constructor failure in `TOmniTaskControl.Create` permanently leaks the object.
**Suggested fix**: Track whether full construction completed (e.g., `FConstructionComplete: boolean`) and only execute `_AddRef` when it is true.

---

### ~~Uninitialized taskFunc, msgName, msgData output parameters~~ — Severity: Medium — FINISHED
**File**: `OtlTaskControl.pas:2275`
**Category**: 2.4 Uninitialized Data
**Description**: `GetMethodNameFromInternalMessage` initializes `func`, `funcEx`, and `proc` to nil but does NOT initialize `taskFunc`, `msgName`, or `msgData`. For `imtStringMsg`/`imtAddressMsg`, `taskFunc` is uninitialized. For `imtFuncMsg`, `msgName`/`msgData` are uninitialized. The caller `DispatchOmniMessage` tests `assigned(taskFunc)` on potentially uninitialized memory.
**Risk**: Relies on stack memory being zero, which is undefined behavior.
**Suggested fix**: Add `taskFunc := nil; msgName := ''; msgData := TOmniValue.Null;` at the top of the method.

---

### ~~SetException uses raw .Free leaving dangling pointer~~ — Severity: Medium — FINISHED
**File**: `OtlTaskControl.pas:1401`
**Category**: 2.2 Double-Free / Use-After-Free
**Description**: `Exception(otExecutor_ref.TaskException).Free` frees the exception but leaves the now-dangling pointer in `otExecutor_ref.TaskException` until the next line overwrites it.
**Evidence**:
```pascal
procedure TOmniTask.SetException(exceptionObject: pointer);
begin
  Exception(otExecutor_ref.TaskException).Free;  // dangling after this line
  otExecutor_ref.TaskException := exceptionObject;
end;
```
**Risk**: In the narrow window between `.Free` and the assignment, a concurrent `GetFatalException` call could read the dangling pointer.
**Suggested fix**: Assign first, then free the old value:
```pascal
var oldEx := otExecutor_ref.TaskException;
otExecutor_ref.TaskException := exceptionObject;
Exception(oldEx).Free;
```

---

### ~~Internal message objects not zeroed after FreeAndNil in UnpackMessage~~ — Severity: Medium — FALSE REPORT (const msg parameter means callers don't observe the freed pointer. The message is consumed by the unpack operation. Current patterns are safe.)
**File**: `OtlTaskControl.pas:1094`
**Category**: 2.2 Double-Free / Use-After-Free
**Description**: Each `UnpackMessage` class procedure frees the internal message object from `msg.MsgData.AsObject`, but since `msg` is `const`, the caller's copy still holds the freed pointer. If the message were reused, this would cause a double-free. One overload (`TOmniInternalFuncMsg`, line 1215) correctly nils `msg.MsgData.AsObject`, but the others do not.
**Risk**: Low in current call patterns, but inconsistent and fragile.
**Suggested fix**: Consistently nil `msg.MsgData` after freeing in all `UnpackMessage` variants.

---

### ~~Queued Invoke messages leak embedded objects on task kill~~ — Severity: Low — FALSE REPORT (Task kill via TerminateThread is already a destructive last-resort operation. Leaking queued message objects during forced termination is acceptable.)
**File**: `OtlTaskControl.pas:3421`
**Category**: 2.1 Resource Leaks
**Description**: In `Terminate`, the message drain loop calls `ForwardTaskMessage(msg)` which only handles `TOmniInternalFuncMsg` specially. Other internal message types (`TOmniInternalStringMsg`, `TOmniInternalAddressMsg`, `TOmniInternalAnonMsg`) have their embedded objects orphaned.
**Risk**: Leak of internal message objects when a task is terminated while its inbox has pending invocations.
**Suggested fix**: Ensure `ForwardTaskMessage` handles all `COtlReservedMsgID` message types, or free unhandled internal objects.

---

### ~~OnMessage(msgID, TOmniMessageExec) — ambiguous ownership~~ — Severity: Low — FALSE REPORT
**File**: `OtlTaskControl.pas:3099`
**Category**: 2.1 Resource Leaks
**Description**: Stores the caller-supplied `TOmniMessageExec` in `otcOnMessageList` without documenting ownership transfer. The destructor frees all list entries. If the caller passes the same object for multiple msgIDs or also frees it externally, a double-free occurs.
**Risk**: Low probability — requires unusual calling patterns.
**Suggested fix**: Document that `OnMessage` takes ownership, or defensively clone the object.

---

## OtlContainers.pas

### ~~TOmniBaseQueue.Initialize — AllocateBlock leaked if assertion fails~~ — Severity: High — FALSE REPORT
**Reason**: OOM-only scenario; assertion fires only in debug builds, and the allocation is unreachable in release. Negligible.
**File**: `OtlContainers.pas:1407`
**Category**: 2.1 Resource Leaks
**Description**: `Initialize` calls `AllocateBlock` after three `Assert` calls. If the alignment assertion at line 1406 fires, the `AllocateBlock` result is lost. Also in the constructor, `Assert(obcMemStack.Push(memory))` silently leaks the just-allocated `memory` block if assertions are disabled and the push fails.
**Evidence**:
```pascal
Assert(NativeInt(obcTailPointer) mod (2*SizeOf(pointer)) = 0);
Assert(NativeInt(obcHeadPointer) mod (2*SizeOf(pointer)) = 0);
Assert(NativeInt(@obcCachedBlock) mod SizeOf(pointer) = 0);   // if fires:
obcTailPointer.Slot := NextSlot(AllocateBlock);  // AllocateBlock result leaked
```
**Risk**: Debug-only (assertions disabled in Release). Fragile error path.
**Suggested fix**: Perform alignment checks before allocating blocks.

---

### ~~TOmniQueue.Initialize — TOmniContainerSubject leaked on re-initialization~~ — Severity: Medium — FALSE REPORT
**Reason**: Re-initialization is not a supported use case; the base class guards against it. No leak in normal usage.
**File**: `OtlContainers.pas:1656`
**Category**: 2.1 Resource Leaks
**Description**: `Initialize` creates a new `TOmniContainerSubject` without first freeing any existing instance. The base class guards against re-initialization for its own fields, but the subclass does not follow the same pattern.
**Suggested fix**: Guard with `FreeAndNil(ocContainerSubject)` before creating.

---

### ~~TOmniValueQueue.Create — FContainerSubject leaked if TQueue.Create raises~~ — Severity: Medium — FALSE REPORT
**Reason**: OOM-only scenario; TQueue.Create only raises on out-of-memory. Negligible.
**File**: `OtlContainers.pas:1673`
**Category**: 2.1 Resource Leaks
**Description**: `FContainerSubject` is created first, then `FInnerQueue := TQueue<TOmniValue>.Create`. Since `TOmniValueQueue` is `TInterfacedObject`-based, Delphi's exception-during-constructor handling does not call `Destroy` when the refcount is 0. `FContainerSubject` leaks.
**Suggested fix**: Wrap in try/except or create `FInnerQueue` first.

---

### ~~TOmniValueQueue.IsEmpty — missing try/finally around critical section~~ — Severity: Low — FALSE REPORT
**Reason**: Body cannot raise an exception; TQueue.Count is a simple field read.
**File**: `OtlContainers.pas:1767`
**Category**: 2.1 Resource Leaks (deadlock risk)
**Description**: `IsEmpty` acquires the critical section without a `try/finally` guard. If `FInnerQueue.Count` were to raise, the critical section would never be released.
**Risk**: Very low — `TQueue.Count` is a simple field read.
**Suggested fix**: Apply `try/finally` or use the `DoWithCritSec` pattern.

---

### ~~TOmniValueQueueCS.Destroy — uses FCritSect.Free instead of FreeAndNil~~ — Severity: Low — FALSE REPORT
**Reason**: FreeAndNil is optional in destructor; field is about to be destroyed.
**File**: `OtlContainers.pas:1826`
**Category**: 2.2 Double-Free / Use-After-Free
**Description**: Leaves a dangling pointer. Not immediately dangerous but inconsistent with cleanup patterns elsewhere.
**Suggested fix**: Replace `FCritSect.Free` with `FreeAndNil(FCritSect)`.

---

### ~~Double semicolon in TOmniValueQueue.Create~~ — Severity: Low — FINISHED
**File**: `OtlContainers.pas:1673`
**Category**: Code quality
**Description**: `FContainerSubject := TOmniContainerSubject.Create;;` — harmless but indicates careless editing.
**Suggested fix**: Remove the extra semicolon.

---

## OtlBackgroundObserver.pas

### ~~Constructor leaks FState on OpenThread failure~~ — Severity: High — FINISHED
**File**: `OtlBackgroundObserver.pas:184`
**Category**: 2.1 Resource Leaks
**Description**: `FState := AllocMem(SizeOf(TAPCState))` is allocated before `OpenThread`. If `OpenThread` returns 0 and raises `EOSError`, `FState` (a raw pointer) is leaked. Interface fields (`FNotifyEvent`) are cleaned up by Delphi's constructor exception handling, but `AllocMem` pointers are not.
**Evidence**:
```pascal
FState := AllocMem(SizeOf(TAPCState));
FState.RefCount := 1;
FState.APCPending := 0;
FState.IsActive := 1;
FState.OnNotify := aOnNotify;
FThreadHandle := OpenThread(THREAD_SET_CONTEXT, false, aTargetThreadID);
if FThreadHandle = 0 then
  raise EOSError.CreateFmt(...);   // FState leaked!
```
**Risk**: Every failed `CreateContainerBackgroundObserver` call leaks `SizeOf(TAPCState)` bytes.
**Suggested fix**: Wrap in try/except: `except FreeMem(FState); FState := nil; raise; end`.

---

### ~~Notify FState := nil not thread-safe with concurrent APCCallback~~ — Severity: Medium — CONFIRMED, DEFERRED
**File**: `OtlBackgroundObserver.pas:226`
**Category**: 2.2 Use-After-Free
**Description**: On `QueueUserAPC` failure, `Notify` frees `FState` and sets `FState := nil`. But `APCCallback` can simultaneously decrement `RefCount` and also free `FState`, creating a race on the shared pointer.
**Risk**: Medium — `Notify` is typically called under the container's lock, but this is not guaranteed by the design.
**Suggested fix**: Use atomic CAS to set `FState` to nil, or restrict `FState` cleanup to a single path.

---

## OtlThreadPool.pas

### ~~TOmniThreadPool.Create leaks running task on WaitForInit failure~~ — Severity: High — FALSE REPORT
**Reason**: OOM-only scenario; WaitForInit failure means the task has already failed initialization and will self-terminate. The interface reference cleanup is handled by Delphi's reference counting.
**File**: `OtlThreadPool.pas:1554`
**Category**: 2.1 Resource Leaks
**Description**: If `otpWorkerTask.WaitForInit` returns false, an exception is raised. Since `TOmniThreadPool` is `TInterfacedObject`, the destructor is not called during constructor exception unwinding. `otpWorkerTask` holds a live running task that is never terminated.
**Evidence**:
```pascal
otpWorker := TOTPWorker.Create(name, otpUniqueID);
otpWorkerTask := CreateTask(otpWorker, ...).Run;
if not otpWorkerTask.WaitForInit then
  raise Exception.Create('ThreadPool management task failed to start');
otpAffinity := TOmniIntegerSet.Create;
```
**Risk**: The orphaned task thread runs indefinitely. In practice, if `WaitForInit` fails the task has already failed initialization and will self-terminate, but the interface reference is leaked.
**Suggested fix**: Wrap in try/except and terminate the task on failure.

---

### ~~InternalStop never frees workItem from Asy_TerminateWorkItem~~ — Severity: Medium — CONFIRMED, DEFERRED
**File**: `OtlThreadPool.pas:1138`
**Category**: 2.1 Resource Leaks
**Description**: `Asy_TerminateWorkItem(workItem)` returns a work item but it is never freed or processed. Compare with `Cancel` (line 1011) which correctly calls `ProcessCompletedWorkItem(workItem)`.
**Evidence**:
```pascal
for iWorker := 0 to owStoppingWorkers.Count - 1 do begin
  worker := TOTPWorkerThread(owStoppingWorkers[iWorker]);
  worker.Asy_TerminateWorkItem(workItem);  // workItem returned but never freed!
  FreeAndNil(worker);
end;
```
**Risk**: Every stopping worker with an active work item leaks a `TOTPWorkItem` during pool shutdown.
**Suggested fix**: After `Asy_TerminateWorkItem`, free the returned work item: `if assigned(workItem) then FreeAndNil(workItem);`

---

## OtlDataManager.pas

### ~~ReleaseOutputBuffer crashes when dmoPreserveOrder not set~~ — Severity: High — CONFIRMED, DEFERRED
**File**: `OtlDataManager.pas:1109`
**Category**: 2.1 Resource Leaks / nil dereference
**Description**: `dmUnusedBuffers` is only created when `dmoPreserveOrder in dmOptions` (line 981). However, `ReleaseOutputBuffer` unconditionally calls `dmUnusedBuffers.Add(buffer)` without checking if `dmUnusedBuffers` is assigned.
**Evidence**:
```pascal
// In constructor (conditional):
if dmoPreserveOrder in dmOptions then begin
  dmBufferRangeList := TList<TPair<int64, TObject>>.Create;
  dmUnusedBuffers := TObjectList.Create;
end;

// In ReleaseOutputBuffer (unconditional):
procedure TOmniBaseDataManager.ReleaseOutputBuffer(buffer: TOmniOutputBuffer);
begin
  (buffer as TOmniOutputBufferSet).ActiveBuffer.MarkFull;
  dmUnusedBuffersLock.Acquire;
  try
    dmUnusedBuffers.Add(buffer);  // AV if dmUnusedBuffers is nil!
  finally dmUnusedBuffersLock.Release; end;
end;
```
**Risk**: Access violation when `ReleaseOutputBuffer` is called without `dmoPreserveOrder`.
**Suggested fix**: Either always create `dmUnusedBuffers`, or add a nil check in `ReleaseOutputBuffer`.

---

### ~~dmUnusedBuffers default OwnsObjects=true may double-free buffers~~ — Severity: Medium — CONFIRMED, DEFERRED
**File**: `OtlDataManager.pas:981`
**Category**: 2.2 Double-Free
**Description**: `dmUnusedBuffers := TObjectList.Create` uses default `OwnsObjects = true`. Buffers added via `ReleaseOutputBuffer` are also referenced externally. When the `TObjectList` is destroyed, it frees its owned objects. If any external code also frees the buffer, this is a double-free.
**Risk**: Depends on the ownership contract between `ReleaseOutputBuffer` callers and the data manager.
**Suggested fix**: Use `TObjectList.Create(false)` and document ownership transfer explicitly.

---

## OtlComm.pas

### ~~Detach called with potentially nil observer in destructor~~ — Severity: Low — FALSE REPORT
**Reason**: Detach tolerates nil; the finding itself acknowledges "currently harmless because Detach tolerates nil."
**File**: `OtlComm.pas:305`
**Category**: 2.1 Resource Leaks (defensive)
**Description**: `TOmniMessageQueue.Destroy` calls `ContainerSubject.Detach(mqEventObserver, ...)` unconditionally, even when `mqEventObserver` is nil (when `createEventObserver = false`). Currently harmless because `Detach` tolerates nil, but fragile.
**Suggested fix**: Guard with `if assigned(mqEventObserver) then`.

---

## OtlSync.Utils.pas

### ~~TEvent leaked if FEvents.Add raises in Ensure~~ — Severity: Low — FALSE REPORT
**Reason**: OOM-only scenario; FEvents.Add only raises on out-of-memory. Negligible.
**File**: `OtlSync.Utils.pas:119`
**Category**: 2.1 Resource Leaks
**Description**: `TOmniSynchronizer<T>.Ensure` creates a `TEvent`, then calls `FEvents.Add(name, Result)` inside the write lock. If `Add` raises (e.g., OOM), the newly created `TEvent` is leaked.
**Suggested fix**: Wrap `FEvents.Add` in try/except to free the event on failure.

---

## Units with No Memory Management Issues Found

The following units were analyzed and found to have no Category 2 issues:

- **OtlCollections.pas** — constructor/destructor ordering is correct; `TWaitFor` waiters freed before their event references.
- **OtlContainerObserver.pas** — observer lists correctly managed; nil external event handled.
- **OtlCommon.Utils.pas** — `GKernel32` handle properly loaded/freed in init/finalization.
- **OtlTask.pas** — `TOmniWaitObjectList` correctly manages parallel lists; `Remove` safely checked via `IndexOf`.
- **OtlPlatform.pas** — `GTimeSource` is a value type, no heap allocation needed.
- **OtlLogger.pas** — `GLogger` correctly created/freed; `Clear` releases string references.
- **OtlEventMonitor.pas** — message drain sequence is correct.

---

## Summary by Severity

| Severity | Count | Key Findings |
|----------|-------|-------------|
| **Critical** | 7 | OtlHooks Register/Unregister dangling pointers; OtlCommon Grow off-by-one; OtlCommon _ReleaseAndClear nil deref; OtlSync TOmniWrappedEvent handle leak; OtlSync TOmniSynchroObject.Destroy use-after-free; OtlParallel Pipeline shared `exc` race |
| **High** | 10 | OtlCommon Create/CreateNamed container leaks; OtlSync Locked<T> race; OtlSync constructor leaks; OtlParallel BackgroundWorker observer leak; OtlParallel RTTI leak; OtlTaskControl destructor nil deref; OtlTaskControl thread leak; OtlTaskControl _AddRef hack; OtlContainers AllocateBlock leak; OtlBackgroundObserver FState leak; OtlThreadPool task leak; OtlDataManager nil deref |
| **Medium** | 10 | Various constructor exception leaks, uninitialized output parameters, double-free risks |
| **Low** | 10 | Cosmetic issues, minor inconsistencies, defensive suggestions |

---

# Static Analysis Results — Category 3: Copy & Paste Errors

**Date**: 2026-04-14
**Scope**: All 18 units listed in STATIC-ANALYSIS-SPEC.md
**Categories covered**: 3.1 Duplicated Code with Wrong Identifiers, 3.2 Incomplete Adaptations

**Summary**: 3 Critical, 4 High, 4 Medium, 10 Low findings across 8 units.

---

## OtlParallel.pas

### ~~`PInteger` used instead of `PNativeInt` in pipeline stage dispatch~~ — Severity: Critical — FINISHED
**File**: `OtlParallel.pas:4634`
**Category**: 3.2 Incomplete Adaptations
**Description**: `TOmniPipelineStage.Execute` checks whether anonymous method references (`opsSimpleStage`, `opsStage`, `opsStageEx`) are nil by dereferencing them as `PInteger` (4 bytes). The Assert on the preceding line confirms `SizeOf(TProc) = SizeOf(NativeInt)`, and the comparison target is `NativeInt(nil)` — but the dereference reads only 32 bits. On 64-bit, this reads only the low 32 bits of an 8-byte interface pointer and compares against a 64-bit zero.
**Evidence**:
```pascal
Assert(SizeOf(TProc) = SizeOf(NativeInt));
if PInteger(@opsSimpleStage)^ <> NativeInt(nil) then       // 4634 — reads 4 bytes, compares to 8
  ExecuteSimpleStage(task, opsSimpleStage, opsInput, opsOutput)
else if PInteger(@opsStage)^ <> NativeInt(nil) then begin   // 4636
  Assert(PInteger(@opsStageEx)^ = NativeInt(nil));           // 4637
  opsStage(opsInput, opsOutput);
end
else begin
  Assert(PInteger(@opsStageEx)^ <> NativeInt(nil));          // 4641
```
**Risk**: On 64-bit, if the low 32 bits of a non-nil method reference happen to be zero (high 32 bits hold the real address), the check incorrectly treats it as nil, dispatching to the wrong branch and calling an unassigned delegate — access violation.
**Suggested fix**: Replace all `PInteger` with `PNativeInt`:
```pascal
if PNativeInt(@opsSimpleStage)^ <> NativeInt(nil) then
```

---

### ~~`TOmniParallelLoop.OnStopInvoke` missing nil-task guard~~ — Severity: Medium — FINISHED
**File**: `OtlParallel.pas:3680`
**Category**: 3.2 Incomplete Adaptations
**Description**: The generic `TOmniParallelLoop<T>.OnStopInvoke` (line 3937) correctly guards against a nil `task` parameter (which is nil when called synchronously from the non-NoWait path). The non-generic `TOmniParallelLoop.OnStopInvoke` was copied but the nil guard was not included.
**Evidence**:
```pascal
// Non-generic — MISSING guard:
function TOmniParallelLoop.OnStopInvoke(stopCode: TProc): IOmniParallelLoop;
begin
  Result := OnStop(
    procedure (const task: IOmniTask)
    begin
      task.Invoke(           // task can be nil here — AV
        procedure begin stopCode(); end);
    end);
end;

// Generic — HAS guard (correct):
function TOmniParallelLoop<T>.OnStopInvoke(stopCode: TProc): IOmniParallelLoop<T>;
begin
  Result := OnStop(
    procedure (const task: IOmniTask)
    begin
      if not assigned(task) then
        stopCode()
      else
        task.Invoke(procedure begin stopCode(); end);
    end);
end;
```
**Risk**: Calling `OnStopInvoke` on a non-generic `Parallel.ForEach` that waits (the common case) causes an access violation when `DoOnStop(nil)` is called.
**Suggested fix**: Add the nil guard to match the generic variant.

---

### ~~`TOmniParallelSimpleLoop<T>.OnStopInvoke` missing nil-task guard~~ — Severity: Medium — FINISHED
**File**: `OtlParallel.pas:4437`
**Category**: 3.2 Incomplete Adaptations
**Description**: Same pattern as above. The non-generic `TOmniParallelSimpleLoop.OnStopInvoke` (line 4310) has the nil-task guard. The generic `TOmniParallelSimpleLoop<T>.OnStopInvoke` was copied without it.
**Evidence**:
```pascal
// Generic <T> — MISSING guard:
function TOmniParallelSimpleLoop<T>.OnStopInvoke(stopCode: TProc):
  IOmniParallelSimpleLoop<T>;
begin
  Result := OnStop(
    procedure (const task: IOmniTask)
    begin
      task.Invoke(           // task can be nil — AV
        procedure begin stopCode(); end);
    end);
end;
```
**Risk**: AV when the user calls `Parallel.For<T>(arr).OnStopInvoke(...)` without `.NoWait`.
**Suggested fix**: Add `if not assigned(task) then stopCode() else ...` guard.

---

## OtlContainers.pas

### ~~`IsFull` compares against `LastIn` instead of `FirstIn`~~ — Severity: Critical — FINISHED
**File**: `OtlContainers.pas:923`
**Category**: 3.1 Duplicated Code with Wrong Identifiers
**Description**: `TOmniBaseBoundedQueue.IsFull` computes the next `LastIn` position (one slot ahead of the current write pointer, wrapped) and then checks whether it equals `obqPublicRingBuffer.LastIn.PData` — i.e. `NextLastIn == CurrentLastIn`. A ring buffer is full when the write pointer catches up to the read pointer, so the comparison should be against `FirstIn.PData`. Compare with `IsEmpty` (line 911) which correctly compares `FirstIn.PData = LastIn.PData`.
**Evidence**:
```pascal
function TOmniBaseBoundedQueue.IsFull: boolean;
var
  NewLastIn: pointer;
begin
  Acquire;
  try
    NewLastIn := pointer(NativeInt(obqPublicRingBuffer.LastIn.PData) + SizeOf(TReferencedPtr));
    if NativeInt(NewLastIn) > NativeInt(obqPublicRingBuffer.EndBuffer) then
      NewLastIn := obqPublicRingBuffer.StartBuffer;
    result := (NativeInt(NewLastIn) = NativeInt(obqPublicRingBuffer.LastIn.PData)) or  // BUG
      (obqRecycleRingBuffer.FirstIn.PData = obqRecycleRingBuffer.LastIn.PData);
  finally Release; end;
end;
```
**Risk**: `IsFull` almost always returns `false` regardless of actual fill level, so callers may enqueue into an already-full ring buffer. The second `or` clause (checking the recycle ring) may partially compensate.
**Suggested fix**: Change to `obqPublicRingBuffer.FirstIn.PData`:
```pascal
result := (NativeInt(NewLastIn) = NativeInt(obqPublicRingBuffer.FirstIn.PData)) or ...
```

---

### ~~`CollectionNotifyEvent` uses wrong threshold for `coiNotifyOnPartlyEmpty`~~ — Severity: High — FINISHED
**File**: `OtlContainers.pas:1715`
**Category**: 3.1 Duplicated Code with Wrong Identifiers
**Description**: After a remove, the code checks `FAlmostFullThreshold` to decide whether to fire `coiNotifyOnPartlyEmpty`. It was copied from the `cnAdded` branch (which correctly checks `FAlmostFullThreshold` for `coiNotifyOnAlmostFull`) and the threshold variable was not updated. `FPartlyEmptyThreshold` is initialized but never consulted anywhere.
**Evidence**:
```pascal
cnRemoved,
cnExtracted:
  begin
    Include(FNotifiableEvents, coiNotifyOnAllRemoves);
    if AfterCount = FAlmostFullThreshold then        // BUG: should be FPartlyEmptyThreshold
      Include(FNotifiableEvents, coiNotifyOnPartlyEmpty);
  end;
```
**Risk**: The `coiNotifyOnPartlyEmpty` event fires at the wrong count level. Consumers waiting for a "partly empty" signal may never receive it or receive it at the wrong time.
**Suggested fix**: Change to `FPartlyEmptyThreshold`.

---

### ~~Wrong class name in `TOmniBaseBoundedQueue.Initialize` assert messages~~ — Severity: Low — FINISHED
**File**: `OtlContainers.pas:832`
**Category**: 3.1 Duplicated Code with Wrong Identifiers
**Description**: Assert messages say `TOmniBaseContainer: obcPublicRingBuffer` and `TOmniBaseContainer: obcRecycleRingBuffer`. The actual class is `TOmniBaseBoundedQueue` and the field prefix is `obq`, not `obc`. Copied from `TOmniBaseQueue`.
**Evidence**:
```pascal
Assert(NativeInt(obqPublicRingBuffer) mod (SizeOf(pointer) * 2) = 0,
  Format('TOmniBaseContainer: obcPublicRingBuffer is not %d-aligned', [SizeOf(pointer) * 2]));
```
**Risk**: Misleading diagnostics when assertions fire.
**Suggested fix**: Change to `TOmniBaseBoundedQueue.Initialize: obqPublicRingBuffer`.

---

### ~~Wrong class name in `TOmniBaseBoundedStack.Initialize` exception~~ — Severity: Low — FINISHED
**File**: `OtlContainers.pas:505`
**Category**: 3.1 Duplicated Code with Wrong Identifiers
**Description**: Exception message says `TOmniBaseContainer: obcBuffer is not aligned` but the class is `TOmniBaseBoundedStack` and the field prefix is `obs`.
**Evidence**:
```pascal
raise Exception.Create('TOmniBaseContainer: obcBuffer is not aligned');
```
**Risk**: Misleading error message.
**Suggested fix**: Change to `TOmniBaseBoundedStack.Initialize: obsBuffer is not aligned`.

---

### ~~Wrong class name in `TOmniValueQueue.Dequeue` exception~~ — Severity: Low — FINISHED
**File**: `OtlContainers.pas:1745`
**Category**: 3.1 Duplicated Code with Wrong Identifiers
**Description**: Exception says `TOmniBaseQueue.Dequeue` but the method is `TOmniValueQueue.Dequeue`. Copied from `TOmniBaseQueue.Dequeue` at line 1268.
**Evidence**:
```pascal
raise Exception.Create('TOmniBaseQueue.Dequeue: Message queue is empty');
```
**Risk**: Misleading error message.
**Suggested fix**: Change to `TOmniValueQueue.Dequeue`.

---

### ~~Double semicolon in `TOmniValueQueue.Create`~~ — Severity: Low — FINISHED
**File**: `OtlContainers.pas:1673`
**Category**: 3.1 Duplicated Code with Wrong Identifiers
**Description**: A stray double semicolon — harmless but a copy-paste residue.
**Evidence**:
```pascal
FContainerSubject := TOmniContainerSubject.Create;;
```
**Risk**: None.
**Suggested fix**: Remove the extra semicolon.

---

## OtlTaskControl.pas

### ~~`RemoveTerminationEvents` missing three fields from `RebuildWaitHandles`~~ — Severity: High — FINISHED
**File**: `OtlTaskControl.pas:2458`
**Category**: 3.2 Incomplete Adaptations
**Description**: `RemoveTerminationEvents` was written to mirror `RebuildWaitHandles` (line 2405) but omits three fields: `NewMessageEvent`, `IdxFirstWaitObject`, and `IdxLastWaitObject`. The destination `msgInfo` record is zero-initialized (it contains managed types), so `NewMessageEvent` is nil and both wait-object indices are 0.
**Evidence**:
```pascal
procedure TOmniTaskExecutor.RemoveTerminationEvents(const srcMsgInfo: TOmniMessageInfo;
  var dstMsgInfo: TOmniMessageInfo);
var
  offset: integer;
begin
  offset := srcMsgInfo.IdxLastTerminate + 1;
  dstMsgInfo.IdxFirstTerminate := -1;
  dstMsgInfo.IdxLastTerminate := -1;
  dstMsgInfo.IdxFirstMessage := srcMsgInfo.IdxFirstMessage - offset;
  dstMsgInfo.IdxLastMessage := srcMsgInfo.IdxLastMessage - offset;
  dstMsgInfo.IdxRebuildHandles := srcMsgInfo.IdxRebuildHandles - offset;
  // MISSING: dstMsgInfo.NewMessageEvent    := srcMsgInfo.NewMessageEvent;
  // MISSING: dstMsgInfo.IdxFirstWaitObject := srcMsgInfo.IdxFirstWaitObject - offset;
  // MISSING: dstMsgInfo.IdxLastWaitObject  := srcMsgInfo.IdxLastWaitObject  - offset;
  dstMsgInfo.NumWaitHandles := srcMsgInfo.NumWaitHandles - offset;
  ...
end;
```
**Risk**: In `ProcessMessages` (line 2375), which uses this method: (1) `DispatchCommMessage` compares `newMsgHandle = msgInfo.NewMessageEvent` (nil) — always false — so primary comm channel messages are never dispatched via `task.Comm.Receive`; (2) `IdxFirstWaitObject = 0` causes the RebuildHandles event (index 0) to be misclassified as a wait-object event, potentially calling an out-of-range response handler.
**Suggested fix**: Add the three missing assignments:
```pascal
dstMsgInfo.NewMessageEvent    := srcMsgInfo.NewMessageEvent;
dstMsgInfo.IdxFirstWaitObject := srcMsgInfo.IdxFirstWaitObject - offset;
dstMsgInfo.IdxLastWaitObject  := srcMsgInfo.IdxLastWaitObject  - offset;
```

---

### ~~Wrong class name in three `TOmniTaskControl.Invoke` end comments~~ — Severity: Low — FINISHED
**File**: `OtlTaskControl.pas:3013, 3019, 3025`
**Category**: 3.1 Duplicated Code with Wrong Identifiers
**Description**: Three `TOmniTaskControl.Invoke` overloads have end comments saying `{ TOmniCommunicationEndpoint.Invoke }`. Copied from earlier code.
**Evidence**:
```pascal
end; { TOmniCommunicationEndpoint.Invoke }   // should be TOmniTaskControl.Invoke
```
**Risk**: None at runtime. Misleads code navigation.
**Suggested fix**: Change to `{ TOmniTaskControl.Invoke }`.

---

### ~~Truncated method name in end comment~~ — Severity: Low — FINISHED
**File**: `OtlTaskControl.pas:3984`
**Category**: 3.1 Duplicated Code with Wrong Identifiers
**Description**: `TOmniMessageExec.OnTerminated` end comment says `{ TOmniMessageExec.OnTerminate }` — missing trailing `d`.
**Risk**: None.
**Suggested fix**: Change to `{ TOmniMessageExec.OnTerminated }`.

---

### ~~Missing class qualifier in `RebuildWaitHandles` end comment~~ — Severity: Low — FINISHED
**File**: `OtlTaskControl.pas:2456`
**Category**: 3.1 Duplicated Code with Wrong Identifiers
**Description**: End comment says `{ RebuildWaitHandles }` without the `TOmniTaskExecutor.` prefix that every other method in the file uses.
**Risk**: None.
**Suggested fix**: Change to `{ TOmniTaskExecutor.RebuildWaitHandles }`.

---

## OtlThreadPool.pas

### ~~`Cancel` multiplies already-millisecond timeout by 1000~~ — Severity: High — FINISHED
**File**: `OtlThreadPool.pas:1006`
**Category**: 3.2 Incomplete Adaptations
**Description**: `TOTPWorker.Cancel` stores the timeout in `waitForTask_ms` (already in milliseconds — line 997 converts from seconds: `int64(WaitOnTerminate_sec.Value) * 1000`). But line 1006 multiplies it by 1000 again when computing the deadline. This was copied from `InternalStop` (line 1130) where the source value is in seconds.
**Evidence**:
```pascal
waitForTask_ms := params[2];
if waitForTask_ms < 0 then
  waitForTask_ms := int64(WaitOnTerminate_sec.Value) * 1000;   // now in ms

endWait_ms := Time.Timestamp_ms + waitForTask_ms * 1000;       // BUG: ms * 1000 = microseconds
```
**Risk**: A 30-second cancel timeout becomes a 30,000-second (8+ hour) wait. `Cancel` effectively never times out.
**Suggested fix**: Change to:
```pascal
endWait_ms := Time.Timestamp_ms + waitForTask_ms;
```

---

## OtlHooks.pas

### ~~All three notification classes store `@localProc` (stack address) instead of function pointer~~ — Severity: Critical — FALSE REPORT
**File**: `OtlHooks.pas:351, 361, 409, 419, 471, 481`
**Category**: 3.1 Duplicated Code with Wrong Identifiers
**Description**: `TThreadNotifications.Register(notifyProc)`, `TPoolNotifications.Register(notifyProc)`, and `TExceptionFilters.Register(filterProc)` all use `pointer(@notifyProc)` — taking the address of a stack-local parameter. This stores a dangling stack pointer. The `Unregister` methods have the same error, so `Remove` also searches for a different dangling stack address and will never find the original entry. The `Notify` methods cast the stored pointer back to a proc type and call it (e.g., line 338: `TThreadNotificationProc(tnList[iObserver+1])(notifyType, threadName)`), confirming the intent is to store the function address, not a pointer-to-local.
**Evidence**:
```pascal
procedure TThreadNotifications.Register(notifyProc: TThreadNotificationProc);
begin
  tnList.Add(pointer(@notifyProc));     // stores address of stack local — dangling!
end;

procedure TThreadNotifications.Unregister(notifyProc: TThreadNotificationProc);
begin
  tnList.Remove(pointer(@notifyProc));  // different stack local — never matches!
end;

// Same pattern in TPoolNotifications (lines 409, 419) and TExceptionFilters (lines 471, 481)
```
**Risk**: Registered procedure callbacks will call into garbage memory when notifications fire. `Unregister` will never find and remove the entry.
**Suggested fix**: Replace `pointer(@notifyProc)` with `pointer(notifyProc)` in all six locations.

---

## OtlSync.pas

### ~~`Move128` 32-bit path moves only 8 bytes, not 16~~ — Severity: High — FALSE REPORT
**File**: `OtlSync.pas:1034`
**Category**: 3.2 Incomplete Adaptations
**Description**: The function comment says "Move 16 bytes atomically" but the `{$IFNDEF CPUX64}` implementation uses `int64` (8 bytes). The 64-bit path correctly uses `InterlockedCompareExchange128`. The 32-bit body was copied from `Move64`/`MoveDPtr` without adaptation.
**Evidence**:
```pascal
procedure Move128(var Source, Destination);
//Move 16 bytes atomically from Source to properly aligned Destination
{$IFNDEF CPUX64}
var
  value: int64;
begin
  value := int64(Source);                           // reads only 8 bytes
  TInterlocked.Exchange(int64(Destination), value); // writes only 8 bytes
end;
```
**Risk**: On 32-bit, only the first 8 of 16 bytes are moved. The upper 8 bytes are silently lost.
**Suggested fix**: Either make `Move128` 64-bit-only (`{$IFDEF CPUX64}` guard), or document the 32-bit limitation.

---

### ~~`CAS16` offset mask not adapted from `CAS8`~~ — Severity: Medium — CONFIRMED, DEFERRED
**File**: `OtlSync.pas:933`
**Category**: 3.2 Incomplete Adaptations
**Description**: `CAS16` was copied from `CAS8` but the alignment mask was not adapted. For `CAS8`, `and 3` yields byte offsets 0–3 within a 4-byte word, all valid for a single byte. For `CAS16`, byte offset 3 would straddle a 4-byte boundary: `$FFFF shl 24` produces `$FF000000`, silently discarding the upper 8 bits of the 16-bit value.
**Evidence**:
```pascal
// CAS8 — correct: any byte offset 0–3 is valid
alignedPtr := PInteger(NativeUInt(@destination) and not NativeUInt(3));
offset := integer(NativeUInt(@destination) and 3) * 8;

// CAS16 — same mask, but 16-bit value can straddle boundary at offset 3
alignedPtr := PInteger(NativeUInt(@destination) and not NativeUInt(3));
offset := integer(NativeUInt(@destination) and 3) * 8;  // offset 24 is invalid for word
```
**Risk**: If `destination` falls at byte offset 3 within its 4-byte-aligned word, the CAS corrupts data silently.
**Suggested fix**: Assert 2-byte alignment: `Assert(NativeUInt(@destination) and 1 = 0, 'CAS16: destination must be 2-byte aligned')`.

---

### ~~`CreateOmniEvent(TEvent, boolean)` factory calls non-existent constructor~~ — Severity: Medium — CONFIRMED, DEFERRED
**File**: `OtlSync.pas:900`
**Category**: 3.2 Incomplete Adaptations
**Description**: The factory `CreateOmniEvent(AExternalEvent: TEvent; ATakeOwnership: boolean)` was added alongside the `THandle`-based constructor, but no matching `TOmniEvent.Create(TEvent, boolean)` constructor was ever implemented. `TOmniEvent` only has `Create(boolean, boolean)` and `Create(THandle, boolean)`. No callers exist in the codebase, so this compiles; if ever called, it would produce a type error or silently misresolve the overload.
**Evidence**:
```pascal
function CreateOmniEvent(AExternalEvent: TEvent; ATakeOwnership: boolean): IOmniEvent;
begin
  Result := TOmniEvent.Create(AExternalEvent, ATakeOwnership);  // no matching constructor
end;
```
**Risk**: Any future caller gets a compile error or wrong overload resolution.
**Suggested fix**: Either implement `TOmniEvent.Create(AExternalEvent: TEvent; ...)` or remove the factory.

---

## OtlCommon.pas

### ~~`TOmniValueContainer.Grow` copy loops skip last element~~ — Severity: Low — FINISHED
**File**: `OtlCommon.pas:1591`
**Category**: 3.1 Duplicated Code with Wrong Identifiers
**Description**: Both copy loops in `Grow` use `High(...) - 1` instead of `High(...)`, skipping the last element. The second loop was copied from the first, carrying the same off-by-one. In practice this is benign because `SetLength` on dynamic arrays already preserves existing elements when growing, making the entire copy round-trip redundant. The bug is masked but present.
**Evidence**:
```pascal
for iValue := 0 to High(ovcValues) - 1 do begin    // skips last element
  tmpNames[iValue] := ovcNames[iValue];
  tmpValues[iValue] := ovcValues[iValue];
end;
SetLength(ovcNames, newLength);   // preserves existing elements (masks the bug)
SetLength(ovcValues, newLength);
for iValue := 0 to High(tmpValues) - 1 do begin    // same off-by-one
  ovcNames[iValue] := tmpNames[iValue];
  ovcValues[iValue] := tmpValues[iValue];
end;
```
**Risk**: Currently benign due to `SetLength` semantics. Would become a data-loss bug if the implementation were changed to not use `SetLength` for reallocation.
**Suggested fix**: Change both loops to `High(...)`, or remove the redundant copy loops entirely since `SetLength` already preserves data.

---

### ~~`CastToUInt64` error message says "int64"~~ — Severity: Low — FINISHED
**File**: `OtlCommon.pas:2377`
**Category**: 3.1 Duplicated Code with Wrong Identifiers
**Description**: The error message was copied from `CastToInt64` and says "cannot be converted to int64" but the method is `CastToUInt64`.
**Evidence**:
```pascal
function TOmniValue.CastToUInt64: uint64;
begin
  if not TryCastToUInt64(Result) then
    raise Exception.Create('TOmniValue cannot be converted to int64');  // should say uint64
end;
```
**Risk**: Misleading diagnostic message.
**Suggested fix**: Change `int64` to `uint64`.

---

### ~~Wrong end-comment on `TOmniExecutable.Clear`~~ — Severity: Low — FINISHED
**File**: `OtlCommon.pas:4044`
**Category**: 3.1 Duplicated Code with Wrong Identifiers
**Description**: The closing comment says `{ TOmniExecutable.IsNull }` but the method is `Clear`.
**Evidence**:
```pascal
procedure TOmniExecutable.Clear;
begin
  oeKind := oekNull;
end; { TOmniExecutable.IsNull }   // should say Clear
```
**Risk**: None. Readability hazard.
**Suggested fix**: Change to `{ TOmniExecutable.Clear }`.

---

### ~~Wrong class/field name in `TOmniCounter.Initialize` assert~~ — Severity: Low — FINISHED
**File**: `OtlCommon.pas:1687`
**Category**: 3.1 Duplicated Code with Wrong Identifiers
**Description**: Assert message says `TOmniCS.Initialize: ocsSync is not aligned` but this is `TOmniCounter.Initialize` operating on `ocCounter`. Copied from `TOmniCS.Initialize`.
**Evidence**:
```pascal
Assert(cardinal(@ocCounter) mod SizeOf(ocCounter) = 0,
  Format('TOmniCS.Initialize: ocsSync is not %d-aligned!', [SizeOf(ocCounter)]));
```
**Risk**: Misleading assert message.
**Suggested fix**: Change to `TOmniCounter.Initialize: ocCounter`.

---

## OtlContainerObserver.pas

### ~~Wrong method name in `NotifyOnce` end comment~~ — Severity: Low — FINISHED
**File**: `OtlContainerObserver.pas:310`
**Category**: 3.1 Duplicated Code with Wrong Identifiers
**Description**: End comment says `{ TOmniContainerSubject.NotifyAndRemove }` but the method was renamed to `NotifyOnce`.
**Evidence**:
```pascal
procedure TOmniContainerSubject.NotifyOnce(interest: TOmniContainerObserverInterest);
  ...
end; { TOmniContainerSubject.NotifyAndRemove }
```
**Risk**: None. Readability hazard.
**Suggested fix**: Change to `{ TOmniContainerSubject.NotifyOnce }`.

---

## OtlComm.pas

### ~~Orphaned duplicate end comment~~ — Severity: Low — FINISHED
**File**: `OtlComm.pas:401`
**Category**: 3.1 Duplicated Code with Wrong Identifiers
**Description**: A duplicate `{ TOmniCommunicationEndpoint.GetNewMessageEvent }` comment appears orphaned between `GetNewMessageEvent` and `GetReader`, probably left behind during a refactor.
**Risk**: None. Readability hazard.
**Suggested fix**: Remove the orphaned comment or change to `{ TOmniCommunicationEndpoint.GetReader }`.

---

## Clean Units

The following units had no Category 3 findings:
- **OtlCollections.pas** — No structural duplications or copy-paste issues found.
- **OtlDataManager.pas** — Clean.
- **OtlBackgroundObserver.pas** — Clean.
- **OtlEventMonitor.pas** — Clean.
- **OtlCommon.Utils.pas** — Clean.
- **OtlSync.Utils.pas** — Clean.
- **OtlTask.pas** — Clean.
- **OtlPlatform.pas** — Clean.
- **OtlLogger.pas** — Clean.

---

## Cross-Reference with Earlier Categories

Several findings in this category were also flagged under different categories:
- **OtlContainers.pas:1779** `PropagateNotifications` `Low..Low` loop — already reported as Critical in Category 1 (1.5 Event/Signal Correctness). Not duplicated here.
- **OtlThreadPool.pas:1006** Cancel timeout — also surfaces as a logic error (Category 4). Listed here as the root cause is a copy-paste from `InternalStop`.
- **OtlHooks.pas Register/Unregister** — also listed under Category 2 (2.2 Use-After-Free) for the dangling pointer aspect.

---

## Top 5 Findings by Impact

1. **OtlHooks.pas:351** — All proc-variant Register/Unregister store dangling stack pointers (Critical)
2. **OtlContainers.pas:923** — `IsFull` compares against `LastIn` instead of `FirstIn` — ring buffer overflow (Critical)
3. **OtlParallel.pas:4634** — `PInteger` instead of `PNativeInt` on 64-bit — wrong pipeline stage dispatch (Critical)
4. **OtlTaskControl.pas:2458** — `RemoveTerminationEvents` missing 3 fields — broken `ProcessMessages` dispatch (High)
5. **OtlThreadPool.pas:1006** — Cancel timeout 1000x too long (High)

---

## Summary by Severity

| Severity | Count | Key Findings |
|----------|-------|-------------|
| **Critical** | 3 | OtlHooks dangling stack pointers in Register/Unregister; OtlContainers IsFull wrong comparand; OtlParallel PInteger/PNativeInt mismatch |
| **High** | 4 | OtlContainers wrong threshold for PartlyEmpty; OtlTaskControl RemoveTerminationEvents missing fields; OtlThreadPool Cancel timeout * 1000; OtlSync Move128 32-bit only moves 8 bytes |
| **Medium** | 4 | OtlSync CAS16 offset mask; OtlSync CreateOmniEvent broken factory; OtlParallel two OnStopInvoke missing nil guards |
| **Low** | 10 | Wrong class/method names in error messages and end comments across OtlContainers, OtlTaskControl, OtlCommon, OtlContainerObserver, OtlComm |

---
---

# Static Analysis Results — Category 4: Logic Errors

**Date**: 2026-04-14
**Scope**: All 18 units listed in STATIC-ANALYSIS-SPEC.md
**Categories covered**: 4.1 Off-By-One Errors, 4.2 Integer Overflow / Type Mismatch, 4.3 Missing or Wrong Error Handling, 4.4 Boolean Logic

**Summary**: 2 Critical, 4 High, 6 Medium, 4 Low findings across 7 units.

---

## OtlThreadPool.pas

### ~~Cancel doubles an already-millisecond timeout with `* 1000`~~ — Severity: Critical — FINISHED
**File**: `OtlThreadPool.pas:1006`
**Category**: 4.2 Integer Overflow / Type Mismatch
**Description**: In `TOTPWorker.Cancel`, when `waitForTask_ms < 0`, the code sets `waitForTask_ms` from `WaitOnTerminate_sec * 1000` (converting seconds to milliseconds — correct). But then on line 1006 it computes `endWait_ms := Time.Timestamp_ms + waitForTask_ms * 1000`, multiplying the **already-millisecond** value by 1000 again. This makes every cancel wait 1000x longer than intended.
**Evidence**:
```pascal
waitForTask_ms := params[2];
if waitForTask_ms < 0 then
  waitForTask_ms := int64(WaitOnTerminate_sec.Value) * 1000;  // now in ms
wasTerminated := true;
iWorker := 0;
while iWorker < owRunningWorkers.Count do begin
  ...
  endWait_ms := Time.Timestamp_ms + waitForTask_ms * 1000;  // BUG: ms * 1000 again!
```
**Risk**: A cancel with the default `WaitOnTerminate_sec` of 5 would wait 5,000,000 ms (~83 minutes) instead of 5,000 ms (5 seconds). The thread pool appears to hang on cancel operations.
**Suggested fix**: Change line 1006 to `endWait_ms := Time.Timestamp_ms + waitForTask_ms;` (the value is already in milliseconds).

---

## OtlContainers.pas

### ~~CollectionNotifyEvent uses wrong threshold for PartlyEmpty~~ — Severity: Critical — FINISHED
**File**: `OtlContainers.pas:1715`
**Category**: 4.4 Boolean Logic
**Description**: In `TOmniValueQueue.CollectionNotifyEvent`, the `cnRemoved`/`cnExtracted` branch checks `AfterCount = FAlmostFullThreshold` to fire `coiNotifyOnPartlyEmpty`. It should check `AfterCount = FPartlyEmptyThreshold`. This means the "partly empty" notification fires at 90% load (almost full threshold) instead of at 80% load (partly empty threshold).
**Evidence**:
```pascal
cnRemoved,
cnExtracted:
  begin
    Include(FNotifiableEvents, coiNotifyOnAllRemoves);
    if AfterCount = FAlmostFullThreshold then           // BUG: should be FPartlyEmptyThreshold
      Include(FNotifiableEvents, coiNotifyOnPartlyEmpty);
  end;
```
**Risk**: `coiNotifyOnPartlyEmpty` is only fired when the count happens to exactly equal the almost-full threshold, which is the wrong semantic. The threshold comparison may also need `<=` instead of `=` since an exact match is fragile (bulk removes can skip the exact value).
**Suggested fix**: Change `FAlmostFullThreshold` to `FPartlyEmptyThreshold`. Consider using `<=` for robustness: `if AfterCount <= FPartlyEmptyThreshold then`.

---

## OtlCommon.pas

### ~~`{$IFDEF Defined(...)}` is always false — dead optimization code~~ — Severity: High — FINISHED
**File**: `OtlCommon.pas:4281` (and 4300, 4405, 4424)
**Category**: 4.4 Boolean Logic
**Description**: Four locations use `{$IFDEF Defined(CPU386) or Defined(CPUX64)}` to select between direct memory access and interlocked operations. However, `{$IFDEF}` takes a single symbol name — it does not understand `Defined()` or `or` expressions. The literal symbol `Defined(CPU386) or Defined(CPUX64)` is never defined, so the `{$IFDEF}` block is always skipped. The correct form is `{$IF Defined(CPU386) or Defined(CPUX64)}`.
**Evidence**:
```pascal
function TOmniAlignedInt32.GetValue: integer;
begin
{$IFDEF Defined(CPU386) or Defined(CPUX64)}   // NEVER TRUE
  Result := Addr^;                              // dead code
{$ELSE}
  Result := TInterlocked.CompareExchange(integer(Addr^), 0, 0);  // always used
{$ENDIF}
end;
```
**Risk**: The interlocked fallback path is functionally correct, so behavior is not broken. However, every `TOmniAlignedInt32.GetValue`/`SetValue` and `TOmniAlignedInt64.GetValue`/`SetValue` call on x86/x64 pays an unnecessary interlocked operation cost. For `TOmniAlignedInt32`, this is used heavily in hot paths (container counts, resource counts).
**Suggested fix**: Change all four occurrences to `{$IF Defined(CPU386) or Defined(CPUX64)}` ... `{$IFEND}`.

---

## OtlCommon.pas

### ~~GetLastError called without qualification may call wrong function~~ — Severity: High — FALSE REPORT
**Reason**: No local GetLastError override exists in the codebase.
**File**: `OtlCommon.pas:3424`
**Category**: 4.3 Missing or Wrong Error Handling
**Description**: In `TOmniAffinity.GetCountPhysical`, `GetLastError` is called without the `Winapi.Windows.` qualification. Per the CLAUDE.md rule, the codebase may implement its own `GetLastError` method. Additionally, on line 3424, `GetLastError` is called after `GetLogicalProcessorInformation(nil, bufLen)` which correctly sets the Win32 error, but any intervening Delphi RTL call could reset it.
**Evidence**:
```pascal
bufLen := 0;
GetLogicalProcessorInformation(nil, bufLen);
if GetLastError <> ERROR_INSUFFICIENT_BUFFER then   // unqualified
  Result := GetCount
```
**Risk**: If the codebase has its own `GetLastError` function (search shows qualified uses in OtlBackgroundObserver and OtlCommon lines 3635/3637/3991/3995), calling the wrong `GetLastError` would return a stale or wrong error code, causing the NUMA detection to silently fall back to incorrect topology.
**Suggested fix**: Qualify as `Winapi.Windows.GetLastError`.

### ~~Double GetLastError calls may return different values~~ — Severity: Medium — FINISHED
**File**: `OtlCommon.pas:3635-3637`
**Category**: 4.3 Missing or Wrong Error Handling
**Description**: In `TOmniThreadEnvironment.GetGroupAffinity`, `Winapi.Windows.GetLastError` is called three times: first to compare against `ERROR_NOT_SUPPORTED`, then twice in the exception format string. Each call is independent; although on x86 Windows `GetLastError` is thread-local and stable until next API call, the pattern is fragile.
**Evidence**:
```pascal
else if Winapi.Windows.GetLastError <> ERROR_NOT_SUPPORTED then
  raise Exception.CreateFmt(
    'TOmniThreadEnvironment.GetGroupAffinity: ... failed with [%d] %s',
    [Winapi.Windows.GetLastError, SysErrorMessage(Winapi.Windows.GetLastError)])
```
**Risk**: If `GetLastError` is called and some intervening call (like memory allocation for the format string) resets it, the exception message would contain error code 0 (ERROR_SUCCESS) instead of the actual error. This makes debugging very difficult.
**Suggested fix**: Capture `GetLastError` once into a local variable before using it.

### ~~Sequential double GetLastError calls in NUMA detection~~ — Severity: Medium — FINISHED
**File**: `OtlCommon.pas:3991-3995`
**Category**: 4.3 Missing or Wrong Error Handling
**Description**: In `TOmniProcessEnvironment.ReadProcessorGroups`, after calling `GetLogicalProcessorInformationEx`, `GetLastError` is called twice sequentially: first to check for `ERROR_NOT_SUPPORTED`, and if that test fails, again to check for `ERROR_INSUFFICIENT_BUFFER`. The second call is only valid if the first comparison failed without any intervening API calls — but critically, if the first check succeeds (error IS `ERROR_NOT_SUPPORTED`), the code enters the `if` branch and exits. If it fails, the error code is still valid for the second check.
**Evidence**:
```pascal
GetLogicalProcessorInformationEx(RelationAll, ..., bufSize);
if Winapi.Windows.GetLastError = ERROR_NOT_SUPPORTED then begin
  CreateFakeNUMAInfo;
  Exit;
end;
if Winapi.Windows.GetLastError <> ERROR_INSUFFICIENT_BUFFER then begin  // second call
  CreateFakeNUMAInfo;
  Exit;
end;
```
**Risk**: The pattern is technically correct on Windows (GetLastError is stable until next WinAPI call), but fragile. If code between the two checks is ever added, or if Delphi RTL calls a WinAPI function internally, the second `GetLastError` would return a stale value.
**Suggested fix**: Capture the error code once: `var lastErr := Winapi.Windows.GetLastError;` then test `lastErr` in both comparisons.

---

## OtlSync.pas

### ~~TOmniLockManager.Lock passes negative wait_ms as cardinal~~ — Severity: High — FINISHED
**File**: `OtlSync.pas:1952-1953`
**Category**: 4.2 Integer Overflow / Type Mismatch
**Description**: In `TOmniLockManager<K>.Lock`, `wait_ms` is computed as `integer(timeout_ms) - integer(Time.Elapsed_ms(startWait))`. When the elapsed time exceeds the timeout, `wait_ms` becomes negative. This negative value is then passed to `waitEvent.WaitFor(cardinal(wait_ms))`, which casts it to a very large positive cardinal, causing an extremely long wait instead of an immediate timeout.
**Evidence**:
```pascal
  finally FLock.Release; end;
  wait_ms := integer(timeout_ms) - integer(Time.Elapsed_ms(startWait));
  waitResult := waitEvent.WaitFor(cardinal(wait_ms));  // negative -> huge cardinal
until ((timeout_ms <> INFINITE) and (wait_ms <= 0)) or
      (waitResult = wrTimeout);
```
**Risk**: If the lock is contested and the timeout expires mid-loop, the code passes a value like `cardinal(-500)` = 4,294,966,796 to `WaitFor`, causing a ~49-day hang instead of timing out immediately. The `until` condition will eventually catch it after the wait, but not before the spurious long wait.
**Suggested fix**: Clamp `wait_ms` to 0 before passing to `WaitFor`:
```pascal
if wait_ms <= 0 then
  break; // timeout expired
waitResult := waitEvent.WaitFor(cardinal(wait_ms));
```

### ~~TCondition.Wait timeout_ms check allows zero-timeout to enter wait loop~~ — Severity: Low — FALSE REPORT
**Reason**: Cardinal can't be negative, code is correct. The <= 0 is equivalent to = 0 which is the intended behavior.
**File**: `OtlSync.pas:2107`
**Category**: 4.4 Boolean Logic
**Description**: The condition `timeout_ms <= 0` is checked using unsigned `cardinal` comparison. Since `timeout_ms` is `cardinal`, it can never be less than 0 — the `<= 0` is equivalent to `= 0`. While functionally correct (zero timeout means "don't wait"), using `<=` on an unsigned type is misleading and suggests the developer expected signed values.
**Evidence**:
```pascal
else if (timeout_ms <= 0) or (timeout_ms <= timer.ElapsedMilliseconds) then
  Result := wrTimeout
```
**Risk**: No runtime impact — `cardinal` can't be negative. This is a readability issue that could lead to future maintenance errors if the parameter type changes to signed.
**Suggested fix**: Use `timeout_ms = 0` for clarity, or change the parameter to a signed type if zero-means-don't-wait semantics are intended.

---

## OtlTaskControl.pas

### ~~ReportInvalidHandle calls unqualified GetLastError~~ — Severity: Medium — FALSE REPORT
**Reason**: No local GetLastError override exists in the codebase.
**File**: `OtlTaskControl.pas:2481`
**Category**: 4.3 Missing or Wrong Error Handling
**Description**: `ReportInvalidHandle` calls `SysErrorMessage(GetLastError)` without the `Winapi.Windows.` qualification. Per the CLAUDE.md coding standard, this should be qualified to avoid calling a potential local `GetLastError` method.
**Evidence**:
```pascal
procedure TOmniTaskExecutor.ReportInvalidHandle(msgInfo: TOmniMessageInfo);
var
  failedList: string;
  iHandle   : integer;
begin
  failedList := SysErrorMessage(GetLastError);  // unqualified
```
**Risk**: If a local `GetLastError` exists, the wrong error code would be included in the exception message, making it harder to debug handle failures.
**Suggested fix**: Qualify as `Winapi.Windows.GetLastError`.

### ~~WaitForEvent debug log calls GetLastError after intervening API calls~~ — Severity: Low — FALSE REPORT
**Reason**: Debug log only; not production code.
**File**: `OtlTaskControl.pas:2648`
**Category**: 4.3 Missing or Wrong Error Handling
**Description**: In `WaitForEvent`, the debug-only `GetLastError` call occurs after `WaitForMultipleObjectsEx` (line 2640) and `DrainBackgroundObservers` — both of which may reset the Win32 error code. By the time `GetLastError` is called, it may no longer reflect the error from the `WaitAny` call that returned `waFailed`.
**Evidence**:
```pascal
WaitForMultipleObjectsEx(0, nil, false, 0, true); // drain pending APCs
{$ENDIF MSWINDOWS}
{$IFNDEF OTL_HasAPC}
DrainBackgroundObservers;
{$ENDIF}
{$IFDEF Debug}
if Result = waFailed then
  OutputDebugString(PChar(Format('... failed with error [%d] %s',
    [GetLastError, SysErrorMessage(GetLastError)])));  // stale error code
{$ENDIF Debug}
```
**Risk**: Debug output may show error code 0 (ERROR_SUCCESS) instead of the actual failure cause. Debug-only, so no production impact.
**Suggested fix**: Capture `GetLastError` immediately after the wait operation, before calling any intervening API functions.

---

## OtlParallel.pas

### ~~Two OnStopInvoke implementations don't guard against nil task~~ — Severity: Medium — FINISHED
**File**: `OtlParallel.pas:3680` and `OtlParallel.pas:4882`
**Category**: 4.3 Missing or Wrong Error Handling
**Description**: `TOmniParallelLoop.OnStopInvoke` and `TOmniPipeline.OnStopInvoke` call `task.Invoke(...)` without checking `assigned(task)`. Other implementations (`TOmniParallelJoin.OnStopInvoke` at line 2221, `TOmniParallelLoop<T>.OnStopInvoke` at line 3942, `TOmniParallelSimpleLoop.OnStopInvoke` at line 4315) correctly include `if not assigned(task) then stopCode() else task.Invoke(...)`.
**Evidence**:
```pascal
// TOmniParallelLoop.OnStopInvoke — NO nil guard
function TOmniParallelLoop.OnStopInvoke(stopCode: TProc): IOmniParallelLoop;
begin
  Result := OnStop(
    procedure (const task: IOmniTask)
    begin
      task.Invoke(          // AV if task is nil
        procedure begin stopCode(); end);
    end);
end;

// TOmniParallelJoin.OnStopInvoke — HAS nil guard (correct)
function TOmniParallelJoin.OnStopInvoke(const stopCode: TProc): IOmniParallelJoin;
begin
  Result := OnStop(
    procedure (const task: IOmniTask)
    begin
      if not assigned(task) then   // safe
        stopCode()
      else
        task.Invoke(
          procedure begin stopCode(); end);
    end);
end;
```
**Risk**: Access violation if OnStop is called with a nil task parameter (which the history notes at line 72 indicates has happened before: "Using Parallel.Join.OnStopInvoke failed with access violation if Join was not executed with .NoWait").
**Suggested fix**: Add `if not assigned(task) then stopCode() else` guard to both `TOmniParallelLoop.OnStopInvoke` and `TOmniPipeline.OnStopInvoke`.

---

## OtlDataManager.pas

### ~~TOmniIntegerDataPackage.GetNext position tracking not thread-safe~~ — Severity: Medium — FINISHED
**File**: `OtlDataManager.pas:469-477`
**Category**: 4.1 Off-By-One Errors
**Description**: In `TOmniIntegerDataPackage.GetNext(var position, var value)`, the `idpPosition` field is incremented non-atomically (`Inc(idpPosition)`), while the corresponding value is fetched via the atomic `idpLow.Add(idpStep)`. If two threads call `GetNext` simultaneously, they each get a unique value from the atomic `idpLow.Add`, but they may get the same `idpPosition` due to the non-atomic increment, or positions may be assigned out of order relative to values.
**Evidence**:
```pascal
function TOmniIntegerDataPackage.GetNext(var position: int64; var value: TOmniValue):
  boolean;
begin
  Result := GetNext(value);   // atomic via idpLow.Add
  if Result then begin
    position := idpPosition;  // non-atomic read
    Inc(idpPosition);         // non-atomic increment
  end;
end;
```
**Risk**: When `dmoPreserveOrder` is active and multiple threads access the same data package, position values can be duplicated or reordered, corrupting the output ordering.
**Suggested fix**: Use an atomic operation: `position := TInterlocked.Increment(idpPosition) - 1` (or use `TOmniAlignedInt64` for `idpPosition`).

---

## OtlThreadPool.pas

### ~~Empty except block silently swallows ThreadData destruction errors~~ — Severity: Low — FALSE REPORT
**Reason**: The except block is intentional cleanup code; thread data destruction must not propagate exceptions as it would prevent MSG_THREAD_DESTROYING from being sent.
**File**: `OtlThreadPool.pas:796-799`
**Category**: 4.3 Missing or Wrong Error Handling
**Description**: In `TOTPWorkerThread.Execute`, the `try owtThreadData := nil; except end;` block silently swallows any exception thrown during thread data destruction. While this is intentional (the code must continue to send `MSG_THREAD_DESTROYING`), there's no logging or notification of the failure.
**Evidence**:
```pascal
      try
        owtThreadData := nil;
      except
      end;
    finally Comm.Send(MSG_THREAD_DESTROYING, threadID); end;
```
**Risk**: If the thread data factory creates objects whose destructors fail (e.g., database connections that throw on close), the failure is completely invisible. Debugging resource leaks becomes very difficult.
**Suggested fix**: At minimum, log the exception before swallowing it, or pass it to `owtAsy_OnUnhandledException`.

### ~~TOmniAlignedInt32 operator Add returns cardinal from int64 arithmetic~~ — Severity: Low — FALSE REPORT
**Reason**: The operator is intentionally designed for unsigned arithmetic on aligned counters. The int64 intermediate prevents overflow during computation, and the cardinal result is the intended type for counter use cases.
**File**: `OtlCommon.pas:4307-4310`
**Category**: 4.2 Integer Overflow / Type Mismatch
**Description**: The `TOmniAlignedInt32.Add` class operator computes `cardinal(int64(ai.Value) + i)`. If `ai.Value` is near `MaxInt` and `i` is positive, the `int64` intermediate is correct, but the `cardinal()` cast truncates to 32 bits. Since the operator returns `cardinal` but `TOmniAlignedInt32.Value` is signed `integer`, mixing signed/unsigned is confusing and can produce unexpected results when the value is negative.
**Evidence**:
```pascal
class operator TOmniAlignedInt32.Add(const ai: TOmniAlignedInt32; i: integer): cardinal;
begin
  Result := cardinal(int64(ai.Value) + i);
end;
```
**Risk**: If `ai.Value` is negative (e.g., `-1`) and `i` is `0`, the result is `cardinal(-1)` = 4294967295. Code using this operator expecting integer semantics would get surprising results.
**Suggested fix**: Consider changing the return type to `integer` for consistency with the underlying field type, or document that this operator is intentionally for unsigned arithmetic.

---

## Summary

| Severity | Count | Key Findings |
|----------|-------|-------------|
| **Critical** | 2 | OtlThreadPool Cancel timeout doubled (ms * 1000 on already-ms value); OtlContainers CollectionNotifyEvent uses wrong threshold for PartlyEmpty |
| **High** | 3 | OtlCommon `{$IFDEF Defined()}` always false — dead optimization; OtlCommon unqualified GetLastError; OtlSync LockManager passes negative wait_ms as cardinal |
| **Medium** | 5 | OtlCommon double GetLastError calls; OtlCommon sequential GetLastError in NUMA; OtlTaskControl unqualified GetLastError; OtlParallel two OnStopInvoke missing nil guards; OtlDataManager non-atomic position tracking |
| **Low** | 4 | OtlSync cardinal <= 0 comparison; OtlTaskControl stale GetLastError in debug log; OtlThreadPool silent except block; OtlCommon signed/unsigned operator mismatch |

---

# Static Analysis Results — Category 5: API Contract Violations

**Date**: 2026-04-14
**Scope**: All 18 units listed in STATIC-ANALYSIS-SPEC.md
**Categories covered**: 5.1 Interface Contract Consistency, 5.2 Precondition Checking, 5.3 Callback Safety

**Summary**: 7 Critical/High, 18 Medium, 9 Low findings across 14 units.

---

## OtlHooks.pas

### ~~Procedure pointer registration stores stack address instead of function address~~ — Severity: Critical — FALSE REPORT
**Reason**: With `{$T-}` (default untyped `@` operator), `@notifyProc` returns the code address value, not the address of the local parameter. The code is correct.
**File**: `OtlHooks.pas:351`, `361`, `409`, `419`, `471`, `481`
**Category**: 5.1 Interface Contract Consistency
**Description**: All six `Register`/`Unregister` methods for procedure-type callbacks store `pointer(@notifyProc)` — the address of the **local parameter variable on the stack** — rather than the procedure pointer value itself. The parameter `notifyProc` is a by-value local copy; `@notifyProc` yields a stack address that becomes invalid as soon as the method returns. The correct expression is `pointer(notifyProc)` (the value of the proc pointer). This is a copy-and-paste pattern repeated in all three notification classes (`TThreadNotifications`, `TPoolNotifications`, `TExceptionFilters`). The `TMethod` overloads are correct.
**Evidence**:
```pascal
procedure TThreadNotifications.Register(notifyProc: TThreadNotificationProc);
begin
  tnList.Add(pointer(@notifyProc));   // BUG: stores stack address of local param
end;

procedure TThreadNotifications.Unregister(notifyProc: TThreadNotificationProc);
begin
  tnList.Remove(pointer(@notifyProc)); // BUG: different stack address — never matches
end;

// Same pattern in TPoolNotifications.Register/Unregister and TExceptionFilters.Register/Unregister
```
**Risk**: Stored pointer is a dangling stack address, invalid immediately. `Unregister` will always fail (stored value never matches a new stack address). During `Notify`, `TThreadNotificationProc(tnList[iObserver+1])` dereferences garbage, causing an access violation or a silent call to a random address. This affects all procedure-type notification hooks.
**Suggested fix**: Change `pointer(@notifyProc)` to `pointer(notifyProc)` in all six methods.

---

### ~~Notification callbacks executed while read lock is held~~ — Severity: High — FINISHED
**File**: `OtlHooks.pas:325-347`, `383-405`, `441-462`
**Category**: 5.3 Callback Safety
**Description**: `TThreadNotifications.Notify`, `TPoolNotifications.Notify`, and `TExceptionFilters.Filter` all acquire a read lock on the internal list and then directly invoke user-provided callbacks without releasing the lock. If a callback attempts to register or unregister a notification (which requires a write lock on the same `TOmniMREW`), a deadlock occurs since `TOmniMREW` does not allow upgrading a read lock to a write lock on the same thread.
**Evidence**:
```pascal
procedure TThreadNotifications.Notify(...);
begin
  tnList.EnterReadLock;
  try
    iObserver := 0;
    while iObserver < tnList.Count do begin
      if tnList[iObserver] = nil then
        TThreadNotificationProc(tnList[iObserver+1])(notifyType, threadName)  // callback under lock
      else begin
        ...
        TThreadNotificationMeth(meth)(notifyType, threadName);  // callback under lock
      end;
      Inc(iObserver, 2);
    end;
  finally tnList.ExitReadLock; end;
end;
```
**Risk**: A "one-shot" hook that unregisters itself in its callback body will deadlock. Any callback that calls `Register`/`Unregister` for the same notification type will deadlock.
**Suggested fix**: Copy the list snapshot while holding the lock, release the lock, then iterate over the snapshot and invoke callbacks.

---

## OtlSync.pas

### ~~Broken double-checked locking in `Locked<T>.Initialize`~~ — Severity: Critical — FINISHED
**File**: `OtlSync.pas:1735-1753`
**Category**: 5.2 Precondition Checking / 5.1 Interface Contract Consistency
**Description**: `Locked<T>.Initialize(factory)` implements a double-checked locking pattern but creates the `FLock` object inside the unprotected outer check. Two threads can both observe `FInitialized = false`, both execute `FLock := TLightweightMREWExImpl.Create`, and both acquire their own independently-created lock instances. The second lock leaks, and neither thread is mutually excluded from calling `factory()`.
**Evidence**:
```pascal
function Locked<T>.Initialize(factory: TFactory): T;
begin
  if not FInitialized then begin         // unsynchronized read
    FLock := TLightweightMREWExImpl.Create; // both threads create their own FLock
    ...
    Acquire;                             // each thread acquires its own FLock!
    try
      if not FInitialized then begin
        FValue := factory();             // factory may be called twice
        FInitialized := true;
      end;
    finally Release; end;
  end;
  Result := FValue;
end;
```
**Risk**: `factory()` can be called multiple times on concurrent first-use. If `factory()` allocates a resource (file handle, object), one instance is leaked. If `factory()` has side effects, they are doubled.
**Suggested fix**: Use a module-level lock for the first-initialization phase (similar to `GOmniCSInitializer` in `TOmniCS.Initialize`), or use `TInterlocked.CompareExchange` on the `FLock` pointer after creation and free the losing instance.

---

### ~~Incomplete `TOmniWrappedEvent` ownership — raises exception on valid API use~~ — Severity: High — FINISHED
**File**: `OtlSync.pas:2709-2726`
**Category**: 5.1 Interface Contract Consistency
**Description**: `CreateOmniEvent(AExternalEvent: THandle; ATakeOwnership: boolean)` is a public API that promises to optionally take ownership of the passed handle. The backing `TOmniWrappedEvent` class raises an exception unconditionally when `ATakeOwnership = true`. The condition check `(FHandle <> 0)` is also wrong — `FHandle` is the auto-created handle from `inherited Create(nil, false, false, '')`, not the parameter.
**Evidence**:
```pascal
constructor TOmniWrappedEvent.Create(AExternalEvent: THandle; ATakeOwnership: boolean);
begin
  inherited Create(nil, false, false, '');
  if (FHandle <> 0) and ATakeOwnership then // TODO : *** recheck
    raise Exception.Create('TOmniWrappedEvent.Create: Owned events are not supported yet');
  FHandle := AExternalEvent;
  FIsOwner := ATakeOwnership;
end;
```
**Risk**: Any caller passing `ATakeOwnership = true` gets an immediate exception. The public API contract is broken.
**Suggested fix**: Implement handle ownership correctly: close the pre-created inherited handle, store `AExternalEvent`, and honor `ATakeOwnership` in the destructor. Add an `AManualReset` parameter.

---

### ~~`FManualReset` unset for handle-wrapped events~~ — Severity: Medium — FINISHED
**File**: `OtlSync.pas:2752-2760`
**Category**: 5.1 Interface Contract Consistency
**Description**: `TOmniEvent.Create(AExternalEvent: THandle, ...)` never sets `FManualReset`. It defaults to `false`. When the event is consumed by an observer (via `ConsumeSignalFromObserver`), `FEvent.ResetEvent` is always called, treating it as auto-reset regardless of the actual event type.
**Evidence**:
```pascal
procedure TOmniEvent.ConsumeSignalFromObserver(const Observer: IOmniSynchroObserver);
begin
  // TODO at the moment, FManualReset is not set when event is created by wrapping an external THandle
  if not FManualReset then begin  // always false for handle-wrapped events
    FEvent.ResetEvent;            // always resets — wrong for manual-reset events
    FState := False;
  end
end;
```
**Risk**: A manual-reset Win32 event wrapped with `CreateOmniEvent(handle, false)` will be incorrectly auto-reset inside `TWaitFor`, changing its semantics.
**Suggested fix**: Add an explicit `AManualReset` parameter to the handle-wrapping `CreateOmniEvent` overload, or probe the event's type with `NtQueryEvent`.

---

### ~~Unprotected `FState` write in `TOmniEvent.WaitFor`~~ — Severity: Medium — FINISHED
**File**: `OtlSync.pas:2797-2798`
**Category**: 5.2 Precondition Checking
**Description**: `TOmniEvent.WaitFor` modifies `FState := False` after the wait returns, without holding the gate lock or the spin lock. All other modifications to `FState` happen inside `PerformObservableAction` which acquires the gate. A concurrent `SetEvent` or `Reset` on another thread can race with this write.
**Evidence**:
```pascal
function TOmniEvent.WaitFor(Timeout: Cardinal): TWaitResult;
begin
  Result := inherited WaitFor(Timeout);
  if (Result = wrSignaled) and (not FManualReset) then
    FState := False;   // unprotected write — no lock held
end;
```
**Risk**: Data race on `FState` between `WaitFor` and concurrent `SetEvent`/`Reset`. `IsSignalled` may return inconsistent results.
**Suggested fix**: Move `FState := False` for auto-reset into `ConsumeSignalFromObserver` (which runs under the gate lock) for the observer path. For the direct `WaitFor` path, acquire the spin lock before clearing `FState`.

---

### ~~`BeforeSignal`/`AfterSignal` callbacks called while gate lock is held~~ — Severity: Medium — CONFIRMED, DEFERRED
**File**: `OtlSync.pas:2567-2571`
**Category**: 5.3 Callback Safety
**Description**: `PerformObservableAction` enters the gate lock and then invokes `BeforeSignal` and `AfterSignal` callbacks on all observers while those gates remain held. The callback context (which thread, which locks held) is not documented in the `IOmniSynchroObserver` interface.
**Evidence**:
```pascal
for iObserver := 0 to count - 1 do
  observersCopy[iObserver].BeforeSignal(self, localData[iObserver]);
Action;
for iObserver := 0 to count - 1 do
  observersCopy[iObserver].AfterSignal(self, localData[iObserver]);
// Gate released only in finally below
```
**Risk**: Any `IOmniSynchroObserver` implementation that attempts to acquire additional locks during `BeforeSignal`/`AfterSignal` risks deadlock.
**Suggested fix**: Document in `IOmniSynchroObserver` that callbacks are invoked while the gate lock is held.

---

### ~~Re-entrant gate lock in `TCondition.Test` — undocumented dependency~~ — Severity: Low — CONFIRMED, DEFERRED
**File**: `OtlSync.pas:2377`, `2398`
**Category**: 5.2 Precondition Checking
**Description**: `TOneCondition.Test` and `TAllCondition.Test` unconditionally acquire `FController.Gate`. All callers already hold the gate. This works because Windows critical sections are re-entrant, but it is undocumented.
**Evidence**:
```pascal
// TCondition.Wait already holds the gate:
FController.FGate.Acquire;
try
  if Test(signaller1) then   // Test also acquires FController.Gate

// TOneCondition.Test:
FController.Gate.Acquire;    // second acquisition of same CS
```
**Risk**: Silent dependency on re-entrancy. Any future refactor replacing the CS with a non-re-entrant lock will deadlock.
**Suggested fix**: Remove the gate acquire/release from `Test` and document it must only be called while the gate is held.

---

### ~~`TOmniResourceCount.TryAllocate` misleading cardinal comparison~~ — Severity: Low — FALSE REPORT
**Reason**: Cardinal can't be negative, code is correct. The <= 0 is equivalent to = 0 which is the intended behavior.
**File**: `OtlSync.pas:1390`
**Category**: 5.2 Precondition Checking
**Description**: `timeout_ms` is `cardinal` (unsigned), so `timeout_ms <= 0` is equivalent to `timeout_ms = 0`. The `<= 0` form is misleading.
**Evidence**:
```pascal
function TOmniResourceCount.TryAllocate(var resourceCount: cardinal;
  timeout_ms: cardinal): boolean;
...
  if timeout_ms <= 0 then  // equivalent to = 0; misleading for cardinal
    Exit;
```
**Risk**: Low. Code functions correctly but intent is unclear.
**Suggested fix**: Change to `if timeout_ms = 0 then`.

---

## OtlContainers.pas

### ~~`TOmniBaseBoundedStack.Empty` does not acquire lock in non-CAS path~~ — Severity: High — FINISHED
**File**: `OtlContainers.pas:470-480`
**Category**: 5.2 Precondition Checking
**Description**: `TOmniBaseBoundedStack.Empty` calls `PopLink` and `PushLink` in a loop but does not call `Acquire`/`Release`. In the non-lock-free path (`{$IFNDEF OTL_HaveCmpx16b}`), `PopLink` and `PushLink` manipulate chain pointers without synchronization. This is inconsistent with `Pop` and `Push`, which both wrap themselves in `Acquire`/`Release`. `TOmniBaseBoundedQueue.Empty` (lines 776-790) does acquire the lock.
**Evidence**:
```pascal
procedure TOmniBaseBoundedStack.Empty;
var
  linkedData: POmniLinkedData;
begin
  repeat
    linkedData := PopLink(obsPublicChainP^);
    if not assigned(linkedData) then
      break; //repeat
    PushLink(linkedData, obsRecycleChainP^);
  until false;
end;
```
**Risk**: Concurrent calls to `Empty` with `Pop`/`Push` in the non-CAS path can produce dangling-pointer chains and use-after-free crashes.
**Suggested fix**: Wrap the body of `TOmniBaseBoundedStack.Empty` in `Acquire`/`Release`.

---

### ~~`TOmniBaseBoundedStack.IsEmpty`/`IsFull` read shared pointers without lock~~ — Severity: Medium — CONFIRMED, DEFERRED
**File**: `OtlContainers.pas:524-531`
**Category**: 5.2 Precondition Checking
**Description**: `IsEmpty` and `IsFull` directly read `obsPublicChainP^.PData` and `obsRecycleChainP^.PData` without acquiring `obsLock`. In the non-CAS path, all mutations go through `Acquire`/`Release` which delegate to `obsLock`. The unprotected reads from `IsEmpty`/`IsFull` are inconsistent with how `Pop`/`Push`/`Empty` protect themselves.
**Evidence**:
```pascal
function TOmniBaseBoundedStack.IsEmpty: boolean;
begin
  Result := not assigned(obsPublicChainP^.PData);
end;

function TOmniBaseBoundedStack.IsFull: boolean;
begin
  Result := not assigned(obsRecycleChainP^.PData);
end;
```
**Risk**: Non-CAS callers could observe incorrect empty/full state. Stale reads could cause missed enqueues or unnecessary spins.
**Suggested fix**: Acquire the lock before reading under `{$IFNDEF OTL_HaveCmpx16b}`, or document that the result is advisory.

---

### ~~`TOmniBaseBoundedQueue.IsEmpty` reads without lock, inconsistent with `IsFull`~~ — Severity: Medium — FINISHED
**File**: `OtlContainers.pas:909-912`
**Category**: 5.2 Precondition Checking
**Description**: `TOmniBaseBoundedQueue.IsEmpty` directly compares two shared pointers without calling `Acquire`. `IsFull` on the same class (lines 914-926) wraps itself in `Acquire`/`Release`. This is an inconsistent contract.
**Evidence**:
```pascal
function TOmniBaseBoundedQueue.IsEmpty: boolean;
begin
  Result := (obqPublicRingBuffer.FirstIn.PData = obqPublicRingBuffer.LastIn.PData);
end;

function TOmniBaseBoundedQueue.IsFull: boolean;
begin
  Acquire;
  try
    ...
  finally Release; end;
end;
```
**Risk**: `IsFull` is protected but `IsEmpty` is not. Inconsistent API contract.
**Suggested fix**: Guard `IsEmpty` with `Acquire`/`Release` to match `IsFull`, or document both as advisory.

---

### ~~Observer callbacks called while internal lock is held — deadlock risk~~ — Severity: Medium — CONFIRMED, DEFERRED
**File**: `OtlContainers.pas:705-729`, `1066-1090`
**Category**: 5.3 Callback Safety
**Description**: `TOmniBoundedStack.Pop/Push` and `TOmniBoundedQueue.Dequeue/Enqueue` call `ContainerSubject.Notify` and `NotifyOnce` after the data operation returns but still in the same call frame. `Notify` acquires a read lock on the per-interest list and calls `observer.Notify`. No documentation warns that observer callbacks must not re-enter the container.
**Evidence** (TOmniBoundedStack.Pop):
```pascal
function TOmniBoundedStack.Pop(var value): boolean;
begin
  Result := inherited Pop(value);
  if Result then begin
    countAfter := osInStackCount.Decrement;
    ContainerSubject.Notify(coiNotifyOnAllRemoves);
    if countAfter <= osPartlyEmptyCount then
      ContainerSubject.NotifyOnce(coiNotifyOnPartlyEmpty);
  end;
end;
```
**Risk**: Re-entrant observer callbacks on the same container will deadlock in `obsLock` or `csListLocks`.
**Suggested fix**: Document that observer callbacks must not re-enter the container, or queue notifications for delivery after the lock is released (as `TOmniValueQueue.DoWithCritSec` correctly does).

---

### ~~`TOmniValueQueue.IsEmpty` missing try/finally around critical section~~ — Severity: Low — FALSE REPORT
**Reason**: Body cannot raise an exception; TQueue.Count is a simple field read. Duplicate of earlier finding.
**File**: `OtlContainers.pas:1767-1772`
**Category**: 5.2 Precondition Checking
**Description**: `TOmniValueQueue.IsEmpty` calls `EnterCriticalSection`/`LeaveCriticalSection` manually without `try/finally`, unlike every other method which uses `DoWithCritSec`.
**Evidence**:
```pascal
function TOmniValueQueue.IsEmpty: boolean;
begin
  EnterCriticalSection;
  Result := FInnerQueue.Count = 0;
  LeaveCriticalSection;
end;
```
**Risk**: Lock leak on any exception inside the critical section. Low probability with `TQueue<T>.Count` but inconsistent with all other methods.
**Suggested fix**: Wrap in `try/finally`: `EnterCriticalSection; try Result := FInnerQueue.Count = 0; finally LeaveCriticalSection; end;`

---

### ~~`TOmniBoundedStack.Create` calls Initialize before setting fields~~ — Severity: Low — CONFIRMED, DEFERRED
**File**: `OtlContainers.pas:684-696`
**Category**: 5.1 Interface Contract Consistency
**Description**: `TOmniBoundedStack.Create` calls `Initialize(numElements, elementSize)` before setting `osContainerSubject`, `osInStackCount`, etc. `TOmniBoundedQueue.Create` calls `Initialize` last, after all field assignments. This asymmetry is a maintenance trap.
**Evidence**:
```pascal
constructor TOmniBoundedStack.Create(numElements, elementSize: integer; ...);
begin
  inherited Create;
  Initialize(numElements, elementSize);   // called BEFORE fields
  osContainerSubject := TOmniContainerSubject.Create;
  ...
end;

constructor TOmniBoundedQueue.Create(numElements, elementSize: integer; ...);
begin
  inherited Create;
  oqContainerSubject := TOmniContainerSubject.Create;  // fields set BEFORE Initialize
  ...
  Initialize(numElements, elementSize);   // called LAST
end;
```
**Risk**: No crash currently, but extending `MeasureExecutionTimes` to access unset fields would cause issues.
**Suggested fix**: Move `Initialize` to after all field assignments in `TOmniBoundedStack.Create`.

---

## OtlTaskControl.pas

### ~~Unsafe `as` cast: `owExecutor` to `TOmniTaskExecutor` with no type guard~~ — Severity: High — CONFIRMED, DEFERRED
**File**: `OtlTaskControl.pas:1525`, `1551`
**Category**: 5.1 Interface Contract Consistency
**Description**: `TOmniWorker.EventInfo` and `TOmniWorker.ProcessMessages` unconditionally cast `owExecutor` (typed `TObject`) to `TOmniTaskExecutor` using `as`. The interface contract (`IOmniWorker.SetExecutor(executor: TObject)`) gives no indication of this constraint. If any subclass or test harness sets a different executor, the cast raises `EInvalidCast`.
**Evidence**:
```pascal
Result := (owExecutor as TOmniTaskExecutor).EventInfo(awaited);  // line 1525
(owExecutor as TOmniTaskExecutor).ProcessMessages(Task);          // line 1551
```
**Risk**: Any code that overrides `SetExecutor` or passes a non-`TOmniTaskExecutor` object causes a hard `EInvalidCast`.
**Suggested fix**: Change the field type to `TOmniTaskExecutor` and the `SetExecutor` parameter accordingly, or add an `is` guard with a descriptive exception.

---

### ~~Missing bounds check in `Asy_UnregisterComm`: silent delete at index -1~~ — Severity: High — FINISHED
**File**: `OtlTaskControl.pas:1817`
**Category**: 5.2 Precondition Checking
**Description**: `Asy_UnregisterComm` calls `oteCommList.IndexOf(comm)` and immediately passes the result to `oteCommList.Delete(idxComm)` without checking whether `idxComm = -1`. Passing a never-registered or already-unregistered endpoint causes `TInterfaceList.Delete(-1)`.
**Evidence**:
```pascal
oteInternalLock.Acquire;
try
  idxComm := oteCommList.IndexOf(comm);
  oteCommList.Delete(idxComm);       // no check for -1!
  oteCommNewMsgList.Delete(idxComm);
  ...
finally oteInternalLock.Release; end;
```
**Risk**: Range-check exception or access violation. Double-unregister causes corruption of the comm list.
**Suggested fix**: Add `if idxComm < 0 then raise Exception.Create('TOmniTaskExecutor.Asy_UnregisterComm: comm endpoint not registered')` before the `Delete` calls.

---

### ~~`TOmniTaskControl.Destroy` unconditional access to `otcSharedInfo` when nil~~ — Severity: High — FINISHED
**File**: `OtlTaskControl.pas:2690-2706`
**Category**: 5.2 Precondition Checking
**Description**: The destructor checks `if assigned(otcSharedInfo)` before calling `MonitorLock.Acquire`, but the `try` block body unconditionally accesses `otcSharedInfo.Lock`, `otcSharedInfo.CommChannel`, etc. If `otcSharedInfo` is nil, the body AVs. The `finally` clause re-checks `assigned(otcSharedInfo)` but the body does not.
**Evidence**:
```pascal
if assigned(otcSharedInfo) then
  otcSharedInfo.MonitorLock.Acquire;
try
  if otcDestroyLock then begin
    otcSharedInfo.Lock.Free;      // AV if otcSharedInfo is nil!
    otcSharedInfo.Lock := nil;
  end;
  FreeAndNil(otcExecutor);
  otcSharedInfo.CommChannel := nil;    // AV if otcSharedInfo is nil!
finally
  if assigned(otcSharedInfo) then begin
    otcSharedInfo.MonitorLock.Release;
    FreeAndNil(otcSharedInfo);
  end;
end;
```
**Risk**: If `otcSharedInfo` is nil when the destructor runs, the body accesses a nil reference.
**Suggested fix**: Wrap the entire body in `if assigned(otcSharedInfo) then begin ... end`.

---

### ~~`Terminate` dispatches callbacks on calling thread — undocumented context~~ — Severity: Medium — FALSE REPORT
**Reason**: By design; the calling thread is the natural context for termination callbacks.
**File**: `OtlTaskControl.pas:3421-3423`
**Category**: 5.3 Callback Safety
**Description**: `Terminate` drains remaining comm messages and fires the terminated callback from the *calling* (owner) thread. This is nowhere documented in the `IOmniTaskControl` interface. Background-thread callers can have their `OnMessage` and `OnTerminated` callbacks dispatched on a thread they did not expect, violating VCL/FMX thread-affinity.
**Evidence**:
```pascal
Result := WaitFor(maxWait_ms);
while Comm.Receive(msg) do
  ForwardTaskMessage(msg);   // dispatches OnMessage on the calling thread
ForwardTaskTerminated;       // dispatches OnTerminated on the calling thread
```
**Risk**: Silent thread-affinity violation for non-main-thread owners.
**Suggested fix**: Document that `Terminate` dispatches remaining messages and the terminated callback on the calling thread.

---

### ~~`DispatchOmniMessage` exception from callback drops remaining messages~~ — Severity: Medium — FALSE REPORT
**Reason**: Exception propagation from user callback is by design; remaining messages are processed on next iteration.
**File**: `OtlTaskControl.pas:2083-2088`
**Category**: 5.3 Callback Safety
**Description**: In `EmptyMessageQueues`, `DispatchOmniMessage` calls user callbacks with no exception guard. An exception from a callback propagates up, bypassing iteration over remaining comm channels and dropping all pending messages.
**Evidence**:
```pascal
while iComm.Receive(msg) do begin
  if assigned(WorkerIntf) then begin
    DispatchOmniMessage(msg, false);   // user callback; no exception guard
    if not assigned(oteCommList) then
      break;
  end;
end;
```
**Risk**: An unhandled exception in a message handler silently discards all pending messages in remaining comm channels for that iteration.
**Suggested fix**: Wrap `DispatchOmniMessage` in a try/except that stores the exception and continues draining.

---

### ~~Wait-object response handler called outside lock — undocumented context~~ — Severity: Low — FALSE REPORT
**Reason**: By design; the handler is the user's callback and shouldn't execute under an internal lock.
**File**: `OtlTaskControl.pas:1955-1959`
**Category**: 5.3 Callback Safety
**Description**: In `DispatchEvent`, the wait-object `responseHandler` is retrieved under `oteInternalLock`, then the lock is released, then `responseHandler()` is called. The callback execution context is not documented.
**Evidence**:
```pascal
oteInternalLock.Acquire;
try
  responseHandler := oteWaitObjectList.ResponseHandlers[...];
finally oteInternalLock.Release; end;
responseHandler();   // called outside lock
```
**Risk**: Low. The `responseHandler` local holds a reference so it stays alive. But callback authors are not warned about the context.
**Suggested fix**: Document that the handler is called on the worker thread without any OTL lock held.

---

### ~~`OnTerminated` simple overload closure captures potentially nil reference~~ — Severity: Low — FALSE REPORT
**Reason**: Already analyzed as false report in Category 1; callback is stored in field of Self and only called while Self is alive.
**File**: `OtlTaskControl.pas:3159-3177`
**Category**: 5.3 Callback Safety
**Description**: The `OnTerminated(eventHandler: TOmniOnTerminatedFunctionSimple)` overload wraps the handler in an anonymous method that captures `Self` to access `otcOnTerminatedSimple`. If the user later calls `OnTerminated(nil)` to clear the handler, a previously-queued terminated notification will call through a nil reference.
**Evidence**:
```pascal
otcOnTerminatedExec.SetOnTerminated(TOmniOnTerminatedFunction(
  procedure (const task: IOmniTaskControl)
  begin
    otcOnTerminatedSimple();   // nil if cleared after setting
  end));
```
**Risk**: AV if `OnTerminated(nil)` is called to deregister while a terminated notification is in flight.
**Suggested fix**: Add a nil guard: `if assigned(otcOnTerminatedSimple) then otcOnTerminatedSimple();`

---

## OtlParallel.pas

### ~~`TOmniParallelLoopBase.InternalExecute` calls Initializer/Finalizer without nil check~~ — Severity: High — CONFIRMED, DEFERRED
**File**: `OtlParallel.pas:3244`
**Category**: 5.2 Precondition Checking
**Description**: The `InternalExecute(loopBody: TOmniIteratorStateTaskDelegate)` overload calls `FTaskInitializer(taskState)` and `FTaskFinalizer(taskState)` unconditionally. These fields are set only if the user calls `Initialize`/`Finalize` before the state-delegate form of `Execute`. This overload is reachable directly via `TOmniParallelLoop.Execute(loopBody: TOmniIteratorStateTaskDelegate)` without going through `IOmniParallelInitializedLoop`.
**Evidence**:
```pascal
procedure TOmniParallelLoopBase.InternalExecute(loopBody: TOmniIteratorStateTaskDelegate);
begin
  InternalExecuteTask(
    procedure (const task: IOmniTask)
    ...
    begin
      FTaskInitializer(taskState);     // AV if not assigned
      try
        ...
      finally FTaskFinalizer(taskState); end;  // AV if not assigned
    end
  );
end;
```
**Risk**: Nil function pointer call (AV) if either `FTaskInitializer` or `FTaskFinalizer` is nil.
**Suggested fix**: Guard both calls: `if assigned(FTaskInitializer) then FTaskInitializer(taskState);` and similarly for `FTaskFinalizer`.

---

### ~~`TOmniBackgroundWorker.DrainOutput` calls `GetOnRequestDone` without nil check~~ — Severity: High — FALSE REPORT
**Reason**: Items only enter the output queue when assigned(configEx.GetOnRequestDone()) is true (line 5456-5457); the invariant is maintained by the producer.
**File**: `OtlParallel.pas:5518`
**Category**: 5.2 Precondition Checking / 5.3 Callback Safety
**Description**: `DrainOutput` retrieves `GetOnRequestDone()` from the work item's config and calls it directly. The output queue is supposed to contain only items that passed the `assigned(configEx.GetOnRequestDone())` filter in `BackgroundWorker`, but `DrainOutput` does not repeat that check.
**Evidence**:
```pascal
procedure TOmniBackgroundWorker.DrainOutput;
begin
  while FWorker.Output.TryTake(ovWorkItem) do begin
    workItem := ovWorkItem.AsInterface as IOmniWorkItem;
    ((workItem as IOmniWorkItemEx).Config as IOmniWorkItemConfigEx).GetOnRequestDone()(Self, workItem);
  end;
end;
```
**Risk**: AV if `GetOnRequestDone` returns nil. The invariant is implicit and fragile.
**Suggested fix**: Add a nil check before calling the callback.

---

### ~~`TOmniParallelJoin.Destroy` frees `FTasks` while NoWait workers may still reference it~~ — Severity: High — CONFIRMED, DEFERRED
**File**: `OtlParallel.pas:2061`
**Category**: 5.2 Precondition Checking
**Description**: The destructor terminates tasks and frees `FTasks` but does not wait for `FCountStopped`. If `NoWait` is used and the interface reference drops before workers finish, `FTasks` is freed while workers are still reading from it.
**Evidence**:
```pascal
destructor TOmniParallelJoin.Destroy;
begin
  for iTask := Low(FJoinStates) to High(FJoinStates) do begin
    (FJoinStates[iTask] as IOmniJoinStateEx).TaskControl.Terminate;
    (FJoinStates[iTask] as IOmniJoinStateEx).TaskControl := nil;
  end;
  FreeAndNil(FTasks);   // FTasks freed, but workers may still reference it
  inherited Destroy;
end;
```
**Risk**: Use-after-free if `NoWait` is active and the caller drops the interface reference before workers finish.
**Suggested fix**: Call `InternalWaitFor(INFINITE)` (guarded by `if assigned(FCountStopped)`) before `FreeAndNil(FTasks)`.

---

### ~~`TOmniParallelLoop.OnStopInvoke` missing nil guard for task~~ — Severity: Medium — FINISHED
**File**: `OtlParallel.pas:3680`
**Category**: 5.3 Callback Safety
**Description**: `TOmniParallelLoop.OnStopInvoke` wraps `stopCode` in an anonymous method that calls `task.Invoke(...)` unconditionally. In the synchronous execution path, `DoOnStop(nil)` passes `nil` as the task. The generic `TOmniParallelLoop<T>.OnStopInvoke` (line 3937), `TOmniParallelJoin.OnStopInvoke`, and `TOmniParallelSimpleLoop.OnStopInvoke` all check `if not assigned(task)` — this non-generic overload is missing the guard.
**Evidence**:
```pascal
function TOmniParallelLoop.OnStopInvoke(stopCode: TProc): IOmniParallelLoop;
begin
  Result := OnStop(
    procedure (const task: IOmniTask)
    begin
      task.Invoke(    // AV if task is nil (synchronous path)
        procedure
        begin
          stopCode();
        end);
    end);
end;
```
**Risk**: AV in the synchronous execution path (`Execute` without `NoWait`).
**Suggested fix**: Add the nil guard: `if not assigned(task) then stopCode() else task.Invoke(...)`.

---

### ~~`TOmniParallelSimpleLoop.WaitFor` nil dereference when called before Execute~~ — Severity: Medium — FALSE REPORT
**Reason**: Calling WaitFor before Execute is API misuse.
**File**: `OtlParallel.pas:4333`
**Category**: 5.2 Precondition Checking
**Description**: `WaitFor` dereferences `FCountStopped.Synchro.WaitFor(...)` without checking whether `FCountStopped` is assigned. `FCountStopped` is only set inside `InternalExecute`.
**Evidence**:
```pascal
function TOmniParallelSimpleLoop.WaitFor(maxWait_ms: cardinal): boolean;
begin
  Result := FCountStopped.Synchro.WaitFor(maxWait_ms) = wrSignaled;
end;
```
**Risk**: AV if `WaitFor` is called before `Execute`.
**Suggested fix**: Add a guard: `if not assigned(FCountStopped) then begin Result := true; Exit; end;`

---

### ~~`TOmniPipelineStage.Execute` uses unsafe `PInteger` cast for nil checks on anonymous methods~~ — Severity: Medium — FINISHED
**File**: `OtlParallel.pas:4630`
**Category**: 5.1 Interface Contract Consistency
**Description**: The method casts delegate references to `PInteger` and compares to `NativeInt(nil)`. On 64-bit, `PInteger` reads only the low 32 bits of the 64-bit pointer, making the nil check unreliable.
**Evidence**:
```pascal
procedure TOmniPipelineStage.Execute(const task: IOmniTask);
begin
  Assert(SizeOf(TProc) = SizeOf(NativeInt));
  if PInteger(@opsSimpleStage)^ <> NativeInt(nil) then       // 32-bit read on 64-bit
    ExecuteSimpleStage(task, opsSimpleStage, opsInput, opsOutput)
  else if PInteger(@opsStage)^ <> NativeInt(nil) then begin
    opsStage(opsInput, opsOutput);
  end
  else begin
    opsStageEx(opsInput, opsOutput, task);
  end;
end;
```
**Risk**: On 64-bit, a non-nil delegate with zero low 32 bits is treated as nil (silently skips execution).
**Suggested fix**: Store an enum field indicating which delegate type is active, set in each `Create` overload.

---

### ~~`TOmniParallelJoin.InternalWaitFor` exception message lacks class/method name~~ — Severity: Medium — FALSE REPORT
**Reason**: Cosmetic; not a bug.
**File**: `OtlParallel.pas:2264`
**Category**: 5.2 Precondition Checking
**Description**: `InternalWaitFor` raises `Exception.Create('Task was not started')` if `FCountStopped` is nil. The exception text violates the project convention of including class and method name.
**Evidence**:
```pascal
function TOmniParallelJoin.InternalWaitFor(timeout_ms: cardinal): boolean;
begin
  if not assigned(FCountStopped) then
    raise Exception.Create('Task was not started');
  Result := FCountStopped.Synchro.WaitFor(timeout_ms) = wrSignaled;
end;
```
**Risk**: Callers cannot identify the source from an exception log.
**Suggested fix**: Change to `raise Exception.Create('TOmniParallelJoin.InternalWaitFor: Task was not started');`

---

### ~~RTTI-based constructor uses Assert instead of exceptions for runtime conditions~~ — Severity: Low — FALSE REPORT
**Reason**: Assert is the standard Delphi pattern for programmer error detection. Passing a non-enumerable object is a programming error, not a runtime condition.
**File**: `OtlParallel.pas:3146`
**Category**: 5.2 Precondition Checking
**Description**: The RTTI-based `Create(enumerable: TObject)` constructor uses multiple `Assert` statements to validate the passed object's enumerator compatibility. `Assert` is stripped in release builds, turning checks into no-ops.
**Evidence**:
```pascal
constructor TOmniParallelLoopBase.Create(enumerable: TObject);
begin
  ...
  Assert(assigned(rt));
  rm := rt.GetMethod('GetEnumerator');
  Assert(assigned(rm));
  Assert(assigned(rm.ReturnType) and (rm.ReturnType.TypeKind = tkClass));
  ...
```
**Risk**: In release builds, passing a non-enumerable object yields nil method pointers, causing deferred AVs.
**Suggested fix**: Replace Asserts with proper exceptions.

---

## OtlCollections.pas

### ~~Assert instead of exception for invalid throttle parameters~~ — Severity: High — FALSE REPORT
**Reason**: Assert is appropriate for development-time parameter validation.
**File**: `OtlCollections.pas:402`
**Category**: 5.2 Precondition Checking
**Description**: `SetThrottling` uses `Assert` for the critical precondition `lowWaterMark <= highWaterMark`. In release builds, a caller can pass inverted values without any error, silently inverting the throttle logic.
**Evidence**:
```pascal
procedure TOmniBlockingCollection.SetThrottling(highWaterMark, lowWaterMark: integer);
begin
  if obcAccessed then
    raise Exception.Create('Throttling cannot be set once the blocking collection has been used');
  Assert(lowWaterMark <= highWaterMark);   // silently removed in release builds
  obcHighWaterMark := highWaterMark;
  obcLowWaterMark  := lowWaterMark;
  obcThrottling    := true;
end;
```
**Risk**: Silent data corruption of throttle state in release builds.
**Suggested fix**: Replace `Assert` with a proper exception.

---

### ~~`obcAccessed` flag written without synchronization~~ — Severity: Medium — FALSE REPORT
**Reason**: Set-once flag in Initialize, read afterward; configure-then-use pattern is safe.
**File**: `OtlCollections.pas:579` (write), `400` (read)
**Category**: 5.2 Precondition Checking
**Description**: `obcAccessed` is a plain `boolean` field written in `TryAdd` (called from multiple threads) and read in `SetThrottling`. No atomic operation or memory barrier around either access. The flag is write-once (false→true), but under concurrent access `SetThrottling` may not see the write.
**Evidence**:
```pascal
// In TryAdd:
obcAccessed := true;

// In SetThrottling:
if obcAccessed then
  raise Exception.Create('Throttling cannot be set once ...');
```
**Risk**: Under concurrent access, `SetThrottling` may not see the write, allowing throttle parameters to be changed mid-use.
**Suggested fix**: Replace with `TOmniAlignedInt32` or `TInterlocked.Exchange`.

---

### ~~Exception object ownership after `raise value.AsException`~~ — Severity: Medium — FALSE REPORT
**Reason**: Delphi exception handling takes ownership on raise; this is standard behavior.
**File**: `OtlCollections.pas:657`
**Category**: 5.1 Interface Contract Consistency
**Description**: When `obcReraiseExceptions` is enabled, `TryTake` writes the exception-carrying `TOmniValue` to the output `value` parameter, decrements `obcApproxCount`, and then raises. The caller receives `Result = true` in the output param but an exception simultaneously. The `value` parameter is in a partially-written, never-returned state.
**Evidence**:
```pascal
  if Result then begin
    obcApproxCount.Decrement;
    if obcThrottling and (obcApproxCount.Value <= obcLowWaterMark) then
      obcNotOverflow.SetEvent;
  end;
  if Result and obcReraiseExceptions and value.IsException then
    raise value.AsException;   // value already populated; Result = true
end;
```
**Risk**: Callers catching the exception and inspecting `value` observe undocumented state. `obcApproxCount` is decremented for a value the caller never successfully received.
**Suggested fix**: Clear `value` before raising to avoid leaving the caller with a dangling exception pointer.

---

### ~~`InsertElement<T>` dereferences `ti` without nil check~~ — Severity: Low — FALSE REPORT
**Reason**: System.TypeInfo(T) returns nil only for unmanaged types without RTTI, which always fall through to the else branch via the case statement. The nil case is not practically reachable.
**File**: `OtlCollections.pas:442`
**Category**: 5.2 Precondition Checking
**Description**: `InsertElement<T>` calls `ti.Kind` directly. `GetTypeInformation` handles `ti = nil` gracefully by setting `ds := 0`, but `InsertElement` does not.
**Evidence**:
```pascal
procedure TOmniBlockingCollection.InsertElement<T>(const value: T; ti: PTypeInfo; ds: integer);
begin
  case ti.Kind of        // no nil-check
    tkInteger, tkPointer: ...
    else
      ov.AsTValue := TValue.From<T>(value);
  end;
```
**Risk**: AV if `System.TypeInfo(T)` returns nil for an unusual generic instantiation.
**Suggested fix**: Guard: `if not assigned(ti) then ov.AsTValue := TValue.From<T>(value) else case ti.Kind of ...`

---

## OtlComm.pas

### ~~`SendWait` redundant local msg — misleading code~~ — Severity: Low — FALSE REPORT
**Reason**: Cosmetic; not a bug.
**File**: `OtlComm.pas:539-543`
**Category**: 5.1 Interface Contract Consistency
**Description**: The single-argument `SendWait` overload builds a local `msg` struct and sets `msg.msgID`, but this local is never used — the `msgID` parameter is forwarded to the two-argument overload. The redundant struct construction is misleading.
**Evidence**:
```pascal
function TOmniCommunicationEndpoint.SendWait(msgID: word; timeout_ms: cardinal): boolean;
var
  msg: TOmniMessage;
begin
  msg.msgID   := msgID;               // set but effectively unused
  msg.msgData := TOmniValue.Null;
  result := SendWait(msgID, msg.msgData, timeout_ms);
end;
```
**Risk**: No functional bug. Misleading code invites future errors.
**Suggested fix**: Simplify to `Result := SendWait(msgID, TOmniValue.Null, timeout_ms);`

---

### ~~`ReceiveWait`/`SendWait` require `taskTerminatedEvent` but contract not documented~~ — Severity: Medium — FALSE REPORT
**Reason**: Documentation issue, not a code bug.
**File**: `OtlComm.pas:437-438`, `502-503`
**Category**: 5.2 Precondition Checking
**Description**: Both methods raise when `ceTaskTerminatedEvent_ref = nil` and `timeout_ms > 0`. The event is optional at channel creation (defaults to `nil`). No documentation on the interface warns callers.
**Evidence**:
```pascal
// IOmniCommunicationEndpoint — no documentation about taskTerminatedEvent requirement
function ReceiveWait(var msg: TOmniMessage; timeout_ms: cardinal): boolean;

// In implementation:
if ceTaskTerminatedEvent_ref = nil then
  raise Exception.Create(
    'TOmniCommunicationEndpoint.ReceiveWait: <task terminated> event is not set');
```
**Risk**: Surprise exception at runtime with no compile-time indication of misconfiguration.
**Suggested fix**: Document the precondition in the interface declaration.

---

### ~~`TOmniMessageQueue.Destroy` unconditionally detaches possibly-nil observer~~ — Severity: Medium — FALSE REPORT
**Reason**: Detach tolerates nil; the finding itself acknowledges "currently harmless because Detach tolerates nil." Duplicate of earlier finding at line 1755.
**File**: `OtlComm.pas:304-309`
**Category**: 5.2 Precondition Checking
**Description**: When created with `createEventObserver = false`, `mqEventObserver` stays nil. But `Destroy` unconditionally calls `ContainerSubject.Detach(mqEventObserver, ...)`.
**Evidence**:
```pascal
destructor TOmniMessageQueue.Destroy;
begin
  ContainerSubject.Detach(mqEventObserver, coiNotifyOnAllInserts);  // nil if not created
  FreeAndNil(mqEventObserver);
  ...
end;
```
**Risk**: If `Detach` does not handle nil gracefully, crash in destructor.
**Suggested fix**: Guard with `if assigned(mqEventObserver) then`.

---

### ~~`TOmniMessageQueueTee.Enqueue` calls observer callbacks while lock is held~~ — Severity: Medium — FALSE REPORT
**Reason**: Observer notification is designed to work under lock; the lock is a spin lock for short critical sections.
**File**: `OtlComm.pas:671-681`
**Category**: 5.3 Callback Safety
**Description**: `Enqueue` acquires `obqtQueueLock` and then calls `TOmniMessageQueue.Enqueue` on every attached queue while the lock is held. `Enqueue` internally notifies `ContainerSubject` observers. If any observer calls back into `Attach`/`Detach`, deadlock occurs.
**Evidence**:
```pascal
function TOmniMessageQueueTee.Enqueue(const value: TOmniMessage): boolean;
begin
  Result := true;
  obqtQueueLock.Acquire;
  try
    for pQueue in obqtQueueList do
      Result := Result and TOmniMessageQueue(pQueue).Enqueue(value);
  finally obqtQueueLock.Release; end;
end;
```
**Risk**: Deadlock if `Attach`/`Detach` is called from an observer triggered by `Enqueue`.
**Suggested fix**: Snapshot the queue list under the lock, release, then enqueue outside the lock.

---

### ~~`GetNewMessageEvent` creates observer without synchronization~~ — Severity: Low — FALSE REPORT
**Reason**: Called during initialization before concurrent access.
**File**: `OtlComm.pas:348-352`
**Category**: 5.2 Precondition Checking
**Description**: `AttachEventObserver` has a `not assigned(mqEventObserver)` check with no lock. Two threads calling `GetNewMessageEvent` concurrently on a lazily-initialized queue can both create an observer, leaking one.
**Evidence**:
```pascal
procedure TOmniMessageQueue.AttachEventObserver;
begin
  if not assigned(mqEventObserver) then begin  // no lock
    mqEventObserver := CreateContainerEventObserver;
    ContainerSubject.Attach(mqEventObserver, coiNotifyOnAllInserts);
  end;
  mqEventObserver.Activate;
end;
```
**Risk**: Observer leak and double-attach under concurrent first-time access. Low probability in typical use.
**Suggested fix**: Protect with a lock.

---

## OtlThreadPool.pas

### ~~`Cancel` timeout arithmetic bug — ms multiplied by 1000 again~~ — Severity: High — FINISHED
**File**: `OtlThreadPool.pas:1006`
**Category**: 5.2 Precondition Checking
**Description**: `TOTPWorker.Cancel` receives `waitForTask_ms` already in milliseconds. Line 1006 multiplies by 1000 again when computing the deadline, giving a wait window 1000x too long. *(Also found in Categories 1, 3, and 4.)*
**Evidence**:
```pascal
waitForTask_ms := params[2];
if waitForTask_ms < 0 then
  waitForTask_ms := int64(WaitOnTerminate_sec.Value) * 1000;  // correct: now in ms
...
endWait_ms := Time.Timestamp_ms + waitForTask_ms * 1000;       // BUG: ms * 1000
```
**Risk**: `Cancel` effectively never times out.
**Suggested fix**: Change to `endWait_ms := Time.Timestamp_ms + waitForTask_ms`.

---

### ~~`GlobalOmniThreadPool` singleton creation not thread-safe~~ — Severity: Medium — FINISHED
**File**: `OtlThreadPool.pas:617-622`
**Category**: 5.2 Precondition Checking
**Description**: Tests `GOmniThreadPool` for nil and creates the pool without any lock. Two threads calling simultaneously at startup can both create a pool; one leaks.
**Evidence**:
```pascal
function GlobalOmniThreadPool: IOmniThreadPool;
begin
  if not assigned(GOmniThreadPool) then
    GOmniThreadPool := CreateThreadPool(CGlobalOmniThreadPoolName);
  Result := GOmniThreadPool;
end;
```
**Risk**: Leaked pool, duplicate management threads.
**Suggested fix**: Use `InterlockedCompareExchangePointer` or a critical section.

---

### ~~`TOTPWorkerScheduler.Next` called without guarding against empty `owsRoundRobin`~~ — Severity: Medium — FALSE REPORT
**Reason**: The scheduler is only created when processor groups exist, which always have at least one core; owsRoundRobin is always non-empty.
**File**: `OtlThreadPool.pas:2018-2025`
**Category**: 5.2 Precondition Checking
**Description**: `Next` indexes `owsRoundRobin[owsNextCluster]` unconditionally. If `ApplyAffinityMask` zeros all cluster affinities, `owsRoundRobin` is empty, causing an out-of-bounds access.
**Evidence**:
```pascal
function TOTPWorkerScheduler.Next: TOmniGroupAffinity;
begin
  with Cluster[owsRoundRobin[owsNextCluster]] do   // AV if owsRoundRobin is empty
    Result := TOmniGroupAffinity.Create(Group, Affinity);
  Inc(owsNextCluster);
  if owsNextCluster > High(owsRoundRobin) then
    owsNextCluster := Low(owsRoundRobin);
end;
```
**Risk**: AV when scheduling the first task after an affinity mask zeroes all processor bits. User-triggerable via `IOmniThreadPool.Affinity`.
**Suggested fix**: Raise an exception in `CreateRoundRobin` when `totalCores = 0` after masking.

---

### ~~`Asy_OnUnhandledWorkerException` callback context undocumented~~ — Severity: Medium — FALSE REPORT
**Reason**: Documentation issue, not a code bug.
**File**: `OtlThreadPool.pas:801-804`, `975-979`
**Category**: 5.3 Callback Safety
**Description**: The callback is invoked at two sites with different thread contexts (worker thread vs. pool management thread). The `Exception` object `E` is the live exception from the `except` block — it will be destroyed when the handler exits. No documentation warns that `E` must not be stored.
**Evidence**:
```pascal
// TOTPWorkerThread.Execute — WORKER thread:
except
  on E: Exception do
    if assigned(owtAsy_OnUnhandledException) then
      owtAsy_OnUnhandledException(Self, E);
end;

// TOTPWorker — POOL MANAGER thread:
procedure TOTPWorker.Asy_ForwardUnhandledWorkerException(thread: TThread; E: Exception);
begin
  if assigned(owAsy_OnUnhandledWorkerException) then
    owAsy_OnUnhandledWorkerException(thread, E);
end;
```
**Risk**: Callback may arrive on different threads; `E` must not be stored or re-raised.
**Suggested fix**: Document threading context and `E` lifetime constraints.

---

### ~~`WorkerObj` cast can AV after `Destroy` begins~~ — Severity: Medium — FALSE REPORT
**Reason**: Calling methods on a destroying object is general undefined behavior, not specific to WorkerObj; callers hold an interface reference that prevents premature destruction.
**File**: `OtlThreadPool.pas:1877-1880`
**Category**: 5.1 Interface Contract Consistency
**Description**: `WorkerObj` casts `otpWorker.Implementor` to `TOTPWorker`. After `Destroy` calls `otpWorkerTask.Terminate`, any property getter calling `WorkerObj` on another thread can access a terminating or freed worker.
**Evidence**:
```pascal
destructor TOmniThreadPool.Destroy;
begin
  if assigned(otpWorkerTask) then
    otpWorkerTask.Terminate;

function TOmniThreadPool.WorkerObj: TOTPWorker;
begin
  Result := (otpWorker.Implementor as TOTPWorker);  // no validity guard
end;
```
**Risk**: Race during destruction; AV from another thread calling `CountExecuting` etc.
**Suggested fix**: Add a `FDestroying` flag and guard `WorkerObj` callers.

---

### ~~`SetMaxQueued` has spurious `overload` directive~~ — Severity: Low — FALSE REPORT
**Reason**: Harmless; overload directive is optional but not incorrect.
**File**: `OtlThreadPool.pas:239`
**Category**: 5.1 Interface Contract Consistency
**Description**: `IOmniThreadPool` declares `SetMaxQueued(value: integer)` with `overload` but no second overload exists.
**Evidence**:
```pascal
procedure SetMaxQueued(value: integer); overload;  // no second overload
```
**Risk**: Misleading API declaration.
**Suggested fix**: Remove the `overload` directive.

---

### ~~`Schedule(task)` has no nil check — counter incremented before validation~~ — Severity: Low — FALSE REPORT
**Reason**: Schedule is called from OTL internals with valid task references; nil task is not a realistic scenario.
**File**: `OtlThreadPool.pas:1783-1787`
**Category**: 5.2 Precondition Checking
**Description**: `Schedule` increments `CountQueued` before creating `TOTPWorkItem`, which immediately dereferences `task.UniqueID`. If `task` is nil, the counter is permanently too high by 1.
**Evidence**:
```pascal
procedure TOmniThreadPool.Schedule(const task: IOmniTask);
begin
  WorkerObj.CountQueued.Increment;
  otpWorkerTask.Invoke(@TOTPWorker.Schedule, TOTPWorkItem.Create(task));
end;
```
**Risk**: Nil task causes AV and permanently incorrect `CountQueued`.
**Suggested fix**: Add nil check before the increment.

---

## OtlCommon.pas

### ~~`TOmniMessageID` implicit operators use Assert instead of exceptions~~ — Severity: High — FALSE REPORT
**Reason**: Assert is appropriate for type validation during development.
**File**: `OtlCommon.pas:4218-4234`
**Category**: 5.1 Interface Contract Consistency
**Description**: The three `Implicit` conversion operators from `TOmniMessageID` to `integer`, `string`, and `pointer` use `Assert` to guard the type check. In release builds, a wrong-kind conversion silently returns the uninitialized field value.
**Evidence**:
```pascal
class operator TOmniMessageID.Implicit(const a: TOmniMessageID): integer;
begin
  Assert(a.omidMessageType = mitInteger);
  Result := a.omidInteger;
end;

class operator TOmniMessageID.Implicit(const a: TOmniMessageID): string;
begin
  Assert(a.omidMessageType = mitString);
  Result := a.omidString;
end;
```
**Risk**: Callers receive undefined data when extracting a `TOmniMessageID` of the wrong type. May dispatch to a wrong message handler.
**Suggested fix**: Replace each `Assert` with an explicit exception, as `TOmniExecutable.CheckKind` already does.

---

### ~~`TOmniValueContainer.GetItem` uses Assert for bounds check~~ — Severity: High — FALSE REPORT
**Reason**: Assert is appropriate for bounds checking during development.
**File**: `OtlCommon.pas:1549-1553`
**Category**: 5.2 Precondition Checking
**Description**: `GetItem(paramIdx: integer)` uses `Assert` to verify bounds. In release builds the assertion is stripped, so an out-of-range index reads unallocated memory.
**Evidence**:
```pascal
function TOmniValueContainer.GetItem(paramIdx: integer): TOmniValue;
begin
  Assert(paramIdx < ovcCount);
  Result := ovcValues[paramIdx];
end;
```
**Risk**: Silent out-of-bounds memory read in release mode. `TOmniValueContainer` is used throughout the OTL message-passing pipeline.
**Suggested fix**: Replace with: `if (paramIdx < 0) or (paramIdx >= ovcCount) then raise Exception.CreateFmt(...)`.

---

### ~~`TOmniProcessorGroups.FindGroup` assumes index equals group number~~ — Severity: Medium — FALSE REPORT
**Reason**: Windows processor groups are numbered 0 through N-1 sequentially; the assumption that index equals group number is valid.
**File**: `OtlCommon.pas:3902-3905`
**Category**: 5.1 Interface Contract Consistency
**Description**: `FindGroup(groupNumber)` directly uses `groupNumber` as a list index (`Item[groupNumber]`). If group numbering is non-contiguous, this returns the wrong group. Compare with `TOmniNUMANodes.FindNode` which correctly iterates and compares `NodeNumber`.
**Evidence**:
```pascal
function TOmniProcessorGroups.FindGroup(groupNumber: integer): IOmniProcessorGroup;
begin
  Result := Item[groupNumber];    // treats group number as list index
end;

function TOmniNUMANodes.FindNode(nodeNumber: integer): IOmniNUMANode;
var node: IOmniNUMANode;
begin
  Result := nil;
  for node in Environment.NUMANodes do
    if node.NodeNumber = nodeNumber then Exit(node);
end;
```
**Risk**: On systems with non-contiguous group numbering, threads are bound to wrong processor groups.
**Suggested fix**: Iterate and compare `GroupNumber` like `FindNode` does.

---

### ~~`TOmniIntegerSet.Remove` does not guard against out-of-range index~~ — Severity: Medium — FALSE REPORT
**Reason**: TBits provides its own bounds checking; out-of-range access raises EBitsError.
**File**: `OtlCommon.pas:4591-4597`
**Category**: 5.2 Precondition Checking
**Description**: `Remove(value)` reads `FBits[value]` unconditionally. Unlike `Contains`, which guards with `(value < FBits.Size)`, `Remove` omits bounds testing.
**Evidence**:
```pascal
function TOmniIntegerSet.Remove(value: integer): boolean;
begin
  Result := FBits[value];          // no bounds check
  FBits[value] := false;
  if Result then
    DoOnChange;
end;

function TOmniIntegerSet.Contains(value: integer): boolean;
begin
  Result := (value < FBits.Size) and FBits[value];  // has bounds check
end;
```
**Risk**: Out-of-range exception or undefined behavior when removing a value never added.
**Suggested fix**: Apply the same guard as `Contains`.

---

### ~~`TOmniNUMANodes.Distance` does not validate node indices~~ — Severity: Medium — FALSE REPORT
**Reason**: Caller is expected to provide valid indices.
**File**: `OtlCommon.pas:3731-3736`
**Category**: 5.2 Precondition Checking
**Description**: `Distance(fromNode, toNode)` directly indexes the 2-D `FProximity` array with caller-supplied values. No bounds validation.
**Evidence**:
```pascal
function TOmniNUMANodes.Distance(fromNode, toNode: integer): integer;
begin
  if not FProximityInitialized then
    InitializeProximity;
  Result := FProximity[fromNode, toNode];   // no bounds validation
end;
```
**Risk**: Out-of-bounds read returns garbage distances.
**Suggested fix**: Add precondition check with descriptive exception.

---

### ~~`TOmniIntegerSet.DoOnChange` fires user callback without guard~~ — Severity: Medium — FALSE REPORT
**Reason**: Callback is set by user; nil check is user's responsibility to set it.
**File**: `OtlCommon.pas:4497-4502`
**Category**: 5.3 Callback Safety
**Description**: `DoOnChange` calls the user-provided `OnChange` callback directly with no exception handling. If the callback raises, the set is in a partially modified state (`FHasValueCopy` invalidated, bits changed). Threading context is undocumented.
**Evidence**:
```pascal
procedure TOmniIntegerSet.DoOnChange;
begin
  FHasValueCopy := false;
  if assigned(OnChange) then
    OnChange(Self);     // user code, no exception guard
end;
```
**Risk**: Callback exception leaves set in inconsistent state. No documentation of which thread the callback executes on.
**Suggested fix**: Document that the callback is synchronous on the mutating thread. Wrap in try/except if exception safety is required.

---

### ~~`TOmniWaitableValue.Signal(data)` is not atomic — value/event race~~ — Severity: Medium — FALSE REPORT
**Reason**: Safe on x86/x64 (TSO memory model). OTL-NG targets Windows only, where this is not a correctness hazard.
**File**: `OtlCommon.pas:3275-3279`
**Category**: 5.2 Precondition Checking / 5.3 Callback Safety
**Description**: `Signal(data)` assigns `FValue` then sets the event with no memory fence or lock between them. On weakly-ordered architectures, a reader unblocked by `WaitFor` could observe the event signalled before seeing the updated `FValue`.
**Evidence**:
```pascal
procedure TOmniWaitableValue.Signal(const data: TOmniValue);
begin
  FValue := data;    // write FValue
  Signal;            // set event — no fence
end;
```
**Risk**: Safe on x86/x64 (TSO), but the API carries no documented thread-safety guarantee. On ARM/POSIX this is a real correctness hazard.
**Suggested fix**: Add a memory barrier between the assignment and `SetEvent`, or document TSO-only safety.

---

### ~~Unqualified `GetLastError` in `TOmniAffinity.GetCountPhysical`~~ — Severity: Low — FALSE REPORT
**Reason**: No local GetLastError override exists in the codebase.
**File**: `OtlCommon.pas:3424`
**Category**: 5.2 Precondition Checking
**Description**: One `GetLastError` call is unqualified; all others in the file use `Winapi.Windows.GetLastError`.
**Evidence**:
```pascal
GetLogicalProcessorInformation(nil, bufLen);
if GetLastError <> ERROR_INSUFFICIENT_BUFFER then   // unqualified
```
**Risk**: Low. No shadowing function found. Inconsistency only.
**Suggested fix**: Change to `Winapi.Windows.GetLastError`.

---

### ~~`TOmniValueContainer.GetName` has no bounds check~~ — Severity: Low — FALSE REPORT
**Reason**: Assert-level bounds checking is appropriate.
**File**: `OtlCommon.pas:1576-1579`
**Category**: 5.2 Precondition Checking
**Description**: `GetName(paramIdx)` accesses `ovcNames[paramIdx]` with no bounds check, unlike `GetItem` which has an `Assert`.
**Evidence**:
```pascal
function TOmniValueContainer.GetName(paramIdx: integer): string;
begin
  Result := ovcNames[paramIdx];   // no check
end;
```
**Risk**: Silent out-of-bounds read. Exposed via public `Name[paramIdx]` property.
**Suggested fix**: Add bounds check matching `GetItem`.

---

## OtlDataManager.pas

### ~~`AllocateOutputBuffer` precondition enforced only by Assert~~ — Severity: Medium — FALSE REPORT
**Reason**: Assert is appropriate for precondition checking.
**File**: `OtlDataManager.pas:995-999`
**Category**: 5.2 Precondition Checking
**Description**: `AllocateOutputBuffer` requires `dmOutputIntf` to be assigned (`SetOutput` must have been called first), but this is enforced only by `Assert`. A nil `dmOutputIntf` is passed into `TOmniOutputBufferSet.Create`, causing AV on subsequent `CopyToOutput`.
**Evidence**:
```pascal
function TOmniBaseDataManager.AllocateOutputBuffer: TOmniOutputBuffer;
begin
  Assert(assigned(dmOutputIntf));
  Result := TOmniOutputBufferSet.Create(Self, dmOutputIntf);
end;
```
**Risk**: Silent nil dereference in production builds.
**Suggested fix**: Replace `Assert` with a runtime exception.

---

### ~~`TOmniIntegerRangeProvider.GetPackageSizeLimit` raises unconditionally~~ — Severity: Low — FALSE REPORT
**Reason**: The method is never reached in normal usage (the spcFast capability bypasses this path). The exception is a correct guard against future misuse.
**File**: `OtlDataManager.pas:589-592`
**Category**: 5.1 Interface Contract Consistency
**Description**: Overrides a virtual method with an unconditional exception. Currently never reached (the `spcFast` capability bypasses this path), but the throwing behavior is undocumented on the base class.
**Evidence**:
```pascal
function TOmniIntegerRangeProvider.GetPackageSizeLimit: integer;
begin
  raise Exception.Create('No limit for TOmniIntegerRangeProvider packages');
end;
```
**Risk**: Future callers that invoke this method unconditionally get an undocumented exception.
**Suggested fix**: Document the contract on the base class or return -1 for "unlimited".

---

## OtlContainerObserver.pas

### ~~`NotifyOnce` callbacks fired under read lock~~ — Severity: Medium — CONFIRMED, DEFERRED
**File**: `OtlContainerObserver.pas:291-310`
**Category**: 5.3 Callback Safety
**Description**: `TOmniContainerSubject.NotifyOnce` and `Notify` iterate the observer list under a per-interest read lock and call `observer.Notify` while the lock is held. An observer callback that calls `Attach`/`Detach` on the same subject will deadlock on the write lock.
**Evidence**:
```pascal
csListLocks[interest].EnterReadLock;
try
  for iObserver := 0 to list.Count - 1 do begin
    observer := TOmniContainerObserver(list[iObserver]);
    if observer.CanNotify then begin
      observer.Notify;          // callback under read lock
      observer.Deactivate;      // redundant — CanNotify already deactivated
    end;
  end;
finally csListLocks[interest].ExitReadLock; end;
```
**Risk**: Deadlock if an observer calls `Attach`/`Detach` for the same interest from its `Notify` callback.
**Suggested fix**: Copy observers into a local list, release the lock, then dispatch.

---

## OtlBackgroundObserver.pas

### ~~Unsafe hard cast in `RegisterBackgroundObserver` (POSIX)~~ — Severity: Medium — FALSE REPORT
**Reason**: POSIX-only code path; OTL-NG targets Windows only. Dead code on the target platform.
**File**: `OtlBackgroundObserver.pas:351`, `356`
**Category**: 5.1 Interface Contract Consistency
**Description**: On non-Windows, `RegisterBackgroundObserver` and `UnregisterBackgroundObserver` use a hard class cast to `TOmniContainerCVObserverImpl` rather than an `as` cast.
**Evidence**:
```pascal
procedure RegisterBackgroundObserver(aObserver: TOmniContainerBackgroundObserver);
begin
  _BackgroundObserverRegistry.Add(TOmniContainerCVObserverImpl(aObserver)); // hard cast
end;
```
**Risk**: If the actual type is ever different, the hard cast silently produces a corrupt vtable pointer instead of raising `EInvalidCast`.
**Suggested fix**: Change to `as TOmniContainerCVObserverImpl`.

---

## OtlEventMonitor.pas

### ~~`ProcessTerminated` does not filter internal OTL messages~~ — Severity: Medium — CONFIRMED, DEFERRED
**File**: `OtlEventMonitor.pas:360-363`
**Category**: 5.1 Interface Contract Consistency
**Description**: `ProcessNewMessage` filters internal OTL messages via `FilterMessage` before calling the user's `OnTaskMessage` handler. `ProcessTerminated` drains Endpoint1 without `FilterMessage`, so internal messages (Invoke, control) leak to the user callback during termination.
**Evidence**:
```pascal
// ProcessNewMessage — filters:
if (not (task as IOmniTaskControlInternals).FilterMessage(emCurrentMsg))
   and assigned(emOnTaskMessage) then
  emOnTaskMessage(task, emCurrentMsg);

// ProcessTerminated — no filter:
while endpoint.Receive(emCurrentMsg) do
  if Assigned(emOnTaskMessage) then
    emOnTaskMessage(task, emCurrentMsg);   // internal messages pass through
```
**Risk**: User callback receives internal OTL messages during termination drain.
**Suggested fix**: Apply the same `FilterMessage` guard in `ProcessTerminated`.

---

### ~~`TOmniEventMonitorPool.Allocate` creates monitor under lock~~ — Severity: Low — FALSE REPORT
**Reason**: OOM-only scenario; constructor failure under lock is negligible. The lock is correctly released in the finally block.
**File**: `OtlEventMonitor.pas:457-466`
**Category**: 5.2 Precondition Checking
**Description**: `Allocate` creates `MonitorClass.Create(nil)` while `empListLock` is held. If creation raises, the lock is correctly released but the partially-constructed monitor leaks.
**Risk**: Minor resource leak on constructor failure.
**Suggested fix**: Create the monitor object before acquiring the lock.

---

## OtlPlatform.pas

### ~~Thread affinity get/set silently no-ops on POSIX~~ — Severity: Low — FALSE REPORT
**Reason**: POSIX-only code path; OTL-NG targets Windows only. Dead code on the target platform.
**File**: `OtlPlatform.pas:181-205`
**Category**: 5.1 Interface Contract Consistency
**Description**: `GetThreadAffinity` returns a fake full-affinity string and `SetThreadAffinity` is a complete no-op on non-Windows, with `// TODO` comments. No indication of failure to callers.
**Evidence**:
```pascal
class function TPlatform.GetThreadAffinity: string;
  {$ELSE}
  Result := Copy(CCPUIDs, 1, TThread.ProcessorCount);
  // TODO : pthread_getaffinity_np
  {$ENDIF MSWINDOWS}

class procedure TPlatform.SetThreadAffinity(const value: string);
  {$ELSE}
  // TODO : pthread_setaffinity_np
  {$ENDIF MSWINDOWS}
```
**Risk**: Code setting thread affinity on non-Windows silently succeeds with no effect.
**Suggested fix**: Document or raise `ENotImplemented`.

---

## Units With No Findings

- **OtlCommon.Utils.pas** — Small utility with no threading preconditions, callbacks, or interface contracts beyond its signature.
- **OtlSync.Utils.pas** — `TOmniSynchronizer<T>` has correct double-checked locking and proper MREW usage.
- **OtlTask.pas** — `TOmniWaitObjectList` is a plain list for single-thread use; `IOmniTask` declarations are consistent.
- **OtlLogger.pas** — Uses lock-free `TOmniBaseQueue` appropriately.

---

# Static Analysis Results — Category 6: Platform & Compiler Issues

**Date**: 2026-04-14
**Scope**: All 18 units listed in STATIC-ANALYSIS-SPEC.md
**Categories covered**: 6.1 Platform Portability, 6.2 Compiler Directives

**Summary**: 0 Critical, 2 High, 2 Medium, 11 Low findings across 9 units.

---

## OtlCommon.pas

### ~~`{$IFDEF Defined(...)}` is invalid preprocessor syntax — always evaluates false~~ — Severity: High — FINISHED
**File**: `OtlCommon.pas:4281`, `4300`, `4405`, `4424`
**Category**: 6.2 Compiler Directives
**Description**: Four `{$IFDEF}` directives use `Defined(CPU386) or Defined(CPUX64)` as their condition. This is invalid Delphi syntax — `{$IFDEF}` accepts only a plain identifier, not a boolean expression. The `Defined()` function is only valid inside `{$IF}`. The Delphi compiler silently treats the entire string `Defined(CPU386) or Defined(CPUX64)` as a single undefined symbol name, so the condition is **always false**. The `{$ELSE}` branch (using `TInterlocked.CompareExchange` / `TInterlocked.Exchange`) is always compiled instead of the intended fast-path direct read/write.
**Evidence**:
```pascal
function TOmniAlignedInt32.GetValue: integer;
begin
{$IFDEF Defined(CPU386) or Defined(CPUX64)}   // BUG: invalid syntax, always false
  Result := Addr^;                              // fast path — never compiled
{$ELSE}
  Result := TInterlocked.CompareExchange(integer(Addr^), 0, 0);  // always taken
{$ENDIF}
end;

procedure TOmniAlignedInt32.SetValue(value: integer);
begin
{$IFDEF Defined(CPU386) or Defined(CPUX64)}   // BUG: same invalid syntax
  Addr^ := value;                              // fast path — never compiled
{$ELSE}
  TInterlocked.Exchange(integer(Addr^), value); // always taken
{$ENDIF}
end;

// Same pattern for TOmniAlignedInt64.GetValue (line 4405) and SetValue (line 4424)
```
**Risk**: On x86 and x64, `TOmniAlignedInt32` and `TOmniAlignedInt64` always take the interlocked path instead of the intended direct memory access. For `TOmniAlignedInt32`, this is a pure performance penalty — aligned 32-bit reads/writes are atomic on both x86 and x64. For `TOmniAlignedInt64`, the interlocked path is actually **correct** on x86 (where 64-bit reads/writes are not atomic), so naively fixing the syntax would introduce a correctness bug on 32-bit targets. The `Int64` fast path should only be enabled for `CPUX64`, not `CPU386`.
**Suggested fix**: Replace `{$IFDEF Defined(CPU386) or Defined(CPUX64)}` with `{$IF Defined(CPU386) or Defined(CPUX64)}` and change `{$ENDIF}` to `{$IFEND}` for the `Int32` methods. For the `Int64` methods, use `{$IF Defined(CPUX64)}` / `{$IFEND}` only (64-bit reads are not atomic on x86).

---

### ~~`{$IFNDEF NEXTGEN}` dead guards — NextGen compiler retired~~ — Severity: Low — FALSE REPORT
**Reason**: Dead code is harmless; cleanup is a separate task.
**File**: `OtlCommon.pas:1919`, `1952`, `1976`
**Category**: 6.2 Compiler Directives
**Description**: Three `{$IFNDEF NEXTGEN}` guards protect `vtChar` and `vtString` handling in `TOmniValue.FromArray`. The NextGen (ARC) compiler was retired in Delphi 10.4. Since `OtlOptions.inc` requires Delphi 11+, `NEXTGEN` is never defined and these guards are dead weight. The source already contains a `// TODO : *** Recheck IFDEFs` comment acknowledging this.
**Evidence**:
```pascal
{$IFNDEF NEXTGEN}
  vtChar:   ovc.Add(string(VChar));
  vtString: ovc.Add(string(VString^));
{$ENDIF NEXTGEN}
```
**Risk**: No functional impact — the guarded code is always compiled. Minor maintenance noise.
**Suggested fix**: Remove the `{$IFNDEF NEXTGEN}` / `{$ENDIF}` guards, keeping the code unconditional.

---

## OtlCommon.Utils.pas

### ~~`OTL_HasTThreadCurrentThread` undefined — `SetThreadDescription` never called~~ — Severity: High — FINISHED
**File**: `OtlCommon.Utils.pas:78`, `103`, `113`, `119`, `125`
**Category**: 6.2 Compiler Directives
**Description**: Six `{$IFDEF OTL_HasTThreadCurrentThread}` blocks guard the declaration of `GSetThreadDescription`, its loading from `kernel32.dll` in the `initialization` section, and its invocation in `SetThreadName`. The symbol `OTL_HasTThreadCurrentThread` was a transitional define for Delphi XE8+ that was removed in `OtlOptions.inc` v3.01 (2026-04-12) along with all other transitional defines. However, the usage sites in `OtlCommon.Utils.pas` were not updated. Since the symbol is now never defined, all the guarded code is compiled out.
**Evidence**:
```pascal
// Variable declaration — never compiled:
{$IFDEF OTL_HasTThreadCurrentThread}
var
  GSetThreadDescription: TSetThreadDescription;
{$ENDIF OTL_HasTThreadCurrentThread}

// Usage in SetThreadName — never compiled:
  {$IFDEF OTL_HasTThreadCurrentThread}
  if assigned(GSetThreadDescription) then
    GSetThreadDescription(TThread.CurrentThread.Handle, PChar(name));
  {$ENDIF OTL_HasTThreadCurrentThread}

// Initialization — never compiled:
  {$IFDEF OTL_HasTThreadCurrentThread}
  GKernel32 := GetModuleHandle('kernel32.dll');
  if GKernel32 <> 0 then
    GSetThreadDescription := GetProcAddress(GKernel32, 'SetThreadDescription');
  {$ENDIF OTL_HasTThreadCurrentThread}
```
**Risk**: Functional regression — `SetThreadDescription` (the modern Windows 10+ API for naming threads, visible in Task Manager and ETW traces) is never loaded or called. Threads are still named via the older `TThread.NameThreadForDebugging` mechanism, but the modern API path is silently dead. On Delphi 11+ `TThread.CurrentThread` is always available, so the guard is unnecessary.
**Suggested fix**: Remove all `{$IFDEF OTL_HasTThreadCurrentThread}` / `{$ENDIF}` guards, keeping the guarded code unconditional.

---

## OtlParallel.pas

### ~~`PInteger` used to dereference pointer-sized anonymous method references on 64-bit~~ — Severity: Medium — FINISHED
**File**: `OtlParallel.pas:4634`, `4636`, `4637`, `4641`
**Category**: 6.1 Platform Portability
**Description**: `TOmniPipelineStage.Execute` checks whether anonymous method delegates (`opsSimpleStage`, `opsStage`, `opsStageEx`) are nil by dereferencing them through `PInteger` (4 bytes). The code asserts `SizeOf(TProc) = SizeOf(NativeInt)` — which is 8 on x64 — but then reads only the lower 4 bytes via `PInteger^` and compares to `NativeInt(nil)`. The comment "D2009 doesn't like TProc casts" is stale — OTL-NG requires Delphi 11+.
**Evidence**:
```pascal
// D2009 doesn't like TProc casts so we're casting to NativeInt
Assert(SizeOf(TProc) = SizeOf(NativeInt));
if PInteger(@opsSimpleStage)^ <> NativeInt(nil) then       // reads 4 of 8 bytes on x64
  ExecuteSimpleStage(task, opsSimpleStage, opsInput, opsOutput)
else if PInteger(@opsStage)^ <> NativeInt(nil) then begin   // reads 4 of 8 bytes on x64
  Assert(PInteger(@opsStageEx)^ = NativeInt(nil));
  opsStage(opsInput, opsOutput);
end
else begin
  Assert(PInteger(@opsStageEx)^ <> NativeInt(nil));
  opsStageEx(opsInput, opsOutput, task);
end;
```
**Risk**: On little-endian x64, a nil interface reference has all 8 bytes zero, and a non-nil reference has a non-zero lower 4 bytes (it's a pointer into the heap), so the `PInteger` check works by coincidence. However, this is a type-width mismatch: `PInteger` reads 4 bytes of an 8-byte field. The comparison `PInteger(...)^ <> NativeInt(nil)` also silently widens the 4-byte read to `NativeInt` (8 bytes) via sign extension, which could produce a false non-zero if the 4-byte value has its high bit set.
**Suggested fix**: Replace `PInteger` with `PNativeInt` in all four occurrences. Remove the stale D2009 comment.

---

### ~~`{$IFNDEF OTL_HasAPC}` branches are permanently dead on Windows~~ — Severity: Low — FALSE REPORT
**Reason**: Dead code is harmless; cleanup is a separate task.
**File**: `OtlParallel.pas:5476–5479`, `5599–5602`
**Category**: 6.2 Compiler Directives
**Description**: Two `{$IFNDEF OTL_HasAPC}` / `{$ENDIF}` blocks contain fallback code for platforms without APC support. `OTL_HasAPC` is always defined on Windows (set in `OtlOptions.inc`). Since OTL-NG targets Windows only, these branches are dead code.
**Risk**: No functional impact. Minor maintenance noise.

---

## OtlSync.pas

### ~~`{$IF}` pattern inconsistency between `TryBeginRead` and `TryBeginWrite`~~ — Severity: Low — FALSE REPORT
**Reason**: Both patterns compile correctly; purely cosmetic inconsistency with no functional impact.
**File**: `OtlSync.pas:405–413`, `419–426`, `435–442`, `492–500`
**Category**: 6.2 Compiler Directives
**Description**: `TryBeginRead` uses two separate `{$IF}` blocks — one inline for the `overload;` keyword, one wrapping the timeout overload declaration. `TryBeginWrite` uses a single `{$IF}` block spanning both the `overload;` keyword and the timeout overload. Both patterns produce correct code on Windows (single non-overloaded function) and on Linux/Android (overloaded pair), but the asymmetry is confusing for maintainers.
**Evidence**:
```pascal
// TryBeginRead — two separate {$IF} blocks:
function  TryBeginRead: boolean; {$IF defined(LINUX) or defined(ANDROID)}overload;{$IFEND} inline;
{$IF defined(LINUX) or defined(ANDROID)}
function  TryBeginRead(timeout: cardinal): boolean; overload; inline;
{$IFEND LINUX or ANDROID}

// TryBeginWrite — one spanning {$IF} block:
function  TryBeginWrite: boolean; {$IF defined(LINUX) or defined(ANDROID)}overload;
function  TryBeginWrite(timeout: cardinal): boolean; overload;
{$IFEND LINUX or ANDROID}
```
**Risk**: No functional impact. Both patterns compile correctly. Readability/consistency concern only.

---

### ~~Linux/Android `{$IF}` blocks are dead code in Windows-only library~~ — Severity: Low — FALSE REPORT
**Reason**: Dead code is harmless; cleanup is a separate task.
**File**: `OtlSync.pas:406–408`, `411–413`, `419–421`, `424–426`, `435–437`, `440–442`, `493–495`, `498–500`, `1561–1566`, `1583–1598`, `1824–1842`, `2898–2915`
**Category**: 6.2 Compiler Directives
**Description**: Multiple `{$IF defined(LINUX) or defined(ANDROID)}` blocks declare timeout-accepting overloads of `TryBeginRead` / `TryBeginWrite` and their implementations. OTL-NG targets Windows only, so these are dead code. Additionally, the idiom `defined(LINUX) or defined(ANDROID)` is inconsistent with the `{$IFDEF POSIX}` used elsewhere in the same file (e.g., line 216).
**Risk**: No functional impact. Maintenance noise and inconsistent conventions.

---

### ~~`{$IFDEF CPUX64}` / `{$ELSE}` implicitly assumes x86 in the else branch~~ — Severity: Low — FALSE REPORT
**Reason**: Safe for Windows x86/x64 targets. Runtime asserts catch mismatches on hypothetical other platforms.
**File**: `OtlSync.pas:971–976`, `980–985`, `2813–2817`, `2822–2826`, `2920–2926`
**Category**: 6.2 Compiler Directives
**Description**: Several `{$IFDEF CPUX64}` / `{$ELSE}` blocks cast to `int64` on x64 and `integer` on non-x64. The `{$ELSE}` branch implicitly assumes 32-bit x86 without explicitly checking `{$IFDEF CPU386}`. The `initialization` section has runtime asserts (`Assert(SizeOf(NativeInt) = SizeOf(integer))`) that catch mismatches, so this is safe for the current x86/x64 Windows targets.
**Risk**: Safe for Windows x86/x64. Would fail at runtime (assert) if compiled for a hypothetical 32-bit non-x86 target.

---

## OtlContainers.pas

### ~~`PInteger` aliasing over `TOmniTaggedValue` header slot on x64~~ — Severity: Medium — FINISHED
**File**: `OtlContainers.pas:1486`, `1498`, `1616`
**Category**: 6.1 Platform Portability
**Description**: The blocking collection uses the first `TOmniTaggedValue` in each buffer as a "header" slot, storing a reference count via `PInteger(memory)^`. On x64, `TOmniTaggedValue` starts with a `TOmniValue` field whose first element is pointer-sized (8 bytes). The `PInteger` cast writes/reads only 4 bytes. This works on little-endian x64 because the count is small (always ≤ 65535, enforced on line 1251–1253), so the upper 4 bytes are zero. However, the aliasing of a 4-byte integer over a field designed to hold a pointer-sized value is fragile.
**Evidence**:
```pascal
// PartitionMemory — writes 4 bytes of an 8-byte field:
PInteger(memory)^ := obcNumSlots - 1;

// IsEmpty — reads 4 bytes and decrements atomically:
if assigned(header) and (TInterlocked.Decrement(PInteger(header)^) = 0) then

// TryDequeue — same pattern:
if assigned(header) and (TInterlocked.Decrement(PInteger(header)^) = 0) then
```
**Risk**: Currently functional because counts are small and x64 is little-endian. Would silently fail if the count exceeded 2^31−1 or the underlying `TOmniValue` layout changed. The `TInterlocked.Decrement` operates on 4 bytes, which is safe for the count range but semantically inconsistent with the 8-byte slot.
**Suggested fix**: Use `PNativeInt` instead of `PInteger` and switch to the `NativeInt`-width `TInterlocked` overloads for consistency with the slot size.

---

### ~~Hardcoded `TOmniTaggedValue` stuffing depends on exact `TOmniValue` size~~ — Severity: Low — FALSE REPORT
**Reason**: Runtime assertion provides a safety net; the layout is brittle but guarded. No silent corruption is possible.
**File**: `OtlContainers.pas:297–300`, `1844`
**Category**: 6.1 Platform Portability
**Description**: `TOmniTaggedValue` uses a hardcoded `Stuffing: array[1..4] of byte` on x64 to pad the record to `3 * SizeOf(pointer)` = 24 bytes. The runtime assertion `Assert(SizeOf(TOmniTaggedValue) = {$IFDEF CPUX64}3{$ELSE}4{$ENDIF}*SizeOf(pointer))` catches mismatches, but the stuffing size is not computed from `TOmniValue`'s actual size. If `TOmniValue` changes size, the assertion fires at startup rather than silently producing wrong results — this is good, but the fix requires manually adjusting the hardcoded stuffing.
**Risk**: The runtime assertion provides a safety net. Low risk of silent corruption, but the layout is brittle.

---

### ~~`USE_MOVEDPTR` re-defined by last line, overriding `DEBUG_OMNI_QUEUE` undefine~~ — Severity: Low — FALSE REPORT
**Reason**: On Windows, OTL_HaveCmpx16b is always defined, so the re-define line is a no-op. Only affects a theoretical non-Windows debug build.
**File**: `OtlContainers.pas:1196–1199`
**Category**: 6.2 Compiler Directives
**Description**: The `{$DEFINE}`/`{$UNDEF}` sequence for `USE_MOVEDPTR` has a logic conflict: line 1199 re-defines `USE_MOVEDPTR` when `OTL_HaveCmpx16b` is not defined, regardless of whether `DEBUG_OMNI_QUEUE` previously cleared it. If both `DEBUG_OMNI_QUEUE` and non-Windows (no `OTL_HaveCmpx16b`) apply, the debug undefine is overridden.
**Evidence**:
```pascal
{$DEFINE USE_MOVEDPTR}
{$IFDEF DEBUG_OMNI_QUEUE}{$UNDEF USE_MOVEDPTR}{$ENDIF}
{$IFDEF OTL_OLDCPU}{$UNDEF USE_MOVEDPTR}{$ENDIF}
{$IFNDEF OTL_HaveCmpx16b}{$DEFINE USE_MOVEDPTR}{$ENDIF} //re-enables even if DEBUG cleared it
```
**Risk**: On Windows, `OTL_HaveCmpx16b` is always defined, so line 1199 is a no-op and `DEBUG_OMNI_QUEUE` works correctly. Only affects a theoretical non-Windows debug build.

---

### ~~`{$IFDEF MSWindows}` inconsistent casing~~ — Severity: Low — FALSE REPORT
**Reason**: Delphi preprocessor symbols are case-insensitive.
**File**: `OtlContainers.pas:123`
**Category**: 6.2 Compiler Directives
**Description**: Uses `{$IFDEF MSWindows}` (mixed case) while the rest of the codebase consistently uses `{$IFDEF MSWINDOWS}` (all caps). Delphi's preprocessor is case-insensitive, so this is not a functional bug.

---

## OtlTaskControl.pas

### ~~`{$IFDEF OTL_Anonymous}` dead code — symbol never defined~~ — Severity: Low — FALSE REPORT
**Reason**: Dead code is harmless; cleanup is a separate task. Implicit finalization handles cleanup.
**File**: `OtlTaskControl.pas:1888–1890`
**Category**: 6.2 Compiler Directives
**Description**: A `{$IFDEF OTL_Anonymous}` block guards `oteFunc := nil` in `TOmniTaskExecutor.Cleanup`. The symbol `OTL_Anonymous` is not defined anywhere in `OtlOptions.inc` or the codebase — it was a pre-Delphi-XE guard. The guarded nil-assignment is never compiled. The field `oteFunc` (a `TOmniTaskDelegate` = reference type) is cleaned up by the compiler's implicit finalization when the object is destroyed, so no resource leak results.
**Evidence**:
```pascal
{$IFDEF OTL_Anonymous}
oteFunc := nil;
{$ENDIF OTL_Anonymous}
```
**Risk**: No functional impact — implicit finalization handles cleanup. Dead code that should be removed (make the nil-assignment unconditional or remove it entirely).

---

### ~~`MSWindows` vs `MSWINDOWS` casing inconsistency~~ — Severity: Low — FALSE REPORT
**Reason**: Delphi preprocessor symbols are case-insensitive.
**File**: `OtlTaskControl.pas:2513`, `2518`, `2527`, `2533`
**Category**: 6.2 Compiler Directives
**Description**: Four `{$IFDEF MSWindows}` occurrences in `SetNUMANode` and `SetProcessorGroup` use mixed case, while the rest of the file (and codebase) consistently uses `{$IFDEF MSWINDOWS}` (all caps). No functional impact due to case-insensitive preprocessor.

---

### ~~Unlabeled `{$ENDIF}` blocks mixed with labeled ones in `Asy_Execute`~~ — Severity: Low — FALSE REPORT
**Reason**: No functional impact; purely cosmetic readability concern.
**File**: `OtlTaskControl.pas:1696`, `1701`, `1723`
**Category**: 6.2 Compiler Directives
**Description**: Three `{$ENDIF}` directives in `Asy_Execute` lack the matching symbol label (e.g., `{$ENDIF}` instead of `{$ENDIF POSIX}` or `{$ENDIF MSWINDOWS}`), while adjacent blocks in the same method use labeled `{$ENDIF MSWINDOWS}`. This makes ifdef matching harder to audit in the most complex method of the file.
**Risk**: No functional impact. Readability concern in a method with dense platform-specific branching.

---

### ~~Dead POSIX thread-priority code~~ — Severity: Low — FALSE REPORT
**Reason**: Dead code is harmless; cleanup is a separate task.
**File**: `OtlTaskControl.pas:1694–1723`
**Category**: 6.2 Compiler Directives
**Description**: Two `{$IFDEF POSIX}` blocks in `Asy_Execute` contain POSIX thread-priority code. Since OTL-NG targets Windows only, these are dead code.
**Risk**: No functional impact. Maintenance noise.

---

## OtlEventMonitor.pas

### ~~`integer()` cast of `TThreadID` in monitor pool~~ — Severity: Low — FALSE REPORT
**Reason**: Safe on Windows where TThreadID is 32-bit. OTL-NG targets Windows only.
**File**: `OtlEventMonitor.pas:439`, `457`, `463`, `475`, `479`
**Category**: 6.1 Platform Portability
**Description**: `TOmniEventMonitorPool` uses `TObjectDictionary<integer, TObject>` and casts `TThreadID` to `integer` for dictionary keys. On Windows (both x86 and x64), `TThreadID` is `LongWord` (32-bit unsigned), so the cast to `integer` (32-bit signed) is a reinterpretation without data loss. Thread IDs on Windows fit within 31 bits in practice. However, using `integer` instead of the canonical `TThreadID` type obscures the intent and would break on a platform where `TThreadID` is wider than 32 bits.
**Risk**: Safe on Windows. The dictionary key type should ideally be `TThreadID` for type safety and self-documentation.

---

## OtlContainerObserver.pas, OtlCollections.pas, OtlComm.pas, OtlDataManager.pas, OtlHooks.pas, OtlBackgroundObserver.pas, OtlSync.Utils.pas, OtlTask.pas, OtlPlatform.pas, OtlLogger.pas

No Category 6 findings.

---

## Units With No Findings

- **OtlCollections.pas** — No platform or compiler directive issues.
- **OtlDataManager.pas** — `{$IFDEF Debug}` usage is clean and properly paired.
- **OtlHooks.pas** — No conditional compilation.
- **OtlBackgroundObserver.pas** — `{$IFDEF OTL_HasAPC}` blocks are well-matched and consistent.
- **OtlContainerObserver.pas** — No conditional compilation.
- **OtlSync.Utils.pas** — No platform-specific code.
- **OtlTask.pas** — No conditional compilation.
- **OtlPlatform.pas** — Correctly uses `NativeUInt` for affinity masks; `{$IFDEF MSWINDOWS}` blocks are properly paired.
- **OtlLogger.pas** — No conditional compilation.

---

# Static Analysis Results — Category 7: Code Quality

**Date**: 2026-04-14
**Scope**: All 18 units listed in STATIC-ANALYSIS-SPEC.md
**Categories covered**: 7.1 Unreachable / Dead Code, 7.2 Inconsistent Patterns, 7.3 Suspicious Constructs

**Summary**: 0 Critical, 3 High, 5 Medium, 5 Low findings across 8 units.

---

## OtlContainers.pas

### ~~`PropagateNotifications` loop iterates only first element — `Low to Low` typo~~ — High — FINISHED
**File**: `OtlContainers.pas:1779`
**Category**: 7.1 Unreachable / Dead Code
**Description**: The `for` loop range uses `Low(TOmniContainerObserverInterest) to Low(TOmniContainerObserverInterest)` — both bounds are `Low`, so the loop body executes at most once (for the first enum value only). All other enum values are never checked. This is a copy-paste bug; the upper bound should be `High`.
**Evidence**:
```pascal
procedure TOmniValueQueue.PropagateNotifications(Events: TInterestSet);
var
  Ev: TOmniContainerObserverInterest;
begin
  if assigned(FContainerSubject) and (Events <> []) then
    for Ev := Low(TOmniContainerObserverInterest) to Low(TOmniContainerObserverInterest) do
      if Ev in Events then
        FContainerSubject.Notify(Ev);
end;
```
**Risk**: Only `coiNotifyOnAllInserts` (the first enum value) is ever propagated. Notifications for `coiNotifyOnAllRemoves`, `coiNotifyOnPartlyEmpty`, and `coiNotifyOnAlmostFull` are silently dropped. Subscribers to `TOmniValueQueue` will never be notified of removals or capacity events.
**Suggested fix**: Change `Low` to `High` on the upper bound: `for Ev := Low(TOmniContainerObserverInterest) to High(TOmniContainerObserverInterest) do`

### ~~`CollectionNotifyEvent` uses wrong threshold for `coiNotifyOnPartlyEmpty`~~ — High — FINISHED
**File**: `OtlContainers.pas:1715`
**Category**: 7.3 Suspicious Constructs
**Description**: In the `cnRemoved/cnExtracted` branch of `CollectionNotifyEvent`, the code checks `AfterCount = FAlmostFullThreshold` to decide whether to fire `coiNotifyOnPartlyEmpty`. It should check `AfterCount = FPartlyEmptyThreshold` instead. The "almost full" threshold is the wrong threshold for a "partly empty" notification.
**Evidence**:
```pascal
    cnRemoved,
    cnExtracted:
      begin
        Include(FNotifiableEvents, coiNotifyOnAllRemoves);
        if AfterCount = FAlmostFullThreshold then          // <-- wrong threshold
          Include(FNotifiableEvents, coiNotifyOnPartlyEmpty);
      end;
```
**Risk**: `coiNotifyOnPartlyEmpty` fires at the wrong count. Since `FAlmostFullThreshold > FPartlyEmptyThreshold`, the notification fires too late (at 90% capacity instead of 80%), breaking throttling logic that depends on it. Note: this bug is partially masked by the `Low to Low` bug above.
**Suggested fix**: Change to `if AfterCount = FPartlyEmptyThreshold then`.

### ~~Double semicolons~~ — Low — FINISHED
**File**: `OtlContainers.pas:1673`
**Category**: 7.3 Suspicious Constructs
**Description**: Double semicolons `;;` in constructor — harmless but indicates sloppy editing.
**Evidence**:
```pascal
  FContainerSubject := TOmniContainerSubject.Create;;
```
**Risk**: None (syntactically valid). Cosmetic issue.
**Suggested fix**: Remove the extra semicolon.

---

## OtlSync.Utils.pas

### ~~`TObjectDictionary` created without ownership — TEvent objects leaked~~ — High — FINISHED
**File**: `OtlSync.Utils.pas:92`
**Category**: 7.3 Suspicious Constructs
**Description**: `TOmniSynchronizer<T>` creates its `FEvents` dictionary as `TObjectDictionary<T, TEvent>.Create` without passing `[doOwnsValues]`. The `Ensure` method creates `TEvent` objects and stores them in the dictionary. When the dictionary is freed in the destructor, the `TEvent` objects are not freed because the dictionary doesn't own them.
**Evidence**:
```pascal
constructor TOmniSynchronizer<T>.Create;
begin
  inherited Create;
  FEvents := TObjectDictionary<T, TEvent>.Create;  // missing [doOwnsValues]
end;

function TOmniSynchronizer<T>.Ensure(const name: T): TEvent;
begin
  // ...
  event := TEvent.Create(nil, true, false, '');
  // ...
  FEvents.Add(name, Result);  // stored but never freed
end;
```
**Risk**: Memory leak — every unique synchronization point name leaks a `TEvent` object. In test suites that create many synchronizers, this accumulates.
**Suggested fix**: Change to `FEvents := TObjectDictionary<T, TEvent>.Create([doOwnsValues]);`

---

## OtlThreadPool.pas

### ~~Empty except block silently swallows thread data cleanup exceptions~~ — Medium — FALSE REPORT
**Reason**: The except block is intentional cleanup code; thread data destruction must not propagate exceptions as it would prevent MSG_THREAD_DESTROYING from being sent.
**File**: `OtlThreadPool.pas:796-799`
**Category**: 7.3 Suspicious Constructs
**Description**: Setting `owtThreadData := nil` is wrapped in a bare `try/except end` that silently swallows all exceptions. If the thread data's destructor (via interface release) raises, the exception is lost with no logging or indication.
**Evidence**:
```pascal
        try
          owtThreadData := nil;
        except
        end;
```
**Risk**: If thread data cleanup raises an exception (e.g., due to a bug in user-provided `IInterface` destructor), the error is completely hidden, making debugging very difficult.
**Suggested fix**: At minimum, log the exception or route it through the unhandled-exception callback (`owtAsy_OnUnhandledException`) that already exists in the outer handler.

### ~~Thread data factory exception silently swallowed~~ — Medium — FALSE REPORT
**Reason**: Intentional; cleanup code that shouldn't propagate exceptions.
**File**: `OtlThreadPool.pas:780-784`
**Category**: 7.3 Suspicious Constructs
**Description**: If the thread data factory raises an exception, the code silently sets `owtThreadData := nil` and continues execution. The thread proceeds without thread data and no indication that the factory failed.
**Evidence**:
```pascal
        if owtThreadDataFactory.IsEmpty then
          owtThreadData := nil
        else try
          owtThreadData := owtThreadDataFactory.Execute;
        except
          owtThreadData := nil;
        end;
```
**Risk**: A broken thread data factory (e.g., resource allocation failure) goes unnoticed. Workers silently operate with nil thread data, potentially causing NullReferenceExceptions later that are hard to trace back to the factory failure.
**Suggested fix**: Either log the exception, propagate it, or at minimum set a flag/status that the factory failed.

---

## OtlCommon.Utils.pas

### ~~`FreeLibrary` called on `GetModuleHandle` result~~ — Medium — FINISHED
**File**: `OtlCommon.Utils.pas:120-128`
**Category**: 7.3 Suspicious Constructs
**Description**: `GetModuleHandle` does not increment the DLL reference count, but the finalization section calls `FreeLibrary` on the returned handle. This is an API contract violation — `FreeLibrary` should only be called on handles obtained via `LoadLibrary`/`LoadLibraryEx`.
**Evidence**:
```pascal
initialization
  GKernel32 := GetModuleHandle('kernel32.dll');
  if GKernel32 <> 0 then
    GSetThreadDescription := GetProcAddress(GKernel32, 'SetThreadDescription');
finalization
  if GKernel32 <> 0 then
    FreeLibrary(GKernel32);     // wrong — GetModuleHandle doesn't increment refcount
```
**Risk**: For `kernel32.dll` specifically, Windows prevents it from being unloaded, so no crash occurs in practice. However, this is incorrect API usage and would cause a premature DLL unload if the same pattern were used with any other DLL.
**Suggested fix**: Remove the `FreeLibrary` call entirely. `GetModuleHandle` is a non-owning lookup, so no cleanup is needed.

---

## OtlCommon.pas

### ~~Double semicolon~~ — Low — FALSE REPORT
**Reason**: Harmless; double semicolons are syntactically valid in Delphi.
**File**: `OtlCommon.pas:1797`
**Category**: 7.3 Suspicious Constructs
**Description**: Double semicolons `;;` — harmless but indicates sloppy editing.
**Evidence**:
```pascal
function TOmniInterfaceDictionary.Count: integer;
begin
  Result := FDictionary.Count;;
end;
```
**Risk**: None. Cosmetic issue.
**Suggested fix**: Remove the extra semicolon.

---

## OtlTaskControl.pas

### ~~Empty except block for priority setting~~ — Low — FALSE REPORT
**Reason**: POSIX-only code; OTL-NG targets Windows only. Dead code on the target platform.
**File**: `OtlTaskControl.pas:1717-1721`
**Category**: 7.3 Suspicious Constructs
**Description**: Setting thread priority on POSIX is wrapped in a bare except that silently swallows all exceptions. The comment says "We don't have privilege" but any exception type is caught.
**Evidence**:
```pascal
    try
      This.Priority := Value
    except
      // We don't have privilege. We need to be root to do this.
    end
```
**Risk**: Low — this is POSIX-only code and the intent is clear. However, it would be better to catch only `EOS` or the specific exception class rather than swallowing all exceptions.
**Suggested fix**: Narrow the exception filter to the expected exception type, or at minimum log the failure at debug level.

---

## OtlLogger.pas

### ~~Unnecessary assignment inside `Clear` loop~~ — Low — FALSE REPORT
**Reason**: Harmless; forces early release of TOmniValue resources, which is a valid defensive pattern.
**File**: `OtlLogger.pas:105-108`
**Category**: 7.3 Suspicious Constructs
**Description**: In `Clear`, the dequeued value is assigned `tmp := ''` inside the loop, which is unnecessary. The value is a local variable that is immediately overwritten by the next `TryDequeue` call. There's also a stray semicolon on its own line.
**Evidence**:
```pascal
procedure TOmniLogger.Clear;
var
  tmp: TOmniValue;
begin
  while eventList.TryDequeue(tmp) do begin
    tmp := '';
    ;
  end;
end;
```
**Risk**: Minor performance waste — forces TOmniValue to release any held string/interface reference one iteration early, but the loop variable would be finalized anyway. The stray `;` is harmless.
**Suggested fix**: Simplify to `while eventList.TryDequeue(tmp) do ;` — the TOmniValue finalization in TryDequeue handles cleanup.

---

## OtlEventMonitor.pas

### ~~`ProcessTerminated` does not call `FilterMessage`~~ — Medium — CONFIRMED, DEFERRED
**File**: `OtlEventMonitor.pas:361-367`
**Category**: 7.2 Inconsistent Patterns
**Description**: In `ProcessNewMessage`, the code calls `(task as IOmniTaskControlInternals).FilterMessage(emCurrentMsg)` to filter out internal messages before passing them to the event handler. However, in `ProcessTerminated`, which also drains the comm channels, `FilterMessage` is never called. Internal messages (e.g., Invoke dispatches) are passed directly to `emOnTaskMessage` and `emOnTaskUndeliveredMessage`.
**Evidence**:
```pascal
// ProcessNewMessage (line 330): filters messages
if (not (task as IOmniTaskControlInternals).FilterMessage(emCurrentMsg))
   and assigned(emOnTaskMessage)
then
  emOnTaskMessage(task, emCurrentMsg);

// ProcessTerminated (line 361): does NOT filter
while endpoint.Receive(emCurrentMsg) do
  if Assigned(emOnTaskMessage) then
    emOnTaskMessage(task, emCurrentMsg);  // internal messages leak through
```
**Risk**: When a task terminates with queued internal messages (e.g., pending `Invoke` calls), those internal messages are delivered to the user's `OnTaskMessage` handler, which may not expect them.
**Suggested fix**: Add the same `FilterMessage` check in `ProcessTerminated` before calling `emOnTaskMessage`.

---

## OtlContainerObserver.pas, OtlBackgroundObserver.pas, OtlCollections.pas, OtlComm.pas, OtlDataManager.pas, OtlHooks.pas, OtlPlatform.pas, OtlSync.pas, OtlParallel.pas, OtlTask.pas

No additional Category 7 findings beyond what was already reported in Categories 1–6.

---

## Units with no Category 7 findings

- **OtlSync.pas** — Code is well-structured; no dead code, inconsistent patterns, or suspicious constructs found.
- **OtlParallel.pas** — No new issues beyond those already reported.
- **OtlCollections.pas** — Clean code quality.
- **OtlComm.pas** — Clean code quality.
- **OtlDataManager.pas** — Clean code quality.
- **OtlHooks.pas** — Clean code quality.
- **OtlBackgroundObserver.pas** — Clean code quality.
- **OtlContainerObserver.pas** — Clean code quality.
- **OtlPlatform.pas** — Clean code quality.
- **OtlTask.pas** — Clean code quality.

---

## Summary

| Severity | Count | Key Findings |
|----------|-------|-------------|
| **Critical** | 0 | — |
| **High** | 3 | OtlContainers `PropagateNotifications` `Low to Low` loop — only first enum value checked, all other notifications silently dropped; OtlContainers `CollectionNotifyEvent` uses `FAlmostFullThreshold` instead of `FPartlyEmptyThreshold` for partly-empty notification; OtlSync.Utils `TObjectDictionary` missing `[doOwnsValues]` — TEvent objects leaked |
| **Medium** | 5 | OtlThreadPool empty except blocks silently swallowing thread data exceptions (2 locations); OtlCommon.Utils `FreeLibrary` on `GetModuleHandle` result; OtlEventMonitor `ProcessTerminated` missing `FilterMessage` |
| **Low** | 5 | Double semicolons (OtlContainers, OtlCommon); OtlTaskControl empty POSIX priority except; OtlLogger unnecessary assignment + stray semicolon in `Clear` |

---

## Cumulative Summary (Categories 1–7)

| Severity | Count | Key Findings |
|----------|-------|-------------|
| **Critical** | 2 | OtlHooks procedure pointer stores stack address (all 3 notification classes); OtlSync `Locked<T>.Initialize` broken double-checked locking |
| **High** | 15 | OtlHooks callbacks under read lock; OtlSync `TOmniWrappedEvent` ownership broken; OtlContainers `Empty` missing lock, `PropagateNotifications` `Low..Low` loop, `CollectionNotifyEvent` wrong threshold; OtlTaskControl unsafe `as` cast, missing IndexOf guard, nil `otcSharedInfo` in destructor; OtlParallel nil Initializer/Finalizer, nil `GetOnRequestDone`, `FTasks` use-after-free; OtlCollections throttle Assert; OtlCommon `TOmniMessageID` Assert, `GetItem` Assert; OtlThreadPool Cancel timeout 1000x; OtlCommon `{$IFDEF Defined(...)}` invalid syntax; OtlCommon.Utils `OTL_HasTThreadCurrentThread` undefined; OtlSync.Utils TEvent leak |
| **Medium** | 29 | Callback-under-lock patterns (OtlContainers, OtlComm, OtlContainerObserver, OtlSync); missing bounds checks (OtlCommon, OtlCollections); undocumented callback contexts (OtlTaskControl, OtlThreadPool); thread-safety gaps (OtlCollections `obcAccessed`, OtlThreadPool singleton, OtlSync `FState`); `FindGroup` index-as-number; `ProcessTerminated` unfiltered messages (OtlEventMonitor); `PInteger` nil check on 64-bit (OtlParallel, OtlContainers); OtlThreadPool swallowed exceptions (2); OtlCommon.Utils `FreeLibrary`/`GetModuleHandle` mismatch |
| **Low** | 27 | Re-entrant lock dependency; misleading cardinal comparison; missing try/finally; constructor ordering; redundant code; unqualified `GetLastError`; POSIX stubs; Assert-based RTTI checks; dead ifdef blocks (OTL_Anonymous, NEXTGEN, Linux/Android, OTL_HasAPC); casing inconsistencies; unlabeled `{$ENDIF}`; implicit x86 assumption; hardcoded stuffing; `USE_MOVEDPTR` logic; `integer` vs `TThreadID`; double semicolons (OtlContainers, OtlCommon); empty POSIX except (OtlTaskControl); OtlLogger stray code in `Clear` |
