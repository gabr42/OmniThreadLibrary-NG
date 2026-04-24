///<summary>Android (FMX) variant of the TOmniBlockingCollection benchmark.
///   On startup the form kicks off the shared bench runner on a worker
///   thread and streams each result line to a TMemo on screen. Every line
///   also goes to the Android log tagged `OTL_DIAG` so `adb logcat` can
///   capture results without touching the device. The Windows-desktop
///   / Linux console variant is bench_33_console.dpr.</summary>

program bench_33_mobile;

{$STRONGLINKTYPES ON}

uses
  System.StartUpCopy,
  FMX.Forms,
  bench_33_shared in 'bench_33_shared.pas',
  bench_33_mobile_main in 'bench_33_mobile_main.pas' {frmBench33Mobile};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TfrmBench33Mobile, frmBench33Mobile);
  Application.Run;
end.
