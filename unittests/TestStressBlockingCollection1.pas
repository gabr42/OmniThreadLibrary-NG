unit TestStressBlockingCollection1;

///<summary>High-iteration stress coverage for IOmniBlockingCollection.
///   Ported from legacy DUnit unit StressTestBlockingCollection1.pas
///   Each [Test] is marked [Category('Stress')] so it can be filtered
///   out of normal runs — expected runtime is several seconds per
///   method at 1000 iterations.</summary>

interface

uses
  DUnitX.TestFramework,
  OtlCollections,
  TestOtlBase;

type
  [TestFixture]
  [Category('Stress')]
  TStressIOmniBlockingCollection = class(TOtlTestBase)
  public
    [Test]
    [Category('Stress')]
    procedure StressTestCompleteAdding;
  end;

implementation

uses
  System.SysUtils,
  OtlCommon,
  OtlParallel;

const
  CIterations = 1000;

procedure TStressIOmniBlockingCollection.StressTestCompleteAdding;
// Stress the "producer races CompleteAdding vs consumer draining" scenario
// CIterations times. Breaks early on the first observed mismatch between
// the last producer-added integer and the last consumer-drained integer —
// the assertion then fails with the offending pair. Uses OTL's
// Parallel.Join (not System.Threading.TParallel.Join as the single-shot
// TestCompleteAdding in TestBlockingCollection1 does).
var
  coll     : IOmniBlockingCollection;
  iTest    : integer;
  lastAdded: integer;
  lastRead : TOmniValue;
begin
  lastAdded := -1;
  lastRead := -2;
  for iTest := 1 to CIterations do begin
    coll := TOmniBlockingCollection.Create;
    lastAdded := -1;
    lastRead := -2;
    Parallel.Join([
      procedure
      var
        i: integer;
      begin
        for i := 1 to 100000 do begin
          if not coll.TryAdd(i) then
            break;
          lastAdded := i;
        end;
      end,

      procedure
      begin
        Sleep(1);
        coll.CompleteAdding;
      end,

      procedure
      begin
        while coll.TryTake(lastRead, INFINITE) do
          ;
      end
    ]).Execute;
    if (lastAdded > 0) and (lastRead.AsInteger > 0)
       and (lastAdded <> lastRead.AsInteger)
    then
      break; //for iTest
  end;
  Assert.AreEqual(lastAdded, lastRead.AsInteger,
    Format('lastAdded=%d lastRead=%d mismatch', [lastAdded, lastRead.AsInteger]));
end;

end.
