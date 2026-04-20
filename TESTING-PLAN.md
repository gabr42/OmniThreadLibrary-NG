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
- [x] **TThreadID range-check** (commit 24a5162) — covered by two
      complementary tests:
      - `TestRegressions.TestBugfixes.TestTOmniValueUInt64HighBitRoundTrip`
        asserts that `TOmniValue.AsUInt64` bit-preserves a high-bit
        uint64 value. The test body is compiled under local `{$R+}` so
        any future regression that reintroduces a range-checked
        conversion on the read path would fail here, cross-platform.
      - `OtlAndroidTests.dproj` sets `DCC_RangeChecking=true` on the
        entire library build, so every pool-using test (TestOtlThreadPool1,
        TestOtlParallel, TestBackgroundObserver1, TestUnobserved, etc.)
        is an end-to-end regression of the actual buggy code path on
        ARM64. Android64 currently at 268 passed + 3 ignored
- [x] **Pipeline closure capture** (3.02, commit 579be5f) —
      `TestRegressions.TestBugfixes.TestPipelineClosureCapturePerStage`.
      Two-stage pipeline where stage 1 raises on a specific input.
      Pre-fix, the worker's except-block captured the function-scope
      `outQueue` by reference, which the stage loop reassigned every
      iteration — so exceptions were routed to opOutput (the last
      assigned value), bypassing all intermediate stages. The fix
      passes the per-stage outQueue via `Task.Param['OutQueue']`.
      Test uses `TPipelineStageDelegate` (not simple-stage, whose
      internal try/except would mask the bug) and decorates stage 2
      with `HandleExceptions` so stage 2 sees exceptions as
      `TOmniValue` with `IsException=true`. Asserts: (a) no raw
      Exception reaches opOutput, (b) stage 2 observes exactly one
      exception marker, (c) non-exception values transform through
      both stages
- [x] **OtlParallel.Select missed-wakeup** (commit c5ccd38) — already
      regression-covered by `TestSelect1.TestParallelSelect.TestSelectNoMissedWakeup`.
      Runs 200 iterations of producer-sends-immediately-after-select-waits
      with a 500 ms timeout. The bug left a window between Select's
      poll and its condvar wait where a signal could be lost; the fix
      replaced the condvar with an auto-reset event. Scaled back from
      the originally-planned 1M iterations because a single miss already
      fails the assertion (`even one miss indicates a wakeup bug`) and
      higher counts would unnecessarily stretch CI. Runs on Win32,
      Win64, Linux64, Android64
- [x] **TOmniValue container leak on exception** (3.01, commit 3210d64) —
      `TestRegressions.TestBugfixes.TestOmniValueCreateLeakOnInvalidType`:
      passes `TObject` (a TClass reference, vtClass=8) in the
      `array of const` to `TOmniValue.Create`. vtClass is not handled
      in the case statement, so the else-branch raises
      `'invalid data type'`. Pre-fix, the half-populated
      `TOmniValueContainer` leaked; fix wraps the loop in try/except
      and frees it on raise. Relies on DUnitX per-run leak tracking
      (FastMM4 reports `Tests Leaked: 0` end-of-run) — a regression
      would surface as one leaked container

## 3. OtlTaskControl — expand from 7 tests

- [x] Background-observer integration: non-main-thread task owner gets
      `OnTerminated` fired exactly once (regression for 3.03 sync-delivery
      + dispatcher fixes in commit 24a5162) —
      `TestRegressions.TestBugfixes.TestBgObserverOnTerminatedFromBgThread`:
      100 iterations inside a `TThread.CreateAnonymousThread` owner,
      each creating an `Unobserved` task with `OnTerminated`. Owner
      calls `DrainBackgroundObservers` in a bounded poll loop until all
      fire (30 s budget). Asserts `fireCount = 100`. Covers the two
      paired fixes: (a) synchronous `ForwardTaskTerminated` from worker
      thread when a bg observer is active (prevents drop when the
      Unobserved cleanup thread frees the control before the owner
      drains), and (b) `TOmniTaskControlDispatcher` lock-serialized
      proxy so the drained closure can never touch a freed control.
      On Win32/Win64/Linux64 the DUnitX runner executes on the main
      thread, so this is the only non-main-thread-owner coverage; on
      Android64 the whole suite already runs on a worker thread
