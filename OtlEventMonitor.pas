///<summary>Event dispatching component. Part of the OmniThreadLibrary project.</summary>
///<author>Primoz Gabrijelcic</author>
///<license>
///This software is distributed under the BSD license.
///
///Copyright (c) 2026, Primoz Gabrijelcic
///All rights reserved.
///
///Redistribution and use in source and binary forms, with or without modification,
///are permitted provided that the following conditions are met:
///- Redistributions of source code must retain the above copyright notice, this
///  list of conditions and the following disclaimer.
///- Redistributions in binary form must reproduce the above copyright notice,
///  this list of conditions and sthe following disclaimer in the documentation
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
///   Contributors      : GJ, Lee_Nover, Sean B. Durkin, Claude AI
///   Creation date     : 2008-06-12
///   Last modification : 2026-04-22
///   Version           : 2.0f
///</para><para>
///   History:
///     2.0f: 2026-04-22
///       - Fixed UAF in Notify{Message,Terminated,ThreadPool}: queued closures
///         captured Self as a raw pointer (TComponent IInterface does not
///         refcount), so a closure could fire on a freed monitor when the
///         last task released the monitor pool ref inside ProcessTerminated
///         while rearmed ProcessNewMessage closures were still queued.
///         Closures now route through a lock-serialized IInterface-refcounted
///         dispatcher; Clear (called from ~TOmniEventMonitor) mutually
///         excludes in-flight Dispatch and makes later Dispatches no-ops.
///     2.0e: 2026-04-14
///       - Fixed ProcessTerminated: apply FilterMessage to drain loop,
///         preventing internal OTL messages from leaking to user callback.
///     2.0d: 2026-04-12
///       - Removed OTL_HasForceQueue conditionals (always true on Delphi 11+).
///     2.0c: 2026-04-12
///       - Removed unused DSiWin32 import.
///     2.0b: 2019-04-14
///       - Removed last MSWINDOWS IFDEFs.
///     2.0a: 2018-05-28
///       - Fixed warnings.
///     2.0: 2018-05-10
///       - Platform independant implementation. Currently only works in main thread.
///     1.11: 2018-03-16
///       - Unhandled exceptions in TOmniEventMonitor.WndProc are passed to OtlHooks filter.
///     1.10: 2017-10-25
///       - TOmniEventMonitorPool.Allocate and Release can now be called from different threads.
///     1.09: 2017-01-22
///       - ERROR_NOT_ENOUGH_QUOTA (1816) is handled in TOmniEventMonitor.WndProc.
///     1.08: 2015-10-04
///       - Imported mobile support by [Sean].
///     1.07e: 2012-10-02
///       - TOmniEventMonitor is marked for 64-bit support.
///     1.07d: 2012-10-01
///       - COmniTaskMsg_NewMessage messages must be processed even if OnTaskMessage event
///         is not assigned. Otherwise internal messages can get lost.
///     1.07c: 2012-09-27
///       - Calls task controller's FilterMessage method to remove internal (Invoke)
///         messages before passing messages to the event handler.
///     1.07b: 2011-12-19
///       - COmniTaskMsg_Terminated is processed even if OnTaskTerminated handler is not set.
///     1.07a: 2011-07-27
///       - Removed 'FreeAndNil(uninitialized variable)' which was leftover from
///         incorrectly removed code in version 1.06.
///     1.07: 2011-07-26
///       - TOmniTaskEvent, TOmniTaskMessageEvent, TOmniPoolThreadEvent, and
///         TOmniPoolWorkItemEvent renamed to TOmniMonitorTaskEvent,
///         TOmniMonitorTaskMessageEvent, TOmniMonitorPoolThreadEvent and
///         TOmniMonitorPoolWorkItemEvent, respectively.
///     1.06: 2011-07-14
///       - Removed task exception object parameter from OnPoolWorkItemCompleted.
///     1.05: 2011-07-04
///       - OnPoolWorkItemCompleted event handler got new parameter - task exception object.
///     1.04b: 2011-02-15
///       - Don't rearm self if message window was already destroyed.
///       - Safely destroy message window.
///     1.04a: 2010-09-23
///       - Destroy internal monitor in Terminate.
///       - Signal termination (in Execute) before 'Terminated' is set (which may cause
///         Monitor to be immediately destroyed.
///     1.04: 2010-07-22
///       - Implemented ProcessMessages.
///     1.03: 2010-07-07
///       - Internal message window is exposed via the MessageWindow property.
///     1.02: 2010-07-01
///       - Includes OTLOptions.inc.
///     1.01a: 2010-05-30
///       - Message retrieving loop destroys interface immediately, not when the next
///         message is received.
///     1.01: 2010-03-03
///       - Implemented TOmniEventMonitorPool, per-thread TOmniEventMonitor allocator.
///     1.0a: 2009-01-26
///       - Pass correct task ID to the OnPoolWorkItemCompleted handler.
///     1.0: 2008-08-26
///       - First official release.
///</para></remarks>

