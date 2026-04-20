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
  , TestOtlBase in 'TestOtlBase.pas'
  , SmokeTest in 'SmokeTest.pas'
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
  , TestChannel1 in 'TestChannel1.pas'
  , TestSelect1 in 'TestSelect1.pas'
  , TestMergeRace1 in 'TestMergeRace1.pas'
  , TestHooks1 in 'TestHooks1.pas'
  , TestTask in 'TestTask.pas'
  , TestOtlParallel in 'TestOtlParallel.pas'
  , TestUnobserved in 'TestUnobserved.pas'
  , TestOtlThreadPool1 in 'TestOtlThreadPool1.pas'
  , TestOtlEventMonitor1 in 'TestOtlEventMonitor1.pas'
  , TestStressBlockingCollection1 in 'TestStressBlockingCollection1.pas'
  , TestStressOtlSync1 in 'TestStressOtlSync1.pas'
  ;

{$IFNDEF TESTINSIGHT}
var
  runner : ITestRunner;
  results: IRunResults;
  logger : ITestLogger;

function HasAnyDUnitXFilterSwitch: boolean;
// Returns True if the command line contains any DUnitX filter flag
// (--run, --runlist, --include, --exclude, or their short forms).
// System.SysUtils.FindCmdLineSwitch only strips a single '-' or '/',
// so it misses DUnitX's double-dash form (`--include:Stress`).
const
  CFilters: array[0..7] of string = (
    'run', 'r', 'runlist', 'rl', 'include', 'i', 'exclude', 'e');
var
  body: string;
  colonPos: integer;
  filter: string;
  iParam: integer;
  param: string;
begin
  for iParam := 1 to ParamCount do begin
    param := ParamStr(iParam);
    if (param = '') or (not CharInSet(param[1], ['-', '/'])) then
      continue;
    body := param.Substring(1);
    if body.StartsWith('-') then
      body := body.Substring(1);
    colonPos := Pos(':', body);
    if colonPos > 0 then
      body := Copy(body, 1, colonPos - 1);
    for filter in CFilters do
      if SameText(body, filter) then
        Exit(True);
  end;
  Result := False;
end;
{$ENDIF}
begin
{$IFDEF TESTINSIGHT}
  TestInsight.DUnitX.RunRegisteredTests;
{$ELSE}
  try
    // Default-exclude the Stress category so the standard run stays fast.
    // Any explicit filter flag (--run/--runlist/--include/--exclude or their
    // short forms) bypasses the default — otherwise the filter would AND with
    // it and still drop stress tests the caller asked for.
    if not HasAnyDUnitXFilterSwitch then
      TDUnitX.Options.Exclude := 'Stress';
    TDUnitX.CheckCommandLine;
    runner := TDUnitX.CreateRunner;
    runner.UseRTTI := True;
    logger := TDUnitXConsoleLogger.Create(false);
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
