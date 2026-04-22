unit test_37_ParallelJoin;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, StdCtrls,
  OtlCommon;

type
  TfrmTestParallelJoin = class(TForm)
    btnJoinAll: TButton;
    btnJoinOne: TButton;
    lbLog: TListBox;
    btnJoinTProc: TButton;
    btnCancel: TButton;
    btnNoWait: TButton;
    procedure btnCancelClick(Sender: TObject);
    procedure btnJoinAllClick(Sender: TObject);
    procedure btnJoinTProcClick(Sender: TObject);
    procedure btnNoWaitClick(Sender: TObject);
  protected
    FJoinCount: TOmniAlignedInt32;
    FJoinCount2: TOmniAlignedInt32;
    procedure Log(const msg: string);
  end;

var
  frmTestParallelJoin: TfrmTestParallelJoin;

implementation

uses
  System.Diagnostics,
  OtlTask,
  OtlParallel;

{$R *.dfm}

procedure TfrmTestParallelJoin.btnCancelClick(Sender: TObject);
begin
  FJoinCount.Value := 0;
  Parallel.Join(
    procedure (const joinState: IOmniJoinState)
    begin
      Sleep(500);
      joinState.Cancel;
    end,
    procedure (const joinState: IOmniJoinState)
    var
      i: integer;
    begin
      for i := 1 to 10 do begin
        Sleep(100);
        FJoinCount.Increment;
        if joinState.IsCancelled then
          break; //for
      end;
    end
  ).Execute;
  Log(Format('Join counted up to %d', [FJoinCount.Value]));
end;

procedure TfrmTestParallelJoin.btnJoinAllClick(Sender: TObject);
var
  expectedTime: integer;
  join        : IOmniParallelJoin;
  sw          : TStopwatch;
begin
  if Sender = btnJoinOne then
    expectedTime := 5
  else
    expectedTime := 3;
  Log(Format('Starting two tasks, expected execution time is %d seconds', [expectedTime]));
  sw := TStopwatch.StartNew;
  join := Parallel.Join(
    procedure (const joinState: IOmniJoinState)
    begin
      Sleep(3000);
    end,
    procedure (const joinState: IOmniJoinState)
    begin
      Sleep(2000);
    end);
  if Sender = btnJoinOne then
    join.NumTasks(1);
  join.Execute;
  Log(Format('Tasks stopped, execution time was %s seconds',
    [FormatDateTime('s.zzz', sw.ElapsedMilliseconds/MSecsPerDay)]));
end;

procedure TfrmTestParallelJoin.btnJoinTProcClick(Sender: TObject);
var
  expectedTime: integer;
  sw          : TStopwatch;
begin
  if Environment.Process.Affinity.Count = 1 then
    expectedTime := 5
  else
    expectedTime := 3;
  Log(Format('Starting two tasks, expected execution time is %d seconds', [expectedTime]));
  sw := TStopwatch.StartNew;
  Parallel.Join(
    procedure
    begin
      Sleep(3000);
    end,
    procedure
    begin
      Sleep(2000);
    end).Execute;
  Log(Format('Tasks stopped, execution time was %s seconds',
    [FormatDateTime('s.zzz', sw.ElapsedMilliseconds/MSecsPerDay)]));
end;

procedure TfrmTestParallelJoin.btnNoWaitClick(Sender: TObject);
var
  join: IOmniParallelJoin;
  sw  : TStopwatch;
begin
  FJoinCount.Value := 0;
  FJoinCount2.Value := 0;
  join := Parallel.Join(
    procedure (const joinState: IOmniJoinState)
    var
      i: integer;
    begin
      for i := 1 to 10 do begin
        Sleep(100);
        FJoinCount.Increment;
        if joinState.IsCancelled then
          break; //for
      end;
    end,
    procedure (const joinState: IOmniJoinState)
    var
      i: integer;
    begin
      for i := 1 to 10 do begin
        Sleep(200);
        FJoinCount2.Increment;
        if joinState.IsCancelled then
          break; //for
      end;
    end
  ).NoWait.Execute;
  Sleep(500);
  sw := TStopwatch.StartNew;
  join.Cancel.WaitFor(INFINITE);
  Log(Format('Waited %d ms for joins to terminate', [sw.ElapsedMilliseconds]));
  Log(Format('Joins counted up to %d and %d', [FJoinCount.Value, FJoinCount2.Value]));
end;

procedure TfrmTestParallelJoin.Log(const msg: string);
begin
  lbLog.ItemIndex := lbLog.Items.Add(FormatDateTime('hh:nn:ss', Now) + ' ' + msg);
end;

end.
