unit TestOtlLogger;

///<summary>Basic coverage for the TOmniLogger in OtlLogger.pas — log+drain,
///   format-overload, Clear, StoreTimeOfDay timestamp switch, thread-ID
///   prefix, concurrent log-from-many-threads, and SaveEventList append
///   semantics.</summary>

interface

uses
  DUnitX.TestFramework,
  TestOtlBase;

type
  [TestFixture]
  TOtlLoggerTest = class(TOtlTestBase)
  public
    [Test] procedure TestLogAndGet;
    [Test] procedure TestLogFormatOverload;
    [Test] procedure TestGetDrainsQueue;
    [Test] procedure TestClear;
    [Test] procedure TestStoreTimeOfDayDefaultNumeric;
    [Test] procedure TestStoreTimeOfDayFormatted;
    [Test] procedure TestThreadIDPrefix;
    [Test] procedure TestConcurrentLog;
    [Test] procedure TestSaveEventListAppends;
    [Test] procedure TestGlobalLoggerAlive;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.RegularExpressions,
  OtlCommon,
  OtlLogger,
  OtlParallel;

const
  CTestPrefixPattern = '^\[\d+\] ';

procedure TOtlLoggerTest.TestLogAndGet;
var
  logger: TOmniLogger;
  sl    : TStringList;
begin
  logger := TOmniLogger.Create;
  try
    logger.Log('hello');
    sl := TStringList.Create;
    try
      logger.GetEventList(sl);
      Assert.AreEqual(1, sl.Count, 'expected one logged entry');
      Assert.IsTrue(sl[0].EndsWith(' hello'),
        Format('entry should end with " hello" — got: "%s"', [sl[0]]));
    finally FreeAndNil(sl); end;
  finally FreeAndNil(logger); end;
end;

procedure TOtlLoggerTest.TestLogFormatOverload;
var
  logger: TOmniLogger;
  sl    : TStringList;
begin
  logger := TOmniLogger.Create;
  try
    logger.Log('x=%d y=%s', [42, 'abc']);
    sl := TStringList.Create;
    try
      logger.GetEventList(sl);
      Assert.AreEqual(1, sl.Count);
      Assert.IsTrue(sl[0].EndsWith(' x=42 y=abc'),
        Format('entry should end with formatted body — got: "%s"', [sl[0]]));
    finally FreeAndNil(sl); end;
  finally FreeAndNil(logger); end;
end;

procedure TOtlLoggerTest.TestGetDrainsQueue;
var
  logger: TOmniLogger;
  sl    : TStringList;
begin
  logger := TOmniLogger.Create;
  try
    logger.Log('one');
    logger.Log('two');
    sl := TStringList.Create;
    try
      logger.GetEventList(sl);
      Assert.AreEqual(2, sl.Count, 'both entries retrieved on first drain');
      sl.Clear;
      logger.GetEventList(sl);
      Assert.AreEqual(0, sl.Count, 'queue should be empty after GetEventList');
    finally FreeAndNil(sl); end;
  finally FreeAndNil(logger); end;
end;

procedure TOtlLoggerTest.TestClear;
var
  logger: TOmniLogger;
  sl    : TStringList;
begin
  logger := TOmniLogger.Create;
  try
    logger.Log('one');
    logger.Log('two');
    logger.Clear;
    sl := TStringList.Create;
    try
      logger.GetEventList(sl);
      Assert.AreEqual(0, sl.Count, 'Clear should have drained all entries');
    finally FreeAndNil(sl); end;
  finally FreeAndNil(logger); end;
end;

procedure TOtlLoggerTest.TestStoreTimeOfDayDefaultNumeric;
var
  logger: TOmniLogger;
  re    : TRegEx;
  sl    : TStringList;
begin
  logger := TOmniLogger.Create;
  try
    Assert.IsFalse(logger.StoreTimeOfDay, 'StoreTimeOfDay defaults to False');
    logger.Log('numeric-ts');
    sl := TStringList.Create;
    try
      logger.GetEventList(sl);
      Assert.AreEqual(1, sl.Count);
      // Default format: "[tid] <int-ms> <msg>"
      re := TRegEx.Create('^\[\d+\] \d+ numeric-ts$');
      Assert.IsTrue(re.IsMatch(sl[0]),
        Format('numeric-ts entry did not match "[tid] <ms> msg" — got: "%s"',
          [sl[0]]));
    finally FreeAndNil(sl); end;
  finally FreeAndNil(logger); end;
end;

procedure TOtlLoggerTest.TestStoreTimeOfDayFormatted;
var
  logger: TOmniLogger;
  re    : TRegEx;
  sl    : TStringList;
