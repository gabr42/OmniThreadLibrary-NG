///<summary>Observer pattern interface for the containers unit.
///    Part of the OmniThreadLibrary project.</summary>
///<author>Primoz Gabrijelcic</author>
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
///   Contributors      : Sean B. Durkin, Claude AI
///   Creation date     : 2009-02-19
///   Last modification : 2026-04-22
///   Version           : 2.07
///</para><para>
///   History:
///     2.07: 2026-04-22
///       - Added IOmniContainerMainThreadObserver + TOmniContainerMainThreadObserver +
///         CreateContainerMainThreadObserver factory: cross-platform observer that
///         dispatches a TProc callback to the main thread via TThread.ForceQueue on
///         each container notification. Multiple notifications coalesce into a
///         single main-thread call. Shutdown method lets the owner gate callback
///         execution before its referenced state is torn down.
///     2.06: 2026-04-17
///       - Fixed use-after-free race in Notify/NotifyOnce: observers are now
///         IInterface-refcounted. Snapshot holds interface refs, keeping
///         observers alive during dispatch while still releasing the read
///         lock. Pattern introduced in 2.05 was correct; the missing piece
///         was observer lifetime management.
///       - TOmniContainerObserver now descends from TInterfacedObject and
///         implements IOmniContainerObserver. Callers must use interface
///         references (IOmniContainerEventObserver etc.) and release with
///         nil instead of FreeAndNil.
///     2.05: 2026-04-14
///       - Fixed Notify/NotifyOnce: snapshot observer list under read lock
///         then dispatch outside the lock, preventing deadlock if callback
///         calls Attach/Detach.
///     2.04: 2026-04-13
///       - Added missing inherited Create call in TOmniContainerEventObserverImpl.
///     2.03: 2026-04-12
///       - Removed TOmniContainerWindowsMessageObserver class and factory function
///         (replaced by cross-platform TOmniContainerQueueObserver in OtlParallel.pas
///         and TOmniContainerBackgroundObserver in OtlBackgroundObserver.pas).
///       - Removed Winapi.Windows dependency.
///     2.02: 2026-04-12
///       - Removed unused TOmniContainerWindowsEventObserver class and factory function.
///       - Qualified Winapi.Windows.SetEvent call to avoid ambiguity with OtlSync.SetEvent.
///     2.0: 2026-04-11 [OTL-NG]
///       - Removed DSiWin32 dependency.
///       - Removed OTL_PlatformIndependent guards (always platform-independent now).
///       - Removed OTL_RaiseLastOSErrorHasAdditionalInfo guard (always available).
///     1.06: 2017-01-22
///        - TOmniContainerWindowsMessageObserverImpl.Notify and .Send handle
///          ERROR_NOT_ENOUGH_QUOTA (1816) error.
///     1.05: 2015-10-03
///       - Imported mobile support by [Sean].
///     1.04: 2010-07-01
///       - Includes OTLOptions.inc.
///     1.03: 2009-12-22
///       - TOmniContainerSubject moved here from OtlContainers because it will also be
///         used in OtlCollections.
///     1.02: 2009-11-15
///       - Windows message observer exposes some of its internals.
///     1.01: 2009-04-06
///       - External event can be provided in the TOmniContainerWindowsEventObserverImpl
///         constructor.
///       - Event is created in TOmniContainerWindowsEventObserverImpl constructor if external
///         event is not provided.
///     1.0: 2009-03-30
///       - First official release.
///</para></remarks>

unit OtlContainerObserver;

{$I OtlOptions.inc}
{$WARN SYMBOL_PLATFORM OFF} // Win32Check

interface

uses
  System.Classes,
  System.SyncObjs,
  System.SysUtils,
  System.Generics.Collections,
  OtlSync,
  OtlCommon,
  OtlEventMonitor.Notify;

