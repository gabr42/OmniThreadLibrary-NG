///<summary>Cross-platform container observer for background thread notification.
///    Part of the OmniThreadLibrary project.</summary>
///<author>Primoz Gabrijelcic, Claude</author>
///<license>
///This software is distributed under the BSD license.
///
///Copyright (c) 2026 Primoz Gabrijelcic
///All rights reserved.
///
///Redistribution and use in source and binary forms, with or without modification,
///are permitted provided that the following conditions are met:
///- Redistributions of source code must retain the above copyright notice, this
///  list of conditions and the following disclaimer.
///- Redistributions in binary form must reproduce the above copyright notice,
///  this list of conditions and the following disclaimer in the documentation
///  and/or other materials provided with the distribution.
///- The name of the Primoz Gabrijelcic may not be used to endorse or promote
///  products derived from this software without specific prior written permission.
///
///THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
///ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
///WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
///DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
///ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
///(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
///LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
///ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
///(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
///SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
///</license>
///<remarks><para>
///   Home              : http://www.omnithreadlibrary.com
///   Support           : https://en.delphipraxis.net/forum/32-omnithreadlibrary/
///   Author            : Primoz Gabrijelcic
///     E-Mail          : primoz@gabrijelcic.org
///     Blog            : http://thedelphigeek.com
///   Contributors      : Claude AI
///   Creation date     : 2026-04-12
///   Last modification : 2026-06-01
///   Version           : 1.04
///</para><para>
///   History:
///     1.04: 2026-06-01
///       - Fixed orphaned APC-ref leak: when Notify had queued an APC but the
///         target thread terminated without ever entering an alertable wait,
///         APCCallback never ran, so the AddRef from QueueUserAPC was never
///         balanced and TAPCState (plus everything its OnNotify closure
///         captured) leaked. Destroy now detects a dead target via
///         GetExitCodeThread and reclaims the orphaned ref via a new
///         ReleaseStateRefs helper (atomic subtract, free on <= 0). The thread
///         handle is opened with THREAD_QUERY_INFORMATION in addition to
///         THREAD_SET_CONTEXT so GetExitCodeThread can succeed. OTL-NG analog
///         of GpEventBus r41604 / r41702.
///     1.03: 2026-04-18
///       - DrainBackgroundObservers is now cross-platform. On Windows it runs a
///         zero-timeout alertable wait to drain queued APCs; on POSIX it drains
///         the thread-local observer registry. Callers no longer need IFDEFs.
///     1.02: 2026-04-17
///       - Observer lifetime now managed by interface refcount. Added
///         IOmniContainerBackgroundObserver; factory returns interface;
///         Register/UnregisterBackgroundObserver take interface.
///     1.01: 2026-04-14
///       - Fixed FState leak on OpenThread failure in constructor; also
///         captured GetLastError before FreeMem to preserve error code.
///     1.0: 2026-04-12 [OTL-NG]
///       - Initial implementation. APC-based container observer for delivering
///         task notifications to background thread owners on Windows.
///         Modeled on GpEventBus QueueUserAPC dispatch pattern.
///       - Cross-platform restructure. Renamed from OtlAPCDispatch.pas.
///       - Windows: QueueUserAPC-based delivery (unchanged logic).
///       - POSIX: Atomic pending flag + thread-local registry for semi-automatic
///         delivery in OTL worker thread owners.
///       - Fixed bug: removed incorrect CanNotify check from Notify (was silencing
///         observer after first notification).
///       - Added IOmniEvent to all observer implementations for wait-set injection.
///         When owner is an OTL worker task, the event is registered as a wait object
///         in the owner's message loop for immediate notification delivery.
///       - Windows APC delivery retained for non-OTL-task owners (plain TThread).
///</para></remarks>

unit OtlBackgroundObserver;

{$I OtlOptions.inc}

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Classes,
  OtlSync,
  OtlContainerObserver;

type
  IOmniContainerBackgroundObserver = interface(IOmniContainerObserver)
    ['{7A12E3F5-4C6B-4A28-B1D6-5D9C8F6B3E21}']
    function GetNotifyEvent: IOmniEvent;
  end;

  TOmniContainerBackgroundObserver = class(TOmniContainerObserver, IOmniContainerBackgroundObserver)
  public
    function GetNotifyEvent: IOmniEvent; virtual; abstract;
  end;

