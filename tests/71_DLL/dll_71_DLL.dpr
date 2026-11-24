library dll_71_DLL;

// Shows how to use OmniThreadLibrary in a DLL. See worker_71_DLL.pas for the rules.

uses
  worker_71_DLL in 'worker_71_DLL.pas',
  api_71_DLL in 'api_71_DLL.pas';

exports
  StartWork,
  CancelWork,
  PrepareForUnload;

begin
  // Don't start tasks here. This code is executed while Windows owns the loader lock.
end.
