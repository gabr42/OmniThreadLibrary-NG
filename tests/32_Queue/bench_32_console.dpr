///<summary>Console benchmark for TOmniBaseQueue (Win32 / Win64 /
///   Linux64). FMX variant lives in bench_32_mobile.dpr for Android64.
///   Runs the fixed N-forwarder x M-reader configurations defined in
///   bench_32_shared.pas and prints per-config avg/min/max ms.</summary>

program bench_32_console;

{$APPTYPE CONSOLE}

{$I OtlOptions.inc}

uses
  {$IFDEF MSWINDOWS}FastMM4,{$ENDIF}
  System.SysUtils,
  {$IFDEF OTL_BENCH_PROBE}OtlBenchProbe,{$ENDIF}
  bench_32_shared in 'bench_32_shared.pas';

procedure PrintPlatform;
begin
  Writeln(Format('Platform : %s (%d-bit)',
    [{$IF Defined(MSWINDOWS)}'Windows'{$ELSEIF Defined(LINUX)}'Linux'
      {$ELSEIF Defined(MACOS)}'macOS'{$ELSE}'Other'{$ENDIF},
     SizeOf(NativeInt) * 8]));
  Writeln;
end;

procedure Run;
var
  runner: TBench32Runner;
  log   : TBenchLogger;
{$IFDEF OTL_BENCH_PROBE}
  onCfgBegin: TBenchConfigHook;
  onCfgEnd  : TBenchConfigHook;
{$ENDIF}
begin
  log :=
    procedure(const msg: string)
    begin
      Writeln(msg);
      Flush(Output); // Linux RTL block-buffers stdout when redirected
    end;
  runner := TBench32Runner.Create;
  try
    PrintPlatform;
    {$IFDEF OTL_BENCH_PROBE}
    onCfgBegin := procedure(const _log: TBenchLogger)
                  begin OtlBenchProbe.ResetAll; end;
    onCfgEnd   := procedure(const _log: TBenchLogger)
                  begin OtlBenchProbe.ReportAll(_log); _log(''); end;
    runner.RunAll(log, onCfgBegin, onCfgEnd);
    {$ELSE}
    runner.RunAll(log);
    {$ENDIF}
  finally FreeAndNil(runner); end;
end;

begin
  try
    Run;
  except
    on E: Exception do begin
      Writeln('Error: ', E.ClassName, ': ', E.Message);
      Flush(Output);
      ExitCode := 1;
    end;
  end;
end.