unit OtlEventMonitor;

{$I OtlOptions.inc}
{$WARN SYMBOL_PLATFORM OFF}

interface

uses
  OtlCommon,
  System.SysUtils,
  System.Generics.Collections,
  System.Classes,
  OtlComm,
  OtlSync,
  OtlTaskControl,
  OtlThreadPool,
  OtlEventMonitor.Notify;

type
  TOmniMonitorTaskEvent = procedure(const task: IOmniTaskControl) of object;
  TOmniMonitorTaskMessageEvent = procedure(const task: IOmniTaskControl; const msg: TOmniMessage) of object;
  TOmniMonitorPoolThreadEvent = procedure(const pool: IOmniThreadPool; threadID: integer) of object;
  TOmniMonitorPoolWorkItemEvent = procedure(const pool: IOmniThreadPool; taskID: int64) of object;

  IOmniEventMonitorDispatcher = interface ['{3FBDB96C-3C0D-4C7C-8A42-0D42CFB2B6DE}']
    procedure Clear;
    procedure DispatchNewMessage(taskControlID: int64);
    procedure DispatchTerminated(taskControlID: int64);
    procedure DispatchThreadPool(threadPoolInfo: TOmniThreadPoolMonitorInfo);
  end; { IOmniEventMonitorDispatcher }

  [ComponentPlatformsAttribute(pidAllPlatforms)]
  TOmniEventMonitor = class(TComponent, IOmniTaskControlMonitor,
                                        IOmniThreadPoolMonitor,
                                        IOmniEventMonitorNotify)
  strict private
  class var
    FLastID                   : TOmniAlignedInt64;
  var
    emCurrentMsg              : TOmniMessage;
    emDispatcher              : IOmniEventMonitorDispatcher;
    emID                      : int64;
    emMonitoredPools          : IOmniInterfaceDictionary;
    emMonitoredTasks          : IOmniInterfaceDictionary;
    emOnPoolThreadCreated     : TOmniMonitorPoolThreadEvent;
    emOnPoolThreadDestroying  : TOmniMonitorPoolThreadEvent;
    emOnPoolThreadKilled      : TOmniMonitorPoolThreadEvent;
    emOnPoolWorkItemEvent     : TOmniMonitorPoolWorkItemEvent;
    emOnTaskMessage           : TOmniMonitorTaskMessageEvent;
    emOnTaskUndeliveredMessage: TOmniMonitorTaskMessageEvent;
    emOnTaskTerminated        : TOmniMonitorTaskEvent;
    emThreadID                : TThreadID;
  protected
    // Invoked via the lock-serialized TOmniEventMonitorDispatcher in the
    // implementation section; not strict because the dispatcher is not a
    // descendant class. Plain protected keeps the methods in-unit only.
    procedure ProcessNewMessage(taskControlID: int64);
    procedure ProcessTerminated(taskControlID: int64);
    procedure ProcessThreadPool(threadPoolInfo: TOmniThreadPoolMonitorInfo);
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;
    function  Detach(const task: IOmniTaskControl): IOmniTaskControl; overload;
    function  Detach(const pool: IOmniThreadPool): IOmniThreadPool; overload;
    function  GetID: int64;
    function  Monitor(const task: IOmniTaskControl): IOmniTaskControl; overload;
    function  Monitor(const pool: IOmniThreadPool): IOmniThreadPool; overload;
    procedure NotifyMessage(taskControlID: int64);
    procedure NotifyTerminated(taskControlID: int64);
    procedure NotifyThreadPool(threadPoolInfo: TOmniThreadPoolMonitorInfo);
    procedure ProcessMessages;
  published
    property ThreadID: TThreadID read emThreadID;
    property OnPoolThreadCreated: TOmniMonitorPoolThreadEvent read emOnPoolThreadCreated
      write emOnPoolThreadCreated;
    property OnPoolThreadDestroying: TOmniMonitorPoolThreadEvent read emOnPoolThreadDestroying
      write emOnPoolThreadDestroying;
    property OnPoolThreadKilled: TOmniMonitorPoolThreadEvent read emOnPoolThreadKilled
      write emOnPoolThreadKilled;
    property OnPoolWorkItemCompleted: TOmniMonitorPoolWorkItemEvent read emOnPoolWorkItemEvent
      write emOnPoolWorkItemEvent;
    property OnTaskMessage: TOmniMonitorTaskMessageEvent read emOnTaskMessage
      write emOnTaskMessage;
    property OnTaskTerminated: TOmniMonitorTaskEvent read emOnTaskTerminated
      write emOnTaskTerminated;
    property OnTaskUndeliveredMessage: TOmniMonitorTaskMessageEvent
      read emOnTaskUndeliveredMessage write emOnTaskUndeliveredMessage;
  end; { TOmniEventMonitor }

  TOmniEventMonitorClass = class of TOmniEventMonitor;

  ///<summary>A pool of per-thread event monitors.</summary>
  ///<since>2010-03-03</since>
  TOmniEventMonitorPool = class
  strict private
    empListLock    : TOmniCS;
    empMonitorClass: TOmniEventMonitorClass;
    empMonitorList : TObjectDictionary<TThreadID, TObject>;
  public
    constructor Create;
    destructor  Destroy; override;
    function  Allocate: TOmniEventMonitor;
    procedure Release(monitor: TOmniEventMonitor);
    property MonitorClass: TOmniEventMonitorClass read empMonitorClass write empMonitorClass;
  end; { TOmniEventMonitorPool }

