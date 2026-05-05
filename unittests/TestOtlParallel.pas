unit TestOtlParallel;

interface

uses
  DUnitX.TestFramework, OtlContainers, System.SysUtils,
  TestOtlBase;

type
  [TestFixture]
  TestParallelFor = class(TOtlTestBase)
  strict protected
    FTestData: array of integer;
    procedure TestRange(iFrom, iTo, iStep: integer);
    procedure InternalTestStepZero;
  public
    [Test] procedure TestIncreasingStep;
    [Test] procedure TestIncreasingEndEqStep;
    [Test] procedure TestIncreasingLargeDataStep;
    [Test] procedure TestDecreasingStep;
    [Test] procedure TestDecreasingStartEqStep;
    [Test] procedure TestDecreasingLargeDataStep;
    [Test] procedure TestIncreasingStartEqStep;
    [Test] procedure TestDecreasingEndEqStep;
    [Test] procedure TestNoExecution;
    [Test] procedure TestStepZero;
    [Test] procedure TestRepeatedDefaultTasks;
    [Test] procedure TestRepeatedExplicitTasks;
  end;

  [TestFixture]
  TestJoin = class(TOtlTestBase)
  public
    [Test]
    {$IFNDEF MSWINDOWS}[Ignore('POSIX has no safe force-kill: pthread_cancel forced-unwind is absorbed by OTL outer except-handlers, so pthread_join deadlocks')]{$ENDIF}
    procedure TestTerminationAllStuck;
    [Test]
    {$IFNDEF MSWINDOWS}[Ignore('POSIX has no safe force-kill: pthread_cancel forced-unwind is absorbed by OTL outer except-handlers, so pthread_join deadlocks')]{$ENDIF}
    procedure TestTerminationPartialStuck;
    [Test]
    {$IFNDEF MSWINDOWS}[Ignore('POSIX has no safe force-kill: pthread_cancel forced-unwind is absorbed by OTL outer except-handlers, so pthread_join deadlocks')]{$ENDIF}
    procedure TestTerminationAllTerminated;
    [Test] procedure TestNoWaitWithoutWaitForRaises;
  end;

implementation

uses
  System.Math,
  System.Diagnostics,
  System.SyncObjs,
  OtlParallel,
  OtlCommon,
  OtlSync;

const
  CTimeout_ms = 5000;

{ TestParallelFor }

procedure TestParallelFor.TestIncreasingStep;
var
  i: Integer;
begin
  for i := 1 to 11 do
    TestRange(1, 10, i);
end;

procedure TestParallelFor.TestIncreasingEndEqStep;
var
  i: Integer;
begin
  for i := 1 to 10 do
    TestRange(1, i, i);
end;

procedure TestParallelFor.TestIncreasingLargeDataStep;
var
  i: Integer;
begin
  for i := 1 to 10 do
    TestRange(1, 100000, i);
end;

procedure TestParallelFor.TestDecreasingStep;
var
  i: Integer;
begin
  for i := 1 to 11 do
    TestRange(10, 1, -i);
end;

procedure TestParallelFor.TestDecreasingStartEqStep;
var
  i: Integer;
begin
  for i := 1 to 10 do
    TestRange(i, 1, -i);
end;

procedure TestParallelFor.TestDecreasingLargeDataStep;
var
  i: Integer;
begin
  for i := 1 to 10 do
    TestRange(100000, 1, -i);
end;

procedure TestParallelFor.TestIncreasingStartEqStep;
var
  i: Integer;
begin
  for i := 1 to 10 do
    TestRange(i, 10, i);
end;

procedure TestParallelFor.InternalTestStepZero;
begin
  TestRange(1, 10, 0);
end;

procedure TestParallelFor.TestDecreasingEndEqStep;
var
  i: Integer;
begin
  for i := 1 to 10 do
    TestRange(10, i, -i);
end;

procedure TestParallelFor.TestNoExecution;
var
  i,j: Integer;
begin
  for i := 1 to 10 do
    for j := 1 to 3 do
      TestRange(i, 0, j);
  for i := 1 to 10 do
    for j := 1 to 3 do
      TestRange(0, i, -j);
end;

procedure TestParallelFor.TestRange(iFrom, iTo, iStep: integer);
var
  iMax: integer;
  iMin: integer;
  i: Integer;

  procedure CheckAllEmpty;
  var
    i: integer;
  begin
    for i := Low(FTestData) to High(FTestData) do
      Assert.AreEqual<integer>(-1, FTestData[i]);
  end;

