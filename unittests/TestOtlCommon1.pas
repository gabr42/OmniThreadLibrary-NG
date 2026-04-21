unit TestOtlCommon1;

interface

uses
  DUnitX.TestFramework,
  OtlCommon,
  TestOtlBase;

type
  [TestFixture]
  TestOmniCounter = class(TOtlTestBase)
  public
    [Test] procedure TestInitialValue;
    [Test] procedure TestIncrement;
    [Test] procedure TestDecrement;
    [Test] procedure TestTakeCount;
    [Test] procedure TestTakeReturnsZeroWhenExhausted;
    [Test] procedure TestTakeBooleanOverload;
    [Test] procedure TestValueProperty;
  end;

  [TestFixture]
  TestOmniWaitableValue = class(TOtlTestBase)
  public
    [Test] procedure TestCreateDefault;
    [Test] procedure TestSignalWithValue;
    [Test] procedure TestWaitForReturnsTrue;
    [Test] procedure TestResetClears;
    [Test] procedure TestSignalWithoutValue;
    [Test] procedure TestWaitForTimeout;
  end;

  [TestFixture]
  TestOmniIntegerSet = class(TOtlTestBase)
  private
    FChangeFired: boolean;
    procedure HandleChange(const intSet: IOmniIntegerSet);
  public
    [Test] procedure TestAddContainsRemove;
    [Test] procedure TestCountAndIsEmpty;
    [Test] procedure TestClear;
    [Test] procedure TestAsMaskRoundTrip;
    [Test] procedure TestAsArrayRoundTrip;
    [Test] procedure TestOnChangeFires;
  end;

  [TestFixture]
  TestOmniValueWrap = class(TOtlTestBase)
  public
    [Test] procedure TestWrapUnwrapRecord;
    [Test] procedure TestFromRecordToRecord;
    [Test] procedure TestFromArrayToArray;
    [Test] procedure TestCastToInteger;
    [Test] procedure TestCastToString;
    [Test] procedure TestCastToBoolean;
    [Test] procedure TestCastToInt64;
  end;

  [TestFixture]
  TestOmniValueOwned = class(TOtlTestBase)
  public
    [Test] procedure TestAsOwnedObject;
    [Test] procedure TestOwnsObjectProperty;
    [Test] procedure TestOwnedObjectFreedOnClear;
  end;

  [TestFixture]
  TestOmniValueContainer = class(TOtlTestBase)
  public
    [Test] procedure TestCountAndAdd;
    [Test] procedure TestAccessByIndex;
    [Test] procedure TestAccessByName;
    [Test] procedure TestExists;
    [Test] procedure TestClear;
    [Test] procedure TestLock;
  end;

  [TestFixture]
  TestOmniEnvironment = class(TOtlTestBase)
  public
    [Test] procedure TestEnvironmentSingleton;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Threading;

type
  TTestRecord = record
    X: integer;
    Y: integer;
  end;

{ TestOmniCounter }

procedure TestOmniCounter.TestInitialValue;
begin
  var counter := CreateCounter(10);
  Assert.AreEqual<integer>(10, counter.Value);
end;

procedure TestOmniCounter.TestIncrement;
begin
  var counter := CreateCounter(0);
  Assert.AreEqual<integer>(1, counter.Increment);
  Assert.AreEqual<integer>(2, counter.Increment);
  Assert.AreEqual<integer>(2, counter.Value);
end;

procedure TestOmniCounter.TestDecrement;
begin
  var counter := CreateCounter(5);
  Assert.AreEqual<integer>(4, counter.Decrement);
  Assert.AreEqual<integer>(3, counter.Decrement);
  Assert.AreEqual<integer>(3, counter.Value);
end;

procedure TestOmniCounter.TestTakeCount;
begin
  var counter := CreateCounter(10);
  var taken := counter.Take(3);
  Assert.AreEqual<integer>(3, taken);
  Assert.AreEqual<integer>(7, counter.Value);
end;