implementation

uses
  System.SyncObjs,
  System.Diagnostics,
  OtlHooks,
  OtlPlatform;

const
  CMaxReceiveLoop_ms = 5;

type
  ///<summary>Reference counted TOmniEventMonitor.</summary>
  TOmniCountedEventMonitor = class
  strict private
    cemMonitor : TOmniEventMonitor;
    cemRefCount: integer;
  public
    constructor Create(monitor: TOmniEventMonitor);
    destructor  Destroy; override;
    function  Allocate: TOmniEventMonitor;
    procedure Release;
    property Monitor: TOmniEventMonitor read cemMonitor;
    property RefCount: integer read cemRefCount;
  end; { TOmniCountedEventMonitor }

  ///<summary>Lock-serialized proxy that keeps queued TOmniEventMonitor
  ///   closures UAF-safe. Queued closures capture the dispatcher interface
  ///   (refcounted) rather than the TComponent-based monitor (not refcounted
  ///   through IInterface). Clear, called from the monitor destructor,
  ///   nils the raw target pointer under the same lock that guards Dispatch,
  ///   so any in-flight Dispatch finishes first and any later Dispatch is
  ///   a no-op. DispatchThreadPool still frees threadPoolInfo when the
  ///   monitor is gone so ownership semantics are preserved.</summary>
  TOmniEventMonitorDispatcher = class(TInterfacedObject, IOmniEventMonitorDispatcher)
  strict private
    FLock  : TCriticalSection;
    FTarget: Pointer; // raw TOmniEventMonitor; nil after Clear
  public
    constructor Create(target: Pointer);
    destructor  Destroy; override;
    procedure Clear;
    procedure DispatchNewMessage(taskControlID: int64);
    procedure DispatchTerminated(taskControlID: int64);
    procedure DispatchThreadPool(threadPoolInfo: TOmniThreadPoolMonitorInfo);
  end; { TOmniEventMonitorDispatcher }

{ TOmniEventMonitor }

constructor TOmniEventMonitor.Create(AOwner: TComponent);
begin
  inherited;
  emID := FLastID.Increment;
  emThreadID := TPlatform.ThreadID;
  if emThreadID <> MainThreadID then
    raise Exception.CreateFmt('TOmniEventMonitor can only be used in the main thread. ' +
                              '(Create called from thread %d)',
                              [emThreadID]);
  emMonitoredTasks := CreateInterfaceDictionary;
  emMonitoredPools := CreateInterfaceDictionary;
  emDispatcher := TOmniEventMonitorDispatcher.Create(Self);
end; { TOmniEventMonitor.Create }

destructor TOmniEventMonitor.Destroy;
var
  intfKV   : TOmniInterfaceDictionaryPair;
