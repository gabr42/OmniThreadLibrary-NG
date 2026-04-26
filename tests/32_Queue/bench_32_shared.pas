unit bench_32_shared;

// Headless benchmark for TOmniBaseQueue (the lock-free queue at the
// bottom of the OTL container stack). Mirrors the GUI test in
// test_32_Queue.pas, but:
//   - removes the optional IsEmpty-probe path (always off — that
//     branch is correctness instrumentation, not throughput);
//   - removes the IOmniCounter / interface-payload variant (numeric
//     payload only — same shape as test_32's threaded path);
//   - runs a fixed set of forwarder/reader configurations back-to-
//     back, reports per-rep and aggregate timings;
//   - has no VCL dependencies — the same unit drives the console
//     app on Win32 / Win64 / Linux64 and the FMX app on Android64.
//
// Differences from bench_33_shared:
//   - bench_33 wraps TOmniBlockingCollection (blocking Take). When
//     the queue runs dry, consumers block via TWaitFor.WaitAny.
//   - bench_32 wraps TOmniBaseQueue directly (non-blocking
//     TryDequeue). When the queue runs dry, consumers spin in a
//     tight loop. CPU stays at 100% on every worker until the
//     stop counter fires — this is by design; what we measure is
//     raw lock-free queue throughput under contention, not the
//     blocking-collection wait path.

interface

uses
  System.SysUtils,
  System.Classes,
  System.Diagnostics,
  System.Generics.Collections,
  OtlCommon,
  OtlTask,
  OtlTaskControl,
  OtlSync,
  OtlContainers;

type
  TBenchLogger = reference to procedure(const msg: string);
  TBenchConfigHook = reference to procedure(const log: TBenchLogger);

  TBench32Config = record
    Forwarders: integer;
    Readers   : integer;
    constructor Create(aForwarders, aReaders: integer);
    function Label_: string;
  end;

  TBench32Runner = class
  public
    const
      CItemCount      = 1000000;
      CWarmupReps     =  1;
      CMeasuredReps   =  3;
      // Generous per-task WaitFor budget — same as bench_33. The 1→7
      // / 7→1 configs in particular can take a long time on slower
      // ARM cores when one side is lopsided. 15 min gives ample
      // headroom for x86_64 finishing in seconds and older ARM64
      // hardware finishing in minutes.
      CWaitTimeout_ms = 900000;
  strict private
    procedure RunOnce(numForwarders, numReaders: integer; out elapsed_ms: int64);
    procedure LogConfigResult(const log: TBenchLogger;
      const cfg: TBench32Config; const runs_ms: TArray<int64>);
  public
    class function Configs: TArray<TBench32Config>; static;
    procedure RunAll(const log: TBenchLogger; const onConfigBegin: TBenchConfigHook = nil;
      const onConfigEnd: TBenchConfigHook = nil);
  end;

implementation

{ TBench32Config }

constructor TBench32Config.Create(aForwarders, aReaders: integer);
begin
  Forwarders := aForwarders;
  Readers    := aReaders;
end;

function TBench32Config.Label_: string;
begin
  Result := Format('%d->%d', [Forwarders, Readers]);
end;

{ TBench32Runner }

class function TBench32Runner.Configs: TArray<TBench32Config>;
begin
  // Same shape as bench_33 — symmetric configs first, then the
  // 1→7 / 7→1 asymmetric ones that stress fan-out and fan-in.
  Result := [
    TBench32Config.Create(1, 1),
    TBench32Config.Create(2, 2),
    TBench32Config.Create(3, 3),
    TBench32Config.Create(4, 4),
    TBench32Config.Create(8, 8),
    TBench32Config.Create(1, 7),
    TBench32Config.Create(7, 1)
  ];
end;

// Shared atomic counters and stop flags. Equivalent to the unit-level
// globals in test_32_Queue.pas (GForwardersCount / GReadersCount /
// GStopForwarders / GStopReaders); reset at the start of every
// RunOnce so successive configs do not pollute each other.
var
  GForwardersCount: TOmniAlignedInt32;
  GReadersCount   : TOmniAlignedInt32;
  GStopForwarders : boolean;
  GStopReaders    : boolean;

// Forwarder / reader worker loops.
//
// Mirrors the threaded path of test_32_Queue.pas (no IsEmpty-probe
// branch, no MSG_START rendezvous — workers start as soon as the
// task is Run; the bench's TStopwatch measures wall time around the
// CreateTask spawns and the per-task WaitFors).
//
// The outer `while not GStopX` loop and the inner `while TryDequeue`
// loop spin without sleeping. When the queue runs dry, TryDequeue
// returns false immediately and the outer flag is rechecked. CPU
// stays pegged on every worker until the stop counter fires.
procedure ForwarderWorker(const task: IOmniTask);
var
  chanColl: TOmniBaseQueue;
  srcColl : TOmniBaseQueue;
  value   : TOmniValue;
begin
  value    := task.Param['Source'];  srcColl  := TOmniBaseQueue(value.AsObject);
  value    := task.Param['Channel']; chanColl := TOmniBaseQueue(value.AsObject);
  while not GStopForwarders do
    while srcColl.TryDequeue(value) do begin
      chanColl.Enqueue(value);
      if GForwardersCount.Increment = TBench32Runner.CItemCount then begin
        GStopForwarders := true;
        Exit;
      end;
    end;
end;

procedure ReaderWorker(const task: IOmniTask);
var
  chanColl: TOmniBaseQueue;
  dstColl : TOmniBaseQueue;
  value   : TOmniValue;
