///<summary>Cross-platform comm ping-pong benchmark.
///   Mirrors tests/09_Communications: dump-N-messages and ping-pong
///   MSG_REQ/MSG_ACK exchange between two worker tasks sharing a
///   TOmniTwoWayChannel. Reports per-rep and aggregate timings so
///   Windows and POSIX paths can be compared directly.</summary>

program bench_pingpong;

{$APPTYPE CONSOLE}

uses
  {$IFDEF MSWINDOWS}FastMM4,{$ENDIF}
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.SyncObjs,
  System.Diagnostics,
  OtlSync,
  OtlTask,
  OtlTaskControl,
  OtlComm,
  OtlCommon;

const
  CTestQueueLength = 10000;
  CNumReps         = 10;
  CWaitTimeout_ms  = 300000; // 5 minutes; the benchmark should finish long before

  // Message IDs. Same layout as test_9 so the protocol is
  // literally identical end-to-end.
  MSG_START_TEST      = 1;
  MSG_NOTIFY_TEST_END = 3;
  MSG_START_TIMING    = 100;
  MSG_END_TIMING      = 101;
  MSG_DUMP_TEST       = 102;
  MSG_REQ             = 103;
  MSG_ACK             = 104;

type
  TTestSuite = (tsDump, tsMessageExchange);

var
  GDoneEvent     : IOmniEvent;
  GResultLock    : TCriticalSection;
  GDumpTimes_ms  : TList<int64>;
  GMsgExTimes_ms : TList<int64>;

type
  TBenchWorker = class(TOmniWorker)
  strict private
    ctComm          : IOmniCommunicationEndpoint;
    ctCommSize      : integer;
    ctExpectedValue : integer;
    ctTestRepetition: integer;
    ctStopwatch     : TStopwatch;
    ctTestSuite     : TTestSuite;
    procedure InitiateMessageExchangeTest;
  strict protected
    procedure InitiateDumpTest;
    procedure RunDumpTest;
    procedure RunMessageExchangeTest;
  public
    constructor Create(commEndpoint: IOmniCommunicationEndpoint; commBufferSize: integer);
    function  Initialize: boolean; override;
    procedure OMAck(var msg: TOmniMessage); message MSG_ACK;
    procedure OMDumpTest(var msg: TOmniMessage); message MSG_DUMP_TEST;
    procedure OMEndTiming(var msg: TOmniMessage); message MSG_END_TIMING;
    procedure OMNotifyTestEnd(var msg: TOmniMessage); message MSG_NOTIFY_TEST_END;
    procedure OMReq(var msg: TOmniMessage); message MSG_REQ;
    procedure OMStartTest(var msg: TOmniMessage); message MSG_START_TEST;
    procedure OMStartTiming(var msg: TOmniMessage); message MSG_START_TIMING;
  end;

{ TBenchWorker }

constructor TBenchWorker.Create(commEndpoint: IOmniCommunicationEndpoint;
  commBufferSize: integer);
begin
  inherited Create;
  ctComm := commEndpoint;
  ctCommSize := commBufferSize;
end;

function TBenchWorker.Initialize: boolean;
begin
  Task.RegisterComm(ctComm);
  Result := true;
end;

procedure TBenchWorker.InitiateDumpTest;
begin
  ctTestSuite := tsDump;
  ctTestRepetition := 1;
  RunDumpTest;
end;

procedure TBenchWorker.InitiateMessageExchangeTest;
begin
  ctTestSuite := tsMessageExchange;
  ctTestRepetition := 1;
  RunMessageExchangeTest;
end;

procedure TBenchWorker.OMAck(var msg: TOmniMessage);
begin
  if msg.MsgData.AsInteger < ctCommSize then
    ctComm.Send(MSG_REQ, msg.MsgData.AsInteger + 1)
  else
    ctComm.Send(MSG_END_TIMING, 0);
end;

procedure TBenchWorker.OMDumpTest(var msg: TOmniMessage);
begin
  Assert(ctTestSuite = tsDump);
  if msg.MsgData.AsInteger <> ctExpectedValue then
    raise Exception.CreateFmt('Invalid value received (%d, expected %d)',
      [msg.MsgData.AsInteger, ctExpectedValue]);
  Inc(ctExpectedValue);
end;

procedure TBenchWorker.OMEndTiming(var msg: TOmniMessage);
var
  testDuration_ms: int64;
begin
  testDuration_ms := ctStopwatch.ElapsedMilliseconds;
  GResultLock.Acquire;
  try
    if ctTestSuite = tsDump then
      GDumpTimes_ms.Add(testDuration_ms)
    else
      GMsgExTimes_ms.Add(testDuration_ms);
  finally GResultLock.Release; end;
  ctComm.Send(MSG_NOTIFY_TEST_END, Ord(ctTestSuite));
end;

procedure TBenchWorker.OMNotifyTestEnd(var msg: TOmniMessage);
begin
  Assert(TTestSuite(msg.MsgData.AsInteger) = ctTestSuite);
  if ctTestSuite = tsMessageExchange then begin
    Inc(ctTestRepetition);
    if ctTestRepetition <= CNumReps then
      RunMessageExchangeTest
    else
      GDoneEvent.SetEvent;
  end
  else if ctTestSuite = tsDump then begin
    Inc(ctTestRepetition);
    if ctTestRepetition <= CNumReps then
      RunDumpTest
    else
      InitiateMessageExchangeTest;
  end;
