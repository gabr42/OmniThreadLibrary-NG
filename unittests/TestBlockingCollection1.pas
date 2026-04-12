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
    [Test]
    procedure TestTryTakeEmpty;
    [Test]
    procedure TestTryTakeWithTimeout;
    [Test]
    procedure TestCountAndIsEmpty;
    [Test]
    procedure TestIsCompletedAndIsFinalized;
    [Test]
    procedure TestGetEnumerator;
    [Test]
    procedure TestNext;
    [Test]
    procedure TestFromArrayToArray;
    [Test]
    procedure TestAddRange;
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

procedure TestIOmniBlockingCollection.TestTryTakeEmpty;
var
  value: TOmniValue;
begin
  var coll: IOmniBlockingCollection := TOmniBlockingCollection.Create;
  Assert.IsFalse(coll.TryTake(value, 0));
end;

procedure TestIOmniBlockingCollection.TestTryTakeWithTimeout;
var
  value: TOmniValue;
begin
  var coll: IOmniBlockingCollection := TOmniBlockingCollection.Create;

  // Start a thread that adds a value after a short delay
  System.Threading.TTask.Run(
    procedure
    begin
      Sleep(100);
      coll.Add(42);
    end);

  // TryTake should block and then succeed
  Assert.IsTrue(coll.TryTake(value, 10000));
  Assert.AreEqual<integer>(42, value.AsInteger);
end;

procedure TestIOmniBlockingCollection.TestCountAndIsEmpty;
begin
  var coll: IOmniBlockingCollection := TOmniBlockingCollection.Create;
  Assert.IsTrue(coll.IsEmpty);
  Assert.AreEqual<integer>(0, coll.Count);

  coll.Add(1);
  coll.Add(2);
  Assert.IsFalse(coll.IsEmpty);
  Assert.AreEqual<integer>(2, coll.Count);

  var value: TOmniValue;
  coll.Take(value);
  Assert.AreEqual<integer>(1, coll.Count);

  coll.Take(value);
  Assert.IsTrue(coll.IsEmpty);
end;

procedure TestIOmniBlockingCollection.TestIsCompletedAndIsFinalized;
begin
  var coll: IOmniBlockingCollection := TOmniBlockingCollection.Create;
  Assert.IsFalse(coll.IsCompleted);
  Assert.IsFalse(coll.IsFinalized);

  coll.Add(1);
  coll.CompleteAdding;
  Assert.IsTrue(coll.IsCompleted);
  Assert.IsFalse(coll.IsFinalized);

  var value: TOmniValue;
  coll.Take(value);
  // After draining all items from a completed collection, it should be finalized
  Assert.IsTrue(coll.IsFinalized);
end;

procedure TestIOmniBlockingCollection.TestGetEnumerator;
begin
  var coll: IOmniBlockingCollection := TOmniBlockingCollection.Create;
  coll.Add(10);
  coll.Add(20);
  coll.Add(30);
  coll.CompleteAdding;

  var sum := 0;
  var count := 0;
  var enum := coll.GetEnumerator;
  while enum.MoveNext do begin
    sum := sum + enum.Current.AsInteger;
    Inc(count);
  end;
  Assert.AreEqual<integer>(3, count);
  Assert.AreEqual<integer>(60, sum);
end;

procedure TestIOmniBlockingCollection.TestNext;
begin
  var coll: IOmniBlockingCollection := TOmniBlockingCollection.Create;
  coll.Add(100);
  coll.Add(200);
  coll.CompleteAdding;

  Assert.AreEqual<integer>(100, coll.Next.AsInteger);
  Assert.AreEqual<integer>(200, coll.Next.AsInteger);
end;

procedure TestIOmniBlockingCollection.TestFromArrayToArray;
begin
  var arr: TArray<integer>;
  arr := [1, 2, 3, 4, 5];
  var coll := TOmniBlockingCollection.FromArray<integer>(arr);
  coll.CompleteAdding; // required before ToArray, which enumerates via Take(INFINITE)
  var result := TOmniBlockingCollection.ToArray<integer>(coll);
  Assert.AreEqual<integer>(5, Length(result));
  Assert.AreEqual<integer>(1, result[0]);
  Assert.AreEqual<integer>(5, result[4]);
end;

procedure TestIOmniBlockingCollection.TestAddRange;
begin
  var collObj := TOmniBlockingCollection.Create;
  var coll: IOmniBlockingCollection := collObj;
  collObj.AddRange<integer>([10, 20, 30, 40]);
  Assert.AreEqual<integer>(4, coll.Count);

  var value: TOmniValue;
  coll.Take(value);
  Assert.AreEqual<integer>(10, value.AsInteger);
  coll.Take(value);
  Assert.AreEqual<integer>(20, value.AsInteger);
end;

end.