begin
  value    := task.Param['Channel'];     chanColl := TOmniBaseQueue(value.AsObject);
  value    := task.Param['Destination']; dstColl  := TOmniBaseQueue(value.AsObject);
  while not GStopReaders do
    while chanColl.TryDequeue(value) do begin
      dstColl.Enqueue(value);
      if GReadersCount.Increment = TBench32Runner.CItemCount then begin
        GStopReaders := true;
        Exit;
      end;
    end;
end;

procedure TBench32Runner.RunOnce(numForwarders, numReaders: integer; out elapsed_ms: int64);
var
  chanColl  : TOmniBaseQueue;
  dstColl   : TOmniBaseQueue;
  forwarders: array of IOmniTaskControl;
  i         : integer;
  readers   : array of IOmniTaskControl;
  srcColl   : TOmniBaseQueue;
  sw        : TStopwatch;
  value     : TOmniValue;
  verified  : integer;
begin
  GForwardersCount.Value := 0;
  GReadersCount.Value    := 0;
  GStopForwarders        := false;
  GStopReaders           := false;

  // Default block size + cached-blocks count from TOmniBaseQueue
  // (65536 / 4). test_32_Queue.pas exposes a UI knob; the bench
  // pins them at the defaults so timing comparisons are stable.
  srcColl  := TOmniBaseQueue.Create;
  chanColl := TOmniBaseQueue.Create;
  dstColl  := TOmniBaseQueue.Create;
  try
    // Seed the source collection. Fill time is not counted.
    for i := 1 to CItemCount do
      srcColl.Enqueue(i);

    sw := TStopwatch.StartNew;

    SetLength(forwarders, numForwarders);
    for i := 0 to numForwarders - 1 do
      forwarders[i] := CreateTask(ForwarderWorker, Format('Forwarder %d', [i]))
                       .SetParameter('Source',  srcColl)
                       .SetParameter('Channel', chanColl)
                       .Unobserved
                       .Run;

    SetLength(readers, numReaders);
    for i := 0 to numReaders - 1 do
      readers[i] := CreateTask(ReaderWorker, Format('Reader %d', [i]))
                    .SetParameter('Channel',     chanColl)
                    .SetParameter('Destination', dstColl)
                    .Unobserved
                    .Run;

    // Wait for all workers to observe the stop flag and exit.
    for i := 0 to High(forwarders) do
      if not forwarders[i].WaitFor(CWaitTimeout_ms) then
        raise Exception.CreateFmt(
          'Forwarder %d did not finish within %d ms', [i, CWaitTimeout_ms]);
    for i := 0 to High(readers) do
      if not readers[i].WaitFor(CWaitTimeout_ms) then
        raise Exception.CreateFmt(
          'Reader %d did not finish within %d ms', [i, CWaitTimeout_ms]);

    elapsed_ms := sw.ElapsedMilliseconds;

    // Lightweight correctness check: the destination collection
    // should hold exactly CItemCount items. We don't verify order
    // because multiple forwarders/readers interleave writes. A
    // miscount would invalidate the timing.
    verified := 0;
    while dstColl.TryDequeue(value) do
      Inc(verified);
    if verified <> CItemCount then
      raise Exception.CreateFmt(
        'Bench verification failed: expected %d items in destination, got %d',
        [CItemCount, verified]);
  finally
    FreeAndNil(srcColl);
    FreeAndNil(chanColl);
    FreeAndNil(dstColl);
  end;
end;

procedure TBench32Runner.LogConfigResult(const log: TBenchLogger;
  const cfg: TBench32Config; const runs_ms: TArray<int64>);
var
  avg   : double;
  joined: string;
  i     : integer;
  maxVal: int64;
  minVal: int64;
  sum   : int64;
begin
  if Length(runs_ms) = 0 then begin
    log(Format('%s: no samples', [cfg.Label_]));
    Exit;
  end;
  sum    := 0;
  minVal := runs_ms[0];
  maxVal := runs_ms[0];
  joined := '';
  for i := 0 to High(runs_ms) do begin
    sum := sum + runs_ms[i];
    if runs_ms[i] < minVal then minVal := runs_ms[i];
    if runs_ms[i] > maxVal then maxVal := runs_ms[i];
    if i > 0 then joined := joined + ',';
    joined := joined + IntToStr(runs_ms[i]);
  end;
  avg := sum / Length(runs_ms);
  log(Format('%-7s avg=%7.1f ms  min=%5d ms  max=%5d ms  runs=[%s]',
    [cfg.Label_, avg, minVal, maxVal, joined]));
end;

procedure TBench32Runner.RunAll(const log: TBenchLogger; const onConfigBegin: TBenchConfigHook;
  const onConfigEnd: TBenchConfigHook);
var
  cfg      : TBench32Config;
  elapsed  : int64;
  i        : integer;
  runs_ms  : TArray<int64>;
  totalSW  : TStopwatch;
begin
  log(Format(
    'TOmniBaseQueue benchmark: %d items, %d warm-up + %d measured reps',
    [CItemCount, CWarmupReps, CMeasuredReps]));
  log('');

  totalSW := TStopwatch.StartNew;
  for cfg in Configs do begin
    if assigned(onConfigBegin) then
      onConfigBegin(log);

    // Warm-up runs — JIT / cache / pool-startup effects. Results discarded.
    for i := 1 to CWarmupReps do
      RunOnce(cfg.Forwarders, cfg.Readers, elapsed);

    SetLength(runs_ms, CMeasuredReps);
    for i := 0 to CMeasuredReps - 1 do begin
      RunOnce(cfg.Forwarders, cfg.Readers, elapsed);
      runs_ms[i] := elapsed;
    end;

    LogConfigResult(log, cfg, runs_ms);

    if assigned(onConfigEnd) then
      onConfigEnd(log);
  end;

  log('');
  log(Format('Total benchmark runtime: %d ms', [totalSW.ElapsedMilliseconds]));
end;

end.
