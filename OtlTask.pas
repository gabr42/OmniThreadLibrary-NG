///<summary>Task interface. Part of the OmniThreadLibrary project.</summary>
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
///   Contributors      : GJ, Lee_Nover, Claude AI
///   Creation date     : 2008-06-12
///   Last modification : 2026-08-24
///   Version           : 3.04
///</para><para>
///   History:
///     3.04: 2026-08-24
///       - Added the {$IFDEF MSWINDOWS} RegisterWaitObject(THandle,
///         TOmniWaitObjectProc) overload, for consistency with the
///         TOmniWaitObjectMethod overload added alongside it in 3.02 - the
///         3.03 entry below said no THandle+Proc combination was needed;
///         that turned out to be premature.
///     3.03: 2026-08-24
///       - Restored TOmniWaitObjectProc (reference to procedure) and the
///         matching IOmniTask.RegisterWaitObject(IOmniEvent, TOmniWaitObjectProc)
///         overload, dropped during the OTL-NG rewrite with no MIGRATION.md
///         entry (found via real-world callers - dvbTeletext.Generator.pas,
///         dvbsGPI.pas, dvbTeletext.pas, amsActManAppUI.pas - that no longer
///         compiled). TOmniWaitObjectList now keeps a third parallel list,
///         owolAnonResponseHandlers, alongside the existing TMethod-based
///         one; each Add overload fills its own list and leaves the other
///         slot nil/empty.
///     3.02: 2026-04-22
///       - Reinstated Windows-only THandle overloads of
///         RegisterWaitObject/UnregisterWaitObject. Internally bridge via
///         Win32 RegisterWaitForSingleObject to an auto-reset proxy
///         IOmniEvent that plugs into the existing CV-based task waiter.
///     3.01: 2026-04-14
///       - Replaced TOmniTransitionEvent with IOmniEvent.
///     3.0: 2026-04-12 [OTL-NG]
///       - Unified IOmniEvent = IOmniEvent on all platforms.
///       - TOmniWaitObjectList uses TList<IOmniEvent> unconditionally.
///       - Removed THandle overloads of RegisterWaitObject/UnregisterWaitObject.
///       - Removed IOmniEventAndProc, TOmniEventProcList, DecorateEvent stubs.
///     2.0: 2020-04-26
///       - Platform-independent TerminateEvent and TerminatedEvent.
///     1.17a: 2019-10-24
///       - Calling TOmniWaitObjectList.Remove removed only the ResponseHandlers[] handler
///         and not the AnonResponseHandlers[] handler.
///     1.17: 2019-04-26
///       - Defined IOmniTask.RegisterWaitObject with an anonymous method callback.
///     1.16: 2017-08-01
///       - Defined IOmniTask.InvokeOnSelf method.
///     1.15: 2017-07-26
///       - Defined IOmniTask.SetTimer overloads accepting TProc and TProc<integer> timer method.
///     1.14: 2016-07-01
///       - Defined IOmniTask.SetProcessorGroup and .SetNUMANode.
///     1.13: 2011-07-14
///       - IOmniTaskExecutionModifier removed again.
///     1.12: 2011-07-04
///       - IOmniTaskExecutor.Execute accepts optional IOmniTaskExecutionModifier parameter.
///     1.11: 2011-03-16
///       - Defined IOmniTask.Invoke method.
///     1.10: 2010-07-01
///       - Includes OTLOptions.inc.
///     1.09: 2010-03-16
///       - Added support for multiple simultaneous timers. SetTimer takes additional
///         'timerID' parameter. The old SetTimer assumes timerID = 0.
///     1.08: 2010-02-03
///       - Defined IOmniTask.CancellationToken property.
///     1.07: 2010-01-13
///       - Defined IOmniTask.Implementor property.
///     1.06: 2009-12-12
///       - Defined IOmniTask.RegisterWaitObject/UnregisterWaitObject.
///       - Implemented TOmniWaitObjectList.
///     1.05: 2009-02-06
///       - Implemented per-thread data storage.
///     1.04: 2009-01-26
///       - Implemented IOmniTask.Enforced behaviour modifier.
///     1.03: 2008-11-01
///       - *** Breaking interface change ***
///         - IOmniTask.Terminated renamed to IOmniTask.Stopped.
///         - New IOmniTask.Terminated that check whether the task
///           *has been requested to terminate*.
///     1.02: 2008-10-05
///       - Added two overloaded SetTimer methods using string/pointer invocation.
///     1.01: 2008-09-18
///       - Exposed SetTimer interface.
///     1.0: 2008-08-26
///       - First official release.
///</para></remarks>

