unit TestStressOtlSync1;

///<summary>High-iteration stress coverage for IOmniResourceCount.
///   Ported from legacy DUnit unit StressTestOtlSync1.pas.
///   Marked [Category('Stress')] so it is excluded from default runs —
///   3x3 allocate/release combinations × 30 s per combination ~ 5 min.</summary>

interface

uses
  DUnitX.TestFramework,
  OtlSync,
  OtlTask,
  OtlCommon,
  TestOtlBase;

type
  [TestFixture]
  [Category('Stress')]
  TStressOtlSync = class(TOtlTestBase)
  strict private
    FQueuedCount  : TOmniAlignedInt32;
    FResourceCount: IOmniResourceCount;
  strict protected
    procedure ResourceAllocate(const task: IOmniTask);
    procedure ResourceRelease(const task: IOmniTask);
  public
    [Test]
    [Category('Stress')]
    procedure StressTestResourceCount;
  end;

implementation

uses
  System.SysUtils,
  OtlPlatform,
  OtlTaskControl;

const
  CResourceCountStressTest_sec = 30;

procedure TStressOtlSync.ResourceAllocate(const task: IOmniTask);
var
  i           : integer;
  startTime_ms: int64;
begin
  startTime_ms := Time.Timestamp_ms;
  // run this thread for 1 sec less than ResourceRelease - if resources are no
  // longer released, the code will hang in Allocate.
  while not Time.HasElapsed(startTime_ms, (CResourceCountStressTest_sec - 2) * 1000) do
    for i := 1 to 10 do begin
      FResourceCount.Allocate;
      FQueuedCount.Increment;
    end;
end;

procedure TStressOtlSync.ResourceRelease(const task: IOmniTask);
var
  startTime_ms: int64;
begin
  startTime_ms := Time.Timestamp_ms;
  while not Time.HasElapsed(startTime_ms, (CResourceCountStressTest_sec - 1) * 1000) do
    if FQueuedCount.Value > 0 then begin
      FQueuedCount.Decrement;
      FResourceCount.Release;
    end;
end;

procedure TStressOtlSync.StressTestResourceCount;
var
  alloc       : TArray<IOmniTaskControl>;
  i           : integer;
  iAlloc      : integer;
  iRelease    : integer;
  release     : TArray<IOmniTaskControl>;
  startTime_ms: int64;

  function WaitTime_ms: integer;
  var
    wait_ms: int64;
  begin
    wait_ms := (CResourceCountStressTest_sec * 1000 + 1000) - Time.Elapsed_ms(startTime_ms);
    if wait_ms < 0 then
      Result := 0
    else
      Result := wait_ms;
  end;

begin
  FResourceCount := CreateResourceCount(10);
  FQueuedCount.Value := 0;

  for iAlloc := 1 to 3 do begin
    SetLength(alloc, iAlloc);
    for iRelease := 1 to 3 do begin
      SetLength(release, iRelease);
      for i := Low(alloc) to High(alloc) do
        alloc[i] := CreateTask(ResourceAllocate, 'ResourceAllocate');
      for i := Low(release) to High(release) do
        release[i] := CreateTask(ResourceRelease, 'ResourceRelease');

      startTime_ms := Time.Timestamp_ms;
      for i := Low(alloc) to High(alloc) do
        alloc[i].Run;
      for i := Low(release) to High(release) do
        release[i].Run;

      try
        for i := Low(alloc) to High(alloc) do
          Assert.IsTrue(alloc[i].WaitFor(WaitTime_ms),
            Format('TStressOtlSync.StressTestResourceCount: ResourceAllocate #%d (iAlloc=%d iRelease=%d) did not terminate within %d ms',
              [i, iAlloc, iRelease, CResourceCountStressTest_sec * 1000 + 1000]));
      finally
        for i := Low(alloc) to High(alloc) do
          alloc[i].Terminate(0);
        try
          for i := Low(release) to High(release) do
            Assert.IsTrue(release[i].WaitFor(WaitTime_ms),
              Format('TStressOtlSync.StressTestResourceCount: ResourceRelease #%d (iAlloc=%d iRelease=%d) did not terminate within %d ms',
                [i, iAlloc, iRelease, CResourceCountStressTest_sec * 1000 + 1000]));
        finally
          for i := Low(release) to High(release) do
            release[i].Terminate(0);
        end;
      end;
    end;
  end;
end;

end.
