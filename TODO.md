# OTL-NG Open Items

Tracking list for work identified during pre-alpha prep. Not GitHub issues (repo
has none as of 2026-04-24). Priority hints reflect pre-alpha readiness: items
that affect real-app correctness or visible test reliability come first;
architectural cleanups and design questions are deferred.

Delete an entry when it's done; promote to a GitHub issue if it needs broader
discussion or external input.

---

## Pre-alpha priority

### 1. Fix WSL manual-link TLS layout (4 GiB-per-thread mmap on bench_33)

The deadlock that originally manifested as a "silent exit" on multi-worker
configs was the missed-wake race in `TSynchroClient.AfterSignal` (fixed
2026-04-25; see `OtlSync.pas` history `3.04`). The bench now runs cleanly
through 1→1 and 2→2 but is OOM-killed (`EXIT=9`) somewhere during 3→3 or
later. Diagnosed: each thread's `Sysinit::AllocTlsBuffer` mmaps ~4 GiB
because `GetTlsSize` returns `@TlsLast - @TlsStart`, and our WSL-link
binary has the symbols laid out backwards (`TlsLast` 8 bytes *before*
`TlsStart`), so the size becomes -8 → 4 294 967 288 as `Cardinal`. With
~6 worker threads × 4 GiB each, RSS hits 24 GiB and the OOM killer fires.

`unittests/Linux64/Debug/ConsoleTestRunner` is laid out correctly
(`TlsStart` low, `TlsLast` high, ~2.5 KiB region) — only the
bench's link is broken. Real users on Delphi-bundled Linux deployment
won't hit this; it's specific to the WSL manual-link harness in
`C:\tmp_otl_link\linkit_bench_33.sh` (and `linkit.sh`).

Likely fix: a small linker script (or `--defsym`) that anchors
`_ZN7Sysinit8TlsStartE` and `_ZN7Sysinit7TlsLastE` to the start and end
of the threadvar region. Rough sketch:

```ld
SECTIONS {
  .data : {
    PROVIDE(_ZN7Sysinit8TlsStartE = .);
    *(.data.threadvar .data.threadvar.*)
    PROVIDE(_ZN7Sysinit7TlsLastE = .);
  } > /* default */
}
```

The exact section name depends on what the Delphi `dcclinux64` `.o`
files actually use for threadvars — `nm`/`objdump` on `System.o` and
`SysInit.o` will reveal it. Verify with
`nm bench_33_console | grep -E "TlsStart|TlsLast"` (TlsStart should be
at lower address than TlsLast) and a fresh RSS sample
(`/c/tmp_otl_link/bench33_early_rss.sh`).

Not a runtime/library bug — this entry tracks build-harness work only.

### 2. Resume POSIX `TWaitFor` persistent-observer optimization

Linux `TWaitFor.Wait` is ~2× slower than Win64 on `bench_pingpong` (~345 ms/rep
vs ~181 ms/rep) because per-wait `AddObserver` / `RemoveObserver` costs
~440 µs/wait. Three prior attempts at persistent observer attachment all hung
Linux in the same pathology: stuck `FState=true` on `oteCommRebuildHandles`
(idx=1) and `Task.Comm.NewMessageEvent` (idx=2) that never get consumed. Static
analysis of every `SetEvent` call site didn't pin the mystery signaller.

Concrete next action: attach gdb under WSL —

```bash
MSYS_NO_PATHCONV=1 wsl -- gdb /mnt/c/tmp_otl_link/Linux64/Debug/bench_pingpong
```

— breakpoint `TOmniEvent.SetEvent` filtered to the two offending instances, and
identify what is re-signalling them during `MSG_START_TEST` dispatch.

Context: `memory/project_posix_persistent_observer_attempt.md` (full retry
history, including current-state-of-revert pointers).

### 3. Add memory barriers to the lock-free queue protocol for ARM64

