unit test_55_ForEachProgress;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics,
  Controls, Forms, Dialogs, StdCtrls, ComCtrls,

  OtlTask,
  OtlParallel;

type
  TfrmForEachWithProgressBar = class(TForm)
    btnStart : TButton;
    pbForEach: TProgressBar;
    procedure btnStartClick(Sender: TObject);
    procedure FormShow(Sender: TObject);
  private
    FPosition : integer;
    FProgress : integer;
    FAutoRun  : boolean;   // started with `--auto` command-line arg
    FAutoLog  : string;    // `--autolog <path>` — write final FProgress here
    FWorker   : IOmniParallelLoop<integer>;
    procedure IncrementProgressBar;
    procedure WriteAutoLogAndClose;
  end;

var
  frmForEachWithProgressBar: TfrmForEachWithProgressBar;

implementation

{$R *.dfm}

const
  CNumLoop = 1000;

procedure TfrmForEachWithProgressBar.btnStartClick(Sender: TObject);
begin
  btnStart.Enabled := false;

  pbForEach.Max := 100;
  pbForEach.Position := 0;
  pbForEach.Update;
  FProgress := 0;
  FPosition := 0;

  // reference must be kept in a global field so that the task controller is not destroyed before the processing ends
  FWorker := Parallel
    .ForEach(1, CNumLoop)
    .NoWait // important, otherwise message loop will be blocked while ForEach waits for all tasks to terminate
    .OnStop(
      procedure (const task: IOmniTask)
      begin
        // because of NoWait, OnStop delegate is invoked from the worker code; we must not destroy the worker at that point or the program will block
        task.Invoke(
          procedure begin
            FWorker := nil;
            btnStart.Enabled := true;
            if FAutoRun then
              WriteAutoLogAndClose;
          end
        );
      end
    );

  FWorker.Execute(
    procedure (const task: IOmniTask; const i: integer)
    begin
      // do some work
      Sleep(1);

      // update the progress bar
      // we cannot use 'i' for progress as it does not increase sequentially
      // IncrementProgressBar uses internal counter to follow the progress
      task.Invoke(IncrementProgressBar);
    end
  );
end;

procedure TfrmForEachWithProgressBar.IncrementProgressBar;
var
  newPosition: integer;
begin
  Inc(FProgress);
  newPosition := Trunc((FProgress / CNumLoop)*pbForEach.Max);

  OutputDebugString(PChar(IntToStr(FProgress)));

  // make sure we don't overflow TProgressBar with messages
  if newPosition <> FPosition then begin
    pbForEach.Position := newPosition;
    FPosition := newPosition;
  end;
end;

procedure TfrmForEachWithProgressBar.FormShow(Sender: TObject);
var
  i: integer;
begin
  // Simple automation hooks. Command line switches:
  //   --auto              click Start once the form is up, close when done
  //   --autolog <path>    write the final FProgress value to <path> on done
  for i := 1 to ParamCount do begin
    if SameText(ParamStr(i), '--auto') then
      FAutoRun := true
    else if SameText(ParamStr(i), '--autolog') and (i < ParamCount) then
      FAutoLog := ParamStr(i + 1);
  end;
  if FAutoRun then begin
    // Queue the click so it fires after the form is fully shown and the
    // message loop is spinning. Without the Queue, the click would run
    // reentrantly inside FormShow and block paint.
    TThread.Queue(nil,
      procedure
      begin
        btnStartClick(btnStart);
      end);
  end;
end;

procedure TfrmForEachWithProgressBar.WriteAutoLogAndClose;
var
  f: TextFile;
begin
  if FAutoLog <> '' then begin
    AssignFile(f, FAutoLog);
    try
      Rewrite(f);
      Writeln(f, Format('FProgress=%d CNumLoop=%d', [FProgress, CNumLoop]));
    finally CloseFile(f); end;
  end;
  Close;
end;

end.
