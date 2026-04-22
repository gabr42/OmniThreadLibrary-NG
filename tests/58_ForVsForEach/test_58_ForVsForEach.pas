unit test_58_ForVsForEach;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics,
  Controls, Forms, Dialogs, StdCtrls;

type
  TfrmForVsForEach = class(TForm)
    btnTest: TButton;
    lbLog: TListBox;
    procedure btnTestClick(Sender: TObject);
  private
    procedure Time(const name: string; proc: TProc);
  public
  end;

var
  frmForVsForEach: TfrmForVsForEach;

implementation

uses
  System.Diagnostics,
  {$IF CompilerVersion >= 28}System.Threading,{$IFEND}
  OtlParallel;

{$R *.dfm}

const
  CLoopCount = 100000000; {100 million}

procedure TfrmForVsForEach.btnTestClick(Sender: TObject);
begin
  Time('for',
    procedure
    var
      i: integer;
    begin
      for i := 1 to CLoopCount do
        ;
    end
  );

  Time('Parallel.For',
    procedure
    begin
      Parallel.For(1, CLoopCount).Execute(
        procedure (idx: integer)
        begin
        end);
    end
  );

  Time('Parallel.ForEach',
    procedure
    begin
      Parallel.ForEach(1, CLoopCount).Execute(
        procedure (const idx: integer)
        begin
        end);
    end
  );

  {$IF CompilerVersion >= 28}
  Time('TParallel.For',
    procedure
    begin
      TParallel.For(1, CLoopCount,
        procedure (idx: integer)
        begin
        end);
    end
  );
  {$IFEND}
end;

procedure TfrmForVsForEach.Time(const name: string; proc: TProc);
var
  i : Integer;
  sw: TStopwatch;
  s : string;
begin
  lbLog.ItemIndex := lbLog.Items.Add('Timing "' + name + '"');
  lbLog.Update;
  s := '';
  for i := 1 to 3 do begin
    sw := TStopwatch.StartNew;
    proc();
    if s <> '' then
      s := s + ', ';
    s := s + IntToStr(sw.ElapsedMilliseconds) + ' ms';
  end;
  lbLog.Items[lbLog.ItemIndex] := '"' + name + '" times: ' + s;
end;

end.
