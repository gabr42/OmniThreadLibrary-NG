unit TestBlockingCollection1;

interface

uses
  DUnitX.TestFramework, OtlContainers, System.SysUtils,
  OtlContainerObserver, OtlCollections, OtlCommon, OtlSync;

type
  // Test methods for class IOmniBlockingCollection
  [TestFixture]
  TestIOmniBlockingCollection = class
  private
    procedure FillOmniValueWithOwnedObject(VAR lValue:TOmniValue);
  public
    [Test]
    procedure TestCompleteAdding;
    [Test]
    procedure TestOwnedObjectleak;
    [Test]
    procedure TestOmniValueObjectleak;
    [Test]
    procedure TestInterfaceLeak;
  end;

implementation

uses
  System.Classes, System.SyncObjs,
  System.Threading;

type
  TMemLeakCheckObj=class(TInterfacedObject)
    constructor Create;
    destructor Destroy; override;
  end;

var
  vMemLeakCheckObjCount: integer = 0;

procedure TestIOmniBlockingCollection.TestCompleteAdding;
var
  coll     : IOmniBlockingCollection;
  lastAdded: integer;
  lastRead : TOmniValue;
  join     : ITask;
begin
  coll := TOmniBlockingCollection.Create;
  lastAdded := -1;
  lastRead := -2;

  join := TParallel.Join([
    procedure
    var
      i: integer;
    begin
      TThread.Current.NameThreadForDebugging('Add');
      for i := 1 to 100000 do begin
        if not coll.TryAdd(i) then
          break;
        lastAdded := i;
      end;
    end,

    procedure
    begin
      TThread.Current.NameThreadForDebugging('Complete');
      while lastAdded = -1 do
        Sleep(1);
      coll.CompleteAdding;
    end,

    procedure
    begin
      TThread.Current.NameThreadForDebugging('Take');
      while coll.TryTake(lastRead, INFINITE) do
        ;
      Sleep(0);
    end
  ]);
  join.Wait(INFINITE);

  Assert.AreEqual(lastAdded, lastRead.AsInteger);
end;

{ TMemLeakCheckObj }

constructor TMemLeakCheckObj.Create;
begin
  TInterlocked.Increment(vMemLeakCheckObjCount);
  inherited;
end;

destructor TMemLeakCheckObj.Destroy;
begin
  inherited;
  TInterlocked.Decrement(vMemLeakCheckObjCount);
end;

procedure TestIOmniBlockingCollection.TestInterfaceLeak;
const cTestSize=10;
VAR i:integer;
    lCollection:IOmniBlockingCollection;
    lValue:TOmniValue;
begin
  lCollection := TOmniBlockingCollection.Create;
  vMemLeakCheckObjCount := 0;
  for i := 1 to cTestSize do begin
    lValue.AsInterface := TMemLeakCheckObj.Create;
    lCollection.Add(lValue);
  end;
  lValue.Clear;
  Assert.AreEqual(cTestSize,vMemLeakCheckObjCount);
  for i := 1 to cTestSize do
    lCollection.Take(lValue);
  lCollection := nil;

  Assert.AreEqual(1, vMemLeakCheckObjCount);
  lValue.Clear; // drop the last interface in the queue
  Assert.AreEqual(0, vMemLeakCheckObjCount);
end;

//Using a separate routine to set the AsOwnedObject property is required because
//the compiler generates code that keeps the last created object alive (refcount) until the
//routine is actually finished
procedure TestIOmniBlockingCollection.FillOmniValueWithOwnedObject(var lValue: TOmniValue);
begin
  lValue.AsOwnedObject := TMemLeakCheckObj.Create;
end;

procedure TestIOmniBlockingCollection.TestOmniValueObjectleak;
VAR lValue:TOmniValue;
begin
  vMemLeakCheckObjCount := 0;
  FillOmniValueWithOwnedObject(lValue);
  Assert.AreEqual(1, vMemLeakCheckObjCount);
  lValue.Clear; // one would expect the owned object to be destroyed here, but it does NOT

  Assert.AreEqual(0, vMemLeakCheckObjCount); // this test Fails
end;

procedure TestIOmniBlockingCollection.TestOwnedObjectleak;
const
  cTestSize = 10;
var
  i          : integer;
  lCollection: IOmniBlockingCollection;
  lValue     : TOmniValue;

begin
  lCollection := TOmniBlockingCollection.Create;
  vMemLeakCheckObjCount := 0;
  for i := 1 to cTestSize do begin
    FillOmniValueWithOwnedObject(lValue);
    lCollection.Add(lValue);
  end;
  lValue.Clear;
  Assert.AreEqual(cTestSize, vMemLeakCheckObjCount);

  for i := 1 to cTestSize do
    lCollection.Take(lValue);
  lCollection := nil;

  Assert.AreEqual(1, vMemLeakCheckObjCount);

  // drop the last owned object in the queue
  lValue.Clear; // drop the last owned object in the queue

  // this test fails for some strange reason, obviously the lValue is not
  // released until the end of the routine eventhough it is actually cleared
  Assert.AreEqual(0, vMemLeakCheckObjCount);
end;

end.