`OtlContainers.pas`'s lock-free protocol (`PopLink` / `PushLink` /
`InsertLink` / `RemoveLink` and the tagged-pointer CAS sites) does
multiple separate reads of `Reference` and `PData` between CAS
operations. On x86/x86_64 (TSO) those reads see writes from other
threads in a globally consistent order without explicit barriers, so
the protocol is correct as-written. On ARM64 (Linux64-ARM64,
Android64-ARM64, macOS-ARM64) the weaker memory model breaks the
implicit ordering — under high consumer-side contention readers can
observe stale `PData` after seeing the matching `Reference`, and the
retry loop can fail to make progress.

Repro (committed `ef39b94`, 2026-04-25): `bench_33` 1→7 on Android64
(Samsung SM-G930F, Cortex-A57/A53). Configs 1→1 through 8→8 finish;
1→7 hits the bench's 5-minute `WaitFor` timeout with "Reader 0 did
not finish". Linux64 x86_64 runs 1→7 cleanly (8 s) — same code, no
weak-memory-order issue. Reverting `ef39b94` would also fix Android
but loses the ~2× POSIX-x86_64 speedup measured.

What needs to happen:

1. Audit every multi-step CAS retry loop in `OtlContainers.pas` and
   identify pairs of reads / writes that need explicit ordering.
2. Use acquire-load / release-store or insert `MFence`-equivalent
   barriers (Delphi exposes `MemoryBarrier` / `TInterlocked.MemoryBarrier`
   — emits no-op on x86 TSO, `DMB ISH` on ARM64).
3. Re-run `bench_33` 1→7 on Android64 to verify the hang is gone, and
   on Linux64 x86_64 to confirm no measurable perf regression.

References for the protocol's invariants:

- `TOmniBaseBoundedStack.PopLink` / `PushLink`: the `Reference` /
  `PData` pair on the chain head/tail.
- `TOmniBaseBoundedQueue.InsertLink` / `RemoveLink`: same shape on
  ring-buffer cells.
- `TOmniBaseQueue.Enqueue` / `Dequeue` (head/tail tagged pointers):
  state-machine transitions on `(Slot, Tag)` pair.

This entry replaces the older "spinlock fallback" item — that's
resolved as of `b91711a` (use `AtomicCmpExchange128` everywhere).
Now the next layer of correctness on weak-memory-order targets.

### 4. Profile Linux64 ~2.5× speedup vs Win64 on `bench_33` balanced configs

`bench_33` 2026-04-25 baseline (`tests/33_BlockingCollection/BENCH_README.md`):

Config | Win64 (ms) | Linux64 (ms) | ratio
---|---|---|---
1→1 | 1239 | 401 | 3.1×
2→2 |  784 | 432 | 1.8×
3→3 |  983 | 424 | 2.3×
4→4 | 1055 | 465 | 2.3×
8→8 | 1521 | 695 | 2.2×

Both numbers are Release-mode builds. Initial hypotheses ruled out:

- **FastMM4-debug overhead.** Win32/Win64 Release without `-DDEBUG`
  give the same numbers as the 2026-04-24 baseline.
- **Lock-free CAS vs POSIX spinlock fallback.** Win32 rebuilt with
  `OTL_HaveCmpx16b` undefined (forcing the same spinlock fallback
  Linux uses on `OtlContainers`) only added 0–30% overhead vs the
  CMPXCHG16B path — Win32 1→1 went from 1039 ms to 1167 ms, 8→8
  from 1124 ms to 1455 ms. Linux64 still beats Win32-with-spinlock
  by ~2.5–3× on those same configs (401 vs 1167; 695 vs 1455). So
  the gap is in the surrounding code (sync primitives, scheduler,
  codegen), not in the queue's contention strategy.

The gap is real, large, and consistent across configs. Worth
understanding before shipping pre-alpha because it implies Win64 has
avoidable overhead in the balanced-pipeline hot path.

Likely contributors to investigate, in order:

1. **Synchronization primitives.** Linux uses pthread futex (cheap
   uncontended fast path, syscall only on contention). Windows
   `TConditionVariableCS.WaitFor` goes through `TMonitor.Wait` →
   per-thread semaphore (`MonitorSupport.NewWaitObject`) — a syscall
   per wait even when uncontended. With many short waits (the
   bench's hot path is `TryDequeue` failure → `WaitAny` → wake →
   retry), the syscall-per-wait cost stacks up.
