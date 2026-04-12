# OmniThreadLibrary NG — Specification & Implementation Plan

## Context

OmniThreadLibrary (OTL) is a mature Delphi threading library that has been Windows-only since its inception. With Delphi now supporting macOS, Linux, iOS, Android, and ARM Windows, OTL needs a platform-independent rewrite to remain relevant. OTL NG ("New Generation") is a new major release that targets all Delphi-supported platforms while preserving the library's core API and programming model. It is not a drop-in upgrade from v3 but should offer a clear migration path.

**Minimum Delphi version**: 11 Alexandria (with 12/13 as primary targets; older versions supported only where not burdensome).

---

## Phase 0: Repository Bootstrap

### 0.1 Sync local master with remote
- [x] Update local master: `git checkout master && git pull origin master` (70 commits, fast-forward to `80b5f297`)

### 0.2 Cherry-pick recent master commits into v4-develop-2
- [x] Cherry-pick 22 meaningful commits from `origin/master` (2025-09-08 to 2026-03-23)
- [x] Key changes: TLightweightMREWEx + ILightweightMREWEx, MREW race condition fix, Locked\<T\> MREW capabilities + IsInitialized, TOmniValue.LogValue improvements, OtlCollections optimizations, LoadNUMAInfo fix, bad 64-bit pointer cast fixes
- [x] Skipped: 5 commits (package files, release docs, CI workflows, unversion)
- [x] Fix compilation issues from cherry-pick conflicts (duplicate methods, missing SetAsUInt64 impl, orphan ERTTI ifdef, IOmniEvent.Handle type fix)
- [x] Update GpDelphiUnits submodule to latest
- [x] Verified: CompileAllUnits.dpr passes Win32 + Win64

### 0.3 Create new repository
- [x] Create `gabr42/OmniThreadLibrary-NG` on GitHub
- [x] Initialize with `develop` branch seeded from v4-develop-2 (after cherry-picks)
- [x] History from the old repo is not carried over — clean start
- [x] `main` branch gets only a README pointing to the project and its relationship to OTL v3
- [x] Set `develop` as the default branch

### 0.4 CI & PR review setup
- [ ] GitHub Actions workflow for Delphi compilation on Windows (Win32 + Win64) — deferred, needs self-hosted runner
- [ ] GitHub Actions workflow for Linux cross-compilation (when supported) — deferred
- [x] Claude Code PR review via GitHub Action (claude-code-review.yml + claude.yml)
- [x] Branch protection on `main`: require PR (CI checks to be added when runner is available)

### 0.5 Submodule setup
- [x] Add `GpDelphiUnits` as a git submodule (same as current setup)
- [x] Add `FastMM` as a git submodule (Windows-only, optional)

---

## Phase 1: Foundation — Platform Abstraction Layer

**Goal**: Replace all Windows-specific primitives with cross-platform abstractions. Everything in this phase compiles and passes tests on Windows before moving on.

### 1.1 OtlOptions.inc cleanup
- [x] Remove minimum compiler version checks for pre-Delphi 11
- [x] Remove `OTL_MobileSupport` conditional — platform independence is now the default
- [x] Keep `OTL_HaveCmpx16b` as opt-in for Windows+x86/x64 performance (but no code path should *require* it)
- [x] Remove the `{$IFNDEF MSWINDOWS}` error directive
- [x] Define `OTL_HasAPC` for Windows (gates QueueUserAPC-based fast path)
- [x] Keep `OTL_PlatformIndependent` as a way to force platform-independent code paths on Windows (for testing)

### 1.2 OtlSync.pas — Synchronization primitives
**Files**: `OtlSync.pas`

#### 1.2.1 Remove inline assembly
- [x] Replace all 16 CAS/atomic assembly blocks with `TInterlocked` / `TInterlockedEx` calls
- [x] `CAS32` -> `TInterlocked.CompareExchange`
- [x] `CAS64` -> `TInterlocked.CompareExchange` (Int64 overload)
- [x] `NInterlockedExchangeAdd` -> `TInterlocked.Add`
- [x] `MFence` -> `System.MemoryBarrier` (compiler intrinsic)
- [x] `Move64`, `Move128`, `MoveDPtr` -> pure Pascal using `TInterlocked.Exchange`/`InterlockedCompareExchange128`
- [x] Keep `TInterlockedEx` wrapper for readability

