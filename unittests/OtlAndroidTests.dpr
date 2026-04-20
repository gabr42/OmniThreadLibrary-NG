program OtlAndroidTests;

{$STRONGLINKTYPES ON}

uses
  System.StartUpCopy,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  FMX.Forms,
  FMX.Types,
  Androidapi.Log,
  Androidapi.IOUtils,
  DUnitX.TestFramework,
  DUnitX.FilterBuilder,
  DUNitX.Loggers.MobileGUI in 'DUNitX.Loggers.MobileGUI.pas' {MobileGUITestRunner}
  , SmokeTest in 'SmokeTest.pas'
  , TestOtlBase in 'TestOtlBase.pas'
  , TestPlatform in 'TestPlatform.pas'
  , TestValue in 'TestValue.pas'
  , TestOmniValue in 'TestOmniValue.pas'
  , TestInterlocked in 'TestInterlocked.pas'
  , TestOmniInterfaceDictionary in 'TestOmniInterfaceDictionary.pas'
  , TestOtlCommon1 in 'TestOtlCommon1.pas'
  , TestOtlSync1 in 'TestOtlSync1.pas'
  , TestSyncUtils1 in 'TestSyncUtils1.pas'
  , TestContainers in 'TestContainers.pas'
  , TestBlockingCollection1 in 'TestBlockingCollection1.pas'
  , TestOtlDataManager1 in 'TestOtlDataManager1.pas'
  , TestOtlComm in 'TestOtlComm.pas'
  , TestContainerObserver1 in 'TestContainerObserver1.pas'
  , TestTask in 'TestTask.pas'
  , TestUnobserved in 'TestUnobserved.pas'
  , TestOtlParallel in 'TestOtlParallel.pas'
  , TestRegressions in 'TestRegressions.pas'
  , TestBackgroundObserver1 in 'TestBackgroundObserver1.pas'
  , TestChannel1 in 'TestChannel1.pas'
  , TestSelect1 in 'TestSelect1.pas'
  , TestMergeRace1 in 'TestMergeRace1.pas'
  , TestHooks1 in 'TestHooks1.pas'
  , TestOtlThreadPool1 in 'TestOtlThreadPool1.pas'
  , TestOtlEventMonitor1 in 'TestOtlEventMonitor1.pas'
  , TestStressBlockingCollection1 in 'TestStressBlockingCollection1.pas'
  , TestStressOtlSync1 in 'TestStressOtlSync1.pas'
  , TestStressBackgroundObserver1 in 'TestStressBackgroundObserver1.pas'
  , TestStressContainerObserver1 in 'TestStressContainerObserver1.pas'
  , TestOtlLogger in 'TestOtlLogger.pas';

{$R *.res}

procedure ALog(const msg: string);
var
  utf8: RawByteString;
begin
  utf8 := UTF8Encode('OTL_DIAG: ' + msg);
  __android_log_write(ANDROID_LOG_INFO, MarshaledAString(RawByteString('OTL_DIAG')), MarshaledAString(utf8));
end;

var
  GSavedExitProc: pointer;
  GPrevExceptProc: pointer;

procedure OnExit;
begin
  ALog('OnExit proc fired, ExitCode=' + IntToStr(System.ExitCode));
  System.ExitProc := GSavedExitProc;
end;

type
  _Unwind_Context = pointer;
  _Unwind_Word = NativeUInt;
  _Unwind_Reason_Code = integer;
  _Unwind_Trace_Fn = function(Context: _Unwind_Context; UserData: pointer): _Unwind_Reason_Code; cdecl;

function _Unwind_Backtrace(trace: _Unwind_Trace_Fn; trace_argument: pointer): _Unwind_Reason_Code; cdecl; external 'libunwind.so';
function _Unwind_GetIP(Context: _Unwind_Context): _Unwind_Word; cdecl; external 'libunwind.so';

var
  GBtAddrs: array[0..31] of _Unwind_Word;
  GBtCount: integer;