{:Creates a background observer targeting the specified thread.
  On Windows, uses QueueUserAPC for non-OTL-task owners (plain TThread in
  alertable wait). On all platforms, the observer exposes an IOmniEvent via
  GetNotifyEvent that can be registered in the owner's wait set for immediate
  delivery when the owner is an OTL worker task.
  @param   aTargetThreadID OS thread ID of the owner thread.
  @param   aOnNotify       Callback invoked on the owner thread.
                            Typically calls ProcessMessages to drain the comm channel.
  @returns Background observer interface. Lifetime is reference-counted.
  @since   2026-04-12
}
function CreateContainerBackgroundObserver(aTargetThreadID: TThreadID;
  const aOnNotify: TProc): IOmniContainerBackgroundObserver;

{:Drains all pending background notifications for the current thread.
  Cross-platform: on Windows performs a zero-timeout alertable wait to run
  queued APCs; on POSIX drains the thread-local observer registry.
  No-op if nothing is pending.
  @since   2026-04-12
}
procedure DrainBackgroundObservers;

{$IFNDEF OTL_HasAPC}
{:Registers a background observer in the current thread's registry.
  Called from CreateInternalMonitor on the owner thread.
  @since   2026-04-12
}
procedure RegisterBackgroundObserver(const aObserver: IOmniContainerBackgroundObserver);

{:Unregisters a background observer from the current thread's registry.
  Called from Terminate cleanup on the owner thread.
  @since   2026-04-12
}
procedure UnregisterBackgroundObserver(const aObserver: IOmniContainerBackgroundObserver);

{:Frees the current thread's background observer registry.
  Called from TOmniTaskExecutor.Cleanup to prevent threadvar leaks.
  @since   2026-04-12
}
procedure CleanupBackgroundObserverRegistry;
{$ENDIF}

implementation

uses
  {$IFDEF OTL_HasAPC}
  Winapi.Windows,
  {$ENDIF OTL_HasAPC}
  System.Generics.Collections,
  OtlCommon; // needed for inline expansion of TOmniContainerObserver methods

{$IFDEF OTL_HasAPC}

// === Windows implementation: QueueUserAPC + IOmniEvent for wait-set injection ===

const
  THREAD_SET_CONTEXT       = $0010;
  THREAD_QUERY_INFORMATION = $0040;

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

  TOmniContainerAPCObserverImpl = class(TOmniContainerBackgroundObserver)
  strict private
    FNotifyEvent : IOmniEvent;
    FState       : PAPCState;
    FThreadHandle: THandle;
  public
    constructor Create(aTargetThreadID: TThreadID; const aOnNotify: TProc);
    destructor  Destroy; override;
    function  GetNotifyEvent: IOmniEvent; override;
    procedure Notify; override;
  end;

{:Atomically subtract `count` refs from the state's RefCount and free the block
  when the running total reaches zero (or below). The `<= 0` guard — rather than
  `= 0` — lets a dead-target reclaim in Destroy fold the orphaned APC ref into
  the same release without risking a double FreeMem if the counts ever overlap.
  Mirrors TEventBus.TThreadDispatchState.ReleaseRefs in GpEventBus.}
procedure ReleaseStateRefs(state: PAPCState; count: integer);
begin
  if TInterlocked.Add(state.RefCount, -count) <= 0 then begin
    state.OnNotify := nil;
    FreeMem(state);
  end;
end; { ReleaseStateRefs }

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
    ReleaseStateRefs(state, 1);  // balance the AddRef from Notify's QueueUserAPC
  end;
end; { APCCallback }

{ TOmniContainerAPCObserverImpl }

constructor TOmniContainerAPCObserverImpl.Create(aTargetThreadID: TThreadID;
  const aOnNotify: TProc);
begin
  inherited Create;
  FNotifyEvent := CreateOmniEvent(false, false);
  FState := AllocMem(SizeOf(TAPCState));
  FState.RefCount := 1;
  FState.APCPending := 0;
  FState.IsActive := 1;
  FState.OnNotify := aOnNotify;
  // THREAD_SET_CONTEXT is required by QueueUserAPC; THREAD_QUERY_INFORMATION is
  // required by GetExitCodeThread, which Destroy uses to detect a dead target
  // and reclaim an orphaned APC ref. Without the query right GetExitCodeThread
  // would fail and the reclaim would never trigger (TAPCState would leak).
  FThreadHandle := OpenThread(THREAD_SET_CONTEXT or THREAD_QUERY_INFORMATION,
    false, aTargetThreadID);
  if FThreadHandle = 0 then begin
    var lastErr := Winapi.Windows.GetLastError;
    FreeMem(FState);
    FState := nil;
    raise EOSError.CreateFmt(
      'TOmniContainerAPCObserverImpl.Create: OpenThread failed for thread %d, error [%d] %s',
      [aTargetThreadID, lastErr, SysErrorMessage(lastErr)]);
  end;
