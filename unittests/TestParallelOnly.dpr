program TestParallelOnly;

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.AutoDetect.Console,
  DUnitX.TestFramework,
  TestOtlParallel in 'TestOtlParallel.pas';

var
  runner : ITestRunner;
  results: IRunResults;
  logger : ITestLogger;
begin
  try
    TDUnitX.CheckCommandLine;
    runner := TDUnitX.CreateRunner;
    runner.UseRTTI := True;
    logger := TDUnitXConsoleLogger.Create(true);
    runner.AddLogger(logger);
    results := runner.Execute;
    if not results.AllPassed then
      System.ExitCode := EXIT_ERRORS;
  except
    on E: Exception do
      System.Writeln(E.ClassName, ': ', E.Message);
  end;
end.
