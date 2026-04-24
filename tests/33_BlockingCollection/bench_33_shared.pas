unit bench_33_shared;

// Headless benchmark for TOmniBlockingCollection. Mirrors the GUI test in
// test_33_BlockingCollection.pas, but:
//   - focuses on the blocking .Take path (no .TryTake branch, no
//     IsFinalized polling, no per-exception paths);
//   - runs a fixed set of producer/consumer configurations back-to-back,
//     reports per-rep and aggregate timings;
//   - has no VCL dependencies — the same unit drives the console app on
//     Win32 / Win64 / Linux64 and the FMX app on Android64.

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
  OtlCollections;

type
  TBenchLogger = reference to procedure(const msg: string);

  TBench33Config = record
    Forwarders: integer;
    Readers   : integer;
    constructor Create(aForwarders, aReaders: integer);
    function Label_: string;
  end;

  TBench33Runner = class
  public
    const
      CItemCount      = 1000000;
      CWarmupReps     =  1;
      CMeasuredReps   =  3;
      CWaitTimeout_ms = 300000; // 5 minutes — bench should finish long before
  strict private
    procedure RunOnce(numForwarders, numReaders: integer; out elapsed_ms: int64);
    procedure LogConfigResult(const log: TBenchLogger;
      const cfg: TBench33Config; const runs_ms: TArray<int64>);
  public
    class function Configs: TArray<TBench33Config>; static;
    procedure RunAll(const log: TBenchLogger);
  end;

implementation

{ TBench33Config }

constructor TBench33Config.Create(aForwarders, aReaders: integer);
begin
  Forwarders := aForwarders;
  Readers    := aReaders;
end;

function TBench33Config.Label_: string;
begin
  Result := Format('%d->%d', [Forwarders, Readers]);
end;

{ TBench33Runner }

class function TBench33Runner.Configs: TArray<TBench33Config>;
begin
  // Order matches the GUI test's buttons: symmetric configs first, then
  // the 1→7 / 7→1 asymmetric ones that stress the producer-few-consumers-
  // many and consumers-few-producers-many paths.
  Result := [
    TBench33Config.Create(1, 1),
    TBench33Config.Create(2, 2),
    TBench33Config.Create(3, 3),
    TBench33Config.Create(4, 4),
    TBench33Config.Create(8, 8),
    TBench33Config.Create(1, 7),
    TBench33Config.Create(7, 1)
  ];
end;

// Shared atomic counters and stop flags. The GUI test uses unit-level
// globals of the same shape; we reset them at the start of every RunOnce
// so successive configurations do not pollute each other.
var
  GForwardersCount: TOmniAlignedInt32;
  GReadersCount   : TOmniAlignedInt32;

procedure ForwarderWorker(const task: IOmniTask);
var
  chanColl: TOmniBlockingCollection;
  srcColl : TOmniBlockingCollection;
  value   : TOmniValue;
begin
  value   := task.Param['Source'];  srcColl  := TOmniBlockingCollection(value.AsObject);
  value   := task.Param['Channel']; chanColl := TOmniBlockingCollection(value.AsObject);
  while srcColl.Take(value) do begin
    chanColl.Add(value);
    if GForwardersCount.Increment = TBench33Runner.CItemCount then begin
      chanColl.CompleteAdding;
      Exit;
    end;
  end;
end;

procedure ReaderWorker(const task: IOmniTask);
var
  chanColl: TOmniBlockingCollection;
  dstColl : TOmniBlockingCollection;
  value   : TOmniValue;
begin
  value   := task.Param['Channel'];     chanColl := TOmniBlockingCollection(value.AsObject);
  value   := task.Param['Destination']; dstColl  := TOmniBlockingCollection(value.AsObject);
  while chanColl.Take(value) do begin
    dstColl.Add(value);
    if GReadersCount.Increment = TBench33Runner.CItemCount then begin
      dstColl.CompleteAdding;
      Exit;
    end;
  end;
end;

procedure TBench33Runner.RunOnce(numForwarders, numReaders: integer; out elapsed_ms: int64);
var
  chanColl  : TOmniBlockingCollection;
  dstColl   : TOmniBlockingCollection;
  forwarders: array of IOmniTaskControl;
  i         : integer;
  readers   : array of IOmniTaskControl;
  srcColl   : TOmniBlockingCollection;
  sw        : TStopwatch;
  value     : TOmniValue;
  verified  : integer;
begin
  GForwardersCount.Value := 0;
  GReadersCount.Value    := 0;

  srcColl  := TOmniBlockingCollection.Create;
  chanColl := TOmniBlockingCollection.Create;
  dstColl  := TOmniBlockingCollection.Create;
  try
    // Seed the source collection. We measure the producer→consumer
    // pipeline only; fill time is not counted.
    for i := 1 to CItemCount do
      srcColl.Add(i);
    srcColl.CompleteAdding;

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

    // Wait for all workers to observe CompleteAdding and exit.
    for i := 0 to High(forwarders) do
      if not forwarders[i].WaitFor(CWaitTimeout_ms) then
        raise Exception.CreateFmt(
          'Forwarder %d did not finish within %d ms', [i, CWaitTimeout_ms]);
    for i := 0 to High(readers) do
      if not readers[i].WaitFor(CWaitTimeout_ms) then
        raise Exception.CreateFmt(
          'Reader %d did not finish within %d ms', [i, CWaitTimeout_ms]);

    elapsed_ms := sw.ElapsedMilliseconds;

    // Lightweight correctness check: the destination collection should
    // hold exactly CItemCount items. We don't verify order because
    // multiple forwarders/readers interleave writes. A miscount would
    // invalidate the timing.
    verified := 0;
    while dstColl.Take(value) do
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

procedure TBench33Runner.LogConfigResult(const log: TBenchLogger;
  const cfg: TBench33Config; const runs_ms: TArray<int64>);
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

procedure TBench33Runner.RunAll(const log: TBenchLogger);
var
  cfg      : TBench33Config;
  elapsed  : int64;
  i        : integer;
  runs_ms  : TArray<int64>;
  totalSW  : TStopwatch;
begin
  log(Format(
    'TOmniBlockingCollection benchmark: %d items, %d warm-up + %d measured reps',
    [CItemCount, CWarmupReps, CMeasuredReps]));
  log('');

  totalSW := TStopwatch.StartNew;
  for cfg in Configs do begin
    // Warm-up runs — JIT / cache / pool-startup effects. Results discarded.
    for i := 1 to CWarmupReps do
      RunOnce(cfg.Forwarders, cfg.Readers, elapsed);

    SetLength(runs_ms, CMeasuredReps);
    for i := 0 to CMeasuredReps - 1 do begin
      RunOnce(cfg.Forwarders, cfg.Readers, elapsed);
      runs_ms[i] := elapsed;
    end;

    LogConfigResult(log, cfg, runs_ms);
  end;

  log('');
  log(Format('Total benchmark runtime: %d ms', [totalSW.ElapsedMilliseconds]));
end;

end.