unit OtlTask;

{$I OtlOptions.inc}

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  OtlCommon,
  OtlSync,
  OtlComm;

type
  IOmniTask = interface;

  TOmniWaitObjectMethod = procedure of object;
  TOmniWaitObjectProc = reference to procedure;

  TOmniWaitObjectList = class
  strict private
    owolAnonResponseHandlers: TList<TOmniWaitObjectProc>;
    owolResponseHandlers    : TList<TMethod>;
    owolWaitObjects         : TList<IOmniEvent>;
  strict protected
    function  GetAnonResponseHandlers(idxHandler: integer): TOmniWaitObjectProc;
    function  GetResponseHandlers(idxHandler: integer): TOmniWaitObjectMethod;
    function  GetWaitObjects(idxWaitObject: integer): IOmniEvent;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure Add(waitObject: IOmniEvent; responseHandler: TOmniWaitObjectMethod); overload;
    procedure Add(waitObject: IOmniEvent; responseHandler: TOmniWaitObjectProc); overload;
    function  Count: integer;
    procedure Remove(waitObject: IOmniEvent);
    property AnonResponseHandlers[idxHandler: integer]: TOmniWaitObjectProc read
      GetAnonResponseHandlers;
    property ResponseHandlers[idxHandler: integer]: TOmniWaitObjectMethod read
      GetResponseHandlers;
    property WaitObjects[idxWaitObject: integer]: IOmniEvent read GetWaitObjects;
  end; { TOmniWaitObjectList }

  TOmniSynchroArray = TArray<IOmniSynchro>;

  TOmniTaskInvokeFunction = reference to procedure;
//  TOmniTaskInvokeFunctionEx = reference to procedure(const task: IOmniTaskControl);

  IOmniTask = interface ['{958AE8A3-0287-4911-B475-F275747400E4}']
    function  GetCancellationToken: IOmniCancellationToken;
    function  GetComm: IOmniCommunicationEndpoint;
    function  GetCounter: IOmniCounter;
    function  GetImplementor: TObject;
    function  GetLock: TSynchroObject;
    function  GetName: string;
    function  GetParam: TOmniValueContainer;
    function  GetTerminateEvent: IOmniEvent;
    function  GetThreadData: IInterface;
    function  GetUniqueID: int64;
  //
    procedure ClearTimer(timerID: integer = 0);
    procedure Enforced(forceExecution: boolean = true);
    procedure Invoke(remoteFunc: TOmniTaskInvokeFunction); //overload;
    procedure InvokeOnSelf(remoteFunc: TOmniTaskInvokeFunction);
//    procedure Invoke(remoteFunc: TOmniTaskInvokeFunctionEx); overload;
    procedure RegisterComm(const comm: IOmniCommunicationEndpoint);
    procedure RegisterWaitObject(waitObject: IOmniEvent; responseHandler: TOmniWaitObjectMethod); overload;
    procedure RegisterWaitObject(waitObject: IOmniEvent; responseHandler: TOmniWaitObjectProc); overload;
    {$IFDEF MSWINDOWS}
    procedure RegisterWaitObject(waitHandle: THandle; responseHandler: TOmniWaitObjectMethod); overload;
    procedure RegisterWaitObject(waitHandle: THandle; responseHandler: TOmniWaitObjectProc); overload;
    {$ENDIF MSWINDOWS}
    procedure SetException(exceptionObject: pointer);
    procedure SetExitStatus(exitCode: integer; const exitMessage: string);
    procedure SetTimer(interval_ms: cardinal); overload; deprecated 'use three-parameter version';
    procedure SetTimer(interval_ms: cardinal; const timerMessage: TOmniMessageID); overload; deprecated 'use three-parameter version';
    procedure SetTimer(timerID: integer; interval_ms: cardinal; const timerMessage: TOmniMessageID); overload;
    procedure SetTimer(timerID: integer; interval_ms: cardinal; const timerMessage: TProc); overload;
    procedure SetTimer(timerID: integer; interval_ms: cardinal; const timerMessage: TProc<integer>); overload;
    procedure StopTimer;
    procedure Terminate;
    function  Terminated: boolean;
    function  Stopped: boolean;
    procedure UnregisterComm(const comm: IOmniCommunicationEndpoint);
    procedure UnregisterWaitObject(waitObject: IOmniEvent); overload;
    {$IFDEF MSWINDOWS}
    procedure UnregisterWaitObject(waitHandle: THandle); overload;
    {$ENDIF MSWINDOWS}
    property CancellationToken: IOmniCancellationToken read GetCancellationToken;
    property Comm: IOmniCommunicationEndpoint read GetComm;
    property Counter: IOmniCounter read GetCounter;
    property Implementor: TObject read GetImplementor;
    property Lock: TSynchroObject read GetLock;
    property Name: string read GetName;
    property Param: TOmniValueContainer read GetParam;
    property TerminateEvent: IOmniEvent read GetTerminateEvent; //use Terminate to terminate a task, don't just set TerminateEvent
    property ThreadData: IInterface read GetThreadData;
    property UniqueID: int64 read GetUniqueID;
  end; { IOmniTask }

  IOmniTaskExecutor = interface ['{123F2A63-3769-4C5B-89DA-1FEB6C3421ED}']
    procedure Execute;
    procedure SetThreadData(const value: IInterface);
  end; { IOmniTaskExecutor }

  TOmniTaskDelegate = reference to procedure(const task: IOmniTask);

