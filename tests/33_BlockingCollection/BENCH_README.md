# bench_33 — TOmniBlockingCollection benchmark

Headless companion to the GUI demo in `test_33_BlockingCollection.pas`.
Runs a fixed set of producer / consumer configurations back-to-back on
`TOmniBlockingCollection.Take`, reports per-config `avg / min / max` ms
and per-run values so a future change to `OtlContainers.pas` (e.g.
replacing the POSIX lock-free spinlock fallback) can be measured
against a stable baseline.

Focuses on the blocking `.Take` path — no `.TryTake` branch, no
`IsFinalized` polling. One `.Take` path is what real consumers use; a
separate micro-benchmark for `.TryTake` is out of scope here.

## Configurations

Configuration | Threads | Workload shape
---|---|---
`1→1` | 1 forwarder, 1 reader | Baseline 2-thread pipeline
`2→2` | 2 + 2                 | Mild contention
`3→3` | 3 + 3                 | "
`4→4` | 4 + 4                 | "
`8→8` | 8 + 8                 | Heavy contention
`1→7` | 1 forwarder, 7 readers | Producer-starved consumers (upper-bounded by single-producer throughput)
`7→1` | 7 forwarders, 1 reader | Consumer-starved producers (upper-bounded by single-consumer throughput)

Each config runs **1 warm-up + 3 measured reps**, 1,000,000 items per
rep. Total bench runtime ≈ 60–90 s on Win64.

## Output format

```
Platform : Windows (64-bit)

TOmniBlockingCollection benchmark: 1000000 items, 1 warm-up + 3 measured reps

1->1    avg=  1002,7 ms  min=  899 ms  max= 1119 ms  runs=[990,1119,899]
2->2    avg=  1116,3 ms  min=  915 ms  max= 1272 ms  runs=[1272,1162,915]
...
7->1    avg=   769,0 ms  min=  748 ms  max=  794 ms  runs=[765,794,748]

Total benchmark runtime: 65206 ms
```

On Android, every line also goes to `adb logcat` tagged `OTL_DIAG`,
matching the unit-test runner. Results can be captured with
`adb logcat -d | grep OTL_DIAG` after the form runs.

## Build and run

### Win32 / Win64

```bash
cd tests/33_BlockingCollection
mkdir -p Win32/Debug Win64/Debug
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcc32.exe" \
  bench_33_console.dpr -B "-U../..;../../FastMM4" \
  "-NSSystem;System.Win;Winapi" -DDEBUG \
  -E"./Win32/Debug" -NU"./Win32/Debug"
./Win32/Debug/bench_33_console.exe
```

Swap `dcc32` → `dcc64` and `Win32` → `Win64` for 64-bit.

### Linux64

Manual-link workflow, same pattern as `unittests/ConsoleTestRunner`
and `benchmarks/comm_pingpong`. Scaffolding under
`C:\tmp_otl_link\`:

- `make_bench_33_lnk_win.py` — derives `bench_33_console.lnk.src`
  from the unittests' `ConsoleTestRunner.lnk` by dropping
  DUnitX / `Test*.o` / `ConsoleTestRunner.o` / `SmokeTest.o` /
  `OtlLogger.o` entries (bench_33 keeps `OtlCollections.o`, unlike
  bench_pingpong).
- `linkit_bench_33.sh` — reads the .lnk.src, translates Windows
  paths to WSL-accessible staging paths via `translate_lnk.py`,
  and invokes `ld` with the right entry symbol
  (`_ZN16Bench_33_console14initializationEv`).

The project root lives on `H:` (a `subst` for `D:\work`) which is
not visible to WSL, so both the .lnk and the emitted `bench_33_console`
binary live under `/mnt/c/tmp_otl_link/...` rather than in the
project tree.

One-shot flow:

```bash
# 1. Emit objects (linker error is expected — we link manually below).
cd tests/33_BlockingCollection
mkdir -p Linux64/Debug
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcclinux64.exe" \
  bench_33_console.dpr -B "-U../..;../../FastMM4" "-NSSystem" \
  -DDEBUG -CC -E"./Linux64/Debug" -NU"./Linux64/Debug"
