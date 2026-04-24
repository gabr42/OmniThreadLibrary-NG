unit bench_33_mobile_main;

// FMX variant of the TOmniBlockingCollection benchmark. Auto-runs on form
// show, streams results via OTL_DIAG so `adb logcat` captures them on
// Android (matching the unit-test runner convention), and appends each
// line to a TMemo so the phone screen reflects progress too. The bench
// body executes on a worker thread — the FMX main thread stays responsive
// and `TThread.Synchronize` feeds Memo updates back to it.

interface

uses
  System.SysUtils,
  System.Classes,
  FMX.Types,
  FMX.Controls,
  FMX.Controls.Presentation,
  FMX.Forms,
  FMX.StdCtrls,
  FMX.ScrollBox,
  FMX.Memo,
  FMX.Memo.Types;

type
  TfrmBench33Mobile = class(TForm)
    memResults: TMemo;
    lblStatus : TLabel;
    procedure FormShow(Sender: TObject);
  strict private
    FAutoRunFired: boolean;
    procedure AppendLine(const msg: string);
    procedure RunBenchOnWorker;
    procedure SetStatus(const s: string);
  end;

var
  frmBench33Mobile: TfrmBench33Mobile;

implementation

{$R *.fmx}

uses
  {$IFDEF ANDROID}
  Androidapi.Log,
  {$ENDIF}
  bench_33_shared;

{$IFDEF ANDROID}
procedure LogcatDiag(const msg: string);
var
  utf8: RawByteString;
begin
  utf8 := UTF8Encode('OTL_DIAG: ' + msg);
  __android_log_write(
    ANDROID_LOG_INFO,
    MarshaledAString(RawByteString('OTL_DIAG')),
    MarshaledAString(utf8));
end;
{$ENDIF}

procedure TfrmBench33Mobile.AppendLine(const msg: string);
begin
  // Always log to logcat first — if the UI update races with a crash, at
  // least the line survives in the device log.
  {$IFDEF ANDROID}LogcatDiag(msg);{$ENDIF}
  memResults.Lines.Add(msg);
  memResults.GoToTextEnd;
end;

procedure TfrmBench33Mobile.SetStatus(const s: string);
begin
  lblStatus.Text := s;
end;

procedure TfrmBench33Mobile.RunBenchOnWorker;
begin
  TThread.CreateAnonymousThread(
    procedure
    var
      runner: TBench33Runner;
    begin
      try
        runner := TBench33Runner.Create;
        try
          runner.RunAll(
            procedure(const msg: string)
            begin
              TThread.Synchronize(nil,
                procedure
                begin
                  AppendLine(msg);
                end);
            end);
        finally FreeAndNil(runner); end;
        TThread.Synchronize(nil,
          procedure
          begin
            SetStatus('Benchmark finished');
            AppendLine('OTL_DIAG: bench33 done');
          end);
      except
        on E: Exception do begin
          var errClass: string := E.ClassName;
          var errMsg  : string := E.Message;
          TThread.Synchronize(nil,
            procedure
            begin
              AppendLine('ERROR ' + errClass + ': ' + errMsg);
              SetStatus('Benchmark failed');
            end);
        end;
      end;
    end).Start;
end;

procedure TfrmBench33Mobile.FormShow(Sender: TObject);
begin
  // FormShow fires every time the form becomes visible — guard the
  // auto-run so rotations / foreground-resumes don't relaunch the bench.
  if FAutoRunFired then Exit;
  FAutoRunFired := true;
  SetStatus('Benchmark running — see log for progress');
  RunBenchOnWorker;
end;

end.
