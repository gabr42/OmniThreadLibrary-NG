///<summary>Two-way intraprocess communication channel. Part of the OmniThreadLibrary project.</summary>
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
///   Contributors      : GJ, Lee_Nover
///   Creation date     : 2008-06-12
///   Last modification : 2026-08-24
///   Version           : 3.02
///</para><para>
///   History:
///     3.02: 2026-08-24
///       - Restored TOmniMessageQueue.OnMessage, dropped during the OTL-NG
///         rewrite with no MIGRATION.md entry (found via a real-world caller,
///         GpDVBMaster.pas, that failed to compile with E2003 Undeclared
///         identifier). v3 built it on a hidden window bound to whichever
///         thread first assigned a handler + TOmniContainerWindowsMessageObserver;
///         reimplemented cross-platform on
///         OtlBackgroundObserver.CreateContainerBackgroundObserver, binding to
///         TThread.Current.ThreadID at assignment time instead. Delivery is
///         automatic for OTL task/worker owners (TOmniTaskExecutor.WaitForEvent
///         drains background observers every loop iteration); a plain,
///         non-OTL thread must call
///         OtlBackgroundObserver.DrainBackgroundObservers itself, or perform
///         an alertable wait.
///     3.01: 2026-04-14
///       - Replaced TOmniTransitionEvent with IOmniEvent.
///     3.0: 2026-04-12 [OTL-NG]
///       - Removed unused Winapi.Windows import.
///     2.0: 2018-04-24
///       - DSiTimeGetTime64 replaced with OtlPlatform.Time.
///     1.13a: 2018-01-16
///       - TOmniMessageQueue.Destroy does not call Empty if TOmniMessageQueue.Create
///         raised exception. This prevents new exception from popping up in Destroy
///         (which masked the initial Create exception).
///     1.13: 2016-12-07
///       - Default queue size bumped to 10000 messages.
///     1.12: 2015-10-04
///       - Imported mobile support by [Sean].
///     1.11: 2015-07-28
///       - Removed IOmniCommunicationEndpointEx.
///       - Removed single-thread use checks.
///       - SendWait and ReceiveWait are now thread-safe.
///     1.10: 2015-07-27
///       - TOmniCommunicationEndpoint implements IOmniCommunicationEndpointEx,
///	        primarily designed for internal use.
///     1.09: 2015-07-10
///       - TOmniCommunicationEndpoint will check for single-thread use if
///         OTL_CheckThreadSafety is defined.
///     1.08a: 2011-11-09
///       - TOmniMessageQueue.Enqueue leaked if queue was full and value contained
///         reference counted value (found by [meishier]).
///     1.08: 2011-11-05
///       - Adapted to OtlCommon 1.24.
///     1.07: 2010-07-01
///       - Includes OTLOptions.inc.
///     1.06a: 2010-05-06
///       - Fixed memory leak when sending String, WideString, Variant and Extended values
///         over the communication channel.
///     1.06: 2010-03-08
///       - Implemented TOmniMessageQueueTee and IOmniCommDispatchingObserver.
///     1.05: 2009-11-13
///       - Default queue size reduced to 1000 messages.
///     1.04: 2009-04-05
///       - Implemented TOmniMessageQueue.Empty and TryDequeue.
///       - TOmniMessageQueue empties itself before it is destroyed.
///     1.03: 2008-10-05
///       - Added two overloaded versions of IOmniCommunicationEndpoint.ReceivedWait,
///         which are just simple wrappers for WaitForSingleObject(NewMessageEvent) +
///         Receive.
///       - Defined OmniThreadLibrary-reserved message ID $FFFF.
///     1.02: 2008-09-26
///       - Better default queue calculation that takes into account OtlContainers
///         overhead and FastMM4 granulation.
///     1.01: 2008-09-20
///       - Added two TOmniMessage constructors.
///</para></remarks>

unit OtlComm;

{$I OtlOptions.inc}

interface

uses
  System.Generics.Collections,
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Diagnostics,
  OtlPlatform,
  OtlCommon,
  OtlSync,
  OtlContainerObserver,
  OtlContainers;

const
  //reserved for internal OTL messaging
  COtlReservedMsgID = $FFFF;
  //Max send wait time
  CMaxSendWaitTime_ms = 100;

  CDefaultQueueSize = 10000;