end; { TOmniContainerAPCObserverImpl.Create }

destructor TOmniContainerAPCObserverImpl.Destroy;
begin
  if assigned(FState) then begin
    TInterlocked.Exchange(FState.IsActive, 0);
    // If an APC is still queued (APCPending=1) but the target thread has
    // already terminated, that APC will never be delivered (dead threads never
    // enter alertable wait), so the AddRef from its QueueUserAPC will never be
    // balanced by APCCallback. Detect that case via GetExitCodeThread and
    // reclaim the orphaned APC ref together with the observer's own ref in a
    // single atomic release. A live target is left at RefCount=1 so the APC
    // still frees the state when it eventually fires (IsActive=0 makes its
    // callback a no-op). The atomic Exchange on APCPending claims the reclaim
    // exactly once; a dead thread cannot be concurrently clearing it.
    var extraRefs := 0;
    if TInterlocked.CompareExchange(FState.APCPending, 0, 0) = 1 then begin
      var exitCode: DWORD;
      if (not GetExitCodeThread(FThreadHandle, exitCode)) or (exitCode <> STILL_ACTIVE) then
        if TInterlocked.Exchange(FState.APCPending, 0) = 1 then
          extraRefs := 1;
    end;
    ReleaseStateRefs(FState, 1 + extraRefs);
    FState := nil;
  end;
  if FThreadHandle <> 0 then begin
    CloseHandle(FThreadHandle);
    FThreadHandle := 0;
  end;
  FNotifyEvent := nil;
  inherited;
end; { TOmniContainerAPCObserverImpl.Destroy }

function TOmniContainerAPCObserverImpl.GetNotifyEvent: IOmniEvent;
begin
  Result := FNotifyEvent;
end; { TOmniContainerAPCObserverImpl.GetNotifyEvent }

procedure TOmniContainerAPCObserverImpl.Notify;
begin
  // Signal the event for wait-set-based delivery (OTL worker task owners).
  // The event is auto-reset so the wait fires once per signal batch.
  FNotifyEvent.SetEvent;
  // Also queue APC for non-OTL-task owners (plain TThread in alertable wait).
  // Coalesce: only queue if no APC is already pending.
  if TInterlocked.CompareExchange(FState.APCPending, 1, 0) = 0 then begin
    TInterlocked.Increment(FState.RefCount);
    if not QueueUserAPC(@APCCallback, FThreadHandle, NativeUInt(FState)) then begin
      // APC queue failed (target thread may have terminated): roll back the
      // pending flag and the AddRef. The observer still holds its own ref here,
      // so RefCount cannot reach zero and FState stays valid.
      TInterlocked.Exchange(FState.APCPending, 0);
      ReleaseStateRefs(FState, 1);
    end;
  end;
end; { TOmniContainerAPCObserverImpl.Notify }

{$ELSE}

// === POSIX implementation: IOmniEvent + thread-local registry ===

type
  IOmniContainerCVObserver = interface
    ['{B15F0E97-8E5F-4EB6-B3F4-7A3D2A8D7F12}']
    procedure DrainPending;
  end;

  TOmniContainerCVObserverImpl = class(TOmniContainerBackgroundObserver, IOmniContainerCVObserver)
  strict private
    FCVPending  : integer;    // atomic 0/1 coalescing flag
    FIsActive   : integer;    // atomic 0/1; cleared on destroy
    FNotifyEvent: IOmniEvent; // signalled on each Notify for wait-set delivery
    FOnNotify   : TProc;      // callback executed on owner thread
  public
    constructor Create(const aOnNotify: TProc);
    destructor  Destroy; override;
    function  GetNotifyEvent: IOmniEvent; override;
    procedure Notify; override;
    procedure DrainPending;
  end;

{ TOmniContainerCVObserverImpl }

constructor TOmniContainerCVObserverImpl.Create(const aOnNotify: TProc);
begin
  inherited Create;
  FNotifyEvent := CreateOmniEvent(false, false);
  FCVPending := 0;
  FIsActive := 1;
  FOnNotify := aOnNotify;
end; { TOmniContainerCVObserverImpl.Create }

destructor TOmniContainerCVObserverImpl.Destroy;
begin
  TInterlocked.Exchange(FIsActive, 0);
  FOnNotify := nil;
  FNotifyEvent := nil;
  inherited;
end; { TOmniContainerCVObserverImpl.Destroy }

function TOmniContainerCVObserverImpl.GetNotifyEvent: IOmniEvent;
begin
  Result := FNotifyEvent;