type
  ///<summary>All possible actions observer can take interest in.</summary>
  TOmniContainerObserverInterest = (
    //Interests with permanent subscription:
    coiNotifyOnAllInserts, coiNotifyOnAllRemoves,
    //Interests with one-shot subscription:
    coiNotifyOnPartlyEmpty, coiNotifyOnAlmostFull
  );

  IOmniContainerObserver = interface
    ['{E9FAE8B6-8F6C-47DF-BBD3-E8E13C0D8B8A}']
    procedure Activate;
    function  CanNotify: boolean;
    procedure Deactivate;
    procedure Notify;
  end; { IOmniContainerObserver }

  IOmniContainerEventObserver = interface(IOmniContainerObserver)
    ['{4EB47D7D-F5E5-4CFA-8A7F-57A5C39E1CD5}']
    function GetEvent: IOmniEvent;
  end; { IOmniContainerEventObserver }

  IOmniContainerPlatformObserver = interface(IOmniContainerObserver)
    ['{9DA96A4B-9B3A-43C7-BAE7-36B14B68EBE5}']
    function GetMonitorNotify: IOmniEventMonitorNotify;
    property MonitorNotify: IOmniEventMonitorNotify read GetMonitorNotify;
  end; { IOmniContainerPlatformObserver }

  ///<summary>Container observer. IInterface-refcounted so subject snapshots
  ///   can keep observers alive during dispatch without holding locks.</summary>
  TOmniContainerObserver = class(TInterfacedObject, IOmniContainerObserver)
  strict private
    coIsActivated: TOmniAlignedInt32;
  public
    constructor Create;
    procedure Activate; inline;
    function  CanNotify: boolean; inline;
    procedure Deactivate; inline;
    procedure Notify; virtual; abstract;
  end; { TOmniContainerObserver }

  TOmniContainerEventObserver = class(TOmniContainerObserver, IOmniContainerEventObserver)
  public
    function GetEvent: IOmniEvent; virtual; abstract;
  end; { TOmniContainerEventObserver }

  // Platform-independant observer using TThread.Queue as a communication mechanism.
  // Used in the TOTLEventMonitor component.
  TOmniContainerPlatformObserver = class(TOmniContainerObserver, IOmniContainerPlatformObserver)
  strict protected
    function GetMonitorNotify: IOmniEventMonitorNotify; virtual; abstract;
  public
    property MonitorNotify: IOmniEventMonitorNotify read GetMonitorNotify;
  end; { TOmniContainerPlatformObserver }

  ///<summary>Container observer that dispatches a plain TProc callback to the
  ///   main thread via TThread.ForceQueue. Multiple Notify calls coalesce into
  ///   a single main-thread invocation. The owner must call Shutdown before
  ///   tearing down any state referenced by the callback.</summary>
  IOmniContainerMainThreadObserver = interface(IOmniContainerObserver)
    ['{B2E7F1A3-4D6C-5B8E-A9F0-1C2D3E4F5061}']
    procedure Shutdown;
  end; { IOmniContainerMainThreadObserver }

  TOmniContainerMainThreadObserver = class(TOmniContainerObserver, IOmniContainerMainThreadObserver)
  public
    procedure Shutdown; virtual; abstract;
  end; { TOmniContainerMainThreadObserver }

  TOmniContainerSubject = class
  strict private
    csListLocks    : array [TOmniContainerObserverInterest] of TOmniMREW;
    csObserverLists: array [TOmniContainerObserverInterest] of TList<IOmniContainerObserver>;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure Attach(const observer: IOmniContainerObserver;
      interest: TOmniContainerObserverInterest);
    procedure Detach(const observer: IOmniContainerObserver;
      interest: TOmniContainerObserverInterest);
    procedure Notify(interest: TOmniContainerObserverInterest);
    procedure NotifyOnce(interest: TOmniContainerObserverInterest);
    procedure Rearm(interest: TOmniContainerObserverInterest);
  end; { TOmniContainerSubject }

  function CreateContainerEventObserver(const externalEvent: IOmniEvent = nil):
    IOmniContainerEventObserver;

  function CreateContainerPlatformObserver(notify: IOmniEventMonitorNotify;
    objectID: int64): IOmniContainerPlatformObserver;

  {:Creates an observer that dispatches aOnNotify to the main thread via
    TThread.ForceQueue. Multiple container notifications arriving before the
    main-thread callback runs are coalesced into a single invocation; the
    callback typically drains the queue in a loop.
    Owners must call Shutdown on the returned observer before destroying any
    state the callback touches, so stale notifications queued on the main
    thread become no-ops.
    @param   aOnNotify Callback invoked on the main thread.
    @returns Main-thread observer interface. Lifetime is reference-counted.
    @since   2026-04-22
  }
  function CreateContainerMainThreadObserver(const aOnNotify: TProc):
    IOmniContainerMainThreadObserver;

implementation

uses
  System.Types;

