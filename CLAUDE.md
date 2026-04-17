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

## Known bug: Unit test hangs with thread pool

### Summary

Unit tests (Win32 and Win64) hang intermittently (~10-30% of full suite runs). The hang occurs in `TestOtlParallel` tests that use `Parallel.For` with the thread pool.

### Symptoms

The pool's manager task stops processing `Schedule` messages. Tasks are never assigned to workers, causing `FCountStopped.Synchro.WaitFor(INFINITE)` to hang.

### What has been ruled out

The `Unobserved` mechanism was redesigned (commit 153001d) to eliminate the `CreateInternalMonitor`/`ForceQueue` dependency. Pure `Unobserved` tasks no longer create event monitors or accumulate refs in `emMonitoredTasks`. Despite this, the hang persists at similar rates, indicating the root cause is in the thread pool itself, not in `Unobserved`.

### Current hang rates (post-Unobserved fix)

| Configuration | Hang rate |
|---|---|
| `TestUnobserved` only | 0/20 |
| `TestOtlParallel` only | ~1/10 |
| Full test suite (242 tests) | ~3/10 |

### Files involved

- `OtlThreadPool.pas`: `TOTPWorker` (pool manager task), `TOTPWorkerThread.ExecuteWorkItem`
- `OtlParallel.pas`: `TOmniParallelSimpleLoop.InternalExecute`, `Parallel.Start`