type
  {$A4}
  TOmniMessage = record
    MsgID  : word;
    MsgData: TOmniValue;
    constructor Create(aMsgID: word; aMsgData: TOmniValue); overload;
    constructor Create(aMsgID: word); overload;
  end; { TOmniMessage }

  TOmniMessageQueue = class;

  {:Callback signature for TOmniMessageQueue.OnMessage.}
  TOmniMessageQueueMessageEvent = procedure(Sender: TObject; const msg: TOmniMessage) of object;

  {:Single producer/single consumer communication channel. No thread safety.
  }
  IOmniCommunicationEndpoint = interface ['{910D329C-D049-48B9-B0C0-9434D2E57870}']
    function  GetNewMessageEvent: IOmniEvent;
    function  GetOtherEndpoint: IOmniCommunicationEndpoint;
    function  GetReader: TOmniMessageQueue;
    function  GetWriter: TOmniMessageQueue;
  //
    function  Receive(var msg: TOmniMessage): boolean; overload;
    function  Receive(var msgID: word; var msgData: TOmniValue): boolean; overload;
    function  ReceiveWait(var msg: TOmniMessage; timeout_ms: cardinal): boolean; overload;
    function  ReceiveWait(var msgID: word; var msgData: TOmniValue; timeout_ms: cardinal): boolean; overload;
    procedure Send(const msg: TOmniMessage); overload;
    procedure Send(msgID: word); overload;
    procedure Send(msgID: word; msgData: array of const); overload;
    procedure Send(msgID: word; msgData: TOmniValue); overload;
    function  SendWait(msgID: word; timeout_ms: cardinal = CMaxSendWaitTime_ms): boolean; overload;
    function  SendWait(msgID: word; msgData: TOmniValue; timeout_ms: cardinal = CMaxSendWaitTime_ms): boolean; overload;
    property NewMessageEvent: IOmniEvent read GetNewMessageEvent;
    property OtherEndpoint: IOmniCommunicationEndpoint read GetOtherEndpoint;
    property Reader: TOmniMessageQueue read GetReader;
    property Writer: TOmniMessageQueue read GetWriter;
  end; { IOmniCommunicationEndpoint }

  IOmniTwoWayChannel = interface ['{3ED1AB88-4209-4E01-AA79-A577AD719520}']
    function Endpoint1: IOmniCommunicationEndpoint;
    function Endpoint2: IOmniCommunicationEndpoint;
  end; { IOmniTwoWayChannel }

  {:Fixed-size ring buffer of TOmniMessage data. Supports multiple simultaneous readers
    and writers.
  }
  TOmniMessageQueue = class(TOmniBoundedQueue)
  strict private
    mqEventObserver: IOmniContainerEventObserver;
    mqIsInitialized: boolean;
    mqMsgObserver  : IOmniContainerObserver;
    mqOnMessage    : TOmniMessageQueueMessageEvent;
  strict protected
    procedure AttachEventObserver;
    procedure SetOnMessage(const value: TOmniMessageQueueMessageEvent);
  public
    constructor Create(numMessages: integer; createEventObserver: boolean = true); reintroduce;
    destructor  Destroy; override;
    function  Dequeue: TOmniMessage; reintroduce;
    function  Enqueue(const value: TOmniMessage): boolean; reintroduce;
    procedure Empty;
    function  GetNewMessageEvent: IOmniEvent;
    function  TryDequeue(var msg: TOmniMessage): boolean; reintroduce;
    property EventObserver: IOmniContainerEventObserver read mqEventObserver;
    {:Callback invoked (on the thread that set OnMessage, or automatically
      whenever that thread is an OTL task - see OtlBackgroundObserver.
      CreateContainerBackgroundObserver) once per message as it is enqueued.
      Assign nil to detach. Setting OnMessage does not replace TryDequeue -
      either drain the queue yourself, or assign a handler, not both.
      @since   2026-08-24
    }
    property OnMessage: TOmniMessageQueueMessageEvent read mqOnMessage write SetOnMessage;
  end; { TOmniMessageQueue }

  IOmniMessageQueueTee = interface ['{8A9526BF-71AA-4D78-BAE8-3490C3987327}']
    procedure Attach(const queue: TOmniMessageQueue);
    procedure Detach(const queue: TOmniMessageQueue);
    function Enqueue(const value: TOmniMessage): boolean;
  end;{ IOmniMessageQueueTee }

  TOmniMessageQueueTee = class(TInterfacedObject, IOmniMessageQueueTee)
  strict private
    obqtQueueList: TList;
    obqtQueueLock: TOmniCS;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure Attach(const queue: TOmniMessageQueue);
    procedure Detach(const queue: TOmniMessageQueue);
    function Enqueue(const value: TOmniMessage): boolean;
  end; { TOmniMessageQueueTee }

  function CreateTwoWayChannel(numElements: integer = CDefaultQueueSize;
    taskTerminatedEvent: IOmniEvent = nil): IOmniTwoWayChannel;

