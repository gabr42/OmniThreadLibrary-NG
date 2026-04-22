unit test_66_threadsInThreads;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics,
  Controls, Forms, Dialogs, StdCtrls,
  OtlComm, OtlTaskControl;

const
  WM_LOG = WM_USER;

type
  TfrmThreadInThreads = class(TForm)
    btnOTLFromTask: TButton;
    btnOTLFromThread: TButton;
    btnOTLFromThreadDrain: TButton;
    lbLog: TListBox;
    procedure btnOTLFromTaskClick(Sender: TObject);
    procedure btnOTLFromThreadClick(Sender: TObject);
    procedure btnOTLFromThreadDrainClick(Sender: TObject);
  private
    FOwnerTask: IOmniTaskControl;
    FThread: TThread;
    procedure Log(const msg: string);
    procedure TaskTerminated;
    procedure ThreadTerminated(Sender: TObject);
    procedure WMLog(var msg: TOmniMessage); message WM_LOG;
  public
  end;

var
  frmThreadInThreads: TfrmThreadInThreads;

implementation

uses
  OtlCommon, OtlTask, OtlParallel, OtlBackgroundObserver;

{$R *.dfm}

type
  TWorker = class(TOmniWorker)
  strict private const
    MSG_STATUS = 1;
  var
    FCalc: IOmniFuture<integer>;
  strict protected
    function Asy_DoTheCalculation(const task: IOmniTask): integer;
  public
    function Initialize: boolean; override;
  end;

  TWorkerThread = class(TThread)
  strict private const
    MSG_STATUS = 1;
  strict protected
    function Asy_DoTheCalculation(const task: IOmniTask): integer;
    procedure Log(const msg: string);
  public
    procedure Execute; override;
  end;

  TWorkerThreadDrain = class(TThread)
  strict private const
    MSG_STATUS = 1;
  strict protected
    function Asy_DoTheCalculation(const task: IOmniTask): integer;
    procedure Log(const msg: string);
  public
    procedure Execute; override;
  end;

{ TfrmThreadInThreads }

procedure TfrmThreadInThreads.btnOTLFromTaskClick(Sender: TObject);
begin
  // Create a Task that will spawn a Future.

  Log('Creating task');

  FOwnerTask := CreateTask(TWorker.Create(), 'OTL owner')
    .OnMessage(Self)
    .OnTerminated(TaskTerminated)
    .Run;
end;

procedure TfrmThreadInThreads.btnOTLFromThreadClick(Sender: TObject);
begin
  // Create a TThread that will spawn a Future.

  Log('Creating thread');

  FThread := TWorkerThread.Create(true);
  FThread.OnTerminate := ThreadTerminated;
  FThread.FreeOnTerminate := true;
  FThread.Start;
end;

procedure TfrmThreadInThreads.btnOTLFromThreadDrainClick(Sender: TObject);
begin
  // Create a TThread that will spawn a Future and drain its events via
  // DrainBackgroundObservers (cross-platform alternative to an alertable
  // MsgWaitForMultipleObjectsEx loop).

  Log('Creating thread (drain)');

  FThread := TWorkerThreadDrain.Create(true);
  FThread.OnTerminate := ThreadTerminated;
  FThread.FreeOnTerminate := true;
  FThread.Start;
end;

procedure TfrmThreadInThreads.Log(const msg: string);
begin
  lbLog.ItemIndex := lbLog.Items.Add(Format('[%d] ', [GetCurrentThreadID]) + msg);
end;

procedure TfrmThreadInThreads.TaskTerminated;
begin
  Log('Task terminated');
  FOwnerTask := nil;
end;

procedure TfrmThreadInThreads.ThreadTerminated(Sender: TObject);
begin
  Log('Thread terminated');
end;

procedure TfrmThreadInThreads.WMLog(var msg: TOmniMessage);
begin
  Log(msg.MsgData.AsString);
end;

{ TWorker }

function TWorker.Asy_DoTheCalculation(const task: IOmniTask): integer;
var
  i: integer;
begin
  for i := 1 to 5 do begin
    task.Comm.Send(MSG_STATUS, Format('[%d] ... still calculating', [GetCurrentThreadID]));
    Sleep(1000);
  end;
  Result := 42;
end;