begin
  iMin := Min(iFrom, iTo);
  iMax := Max(iFrom, iTo);
  SetLength(FTestData, iMax - iMin + 1);
  FillChar(FTestData[0], (iMax - iMin + 1) * SizeOf(FTestData[0]), $FF);

  Parallel.For(iFrom, iTo, iStep).Execute(
    procedure (idx: integer)
    begin
      FTestData[idx-iMin] := idx;
    end);

  if iStep > 0 then begin
    if iFrom > iTo then
      CheckAllEmpty
    else for i := iFrom to iTo do begin
      if ((i-iFrom) mod iStep) = 0 then
        Assert.AreEqual<integer>(i, FTestData[i-iMin], Format('at index %d', [i]))
      else
        Assert.AreEqual<integer>(-1, FTestData[i-iMin], Format('at index %d', [i]));
    end;
  end
  else begin
    if iFrom < iTo then
      CheckAllEmpty
    else for i := iFrom downto iTo do begin
      if ((i-iFrom) mod iStep) = 0 then
        Assert.AreEqual<integer>(i, FTestData[i-iMin], Format('at index %d', [i]))
      else
        Assert.AreEqual<integer>(-1, FTestData[i-iMin], Format('at index %d', [i]));
    end;
  end;
end;

procedure TestParallelFor.TestRepeatedDefaultTasks;
var
  counter: integer;
  n      : integer;
begin
  // Stress test: repeated Parallel.For with default task count (all cores).
  // Exercises thread pool reuse and condvar-based TWaitFor signal handling
  // under high concurrency. Previously deadlocked after ~5 iterations due to
  // lock-order inversion in PerformObservableAction (SpinLock->FGate vs
  // FGate->SpinLock in TCondition.Wait).
  for n := 1 to 50 do begin
    counter := 0;
    Parallel.For(1, 10, 1)
      .Execute(
        procedure (idx: integer)
        begin
          TInterlocked.Increment(counter);
        end);
    Assert.AreEqual(10, counter, Format('iteration %d', [n]));
  end;
end;

procedure TestParallelFor.TestRepeatedExplicitTasks;
var
  counter: integer;
  n      : integer;
begin
  // Stress test with explicit NumTasks(2) and NoThreadPool.
  for n := 1 to 50 do begin
    counter := 0;
    Parallel.For(1, 10, 1).NumTasks(2)
      .TaskConfig(Parallel.TaskConfig.NoThreadPool)
      .Execute(
        procedure (idx: integer)
        begin
          TInterlocked.Increment(counter);
        end);
    Assert.AreEqual(10, counter, Format('iteration %d', [n]));
  end;
end;

procedure TestParallelFor.TestStepZero;
begin
  Assert.WillRaise(InternalTestStepZero, Exception);
end;

{ TestJoin }

procedure TestJoin.TestTerminationAllStuck;
var
  i      : integer;
  join   : IOmniParallelJoin;
  release: IOmniEvent;
  done   : TArray<IOmniEvent>;
  started: TArray<boolean>;
  stopped: TArray<boolean>;
  sw     : TStopwatch;

  function MakeTask(idx: integer; const releaseEv, doneEv: IOmniEvent): TProc;
  begin
    // CLAUDE.md anonymous-method capture rule: parameters are passed by
    // value, so the closure captures these specific values instead of the
    // outer loop variables.
    Result :=
      procedure
      begin
        started[idx] := true;
        Sleep(100);
        // Stays "stuck" (ignores cancellation) until the test releases us.
        // Replaces the prior fixed Sleep(2000) — that's how we used to
        // bound the leak, but it left OS threads racing for the loader
        // lock with whatever workers leaked from neighbouring tests.
        releaseEv.WaitFor(INFINITE);
        stopped[idx] := true;
        doneEv.SetEvent;
      end;
  end;

begin
  // Tests IOmniParallelJoin.Terminate when all tasks are stuck and don't
  // terminate within the timeout. Earlier versions force-killed stuck
  // workers via TerminateThread; that has been replaced by detach because
  // killing a thread mid-allocation leaks the heap critical section and
  // deadlocks the entire process. The new contract:
  //   - Terminate(500) returns false (couldn't stop the tasks cleanly).
  //   - Terminate returns within ~500 ms instead of blocking on stuck
  //     threads.
  //   - Tasks are detached: their OS threads keep running until released.
  //
  // The release+done events let the test reclaim the detached threads
  // before returning, instead of leaking them past the test boundary
  // where many such leaked workers can pile up at the Windows loader
  // lock during process / pool teardown.

  SetLength(started, 2);
  FillChar(started[0], Length(started), false);
  SetLength(stopped, 2);
  FillChar(stopped[0], Length(stopped), false);
  release := CreateOmniEvent(true, false); // manual-reset, fires both tasks at once
  SetLength(done, 2);
  done[0] := CreateOmniEvent(true, false);
  done[1] := CreateOmniEvent(true, false);

  join := Parallel.Join(
    MakeTask(0, release, done[0]),
    MakeTask(1, release, done[1])).NoWait.Execute;
  sw := TStopwatch.StartNew;
  Assert.IsFalse(join.Terminate(500), 'Terminate');
  Assert.IsTrue(sw.ElapsedMilliseconds < 1900, 'Elapsed time');

  for i := 0 to 1 do
    Assert.IsTrue(started[i], 'started ' + IntToStr(i));

  // Reclaim the detached workers: release them and wait for each to finish.
  release.SetEvent;
  for i := 0 to 1 do
    Assert.AreEqual(wrSignaled, done[i].WaitFor(CTimeout_ms),
      'Detached task ' + IntToStr(i) + ' did not finish after release');
  for i := 0 to 1 do
    Assert.IsTrue(stopped[i], 'stopped ' + IntToStr(i));
  // `done` events are set from user code, before the OS thread leaves
  // EndThread. Margin so the OS thread has fully exited by the time the
  // next test starts (avoids leaked-worker pile-up at the loader lock).
  Sleep(200);