implementation

{ TOmniWaitObjectList }

constructor TOmniWaitObjectList.Create;
begin
  inherited Create;
  owolWaitObjects := TList<IOmniEvent>.Create;
  owolResponseHandlers := TList<TMethod>.Create;
  owolAnonResponseHandlers := TList<TOmniWaitObjectProc>.Create;
end; { TOmniWaitObjectList.Create }

destructor TOmniWaitObjectList.Destroy;
begin
  FreeAndNil(owolAnonResponseHandlers);
  FreeAndNil(owolResponseHandlers);
  FreeAndNil(owolWaitObjects);
  inherited Destroy;
end; { TOmniWaitObjectList.Destroy }

procedure TOmniWaitObjectList.Add(waitObject: IOmniEvent;
  responseHandler: TOmniWaitObjectMethod);
begin
  Remove(waitObject);
  owolWaitObjects.Add(waitObject);
  owolResponseHandlers.Add(TMethod(responseHandler));
  owolAnonResponseHandlers.Add(nil);
end; { TOmniWaitObjectList.Add }

procedure TOmniWaitObjectList.Add(waitObject: IOmniEvent;
  responseHandler: TOmniWaitObjectProc);
var
  emptyMethod: TMethod;
begin
  Remove(waitObject);
  owolWaitObjects.Add(waitObject);
  emptyMethod.Code := nil;
  emptyMethod.Data := nil;
  owolResponseHandlers.Add(emptyMethod);
  owolAnonResponseHandlers.Add(responseHandler);
end; { TOmniWaitObjectList.Add }

function TOmniWaitObjectList.Count: integer;
begin
  Result := owolWaitObjects.Count;
end; { TOmniWaitObjectList.Count }

function TOmniWaitObjectList.GetAnonResponseHandlers(idxHandler: integer): TOmniWaitObjectProc;
begin
  Result := owolAnonResponseHandlers[idxHandler];
end; { TOmniWaitObjectList.GetAnonResponseHandlers }

function TOmniWaitObjectList.GetResponseHandlers(idxHandler: integer):
  TOmniWaitObjectMethod;
begin
  Result := TOmniWaitObjectMethod(owolResponseHandlers[idxHandler]);
end; { TOmniWaitObjectList.GetResponseHandlers }

function TOmniWaitObjectList.GetWaitObjects(idxWaitObject: integer): IOmniEvent;
begin
  Result := owolWaitObjects[idxWaitObject];
end; { TOmniWaitObjectList.GetWaitObjects }

procedure TOmniWaitObjectList.Remove(waitObject: IOmniEvent);
var
  idxWaitObject: integer;
begin
  idxWaitObject := owolWaitObjects.IndexOf(waitObject);
  if idxWaitObject >= 0 then begin
    owolWaitObjects.Delete(idxWaitObject);
    owolResponseHandlers.Delete(idxWaitObject);
    owolAnonResponseHandlers.Delete(idxWaitObject);
  end;
end; { TOmniWaitObjectList.Remove }

end.