#### 1.2.2 Redesign 5-parameter CAS (CMPXCHG16B) dependency
- [x] Win32: Pack pointer+reference into Int64, use `TInterlocked.CompareExchange(Int64)`
- [x] Win64: Use `Winapi.Windows.InterlockedCompareExchange128` (RTL-declared)
- [x] Non-Windows: Spinlock fallback (containers have non-lock-free path when `OTL_HaveCmpx16b` is undef)
- [x] CAS8/CAS16: Byte-in-word CAS technique with retry loop

#### 1.2.3 Unify TOmniTransitionEvent
- [ ] `TOmniTransitionEvent = IOmniEvent` on ALL platforms (deferred — cascades to OtlComm.pas)
- [x] `IOmniEvent` wraps `System.SyncObjs.TEvent` — already cross-platform
- [x] Remove `IOmniHandleObject` interface (replaced by `IOmniSynchroObject`)
- [x] Unify `IOmniCancellationToken` — always uses `IOmniEvent` internally
- [x] `IOmniResourceCount` inherits from `IOmniSynchroObject` unconditionally

#### 1.2.4 Replace WaitForMultipleObjects
- [x] All multi-wait code uses condition-variable-based `TWaitFor` (formerly `TSynchroWaitFor`)
- [x] On Windows: condition variables used for WaitAll/WaitAny; `MsgWaitAny` uses `MsgWaitForMultipleObjectsEx` directly
- [x] `TWaitFor` class is the single implementation on all platforms
- [x] Windows-only convenience: `Create(THandle[])`, `SetHandles`, `MsgWaitAny`, `WaitHandles` property
- [ ] Remove `MsgWaitForMultipleObjectsEx` usage from task loop (see Phase 2)

#### 1.2.5 TOmniResourceCount
- [x] Replace Windows event handle implementation with `IOmniEvent`-based implementation
- [x] Single unified class on all platforms (removed non-Windows stub)
- [x] Windows-only `Handle` property for backward compatibility

#### 1.2.6 Cleanup (sub-step G)
- [x] Remove `DSiWin32`, `GpStuff`, `GpLists` from uses clause
- [x] `TOmniLockManager<K>`: Replace `TDSiEventHandle`/`TGpDoublyLinkedList` with `IOmniEvent`/`TObjectList`
- [x] Remove all `{$IFDEF OTL_MobileSupport}` guards (always true)
- [x] Remove all `{$IFDEF OTL_HasVolatileAttribute}` guards (always true)
- [x] Remove `{$IFDEF OTL_CountdownHasSpinCount}` guard (always true)
- [x] Remove `{$IFDEF OTL_ForceThreadTracking}` usage (define removed)
- [x] Implement `TOmniSingleThreadUseChecker.Check/DebugCheck` unconditionally
- [x] Delete `OtlSync_.pas` (dead v2.02 snapshot)

### 1.3 OtlContainers.pas — Lock-free containers
**Files**: `OtlContainers.pas`

- [x] Remove assembly-based `CASTag` — CAS functions now pure Pascal in OtlSync (Step 1.2); CASTag calls CAS8 from OtlSync
- [x] Replace `asm pause` spinlock yield with `TThread.SpinWait(1)` (cross-platform pause hint)
- [x] Lock-free queues (`TOmniBaseBoundedQueue`, `TOmniBaseBoundedStack`) **remain lock-free** on Windows (bus-locked path via `OTL_HaveCmpx16b`); critical-section fallback on other platforms
- [x] Remove `DSiWin32`, `GpStuff`, `Winapi.Windows` dependencies (all were dead imports)
- [x] Remove `{$IFDEF OTL_MobileSupport}` guards (always true with Delphi 11+)
- [x] Unify `TReferencedPtr` layout — `Reference` field always present
- [x] Always allocate critical section locks (fields unconditional; Acquire/Release conditional)
- [x] Remove automatic `OTL_OLDCPU` for Win32 (SSE2 is baseline for Delphi 11+)
- [x] Make initialization size assertions unconditional
- **Deferred**: Truly lock-free non-128-bit-CAS fallback (hazard pointers or index-based 64-bit CAS) — significant algorithmic redesign, deferred past Phase 1

