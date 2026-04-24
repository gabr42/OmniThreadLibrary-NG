///<summary>Console benchmark for TOmniBlockingCollection (Win32 / Win64 /
///   Linux64). FMX variant lives in bench_33_mobile.dpr for Android64.
///   Runs the fixed N-forwarder × M-reader Take-path configurations defined
///   in bench_33_shared.pas and prints per-config avg/min/max ms.</summary>

program bench_33_console;

{$APPTYPE CONSOLE}

uses
  {$IFDEF MSWINDOWS}FastMM4,{$ENDIF}
  System.SysUtils,
  bench_33_shared in 'bench_33_shared.pas';

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
  runner: TBench33Runner;
begin
  runner := TBench33Runner.Create;
  try
    PrintPlatform;
    runner.RunAll(
      procedure(const msg: string)
      begin
        Writeln(msg);
      end);
  finally FreeAndNil(runner); end;
end;

begin
  try
    Run;
  except
    on E: Exception do begin
      Writeln('Error: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