implementation

uses
  System.Types,
  {$IFDEF MSWINDOWS}{$IFDEF DEBUG}OtlCommBufferTest,{$ENDIF}{$ENDIF}
  OtlBackgroundObserver,
  OtlEventMonitor;

type
  IOmniCommunicationEndpointInternal = interface ['{4F872DE9-6E9A-4881-B9EC-E2189DAC00F4}']
    procedure DetachFromQueues;
  end; { IOmniCommunicationEndpointInternal }

  TOmniTwoWayChannel = class;

  TOmniCommunicationEndpoint = class(TInterfacedObject,
                                     IOmniCommunicationEndpoint,
                                     IOmniCommunicationEndpointInternal)
  strict private
    ceOwner_ref              : TOmniTwoWayChannel;
    ceReader_ref             : TOmniMessageQueue;
    ceTaskTerminatedEvent_ref: IOmniEvent;
    ceWriter_ref             : TOmniMessageQueue;
    FMultiWaitLock           : IOmniCriticalSection;
  protected
    procedure DetachFromQueues;
    function  GetNewMessageEvent: IOmniEvent;
    function  GetOtherEndpoint: IOmniCommunicationEndpoint;
    function  GetReader: TOmniMessageQueue;
    function  GetWriter: TOmniMessageQueue;
  public
    constructor Create(owner: TOmniTwoWayChannel; readQueue, writeQueue: TOmniMessageQueue;
      taskTerminatedEvent_ref: IOmniEvent);
    destructor  Destroy; override;
    function  Receive(var msg: TOmniMessage): boolean; overload; inline;
    function  Receive(var msgID: word; var msgData: TOmniValue): boolean; overload; inline;
    function  ReceiveWait(var msg: TOmniMessage; timeout_ms: cardinal): boolean; overload; inline;
    function  ReceiveWait(var msgID: word; var msgData: TOmniValue; timeout_ms: cardinal):
      boolean; overload; inline;
    procedure Send(msgID: word); overload; inline;
    procedure Send(msgID: word; msgData: array of const); overload;
    procedure Send(msgID: word; msgData: TOmniValue); overload; inline;
    procedure Send(const msg: TOmniMessage); overload; inline;
    function  SendWait(msgID: word; timeout_ms: cardinal = CMaxSendWaitTime_ms): boolean; overload; inline;
    function  SendWait(msgID: word; msgData: TOmniValue;
      timeout_ms: cardinal = CMaxSendWaitTime_ms): boolean; overload;
    property NewMessageEvent: IOmniEvent read GetNewMessageEvent;
    property OtherEndpoint: IOmniCommunicationEndpoint read GetOtherEndpoint;
    property Reader: TOmniMessageQueue read GetReader;
    property Writer: TOmniMessageQueue read GetWriter;
  end; { TOmniCommunicationEndpoint }

  TOmniTwoWayChannel = class(TInterfacedObject, IOmniTwoWayChannel)
  strict private
    twcEndpoint             : array [1..2] of IOmniCommunicationEndpoint;
    twcLock                 : TOmniCS;
    twcMessageQueueSize     : integer;
    twcTaskTerminatedEvt_ref: IOmniEvent;
    twcUnidirQueue          : array [1..2] of TOmniMessageQueue;
  strict protected
    procedure CreateBuffers; inline;
  protected
    function  OtherEndpoint(endpoint: IOmniCommunicationEndpoint): IOmniCommunicationEndpoint;
  public
    constructor Create(messageQueueSize: integer; taskTerminatedEvent: IOmniEvent);
    destructor  Destroy; override;
    function Endpoint1: IOmniCommunicationEndpoint; inline;
    function Endpoint2: IOmniCommunicationEndpoint; inline;
  end; { TOmniTwoWayChannel }

{ exports }

function CreateTwoWayChannel(numElements: integer;
  taskTerminatedEvent: IOmniEvent): IOmniTwoWayChannel;
begin
  Result := TOmniTwoWayChannel.Create(numElements, taskTerminatedEvent);
