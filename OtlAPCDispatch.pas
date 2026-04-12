///<summary>APC-based container observer for background thread notification.
///    Part of the OmniThreadLibrary project.</summary>
///<author>Primoz Gabrijelcic, Claude</author>
///<remarks><para>
///   Home              : http://www.omnithreadlibrary.com
///   Support           : https://en.delphipraxis.net/forum/32-omnithreadlibrary/
///   Author            : Primoz Gabrijelcic
///     E-Mail          : primoz@gabrijelcic.org
///     Blog            : http://thedelphigeek.com
///   Creation date     : 2026-04-12
///   Last modification : 2026-04-12
///   Version           : 1.0
///</para><para>
///   History:
///     1.0: 2026-04-12
///       - Initial implementation. APC-based container observer for delivering
///         task notifications to background thread owners on Windows.
///         Modeled on GpEventBus QueueUserAPC dispatch pattern.
///</para></remarks>

unit OtlAPCDispatch;

{$I OtlOptions.inc}

{$IFDEF OTL_HasAPC}

interface

uses
  Winapi.Windows,
  System.SysUtils,
  System.SyncObjs,
  OtlContainerObserver;

type
  TOmniContainerAPCObserver = class(TOmniContainerObserver)
  end;

{:Creates an APC observer targeting the specified thread.
  @param   aTargetThreadID OS thread ID of the thread that should receive APC callbacks.
  @param   aOnNotify       Procedure called on the target thread when APC fires.
                            Typically calls ProcessMessages to drain the comm channel.
  @returns APC observer instance. Caller must free.
  @since   2026-04-12
}
function CreateContainerAPCObserver(aTargetThreadID: TThreadID;
  const aOnNotify: TProc): TOmniContainerAPCObserver;

implementation

uses
  OtlCommon; // needed for inline expansion of TOmniContainerObserver methods

const
  THREAD_SET_CONTEXT = $0010;

function OpenThread(dwDesiredAccess: DWORD; bInheritHandle: BOOL;
  dwThreadId: DWORD): THandle; stdcall; external kernel32;

type
  PAPCState = ^TAPCState;
  TAPCState = record
    RefCount  : integer;  // interlocked; observer=1 ref, each pending APC=1 ref
    APCPending: integer;  // atomic 0/1 flag; coalesces multiple Notify calls
    IsActive  : integer;  // atomic 0/1; set to 0 on destroy so stale APCs are no-ops
    OnNotify  : TProc;    // callback executed on target thread
  end;

  TOmniContainerAPCObserverImpl = class(TOmniContainerAPCObserver)
  strict private
    FState       : PAPCState;
    FThreadHandle: THandle;
  public
    constructor Create(aTargetThreadID: TThreadID; const aOnNotify: TProc);
    destructor  Destroy; override;
    procedure Notify; override;
  end;

procedure APCCallback(dwParam: NativeUInt); stdcall;
var
  state: PAPCState;
begin
  state := PAPCState(dwParam);
  // Clear pending flag BEFORE executing so new notifications during
  // execution will queue another APC
  TInterlocked.Exchange(state.APCPending, 0);
  try
    if TInterlocked.CompareExchange(state.IsActive, 1, 1) = 1 then
      state.OnNotify();
  finally
    if TInterlocked.Decrement(state.RefCount) = 0 then begin
      state.OnNotify := nil;
      FreeMem(state);
    end;
  end;
end; { APCCallback }

{ TOmniContainerAPCObserverImpl }

constructor TOmniContainerAPCObserverImpl.Create(aTargetThreadID: TThreadID;
  const aOnNotify: TProc);
begin
  inherited Create;
  FState := AllocMem(SizeOf(TAPCState));
  FState.RefCount := 1;
  FState.APCPending := 0;
  FState.IsActive := 1;
  FState.OnNotify := aOnNotify;
  FThreadHandle := OpenThread(THREAD_SET_CONTEXT, false, aTargetThreadID);
  if FThreadHandle = 0 then
    raise EOSError.CreateFmt(
      'TOmniContainerAPCObserverImpl.Create: OpenThread failed for thread %d, error [%d] %s',
      [aTargetThreadID, Winapi.Windows.GetLastError, SysErrorMessage(Winapi.Windows.GetLastError)]);
  Activate;
end; { TOmniContainerAPCObserverImpl.Create }

destructor TOmniContainerAPCObserverImpl.Destroy;
begin
  if assigned(FState) then begin
    TInterlocked.Exchange(FState.IsActive, 0);
    if TInterlocked.Decrement(FState.RefCount) = 0 then begin
      FState.OnNotify := nil;
      FreeMem(FState);
    end;
    FState := nil;
  end;
  if FThreadHandle <> 0 then begin
    CloseHandle(FThreadHandle);
    FThreadHandle := 0;
  end;
  inherited;
end; { TOmniContainerAPCObserverImpl.Destroy }

procedure TOmniContainerAPCObserverImpl.Notify;
begin
  if not CanNotify then
    Exit;
  // Coalesce: only queue if no APC is already pending
  if TInterlocked.CompareExchange(FState.APCPending, 1, 0) = 0 then begin
    TInterlocked.Increment(FState.RefCount);
    if not QueueUserAPC(@APCCallback, FThreadHandle, NativeUInt(FState)) then begin
      // APC queue failed (target thread may have terminated)
      TInterlocked.Exchange(FState.APCPending, 0);
      if TInterlocked.Decrement(FState.RefCount) = 0 then begin
        FState.OnNotify := nil;
        FreeMem(FState);
        FState := nil;
      end;
    end;
  end;
end; { TOmniContainerAPCObserverImpl.Notify }

function CreateContainerAPCObserver(aTargetThreadID: TThreadID;
  const aOnNotify: TProc): TOmniContainerAPCObserver;
begin
  Result := TOmniContainerAPCObserverImpl.Create(aTargetThreadID, aOnNotify);
end; { CreateContainerAPCObserver }

{$ELSE}

interface

implementation

{$ENDIF OTL_HasAPC}

end.