begin
  // Sever pending queued closures first: after Clear returns, any in-flight
  // Dispatch has finished and any still-queued Dispatch is a no-op. This
  // must run before we tear down emMonitoredTasks / emMonitoredPools.
  if assigned(emDispatcher) then begin
    emDispatcher.Clear;
    emDispatcher := nil;
  end;
  // Guard the dictionary accesses: if the constructor raised before
  // assigning them (non-main-thread guard fires after `inherited` registers
  // us with our TComponent owner, so Delphi calls Destroy to clean up the
  // half-initialized object), `for intfKV in <nil dict>` AVs. The AV then
  // triggers madExcept's bug-report hook, and many simultaneous AVs
  // serialize inside madExcept.TWinHttp.InitMantis — root cause of the
  // residual TestCancelAll-related hangs.
  if assigned(emMonitoredTasks) then begin
    for intfKV in emMonitoredTasks do
      (intfKV.Value as IOmniTaskControl).RemoveMonitor;
    emMonitoredTasks.Clear;
  end;
  if assigned(emMonitoredPools) then begin
    for intfKV in emMonitoredPools do
      (intfKV.Value as IOmniThreadPool).RemoveMonitor;
    emMonitoredPools.Clear;
  end;
  inherited;
end; { TOmniEventMonitor.Destroy }

function TOmniEventMonitor.Detach(const task: IOmniTaskControl): IOmniTaskControl;
begin
  emMonitoredTasks.Remove(task.UniqueID);
  Result := task.RemoveMonitor;
end; { TOmniEventMonitor.Detach }

function TOmniEventMonitor.Detach(const pool: IOmniThreadPool): IOmniThreadPool;
begin
  emMonitoredPools.Remove(pool.UniqueID);
  Result := pool.RemoveMonitor;
end; { TOmniEventMonitor.Detach }

function TOmniEventMonitor.GetID: int64;
begin
  Result := emID;
end; { TOmniEventMonitor.GetID }

function TOmniEventMonitor.Monitor(const task: IOmniTaskControl): IOmniTaskControl;
begin
  emMonitoredTasks.Add(task.UniqueID, task);
  Result := task.SetMonitor(Self as IOmniEventMonitorNotify);
end; { TOmniEventMonitor.Monitor }

function TOmniEventMonitor.Monitor(const pool: IOmniThreadPool): IOmniThreadPool;
begin
  emMonitoredPools.Add(pool.UniqueID, pool);
  Result := pool.SetMonitor(Self as IOmniEventMonitorNotify);
end; { TOmniEventMonitor.Monitor }

procedure TOmniEventMonitor.NotifyMessage(taskControlID: int64);
var
  dispatcher: IOmniEventMonitorDispatcher;
begin
  dispatcher := emDispatcher; // strong ref keeps dispatcher alive inside the closure
  TThread.ForceQueue(
    TThread.CurrentThread,
    procedure
    begin
      dispatcher.DispatchNewMessage(taskControlID);
    end);
end; { TOmniEventMonitor.NotifyMessage }

procedure TOmniEventMonitor.NotifyTerminated(taskControlID: int64);
var
  dispatcher: IOmniEventMonitorDispatcher;
begin
  dispatcher := emDispatcher;
  TThread.ForceQueue(
    TThread.CurrentThread,
    procedure
    begin
      dispatcher.DispatchTerminated(taskControlID);
    end);
end; { TOmniEventMonitor.NotifyTerminated }

procedure TOmniEventMonitor.NotifyThreadPool(
  threadPoolInfo: TOmniThreadPoolMonitorInfo);
var
  dispatcher: IOmniEventMonitorDispatcher;
begin
  dispatcher := emDispatcher;
  TThread.ForceQueue(
    TThread.CurrentThread,
    procedure
    begin
      dispatcher.DispatchThreadPool(threadPoolInfo);
    end);
end; { TOmniEventMonitor.NotifyThreadPool }

procedure TOmniEventMonitor.ProcessMessages;
begin
  CheckSynchronize;
end; { TOmniEventMonitor.ProcessMessages }