begin
  logger := TOmniLogger.Create;
  try
    logger.StoreTimeOfDay := True;
    logger.Log('formatted-ts');
    sl := TStringList.Create;
    try
      logger.GetEventList(sl);
      Assert.AreEqual(1, sl.Count);
      // StoreTimeOfDay format: "[tid] yyyymmdd-hhnnsszzz msg"
      re := TRegEx.Create('^\[\d+\] \d{8}-\d{9} formatted-ts$');
      Assert.IsTrue(re.IsMatch(sl[0]),
        Format('formatted-ts entry did not match "[tid] yyyymmdd-hhnnsszzz msg" — got: "%s"',
          [sl[0]]));
    finally FreeAndNil(sl); end;
  finally FreeAndNil(logger); end;
end;

procedure TOtlLoggerTest.TestThreadIDPrefix;
var
  expected: string;
  logger  : TOmniLogger;
  sl      : TStringList;
begin
  logger := TOmniLogger.Create;
  try
    logger.Log('tid-check');
    sl := TStringList.Create;
    try
      logger.GetEventList(sl);
      Assert.AreEqual(1, sl.Count);
      expected := Format('[%d] ', [TThread.CurrentThread.ThreadID]);
      Assert.IsTrue(sl[0].StartsWith(expected),
        Format('entry should start with "%s" — got: "%s"', [expected, sl[0]]));
    finally FreeAndNil(sl); end;
  finally FreeAndNil(logger); end;
end;

procedure TOtlLoggerTest.TestConcurrentLog;
const
  CThreads       = 4;
  CLogsPerThread = 250;
var
  i     : integer;
  logger: TOmniLogger;
  sl    : TStringList;
  total : integer;
begin
  logger := TOmniLogger.Create;
  try
    Parallel.For(0, CThreads - 1).Execute(
      procedure (idx: integer)
      var
        j: integer;
      begin
        for j := 1 to CLogsPerThread do
          logger.Log('t%d-%d', [idx, j]);
      end);

    sl := TStringList.Create;
    try
      logger.GetEventList(sl);
      total := CThreads * CLogsPerThread;
      Assert.AreEqual(total, sl.Count,
        Format('expected %d concurrent entries, got %d', [total, sl.Count]));
      // Every entry carries the common "[tid] " prefix.
      for i := 0 to sl.Count - 1 do
        Assert.IsTrue(TRegEx.IsMatch(sl[i], CTestPrefixPattern),
          Format('entry #%d missing [tid] prefix — "%s"', [i, sl[i]]));
    finally FreeAndNil(sl); end;
  finally FreeAndNil(logger); end;
end;

procedure TOtlLoggerTest.TestSaveEventListAppends;
var
  fileName: string;
  logger  : TOmniLogger;
  roundSL : TStringList;
begin
  fileName := TPath.Combine(TPath.GetTempPath, 'otl_logger_test.log');
  if TFile.Exists(fileName) then
    TFile.Delete(fileName);

  // Seed file with one pre-existing line — SaveEventList must preserve it.
  roundSL := TStringList.Create;
  try
    roundSL.Add('pre-existing');
    roundSL.SaveToFile(fileName);
  finally FreeAndNil(roundSL); end;

  logger := TOmniLogger.Create;
  try
    logger.Log('appended-a');
    logger.Log('appended-b');
    logger.SaveEventList(fileName);

    // Per contract SaveEventList internally drains via GetEventList — the
    // queue is now empty.
    roundSL := TStringList.Create;
    try
      logger.GetEventList(roundSL);
      Assert.AreEqual(0, roundSL.Count,
        'SaveEventList should leave the queue empty');
    finally FreeAndNil(roundSL); end;

    roundSL := TStringList.Create;
    try
      roundSL.LoadFromFile(fileName);
      Assert.AreEqual(3, roundSL.Count, 'file should have 1 seeded + 2 appended lines');
      Assert.AreEqual('pre-existing', roundSL[0]);
      Assert.IsTrue(roundSL[1].EndsWith(' appended-a'));
      Assert.IsTrue(roundSL[2].EndsWith(' appended-b'));
    finally FreeAndNil(roundSL); end;
  finally
    FreeAndNil(logger);
    if TFile.Exists(fileName) then
      TFile.Delete(fileName);
  end;
end;

procedure TOtlLoggerTest.TestGlobalLoggerAlive;
var
  sl: TStringList;
begin
  Assert.IsNotNull(GLogger, 'GLogger must be constructed at unit init');
  GLogger.Clear;
  GLogger.Log('global');
  sl := TStringList.Create;
  try
    GLogger.GetEventList(sl);
    Assert.AreEqual(1, sl.Count);
    Assert.IsTrue(sl[0].EndsWith(' global'));
  finally FreeAndNil(sl); end;
end;

end.
