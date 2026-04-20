# OmniThreadLibrary NG

## Project structure

- Library source files are in the project root
- Unit tests are in `unittests/`
- DUnitX test runner: `unittests/ConsoleTestRunner.dpr`
- Compilation smoke test (all units): `unittests/CompileAllUnits.dpr`
- FastMM4 is a git submodule in `FastMM4/`
- Platform-specific options are in `OtlOptions.inc`

## Compiling and running unit tests

OTL-NG targets five configurations: Win32, Win64, Linux64, Android64
(runtime), and Windows ARM64EC (compile-only smoke). All commands run
from the `unittests/` directory. Two runner `.dpr` files:

- `ConsoleTestRunner.dpr` — Win32/Win64/Linux64/ARM64EC
- `OtlAndroidTests.dpr` — Android FMX GUI runner (same test units)

Whenever you add a new test unit, register it in **both** runners.

### Win32 / Win64 — Delphi 13.1 (RAD Studio 37.0)

```bash
cd unittests
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcc32.exe" ConsoleTestRunner.dpr -B "-U..;../FastMM4" "-NSSystem;System.Win;Winapi;Vcl" -DDEBUG -E"./Win32/Debug" -NU"./Win32/Debug"
./Win32/Debug/ConsoleTestRunner.exe
```

Swap `dcc32` → `dcc64` and `Win32` → `Win64` for the 64-bit build.

### Win32 / Win64 — Delphi 11 (22.0) / Delphi 12 (23.0)

Custom installs under `E:\Delphi\`; FastMM4 at `../../fastmm4`,
TestInsight at `x:/common/testinsight`; output to `unittests/`
(current directory, unlike Delphi 13):

```bash
cd unittests
"e:\Delphi\23.0\bin\dcc32.exe" ConsoleTestRunner -b "-u..;../../fastmm4;x:/common/testinsight" -i.. "-nsSystem;System.Win;Winapi;Vcl;Vcl.Imaging;Vcl.Samples;Data;Xml"
./ConsoleTestRunner.exe
```

Delphi 11 is identical with `e:\Delphi\22.0\bin\dcc32.exe`.

### Linux64 (Delphi 13.1 only; WSL link required)

Delphi's bundled `ld-linux.exe` cannot resolve Linux system libraries,
so the compile step emits `.o` files and we link via WSL's native `ld`.

```bash
cd unittests
# Step 1: compile (link step will fail — that's expected)
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcclinux64.exe" ConsoleTestRunner.dpr -B "-U..;../FastMM4" "-NSSystem;Data;Xml" -DDEBUG -CC -E"./Linux64/Debug" -NU"./Linux64/Debug"