procedure TOmniEventMonitor.ProcessNewMessage(taskControlID: int64);
var
  task        : IOmniTaskControl;
  timeStart_ms: int64;

  function ProcessMessages(timeout_ms: integer = CMaxReceiveLoop_ms;
    rearmSelf: boolean = true): boolean;
  begin
    Result := true;
    while task.Comm.Receive(emCurrentMsg) do begin
      if (not (task as IOmniTaskControlInternals).FilterMessage(emCurrentMsg))
         and assigned(emOnTaskMessage)
      then
        emOnTaskMessage(task, emCurrentMsg);

      { TODO 1 -oPrimoz Gabrijelcic : emMessageWindow? }
      if (GTimeSource.Elapsed_ms(timeStart_ms) > timeout_ms) {and (emMessageWindow <> 0)} then begin
        if rearmSelf then
          NotifyMessage(taskControlID);
        break; //while
      end;
    end; //while
    emCurrentMsg.MsgData._ReleaseAndClear;
  end; { ProcessMessages }

begin
  task := emMonitoredTasks.ValueOf(taskControlID) as IOmniTaskControl;
  if assigned(task) then begin
    timeStart_ms := GTimeSource.Timestamp_ms;
    ProcessMessages;
  end;
end; { TOmniEventMonitor.ProcessNewMessage }

procedure TOmniEventMonitor.ProcessTerminated(taskControlID: int64);
var
  endpoint: IOmniCommunicationEndpoint;
  task    : IOmniTaskControl;
begin
  task := emMonitoredTasks.ValueOf(taskControlID) as IOmniTaskControl;
  if assigned(task) then begin
    endpoint := (task as IOmniTaskControlSharedInfo).SharedInfo.CommChannel.Endpoint1;
    while endpoint.Receive(emCurrentMsg) do
      if (not (task as IOmniTaskControlInternals).FilterMessage(emCurrentMsg))
         and assigned(emOnTaskMessage)
      then
        emOnTaskMessage(task, emCurrentMsg);
    endpoint := (task as IOmniTaskControlSharedInfo).SharedInfo.CommChannel.Endpoint2;
    while endpoint.Receive(emCurrentMsg) do
      if Assigned(emOnTaskUndeliveredMessage) then
        emOnTaskUndeliveredMessage(task, emCurrentMsg);
    emCurrentMsg.MsgData._ReleaseAndClear;
    if Assigned(emOnTaskTerminated) then
      OnTaskTerminated(task);
    Detach(task);
  end;
end; { TOmniEventMonitor.ProcessTerminated }

procedure TOmniEventMonitor.ProcessThreadPool(
  threadPoolInfo: TOmniThreadPoolMonitorInfo);
var
  pool: IOmniThreadPool;
begin
  try
    pool := emMonitoredPools.ValueOf(threadPoolInfo.UniqueID) as IOmniThreadPool;
    if assigned(pool) then begin
      if threadPoolInfo.ThreadPoolOperation = tpoCreateThread then begin
        if assigned(OnPoolThreadCreated) then
          OnPoolThreadCreated(pool, threadPoolInfo.ThreadID);
      end
      else if threadPoolInfo.ThreadPoolOperation = tpoDestroyThread then begin
        if assigned(OnPoolThreadDestroying) then
          OnPoolThreadDestroying(pool, threadPoolInfo.ThreadID);
      end
      else if threadPoolInfo.ThreadPoolOperation = tpoKillThread then begin
        if assigned(OnPoolThreadKilled) then
          OnPoolThreadKilled(pool, threadPoolInfo.ThreadID);
      end
      else if threadPoolInfo.ThreadPoolOperation = tpoWorkItemCompleted then begin
        if assigned(OnPoolWorkItemCompleted) then
          OnPoolWorkItemCompleted(pool, threadPoolInfo.TaskID);
      end;
    end;
  finally FreeAndNil(threadPoolInfo); end;
end; { TOmniEventMonitor.ProcessThreadPool }

{ TOmniEventMonitorDispatcher }

