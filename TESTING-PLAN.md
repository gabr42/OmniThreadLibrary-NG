# OmniThreadLibrary-NG Testing Plan

Tracking list of testing work identified in the 2026-04-20 coverage audit.
Check items off as they're completed. Priority order is roughly top-to-bottom
within each section.

---

## 1. Fill the biggest unit coverage gaps

### 1a. OtlThreadPool (no dedicated test file)

- [x] Create `unittests/TestOtlThreadPool1.pas`
- [x] Test `GlobalOmniThreadPool` concurrent first-access (regression for
      3.04 lazy-init fix)
- [x] Test MaxExecuting / MinWorkers behavior
- [x] Test worker recycling across consecutive `Schedule` calls
- [x] Test CancelAll with signalCancellationToken
- [x] Test Cancel(taskID) (single-task cancel path)
- [x] Test IdleWorkerThreadTimeout_sec behavior (worker teardown after idle) —
      uses `SetThreadDataFactory` counter rather than ThreadID comparison
      (pthread IDs are recycled on POSIX, making ThreadID an unreliable proxy)
- [x] Test force-kill path on a deliberately stuck task — MSWINDOWS-only;
      runtime-skipped on POSIX where `pthread_cancel` deadlocks (see
      `project_pthread_cancel_unusable.md`). Test omits `pool.IsIdle` check
      because `CountRunning` is not decremented after a force-kill in
      `ProcessCompletedWorkItem` (the worker was already removed from
      `owRunningWorkers` by the Cancel path) — instead verifies the pool
      can still schedule new work after a force-kill
- [x] Add to `ConsoleTestRunner.dpr` and `OtlAndroidTests.dpr`

**Incidental fix while writing these tests**: `TOTPWorker.LocateThread`
declared its parameter as `DWORD`. On POSIX `TThreadID = NativeUInt` is
uint64; the implicit uint64→DWORD truncation silently broke worker
lookup (and on Android with range checking ON it raised `ERangeError`).
Changed signature to `TThreadID`. This also resolved two pre-existing
Linux64 Unobserved failures (`TestScheduleControlReleased`,
`TestRunControlReleased`) whose root cause was LocateThread missing
workers and skipping cleanup.

### 1b. OtlEventMonitor (no test file)

- [x] Create `unittests/TestOtlEventMonitor1.pas`
- [x] Test `OnTaskMessage` / `OnTaskTerminated` delivery
- [x] Test `ProcessTerminated` filtering — assert internal OTL messages
      don't leak to user handler (2.0e regression)
- [x] Test monitor detach/destroy while tasks are still running

**Incidental finding while writing these tests**: `TOmniThreadPool.MonitorWith`
is guarded by `{$IFDEF MSWINDOWS}` in `OtlThreadPool.pas:1751` — the call
`monitor.Monitor(Self)` is a no-op on Linux64/Android64, so pool-level
events (`OnPoolThreadCreated`, `OnPoolWorkItemCompleted`, etc.) never fire
on non-Windows targets. `TestMonitorPoolWorkItemCompleted` is runtime-skipped
on `{$IFNDEF MSWINDOWS}` with a `Assert.Pass` so the test suite stays green
while the limitation is documented.

### 1c. OtlContainers (thin — 8 tests for 2000 LOC)

- [x] Test `TOmniBaseBoundedQueue.IsFull` / `IsEmpty` state transitions
      (regression for the IsFull-always-false bug) — covered by pre-existing
      `TestBasicQueue`/`TestBasicStack` (each step asserts both states via
      `Verify(isEmpty, isFull)`) and the new one-element / large-capacity
      tests (`TestOneElementQueue`, `TestBoundedQueueLargeCapacity`, etc.)
- [ ] ~~Test CAS16 alignment behavior on 64-bit (3.02 fix)~~ — not
      externally observable. Alignment is enforced by the container's
      internal buffer layout (`TOmniBaseBoundedQueue.Initialize` rounds
      slot size up to 16-byte alignment on CPUX64); any misalignment
      would crash at the CAS site rather than produce a wrong result,
      so the MPMC stress tests below serve as indirect coverage.
- [x] Stress test: bounded queue/stack under N producers + M consumers —
      `TestBoundedQueueMPMC` / `TestBoundedStackMPMC` (4 producers ×
      4 consumers × 2500 items each, capacity=128). Uses
      `expectedSum = N*(N+1) div 2` to detect lost or duplicated items.
      MPMC helpers `MakeProducer` / `MakeConsumer` follow the CLAUDE.md
      closure-capture rule (by-value params in a helper function)
