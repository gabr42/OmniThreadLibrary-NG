program app_71_DLL;

// Compile dll_71_DLL into the same folder before running this program.

uses
  Forms,
  test_71_DLL in 'test_71_DLL.pas' {frmTestDLL},
  api_71_DLL in 'api_71_DLL.pas';

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmTestDLL, frmTestDLL);
  Application.Run;
end.