### 1.4 OtlCollections.pas — Blocking collection
**Files**: `OtlCollections.pas`

- [x] `TOmniBlockingCollection`: Replace `WaitForMultipleObjects` with `TWaitFor.WaitAny` (condition-variable-based)
- [x] Replace `THandle` arrays with `IOmniEvent`-based `TWaitFor` (persistent `FTakeWaiter` and `FCompletedWaiter` fields)
- [x] Lock-free internals: collection uses `TOmniQueue` (lock-free on Windows via OTL_HaveCmpx16b, CS fallback elsewhere — unchanged from Step 1.3)
- [x] Replace `DSiWaitForTwoObjects` in TryAdd with `FCompletedWaiter.WaitAny`
- [x] Switch from `TOmniContainerWindowsEventObserver` to `TOmniContainerEventObserver` (returns `IOmniEvent`)
- [x] Remove `DSiWin32`, `GpStuff`, `Winapi.Windows`, `OtlPlatform` dependencies
- [x] Replace `asm pause` with `TThread.SpinWait(1)`
- [x] Fixed non-Windows TryTake bug: observer event was omitted from waiter, preventing wake-up on enqueue
- **Test blocked on 1.5**: ~~`TestBlockingCollection1` hangs because `TOmniEvent.SetEvent` on Windows bypasses `PerformObservableAction`~~ **Fixed in Step 1.5.**

### 1.5 OtlContainerObserver.pas — Observer pattern
**Files**: `OtlContainerObserver.pas`, `OtlSync.pas`

- [x] **Fixed (deferred from 1.2)**: `TOmniEvent.Reset`/`SetEvent` now always use `PerformObservableAction` on all platforms, fixing CV-based `TWaitFor` on Windows
- [x] Removed DSiWin32 dependency from OtlContainerObserver.pas
- [x] Removed `OTL_PlatformIndependent` guards (replaced with plain `{$IFDEF MSWINDOWS}`)
- [x] Removed `OTL_RaiseLastOSErrorHasAdditionalInfo` ifdef (always available in Delphi 11+)
- [x] Keep `TOmniContainerEventObserver` (IOmniEvent-based) as the universal observer
- [x] Keep `TOmniContainerPlatformObserver` for monitor-based notification
- [x] All 61 unit tests pass (including previously-deadlocking `TestBlockingCollection1`)
- **Deferred to Phase 2**: Remove `TOmniContainerWindowsMessageObserver` and `TOmniContainerWindowsEventObserver` — still used by `OtlComm.pas` (Step 2.1) and `OtlParallel.pas` (Step 3.1)

### 1.6 OtlPlatform.pas — Platform utilities
**Files**: `OtlPlatform.pas`

- [x] `TTimeSource`: Uses `TStopwatch.ElapsedMilliseconds` on all platforms (removed `DSiTimeGetTime64` path)
- [x] Thread affinity: Implemented for Windows via direct `Winapi.Windows` API (`GetProcessAffinityMask`, `SetThreadAffinityMask`). Non-Windows: no-op with TODO for `pthread_setaffinity_np`.
- [x] `TPlatform.ThreadID`: Already cross-platform via `TThread.CurrentThread.ThreadID`
- [x] Removed DSiWin32 dependency
- [x] All 61 unit tests pass
- **Deferred to Phase 2**: Drop NUMA support (`NUMANode`, `ProcessorGroup`) — these are in `OtlCommon.pas` and `OtlTaskControl.pas`

### 1.7 Remove GpLists dependency
- [x] Replaced all GpLists types in 6 files with standard `System.Generics.Collections`:
  - `TGpInt64List` → `TList<Int64>` (OtlTask, OtlTaskControl)
  - `TGpTMethodList` → `TList<TMethod>` (OtlTask)
  - `TGpIntegerObjectList` → `TObjectDictionary<Integer, TObject>` (OtlEventMonitor) or `TList<TPair<Integer, TObject>>` (OtlTaskControl, OtlParallel)
  - `TGpInt64ObjectList` → `TList<TPair<Int64, T>>` (OtlTaskControl timers, OtlDataManager)
  - `TGpIntegerList`/`IGpIntegerList` → `TList<Integer>` (TestOmniInterfaceDictionary)