# Step 2: sync fresh .o files to staging, then link via WSL
cp -f ./Linux64/Debug/*.o /c/tmp_otl_link/Linux64/Debug/
MSYS_NO_PATHCONV=1 WSLENV= wsl -- bash /mnt/c/tmp_otl_link/linkit.sh

# Step 3: run the ELF under WSL
wsl /mnt/c/tmp_otl_link/Linux64/Debug/ConsoleTestRunner
```

Notes:
- Drop `System.Win;Winapi;Vcl.*` from `-NS`; keep `System;Data;Xml`.
  Add `-CC` for the console target.
- `linkit.sh` does **not** auto-sync `.o` files — without the `cp` step
  the link uses stale objects and source changes appear to have no
  effect.
- Not available on Delphi 11/12 (missing Linux RTL libs).

### Android64 (Delphi 13.1 only; FMX GUI runner)

`unittests/build_android.bat` is a one-shot script that runs
`msbuild /t:Make;Deploy`, installs the APK via `adb`, and launches the
runner. It auto-runs all tests and logs the summary to logcat:

```bash
cd unittests
./build_android.bat
"C:\Users\gabr\AppData\Local\Android\sdk\platform-tools\adb.exe" logcat -v time | grep "OTL_DIAG: AutoRun: TestCount"
```

Watch for `OTL_DIAG: AutoRun: TestCount=N Passed=P Failed=F Errors=E Leaks=L Ignored=I`.

### ARM64EC (Delphi 13.1 only; compile-only smoke)

No runtime available — the binary runs but cannot be executed on a
standard Windows dev machine. Use as a cross-compile smoke test.
**Note:** `dccarm64ec.exe` lives in `bin64\`, not `bin\`.

```bash
cd unittests
mkdir -p ./ARM64EC/Debug
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin64\dccarm64ec.exe" ConsoleTestRunner.dpr -B "-U..;../FastMM4" "-NSSystem;System.Win;Winapi;Vcl" -DDEBUG -E"./ARM64EC/Debug" -NU"./ARM64EC/Debug"
```

CPU defines: `CPUARM64` and `CPU64BITS` are defined, `CPUX64` is NOT.
Guard inline ASM with `{$IFDEF CPUX64}`; use `{$IFDEF CPU64BITS}` when
the distinction is "NativeInt is 64-bit" rather than "x86-64
intrinsics available".

### CompileAllUnits (compilation-only smoke across every target)

Replace `ConsoleTestRunner` with `CompileAllUnits` in any of the above
commands. This project references every library unit and verifies
they compile cleanly but has no test logic.

### General notes

- The `-NS` and `-U` arguments must be quoted in bash because they
  contain semicolons.
- Delphi 13 outputs to `unittests/Win32/Debug/` (or `Win64/Debug/`,
  `Linux64/Debug/`, `ARM64EC/Debug/`); Delphi 11/12 output to the
  current directory.
- Delphi 13 uses the standard Program Files installation;
  Delphi 11/12 use custom installs under `E:\Delphi\`.

## Known platform differences

- `OtlOptions.inc` defines `OTL_HaveCmpx16b` and `OTL_HasAPC` only on `MSWINDOWS`.
- Some test units are Windows-only (guarded with `{$IFDEF MSWindows}` in ConsoleTestRunner.dpr): `SmokeTest`, `TestTask`, `TestOtlParallel`.

## Thread-to-main-thread communication

OTL-NG sometimes sends information from worker threads to the main thread (e.g., task termination notifications via `TThread.Queue`/`TThread.ForceQueue`). This is a fundamental design fact that will not change. The thread owner must occasionally allow this information to be processed. For main threads, this means processing the queue used by `TThread.Queue`. Console applications must call `CheckSynchronize` at appropriate points to drain this queue.

## Known bug: Unit test hangs with thread pool

### Summary

Unit tests (Win32 and Win64) hang intermittently (~4% of full suite runs). The hang occurs in tests that use the thread pool.

### What has been fixed

1. **Unobserved redesign** (commit 153001d): Eliminated `CreateInternalMonitor`/`ForceQueue` dependency.
2. **Gate-leak race in TWaitFor** (OtlSync.pas v3.02): Fixed race where `PerformObservableAction` acquired a gate via `EnterGate`, but `TWaitFor.Destroy` ran concurrently and nilled `FController` via `Deref`, causing `GetGate` to return nil and the finally block to skip releasing the lock. Fix: `EnterGate` now saves the gate reference to `FAcquiredGate` before acquiring, so `GetGate` returns it regardless of `FController` state.

### Current hang rates (post gate-leak fix)

| Configuration | Hang rate |
|---|---|
| `TestTask.TestStartTask` only | 0/30 |
| Full test suite (242 tests) | ~2/50 |

### Files involved

- `OtlSync.pas`: `TSynchroClient.EnterGate`, `GetGate`, `LeaveGate`, `PerformObservableAction`
- `OtlThreadPool.pas`: `TOTPWorker` (pool manager task), `TOTPWorkerThread.ExecuteWorkItem`
- `OtlParallel.pas`: `TOmniParallelSimpleLoop.InternalExecute`, `Parallel.Start`
