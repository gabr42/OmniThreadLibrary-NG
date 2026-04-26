# OTL-NG Open Items

Tracking list for work identified during pre-alpha prep. Not GitHub issues (repo
has none as of 2026-04-24). Priority hints reflect pre-alpha readiness: items
that affect real-app correctness or visible test reliability come first;
architectural cleanups and design questions are deferred.

Delete an entry when it's done; promote to a GitHub issue if it needs broader
discussion or external input.

---

## Pre-alpha priority

### 1. ~~Fix WSL manual-link TLS layout~~ — obsolete

The TLS-layout bug only ever lived in the WSL manual-link harness
(`C:\tmp_otl_link\linkit*.sh`). With the SDK at
`c:\Users\gabr\Documents\Embarcadero\Studio\SDKs\ubuntu24.04.sdk`
populated, Delphi's bundled `ld-linux.exe` can do the link itself —
no WSL detour, no TLS bug.

Working CLI invocation (commit 2026-04-26): pass `--syslibroot` at
the SDK and `--libpath` listing both the SDK lib dirs and Delphi's
`lib\linux64\release` (for the `librtlhelper.a` family). See
`CLAUDE.md` § Linux64. `bench_33_console` and `ConsoleTestRunner`
both build clean via this path; bench peak RSS dropped from 25 GiB
(WSL-link with the broken TLS layout) to 165 MiB.

The legacy WSL manual-link harness can be retired. No remaining
work — entry kept as a record so the repro recipe survives.

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

### 3. Profile Linux64 3–5× speedup vs Win64 on `bench_33` balanced configs

`bench_33` baseline post commit `ef39b94` (lock-free queue protocol
on every 64-bit target, see `tests/33_BlockingCollection/BENCH_README.md`):

Config | Win64 (ms) | Linux64 (ms) | ratio
---|---|---|---
1→1 | 1239 |  548 | 2.3×
2→2 |  784 |  220 | 3.6×
3→3 |  983 |  215 | 4.6×
4→4 | 1055 |  235 | 4.5×
8→8 | 1521 |  405 | 3.8×
1→7 | 7985 | 8118 | parity
7→1 |  751 |  325 | 2.3×

Both Release-mode builds. Hypotheses ruled out earlier:

- **FastMM4-debug overhead.** Win32/Win64 Release without `-DDEBUG`
  give the same numbers as the original baseline.
- **Lock-free CAS vs the old POSIX spinlock fallback.** Resolved
  by commits `b91711a` + `ef39b94`. Both targets now run the same
  lock-free protocol, so the gap can't be the queue's contention
  strategy — it's in the surrounding code.

The gap is real, large, and consistent across balanced configs.
Worth understanding before shipping pre-alpha because it implies
Win64 has avoidable overhead in the balanced-pipeline hot path.

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

Note that `1→7` is now at parity (was Linux-slower pre-`ef39b94`,
because the spinlock fallback hurt POSIX disproportionately on
asymmetric workloads). The remaining `1→7` cost is the
`AddObserver` / `RemoveObserver` churn already tracked in item #2.

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