type
  TOmniContainerEventObserverImpl = class(TOmniContainerEventObserver)
  strict private
    ceoEvent: IOmniEvent;
  public
    constructor Create(const externalEvent: IOmniEvent);
    function  GetEvent: IOmniEvent; override;
    procedure Notify; override;
  end; { TOmniContainerEventObserverImpl }

  TOmniContainerPlatformObserverImpl = class(TOmniContainerPlatformObserver)
  strict private
    FNotify    : IOmniEventMonitorNotify;
    FObjectID  : int64;
  strict protected
    function GetMonitorNotify: IOmniEventMonitorNotify; override;
  public
    constructor Create(notify: IOmniEventMonitorNotify; objectID: int64);
    procedure Notify; override;
  end; { TOmniContainerPlatformObserverImpl }

  TOmniContainerMainThreadObserverImpl = class(TOmniContainerMainThreadObserver)
  strict private
    FIsActive: TOmniAlignedInt32;
    FOnNotify: TProc;
    FPending : TOmniAlignedInt32;
  public
    constructor Create(const aOnNotify: TProc);
    procedure Notify; override;
    procedure Shutdown; override;
  end; { TOmniContainerMainThreadObserverImpl }

{ exports }

function CreateContainerEventObserver(const externalEvent: IOmniEvent = nil):
  IOmniContainerEventObserver;
begin
  Result := TOmniContainerEventObserverImpl.Create(externalEvent);
end; { CreateContainerWindowsEventObserver }

function CreateContainerPlatformObserver(notify: IOmniEventMonitorNotify;
  objectID: int64): IOmniContainerPlatformObserver;
begin
  Result := TOmniContainerPlatformObserverImpl.Create(notify, objectID);
end; { CreateContainerPlatformObserver }

function CreateContainerMainThreadObserver(const aOnNotify: TProc):
  IOmniContainerMainThreadObserver;
begin
  Result := TOmniContainerMainThreadObserverImpl.Create(aOnNotify);
end; { CreateContainerMainThreadObserver }

{ TOmniContainerObserver }

procedure TOmniContainerObserver.Activate; //inline
begin
  coIsActivated.Value := 1;
end; { TOmniContainerObserver.Activate }

constructor TOmniContainerObserver.Create;
begin
  inherited;
  Activate;
end; { TOmniContainerObserver.Create }

function TOmniContainerObserver.CanNotify: boolean;
begin
  Result := coIsActivated.CAS(1, 0);
end; { TOmniContainerObserver.CanNotify }

procedure TOmniContainerObserver.Deactivate;
begin
  coIsActivated.Value := 0;
end; { TOmniContainerObserver.Deactivate }

{ TOmniContainerEventObserverImpl }

constructor TOmniContainerEventObserverImpl.Create(const externalEvent: IOmniEvent);
begin
  inherited Create;
  ceoEvent := externalEvent;
  if not assigned(ceoEvent) then
    ceoEvent := CreateOmniEvent(False, False)
end; { TOmniContainerWindowsEventObserverImpl.Create }

function TOmniContainerEventObserverImpl.GetEvent: IOmniEvent;
begin
  Result := ceoEvent;
end; { TOmniContainerWindowsEventObserverImpl.GetEvent }

procedure TOmniContainerEventObserverImpl.Notify;
begin
  ceoEvent.SetEvent;
end; { TOmniContainerWindowsEventObserverImpl.Notify }

{ TOmniContainerSubject }

constructor TOmniContainerSubject.Create;
var
  interest: TOmniContainerObserverInterest;
begin
  inherited Create;
  for interest := Low(TOmniContainerObserverInterest) to High(TOmniContainerObserverInterest) do
    csObserverLists[interest] := TList<IOmniContainerObserver>.Create;
end; { TOmniContainerSubject.Create }

destructor TOmniContainerSubject.Destroy;
var
  interest: TOmniContainerObserverInterest;
begin
  for interest := Low(TOmniContainerObserverInterest) to High(TOmniContainerObserverInterest) do begin
    csObserverLists[interest].Free;
    csObserverLists[interest] := nil;
  end;
  inherited;
end; { TOmniContainerSubject.Destroy }

procedure TOmniContainerSubject.Attach(const observer: IOmniContainerObserver;
  interest: TOmniContainerObserverInterest);
begin
  csListLocks[interest].EnterWriteLock;
  try
    if csObserverLists[interest].IndexOf(observer) < 0 then
      csObserverLists[interest].Add(observer);
  finally csListLocks[interest].ExitWriteLock; end;
end; { TOmniContainerSubject.Attach }

procedure TOmniContainerSubject.Detach(const observer: IOmniContainerObserver;
  interest: TOmniContainerObserverInterest);
