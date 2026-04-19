unit SmokeTest;

interface

uses
  System.SysUtils,
  {$IFDEF MSWindows}
  Winapi.Windows,
  {$ENDIF}
  DUnitX.TestFramework,
  TestOtlBase;

type
  [TestFixture]
  TSmokeTest = class(TOtlTestBase)
  public
    {$IFDEF MSWindows}
    [Test] procedure TestDSiClassWndProcParamSize;
    {$ENDIF}
    [Test] procedure TestTOmniValueArrayInt64Cast;
    [Test] procedure TestCancelledFuture;
  end;

implementation

uses
  OtlParallel,
  OtlCommon,
  OtlSync;

{ TSmokeTest }

{$IFDEF MSWindows}
type
  TDSiWParam = WPARAM;
  TDSiLParam = LPARAM;

procedure TSmokeTest.TestDSiClassWndProcParamSize;
begin
  {$IFDEF CPUX64}
  Assert.AreEqual<integer>(8, SizeOf(TDSiWParam));
  Assert.AreEqual<integer>(8, SizeOf(TDSiLParam));
  {$ELSE}
  Assert.AreEqual<integer>(4, SizeOf(TDSiWParam));
  Assert.AreEqual<integer>(4, SizeOf(TDSiLParam));
  {$ENDIF}
end;
{$ENDIF}

procedure TSmokeTest.TestTOmniValueArrayInt64Cast;
var
  arrIn : TArray<int64>;
  arrOut: TArray<int64>;
  i     : Integer;
  ov    : TOmniValue;
begin
  // Issue #89

  SetLength(arrIn, 5);
  arrIn[0] := 1;
  arrIn[1] := 2;
  arrIn[2] := $FFFFFFFF;
  arrIn[3] := $100000000;
  arrIn[4] := $FFFFFFFFFFFFFF;

  ov := TOmniValue.CastFrom<TArray<Int64>>(arrIn);

  arrOut := ov.CastTo<TArray<Int64>>;

  Assert.AreEqual<integer>(Length(arrIn), Length(arrOut));

  for i := Low(arrIn) to High(arrIn) do
    Assert.AreEqual<int64>(arrIn[i], arrOut[i]);
end;

procedure TSmokeTest.TestCancelledFuture;
var
  executed: boolean;
  future  : IOmniFuture<Integer>;
  token   : IOmniCancellationToken;
begin
  token := CreateOmniCancellationToken;
  token.Signal;

  executed := false;

  future := Parallel.Future<Integer>(
    function: Integer
    begin
      executed := true;
      Result := 100;
    end,
    Parallel.TaskConfig.CancelWith(token)
  );

  Assert.IsTrue(future.IsCancelled);
  Assert.IsFalse(executed);
end;

end.