end;

procedure TestJoin.TestTerminationAllTerminated;
// (Name is historical and slightly misleading — this test actually verifies
// the partial-stuck case: task 0 ignores cancellation, task 1 finishes
// quickly. Pre-detach, the test asserted stopped[0]=false because the stuck
// worker was force-killed before reaching `stopped[0] := true`. With detach,
// the stuck worker eventually finishes; we now use a release+done event
// pair to reclaim it within the test instead of leaking it.)
var
  i      : integer;
  join   : IOmniParallelJoin;
  release: IOmniEvent;
  done   : TArray<IOmniEvent>;
  started: TArray<boolean>;
  stopped: TArray<boolean>;
  sw     : TStopwatch;

  function MakeTask(idx: integer; stuck: boolean;
    const releaseEv, doneEv: IOmniEvent): TProc;
  begin
    Result :=
      procedure
      begin
        started[idx] := true;
        Sleep(100);
        if stuck then
          releaseEv.WaitFor(INFINITE);
        stopped[idx] := true;
        doneEv.SetEvent;
      end;
  end;

begin
  // Tests IOmniParallelJoin.Terminate when one task is stuck and the other
  // terminates cleanly. Terminate(500) returns false (couldn't stop the
  // stuck task within timeout); the stuck task is detached.

  SetLength(started, 2);
  FillChar(started[0], Length(started), false);
  SetLength(stopped, 2);
  FillChar(stopped[0], Length(stopped), false);
  release := CreateOmniEvent(true, false);
  SetLength(done, 2);
  done[0] := CreateOmniEvent(true, false);
  done[1] := CreateOmniEvent(true, false);

  join := Parallel.Join(
    MakeTask(0, true,  release, done[0]),
    MakeTask(1, false, release, done[1])).NoWait.Execute;
  sw := TStopwatch.StartNew;
  Assert.IsFalse(join.Terminate(500), 'Terminate');
  Assert.IsTrue(sw.ElapsedMilliseconds < 1900, 'Elapsed time');

  // Task 1 (not stuck) should already be done.
  Assert.AreEqual(wrSignaled, done[1].WaitFor(CTimeout_ms),
    'Non-stuck task did not finish');
  for i := 0 to 1 do
    Assert.IsTrue(started[i], 'started ' + IntToStr(i));

  // Reclaim the stuck/detached worker before this test returns.
  release.SetEvent;
  Assert.AreEqual(wrSignaled, done[0].WaitFor(CTimeout_ms),
    'Detached task 0 did not finish after release');
  for i := 0 to 1 do
    Assert.IsTrue(stopped[i], 'stopped ' + IntToStr(i));
  // Margin for OS thread teardown after `done` fires (see TestTerminationAllStuck).
  Sleep(200);
end;

procedure TestJoin.TestTerminationPartialStuck;
var
  i      : integer;
  join   : IOmniParallelJoin;
  started: TArray<boolean>;
  stopped: TArray<boolean>;
  sw     : TStopwatch;

  function MakeTask(idx: integer; hangForever: boolean): TProc;
  begin
    Result :=
      procedure
      begin
        started[idx] := true;
        Sleep(100);
        if hangForever then
          Sleep(2000);
        stopped[idx] := true;
      end;
  end;

begin
  // Tests IOmniParallelJoin.Terminate when all tasks terminate correctly.

  SetLength(started, 2);
  FillChar(started[0], Length(started), false);
  SetLength(stopped, 2);
  FillChar(stopped[0], Length(stopped), false);

  join := Parallel.Join(MakeTask(0, false), MakeTask(1, false)).NoWait.Execute;
  sw := TStopwatch.StartNew;
  Assert.IsTrue(join.Terminate(500), 'Terminate');
  Assert.IsTrue(sw.ElapsedMilliseconds < 1900, 'Elapsed time');

  for i := 0 to 1 do begin
    Assert.IsTrue(started[i], 'started ' + IntToStr(i));
    Assert.IsTrue(stopped[i], 'stopped ' + IntToStr(i));
  end;
end;

procedure TestJoin.TestNoWaitWithoutWaitForRaises;
begin
  // Dropping a NoWait Join without calling WaitFor/Terminate is a programming error.
  Assert.WillRaise(
    procedure
    var
      join: IOmniParallelJoin;
    begin
      join := Parallel.Join(
        procedure begin Sleep(50) end,
        procedure begin Sleep(50) end
      ).NoWait.Execute;
      join := nil; // drop without WaitFor — should raise
    end,
    Exception);
end;

end.
