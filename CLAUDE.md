# OmniThreadLibrary NG

## Project structure

- Library source files are in the project root
- Unit tests are in `unittests/`
- DUnitX test runner: `unittests/ConsoleTestRunner.dpr`
- Compilation smoke test (all units): `unittests/CompileAllUnits.dpr`
- FastMM4 is a git submodule in `FastMM4/`
- GpDelphiUnits is a git submodule in `GpDelphiUnits/`
- Platform-specific options are in `OtlOptions.inc`

## Compiling and running unit tests

All commands run from the `unittests/` directory. Replace `dcc32` with `dcc64` for Win64 builds.

### Delphi 13.1 (RAD Studio 37.0)

```bash
cd unittests
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcc32.exe" ConsoleTestRunner.dpr -B "-U..;../FastMM4;../GpDelphiUnits/src" "-NSSystem;System.Win;Winapi;Vcl" -DDEBUG -E"./Win32/Debug" -NU"./Win32/Debug"
./Win32/Debug/ConsoleTestRunner.exe
```

### Delphi 12 (RAD Studio 23.0)

```bash
cd unittests
"e:\Delphi\23.0\bin\dcc32.exe" ConsoleTestRunner -b "-u..;../../fastmm4;x:/common/testinsight" -i.. "-nsSystem;System.Win;Winapi;Vcl;Vcl.Imaging;Vcl.Samples;Data;Xml"
./ConsoleTestRunner.exe
```

### Delphi 11 (RAD Studio 22.0)

```bash
cd unittests
"e:\Delphi\22.0\bin\dcc32.exe" ConsoleTestRunner -b "-u..;../../fastmm4;x:/common/testinsight" -i.. "-nsSystem;System.Win;Winapi;Vcl;Vcl.Imaging;Vcl.Samples;Data;Xml"
./ConsoleTestRunner.exe
```

### Linux64 cross-compilation (Delphi 13.1 only)

```bash
cd unittests
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcclinux64.exe" ConsoleTestRunner.dpr -B "-U..;../FastMM4;../GpDelphiUnits/src" "-NSSystem;Data;Xml" -DDEBUG -CC -E"./Linux64/Debug" -NU"./Linux64/Debug"
```

**Status: does not compile yet.** `OtlSync.pas` has several issues:
- `InterlockedCompareExchange128` is Windows-only (no `{$IFDEF MSWINDOWS}` guard inside `{$IFDEF CPUX64}`)
- `overload` keyword on implementation methods (lines 1894, 2976)
- `CloseHandle` used without platform guard in `TOmniWrappedEvent` (lines 2773-2782)
- `SetSynchObjects` declared unconditionally but implemented inside `{$IFDEF MSWINDOWS}` block
- Missing semicolon on line 2967

The output binary is a Linux ELF executable — it cannot be run on Windows, must be copied to a Linux machine.

### CompileAllUnits (compilation-only smoke test)

Replace `ConsoleTestRunner` with `CompileAllUnits` in the commands above. This project references all library units and verifies they compile, but has no test logic.

### Notes