end;

procedure TBenchWorker.OMReq(var msg: TOmniMessage);
begin
  Assert(ctTestSuite = tsMessageExchange);
  if msg.MsgData.AsInteger <> ctExpectedValue then
    raise Exception.CreateFmt('Invalid value received (%d, expected %d)',
      [msg.MsgData.AsInteger, ctExpectedValue]);
  ctComm.Send(MSG_ACK, msg.MsgData);
  Inc(ctExpectedValue);
end;

procedure TBenchWorker.OMStartTest(var msg: TOmniMessage);
begin
  InitiateDumpTest;
end;

procedure TBenchWorker.OMStartTiming(var msg: TOmniMessage);
begin
  ctStopwatch := TStopwatch.StartNew;
  ctTestSuite := TTestSuite(msg.MsgData.AsInteger);
  ctExpectedValue := 1;
end;

procedure TBenchWorker.RunDumpTest;
var
  iMsg: integer;
begin
  // Dump ctCommSize messages into the link, leaving two slots for
  // MSG_START_TIMING and MSG_END_TIMING.
  ctComm.Send(MSG_START_TIMING, Ord(tsDump));
  for iMsg := 1 to ctCommSize - 2 do
    ctComm.Send(MSG_DUMP_TEST, iMsg);
  ctComm.Send(MSG_END_TIMING, 0);
end;

procedure TBenchWorker.RunMessageExchangeTest;
begin
  ctComm.Send(MSG_START_TIMING, Ord(tsMessageExchange));
  ctComm.Send(MSG_REQ, 1);
end;

procedure PrintStats(const name: string; const times: TList<int64>);
var
  avg     : double;
  cnt     : integer;
  i       : integer;
  joined  : string;
  maxVal  : int64;
  minVal  : int64;
  sum     : int64;
begin
  cnt := times.Count;
  if cnt = 0 then begin
    Writeln(name, ': no samples');
    Exit;
  end;
  sum := 0;
  minVal := times[0];
  maxVal := times[0];
  for i := 0 to cnt - 1 do begin
    sum := sum + times[i];
    if times[i] < minVal then minVal := times[i];
    if times[i] > maxVal then maxVal := times[i];
  end;
  avg := sum / cnt;
  joined := '';
  for i := 0 to cnt - 1 do begin
    if i > 0 then joined := joined + ',';
    joined := joined + IntToStr(times[i]);
  end;
  Writeln(Format('%-28s count=%2d  sum=%5d ms  avg=%7.1f ms  min=%5d ms  max=%5d ms',
    [name, cnt, sum, avg, minVal, maxVal]));
  Writeln(Format('%-28s values=[%s]', ['', joined]));
end;

procedure RunBenchmark;
var
  Comm        : IOmniTwoWayChannel;
  startTicks  : int64;
  TaskA       : IOmniTaskControl;
  TaskB       : IOmniTaskControl;
  totalTime_ms: int64;
begin
  GResultLock := TCriticalSection.Create;
  GDumpTimes_ms := TList<int64>.Create;
  GMsgExTimes_ms := TList<int64>.Create;
  GDoneEvent := CreateOmniEvent(true, false); // manual reset, initially not signalled
  try
    Comm := CreateTwoWayChannel(CTestQueueLength);
    TaskA := CreateTask(TBenchWorker.Create(Comm.Endpoint1, CTestQueueLength), 'A').Run;
    TaskB := CreateTask(TBenchWorker.Create(Comm.Endpoint2, CTestQueueLength), 'B').Run;

    Writeln(Format('Benchmark: CTestQueueLength=%d, reps=%d', [CTestQueueLength, CNumReps]));
    Writeln(Format('Platform : %s (%d-bit)',
      [{$IFDEF MSWINDOWS}'Windows'{$ELSE}{$IFDEF LINUX}'Linux'{$ELSE}'Other'{$ENDIF}{$ENDIF},
       SizeOf(NativeInt) * 8]));
    Writeln;

    startTicks := TStopwatch.GetTimeStamp;
    TaskA.Comm.Send(MSG_START_TEST, 0);

    if GDoneEvent.WaitFor(CWaitTimeout_ms) <> wrSignaled then begin
      Writeln('ERROR: benchmark timed out after ', CWaitTimeout_ms, ' ms');
      Halt(1);
    end;

    totalTime_ms := Round(
      (TStopwatch.GetTimeStamp - startTicks) * 1000.0 / TStopwatch.Frequency);

    Writeln(Format('Total runtime: %d ms', [totalTime_ms]));
    Writeln;
    PrintStats('Dump (10000 one-way)', GDumpTimes_ms);
    Writeln;
    PrintStats('MsgExchange (10000 r/t)', GMsgExTimes_ms);

    TaskA.Terminate(1000);
    TaskB.Terminate(1000);
  finally
    FreeAndNil(GDumpTimes_ms);
    FreeAndNil(GMsgExTimes_ms);
    FreeAndNil(GResultLock);
    GDoneEvent := nil;
  end;
end;

begin
  try
    RunBenchmark;
  except
    on E: Exception do begin
      Writeln('Error: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