# 2. Stage bench objects into the WSL-accessible dir.
cp -f ./Linux64/Debug/*.o /c/tmp_otl_link/Linux64/Debug/
# 3. Regenerate the .lnk.src (once, after adding new OTL units to the bench).
/c/Python313/python /c/tmp_otl_link/make_bench_33_lnk_win.py
# 4. Link via WSL.
MSYS_NO_PATHCONV=1 WSLENV= wsl -- bash /mnt/c/tmp_otl_link/linkit_bench_33.sh
# 5. Run.
MSYS_NO_PATHCONV=1 WSLENV= wsl -- /mnt/c/tmp_otl_link/Linux64/Debug/bench_33_console
```

Step 3 only needs re-running when the bench's Delphi-unit set changes
(e.g. a new `uses` in `bench_33_shared.pas`). Everyday iterations on
the bench body only need steps 1, 2, 4, 5.

### Android64

FMX front-end (`bench_33_mobile.dpr`, `bench_33_mobile_main.pas`,
`bench_33_mobile_main.fmx`) auto-runs on form show, streams each
result line into a `TMemo`, and also emits each line to `adb
logcat` tagged `OTL_DIAG`.

`.dproj` scaffolding is not checked in yet — easiest setup is to
copy `unittests/OtlAndroidTests.dproj` (the `.deployproj` and
Android artefacts) and swap in `bench_33_mobile.dpr` as the main
source. Build / deploy / launch mirrors
`unittests/build_android.bat`.

Once running:

```bash
"C:\Users\<user>\AppData\Local\Android\sdk\platform-tools\adb.exe" \
  logcat -d | grep OTL_DIAG
```

## Shared source layout

File | Role
---|---
`bench_33_shared.pas` | `TBench33Runner` class + worker procs. No VCL/FMX deps; both front-ends consume this.
`bench_33_console.dpr` | Win32 / Win64 / Linux64 console entry. Prints via `Writeln`.
`bench_33_mobile.dpr` | Android FMX entry.
`bench_33_mobile_main.pas` | FMX form; spawns a worker thread to run `RunAll`, streams results to screen + `OTL_DIAG`.
`bench_33_mobile_main.fmx` | Minimal UI (`lblStatus` + `memResults`).

Per-config timings are formatted by `TBench33Runner.LogConfigResult`
and are identical across all front-ends — one baseline table per
platform.

## Interpreting results

- **Balanced configs (`N→N`)** should scale gently with N up to
  roughly the core count; beyond that the BlockingCollection's
  internal CAS contention dominates and throughput flattens or
  regresses.
- **`1→7`** is bottlenecked by a single forwarder feeding seven
  consumers — expect it to be ~5–10× slower than balanced configs
  because the channel runs dry most of the time.
- **`7→1`** is bottlenecked by a single reader — expect it to be
  close to the fastest (producers can pre-load the channel).

A change that improves the lock-free-container throughput should
primarily affect the `N→N` configs (CAS contention). Regressions
should show up most visibly on `8→8` and on POSIX, where the
spinlock fallback in `OtlContainers.pas` currently serialises
access.

## Baseline (2026-04-24)

Captured on this machine for reference. Replace with your own after
you run the benchmark — hardware varies.

Platform | 1→1 | 2→2 | 3→3 | 4→4 | 8→8 | 1→7 | 7→1
---|---|---|---|---|---|---|---
Win32   | 1055 | 1153 | 1198 | 1163 | 1168 | 8983 | 1009
Win64   | 1003 | 1116 |  995 |  935 | 1433 | 7085 |  769

(average ms over 3 measured reps, 1M items per rep)
