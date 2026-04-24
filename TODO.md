# OTL-NG Open Items

Tracking list for work identified during pre-alpha prep. Not GitHub issues (repo
has none as of 2026-04-24). Priority hints reflect pre-alpha readiness: items
that affect real-app correctness or visible test reliability come first;
architectural cleanups and design questions are deferred.

Delete an entry when it's done; promote to a GitHub issue if it needs broader
discussion or external input.

---

## Pre-alpha priority

### 1. Investigate Linux64 `bench_33` silent exit on any multi-worker config

**Precise repro** (deterministic, 1000 items is enough — not memory-related):

1. In `bench_33_shared.pas`, temporarily set `CItemCount = 1000` and
   `Configs = [Create(1,1), Create(2,1)]`.
2. Rebuild: `dcclinux64 ...` + `cp *.o → /c/tmp_otl_link/Linux64/Debug/`
   + `linkit_bench_33.sh`.
3. Run: `wsl -- /mnt/c/tmp_otl_link/Linux64/Debug/bench_33_console`.
4. Observe: `1→1` completes all 4 runs cleanly (~360 ms each). `2→1`
   prints `[trace 2x1 readers started]` from the main thread, then the
   process exits with code 1 **before any worker code runs** (no
   worker-side Writeln emerges even when the workers have a first-line
   stdout trace).

**Observations so far**:

- Fails on any config where one collection has multiple concurrent
  producers OR multiple concurrent consumers: `2→1`, `1→2`, `2→2`, and
  presumably larger. Does NOT fail on `1→1`.
- Reproduces with 1000 items and 1M items equally — not memory-related.
- Process exits with code 1, but:
  - No exception message reaches `main`'s outer `try/except`.
  - `gdb -ex "catch signal SIGSEGV SIGABRT SIGBUS SIGILL" -ex run` —
    no signal fires.
  - `gdb -ex "catch syscall exit_group" -ex "commands" ... -ex run` —
    catchpoint doesn't emit a backtrace either; the inferior just ends.
  - `strace -e signal` produces only per-thread `+++ exited with 0 +++`;
    no SIGSEGV / SIGABRT before the main thread disappears.
  - Worker threads DO spawn (`[New Thread LWP N]` appears in gdb), but
    a first-line stdout trace inside the worker never reaches the log
    on the failing configs — suggesting workers are torn down before
    executing.
- Ruled out:
  - `.Unobserved` vs plain `.Run` — same failure either way.
  - `Add` vs `TryAdd` on chan/dst collections — same failure (a real
    `ECollectionCompleted` race did exist; it's fixed in commit
    `9ab5228`, but the Linux crash is unrelated).
  - Concurrent `Writeln` from worker threads — bench still crashes
    with worker-side Writeln removed entirely.

**Likely areas to explore**:

1. OTL task teardown on POSIX when dedicated-thread tasks are created
   in rapid back-to-back batches (each `RunOnce` spawns N+M fresh
   TThread instances; over 4 runs that's 20-30 thread create/destroy
   cycles per config). Look for Linux-only cleanup races in
   `TOmniTaskControl.Destroy` / `TOmniThread.Terminate` /
   `TOmniUnobservedCleanupThread`.
2. `TBlockingCollection` concurrent Take/TryAdd on the POSIX lock-free
   fallback (adjacent to item 2). Try reproducing with raw
   `TOmniBlockingCollection` + `TThread` (no OTL task layer) — if that
   crashes too, the container is at fault; if it doesn't, the task
   layer is.
3. Enable `ulimit -c unlimited`, set
   `/proc/sys/kernel/core_pattern=core.%p` (or equivalent in the
   bench's cwd), and post-mortem-debug the core via `gdb bench
   core.<pid>`. This should give the real crash site even when
   in-process gdb misses the signal.

**Scaffolding**: `C:\tmp_otl_link\make_bench_33_lnk_win.py`,
`linkit_bench_33.sh`, `gdb_bench33.sh`, `gdb_catch_any.sh`,
`strace_bench33.sh` — all set up and working.

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

### 3. Replace lock-free-container spinlock fallback with cross-platform CAS

`OtlContainers.pas` lock-free queue / stack rely on 128-bit CAS. On Windows x64
this is `InterlockedCompareExchange128` (CMPXCHG16B). On POSIX and non-x86
(ARM64, ARM64EC) the fallback is a global spinlock-protected critical section —
semantically correct but NOT lock-free; throughput under contention drops to
single-writer. Matters for pre-alpha users who profiled lock-free progress on
Windows and now deploy on Linux / Android.

TODO marker: `OtlSync.pas:954`.

Approaches:

1. ARM64 `LDXP` / `STXP` intrinsics for 128-bit CAS (closest analogue to
   CMPXCHG16B).
2. Redesign containers around 64-bit CAS + version counter in a tagged pointer
   (hard with 48-bit virtual addresses on some ARM64).
3. Per-thread hazard-pointer reclamation.

Start with (1) since it's the most direct port.

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
