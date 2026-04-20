unit TestOtlBase;

interface

uses
  DUnitX.TestFramework;

type
  TOtlTestBase = class
  public
    [TearDown] procedure DrainThreadQueue;
  end;

implementation

uses
  System.Classes;

procedure TOtlTestBase.DrainThreadQueue;
begin
  // CheckSynchronize only works on the main thread. In the console runner the
  // test thread IS the main thread, so we drain here. In the FMX runner tests
  // execute on a worker thread and the main thread pumps messages natively,
  // so draining from the worker would raise EThread and is unnecessary.
  if TThread.CurrentThread.ThreadID = MainThreadID then
    CheckSynchronize(0);
end;

end.