end; { CreateTwoWayChannel }

{ TOmniMessage }

constructor TOmniMessage.Create(aMsgID: word; aMsgData: TOmniValue);
begin
  MsgID := aMsgID;
  MsgData := aMsgData;
end; { TOmniMessage.Create }

constructor TOmniMessage.Create(aMsgID: word);
begin
  MsgID := aMsgID;
  MsgData := TOmniValue.Null;
end; { TOmniMessage.Create }

{ TOmniMessageQueue }

constructor TOmniMessageQueue.Create(numMessages: integer; createEventObserver: boolean);
begin
  inherited Create(numMessages, SizeOf(TOmniMessage));
  if createEventObserver then
    AttachEventObserver;
  mqIsInitialized := true;
end; { TOmniMessageQueue.Create }

destructor TOmniMessageQueue.Destroy;
begin
  OnMessage := nil; // detach mqMsgObserver before the queue underneath it disappears
  if assigned(mqEventObserver) then begin
    ContainerSubject.Detach(mqEventObserver, coiNotifyOnAllInserts);
    mqEventObserver := nil;
  end;
  if mqIsInitialized then // don't try to clear the queue if code crashes in constructor
    Empty;
  inherited;
end; { TOmniMessageQueue.Destroy }

procedure TOmniMessageQueue.AttachEventObserver;
begin
  if not assigned(mqEventObserver) then begin
    mqEventObserver := CreateContainerEventObserver;
    ContainerSubject.Attach(mqEventObserver, coiNotifyOnAllInserts);
  end;
  mqEventObserver.Activate;
end; { TOmniMessageQueue.AttachEventObserver }

{:Sets up (or tears down) delivery of OnMessage. The observer binds to
  whichever thread is current when a handler is first assigned - matching
  v3's hidden-window binding, but via CreateContainerBackgroundObserver
  instead (cross-platform; Windows: QueueUserAPC, POSIX: thread-local
  registry). Delivery is automatic for OTL task/worker threads
  (TOmniTaskExecutor.WaitForEvent drains background observers on every loop
  iteration); a plain, non-OTL thread must call
  OtlBackgroundObserver.DrainBackgroundObservers itself, or perform an
  alertable wait, for the callback to run.}
procedure TOmniMessageQueue.SetOnMessage(const value: TOmniMessageQueueMessageEvent);
begin
  if (not assigned(mqOnMessage)) and assigned(value) then begin // set up observer
    mqMsgObserver := CreateContainerBackgroundObserver(TThread.Current.ThreadID,
      procedure
      var
        msg: TOmniMessage;
      begin
        while TryDequeue(msg) do
          if assigned(mqOnMessage) then
            mqOnMessage(Self, msg);
      end);
    ContainerSubject.Attach(mqMsgObserver, coiNotifyOnAllInserts);
  end
  else if assigned(mqOnMessage) and (not assigned(value)) then begin // tear down observer
    ContainerSubject.Detach(mqMsgObserver, coiNotifyOnAllInserts);
    mqMsgObserver := nil;
  end;
  mqOnMessage := value;
end; { TOmniMessageQueue.SetOnMessage }

function TOmniMessageQueue.Dequeue: TOmniMessage;
begin
  if not TryDequeue(Result) then
    raise Exception.Create('TOmniMessageQueue.Dequeue: Message queue is empty');
end; { TOmniMessageQueue.Dequeue }

procedure TOmniMessageQueue.Empty;
var
  msg: TOmniMessage;
begin
  while TryDequeue(msg) do
    ;
end; { TOmniMessageQueue.Empty }

function TOmniMessageQueue.Enqueue(const value: TOmniMessage): boolean;
var
  tmp: TOmniMessage;
begin
  tmp := value;
  tmp.MsgData._AddRef;
  Result := inherited Enqueue(tmp);
  if Result then
    tmp.MsgData.RawZero
  else
    tmp.MsgData._Release;
end; { TOmniMessageQueue.Enqueue }

function TOmniMessageQueue.GetNewMessageEvent: IOmniEvent;
begin
  AttachEventObserver;
  Result := mqEventObserver.GetEvent;
end; { TOmniMessageQueue.GetNewMessageEvent }

function TOmniMessageQueue.TryDequeue(var msg: TOmniMessage): boolean;
var
  tmp: TOmniMessage;
