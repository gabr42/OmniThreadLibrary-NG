unit TestStressFutureInOmniTask;

///<summary>Stress regression for tests/66_ThreadsInThreads button 1
///    ("OTL from a OTL task"). An outer TOmniWorker creates a nested
///    Parallel.Future; the Future's OnTerminated callback, delivered on
///    the outer's worker thread via the background-observer wait-object
///    path, drops the last reference to the Future's TaskControl, then
///    terminates the outer. Reproduces and locks down two UAFs:
///
///     1. TOmniTaskControl.HandleBackgroundNotification invoked as a raw
///        method pointer from the owner's wait-set dispatch: the user
///        callback can release Self mid-method, so the stack unwind
///        touches freed memory.
///     2. The wait-set entry for the inner task is never removed when
///        its Terminate is short-circuited by otcInEventHandler (being
///        called from inside the task's own OnTerminated); on the next
///        signal the owner invokes a dangling method pointer.
///
///    The race is timing-sensitive — in the original repro it showed up
///    every few manual clicks. The test runs many iterations so the odds
///    of hitting it in any single run are very high if the fixes
///    regress.</summary>
///<author>Primoz Gabrijelcic, Claude</author>
///<remarks><para>
///   Creation date     : 2026-04-22
///   Last modification : 2026-04-22
///   Version           : 1.00
///</para></remarks>

interface

uses
  DUnitX.TestFramework,
  TestOtlBase;

type
  [TestFixture]
  [Category('Stress')]
  TStressFutureInOmniTask = class(TOtlTestBase)
  public
    [Test]
    [Category('Stress')]
    procedure StressTestFutureOnTerminatedReleasesSelf;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  OtlCommon,
  OtlComm,
  OtlTask,
  OtlTaskControl,
  OtlParallel;

const
  CIterations = 2000; // manual repro was ~1 in 3 clicks; 2000 is comfortably above the noise floor
  CMessagesPerFuture = 20;
  CPerTaskTimeout_ms = 10000;

type
  ///<summary>Outer worker that spawns a Parallel.Future from Initialize
  ///   and terminates itself when the Future's OnTerminated fires. The
  ///   callback nils FCalc first, exercising the path where the inner
  ///   TaskControl is released from inside its own OnTerminated while
  ///   the outer's wait-set dispatch is still on the stack.</summary>
  TFutureSpawner = class(TOmniWorker)
  strict private
    FCalc: IOmniFuture<integer>;
  public
    function Initialize: boolean; override;
  end;

function TFutureSpawner.Initialize: boolean;
begin
  Result := inherited Initialize;
  if not Result then
    Exit;
  FCalc := Parallel.Future<integer>(
    function (const aTask: IOmniTask): integer
    var
      j: integer;
    begin
      // Burst of messages drives ProcessMessages rearms on the outer
      // (ProcessNewMessage rearms itself after CMaxReceiveLoop_ms) and
      // maximizes the window for the wait-set race.
      for j := 1 to CMessagesPerFuture do
        aTask.Comm.Send(1, j);
      Result := 42;
    end,
    Parallel.TaskConfig
      .OnMessage(1,
        procedure (const taskCtrl: IOmniTaskControl; const msg: TOmniMessage)
        begin
          // No-op — only the message path waking the outer matters.
        end)
      .OnTerminated(
        procedure
        begin
          // This closure runs on the outer's worker thread (delivered
          // via bg-observer wait-object dispatch). Nilling FCalc drops
          // the last external ref on the Future's TaskControl; the
          // fixes must pin Self across HandleBackgroundNotification and
          // unregister the wait-object in Destroy.
          FCalc := nil;
          Task.Terminate;
        end));
end; { TFutureSpawner.Initialize }

{ TStressFutureInOmniTask }

procedure TStressFutureInOmniTask.StressTestFutureOnTerminatedReleasesSelf;
var
  i   : integer;
  task: IOmniTaskControl;
begin
  for i := 1 to CIterations do begin
    task := CreateTask(TFutureSpawner.Create(), 'stress-outer').Run;
    try
      Assert.IsTrue(task.WaitFor(CPerTaskTimeout_ms),
        Format('Iteration %d: outer task did not terminate within %d ms',
          [i, CPerTaskTimeout_ms]));
    finally
      task.Terminate;
      task := nil;
    end;
  end;
end; { TStressFutureInOmniTask.StressTestFutureOnTerminatedReleasesSelf }

end.
