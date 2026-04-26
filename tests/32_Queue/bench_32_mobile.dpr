///<summary>Android (FMX) variant of the TOmniBaseQueue benchmark.
///   On startup the form kicks off the shared bench runner on a worker
///   thread and streams each result line to a TMemo on screen. Every line
///   also goes to the Android log tagged `OTL_DIAG` so `adb logcat` can
///   capture results without touching the device. The Windows-desktop
///   / Linux console variant is bench_32_console.dpr.</summary>

program bench_32_mobile;

{$STRONGLINKTYPES ON}

uses
  System.StartUpCopy,
  FMX.Forms,
  bench_32_shared in 'bench_32_shared.pas',
  bench_32_mobile_main in 'bench_32_mobile_main.pas' {frmBench32Mobile};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TfrmBench32Mobile, frmBench32Mobile);
  Application.Run;
end.
