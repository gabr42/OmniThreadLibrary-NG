program app_3_HelloWorld_with_package.XE3;

{$R 'MainIcon.res' '..\..\res\MainIcon.rc'}

uses
  FastMM4,
  Forms,
  test_3_HelloWorld_with_package in 'test_3_HelloWorld_with_package.pas' {frmTestHelloWorld},
  OtlCommon in '..\..\OtlCommon.pas',
  OtlTask in '..\..\OtlTask.pas',
  OtlThreadPool in '..\..\OtlThreadPool.pas',
  OtlComm in '..\..\OtlComm.pas';

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmTestHelloWorld, frmTestHelloWorld);
  Application.Run;
end.
