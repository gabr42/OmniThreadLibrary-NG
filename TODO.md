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
(formerly at `C:\tmp_otl_link\`, deleted 2026-04-26). With the SDK
at `c:\Users\gabr\Documents\Embarcadero\Studio\SDKs\ubuntu24.04.sdk`
populated, Delphi's bundled `ld-linux.exe` can do the link itself —
no WSL detour, no TLS bug.

Working CLI invocation (commit `030e47e`, 2026-04-26): pass
`--syslibroot` at the SDK and `--libpath` listing both the SDK lib
dirs and Delphi's `lib\linux64\release` (for the `librtlhelper.a`
family). See `CLAUDE.md` § Linux64. `bench_33_console` and
`ConsoleTestRunner` both build clean via this path; bench peak RSS
dropped from 25 GiB (WSL-link with the broken TLS layout) to 165 MiB.

No remaining work — entry kept as a record.

### 2. Profile Linux64 3–5× speedup vs Win64 on `bench_33` balanced configs — findings 2026-04-26

`bench_33` baseline (post commit `ef39b94`, lock-free queue protocol
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

Phase 2 instrumentation (`OtlBenchProbe.pas`, wired at outermost
`TryAdd` / `TryTake` call sites in `OtlCollections.pas`, gated by
`-DOTL_BENCH_PROBE`) per-call costs across the same configs:

Config | Win64 TryAdd | Linux64 TryAdd | W/L | Win64 TryTake | Linux64 TryTake | W/L
---|---|---|---|---|---|---
1→1 |   574 ns |   260 ns | 2.2× |    62 ns |   129 ns | 0.5×
2→2 |  1131 ns |   325 ns | 3.5× |    75 ns |   120 ns | 0.6×
4→4 |  2262 ns |   410 ns | 5.5× |    91 ns |   143 ns | 0.6×
8→8 |  6114 ns |  1182 ns | 5.2× |   333 ns |   905 ns | 0.4×
1→7 |  6426 ns |  3461 ns | 1.9× |  9008 ns | 22961 ns | 0.4× (mostly wait time)
7→1 |  1454 ns |   606 ns | 2.4× |    57 ns |   104 ns | 0.5×

Hypotheses ruled out:

- **Lock-free queue (`Enqueue` / `TryDequeue`)**. Probed inline:
  Win64 49 ns / 51 ns per call vs Linux64 195 ns / 174 ns. Win64 is
  *4× faster* per queue op — the gap is not in the queue.
- **False sharing between `obcAddCountAndCompleted` and
  `obcApproxCount`.** Padded them onto separate cache lines — no
  measurable change. Contention is on a single field, not between
  fields.
- **`TOmniAlignedInt32.Initialize` writing FAddr per call.** Made
  one-shot — 2-6% improvement, not the dominant cost.
- **Per-WaitAny syscall cost dominating.** Win64 `WaitAny` *is* 10×
  more expensive per call (~1.13 ms vs ~118 µs on Linux), but is
  called 28× less often on balanced configs because Win64 producer
  is slower → queue rarely runs dry. Net wait-time is *higher* on
  Linux (290 s vs 100 s across the matrix). Sync primitive cost
  matters on `1→7` (asymmetric) but not on balanced configs.
- **Probe instrumentation contention.** Inner probes inflate outer
  probe measurements by 10-20% under heavy contention because each
  `TBenchProbe.Add` is itself a few atomic ops on shared state. Only
  outermost probes are kept wired.

Confirmed root cause: **`TryAdd`'s three contended `LOCK XADD`
operations on shared `TOmniAlignedInt32` fields** —
`obcAddCountAndCompleted.Increment` (entry), `obcApproxCount.Increment`
(after Enqueue), `obcAddCountAndCompleted.Decrement` (exit). Per-op
cost on x86-64 LOCK XADD against a contended cache line should be
~50-100 ns. Linux64 measures roughly that (TryAdd-minus-Enqueue at
8→8 ≈ 360 ns total = 120 ns each). Win64 measures ~1900 ns each at
8→8 — **15× the expected hardware-level cost**, on the same x86-64
silicon. Same `LOCK XADD` instructions, both LLVM-compiled. The gap
is in OS scheduler + cache-coherency dynamics under contention, not
OTL code.

Skipping the entry counter entirely (one of the three atomic ops)
yielded a 25% improvement at 8→8 on Win64 — confirming the atomics
are the dominant cost — but only at high contention, and removing
the entry counter breaks `CompleteAdding` semantics.

Mitigation paths:

1. **Reduce TryAdd's atomic-op count from 3 to 1.** Replace
   `obcAddCountAndCompleted` increment/decrement-pair-around-body
   with a single CAS or seqlock-style read of a completed flag.
   `CompleteAdding` would need a different mechanism to wait for
   in-flight TryAdds to drain (RCU-like grace period, or rendezvous
   barrier). Algorithmic change with subtle race conditions to
   re-prove. Largest potential win: ~3× on Win64 balanced configs.
2. **Per-thread approximate counters, periodic merge.** Each thread
   maintains a thread-local count; CompleteAdding waits for all to
   drain. Works but complicates teardown and adds bookkeeping.
3. **Accept the gap and move on.** Win64 *is* slower on this
   synthetic balanced-throughput micro-benchmark, but real-app
   blocking-collection workloads usually have lower contention or
   asymmetric fan-in (the `7→1` shape) where the gap is much
   smaller (2.2-2.4×) and absolute cost is bounded.

Recommendation for pre-alpha: option 3 (accept). The bench shows a
gap but doesn't show user-visible breakage. Revisit after pre-alpha
if real-app reports surface, with option 1 as the natural target.

Phase 2 instrumentation (`OtlBenchProbe.pas`) is checked in for
future use — compile-time gated by `-DOTL_BENCH_PROBE`, no runtime
impact when off.

---

## Post pre-alpha

### 3. ~~Make OTL tasks implicitly owned (eliminate `Unobserved`)~~ — won't do

Closed 2026-04-26 after impact analysis. Original author TODO at
`OtlTaskControl.pas:170`: *"The whole Unobserved mess should go away
- task should be implicitly owned ALWAYS"*. Comment removed in the
same commit.

The change sounds clean (every task auto-owns itself, `.Unobserved`
becomes a no-op alias) but it would silently break a real, observable
behavior of the current model:

**Today's contract (precise):** when the last `IOmniTaskControl`
reference drops, `TOmniTaskControl.Destroy` runs and calls `Terminate`
→ `Stop` + `WaitFor(INFINITE)`. The dropping thread *blocks* until
the task body exits. Tasks that poll `task.Terminated` exit cleanly;
tasks that don't, run to completion while the dropping thread blocks.
This is **synchronous cooperative cancellation gated on ref-count**,
not asynchronous fire-and-forget.

`FTask := nil` is therefore a real cancellation primitive that real
code relies on — destructors of forms / classes that hold an
`IOmniTaskControl` field don't need explicit `.Terminate` because
field destruction does it for them.

**Under the proposal:** `FTask := nil` returns immediately, the task
keeps running. No more hung destructors — but also no more implicit
cancellation. Callers must remember `.Terminate` themselves.

The new failure mode is *invisible* (silent zombie tasks consuming
pool slots, possibly accessing freed owners) where the old failure
mode was *visible* (hung shutdown). On balance the migration trades
one footgun for a worse one.

Risk-categorised survey of the test suite + bench/demo code (47
files):

- **Pattern A — explicit `.Unobserved.Run`** (~6-20 sites): no change.
- **Pattern B — loop spawn with `.Unobserved`** (2-5 sites): no change.
- **Pattern C — stored field + explicit `.Terminate`** (e.g.
  `test_2_TwoWayHello`, `test_22_TerminationTest`, ~6-20 sites):
  explicit `.Terminate` paths keep working, but error paths that nil
  the field without calling `.Terminate` first leak the task.
- **Pattern D — array of stored refs** (`test_10_Containers`,
  `test_33_BlockingCollection`, etc.): same as C.
- **Pattern E — `Monitor(...).Run` without storing** (~6-20 sites):
  no change (monitor holds the ref).

Patterns C and D are the medium-risk class; "high risk" would be
intentional drop-to-cancel patterns, which exist in the wild.

Other concrete failure modes the change would introduce:

1. **Long-running tasks ignoring the Stop signal.** Today the
   destructor's `WaitFor` blocks visibly. Under the proposal, the
   task keeps running silently — invisible bug.
2. **GUI form lifetime.** Forms whose `OnDestroy` doesn't explicitly
   `.Terminate` rely on the field-drop cancellation. Under the
   proposal the form is freed but the task keeps running, possibly
   accessing freed members or sending messages to a freed form.
3. **Test isolation.** A test that drops the ref without
   `.Terminate` currently leaves a clean slate (destructor blocks).
   Under the proposal tasks can leak across tests, producing flaky
   cross-test interference.
4. **Recursive task creation.** Parent task spawns children via
   local refs. If parent throws, current code cancels children
   (ref-count drop). Under the proposal children outlive parent.
5. **`InstallUnobservedCommDispatcher` overhead applied universally.**
   Currently paid only by opt-in tasks; under the proposal every
   task pays it.

If a redesign happens later, it should:
- Be gated by `{$DEFINE OTL_LEGACY_REFCOUNT_CANCEL}` for at least
  one major version, defaulting ON
- Ship with a documented lint pattern: every `IOmniTaskControl`
  field that gets nil'd must have a preceding explicit `.Terminate`
- Validate against real-app code, not just OTL's own tests

For now: status quo. The current model has been load-tested by years
of real OTL usage; trading a known footgun for an unproven one is a
net loss without concrete user demand. Re-open if real-app reports
during pre-alpha surface a concrete user need.

### 4. ~~Triage `OtlParallel` design-question TODOs~~ — done

Resolved 2026-04-26. All 11 author TODO comments at the top of
`OtlParallel.pas` (lines 381–392) plus the pipeline output-ordering
TODO (line 1682) and the related "Notes for OTL 3" comment block
were removed. They were old enough that the original intent behind
most of them was no longer remembered; carrying them forward as
"open" was misleading. If any of those API-shape questions resurface
in real-world use, they can be re-opened as concrete proposals
rather than as inherited prompts.

### 5. ~~Recheck legacy NEXTGEN / MSWINDOWS IFDEFs in `OtlCommon.pas`~~ — done

Resolved 2026-04-26 (`OtlCommon.pas` v3.02). Three blocks of stale
guards in `TOmniValue.Create` / `CreateNamed` removed:

- `{$IFNDEF NEXTGEN}` around `vtChar` / `vtString` cases — NEXTGEN
  is gone in Delphi 11+, so the guards always evaluated to true.
- `{$IFDEF MSWINDOWS}` around `vtAnsiString` / `vtWideString` /
  `vtPChar` — the `vt*` TVarRec constants are universal; the only
  Windows-specific helper was `StrPasA(VPChar)` (lives in
  `System.AnsiStrings`, Windows-only). Replaced with the universal
  `string(AnsiString(VPChar))` cast which works on every platform.

Verified Win32/Win64/Linux64/ARM64EC all build + run clean.

---

## Deferred (not tracking here)

- `SelectCase.Send<T>` (send-side select) — deferred, tracked in
  `SPEC.md:424`.
- macOS / iOS / WinARM64 runtime — targeted but unverified; no test runner
  configured.
- POSIX `TWaitFor` persistent-observer optimization — five attempts
  (2026-04-23 through 2026-04-26), all hang Linux identically. The
  ~440 µs/wait perf win on POSIX is not worth more drills without a
  redesign. Full retry history and three+ proposed redesign paths in
  `memory/project_posix_persistent_observer_attempt.md`. Pick up only
  if a concrete plan based on (a) gdb-watchpoint hunt for the mystery
  signaller, (b) per-Wait observer model with batched locking, or
  (c) eventfd+epoll primitive replacement is on the table.

  **Reference cost (2026-04-26).** Captured bench_33 (TOmniBlocking-
  Collection) vs bench_32 (raw TOmniBaseQueue) at the same workload
  shape on two Android devices. The 1→7 row isolates the
  wait/observer overhead, since 1→7 is the only config where a
  starved consumer hammers `TWaitFor.WaitAny`:

  | Device | bench_33 1→7 | bench_32 1→7 | Ratio |
  |---|---:|---:|---:|
  | Galaxy S7 (Cortex-A57/A53) | 79,965 ms | 1,444 ms | **57×** |
  | Pixel 9 Pro (ARMv9-A)      | 51,506 ms |   686 ms | **75×** |

  That ratio is approximately the upper bound of what a successful
  persistent-observer / batched-lock / eventfd redesign could
  recover on POSIX 1→7. Even halving that cost would be a major
  win on real-app fan-out workloads with starved consumers.
