program app_68_Channel;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Classes,
  System.Threading,
  OtlParallel;

const
  CCount = 10;

procedure DemoBasicSendReceive;
begin
  Writeln;
  Writeln('-- Basic send/receive --');

  var ch := Parallel.Channel<integer>;
  ch.Sender.Send(42);
  Writeln('Received: ', ch.Receiver.Receive);
end;

procedure DemoCrossThread;
begin
  Writeln;
  Writeln('-- Cross-thread producer/consumer --');

  var ch := Parallel.Channel<integer>;

  // Producer in a worker task
  TTask.Run(
    procedure
    begin
      for var i := 1 to CCount do begin
        ch.Sender.Send(i * i);
        Sleep(50);
      end;
      ch.Close;
    end);

  // Consumer on the main thread — Receive blocks until data or close.
  var sum := 0;
  var value: integer;
  while ch.Receiver.TryReceive(value, INFINITE) do begin
    Writeln('  got: ', value);
    Inc(sum, value);
  end;

  Writeln('Sum of squares 1..', CCount, ' = ', sum);
end;

procedure DemoBoundedChannel;
begin
  Writeln;
  Writeln('-- Bounded channel (TrySend/TryReceive) --');

  var ch := Parallel.Channel<integer>(2); // capacity 2

  Writeln('TrySend(1): ', ch.Sender.TrySend(1));
  Writeln('TrySend(2): ', ch.Sender.TrySend(2));
  Writeln('TrySend(3, 0ms) [expect false, channel full]: ', ch.Sender.TrySend(3, 0));

  var value: integer;
  ch.Receiver.TryReceive(value, 0);
  Writeln('Received: ', value, ' — channel has room again');
  Writeln('TrySend(3): ', ch.Sender.TrySend(3));
end;

begin
  try
    Writeln('Parallel.Channel<T> demo');
    Writeln('========================');

    DemoBasicSendReceive;
    DemoCrossThread;
    DemoBoundedChannel;

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