begin
  tmp.MsgData.RawZero;
  Result := inherited Dequeue(tmp);
  if not Result then
    Exit;
  msg := tmp;
  tmp.MsgData._Release;
end; { TOmniMessageQueue.TryDequeue }

{ TOmniCommunicationEndpoint }

constructor TOmniCommunicationEndpoint.Create(owner: TOmniTwoWayChannel; readQueue,
  writeQueue: TOmniMessageQueue; taskTerminatedEvent_ref: IOmniEvent);
begin
  inherited Create;
  ceOwner_ref := owner;
  ceReader_ref := readQueue;
  ceWriter_ref := writeQueue;
  ceTaskTerminatedEvent_ref := taskTerminatedEvent_ref;
  FMultiWaitLock := CreateOmniCriticalSection;
end; { TOmniCommunicationEndpoint.Create }

destructor TOmniCommunicationEndpoint.Destroy;
begin
  FMultiWaitLock := nil;
  inherited;
end; { TOmniCommunicationEndpoint.Destroy }

procedure TOmniCommunicationEndpoint.DetachFromQueues;
begin
  ceReader_ref := nil;
  ceWriter_ref := nil;
end; { TOmniCommunicationEndpoint.DetachFromQueues }

function TOmniCommunicationEndpoint.GetNewMessageEvent: IOmniEvent;
begin
  Result := ceReader_ref.GetNewMessageEvent;
end; { TOmniCommunicationEndpoint.GetNewMessageEvent }

function TOmniCommunicationEndpoint.GetOtherEndpoint: IOmniCommunicationEndpoint;
begin
  Result := ceOwner_ref.OtherEndpoint(Self);
end; { TOmniCommunicationEndpoint.GetOtherEndpoint }

function TOmniCommunicationEndpoint.GetReader: TOmniMessageQueue;
begin
  Result := ceReader_ref;
end; { TOmniCommunicationEndpoint.GetReader }

function TOmniCommunicationEndpoint.Receive(var msgID: word; var msgData:
  TOmniValue): boolean;
var
  msg: TOmniMessage;
begin
  Result := Receive(msg);
  if Result then begin
    msgID := msg.msgID;
    msgData := msg.msgData;
  end;
end; { TOmniCommunicationEndpoint.Receive }

function TOmniCommunicationEndpoint.Receive(var msg: TOmniMessage): boolean;
begin
  Result := ceReader_ref.TryDequeue(msg);
end; { TOmniCommunicationEndpoint.Receive }

function TOmniCommunicationEndpoint.ReceiveWait(var msg: TOmniMessage; timeout_ms: cardinal): boolean;
var
  insertObserver: IOmniContainerEventObserver;
  insertEvent   : IOmniEvent;
  insertWaiter  : TWaitFor;
  Signaller     : IOmniSynchro;
  startTime     : int64;
  waitResult    : TWaitFor.TWaitForResult;
  waitTime      : int64;
begin
  Result := Receive(msg);
  if (not Result) and (timeout_ms > 0) then begin
    if ceTaskTerminatedEvent_ref = nil then
      raise Exception.Create('TOmniCommunicationEndpoint.ReceiveWait: <task terminated> event is not set');
    startTime := Time.Timestamp_ms;
    insertObserver := CreateContainerEventObserver;
    try
      insertEvent := insertObserver.GetEvent;
      insertWaiter := TWaitFor.Create([insertEvent, ceTaskTerminatedEvent_ref], FMultiWaitLock);
      try
        ceReader_ref.ContainerSubject.Attach(insertObserver, coiNotifyOnAllInserts);
        try
          repeat
            Result := ceReader_ref.TryDequeue(msg);
            if Result then
              break;
            waitTime := Int64(timeout_ms) - Time.Elapsed_ms(startTime);
            if waitTime < 0 then
              break;
            waitResult := insertWaiter.WaitAny(cardinal(waitTime), Signaller);
            if (waitResult = waAwaited) and (Signaller = insertEvent) then
              Result := ceReader_ref.TryDequeue(msg)
            else if waitResult = waIOCompletion then
              continue // spurious wakeup, retry
            else
              break; // timeout or terminated
          until Result or (Time.Elapsed_ms(startTime) >= Int64(timeout_ms));
        finally ceReader_ref.ContainerSubject.Detach(insertObserver, coiNotifyOnAllInserts); end;
      finally FreeAndNil(insertWaiter); end;
    finally insertObserver := nil; end;
  end;
