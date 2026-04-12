program ConsoleTestRunner;

{$IFNDEF TESTINSIGHT}
{$APPTYPE CONSOLE}
{$ENDIF}
{$STRONGLINKTYPES ON}

{$DEFINE CONSOLE_TESTRUNNER}

uses
  System.SysUtils,
  {$IFDEF TESTINSIGHT}
  TestInsight.DUnitX,
  {$ELSE}
  DUnitX.Loggers.Console,
  DUnitX.AutoDetect.Console,
  {$ENDIF }
  DUnitX.TestFramework
//  {$IFDEF MSWindows}, SmokeTest in 'SmokeTest.pas'{$ENDIF }
  , TestRegressions in 'TestRegressions.pas'
  , TestBlockingCollection1 in 'TestBlockingCollection1.pas'
  , TestOtlDataManager1 in 'TestOtlDataManager1.pas'
  , TestOmniInterfaceDictionary in 'TestOmniInterfaceDictionary.pas'
  , TestOmniValue in 'TestOmniValue.pas'
  , TestValue in 'TestValue.pas'
  , TestPlatform in 'TestPlatform.pas'
  , TestInterlocked in 'TestInterlocked.pas'
  , TestContainers in 'TestContainers.pas'
  , TestOtlComm in 'TestOtlComm.pas'
  , TestOtlSync1 in 'TestOtlSync1.pas'
  , TestOtlCommon1 in 'TestOtlCommon1.pas'
  , TestContainerObserver1 in 'TestContainerObserver1.pas'
  , TestSyncUtils1 in 'TestSyncUtils1.pas'
  , TestBackgroundObserver1 in 'TestBackgroundObserver1.pas'
//  {$IFDEF MSWindows}, TestTask in 'TestTask.pas'{$ENDIF }
//  {$IFDEF MSWindows}, TestOtlParallel in 'TestOtlParallel.pas'{$ENDIF }
  ;

{$IFNDEF TESTINSIGHT}
var
  runner : ITestRunner;
  results: IRunResults;
  logger : ITestLogger;
{$ENDIF}
begin
{$IFDEF TESTINSIGHT}
  TestInsight.DUnitX.RunRegisteredTests;
{$ELSE}
  try
    TDUnitX.CheckCommandLine;
    runner := TDUnitX.CreateRunner;
    runner.UseRTTI := True;
    logger := TDUnitXConsoleLogger.Create(true);
    runner.AddLogger(logger);
    results := runner.Execute;
    if not results.AllPassed then
      System.ExitCode := EXIT_ERRORS;
    {$WARN SYMBOL_PLATFORM OFF}
    if DebugHook <> 0 then begin
      Write('> ');
      Readln;
    end;
    {$WARN SYMBOL_PLATFORM ON}
  except
    on E: Exception do
      System.Writeln(E.ClassName, ': ', E.Message);
  end;
{$ENDIF}
end.