procedure TestOmniCounter.TestTakeReturnsZeroWhenExhausted;
begin
  var counter := CreateCounter(2);
  var taken := counter.Take(5);
  Assert.AreEqual<integer>(2, taken);
  Assert.AreEqual<integer>(0, counter.Value);
end;

procedure TestOmniCounter.TestTakeBooleanOverload;
begin
  var counter := CreateCounter(3);
  var taken: integer;
  Assert.IsTrue(counter.Take(2, taken));
  Assert.AreEqual<integer>(2, taken);
  // Take(5, taken) with 1 remaining: takes 1, returns true (taken > 0)
  Assert.IsTrue(counter.Take(5, taken));
  Assert.AreEqual<integer>(1, taken);
  // Now exhausted: Take returns false
  Assert.IsFalse(counter.Take(1, taken));
end;

procedure TestOmniCounter.TestValueProperty;
begin
  var counter := CreateCounter(0);
  counter.Value := 42;
  Assert.AreEqual<integer>(42, counter.Value);
  counter.Value := 0;
  Assert.AreEqual<integer>(0, counter.Value);
end;

{ TestOmniWaitableValue }

procedure TestOmniWaitableValue.TestCreateDefault;
begin
  var wv := CreateWaitableValue;
  Assert.IsTrue(wv.Value.IsEmpty);
end;

procedure TestOmniWaitableValue.TestSignalWithValue;
begin
  var wv := CreateWaitableValue;
  wv.Signal(42);
  Assert.AreEqual<integer>(42, wv.Value);
end;

procedure TestOmniWaitableValue.TestWaitForReturnsTrue;
begin
  var wv := CreateWaitableValue;
  wv.Signal(100);
  Assert.IsTrue(wv.WaitFor(0));
  Assert.AreEqual<integer>(100, wv.Value);
end;

procedure TestOmniWaitableValue.TestResetClears;
begin
  var wv := CreateWaitableValue;
  wv.Signal(42);
  Assert.IsTrue(wv.WaitFor(0));
  wv.Reset;
  Assert.IsFalse(wv.WaitFor(0));
end;

procedure TestOmniWaitableValue.TestSignalWithoutValue;
begin
  var wv := CreateWaitableValue;
  wv.Signal;
  Assert.IsTrue(wv.WaitFor(0));
end;

procedure TestOmniWaitableValue.TestWaitForTimeout;
begin
  var wv := CreateWaitableValue;
  Assert.IsFalse(wv.WaitFor(10));
end;

{ TestOmniIntegerSet }

procedure TestOmniIntegerSet.HandleChange(const intSet: IOmniIntegerSet);
begin
  FChangeFired := true;
end;

procedure TestOmniIntegerSet.TestAddContainsRemove;
begin
  var s: IOmniIntegerSet := TOmniIntegerSet.Create;
  // Add returns true if value was already present (old bit value)
  Assert.IsFalse(s.Add(5));   // new → returns false
  Assert.IsFalse(s.Add(10));  // new → returns false
  Assert.IsTrue(s.Add(5));    // already present → returns true
  Assert.IsTrue(s.Contains(5));
  Assert.IsTrue(s.Contains(10));
  Assert.IsFalse(s.Contains(7));
  Assert.IsTrue(s.Remove(5));  // was present → returns true
  Assert.IsFalse(s.Contains(5));
  Assert.IsFalse(s.Remove(5)); // not present → returns false
end;

procedure TestOmniIntegerSet.TestCountAndIsEmpty;
begin
  var s: IOmniIntegerSet := TOmniIntegerSet.Create;
  Assert.IsTrue(s.IsEmpty);
  Assert.AreEqual<integer>(0, s.Count);
  s.Add(1);
  s.Add(2);
  Assert.IsFalse(s.IsEmpty);
  Assert.AreEqual<integer>(2, s.Count);
end;