- [x] Message filtering / `RegisterComm` / multiple comm channels —
      three tests added to `TestTask.TestITaskControl` covering the
      task-level comm-registration path (previously exercised only
      indirectly via `TThreadPool.Comm`):
      `TestRegisterCommDispatchesMessages` (10 messages on a registered
      external channel dispatch to the `message MSG_EXT_A` handler),
      `TestUnregisterCommStopsDispatch` (dispatch one, Invoke
      `UnregisterChannelA`, send two more → count stays at 1),
      `TestMultipleAdditionalComms` (two extra channels, independent
      counters; 4+3 messages). Worker is a `TSynchronizedOmniWorker`
      subclass that calls `Task.RegisterComm` / `Task.UnregisterComm`
      from `Initialize` and an `Invoke`-callable method. Counter
      updates use `TInterlocked`; poll helper `WaitForCountAtLeast`
      avoids CheckSynchronize dependence
- [x] Exception-in-worker propagation via `FatalException` — four
      tests in `TestTask.TestITaskControl`:
      `TestFatalExceptionFromAnonymousTask` (etProcedure raises →
      `task.FatalException` exposes the same class + message),
      `TestFatalExceptionFromWorker` (etWorker message handler raises
      → exception propagates out of DispatchMessages, caught by
      `TOmniTask.Execute`),
      `TestDetachExceptionTransfersOwnership` (DetachException returns
      the Exception and nils the executor's store; caller frees it;
      FatalException is nil afterwards — relies on FastMM4 per-run
      leak tracking), and
      `TestNoExceptionMeansNilFatalException` (normal termination
      leaves FatalException nil). Uses a local `EWorkerTestException`
      class so assertion can match on exact type.
      Note: TRaisingWorker needs an explicit `constructor Create`
      (delegating to `inherited`) — calling
      `TRaisingWorker.Create` directly on a TOmniWorker subclass
      with no declared constructor triggers `E2250` on the
      `CreateTask(const worker: IOmniWorker; ...)` overload
- [x] `Invoke` with varying argument counts / types —
      `TestTask.TestITaskControl` now covers the four Invoke overloads
      that existing `TestInvoke` missed:
      `TestInvokeByPointerOverloads` (method-pointer dispatch — three
      variants: no args, TOmniValue, array-of-const; these go through
      `TOmniInternalAddressMsg` and resolve the name via
      `Implementor.MethodName(method)` at `OtlTaskControl.pas:2402`),
      `TestInvokeArrayOfConstPacking` (multi-item array-of-const packs
      into an array `TOmniValue` the worker can index),
      `TestInvokeRemoteFunc` (anonymous procedure — dispatched via
      `TOmniInternalFuncMsg`, line 2138-2139), and
      `TestInvokeRemoteFuncEx` (anonymous procedure receiving
      `IOmniTask` — line 2140-2141 calls
      `funcEx(WorkerIntf.Task)`, test asserts the captured
      `UniqueID` matches the task control). New test worker
      `TInvokePointerWorker` uses a 3-bit flag register and a single
      Synchronizer signal so the entire by-pointer sequence races to
      completion. Note: a single-char literal like `'x'` must be
      cast to `string` inside an `array of const` — otherwise it
      types as `vtWideChar`, which `TOmniValue.Create(array of const)`
      at `OtlCommon.pas:1941` rejects with "invalid data type".
- [x] Group affinity / `SetProcessorGroupAffinity` paths —
      `TestTask.TestITaskControl` now covers the four branches of
      the fluent `ProcessorGroup(n)` and `NUMANode(n)` builders:
      `TestProcessorGroupValidIsAccepted` and
      `TestNUMANodeValidIsAccepted` run a task with group/node 0
      (always present: real on Windows, faked via
      `TOmniEnvironment.CreateFakeNUMAInfo` at
      `OtlCommon.pas:3963-3973` on Linux64/Android64), and
      `TestProcessorGroupInvalidRaises` /
      `TestNUMANodeInvalidRaises` assert that
      `VerifyProcessorGroup` and `VerifyNUMANode` raise
      synchronously for negative / out-of-range values — no task
      startup needed. The `SetThreadGroupAffinity` /
      `SetThreadAffinityMask` Windows APIs in `SetProcessorGroup`
      and `SetNUMANode` are reached only on Windows (guarded by
      `{$IFDEF MSWindows}` at `OtlTaskControl.pas:2645-2650`), but
      the overall cross-platform invariant — valid values accepted,
      invalid values rejected — holds on all targets.