- [x] GpLists removed from uses clause of: OtlTask, OtlTaskControl, OtlParallel, OtlEventMonitor, OtlDataManager, TestOmniInterfaceDictionary
- [x] All 61 unit tests pass
- **Note**: `GpStringHash` is still used by OtlTaskControl.pas (separate dependency, see Step 1.8)

### 1.8 Remove GpStringHash dependency
- [x] Replace `GpStringHash` usage in `OtlTaskControl.pas` with `TObjectDictionary<string, TOmniInvokeInfo>` from `System.Generics.Collections`
- [x] Replace `GpStringHash` usage in `unittests/TestOmniInterfaceDictionary.pas` (removed unused import, replaced `GetGoodHashSize` with constant)
- [x] Remove `GpStringHash` from uses clauses
- [x] All 61 unit tests pass

---

## Phase 2: Communication & Task Infrastructure

### 2.1 OtlComm.pas — Message passing
**Files**: `OtlComm.pas`

- [x] Remove hidden window allocation (`DSiAllocateHWnd` / `WndProc`)
- [x] Remove `TOmniContainerWindowsMessageObserver` usage
- [x] Use `TOmniContainerEventObserver` (IOmniEvent-based) for all queue notifications
- [x] Remove `Winapi.Messages` dependency
- [x] `TOmniMessageQueue.NewMessageEvent` returns `IOmniEvent` on all platforms
- [x] Keep `TOmniMessage` record (MsgID + TOmniValue payload) unchanged
- [ ] **Deferred to 2.3**: Unify `TOmniTransitionEvent = IOmniEvent` on ALL platforms (currently conditional `THandle`/`IOmniEvent`). This cascades through `OtlComm.pas` (`NewMessageEvent`), `OtlTask.pas` (`TOmniWaitObjectList`), and `OtlTaskControl.pas` (`DispatchCommMessage`, `TerminateWhen`, `Asy_RegisterWaitObject`). Also remove the transitional `OtlSync.SetEvent(event: TOmniTransitionEvent)` helper once the type is unified.

### 2.2 OtlCommon.pas — Core types ✅
**Files**: `OtlCommon.pas`, `OtlPlatform.pas`

- [x] `TOmniValue`: Kept as-is (wide usage, stable API)
- [x] NUMA/processor group interfaces kept (used by OtlThreadPool.pas, OtlTaskControl.pas) — replaced DSiWin32-based implementation with direct WinAPI calls
- [x] Replaced `DSiGetThreadGroupAffinity`/`DSiSetThreadGroupAffinity` with `Winapi.Windows.GetThreadGroupAffinity`/`SetThreadGroupAffinity`
- [x] Replaced all DSi* affinity functions with direct WinAPI (`GetProcessAffinityMask`, `SetProcessAffinityMask`, `SetThreadAffinityMask`, `GetLogicalProcessorInformation`)
- [x] Replaced `DSiGetProcessMemory` with `Winapi.PsAPI.GetProcessMemoryInfo`
- [x] Replaced `DSiGetProcessTimes` with `Winapi.Windows.GetProcessTimes` + inline FILETIME conversion
- [x] Replaced `DSiGetNumaHighestNodeNumber`/`DSiGetNumaProximityNodeEx` with direct WinAPI calls
- [x] Replaced `DSiGetSystemFirmwareTable` with dynamic load via `GetProcAddress`
- [x] Rewrote `LoadNUMAInfo` to use direct `GetLogicalProcessorInformationEx` with raw buffer walking (works around RTL buffer type bug)
- [x] Exported `AffinityMaskToString`/`StringToAffinityMask` from OtlPlatform.pas interface section
- [x] Keep thread affinity setting on Windows+Linux
- [x] No Variant COM-specific paths found (`varDispatch`, `varUnknown` not present) — nothing to remove

### 2.3 OtlTask.pas & OtlTaskControl.pas — Task system
**Files**: `OtlTask.pas`, `OtlTaskControl.pas`

