unit test_2_TwoWayHello_FMX;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.Memo.Types,
  FMX.ScrollBox, FMX.Memo, FMX.Controls.Presentation, FMX.StdCtrls, FMX.Layouts,
  FMX.ListBox,
  OtlCommon,
  OtlTask,
  OtlTaskControl,
  OtlEventMonitor,
  OtlComm,
  OtlSync;

type
  TfrmTwoWayHello = class(TForm)
    btnStartHello: TButton;
    btnChangeMessage: TButton;
    btnStopHello: TButton;
    lbLog: TListBox;
    procedure FormCreate(Sender: TObject);
    procedure btnChangeMessageClick(Sender: TObject);
    procedure btnStartHelloClick(Sender: TObject);
    procedure btnStopHelloClick(Sender: TObject);
  private
    FHelloTask      : IOmniTaskControl;
    FMessageDispatch: TOmniEventMonitor;
  public
    procedure HandleTaskTerminated(const task: IOmniTaskControl);
    procedure HandleTaskMessage(const task: IOmniTaskControl; const msg: TOmniMessage);
  end;

var
  frmTwoWayHello: TfrmTwoWayHello;

implementation

{$R *.fmx}

const
  MSG_CHANGE_MESSAGE = 1;

procedure RunHello(const task: IOmniTask);
var
  msg    : string;
  msgData: TOmniValue;
  msgID  : word;
  waiter : TWaitFor;
begin
  msg := task.Param['Message'];
  waiter := TWaitFor.Create([task.TerminateEvent, task.Comm.NewMessageEvent]);
  try
    repeat
      case waiter.WaitAny(task.Param['Delay'].AsCardinal) of
        waAwaited:
          begin
            if (Length(waiter.Signalled) = 0) or (waiter.Signalled[0].Index = 0) then
              break; //repeat (terminate event)
            while task.Comm.Receive(msgID, msgData) do
              if msgID = MSG_CHANGE_MESSAGE then
                msg := msgData;
          end;
        waTimeout:
          task.Comm.Send(0, msg);
        else
          break; //repeat
      end;
    until false;
  finally FreeAndNil(waiter); end;
end;

procedure TfrmTwoWayHello.FormCreate(Sender: TObject);
begin
  FMessageDispatch := TOmniEventMonitor.Create(Self);
  FMessageDispatch.OnTaskMessage := HandleTaskMessage;
  FMessageDispatch.OnTaskTerminated := HandleTaskTerminated;
end;

procedure TfrmTwoWayHello.HandleTaskMessage(const task: IOmniTaskControl;
  const msg: TOmniMessage);
begin
  lbLog.ItemIndex := lbLog.Items.Add(Format('[%d/%s] %d|%s',
    [task.UniqueID, task.Name, msg.MsgID, msg.MsgData.AsString]));
end;

procedure TfrmTwoWayHello.HandleTaskTerminated(const task: IOmniTaskControl);
begin
  lbLog.ItemIndex := lbLog.Items.Add(Format('[%d/%s] Terminated', [task.UniqueID, task.Name]));
end;

procedure TfrmTwoWayHello.btnChangeMessageClick(Sender: TObject);
begin
  FHelloTask.Comm.Send(MSG_CHANGE_MESSAGE, WideString('Random ' + IntToStr(Random(1234))));
end;

procedure TfrmTwoWayHello.btnStartHelloClick(Sender: TObject);
begin
  FHelloTask :=
    FMessageDispatch.Monitor(CreateTask(RunHello, 'Hello'))
    .SetParameter('Delay', 1000)
    .SetParameter('Message', 'Hello')
    .Run;
end;

procedure TfrmTwoWayHello.btnStopHelloClick(Sender: TObject);
begin
  FHelloTask.Terminate;
  FHelloTask := nil;
end;

end.
