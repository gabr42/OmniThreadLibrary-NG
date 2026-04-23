# bench_pingpong — OTL comm ping-pong benchmark

Mirrors `tests/09_Communications` but runs as a console app so the
same workload can be timed on Windows, Linux, and other platforms
where a GUI is inconvenient. Two worker tasks share a bounded
`TOmniTwoWayChannel`; each rep runs a one-way dump of 10,000 messages
and a 10,000-round `MSG_REQ`/`MSG_ACK` ping-pong, repeated 10× each.
Reports per-rep timings so Windows fast-path vs POSIX slow-path can be
compared directly.

## Build and run

### Win32 / Win64

```bash
cd benchmarks/comm_pingpong
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcc32.exe" ^
  bench_pingpong.dpr -B "-U../..;../../FastMM4" ^
  "-NSSystem;System.Win;Winapi" -DDEBUG ^
  -E"./Win32/Debug" -NU"./Win32/Debug"
./Win32/Debug/bench_pingpong.exe
```

Swap `dcc32` → `dcc64` and `Win32` → `Win64` for 64-bit.

### Linux64

Same manual-link workflow as `unittests/ConsoleTestRunner` —
`dcclinux64` emits `.o` files, then the link is done with WSL's
native `ld` against the Delphi-provided object archive. A
`bench_pingpong.lnk` derived from the unit tests' `.lnk` (minus
DUnitX, `SmokeTest`, `OtlLogger`, `OtlParallel`, `OtlDataManager`,
`OtlSync.Utils`, `OtlCollections`, and `Test*.o`, with paths
redirected to `benchmarks/comm_pingpong/Linux64/Debug/`) plus a
linker script with entry point
`_ZN14Bench_pingpong14initializationEv` are the only bench-specific
pieces.

## Output format

```
Benchmark: CTestQueueLength=10000, reps=10
Platform : <platform> (64-bit)

Total runtime: <total> ms

Dump (10000 one-way)         count=10  sum=<s> ms  avg=<a> ms  min=<mn> ms  max=<mx> ms
                             values=[t1,t2,...,t10]

MsgExchange (10000 r/t)      count=10  sum=<s> ms  avg=<a> ms  min=<mn> ms  max=<mx> ms
                             values=[t1,t2,...,t10]
```

## Timings

| Platform | Total | MsgEx avg | MsgEx min | MsgEx max |
|---|---|---|---|---|
| Win32    | 2.15 s | 197 ms | 176 ms | 234 ms |
| Win64    | 2.00 s | 181 ms | 160 ms | 267 ms |
| Linux64  | 4.21 s | 345 ms | 333 ms | 353 ms |

Linux64 is still ~2× slower than Windows — the CV + observer path
on POSIX has fundamental per-signal kernel-transition cost that the
direct `WaitForMultipleObjects` fast path avoids on Windows.