- The `-NS` and `-U` arguments must be quoted in bash because they contain semicolons.
- Delphi 13 outputs to `unittests/Win32/Debug/` or `unittests/Win64/Debug/`. Delphi 11/12 output to `unittests/` (current directory).
- Delphi 11/12 use custom installations on `E:\Delphi\` and reference FastMM4 at `../../fastmm4` and TestInsight at `x:/common/testinsight`.
- Delphi 13 uses the standard Program Files installation and references `../GpDelphiUnits/src` (git submodule).
- Linux64 cross-compilation: drop `System.Win`, `Winapi`, `Vcl.*` from `-NS`; keep `System;Data;Xml`. Add `-CC` for console target.
- Linux64 cross-compilation is only available with Delphi 13.1. Delphi 11/12 custom installations at `E:\Delphi\` are missing the Linux RTL libraries.

## Known platform differences

- `OtlOptions.inc` defines `OTL_HaveCmpx16b` and `OTL_HasAPC` only on `MSWINDOWS`.
- Some test units are Windows-only (guarded with `{$IFDEF MSWindows}` in ConsoleTestRunner.dpr): `SmokeTest`, `TestTask`, `TestOtlParallel`.

## Thread-to-main-thread communication

OTL-NG sometimes sends information from worker threads to the main thread (e.g., task termination notifications via `TThread.Queue`/`TThread.ForceQueue`). This is a fundamental design fact that will not change. The thread owner must occasionally allow this information to be processed. For main threads, this means processing the queue used by `TThread.Queue`. Console applications must call `CheckSynchronize` at appropriate points to drain this queue.

## Known bug: Unit test hangs with thread pool + Unobserved

### Summary

Unit tests (Win32 and Win64) hang intermittently (~5-30% of runs). The bug is in the interaction between the thread pool and the `Unobserved` mechanism.

### Root cause

`Unobserved` calls `CreateInternalMonitor` which calls `TOmniEventMonitor.Monitor(Self)`. This stores a strong `IOmniTaskControl` reference in the monitor's `emMonitoredTasks` dictionary. This reference creates a cycle:

- `emMonitoredTasks[id]` → `IOmniTaskControl` (strong ref, prevents destruction)
- `TOmniTaskControl.Destroy` → `DestroyMonitor` → would release the monitor, but `Destroy` never runs because the reference keeps the object alive

The cycle is designed to be broken by `ForceQueue(ProcessTerminated)` → `Detach` → `emMonitoredTasks.Remove`. But `ForceQueue` requires `CheckSynchronize` to be called on the main thread. In console apps (like the DUnitX test runner), `CheckSynchronize` is never called, so:

1. Stale `IOmniTaskControl` references accumulate (500+ over 50 `Parallel.For` iterations)
2. Each stale task control holds a comm channel with container observers and event objects
3. These accumulated observers interfere with the pool's manager task's event signaling
4. The pool's manager task stops processing `Schedule` messages → tasks are never assigned to workers → `FCountStopped.Synchro.WaitFor(INFINITE)` hangs

### Key evidence from investigation

| Configuration | Hang rate | Conclusion |
|---|---|---|
| `task.Run` (no pool) | 0/50 | Pool is the cause |
| Pool + NO `Unobserved` | 0/50 (2/200) | `Unobserved` is the trigger |
| Pool + `Unobserved` (baseline) | 5/100 | Current state |
| `Parallel.For` + `NoThreadPool` | 0/100 | Pool + Unobserved together |
| Full test suite (226 tests) | ~30% | More tasks = higher probability |

### This is a leftover from the old OTL architecture

The old OTL used Windows message-based event dispatching. Console apps were required to call `ProcessThreadMessages`. The NG version moved to condvar-based synchronization (`TWaitFor`), but `Unobserved` still uses `TThread.ForceQueue` which requires message processing.

The TODO in `Unobserved` confirms this was known:
```pascal
{ TODO 1 -oPrimoz Gabrijelcic : reimplement without the internal monitor }
```

### Short-term fix (to make unit tests pass)

Add `CheckSynchronize(0)` calls at strategic points so `ForceQueue` items get processed in console apps. Candidate locations:
- After `FCountStopped.Synchro.WaitFor(INFINITE)` in `TOmniParallelSimpleLoop.InternalExecute`
- After `FCountStopped.Synchro.WaitFor(INFINITE)` in `TOmniParallelLoopBase.InternalExecuteTask`
- In the DUnitX test runner between test iterations

**Important**: `CheckSynchronize` must be called AFTER all tasks have completed their `InternalExecute` (including the MonitorLock release). There's a brief race window between `FCountStopped` signaling and the worker thread releasing MonitorLock. A small `Sleep(0)` or checking that all workers have sent `MSG_COMPLETED` may be needed.

### Long-term fix

Reimplement `Unobserved` without the internal event monitor, as the TODO suggests. Options:
- Use `[weak]` attribute (Delphi 11+) for the `emMonitoredTasks` reference to break the cycle
- Remove `emMonitoredTasks` entirely for internal monitors (since callbacks are no-ops)
- Replace the ForceQueue mechanism with direct reference management
- Make `Unobserved` a simple flag with lifecycle managed by reference counting

### Files involved

- `OtlTaskControl.pas`: `CreateInternalMonitor`, `Unobserved`, `TOmniTask.InternalExecute`, `TOmniTaskControl.Destroy`/`DestroyMonitor`
- `OtlEventMonitor.pas`: `TOmniEventMonitor.Monitor`, `emMonitoredTasks`, `NotifyTerminated`/`ProcessTerminated`/`Detach`
- `OtlParallel.pas`: `TOmniParallelSimpleLoop.InternalExecute` (the `Parallel.For` simple loop path — NOT `TOmniParallelLoopBase.InternalExecuteTask`)
- `OtlThreadPool.pas`: `TOTPWorker` (pool manager task), `TOTPWorkerThread.ExecuteWorkItem`

### Test infrastructure in unittests/

Several test scripts and helper files were created during the investigation. These can be cleaned up:
- `run_*.sh` — bash scripts for automated test runs
- `hang_*.log` — captured logs from hanging runs  
- `MinimalRepro*.dpr`, `MinimalPool*.dpr` — minimal reproduction programs
- `TestInstrumented.pas`, `InitLogger.pas`, `InstrumentedRunner.dpr` — instrumented test helpers