## 4. Port existing stress tests to DUnitX + make cross-platform

Current `StressTestRunner.dpr` uses legacy DUnit (`TestFramework`) and
depends on the `Windows` unit. These need to move into the main DUnitX
suite so they run on Win32/Win64/Linux64/Android.

- [x] Port `StressTestBlockingCollection1.TestCompleteAdding` to DUnitX
      - Ported as `TestStressBlockingCollection1.pas` →
        `TStressIOmniBlockingCollection.StressTestCompleteAdding`.
      - Marked `[Category('Stress')]` (fixture + method) and registered in
        both `ConsoleTestRunner.dpr` and `OtlAndroidTests.dpr`.
      - Uses OTL's own `Parallel.Join([...]).Execute` (same as legacy, not
        `System.Threading.TParallel.Join`), 1000 iterations, breaks early
        on first lastAdded/lastRead mismatch.
      - Verified Win32/Win64 292+1, Linux64 286+1, Android64 287+1,
        ARM64EC compile ✓. Runtime on Win32 ~20 s.
- [x] Port `StressTestOtlSync1.StressTestResourceCount` to DUnitX
      - Ported as `TestStressOtlSync1.pas` →
        `TStressOtlSync.StressTestResourceCount` (3×3 allocate/release
        combinations × 30 s per combination ≈ 4–5 min total).
      - Marked `[Category('Stress')]` (fixture + method) and registered in
        both `ConsoleTestRunner.dpr` and `OtlAndroidTests.dpr`.
      - All timing variables renamed with `_ms` suffix (`startTime_ms`,
        `wait_ms`) per project convention; the legacy
        `CheckTrue(task.WaitFor(...), ...)` calls replaced with
        `Assert.IsTrue(...)` + a `Format` message that names the fixture,
        the ResourceAllocate/Release index, and the `iAlloc/iRelease`
        combination so a hang is immediately diagnosable.
      - Verified Win32 (4m21s passing) / Win64 / Linux64 (WSL manual link)
        runtime passing; ARM64EC compile ✓; Android64 run confirmed the
        stress test is *excluded* from the auto-run (TestCount=289
        Passed=286 Ignored=3).
      - Android-side fix required for this task: the FMX `MobileGUI`
        runner at `DUNitX.Loggers.MobileGUI.pas:144` calls
        `TDUnitX.CreateRunner` but never `CheckCommandLine`, so
        `TDUnitX.Filter` stays nil and category filtering is skipped at
        `DUnitX.TestRunner.pas:538-539`. `OtlAndroidTests.dpr` now
        builds the filter manually via
        `TDUnitX.Filter := TDUnitXFilterBuilder.BuildFilter(TDUnitX.Options)`
        after setting `Options.Exclude := 'Stress'`.
- [ ] Decide fate of `StressTestRunner.dpr`/`.dproj`: delete once ported,
      or keep as a Windows-only high-iteration harness

## 5. Cross-cutting / infrastructure

- [x] Add a `[Category('Stress')]` or similar DUnitX attribute so
      long-running tests can be filtered in/out of normal runs
      - `ConsoleTestRunner.dpr` now sets `TDUnitX.Options.Exclude := 'Stress'`
        by default unless the caller passed `--run/--runlist/--include/--exclude`
        (DUnitX's `--` switches are not detected by `FindCmdLineSwitch`, so a
        local helper `HasAnyDUnitXFilterSwitch` does the scan).
      - `OtlAndroidTests.dpr` sets the exclusion unconditionally (no CLI on
        Android).
      - To run stress tests on demand: `ConsoleTestRunner.exe --include:Stress`.
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
