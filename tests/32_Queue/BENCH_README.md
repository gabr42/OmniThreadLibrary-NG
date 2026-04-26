# bench_32 — TOmniBaseQueue benchmark

Headless companion to the GUI demo in `test_32_Queue.pas`.
Runs a fixed set of forwarder / reader configurations back-to-back on
`TOmniBaseQueue.Enqueue` / `TOmniBaseQueue.TryDequeue`, reports per-
config `avg / min / max` ms and per-run values so a future change to
the lock-free queue protocol in `OtlContainers.pas` can be measured
against a stable baseline.

Focuses on the **non-blocking** queue path. Workers spin in a tight
loop calling `TryDequeue`; when the queue is empty `TryDequeue`
returns `false` immediately and the outer loop checks the stop flag.
CPU stays pegged on every worker until the stop counter fires —
this is by design; what we measure is raw lock-free queue throughput
under contention, **not** the blocking-collection wait path that
bench_33 covers.

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
rep. Total bench runtime ≈ 10–15 s on x86-64.

## Output format

```
Platform : Windows (64-bit)

TOmniBaseQueue benchmark: 1000000 items, 1 warm-up + 3 measured reps

1->1    avg=   178,0 ms  min=  162 ms  max=  193 ms  runs=[193,179,162]
2->2    avg=   186,3 ms  min=  177 ms  max=  203 ms  runs=[203,179,177]
...
7->1    avg=   273,3 ms  min=  260 ms  max=  294 ms  runs=[260,294,266]

Total benchmark runtime: 8934 ms
```

On Android, every line also goes to `adb logcat` tagged `OTL_DIAG`,
matching the unit-test runner. Results can be captured with
`adb logcat -d | grep OTL_DIAG` after the form runs.

## Build and run

### Win32 / Win64

```bash
cd tests/32_Queue
mkdir -p Win32/Debug Win64/Debug
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcc32.exe" \
  bench_32_console.dpr -B "-U../..;../../FastMM4" -I"../.." \
  "-NSSystem;System.Win;Winapi" -DDEBUG \
  -E"./Win32/Debug" -NU"./Win32/Debug"
./Win32/Debug/bench_32_console.exe
```

Swap `dcc32` → `dcc64` and `Win32` → `Win64` for 64-bit.

### Linux64

Single-step compile + link via `dcclinux64`, same pattern as
`CLAUDE.md` § Linux64. Requires the populated SDK at
`c:\Users\gabr\Documents\Embarcadero\Studio\SDKs\ubuntu24.04.sdk`.

```bash
cd tests/32_Queue
mkdir -p Linux64/Debug
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcclinux64.exe" \
  bench_32_console.dpr -B "-U../..;../../FastMM4" -I"../.." "-NSSystem;Data;Xml" \
  -DDEBUG -CC -E"./Linux64/Debug" -NU"./Linux64/Debug" \
  --syslibroot:"C:/Users/gabr/Documents/Embarcadero/Studio/SDKs/ubuntu24.04.sdk" \
  --libpath:"C:/Users/gabr/Documents/Embarcadero/Studio/SDKs/ubuntu24.04.sdk/usr/lib/x86_64-linux-gnu;C:/Users/gabr/Documents/Embarcadero/Studio/SDKs/ubuntu24.04.sdk/lib/x86_64-linux-gnu;C:/Users/gabr/Documents/Embarcadero/Studio/SDKs/ubuntu24.04.sdk/usr/lib/gcc/x86_64-linux-gnu/13;C:/Program Files (x86)/Embarcadero/Studio/37.0/lib/linux64/debug;C:/Program Files (x86)/Embarcadero/Studio/37.0/lib/linux64/release"

# Run via WSL (H: is a subst not visible to WSL, copy to /mnt/c first):
cp ./Linux64/Debug/bench_32_console /c/Temp/bench_32_console
MSYS_NO_PATHCONV=1 WSLENV= wsl -- /mnt/c/Temp/bench_32_console
```

### Android64

FMX front-end (`bench_32_mobile.dpr`, `bench_32_mobile_main.pas`,
`bench_32_mobile_main.fmx`) auto-runs on form show, streams each
result line into a `TMemo`, and also emits each line to `adb
logcat` tagged `OTL_DIAG`.

Open `bench_32_mobile.dproj` in the IDE, target Android64, build,
deploy, run. Once running:

```bash
"C:\Users\<user>\AppData\Local\Android\sdk\platform-tools\adb.exe" \
  logcat -d | grep OTL_DIAG
```

## Shared source layout

File | Role
---|---
`bench_32_shared.pas` | `TBench32Runner` class + worker procs. No VCL/FMX deps; both front-ends consume this.
`bench_32_console.dpr` | Win32 / Win64 / Linux64 console entry. Prints via `Writeln`.
`bench_32_mobile.dpr` | Android FMX entry.
`bench_32_mobile_main.pas` | FMX form; spawns a worker thread to run `RunAll`, streams results to screen + `OTL_DIAG`.
`bench_32_mobile_main.fmx` | Minimal UI (`lblStatus` + `memResults`).

Per-config timings are formatted by `TBench32Runner.LogConfigResult`
and are identical across all front-ends — one baseline table per
platform.

## Interpreting results

- **Balanced configs (`N→N`)** stress the lock-free queue's CAS
  contention. Throughput should scale gently with N up to roughly
  the core count; beyond that contention cost dominates and timings
  flatten or regress.
- **`1→7`** is bottlenecked by a single forwarder feeding seven
  consumers — readers spin endlessly hammering `TryDequeue` until
  the producer pushes an item. Expect lots of CPU, modest
  throughput.
- **`7→1`** is bottlenecked by a single reader. Producers fill the
  channel quickly; the reader dequeues serially. Channel size grows
  before being drained.

A change that improves the lock-free-queue throughput should
primarily affect the `N→N` configs (CAS contention).

## Comparison with bench_33

bench_33 wraps `TOmniBlockingCollection` (same queue underneath, plus
the wait/observer machinery for blocking `Take`); bench_32 wraps the
queue directly. Comparing the two on the same machine isolates the
overhead of the blocking-collection layer:

- bench_32 timing ≈ raw lock-free queue cost
- bench_33 timing − bench_32 timing ≈ TWaitFor + observer + atomic
  counter overhead

If bench_33 regresses but bench_32 doesn't, the change is in the
blocking layer. If both move together, the change is in the queue.

## Baseline (2026-04-26)

Captured on this machine for reference. Replace with your own after
you run the benchmark — hardware varies.

Platform | 1→1 | 2→2 | 3→3 | 4→4 | 8→8 | 1→7 | 7→1
---|---|---|---|---|---|---|---
Win64    | 178 | 186 | 243 | 261 | 377 | 292 | 273
Linux64  | 149 | 202 | 259 | 307 | 464 | 350 | 327

(average ms over 3 measured reps, 1M items per rep). Debug builds
with `-DDEBUG` and FastMM4 debug. Linux64 from a `dcclinux64` single-
step build, run on WSL2 / Ubuntu 24.04.
