program app_62_console;

{$APPTYPE CONSOLE}

uses
  Classes,
  SysUtils,
  OtlCommon,
  OtlComm,
  OtlTask,
  OtlTaskControl,
  OtlParallel;

const
  MSG_STATUS = 1;

  function DoTheCalculation(const task: IOmniTask): integer;
  var
    i: integer;
  begin
    for i := 1 to 5 do begin
      task.Comm.Send(MSG_STATUS, '... still calculating');
      Sleep(1000);
    end;
    Result := 42;
  end;

var
  calc: IOmniFuture<integer>;

begin
  try
    calc := Parallel.Future<integer>(DoTheCalculation,
      parallel.TaskConfig.OnMessage(MSG_STATUS,
        procedure(const task: IOmniTaskControl; const msg: TOmniMessage)
        begin
          Writeln(msg.MsgData.AsString);
        end));

    Writeln('Background thread is calculating ...');
    while not calc.IsDone do begin
      CheckSynchronize(100);
    end;
    Writeln('And the answer is: ', calc.Value);

    {$WARN SYMBOL_PLATFORM OFF}
    if DebugHook <> 0 then
      Readln;
    {$WARN SYMBOL_PLATFORM DEFAULT}
  except
    on E: Exception do
      Writeln(E.ClassName, ': ', E.Message);
  end;
end.
