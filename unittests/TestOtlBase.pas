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
  CheckSynchronize(0);
end;

end.