end; { TOmniCommunicationEndpoint.ReceiveWait }

function TOmniCommunicationEndpoint.ReceiveWait(var msgID: word; var msgData: TOmniValue;
  timeout_ms: cardinal): boolean;
var
  msg: TOmniMessage;
begin
  Result := ReceiveWait(msg, timeout_ms);
  if Result then begin
    msgID := msg.MsgID;
    msgData := msg.MsgData;
  end;
end; { TOmniCommunicationEndpoint.ReceiveWait }

procedure TOmniCommunicationEndpoint.Send(const msg: TOmniMessage);
begin
  if not ceWriter_ref.Enqueue(msg) then
    raise Exception.Create('TOmniCommunicationEndpoint.Send: Queue is full');
end;  { TOmniCommunicationEndpoint.Send }

function TOmniCommunicationEndpoint.SendWait(msgID: word; msgData: TOmniValue;
  timeout_ms: cardinal): boolean;
var
  msg                : TOmniMessage;
  partlyEmptyObserver: IOmniContainerEventObserver;
  partlyEvent        : IOmniEvent;
  partlyEmptyWaiter  : TWaitFor;
  Signaller          : IOmniSynchro;
  startTime          : int64;
  waitResult         : TWaitFor.TWaitForResult;
  waitTime           : int64;
begin
  msg.msgID := msgID;
  msg.msgData := msgData;
  Result := ceWriter_ref.Enqueue(msg);
  if (not Result) and (timeout_ms > 0) then begin
    if ceTaskTerminatedEvent_ref = nil then
      raise Exception.Create('TOmniCommunicationEndpoint.SendWait: <task terminated> event is not set');
    startTime := Time.Timestamp_ms;
    partlyEmptyObserver := CreateContainerEventObserver;
    try
      partlyEvent := partlyEmptyObserver.GetEvent;
      partlyEmptyWaiter := TWaitFor.Create([partlyEvent, ceTaskTerminatedEvent_ref], FMultiWaitLock);
      try
        OtherEndpoint.Reader.ContainerSubject.Attach(partlyEmptyObserver, coiNotifyOnPartlyEmpty);
        try
          repeat
            Result := ceWriter_ref.Enqueue(msg);
            if Result then
              break;
            waitTime := Int64(timeout_ms) - Time.Elapsed_ms(startTime);
            if waitTime < 0 then
              break;
            partlyEmptyObserver.Activate;
            waitResult := partlyEmptyWaiter.WaitAny(cardinal(waitTime), Signaller);
            if (waitResult = waAwaited) and (Signaller = partlyEvent) then
              Result := ceWriter_ref.Enqueue(msg)
            else if waitResult = waIOCompletion then
              continue // spurious wakeup, retry
            else
              break; // timeout or terminated
          until Result or (Time.Elapsed_ms(startTime) >= Int64(timeout_ms));
        finally OtherEndpoint.Reader.ContainerSubject.Detach(partlyEmptyObserver, coiNotifyOnPartlyEmpty); end;
      finally FreeAndNil(partlyEmptyWaiter); end;
    finally partlyEmptyObserver := nil; end;
  end;
  if not Result then
    msg.msgData._ReleaseAndClear;
end; { TOmniCommunicationEndpoint.SendWait }

function TOmniCommunicationEndpoint.SendWait(msgID: word;
  timeout_ms: cardinal): boolean;
var
  msg: TOmniMessage;
begin
  msg.msgID := msgID;
  msg.msgData := TOmniValue.Null;
  result := SendWait(msgID, msg.msgData, timeout_ms);
end; { TOmniCommunicationEndpoint.SendWait }

procedure TOmniCommunicationEndpoint.Send(msgID: word; msgData: TOmniValue);
var
  msg: TOmniMessage;
begin
  msg.msgID := msgID;
  msg.msgData := msgData;
  Send(msg);
end; { TOmniCommunicationEndpoint.Send }

procedure TOmniCommunicationEndpoint.Send(msgID: word; msgData: array of const);
begin
  Send(msgID, TOmniValue.Create(msgData));
end; { TOmniCommunicationEndpoint.Send }

procedure TOmniCommunicationEndpoint.Send(msgID: word);
begin
  Send(msgID, TOmniValue.Null);
end; { TOmniCommunicationEndpoint.Send }

function TOmniCommunicationEndpoint.GetWriter: TOmniMessageQueue;
begin
  Result := ceWriter_ref;