procedure TestOmniIntegerSet.TestClear;
begin
  var s: IOmniIntegerSet := TOmniIntegerSet.Create;
  s.Add(1);
  s.Add(2);
  s.Add(3);
  s.Clear;
  Assert.IsTrue(s.IsEmpty);
  Assert.AreEqual<integer>(0, s.Count);
end;

procedure TestOmniIntegerSet.TestAsMaskRoundTrip;
begin
  var s: IOmniIntegerSet := TOmniIntegerSet.Create;
  s.Add(0);
  s.Add(3);
  s.Add(5);
  var mask := s.AsMask;
  // bits 0, 3, 5 => 1 + 8 + 32 = 41
  Assert.AreEqual<uint64>(41, mask);

  var s2: IOmniIntegerSet := TOmniIntegerSet.Create;
  s2.AsMask := mask;
  Assert.IsTrue(s2.Contains(0));
  Assert.IsTrue(s2.Contains(3));
  Assert.IsTrue(s2.Contains(5));
  Assert.IsFalse(s2.Contains(1));
end;

procedure TestOmniIntegerSet.TestAsArrayRoundTrip;
begin
  var s: IOmniIntegerSet := TOmniIntegerSet.Create;
  s.Add(10);
  s.Add(20);
  s.Add(30);
  var arr := s.AsArray;
  Assert.AreEqual<integer>(3, Length(arr));

  var s2: IOmniIntegerSet := TOmniIntegerSet.Create;
  s2.AsArray := arr;
  Assert.IsTrue(s2.Contains(10));
  Assert.IsTrue(s2.Contains(20));
  Assert.IsTrue(s2.Contains(30));
  Assert.AreEqual<integer>(3, s2.Count);
end;

procedure TestOmniIntegerSet.TestOnChangeFires;
begin
  FChangeFired := false;
  var s: IOmniIntegerSet := TOmniIntegerSet.Create;
  s.OnChange := HandleChange;
  s.Add(1);
  Assert.IsTrue(FChangeFired);
end;

{ TestOmniValueWrap }

procedure TestOmniValueWrap.TestWrapUnwrapRecord;
begin
  var rec: TTestRecord;
  rec.X := 10;
  rec.Y := 20;
  var v := TOmniValue.Wrap<TTestRecord>(rec);
  var rec2 := v.Unwrap<TTestRecord>;
  Assert.AreEqual<integer>(10, rec2.X);
  Assert.AreEqual<integer>(20, rec2.Y);
end;

procedure TestOmniValueWrap.TestFromRecordToRecord;
begin
  var rec: TTestRecord;
  rec.X := 42;
  rec.Y := 99;
  var v := TOmniValue.FromRecord<TTestRecord>(rec);
  Assert.IsTrue(v.IsRecord);
  var rec2 := v.ToRecord<TTestRecord>;
  Assert.AreEqual<integer>(42, rec2.X);
  Assert.AreEqual<integer>(99, rec2.Y);
end;

procedure TestOmniValueWrap.TestFromArrayToArray;
begin
  var arr: TArray<integer>;
  arr := [1, 2, 3, 4, 5];
  var v := TOmniValue.FromArray<integer>(arr);
  Assert.IsTrue(v.IsArray);
  var arr2 := v.ToArray<integer>;
  Assert.AreEqual<integer>(5, Length(arr2));
  Assert.AreEqual<integer>(1, arr2[0]);
  Assert.AreEqual<integer>(5, arr2[4]);
end;

procedure TestOmniValueWrap.TestCastToInteger;
begin
  var v: TOmniValue := 42;
  Assert.AreEqual<integer>(42, v.CastTo<integer>);
end;

procedure TestOmniValueWrap.TestCastToString;
begin
  var v: TOmniValue := 'hello';
  Assert.AreEqual<string>('hello', v.CastTo<string>);
end;

procedure TestOmniValueWrap.TestCastToBoolean;
begin
  var v: TOmniValue := true;
  Assert.AreEqual<boolean>(true, v.CastTo<boolean>);
end;