begin
  csListLocks[interest].EnterWriteLock;
  try
    csObserverLists[interest].Remove(observer);
  finally csListLocks[interest].ExitWriteLock; end;
end; { TOmniContainerSubject.Detach }

procedure TOmniContainerSubject.Notify(interest: TOmniContainerObserverInterest);
var
  iObserver: integer;
  list     : TList<IOmniContainerObserver>;
  snapshot : TArray<IOmniContainerObserver>;
begin
  // Lock-free fast path: if no observer is currently registered, skip the
  // read-lock / snapshot overhead entirely. Attach/Detach hold the write
  // lock, so a stale-zero read here at worst means a simultaneously
  // attaching observer misses a notification that predates its attach
  // — which is indistinguishable from racing Attach against a signal.
  if csObserverLists[interest].Count = 0 then
    Exit;
  {$R-}
  csListLocks[interest].EnterReadLock;
  try
    list := csObserverLists[interest];
    SetLength(snapshot, list.Count);
    for iObserver := 0 to list.Count - 1 do
      snapshot[iObserver] := list[iObserver];
  finally csListLocks[interest].ExitReadLock; end;
  for iObserver := 0 to High(snapshot) do
    snapshot[iObserver].Notify;
  {$R+}
end; { TOmniContainerSubject.Notify }

procedure TOmniContainerSubject.NotifyOnce(interest: TOmniContainerObserverInterest);
var
  iObserver: integer;
  list     : TList<IOmniContainerObserver>;
  observer : IOmniContainerObserver;
  snapshot : TArray<IOmniContainerObserver>;
begin
  {$R-}
  csListLocks[interest].EnterReadLock;
  try
    list := csObserverLists[interest];
    SetLength(snapshot, list.Count);
    for iObserver := 0 to list.Count - 1 do
      snapshot[iObserver] := list[iObserver];
  finally csListLocks[interest].ExitReadLock; end;
  for iObserver := 0 to High(snapshot) do begin
    observer := snapshot[iObserver];
    if observer.CanNotify then begin
      observer.Notify;
      observer.Deactivate;
    end;
  end;
  {$R+}
end; { TOmniContainerSubject.NotifyOnce }

procedure TOmniContainerSubject.Rearm(interest: TOmniContainerObserverInterest);
var
  iObserver: integer;
  list     : TList<IOmniContainerObserver>;
begin
  {$R-}
  csListLocks[interest].EnterReadLock;
  try
    list := csObserverLists[interest];
    for iObserver := 0 to list.Count - 1 do
      list[iObserver].Activate;
  finally csListLocks[interest].ExitReadLock; end;
  {$R+}
end; { TOmniContainerSubject.Rearm }

{ TOmniContainerPlatformObserverImpl }

constructor TOmniContainerPlatformObserverImpl.Create(notify: IOmniEventMonitorNotify;
  objectID: int64);
begin
  inherited Create;
  FNotify := notify;
  FObjectID := objectID;
end; { TOmniContainerPlatformObserverImpl.Create }

function TOmniContainerPlatformObserverImpl.GetMonitorNotify: IOmniEventMonitorNotify;
begin
  Result := FNotify;
end; { TOmniContainerPlatformObserverImpl.GetMonitorNotify }

procedure TOmniContainerPlatformObserverImpl.Notify;
begin
  FNotify.NotifyMessage(FObjectID);
end; { TOmniContainerPlatformObserverImpl.Notify }

{ TOmniContainerMainThreadObserverImpl }

constructor TOmniContainerMainThreadObserverImpl.Create(const aOnNotify: TProc);
begin
  inherited Create;
  FOnNotify := aOnNotify;
  FIsActive.Value := 1;
end; { TOmniContainerMainThreadObserverImpl.Create }

procedure TOmniContainerMainThreadObserverImpl.Notify;
var
  keepAlive: IOmniContainerObserver;
begin
  if FIsActive.Value = 0 then
    Exit;
  if not FPending.CAS(0, 1) then
    Exit; // another dispatch already queued; coalesce
  keepAlive := Self; // interface ref keeps observer alive until closure runs
  TThread.ForceQueue(nil,
    procedure
    begin
      FPending.Value := 0;
      if FIsActive.Value = 1 then
        FOnNotify();
      keepAlive := nil;
    end);
end; { TOmniContainerMainThreadObserverImpl.Notify }

procedure TOmniContainerMainThreadObserverImpl.Shutdown;
begin
  FIsActive.Value := 0;
end; { TOmniContainerMainThreadObserverImpl.Shutdown }

end.