end; { TOmniCommunicationEndpoint.GetWriter }

{ TOmniTwoWayChannel }

constructor TOmniTwoWayChannel.Create(messageQueueSize: integer;
  taskTerminatedEvent: IOmniEvent);
begin
  inherited Create;
  twcMessageQueueSize := messageQueueSize;
  twcTaskTerminatedEvt_ref := taskTerminatedEvent;
end; { TOmniTwoWayChannel.Create }

destructor TOmniTwoWayChannel.Destroy;
var
  i: integer;
begin
  for i := 1 to 2 do
    if assigned(twcEndpoint[i]) then
      (twcEndpoint[i] as IOmniCommunicationEndpointInternal).DetachFromQueues;
  for i := 1 to 2 do begin
    twcUnidirQueue[i].Free;
    twcUnidirQueue[i] := nil;
  end;
  inherited;
end; { TOmniTwoWayChannel.Destroy }

procedure TOmniTwoWayChannel.CreateBuffers;
begin
  if twcUnidirQueue[1] = nil then
    twcUnidirQueue[1] := TOmniMessageQueue.Create(twcMessageQueueSize);
  if twcUnidirQueue[2] = nil then
    twcUnidirQueue[2] := TOmniMessageQueue.Create(twcMessageQueueSize);
end; { TOmniTwoWayChannel.CreateBuffers }

function TOmniTwoWayChannel.Endpoint1: IOmniCommunicationEndpoint;
begin
  if twcEndpoint[1] = nil then begin
    twcLock.Acquire;
    try
      if twcEndpoint[1] = nil then begin
        CreateBuffers;
        twcEndpoint[1] := TOmniCommunicationEndpoint.Create(Self, twcUnidirQueue[1], twcUnidirQueue[2], twcTaskTerminatedEvt_ref);
      end;
    finally twcLock.Release; end;
  end;
  Result := twcEndpoint[1];
end; { TOmniTwoWayChannel.Endpoint1 }

function TOmniTwoWayChannel.Endpoint2: IOmniCommunicationEndpoint;
begin
  if twcEndpoint[2] = nil then begin
    twcLock.Acquire;
    try
      if twcEndpoint[2] = nil then begin
        CreateBuffers;
        twcEndpoint[2] := TOmniCommunicationEndpoint.Create(Self, twcUnidirQueue[2], twcUnidirQueue[1], twcTaskTerminatedEvt_ref);
      end;
    finally twcLock.Release; end;
  end;
  Result := twcEndpoint[2];
end; { TOmniTwoWayChannel.Endpoint2 }

function TOmniTwoWayChannel.OtherEndpoint(endpoint: IOmniCommunicationEndpoint):
  IOmniCommunicationEndpoint;
begin
  if endpoint = Endpoint1 then
    Result := Endpoint2
  else if endpoint = Endpoint2 then
    Result := Endpoint1
  else
    raise Exception.Create('TOmniTwoWayChannel.OtherEndpoint: Invalid endpoint!');
end; { TOmniTwoWayChannel.OtherEndpoint }

{ TOmniMessageQueueTee }

constructor TOmniMessageQueueTee.Create;
begin
  inherited Create;
  obqtQueueList := TList.Create;
end; { TOmniMessageQueueTee.Create }

destructor TOmniMessageQueueTee.Destroy;
begin
  FreeAndNil(obqtQueueList);
  inherited;
end; { TOmniMessageQueueTee.Destroy }

procedure TOmniMessageQueueTee.Attach(const queue: TOmniMessageQueue);
begin
  obqtQueueLock.Acquire;
  try
    obqtQueueList.Add(queue);
  finally obqtQueueLock.Release; end;
end; { TOmniMessageQueueTee.Attach }

procedure TOmniMessageQueueTee.Detach(const queue: TOmniMessageQueue);
begin
  obqtQueueLock.Acquire;
  try
    obqtQueueList.Remove(queue);
  finally obqtQueueLock.Release; end;
end; { TOmniMessageQueueTee.Detach }

function TOmniMessageQueueTee.Enqueue(const value: TOmniMessage): boolean;
var
  pQueue: pointer;
begin
  Result := true;
  obqtQueueLock.Acquire;
  try
    for pQueue in obqtQueueList do
      Result := Result and TOmniMessageQueue(pQueue).Enqueue(value);
  finally obqtQueueLock.Release; end;
end; { TOmniMessageQueueTee.Enqueue }

end.