#### 2.3.1 Task execution loop redesign
- [ ] Replace `MsgWaitForMultipleObjectsEx`-based `WaitForEvent` with CV-based `TWaitFor.WaitAny`
- [ ] **Deferred from 1.2.4**: Remove `MsgWaitForMultipleObjectsEx` usage from task loop — currently `TWaitFor.MsgWaitAny` wraps it for backward compat
- [ ] The task loop waits on: communication channel event + termination event + timer timeout + custom wait objects
- [ ] All wait objects are `IOmniEvent` (unified type)
- [ ] Remove Windows message processing from the task loop (`ProcessThreadMessages`)
- [ ] Timer dispatch remains polling-based (already platform-independent)

#### 2.3.2 Owner thread notification
- [ ] **OTL worker threads (owner is OTL task)**: Notification via condition variable wake on the owner's wait loop
- [ ] **Main/UI thread**: `TThread.Queue` for completion/message callbacks
- [ ] **Plain TThread owner**: Owner must call `IOmniTaskControl.ProcessMessages` explicitly to drain pending notifications. On Windows, if the owner thread is in an alertable wait, notifications can be delivered via QueueUserAPC as a fast path (behind `{$IFDEF OTL_HasAPC}`).
- [ ] `IOmniTaskControl.ProcessMessages`: New method — drains pending messages and executes callbacks. Returns immediately if nothing pending.
- [ ] `IOmniTaskControl.WaitForMessage(timeout_ms)`: New method — blocks until a message is available or timeout. Uses CV internally.

#### 2.3.3 Task termination
- [ ] `OnTerminated` callback: dispatched via `TThread.Queue` when owner is main thread, via CV signal when owner is OTL thread, requires explicit polling when owner is plain TThread
- [ ] `IOmniTaskControl.WaitFor`: Uses `IOmniEvent.WaitFor` (cross-platform)
- [ ] Remove `WaitForSingleObject` on thread handle

#### 2.3.4 Thread priority
- [ ] `SetThreadPriority`: Use `TThread.Priority` property (cross-platform in Delphi RTL)
- [ ] Remove direct `Winapi.Windows.SetThreadPriority` call

#### 2.3.5 COM initialization
- [ ] Add `IOmniTaskConfig.COMInitialize(apartmentModel)` option
- [ ] On Windows: calls `CoInitializeEx` in worker thread's `Initialize`, `CoUninitialize` in `Cleanup`
- [ ] On non-Windows: no-op
- [ ] Guarded by `{$IFDEF MSWINDOWS}`

