unit test_31_WaitableObjects;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, StdCtrls,
  OtlSync,
  OtlComm,
  OtlTask,
  OtlTaskControl;

type
  TfrmTestWaitableObjects = class(TForm)
    btnRegister1    : TButton;
    btnRegisterH1   : TButton;
    btnSignal1      : TButton;
    btnSignal2      : TButton;
    btnSignalH2     : TButton;
    btnSingnalH1    : TButton;
    btnUnregister1  : TButton;
    btnUnregisterH1 : TButton;
    lbLog           : TListBox;
    procedure btnRegister1Click(Sender: TObject);
    procedure btnRegisterH1Click(Sender: TObject);
    procedure btnSignal1Click(Sender: TObject);
    procedure btnSignal2Click(Sender: TObject);
    procedure btnSignalH2Click(Sender: TObject);
    procedure btnSingnalH1Click(Sender: TObject);
    procedure btnUnregister1Click(Sender: TObject);
    procedure btnUnregisterH1Click(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
    procedure FormCreate(Sender: TObject);
  strict private
    FEvent : IOmniEvent;
    FHandle: THandle;
  private
    FSignalDemo: IOmniTaskControl;
    procedure ReportMessage(const task: IOmniTaskControl; const msg: TOmniMessage);
  public
  end;

var
  frmTestWaitableObjects: TfrmTestWaitableObjects;

implementation

uses
  OtlCommon;

const
  MSG_SIGNAL_2        = 1;
  MSG_HANDLE_2        = 2;
  MSG_CHANGE_SIGNAL_1 = 3;
  MSG_CHANGE_HANDLE_1 = 4;

type
  TSignalDemo = class(TOmniWorker)
  strict private
    FSignal1: IOmniEvent;
    FSignal2: IOmniEvent;
    FHandle1: THandle;
    FHandle2: THandle;
  private
  strict protected
    procedure HandleSignal1;
    procedure HandleSignal2;
    procedure HandleHandle1;
    procedure HandleHandle2;
  protected
    procedure Cleanup; override;
    function  Initialize: boolean; override;
  public
    procedure OMChangeSignal1(var msg: TOmniMessage); message MSG_CHANGE_SIGNAL_1;
    procedure OMChangeHandle1(var msg: TOmniMessage); message MSG_CHANGE_HANDLE_1;
    procedure OMSignal2(var msg: TOmniMessage); message MSG_SIGNAL_2;
    procedure OMHandle2(var msg: TOmniMessage); message MSG_HANDLE_2;
  end; { TSignalDemo }

{$R *.dfm}

{ TfrmTestWaitableObjects }

procedure TfrmTestWaitableObjects.btnRegister1Click(Sender: TObject);
begin
  FSignalDemo.Comm.Send(MSG_CHANGE_SIGNAL_1, 1);
end; { TfrmTestWaitableObjects.btnRegister1Click }

procedure TfrmTestWaitableObjects.btnRegisterH1Click(Sender: TObject);
begin
  FSignalDemo.Comm.Send(MSG_CHANGE_HANDLE_1, 1);
end; { TfrmTestWaitableObjects.btnRegisterH1Click }

procedure TfrmTestWaitableObjects.btnSignal1Click(Sender: TObject);
begin
  FEvent.SetEvent;
end; { TfrmTestWaitableObjects.btnSignal1Click }

procedure TfrmTestWaitableObjects.btnSingnalH1Click(Sender: TObject);
begin
  Windows.SetEvent(FHandle);
end; { TfrmTestWaitableObjects.btnSingnalH1Click }

procedure TfrmTestWaitableObjects.btnSignal2Click(Sender: TObject);
begin
  FSignalDemo.Comm.Send(MSG_SIGNAL_2);
end; { TfrmTestWaitableObjects.btnSignal2Click }

procedure TfrmTestWaitableObjects.btnSignalH2Click(Sender: TObject);
begin
  FSignalDemo.Comm.Send(MSG_HANDLE_2);
end; { TfrmTestWaitableObjects.btnSignalH2Click }

procedure TfrmTestWaitableObjects.btnUnregister1Click(Sender: TObject);
begin
  FSignalDemo.Comm.Send(MSG_CHANGE_SIGNAL_1, 0);
end; { TfrmTestWaitableObjects.btnUnregister1Click }

procedure TfrmTestWaitableObjects.btnUnregisterH1Click(Sender: TObject);
begin
  FSignalDemo.Comm.Send(MSG_CHANGE_HANDLE_1, 0);
end; { TfrmTestWaitableObjects.btnUnregisterH1Click }

procedure TfrmTestWaitableObjects.FormCloseQuery(Sender: TObject; var CanClose: boolean);
begin
  FSignalDemo.Terminate;
  CloseHandle(FHandle);
end; { TfrmTestWaitableObjects.FormCloseQuery }

procedure TfrmTestWaitableObjects.FormCreate(Sender: TObject);
begin
  FEvent := CreateOmniEvent(false, false);
  FHandle := CreateEvent(nil, false, false, '');
  FSignalDemo := CreateTask(TSignalDemo.Create(), 'Signal demo thread')
    .OnMessage(ReportMessage)
    .SetParameter(FEvent)
    .SetParameter(FHandle)
    .Run;
end; { TfrmTestWaitableObjects.FormCreate }

procedure TfrmTestWaitableObjects.ReportMessage(const task: IOmniTaskControl; const msg:
  TOmniMessage);
begin
  lbLog.ItemIndex := lbLog.Items.Add(msg.MsgData);
end; { TfrmTestWaitableObjects.ReportMessage }

{ TSignalDemo }

procedure TSignalDemo.Cleanup;
begin
  FSignal2 := nil;
  CloseHandle(FHandle2);
  inherited;
end; { TSignalDemo.Cleanup }

procedure TSignalDemo.OMChangeSignal1(var msg: TOmniMessage);
begin
  if msg.MsgData = 1 then
    Task.RegisterWaitObject(FSignal1, HandleSignal1)
  else
    Task.UnregisterWaitObject(FSignal1);
end; { TSignalDemo.OMChangeSignal1 }

procedure TSignalDemo.OMChangeHandle1(var msg: TOmniMessage);
begin
  if msg.MsgData = 1 then
    Task.RegisterWaitObject(FHandle1, HandleHandle1)
  else
    Task.UnregisterWaitObject(FHandle1);
end; { TSignalDemo.OMChangeSignal1 }

procedure TSignalDemo.OMSignal2(var msg: TOmniMessage);
begin
  FSignal2.SetEvent;
end; { TSignalDemo.OMSignal2 }

procedure TSignalDemo.OMHandle2(var msg: TOmniMessage);
begin
  Windows.SetEvent(FHandle2);
end; { TSignalDemo.OMSignal2 }

procedure TSignalDemo.HandleSignal1;
begin
  Task.Comm.Send(0, 'Received signal 1');
end; { TSignalDemo.HandleSignal1 }

procedure TSignalDemo.HandleHandle1;
begin
  Task.Comm.Send(0, 'Received handle 1');
end; { TSignalDemo.HandleSignal1 }

procedure TSignalDemo.HandleSignal2;
begin
  Task.Comm.Send(0, 'Received signal 2');
end; { TSignalDemo.HandleSignal2 }

procedure TSignalDemo.HandleHandle2;
begin
  Task.Comm.Send(0, 'Received handle 2');
end; { TSignalDemo.HandleSignal2 }

function TSignalDemo.Initialize: boolean;
begin
  Result := inherited Initialize;
  if not Result then
    Exit;
  FSignal1 := Task.Param[0].AsInterface as IOmniEvent;
  FHandle1 := Task.Param[1];
  FSignal2 := CreateOmniEvent(false, false);
  FHandle2 := CreateEvent(nil, false, false, nil);
  Task.RegisterWaitObject(FSignal1, HandleSignal1);
  Task.RegisterWaitObject(FSignal2, HandleSignal2);
  Task.RegisterWaitObject(FHandle1, HandleHandle1);
  Task.RegisterWaitObject(FHandle2, HandleHandle2);
end; { TSignalDemo.Initialize }

end.