procedure TestOmniValueWrap.TestCastToInt64;
begin
  var v: TOmniValue := int64(123456789012345);
  Assert.AreEqual<int64>(123456789012345, v.CastTo<int64>);
end;

{ TestOmniValueOwned }

procedure TestOmniValueOwned.TestAsOwnedObject;
begin
  var obj := TStringList.Create;
  var v: TOmniValue;
  v.AsOwnedObject := obj;
  Assert.IsTrue(v.IsOwnedObject);
  // IsObject returns false for owned objects (different ovType)
  Assert.IsFalse(v.IsObject);
  Assert.AreSame(obj, v.AsObject);
end;

procedure TestOmniValueOwned.TestOwnsObjectProperty;
begin
  var obj := TStringList.Create;
  var v: TOmniValue;
  v.AsObject := obj;
  Assert.IsFalse(v.IsOwnedObject);
  v.OwnsObject := true;
  Assert.IsTrue(v.IsOwnedObject);
  // Don't let it leak - clear takes ownership
  v.Clear;
end;

procedure TestOmniValueOwned.TestOwnedObjectFreedOnClear;
begin
  var sl := TStringList.Create;
  var v: TOmniValue;
  v.AsOwnedObject := sl;
  Assert.IsTrue(v.IsOwnedObject);
  v.Clear;
  // After Clear, the owned object should have been freed.
  // We can't directly test the freed state, but verify the value is cleared.
  Assert.IsTrue(v.IsEmpty);
end;

{ TestOmniValueContainer }

procedure TestOmniValueContainer.TestCountAndAdd;
begin
  var c := TOmniValueContainer.Create;
  try
    Assert.AreEqual<integer>(0, c.Count);
    c.Add(1);
    c.Add(2);
    c.Add(3);
    Assert.AreEqual<integer>(3, c.Count);
  finally c.Free; end;
end;

procedure TestOmniValueContainer.TestAccessByIndex;
begin
  var c := TOmniValueContainer.Create;
  try
    c.Add(10);
    c.Add(20);
    c.Add(30);
    Assert.AreEqual<integer>(10, c[0].AsInteger);
    Assert.AreEqual<integer>(20, c[1].AsInteger);
    Assert.AreEqual<integer>(30, c[2].AsInteger);
  finally c.Free; end;
end;

procedure TestOmniValueContainer.TestAccessByName;
begin
  var c := TOmniValueContainer.Create;
  try
    c.Add(42, 'answer');
    c.Add('hello', 'greeting');
    Assert.AreEqual<integer>(42, c.ByName('answer').AsInteger);
    Assert.AreEqual<string>('hello', c.ByName('greeting').AsString);
  finally c.Free; end;
end;

procedure TestOmniValueContainer.TestExists;
begin
  var c := TOmniValueContainer.Create;
  try
    c.Add(1, 'first');
    Assert.IsTrue(c.Exists('first'));
    Assert.IsFalse(c.Exists('second'));
  finally c.Free; end;
end;

procedure TestOmniValueContainer.TestClear;
begin
  // Clear is strict protected; test via Assign which internally clears
  var c := TOmniValueContainer.Create;
  try
    c.Assign([1, 2, 3]);
    Assert.AreEqual<integer>(3, c.Count);
    c.Assign([10]);
    Assert.AreEqual<integer>(1, c.Count);
    Assert.AreEqual<integer>(10, c[0].AsInteger);
  finally c.Free; end;
end;

procedure TestOmniValueContainer.TestLock;
begin
  var c := TOmniValueContainer.Create;
  try
    Assert.IsFalse(c.IsLocked);
    c.Lock;
    Assert.IsTrue(c.IsLocked);
  finally c.Free; end;
end;

{ TestOmniEnvironment }

procedure TestOmniEnvironment.TestEnvironmentSingleton;
begin
  var first  := Environment;
  var second := Environment;
  Assert.IsTrue(first = second, 'Environment must return the same singleton across calls');
  Assert.IsNotNull(first, 'Environment singleton must not be nil');
end;

end.