#### 2.3.6 TOmniWorker message dispatch
- [ ] `message` directive pattern stays (it's a Delphi language feature, not Windows-specific)
- [ ] `Dispatch()` method works cross-platform

### 2.4 OtlThreadPool.pas — Thread pool
**Files**: `OtlThreadPool.pas`

- [ ] Replace `SuspendThread`/`ResumeThread` with CV-based idle/wake
- [ ] Worker threads wait on a condition variable when idle; signaled when work arrives
- [ ] Remove monitor thread if CV-based approach makes it unnecessary
- [ ] Keep named/separate thread pools
- [ ] Keep configurable min/max worker count and idle timeout
- [ ] Remove `WM_USER` message constants
- [ ] Remove `Winapi.Messages` dependency
- [ ] Thread priority via `TThread.Priority`

---

## Phase 3: High-Level Parallel API

### 3.1 OtlParallel.pas
**Files**: `OtlParallel.pas`

- [ ] **Keep all abstractions**: `Parallel.For`, `Parallel.ForEach`, `Parallel.Join`, `Parallel.Future`, `Parallel.Pipeline`, `Parallel.Map`, `Parallel.TimedTask`, `Parallel.Async`, `Parallel.BackgroundWorker`
- [ ] **Drop**: `Parallel.ForkJoin`
- [ ] Replace `WaitForSingleObject(FCountStopped.Handle, ...)` with `IOmniEvent.WaitFor`
- [ ] Replace `THandle` usage with `IOmniEvent`
- [ ] All `ForEach` configuration options stay (`.NumTasks`, `.NoWait`, `.OnStop`, `.Aggregate`, `.Into`, `.PreserveOrder`, etc.)
- [ ] Completion notification via CV/event (not Windows handles)

### 3.2 OtlDataManager.pas
**Files**: `OtlDataManager.pas`

- [ ] Replace `WaitForMultipleObjects` with CV-based wait
- [ ] Replace `THandle` arrays (`obsWaitHandles`) with `IOmniEvent` arrays
- [ ] Replace `SetEvent` calls with `IOmniEvent.SetEvent`

### 3.3 Future parallel patterns (deferred)
- [ ] `Parallel.Channel` (Go-style CSP)
- [ ] `Parallel.Merge`
- [ ] `Parallel.Race`
- [ ] To be designed after core NG is working

---

## Phase 4: Monitoring, Hooks & Event Bus

### 4.1 OtlEventMonitor.pas
- [ ] Already mostly platform-independent (uses `TThread.Queue`)
- [ ] Remove any remaining `DSiWin32` dependencies
- [ ] Keep main-thread-only constraint

### 4.2 OtlHooks.pas
- [ ] Already platform-independent — no changes needed

### 4.3 GpEventBus — separate cross-platform port
- [ ] GpEventBus stays as a separate project in `GpDelphiUnits`
- [ ] Port to cross-platform: replace `QueueUserAPC` with condition-variable-based dispatch for background threads
- [ ] Keep `TThread.Queue` for main thread dispatch
- [ ] If cross-platform port proves infeasible as external project, create `OtlEventBus.pas` inside OTL NG with the same API

---

## Phase 5: Cleanup & Testing

### 5.1 Remove dead code
- [ ] Remove all `{$IF Defined(MSWINDOWS) and not Defined(OTL_PlatformIndependent)}` dual paths — keep only the platform-independent path
- [ ] Remove Windows-specific observer classes
- [ ] Remove package registration files (design-time packages dropped)
- [ ] Remove support for Delphi versions < 11

### 5.2 DSiWin32 usage reduction
- [ ] DSiWin32 remains available via GpDelphiUnits submodule as Windows-specific enhancement
- [ ] All core OTL units: replace DSiWin32 calls with direct `Winapi.Windows` calls or cross-platform equivalents
- [ ] Allowed remaining DSiWin32 usage: only in platform-specific enhancement code behind `{$IFDEF MSWINDOWS}`

### 5.3 Compiler hints and warnings audit
- [ ] Build all units and test projects with hints and warnings enabled
- [ ] Review every hint and warning; fix or suppress with justification
- [ ] Goal: zero-warning build for `CompileAllUnits.dproj` and `ConsoleTestRunner.dproj` on Win32 and Win64
- [ ] Known pre-existing warnings to investigate:
  - `W1035: Return value of function 'Locked<T>.Initialize' might be undefined` (OtlSync.pas)
  - `H2443: Inline function not expanded because unit not in USES list` (OtlSync.pas, OtlContainers.pas)
  - `W1036: Variable might not have been initialized` (OtlTaskControl.pas)
  - `H2077: Value assigned never used` / `H2164: Variable declared but never used` (OtlParallel.pas, OtlSync.pas)

### 5.4 Test migration: DUnit → DUnitX
- [ ] Port all test modules to DUnitX framework
- [ ] Test modules to port:
  - `SmokeTest.pas`, `TestTask.pas`, `TestOtlSync1.pas`, `TestOtlComm.pas`
  - `TestBlockingCollection1.pas`, `TestOtlParallel.pas`, `TestContainers.pas`
  - `TestOtlDataManager1.pas`, `TestOmniValue.pas`, `TestRegressions.pas`
  - `StressTest*.pas`
- [ ] Keep `CompileAllUnits.dpr` for compilation verification
- [ ] Update `buildandrun.bat` for DUnitX runner

### 5.5 CI pipeline
- [ ] GitHub Actions: Windows (Win32 + Win64) build and test
- [ ] GitHub Actions: Linux64 build (when Delphi Linux compiler available in CI)
- [ ] Claude Code automated PR review

### 5.6 Migration guide
- [ ] Document all API changes from OTL v3 to OTL NG
- [ ] Document removed features (ForkJoin, NUMA, design-time packages)
- [ ] Document new features (`ProcessMessages`, `WaitForMessage`, COM initialization option)
- [ ] Document behavioral changes (condition variable waits vs Windows handles, polling requirement for plain TThread owners)
- [ ] Provide code examples showing before/after for common patterns
- [ ] File: `MIGRATION.md` in repo root

---

## Key Design Decisions Summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Inline assembly | Remove entirely | ARM Windows support; TInterlocked is sufficient |
| Lock-free containers | Stay lock-free (with fallback on non-x86) | Core performance feature |
| WaitForMultipleObjects | Condition variables everywhere | Only cross-platform option |
| Container observers | IOmniEvent only (drop PostMessage) | Single code path |
| TOmniTransitionEvent | Always IOmniEvent | Unify all platforms |
| Non-OTL thread notification | Explicit polling + APC fast path on Windows | Pragmatic trade-off |
| TOmniValue | Keep as-is | Too much code depends on it |
| DSiWin32 | Optional Windows enhancement, not core dependency | Keep submodule but minimize usage |
| GpLists | Remove, replace with generics | Reduce external dependencies |
| NUMA | Drop | Not cross-platform, rarely used |
| Thread affinity | Windows + Linux only | macOS/iOS/Android don't support it |
| Test framework | DUnitX | Cross-platform testing |
| Design-time packages | Drop | Simplify build/deployment |
| Parallel.ForkJoin | Drop | Unused |
| COM initialization | Optional Windows-only task config | Needed for COM automation scenarios |
| GpEventBus | Separate cross-platform port | Usable outside OTL |
| Cancellation token | Keep IOmniCancellationToken | Already partially cross-platform |

---

## Implementation Order

```
Phase 0: Repository bootstrap (prerequisite for all other work)
  0.1 Sync master -> 0.2 Cherry-pick -> 0.3 New repo -> 0.4 CI -> 0.5 Submodules

Phase 1: Foundation (bottom-up, each step must compile+test before next)
  1.1 OtlOptions.inc
  1.2 OtlSync.pas (hardest — do first)
  1.3 OtlContainers.pas (depends on 1.2)
  1.4 OtlCollections.pas (depends on 1.3)
  1.5 OtlContainerObserver.pas
  1.6 OtlPlatform.pas
  1.7 Remove GpLists

Phase 2: Communication (depends on Phase 1)
  2.1 OtlComm.pas
  2.2 OtlCommon.pas
  2.3 OtlTask.pas + OtlTaskControl.pas (largest unit, most complex)
  2.4 OtlThreadPool.pas

Phase 3: High-level API (depends on Phase 2)
  3.1 OtlParallel.pas
  3.2 OtlDataManager.pas

Phase 4: Monitoring & event bus
  4.1 OtlEventMonitor.pas
  4.2 OtlHooks.pas (no-op)
  4.3 GpEventBus cross-platform (separate project)

Phase 5: Cleanup & testing (ongoing, but final push here)
  5.1 Dead code removal
  5.2 DSiWin32 reduction
  5.3 Compiler hints and warnings audit
  5.4 DUnitX migration
  5.5 CI pipeline
  5.6 Migration guide
```

---

## Verification Plan

### Per-phase verification
- After each phase: all existing unit tests must pass on Windows (Win32 + Win64)
- After Phase 1: `OTL_PlatformIndependent` flag set on Windows must compile and pass all sync/container tests
- After Phase 2: full task lifecycle tests pass (create task, send message, receive response, terminate)
- After Phase 3: all `Parallel.*` tests pass
- After Phase 5: full test suite passes on Windows; Linux compilation succeeds

### End-to-end verification
- Run `CompileAllUnits.dpr` on Windows Win32, Win64
- Run full DUnitX test suite on Windows
- Compile on Linux64 (no assembly, no Windows units)
- Run numbered demo tests that don't require VCL UI (`tests/00_Beep` through applicable tests)
- Verify `Parallel.ForEach`, `Parallel.Future`, `Parallel.Pipeline` work correctly
- Stress tests pass without deadlocks or race conditions

### Platform matrix (initial)
| Platform | Build | Test | Status |
|----------|-------|------|--------|
| Windows Win32 | CI | CI | Primary |
| Windows Win64 | CI | CI | Primary |
| Linux64 | CI | CI | Secondary |
| macOS ARM64 | Manual | Manual | Deferred |
| iOS/Android | Manual | Manual | Deferred |
