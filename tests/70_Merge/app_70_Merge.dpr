program app_70_Merge;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Classes,
  System.Threading,
  OtlParallel;

procedure DemoMerge;
begin
  Writeln;
  Writeln('-- Parallel.Merge: fan-in from two producers --');

  var chOdd  := Parallel.Channel<integer>;
  var chEven := Parallel.Channel<integer>;

  // Odd-number producer
  TTask.Run(
    procedure
    begin
      for var i := 1 to 9 do
        if Odd(i) then begin
          chOdd.Sender.Send(i);
          Sleep(15);
        end;
      chOdd.Close;
    end);

  // Even-number producer
  TTask.Run(
    procedure
    begin
      for var i := 2 to 10 do
        if not Odd(i) then begin
          chEven.Sender.Send(i);
          Sleep(10);
        end;
      chEven.Close;
    end);

  // Merge both into a single receiver.
  var merged := Parallel.Merge<integer>([chOdd.Receiver, chEven.Receiver]);

  var value: integer;
  var sum   := 0;
  var count := 0;
  while merged.TryReceive(value, 5000) do begin
    Write(value:3);
    Inc(sum, value);
    Inc(count);
  end;
  Writeln;
  Writeln('Received ', count, ' values, sum = ', sum, ' (expected 55).');
end;

procedure DemoRace;
begin
  Writeln;
  Writeln('-- Parallel.Race: first value from any channel wins --');

  var chA := Parallel.Channel<string>;
  var chB := Parallel.Channel<string>;

  TTask.Run(
    procedure
    begin
      Sleep(100);
      chA.Sender.Send('A (slow)');
    end);

  TTask.Run(
    procedure
    begin
      Sleep(20);
      chB.Sender.Send('B (fast)');
    end);

  var winner := Parallel.Race<string>([chA.Receiver, chB.Receiver], 5000);
  Writeln('Winner: ', winner);
end;

procedure DemoTryRaceTimeout;
begin
  Writeln;
  Writeln('-- Parallel.TryRace timeout (no producer) --');

  var ch := Parallel.Channel<integer>;
  var value: integer;

  if Parallel.TryRace<integer>([ch.Receiver], value, 100) then
    Writeln('Got ', value)
  else
    Writeln('Timed out as expected.');
end;

begin
  try
    Writeln('Parallel.Merge / Race demo');
    Writeln('==========================');

    DemoMerge;
    DemoRace;
    DemoTryRaceTimeout;

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
