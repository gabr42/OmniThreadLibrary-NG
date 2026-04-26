///<summary>Compile-time-gated per-call instrumentation for OTL hot-path
///   profiling. No-op when <c>OTL_BENCH_PROBE</c> is not defined; safe to
///   `uses` from any unit unconditionally — the interface section is empty
///   in the off configuration so call sites that need the probe vars must
///   themselves be guarded with <c>{$IFDEF OTL_BENCH_PROBE}</c>.</summary>
///<author>Primoz Gabrijelcic</author>
///<remarks><para>
///   Creation date     : 2026-04-26
///   Last modification : 2026-04-26
///   Version           : 1.00
///</para><para>
///   History:
///     1.00: 2026-04-26
///       - Initial version. Used by TODO #2 perf investigation
///         (Linux64 vs Win64 bench_33 gap).
///</para></remarks>

unit OtlBenchProbe;

{$I OtlOptions.inc}

interface

{$IFDEF OTL_BENCH_PROBE}

uses
  System.SysUtils;

type
  TBenchProbe = record
  strict private
    FName      : string;
    FCount     : int64;
    FTotalTicks: int64;
    FMaxTicks  : int64;
  public
    procedure Init(const aName: string);
    procedure Reset;
    procedure Add(elapsedTicks: int64);
    function  Report: string;
  end;

  TProbeLogger = reference to procedure(const msg: string);

procedure ProbeStart(out start: int64); inline;
procedure ProbeStop(var probe: TBenchProbe; start: int64); inline;

procedure ResetAll;
procedure ReportAll(const log: TProbeLogger);

var
  // Wired probes — kept deliberately at outermost call sites only. Adding
  // probes inside TryAdd / TryTake (e.g. around individual atomic ops or
  // Enqueue/TryDequeue) inflates the outer measurements by 10–20% under
  // contention because each TBenchProbe.Add is itself an atomic op on
  // shared probe state. If you need finer breakdowns, switch to per-thread
  // accumulators first.
  ProbeTryAdd : TBenchProbe;
  ProbeTryTake: TBenchProbe;

{$ENDIF OTL_BENCH_PROBE}

implementation

{$IFDEF OTL_BENCH_PROBE}

uses
  System.SyncObjs,
  System.Diagnostics;

{ TBenchProbe }

procedure TBenchProbe.Init(const aName: string);
begin
  FName := aName;
  Reset;
end;

procedure TBenchProbe.Reset;
begin
  FCount      := 0;
  FTotalTicks := 0;
  FMaxTicks   := 0;
end;

procedure TBenchProbe.Add(elapsedTicks: int64);
var
  prev: int64;
begin
  TInterlocked.Increment(FCount);
  TInterlocked.Add(FTotalTicks, elapsedTicks);
  // Lock-free max update
  repeat
    prev := FMaxTicks;
    if elapsedTicks <= prev then Exit;
  until TInterlocked.CompareExchange(FMaxTicks, elapsedTicks, prev) = prev;
end;

function TBenchProbe.Report: string;
var
  freq : int64;
  avgNs: double;
  maxNs: double;
  totMs: double;
begin
  freq := TStopwatch.Frequency;
  if (FCount = 0) or (freq = 0) then
    Exit(Format('  %-22s count=%-12d (no samples)', [FName, FCount]));
  avgNs := (FTotalTicks * 1.0e9 / freq) / FCount;
  maxNs := FMaxTicks * 1.0e9 / freq;
  totMs := FTotalTicks * 1000.0 / freq;
  Result := Format(
    '  %-22s count=%-12d  avg=%9.0f ns  max=%10.0f ns  total=%9.1f ms',
    [FName, FCount, avgNs, maxNs, totMs]);
end;

{ unit-level }

procedure ProbeStart(out start: int64);
begin
  start := TStopwatch.GetTimeStamp;
end;

procedure ProbeStop(var probe: TBenchProbe; start: int64);
begin
  probe.Add(TStopwatch.GetTimeStamp - start);
end;

procedure ResetAll;
begin
  ProbeTryAdd.Reset;
  ProbeTryTake.Reset;
end;

procedure ReportAll(const log: TProbeLogger);
begin
  log('--- OTL bench probes ---');
  log(ProbeTryAdd.Report);
  log(ProbeTryTake.Report);
end;

initialization
  ProbeTryAdd.Init('TryAdd');
  ProbeTryTake.Init('TryTake');

{$ENDIF OTL_BENCH_PROBE}

end.