function TraceCallback(Context: _Unwind_Context; UserData: pointer): _Unwind_Reason_Code; cdecl;
begin
  if GBtCount < Length(GBtAddrs) then begin
    GBtAddrs[GBtCount] := _Unwind_GetIP(Context);
    Inc(GBtCount);
    Result := 0; // _URC_NO_REASON / continue
  end
  else
    Result := 5; // _URC_END_OF_STACK
end;

procedure LogBacktrace;
var
  i: integer;
  line: string;
begin
  GBtCount := 0;
  _Unwind_Backtrace(@TraceCallback, nil);
  line := 'BT';
  for i := 0 to GBtCount - 1 do
    line := line + ' ' + IntToHex(GBtAddrs[i], 16);
  ALog(line);
end;

procedure DiagExceptProc(ExceptObject: TObject; ExceptAddr: Pointer);
var
  errorCode: integer;
  msg: string;
begin
  msg := 'UNHANDLED EXCEPTION ' + ExceptObject.ClassName;
  if ExceptObject is EInOutError then
    errorCode := EInOutError(ExceptObject).ErrorCode
  else
    errorCode := 0;
  if ExceptObject is Exception then
    msg := msg + ': [' + Exception(ExceptObject).Message + ']';
  msg := msg + ' ErrorCode=' + IntToStr(errorCode) + ' ExceptAddr=' + IntToHex(NativeUInt(ExceptAddr), 16);
  ALog(msg);
  LogBacktrace;
end;

// RaiseExceptObjProc fires at the RAISE SITE, before stack unwind — so the
// backtrace captured here shows where the exception is actually thrown from.
type
  PExceptionRecord = ^TExceptionRecord;
  TExceptionRecord = record
    ExceptionCode: Cardinal;
    ExceptionFlags: Cardinal;
    InnerException: Pointer;
    ExceptionAddress: Pointer;
    NumberParameters: Cardinal;
    ExceptAddr: Pointer;
    ExceptObject: TObject;
  end;

var
  GRaiseSiteCount: integer = 0;

procedure DiagRaiseExceptObjProc(P: PExceptionRecord); cdecl;
var
  msg: string;
  obj: TObject;
begin
  Inc(GRaiseSiteCount);
  obj := P.ExceptObject;
  if obj = nil then begin
    ALog('RAISE #' + IntToStr(GRaiseSiteCount) + ' obj=nil');
    exit;
  end;
  msg := 'RAISE #' + IntToStr(GRaiseSiteCount) + ' ' + obj.ClassName;
  if obj is Exception then
    msg := msg + ': [' + Exception(obj).Message + ']';
  if obj is EInOutError then
    msg := msg + ' ErrorCode=' + IntToStr(EInOutError(obj).ErrorCode);
  msg := msg + ' ExceptAddr=' + IntToHex(NativeUInt(P.ExceptAddr), 16);
  ALog(msg);
  LogBacktrace;
end;

begin
  GSavedExitProc := System.ExitProc;
  System.ExitProc := @OnExit;
  GPrevExceptProc := System.ExceptProc;
  System.ExceptProc := @DiagExceptProc;
  System.RaiseExceptObjProc := @DiagRaiseExceptObjProc;
  ALog('ALog address=' + IntToHex(NativeUInt(@ALog), 16));

  // Default-exclude the Stress category — Android has no CLI so these
  // multi-minute stress tests would otherwise block the auto-run.
  // The MobileGUI runner never calls CheckCommandLine, so Options.Exclude
  // alone has no effect — the filter must be built and assigned manually.
  TDUnitX.Options.Exclude := 'Stress';
  TDUnitX.Filter := TDUnitXFilterBuilder.BuildFilter(TDUnitX.Options);

  ALog('main begin');
  try
    ALog('before Application.Initialize');
    Application.Initialize;
    ALog('after Application.Initialize');
    ALog('before CreateForm');
    Application.CreateForm(TMobileGUITestRunner, MobileGUITestRunner);
    ALog('after CreateForm');
    ALog('before Application.Run');
    Application.Run;
    ALog('after Application.Run');
  except
    on E: Exception do
      ALog('OUTER EXCEPTION ' + E.ClassName + ': ' + E.Message);
  end;
  ALog('main end');
end.
