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

### Linux64 (Delphi 13.1 only)

Single-step compile + link via `dcclinux64`. Requires a populated
PAServer SDK at `c:\Users\gabr\Documents\Embarcadero\Studio\SDKs\ubuntu24.04.sdk`
(synced from a real Linux box once via the IDE — it pulls down libc,
libgcc, libpthread, etc.). With `--syslibroot` and `--libpath`
pointing at it plus Delphi's `lib\linux64\release` (for the
`librtlhelper.a` family), Delphi's bundled `ld-linux.exe` resolves
all symbols on its own.

```bash
cd unittests
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcclinux64.exe" ConsoleTestRunner.dpr \
  -B "-U..;../FastMM4" "-NSSystem;Data;Xml" -DDEBUG -CC \
  -E"./Linux64/Debug" -NU"./Linux64/Debug" \
  --syslibroot:"C:/Users/gabr/Documents/Embarcadero/Studio/SDKs/ubuntu24.04.sdk" \
  --libpath:"C:/Users/gabr/Documents/Embarcadero/Studio/SDKs/ubuntu24.04.sdk/usr/lib/x86_64-linux-gnu;C:/Users/gabr/Documents/Embarcadero/Studio/SDKs/ubuntu24.04.sdk/lib/x86_64-linux-gnu;C:/Users/gabr/Documents/Embarcadero/Studio/SDKs/ubuntu24.04.sdk/usr/lib/gcc/x86_64-linux-gnu/13;C:/Program Files (x86)/Embarcadero/Studio/37.0/lib/linux64/debug;C:/Program Files (x86)/Embarcadero/Studio/37.0/lib/linux64/release"

# Run via WSL (binary on Windows side, executed by Linux kernel through 9P).
# H: is a subst not visible to WSL; copy to /mnt/c first or stage on a
# WSL-accessible path. C:\Temp is a fine throwaway location.
cp ./Linux64/Debug/ConsoleTestRunner /c/Temp/CTR
MSYS_NO_PATHCONV=1 WSLENV= wsl -- /mnt/c/Temp/CTR
```

Notes:
- Drop `System.Win;Winapi;Vcl.*` from `-NS`; keep `System;Data;Xml`.
  Add `-CC` for the console target.
- An earlier WSL manual-link harness lived at `C:\tmp_otl_link\` and
  was retired 2026-04-26 (it had a TLS-layout bug that caused
  4 GiB-per-thread mmaps). Don't bring it back.
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

## Pool-manager hang (resolved 2026-04-17)

Earlier builds had intermittent full-suite hangs (~4% on Win32/Win64)
in thread-pool tests. Three fixes landed:

1. **Unobserved redesign** (commit 153001d): Eliminated
   `CreateInternalMonitor` / `ForceQueue` dependency; `SharedInfo` now
   self-references during cleanup.

2. **Gate-leak in TWaitFor** (commit ac3f364, OtlSync.pas v3.02):
   `PerformObservableAction` acquired a gate via `EnterGate`, but
   `TWaitFor.Destroy` running concurrently could nil `FController`
   via `Deref`, making `GetGate` return nil and the finally block
   skip the release. Fix: `EnterGate` saves the gate reference to
   `FAcquiredGate` before acquiring, so `GetGate` / `LeaveGate` work
   regardless of `FController` state.

3. **UAF in TOmniContainerSubject.Notify** (commit 0f801d0): `Notify`
   took a snapshot of observers under the read lock, then released the
   lock before invoking them (introduced by c5ccd38 to avoid re-entrant
   Attach/Detach deadlock). Between snapshot and invocation another
   thread could `Detach + FreeAndNil` an observer, producing AVs in the
   thread-pool manager. Fix: observers are now `IInterface`-refcounted
   (`TOmniContainerObserver` descends from `TInterfacedObject` implementing
   `IOmniContainerObserver`); `Notify` / `NotifyOnce` snapshot
   `TArray<IOmniContainerObserver>`, so refcounts keep observers alive
   through dispatch while the read lock is released. Preserves c5ccd38
   lock semantics.

Verified post-0f801d0: 50/50 clean full-suite runs, plus subsequent
regression sweeps with no hang reproduced.

### Historical files involved

- `OtlSync.pas`: `TSynchroClient.EnterGate`, `GetGate`, `LeaveGate`, `PerformObservableAction`
- `OtlContainers.pas`: `TOmniContainerSubject.Notify` / `NotifyOnce` / `Attach` / `Detach`
- `OtlThreadPool.pas`: `TOTPWorker` (pool-manager task), `TOTPWorkerThread.ExecuteWorkItem`
- `OtlParallel.pas`: `TOmniParallelSimpleLoop.InternalExecute`, `Parallel.Start`