2. **Cond var design.** On Windows, `TConditionVariableCS.Release`
   eventually calls `WakeConditionVariableProc` (NT cv) but
   `TMonitor.Pulse` uses semaphores. Bench may be hitting the
   non-NT-cv path. Worth verifying with a profiler.
3. **Compiler codegen.** Both `dcc64` and `dcclinux64` are LLVM-
   based, but with different backends and inlining heuristics.
   `OtlCollections.TryAdd` / `TryTake` are the inner-loop functions
   — disassembling both for `4→4` would expose any obvious gap.
4. **Memory allocator.** Mostly ruled out at the Delphi-MM level
   (FastMM4-debug-off didn't move Windows numbers). But glibc
   `malloc` vs Windows heap could still differ on the queue-block
   path. Lower priority than (1) and (2).

Note that `1→7` flips direction (Linux is *slower*: 10.7 s vs Win64
7.9 s). That config's bottleneck is `AddObserver` / `RemoveObserver`
churn under POSIX — a separate problem already tracked in item #2
above. The two findings are likely independent.

Concrete next action: build both targets with `-O3 -fno-omit-frame-
pointer` (Linux) / `--profile` (Windows), capture flame graphs of a
4→4 run, compare time spent in `WaitAny` / `TryDequeue` /
`AddObserver`. Bench source unchanged — same `.dpr` runs both
platforms.

---

## Post pre-alpha

### 3. Make OTL tasks implicitly owned (eliminate `Unobserved`)

`OtlTaskControl.pas:170` author TODO: *"The whole Unobserved mess should go
away - task should be implicitly owned ALWAYS"*.

Current model requires callers to chain `.Unobserved` when they don't hold the
task reference. Most `CreateTask(...).Run` users forget, which is how commits
`c3d531d` and `24a5162` originated. Architectural change — defer until
post-pre-alpha, but capture the invariant so related bugs don't get papered
over in the meantime.

Design sketch: every task acquires an internal self-reference at `Run`, drops
it at termination; no external reference needed to keep it alive; `.Unobserved`
becomes a no-op alias. Risk: the lifetime contract changes for every caller,
needs a careful migration with a compatibility mode.

### 4. Triage `OtlParallel` design-question TODOs

12 author TODOs on lines 381-392 and 1682:

- Replace `OnStop` with `TaskConfig.OnTerminate` whenever appropriate.
- `IOmniParallelLoop.Initialize` should return a normal interface (drop
  `InitializedLoop`).
- `IOmniParallelLoop.Execute` should return `self`.
- Remove `IOmniParallelLoop.OnMessage`.
- `IOmniFuture<T>.IsExceptional`.
- `TryFatalException` with timeout.
- Change `.Aggregate` to use `.Into` signature for loop body.
- Consider `.Aggregate<T>` where T is the aggregate type.
- Combining `Futures` with `NoWait` version of `Aggregate`.
- Single-threaded access to a data source (datasets etc.).
- `Parallel.MapReduce`?
- Stage output ordering when pipeline stages run in parallel (line 1682).

This task is the triage pass — for each, decide (a) keep as future idea, (b)
close because superseded, (c) promote to its own entry here. Not the
implementation.

### 5. Recheck legacy NEXTGEN / MSWINDOWS IFDEFs in `OtlCommon.pas`

Lines 1823, 1827, 1847, 1851 have TODOs marked *"\*\*\* Recheck IFDEFs"*.
These guard `TOmniValue` variant-array handling paths. `NEXTGEN` (the old
ARC-based mobile compiler) is gone in Delphi 11+; anything gated by `{$IFNDEF
NEXTGEN}` now always compiles and should be revisited. Also audit the
adjacent `{$IFDEF MSWINDOWS}` guards — per
`memory/project_linux_port_status.md`, several MSWINDOWS guards around pure
language features turned out to be ancient leftovers that silently broke
Linux.

Not blocking pre-alpha.

---

## Deferred (not tracking here)

- `SelectCase.Send<T>` (send-side select) — deferred, tracked in
  `SPEC.md:424`.
- macOS / iOS / WinARM64 runtime — targeted but unverified; no test runner
  configured.