function TWorker.Initialize: boolean;
begin
  Result := inherited Initialize;
  if Result then begin
    Task.Comm.Send(WM_LOG, Format('[%d] Starting a Future', [GetCurrentThreadID]));
    FCalc := Parallel.Future<integer>(Asy_DoTheCalculation,
      Parallel.TaskConfig
        .OnMessage(MSG_STATUS,
          procedure(const workerTask: IOmniTaskControl; const msg: TOmniMessage)
          begin
            // workerTask = task controller for Parallel.Future worker thread
            // Task = TWorker.Task = interface of the TWorker task
            Task.Comm.Send(WM_LOG, Format('[%d] Future sent a message: %s',
              [GetCurrentThreadID, msg.MsgData.AsString]));
          end)
        .OnTerminated(
          procedure
          begin
            Task.Comm.Send(WM_LOG, Format('[%d] Future terminated, result = %d',
              [GetCurrentThreadID, FCalc.Value]));
            FCalc := nil;
            Task.Comm.Send(WM_LOG, Format('[%d] Terminating worker', [GetCurrentThreadID]));
            // Terminate TWorker
            Task.Terminate;
          end));
  end;
end;

{ TWorkerThread }

function TWorkerThread.Asy_DoTheCalculation(const task: IOmniTask): integer;
var
  i: integer;
begin
  for i := 1 to 5 do begin
    task.Comm.Send(MSG_STATUS, Format('[%d] ... still calculating', [GetCurrentThreadID]));
    Sleep(1000);
  end;
  Result := 42;
end;

procedure TWorkerThread.Execute;
var
  calc   : IOmniFuture<integer>;
  handles: array [0..0] of THandle;
begin
  Log('Starting a Future');

  calc := Parallel.Future<integer>(Asy_DoTheCalculation,
    Parallel.TaskConfig
      .OnMessage(MSG_STATUS,
        procedure(const workerTask: IOmniTaskControl; const msg: TOmniMessage)
        begin
          Log('Future sent a message: ' + msg.MsgData.AsString);
        end));

  // MWMO_ALERTABLE puts the thread into an alertable wait so OTL's
  // QueueUserAPC-based delivery of the nested Future's OnMessage /
  // OnTerminated callbacks can fire on this (non-OTL, non-main) thread.
  repeat
    MsgWaitForMultipleObjectsEx(0, handles, INFINITE, QS_ALLPOSTMESSAGE, MWMO_ALERTABLE);
  until calc.IsDone;

  Log('Future terminated, result = ' + IntToStr(calc.Value));
  calc := nil;
  Log('Terminating worker');
end;

procedure TWorkerThread.Log(const msg: string);
var
  s: string;
begin
  s := Format('[%d] ', [GetCurrentThreadID]) + msg;
  Queue(
    procedure
    begin
      frmThreadInThreads.Log(s);
    end);
end;

{ TWorkerThreadDrain }

function TWorkerThreadDrain.Asy_DoTheCalculation(const task: IOmniTask): integer;
var
  i: integer;
begin
  for i := 1 to 5 do begin
    task.Comm.Send(MSG_STATUS, Format('[%d] ... still calculating', [GetCurrentThreadID]));
    Sleep(1000);
  end;
  Result := 42;
end;

procedure TWorkerThreadDrain.Execute;
var
  calc: IOmniFuture<integer>;
begin
  Log('Starting a Future');

  calc := Parallel.Future<integer>(Asy_DoTheCalculation,
    Parallel.TaskConfig
      .OnMessage(MSG_STATUS,
        procedure(const workerTask: IOmniTaskControl; const msg: TOmniMessage)
        begin
          Log('Future sent a message: ' + msg.MsgData.AsString);
        end));

  // DrainBackgroundObservers is cross-platform: on Windows it runs a
  // zero-timeout alertable wait to fire queued APCs; on POSIX it drains
  // the thread-local background-observer registry.
  while not calc.IsDone do begin
    DrainBackgroundObservers;
    Sleep(10);
  end;

  Log('Future terminated, result = ' + IntToStr(calc.Value));
  calc := nil;
  Log('Terminating worker');
end;

procedure TWorkerThreadDrain.Log(const msg: string);
var
  s: string;
begin
  s := Format('[%d] ', [GetCurrentThreadID]) + msg;
  Queue(
    procedure
    begin
      frmThreadInThreads.Log(s);
    end);
end;

end.