constructor TOmniEventMonitorDispatcher.Create(target: Pointer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FTarget := target;
end; { TOmniEventMonitorDispatcher.Create }

destructor TOmniEventMonitorDispatcher.Destroy;
begin
  FreeAndNil(FLock);
  inherited;
end; { TOmniEventMonitorDispatcher.Destroy }

procedure TOmniEventMonitorDispatcher.Clear;
begin
  FLock.Enter;
  try
    FTarget := nil;
  finally FLock.Leave; end;
end; { TOmniEventMonitorDispatcher.Clear }

procedure TOmniEventMonitorDispatcher.DispatchNewMessage(taskControlID: int64);
begin
  FLock.Enter;
  try
    if FTarget <> nil then
      TOmniEventMonitor(FTarget).ProcessNewMessage(taskControlID);
  finally FLock.Leave; end;
end; { TOmniEventMonitorDispatcher.DispatchNewMessage }

procedure TOmniEventMonitorDispatcher.DispatchTerminated(taskControlID: int64);
begin
  FLock.Enter;
  try
    if FTarget <> nil then
      TOmniEventMonitor(FTarget).ProcessTerminated(taskControlID);
  finally FLock.Leave; end;
end; { TOmniEventMonitorDispatcher.DispatchTerminated }

procedure TOmniEventMonitorDispatcher.DispatchThreadPool(
  threadPoolInfo: TOmniThreadPoolMonitorInfo);
begin
  FLock.Enter;
  try
    if FTarget <> nil then
      TOmniEventMonitor(FTarget).ProcessThreadPool(threadPoolInfo)
    else
      // ProcessThreadPool would have freed it; preserve ownership contract.
      FreeAndNil(threadPoolInfo);
  finally FLock.Leave; end;
end; { TOmniEventMonitorDispatcher.DispatchThreadPool }

{ TOmniCountedEventMonitor }

constructor TOmniCountedEventMonitor.Create(monitor: TOmniEventMonitor);
begin
  inherited Create;
  cemMonitor := monitor;
  cemRefCount := 1;
end; { TOmniCountedEventMonitor.Create }

destructor TOmniCountedEventMonitor.Destroy;
begin
  FreeAndNil(cemMonitor);
  inherited;
end; { TOmniCountedEventMonitor.Destroy }

function TOmniCountedEventMonitor.Allocate: TOmniEventMonitor;
begin
  if cemRefCount = 0 then
    cemMonitor := TOmniEventMonitor.Create(nil);
  Inc(cemRefCount);
  Result := cemMonitor;
end; { TOmniCountedEventMonitor.Allocate }

procedure TOmniCountedEventMonitor.Release;
begin
  Assert(cemRefCount > 0);
  Dec(cemRefCount);
  if cemRefCount = 0 then
    FreeAndNil(cemMonitor);
end; { TOmniCountedEventMonitor.Release }

{ TOmniEventMonitorPool }

constructor TOmniEventMonitorPool.Create;
begin
  inherited Create;
  empMonitorList := TObjectDictionary<TThreadID, TObject>.Create([doOwnsValues]);
end; { TOmniEventMonitorPool.Create }

destructor TOmniEventMonitorPool.Destroy;
begin
  FreeAndNil(empMonitorList);
  inherited;
end; { TOmniEventMonitorPool.Destroy }

///<summary>Returns monitor associated with the current thread. Allocates new monitor if
///    no monitor has been associated with this thread.</summary>
function TOmniEventMonitorPool.Allocate: TOmniEventMonitor;
var
  monitorInfo: TOmniCountedEventMonitor;
begin
  empListLock.Acquire;
  try
    var obj: TObject;
    if empMonitorList.TryGetValue(TPlatform.ThreadID, obj) then begin
      monitorInfo := TOmniCountedEventMonitor(obj);
      monitorInfo.Allocate;
    end
    else begin
      monitorInfo := TOmniCountedEventMonitor.Create(MonitorClass.Create(nil));
      empMonitorList.Add(monitorInfo.Monitor.ThreadID, monitorInfo);
    end;
    Result := monitorInfo.Monitor;
  finally empListLock.Release; end;
end; { TOmniEventMonitorPool.Allocate }

///<summary>Releases monitor from the current thread. If monitor is no longer in use,
///    destroys the monitor.</summary>
///<since>2010-03-03</since>
procedure TOmniEventMonitorPool.Release(monitor: TOmniEventMonitor);
var
  monitorInfo: TOmniCountedEventMonitor;
  threadID   : TThreadID;
begin
  empListLock.Acquire;
  try
    threadID := monitor.ThreadID;
    var obj: TObject;
    if not empMonitorList.TryGetValue(threadID, obj) then
      raise Exception.CreateFmt(
        'TOmniEventMonitorPool.Release: Monitor is not allocated for thread %d',
        [monitor.ThreadID]);
    monitorInfo := TOmniCountedEventMonitor(obj);
    Assert(monitorInfo.Monitor = monitor);
    monitorInfo.Release;
    if monitorInfo.RefCount = 0 then
      empMonitorList.Remove(threadID);
  finally empListLock.Release; end;
end; { TOmniEventMonitorPool.Release }

end.
