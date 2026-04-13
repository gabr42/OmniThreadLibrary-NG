program TestForHang;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.SyncObjs,
  OtlParallel,
  OtlCommon;

begin
  try
    WriteLn('CPU cores: ', Environment.Process.Affinity.Count);
    Flush(Output);

    // Use TaskConfig.RunDirectly to bypass thread pool
    for var n := 1 to 50 do begin
      var counter: integer := 0;
      Write(Format('[%d] ', [n]));
      Flush(Output);
      Parallel.For(1, 3, 1).NumTasks(2)
        .TaskConfig(Parallel.TaskConfig.NoThreadPool)
        .Execute(
          procedure (idx: integer)
          begin
            TInterlocked.Increment(counter);
          end);
      WriteLn('OK (counter=', counter, ')');
      Flush(Output);
    end;
    WriteLn('All done!');
  except
    on E: Exception do begin
      Writeln(E.ClassName, ': ', E.Message);
      Flush(Output);
    end;
  end;
end.
