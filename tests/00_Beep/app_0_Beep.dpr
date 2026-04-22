program app_0_Beep.XE3;

{$R 'MainIcon.res' '..\..\res\MainIcon.rc'}

uses
  FastMM4,
  Forms,
  test_0_Beep in 'test_0_Beep.pas' {frmTestSimple};

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmTestSimple, frmTestSimple);
  Application.Run;
end.