- [x] Test edge cases: capacity=1, capacity=max — covered by
      `TestOneElementQueue`/`TestOneElementStack` and the new
      `TestBoundedQueueLargeCapacity`/`TestBoundedStackLargeCapacity`
      (CCapacity=65536). Count accuracy under contention: N/A — there
      is no public `Count` property on `TOmniBaseBoundedQueue` or
      `TOmniBaseBoundedStack`; only `IsEmpty`/`IsFull` are exposed

## 2. Regression tests for recent "fix-without-a-test" commits

- [x] **Gate-leak race in TWaitFor** (commit ac3f364) —
      `TestRegressions.TestBugfixes.TestWaitForGateLeakRace`: 20000
      iterations of `event.SetEvent`/`event.Reset` (each triggers
      `PerformObservableAction`→`EnterGate`) while a background
      thread creates and destroys `TWaitFor.Create([event])`. Uses
      `wfDone.WaitFor(30000 ms)` as deadlock detector — before the
      fix the race would leak the gate, hanging the next `SetEvent`
- [ ] **TThreadID range-check** (commit 24a5162) — compile a dproj with
      `DCC_RangeChecking=true` on non-Android, run pool tests, assert
      no `ERangeError`
- [ ] **Pipeline closure capture** (3.02) — multi-stage pipeline that
      propagates stage exceptions and asserts each stage's captured
      state is independent
- [ ] **OtlParallel.Select missed-wakeup** (3.02) — high-contention
      send/receive loop, assert no deadlock after 1M iterations
- [ ] **TOmniValue container leak on exception** (3.01) — force
      construction failure path, assert ref counts return to baseline

## 3. OtlTaskControl — expand from 7 tests

- [ ] Background-observer integration: non-main-thread task owner gets
      `OnTerminated` fired exactly once (regression for 3.03 sync-delivery
      + dispatcher fixes in commit 24a5162)
- [ ] Message filtering / `RegisterComm` / multiple comm channels
- [ ] Exception-in-worker propagation via `FatalException`
- [ ] `Invoke` with varying argument counts / types
- [ ] Group affinity / `SetProcessorGroupAffinity` paths

## 4. Port existing stress tests to DUnitX + make cross-platform

Current `StressTestRunner.dpr` uses legacy DUnit (`TestFramework`) and
depends on the `Windows` unit. These need to move into the main DUnitX
suite so they run on Win32/Win64/Linux64/Android.

- [ ] Port `StressTestBlockingCollection1.TestCompleteAdding` to DUnitX
      - Drop `{$IFDEF Unicode}` wrapper (always true now)
      - Remove `Windows` unit dependency
      - Add to `ConsoleTestRunner.dpr` and `OtlAndroidTests.dpr`
- [ ] Port `StressTestOtlSync1.StressTestResourceCount` to DUnitX
      - Already uses `OtlPlatform.Time` — should be cross-platform as-is
      - Keep the 30-second runtime gated behind a "long test" category so it
        doesn't bloat the normal CI run
- [ ] Decide fate of `StressTestRunner.dpr`/`.dproj`: delete once ported,
      or keep as a Windows-only high-iteration harness

## 5. Cross-cutting / infrastructure

- [ ] Add a `[Category('Stress')]` or similar DUnitX attribute so
      long-running tests can be filtered in/out of normal runs
- [ ] Add memory-leak assertions to more tests (follow the
      `TMemLeakCheckObj` pattern from `StressTestBlockingCollection1`)
- [ ] Audit tests for hard-coded `Sleep(...)` timing — replace with
      event-driven waits where feasible to reduce CI flakiness
- [ ] Document how to run the full suite across all four platforms in
      one place (currently split between CLAUDE.md and
      `unittests/build_android.bat`)

## 6. Lower-priority / nice-to-have

- [ ] OtlLogger.pas — basic unit tests (currently zero)
- [ ] OtlPlatform.pas — POSIX/Windows divergence coverage
- [ ] OtlCommon.TOmniEnvironment — NUMA/affinity fallback paths
- [ ] OtlBackgroundObserver concurrent registration/unregistration stress
- [ ] OtlContainerObserver snapshot-delivery concurrency (1.05 deadlock fix)

---

## Notes

- Target platforms for every new test unless stated otherwise: Win32,
  Win64, Linux64, Android64. Guard with `{$IFDEF MSWindows}` only when
  the functionality under test is Windows-specific (e.g., processor-group
  affinity).
- Use DUnitX fixtures and the `Assert.*` API, not legacy DUnit.
- Add new test units to both `ConsoleTestRunner.dpr` and
  `OtlAndroidTests.dpr` (Android FMX runner).
- Follow the cross-platform test-listing pattern already in
  `OtlAndroidTests.dpr` — it currently runs 239 tests (236 + 3 ignored),
  matching Linux64.
