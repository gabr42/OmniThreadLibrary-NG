program app_69_Select;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Classes,
  System.Threading,
  OtlParallel;

procedure DemoTwoChannels;
begin
  Writeln;
  Writeln('-- Select between two channels (different rates) --');

  var chFast := Parallel.Channel<integer>;
  var chSlow := Parallel.Channel<integer>;

  // Fast producer: 5 values, 20 ms apart
  TTask.Run(
    procedure
    begin
      for var i := 1 to 5 do begin
        chFast.Sender.Send(i);
        Sleep(20);
      end;
      chFast.Close;
    end);

  // Slow producer: 3 values, 60 ms apart
  TTask.Run(
    procedure
    begin
      for var i := 100 to 102 do begin
        chSlow.Sender.Send(i);
        Sleep(60);
      end;
      chSlow.Close;
    end);

  var sel := Parallel.Select([
    SelectCase.Receive<integer>(chFast.Receiver,
      procedure(v: integer) begin Writeln('  fast: ', v) end),
    SelectCase.Receive<integer>(chSlow.Receiver,
      procedure(v: integer) begin Writeln('  slow: ', v) end)
  ]);

  // Loop until both channels are drained and closed.
  while sel.Wait(1000) <> srAllClosed do
    ;

  Writeln('Both channels drained.');
end;

procedure DemoDefaultCase;
begin
  Writeln;
  Writeln('-- SelectCase.Default (non-blocking poll) --');

  var ch := Parallel.Channel<integer>;

  var result := Parallel.Select([
    SelectCase.Receive<integer>(ch.Receiver,
      procedure(v: integer) begin Writeln('  got: ', v) end),
    SelectCase.Default(
      procedure begin Writeln('  no data — default fired') end)
  ]).Wait;

  Writeln('Result = ', Ord(result), ' (srDefault=', Ord(srDefault), ')');
end;

procedure DemoTimeout;
begin
  Writeln;
  Writeln('-- Wait(timeout) on empty channel --');

  var ch := Parallel.Channel<integer>;
  var start_ms := TThread.GetTickCount;

  var result := Parallel.Select([
    SelectCase.Receive<integer>(ch.Receiver,
      procedure(v: integer) begin end)
  ]).Wait(100);

  Writeln('Elapsed: ', TThread.GetTickCount - start_ms, ' ms, result = ',
    Ord(result), ' (srTimeout=', Ord(srTimeout), ')');
end;

begin
  try
    Writeln('Parallel.Select demo');
    Writeln('====================');

    DemoTwoChannels;
    DemoDefaultCase;
    DemoTimeout;

    {$WARN SYMBOL_PLATFORM OFF}
    if DebugHook <> 0 then begin
      Writeln;
      Write('Press Enter to exit... ');
      Readln;
    end;
    {$WARN SYMBOL_PLATFORM DEFAULT}
  except
    on E: Exception do
      Writeln(E.ClassName, ': ', E.Message);
  end;
end.