end; { TOmniContainerCVObserverImpl.GetNotifyEvent }

procedure TOmniContainerCVObserverImpl.Notify;
begin
  // Signal the event for wait-set-based delivery (OTL worker task owners).
  FNotifyEvent.SetEvent;
  // Also set pending flag for thread-local registry drain (non-OTL owners).
  TInterlocked.CompareExchange(FCVPending, 1, 0);
end; { TOmniContainerCVObserverImpl.Notify }

procedure TOmniContainerCVObserverImpl.DrainPending;
begin
  if TInterlocked.CompareExchange(FIsActive, 1, 1) <> 1 then
    Exit;
  if TInterlocked.Exchange(FCVPending, 0) = 1 then
    FOnNotify();
end; { TOmniContainerCVObserverImpl.DrainPending }

{ Thread-local background observer registry }

type
  TOmniBackgroundObserverRegistry = class
  strict private
    FList: TList<IOmniContainerBackgroundObserver>;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure Add(const aObserver: IOmniContainerBackgroundObserver);
    procedure Remove(const aObserver: IOmniContainerBackgroundObserver);
    procedure DrainAll;
  end;

threadvar
  _BackgroundObserverRegistry: TOmniBackgroundObserverRegistry;

constructor TOmniBackgroundObserverRegistry.Create;
begin
  inherited Create;
  FList := TList<IOmniContainerBackgroundObserver>.Create;
end; { TOmniBackgroundObserverRegistry.Create }

destructor TOmniBackgroundObserverRegistry.Destroy;
begin
  FreeAndNil(FList);
  inherited;
end; { TOmniBackgroundObserverRegistry.Destroy }

procedure TOmniBackgroundObserverRegistry.Add(const aObserver: IOmniContainerBackgroundObserver);
begin
  if FList.IndexOf(aObserver) < 0 then
    FList.Add(aObserver);
end; { TOmniBackgroundObserverRegistry.Add }

procedure TOmniBackgroundObserverRegistry.Remove(const aObserver: IOmniContainerBackgroundObserver);
begin
  FList.Remove(aObserver);
end; { TOmniBackgroundObserverRegistry.Remove }

procedure TOmniBackgroundObserverRegistry.DrainAll;
var
  i: integer;
begin
  for i := 0 to FList.Count - 1 do
    (FList[i] as IOmniContainerCVObserver).DrainPending;
end; { TOmniBackgroundObserverRegistry.DrainAll }

procedure RegisterBackgroundObserver(const aObserver: IOmniContainerBackgroundObserver);
begin
  if not assigned(_BackgroundObserverRegistry) then
    _BackgroundObserverRegistry := TOmniBackgroundObserverRegistry.Create;
  _BackgroundObserverRegistry.Add(aObserver);
end; { RegisterBackgroundObserver }

procedure UnregisterBackgroundObserver(const aObserver: IOmniContainerBackgroundObserver);
begin
  if assigned(_BackgroundObserverRegistry) then
    _BackgroundObserverRegistry.Remove(aObserver);
end; { UnregisterBackgroundObserver }

procedure CleanupBackgroundObserverRegistry;
begin
  FreeAndNil(_BackgroundObserverRegistry);
end; { CleanupBackgroundObserverRegistry }

{$ENDIF OTL_HasAPC}

{ Cross-platform drain }

procedure DrainBackgroundObservers;
{$IFDEF OTL_HasAPC}
var
  dummyHandle: THandle;
{$ENDIF}
begin
  {$IFDEF OTL_HasAPC}
  // MWMO_ALERTABLE + zero timeout + empty wait set: runs any queued APCs on
  // the current thread without yielding the time slice. The handle parameter
  // is declared `var` but not read when nCount=0, so a stack dummy suffices.
  MsgWaitForMultipleObjectsEx(0, dummyHandle, 0, 0, MWMO_ALERTABLE);
  {$ELSE}
  if assigned(_BackgroundObserverRegistry) then
    _BackgroundObserverRegistry.DrainAll;
  {$ENDIF}
end; { DrainBackgroundObservers }

{ Factory }

function CreateContainerBackgroundObserver(aTargetThreadID: TThreadID;
  const aOnNotify: TProc): IOmniContainerBackgroundObserver;
begin
  {$IFDEF OTL_HasAPC}
  Result := TOmniContainerAPCObserverImpl.Create(aTargetThreadID, aOnNotify);
  {$ELSE}
  Result := TOmniContainerCVObserverImpl.Create(aOnNotify);
  {$ENDIF}
end; { CreateContainerBackgroundObserver }

end.
