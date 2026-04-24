///<summary>Synchronisation primitives. Part of the OmniThreadLibrary project.</summary>
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
///   Contributors      : GJ, Lee_Nover, dottor_jeckill, Sean B. Durkin, VyPu, Claude AI
///   Creation date     : 2009-03-30
///   Last modification : 2026-04-17
///   Version           : 3.03
///</para><para>
///   History:
///     3.03: 2026-04-17
///       - Cross-platform build: compiles for Linux64 (dcclinux64) and Windows
///         ARM64EC (dccarm64ec) in addition to Win32/Win64.
///       - Guarded TOmniWrappedEvent (Windows-only: uses CloseHandle) with
///         {$IFDEF MSWINDOWS}.
///       - Moved TWaitFor.SetSynchObjects implementation out of the Windows
///         block; its declaration is unconditional and its body does not touch
///         Windows APIs.
///       - Removed illegal 'overload' directive from implementation-site
///         method headers (Locked<T>.TryBeginWrite,
///         TLightweightMREWExImpl.TryBeginWrite) and added a missing ';' on
///         TLightweightMREWExImpl.TryBeginRead — all inside the Linux/Android
///         conditional block, so prior Windows builds never exercised them.
///       - Switched {$IFDEF CPUX64} to {$IFDEF CPU64BITS} in TOmniMREW.ExitWriteLock
///         and TInterlockedEx.CompareExchange/Add so Windows ARM64 (64-bit
///         NativeInt) takes the 64-bit path instead of mis-casting to integer.
///       - Added non-Windows x86_64 InterlockedCompareExchange128 fallback —
///         dcclinux64 does not support inline ASM, so the Linux fallback uses a
///         coarse global spinlock. TODO: replace with a proper cross-platform
///         design before ARM64/Android targets are enabled.
///     3.02: 2026-04-14
///       - Fixed CAS16 offset mask: added alignment assert to prevent
///         straddling 4-byte boundary at byte offset 3.
///       - Removed dead CreateOmniEvent(TEvent, boolean) factory (no
///         matching constructor, no callers).
///       - Fixed TOmniSynchroObject.Destroy use-after-free: moved inherited
///         call after the spin lock `with` block to prevent TSynchroSpin
///         from accessing destroyed Self.
///       - Fixed TOmniWrappedEvent: close handle leaked by inherited
///         constructor; implement owned-event cleanup in destructor.
///       - Fixed TOmniMREW.ExitWriteLock: use TInterlocked.Exchange for ARM
///         memory barrier correctness.
///       - Fixed TOmniMREW.EnterReadLock/EnterWriteLock: added progressive
///         TThread.SpinWait backoff to prevent 100% CPU burn under contention.
///       - Fixed TOmniEvent.WaitFor: FState update now uses
///         PerformObservableAction for proper synchronization.
///       - Fixed TOmniEvent.Create(THandle): added AManualReset parameter to
///         prevent incorrect auto-reset behavior on manual-reset external events.
///       - Fixed Locked<T>.Initialize: race on FLock creation now uses
///         TInterlocked.CompareExchange; added MFence for ARM barrier.
///       - Fixed TOmniLockManager.Lock: negative wait_ms no longer wraps to
///         cardinal max — breaks out of loop instead.
///     3.02: 2026-04-17
///       - Fixed gate-leak race in TSynchroClient: EnterGate now saves the gate
///         reference before acquiring, so GetGate returns it even after Deref
///         nils FController. Prevents leaked lock when PerformObservableAction
///         runs concurrently with TWaitFor.Destroy.
///     3.01: 2026-04-14
///       - Fixed TCondition.Wait spurious wakeup bug — condvar wait now loops
///         instead of returning wrIOCompletion on spurious wakeup.
///       - Fixed lock-order inversion deadlock in PerformObservableAction —
///         snapshot-based approach releases spin lock before entering gates.
///       - Removed TOmniTransitionEvent type alias (replaced with IOmniEvent).
///     3.0: 2026-04-12
///       - OTL-NG: TOmniTransitionEvent is now unconditionally IOmniEvent on all platforms.
///       - Added TWaitFor.SetSynchObjects for updating synchro objects after construction.
///       - Simplified SetEvent(IOmniEvent) helper (removed conditional).
///       - Removed unused GpSync.CondVar import.
///       - Fixed TPreSignalData.Create parameter name bug (AllSignalled self-assignment).
///       - Fixed W1035 warnings in Atomic<T>.Initialize and Locked<T>.Initialize.
///     2.03a: 2025-11-20
///       - Implemented Locked<T>.IsInitialized.
///     2.03: 2025-11-11
///       - Implemented TLightweightMREWEx extension to TLightweightMREW (Delphi 11+ only).
///         This class adds support for nested BeginWrite/EndWrite calls.
///         See https://www.thedelphigeek.com/2021/02/readers-writ-47358-48721-45511-46172.html
///         for more information.
///       - Implemented interface ILightweightMREWEx with the same public
///         methods as TLightweightMREWEx and implementing class
///         TLightweightMREWExImpl that wraps TLightweightMREWEx.
///       - Added methods Enter: T and Leave to Locked<T>.
///       - Added methods BeginRead, TryBeginRead, EndRead, BeginWrite,
///         TryBeginWrite, EndWrite to Locked<T> (Delphi 11+ only).
///       - Locked<T>.Access/Release now implement locking with a
///         SRW lock (when available) in 'write' access mode. This is functionally
///         identical to the old implementation (critical section).
///     2.02: 2021-02-01
///       - Added TWaitFor constructor overload accepting array of IOmniSynchro instances.
///       - IOmniEvent.Signal works the same as IOmniEvent.SetEvent.
///       - Fixed TWaitFor.WaitAll and TWaitFor.WaitAny for non-Windows platforms.
///     2.01b: 2019-03-19
///       - TOmniMREW.TryEnterReadLock and .TryEnterWriteLock were returning True on timeout.
///     2.01a: 2018-11-02
///       - Fixed race condition between TOmniResourceCount.[Try]Allocate and TOmniResourceCount.Release.
///     2.01: 2018-06-14
///       - Added TOmniEvent constructor that wraps existing THandle (Windows only),
///         optionally taking over the ownership.
///     2.0a: 2018-05-28
///       - Fixed warnings.
///     2.0: 2018-05-13
///       - Removed support for pre-XE Delphis.
///       - DSiTimeGetTime64 replaced with OtlPlatform.Time.
///       - Removed TInterlockedEx.Increment and .Decrement.
///     1.27c: 2020-09-16
///       - Fixed TOmniMREW.TryEnterWriteLock which incorrectly managed the shared lock
///         state when a timeout occurred. [issue #149]
///     1.27b: 2019-03-19
///       - TOmniMREW.TryEnterReadLock and .TryEnterWriteLock were returning True on timeout.
///     1.27a: 2018-11-02
///       - Fixed race condition between TOmniResourceCount.[Try]Allocate and TOmniResourceCount.Release.
///	    1.27: 2018-04-06
///	      - Added timeout parameter to TOmniMREW.TryEnterReadLock and TOmniMREW.TryExitReadLock.
///     1.26: 2017-11-09
///       - [VyPu] Fixed: TOmniCriticalSection.Release decremented ocsLockCount after releasing the critical section.
///     1.25: 2017-09-28
///       - [VyPu] Locked<T>.Value is now both readable and writable property.
///     1.24: 2017-06-14
///       - TOmniCS.Initialize uses global lock to synchronize initialization instead of
///         a CAS operation. This fixes all reasons for the infamous error
///         "TOmniCS.Initialize: XXX is not properly aligned!".
///     1.23: 2016-10-24
///       - Implemented two-parameter version of Atomic initializer which intializes
///         an interface type from a class type.
///     1.22c: 2015-09-10
///       - Fixed unsafe 64-bit pointer-to-integer casts.
///     1.22b: 2015-09-07
///       - TWaitFor.MsgWaitAny now uses RegisterWaitForSingleObject approach when
///         waiting on 64 handles. Previously, MsgWaitForMultipleObjectsEx was called,
///         which can only handle up to 63 handles.
///     1.22a: 2015-09-04
///       - Fixed a bug in TWaitFor: When the code was waiting on less than 64 handles
///         and timeout occurred, the Signalled[] property was not always empty.
///       - Fixed: TWaitFor was not working correctly with more than 64 handles if
///         it was created with the parameter-less constructor.
///     1.22: 2015-07-27
///       - Implemented TOmniSingleThreadUseChecker.AttachToThread which forcibly
///         attaches thread checker to the current thread even if it was used
///         from another thread before.
///     1.21: 2015-07-10
///       - Implemented TOmniSingleThreadUseChecker, a record which checks that the
///         owner is only used from one thread. See OtlComm/TOmniCommunicationEndpoint
///         for an example.
///     1.20: 2015-04-17
///       - TOmniCS.GetLockCount won't crash if Initialize was not called yet.
///     1.19: 2014-11-04
///       - TWaitForAll renamed to TWaitFor.
///       - TWaitFor.Wait renamed to TWaitFor.WaitAll.
///       - Implemented TWaitFor.MsgWaitAny and .WaitAny.
///       - Implemented WaitForAnyObject.
///     1.18: 2014-11-03
///       - Implemented WaitForAllObjects and TWaitForAll class.
///     1.17: 2014-01-11
///       - Implemented TOmniMREW.TryEnterReadLock and TryEnterWriteLock.
///     1.16: 2014-01-09
///       - Locked<T>.Free can be called if Locked<T> owns its Value.
///     1.15: 2013-03-05
///       - TOmniLockManager<K> is reentrant.
///     1.14: 2013-02-27
///       - Implemented TOmniLockManager<K> and IOmniLockManager<K>.
///     1.13a: 2013-01-08
///       - Locked<T>.Free must execute in locked context.
///     1.13: 2012-02-21
///       - Implemented Locked<T>.Locked.
///     1.12: 2011-12-16
///       - [GJ] Converted low-level primitives to work in 64-bit platform and added few
///         platform-independent versions (CAS, MoveDPtr).
///     1.11: 2011-12-14
///       - Implemented simplified versions of Atomic<T:class,constructor>.Initialize and
///         Locked<T:class,constructor>.Initialize that work on D2010 and newer.
///     1.10a: 2011-12-09
///       - TOmniCS reuses LockCount from owned TOmniCriticalSection.
///     1.10: 2011-12-02
///       - Locked<class> by default takes ownership of the object and frees it when
///         Locked<> goes out of scope. You can change this by calling
///         Locked<T>.Create(obj, false). To free the object manually, call Locked<T>.Free.
///       - Atomic<class>.Initialize was broken.
///       - Implemented Atomic<class>.Initialize(object) and Locked<class>.Initialize.
///       - Implemented Mfence.
///       - Locked<T>.Initialize creates memory barrier after storing newly created
///         resource into shared variable.
///     1.09: 2011-12-01
///       - IOmniCriticalSection implements TFixedCriticalSection (as suggested by Eric
///         Grange in http://delphitools.info/2011/11/30/fixing-tcriticalsection/).
///       - Implemented IOmniCriticalSection.LockCount and TOmniCS.LockCount.
///       - Locked<T>.GetValue raises exception if critical section's LockCount is 0.
///     1.08: 2011-11-29
///       - Implements Locked<T> class.
///     1.07a: 2011-11-29
///       - Compiles with D2007.
///     1.07: 2011-11-25
///       - Implemented Atomic<T> class for atomic interface initialization.
///     1.06: 2011-03-01
///       - [dottor_jeckill] Bug fix: TOmniResourceCount.TryAllocate always returned False.
///     1.05: 2010-07-01
///       - Includes OTLOptions.inc.
///     1.04a: 2010-03-30
///       - Prevent race condition in a rather specialized usage of TOmniResourceCount.
///     1.04: 2010-02-04
///       - Implemented CAS8 and CAS16.
///     1.03: 2010-02-03
///       - IOmniCancellationToken extended with the Clear method.
///     1.02: 2010-02-02
///       - Implemented IOmniCancellationToken.
///     1.01a: 2010-01-07
///       - "Wait when no resources" state in TOmniResourceCount was not properly
///         implemented.
///     1.01: 2009-12-30
///       - Implemented resource counter with empty state signalling - TOmniResourceCount.
///     1.0: 2008-08-26
///       - TOmniCS and IOmniCriticalSection imported from the OtlCommon unit.
///       - [GJ] Added very simple (and very fast) multi-reader-exclusive-writer TOmniMREW.
///       - First official release.
///</para></remarks>

unit OtlSync;

{$I OtlOptions.inc}

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Classes,
  System.Generics.Defaults,
  System.Generics.Collections,
  System.RTTI,
  System.TypInfo,
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF MSWINDOWS}
  {$IFDEF POSIX}
  Posix.Pthread,
  {$ENDIF POSIX}
  System.Diagnostics,
  OtlCommon;

type
  TFixedCriticalSection = class(TCriticalSection)
  strict protected
    FDummy: array [0..95] of byte;
    FLogMe: boolean;
  public
    constructor Create(logMe: boolean = false);
    destructor  Destroy; override;
    procedure Acquire; override;
    procedure Release; override;
  end; { TFixedCriticalSection }

  IOmniCriticalSection = interface ['{AA92906B-B92E-4C54-922C-7B87C23DABA9}']
    function  GetLockCount: integer;
    //
    procedure Acquire;
    procedure Release;
    function  GetSyncObj: TSynchroObject;
    property LockCount: integer read GetLockCount;
  end; { IOmniCriticalSection }

  IOmniSynchroObserver = interface ['{03330A74-3C3D-4D2F-9A21-89663DE7FD10}']
    procedure EnterGate;
    procedure LeaveGate;
    procedure GetGate(out gate: IOmniCriticalSection);
    /// <param name="SynchObj">SynchObj must support IOmniSynchroObject.</param>
    procedure DereferenceSynchObj(const SynchObj: TObject; AllowInterface: boolean);
    /// <param name="Subtractend">Signaller must support IOmniSynchroObject.</param>
    procedure BeforeSignal(const Signaller: TObject; var Data: TObject);
    /// <param name="Subtractend">Signaller must support IOmniSynchroObject.</param>
    procedure AfterSignal(const Signaller: TObject; var Data: TObject);
  end; { IOmniSynchroObserver }

  IOmniSynchro = interface ['{2C4F0CF8-A722-45EC-BFCA-AA512E58B54D}']
    function  EnterSpinLock: IInterface;
    procedure Signal;
    /// <remarks>
    ///  If this event is attached to IOmniSynchroObserver,
    //    such as TWaitFor (acting as a condition variable)
    ///   a thread must not invoke WaitFor() directly on this event, but
    ///   rather through the containing TWaitFor, or as otherwise defined by
    //    the attached observer.
    /// </remarks>
    function  WaitFor(Timeout: Cardinal = INFINITE): TWaitResult; overload;
    procedure ConsumeSignalFromObserver( const Observer: IOmniSynchroObserver);
    /// <remarks>
    ///  IsSignaled() is only valid when all the Signal()/ Reset()
    ///   invocations are done whilst attached to an IOmniEventObserver.
    ///   Otherwise this returned value must not be relied upon.
    /// </remarks>
    function  IsSignalled: boolean;
    procedure AddObserver(const Observer: IOmniSynchroObserver);
    procedure RemoveObserver(const Observer: IOmniSynchroObserver);
    function  Base: TSynchroObject;
    {$IFDEF MSWINDOWS}
    function  Handle: THandle;
    function  HasKernelHandle: boolean;
    /// <remarks>
    ///  Called from the kernel-wait fast path (TCondition.TryKernelFastPath)
    ///  after WaitForMultipleObjects returned a signalled handle and the OS
    ///  already performed whatever auto-reset was appropriate. The default
    ///  implementation just syncs the tracked FState to match; implementors
    ///  must NOT issue an additional kernel syscall (ResetEvent, etc.).
    /// </remarks>
    procedure AckKernelConsumed;
    {$ENDIF}
  end; { IOmniSynchro }

  IOmniSynchroObject = interface ['{A8B95978-87BF-4031-94B2-8EDC351F47BE}']
    function  GetSynchro: IOmniSynchro;
  //
    property Synchro: IOmniSynchro read GetSynchro;
  end; { IOmniSynchroObject }

  /// <remarks>
  ///   IOmniEvent is a wrapper around a TEvent object.
  ///   It can co-operate with condition variables through the use of an
  ///   attached IOmniEventObserver. IOmniEvent objects can be enrolled
  ///   in TWaitFor objects on non-windows platforms.
  /// </remarks>
  IOmniEvent = interface(IOmniSynchro) ['{3403D24B-3CBE-4A83-9F4C-FA4719AA23C5}']
    procedure SetEvent;
    procedure Reset;
    function  BaseEvent: TEvent;
  end; { IOmniEvent }

  IOmniCountdownEvent = interface(IOmniSynchro) ['{40557184-B610-46E8-B186-D5B431D1B1A4}']
    function  BaseCountdown: TCountdownEvent;
    procedure Reset;
  end; { IOmniCountdownEvent }



  //IOmniHandleObject removed — use IOmniSynchroObject instead

  ///<summary>Simple critical section wrapper. Critical section is automatically
  ///    initialised on first use.</summary>
  TOmniCS = record
  strict private
    ocsSync: IOmniCriticalSection;
  private
    function  GetLockCount: integer; inline;
    function  GetSyncObj: TSynchroObject; inline;
  public
    procedure Initialize;
    procedure Acquire; inline;
    procedure Release; inline;
    property LockCount: integer read GetLockCount;
    property SyncObj: TSynchroObject read GetSyncObj;
  end; { TOmniCS }

  ///<summary>Very lightweight multiple-readers-exclusive-writer lock.</summary>
  TOmniMREW = record
  strict private
    //Treated as an integer, IInterface is only used to provide automatic initialization to 0.
    //Bit0 is 'writing in progress' flag.
    omrewReference: IInterface;
  public
    procedure EnterReadLock; inline;
    procedure EnterWriteLock; inline;
    procedure ExitReadLock; inline;
    procedure ExitWriteLock; inline;
    function  TryEnterReadLock(timeout_ms: integer = 0): boolean;
    function  TryEnterWriteLock(timeout_ms: integer = 0): boolean;
  end; { TOmniMREW }

  IOmniResourceCount = interface(IOmniSynchroObject)
  ['{F5281539-1DA4-45E9-8565-4BEA689A23AD}']
    {$IFDEF MSWINDOWS}
    function  GetHandle: THandle;
    {$ENDIF MSWINDOWS}
    function  Allocate: cardinal;
    function  Release: cardinal;
    function  TryAllocate(var resourceCount: cardinal; timeout_ms: cardinal = 0): boolean;
    {$IFDEF MSWINDOWS}
    property Handle: THandle read GetHandle;
    {$ENDIF MSWINDOWS}
  end; { IOmniResourceCount }

  ///<summary>Kind of an inverse semaphore. Gets signalled when count drops to 0.
  ///   Allocate decrements the count (and blocks if initial count is 0), Release
  ///   increments the count.
  ///   Threadsafe.
  ///</summary>
  TOmniResourceCount = class(TInterfacedObject, IOmniResourceCount, IOmniSynchroObject)
  strict private
    orcAvailable   : IOmniEvent;
    orcZero        : IOmniEvent;
    orcLock        : TOmniCS;
    orcNumResources: TOmniAlignedInt32;
  protected
    {$IFDEF MSWINDOWS}
    function  GetHandle: THandle;
    {$ENDIF MSWINDOWS}
    function  GetSynchro: IOmniSynchro;
  public
    constructor Create(initialCount: cardinal);
    function  Allocate: cardinal; inline;
    function  Release: cardinal;
    function  TryAllocate(var resourceCount: cardinal; timeout_ms: cardinal = 0): boolean;
    {$IFDEF MSWINDOWS}
    property Handle: THandle read GetHandle;
    {$ENDIF MSWINDOWS}
    property Synchro: IOmniSynchro read GetSynchro;
  end; { TOmniResourceCount }

  IOmniCancellationToken = interface ['{5946F4E8-45C0-4E44-96AB-DBE2BE66A701}']
    function  GetEvent: IOmniEvent;
    {$IFDEF MSWINDOWS}
    function  GetHandle: THandle;
    {$ENDIF MSWINDOWS}
  //
    procedure Clear;
    function  IsSignalled: boolean;
    procedure Signal;
    property Event: IOmniEvent read GetEvent;
    {$IFDEF MSWINDOWS}
    property Handle: THandle read GetHandle;
    {$ENDIF MSWINDOWS}
  end; { IOmniCancellationToken }

  TLightweightMREWEx = record
  private
    FRWLock        : TLightweightMREW;
    FWriteLockCount: TOmniAlignedInt32;
    FLockOwner     : TThreadID;
  private
    function  GetLockOwner: TThreadID; inline;
    procedure SetLockOwner(value: TThreadID); inline;
  public
    class operator Initialize(out dest: TLightweightMREWEx);
    procedure BeginRead; inline;
    function  TryBeginRead: boolean; {$IF defined(LINUX) or defined(ANDROID)}overload;{$ENDIF} inline;
    {$IF defined(LINUX) or defined(ANDROID)}
    function  TryBeginRead(timeout: cardinal): boolean; overload; inline;
    {$ENDIF LINUX or ANDROID}
    procedure EndRead; inline;
    procedure BeginWrite;
    function  TryBeginWrite: boolean; {$IF defined(LINUX) or defined(ANDROID)}overload;
    function  TryBeginWrite(timeout: cardinal): boolean; overload;
    {$ENDIF LINUX or ANDROID}
    procedure EndWrite;
  end; { TLightweightMREWEx }

  ILightweightMREWEx = interface
    procedure BeginRead;
    function  TryBeginRead: boolean; {$IF defined(LINUX) or defined(ANDROID)}overload;
    function  TryBeginRead(timeout: cardinal): boolean; overload;
    {$ENDIF LINUX or ANDROID}
    procedure EndRead;
    procedure BeginWrite;
    function  TryBeginWrite: boolean; {$IF defined(LINUX) or defined(ANDROID)}overload;
    function  TryBeginWrite(timeout: cardinal): boolean; overload;
    {$ENDIF LINUX or ANDROID}
    procedure EndWrite;
  end; { ILightweightMREWEx }

  TLightweightMREWExImpl = class(TInterfacedObject, ILightweightMREWEx)
  strict private
    FLock: TLightweightMREWEx;
  public
    procedure BeginRead;
    function  TryBeginRead: boolean; {$IF defined(LINUX) or defined(ANDROID)}overload;
    function  TryBeginRead(timeout: cardinal): boolean; overload;
    {$ENDIF LINUX or ANDROID}
    procedure EndRead;
    procedure BeginWrite;
    function  TryBeginWrite: boolean; {$IF defined(LINUX) or defined(ANDROID)}overload;
    function  TryBeginWrite(timeout: cardinal): boolean; overload;
    {$ENDIF LINUX or ANDROID}
    procedure EndWrite;
  end; { TLightweightMREWEx }

  Atomic<T> = class
    type TFactory = reference to function: T;
    class function Initialize(var storage: T; factory: TFactory): T; overload;
    class function Initialize(var storage: T): T; overload;
  end; { Atomic<T> }

  Atomic<I; T:constructor> = class
    class function Initialize(var storage: I): I;
  end; { Atomic<I,T> }

  Locked<T> = record
  strict private // keep those aligned!
    // FLock and FLockCount must be interfaces.
    // If an instance of Locked<T> is access via property, it will bo copied.
    // If FLock or FLockCount would be non-referenced objects, this copying
    // would break the connection between the original Locked<T> and its copy.
    FLock     : ILightweightMREWEx;
    {$IFDEF DEBUG}
    FLockCount: IOmniCounter;
    {$ENDIF DEBUG}
    FValue    : T;
  strict private
    FInitialized: boolean;
    FLifecycle  : IInterface;
    FOwnsObject : boolean;
    procedure AssertLocked; inline;
    procedure Clear; inline;
    function  GetValue: T; inline;
    procedure SetValue(const value: T); inline;
  public
    type TFactory = reference to function: T;
    type TProcT = reference to procedure(const value: T);
    constructor Create(const value: T; ownsObject: boolean = true);
    class operator Implicit(const value: Locked<T>): T; inline;
    class operator Implicit(const value: T): Locked<T>; inline;
    function  Initialize(factory: TFactory): T; overload;
    function  Initialize: T; overload;
    procedure Acquire; inline;   // acquires Write SRW lock on Delphi 11+, critical section lock on previous versions
    procedure Release; inline;   // releases Write SRW lock on Delphi 11+, critical section lock on previous versions
    function  Enter: T; inline;  // acquires Write SRW lock on Delphi 11+, critical section lock on previous versions
    procedure Leave; inline;     // releases Write SRW lock on Delphi 11+, critical section lock on previous versions
    procedure Locked(proc: TProc); overload; inline;
    procedure Locked(proc: TProcT); overload; inline;

    function  BeginRead: T; inline;
    procedure EndRead; inline;
    function  TryBeginRead: boolean; {$IF defined(LINUX) or defined(ANDROID)}overload;{$ENDIF} inline;
    {$IF defined(LINUX) or defined(ANDROID)}
    function  TryBeginRead(Timeout: Cardinal): Boolean; overload; inline;
    {$ENDIF LINUX or ANDROID}
    function  BeginWrite: T; inline;
    procedure EndWrite; inline;
    function  TryBeginWrite: boolean; {$IF defined(LINUX) or defined(ANDROID)}overload;
    function  TryBeginWrite(timeout: cardinal): boolean; overload; inline;
    {$ENDIF LINUX or ANDROID}
    procedure Free; //inline;
    property IsInitialized: boolean read FInitialized;
    property Value: T read GetValue write SetValue;
  end; { Locked<T> }

  IOmniLockManagerAutoUnlock = interface
    procedure Unlock;
  end; { IOmniLockManagerAutoUnlock }

  IOmniLockManager<K> = interface
    function  Lock(const key: K; timeout_ms: cardinal): boolean;
    function  LockUnlock(const key: K; timeout_ms: cardinal): IOmniLockManagerAutoUnlock;
    procedure Unlock(const key: K);
  end; { IOmniLockManager<K> }

  TOmniLockManager<K> = class(TInterfacedObject, IOmniLockManager<K>)
  strict private type
    TNotifyPair = class
      Key   : K;
      Notify: IOmniEvent;
      constructor Create(const aKey: K; aNotify: IOmniEvent);
    end;
    TLockValue = record
      LockCount: integer;
      ThreadID : TThreadID;
      constructor Create(aThreadID: TThreadID; aLockCount: integer);
    end;
  strict private
    FComparer  : IEqualityComparer<K>;
    FLock      : TOmniCS;
    FLockList  : TDictionary<K,TLockValue>;
    FNotifyList: TObjectList<TNotifyPair>;
  strict private type
    TAutoUnlock = class(TInterfacedObject, IOmniLockManagerAutoUnlock)
    strict private
      FUnlockProc: TProc;
    public
      constructor Create(unlockProc: TProc);
      destructor  Destroy; override;
      procedure Unlock;
    end;
  public
    class function CreateInterface(capacity: integer = 0): IOmniLockManager<K>; overload;
    class function CreateInterface(comparer: IEqualityComparer<K>; capacity: integer = 0):
      IOmniLockManager<K>; overload;
    constructor Create(capacity: integer = 0); overload;
    constructor Create(const comparer: IEqualityComparer<K>; capacity: integer = 0); overload;
    destructor  Destroy; override;
    function  Lock(const key: K; timeout_ms: cardinal): boolean;
    function  LockUnlock(const key: K; timeout_ms: cardinal): IOmniLockManagerAutoUnlock;
    procedure Unlock(const key: K);
  end; { TOmniLockManager<K> }

  ///<summary>Waits on any/all from any number of synchro objects such as Events
  ///  and CountDownEvents. Uses condition variables internally for cross-platform
  ///  compatibility. On Windows, also supports THandle-based construction and
  ///  MsgWaitAny for message loop integration.</summary>
  TWaitFor = class
  public type
    TWaitForResult = (
      waAwaited,      // WAIT_OBJECT_0 .. WAIT_OBJECT_n
      waTimeout,      // WAIT_TIMEOUT
      waFailed,       // WAIT_FAILED
      waIOCompletion, // WAIT_IO_COMPLETION
      waMessage       // message or wake event (WAIT_OBJECT_n+1)
    );
    THandleInfo = record
      Index: integer;
    end;
    THandles = array of THandleInfo;
    {$IFDEF MSWINDOWS}
    THandleArr = array of THandle;
    {$ENDIF MSWINDOWS}
  strict private type
    TSynchroList = class(TList<IOmniSynchro>) end;
    ISynchroClientEx = interface ['{A4D963B3-88CD-466A-9885-3C66E605E32E}']
      procedure Deref;
    end; { ISynchroClientEx }
    TSynchroClient = class(TInterfacedObject, IOmniSynchroObserver, ISynchroClientEx)
    strict private
      FController  : TWaitFor;
      FAcquiredGate: IOmniCriticalSection;
      procedure EnterGate;
      procedure LeaveGate;
      procedure GetGate(out gate: IOmniCriticalSection);
      procedure DereferenceSynchObj(const SynchObj: TObject; AllowInterface: boolean);
      procedure BeforeSignal(const Signaller: TObject; var Data: TObject);
      procedure AfterSignal(const Signaller: TObject; var Data: TObject);
      procedure Deref;
    public
      constructor Create(AController: TWaitFor);
    end; { TSynchroClient }
  protected type
    TCondition = class
    protected
      FCondVar   : TConditionVariableCS;
      FController: TWaitFor;
      {$IFDEF MSWINDOWS}
      // Fast path: if every synch object exposes a kernel HANDLE, wait with
      // WaitForMultipleObjects and skip the observer/CV machinery. Returns
      // true when the fast path handled the wait.
      function  TryKernelFastPath(timeout_ms: cardinal;
                  var Signaller: IOmniSynchro; out waitResult: TWaitResult): boolean;
      // Large-set fallback for > 64 kernel handles. Uses
      // RegisterWaitForSingleObject so externally-signalled raw HANDLE
      // events (which don't drive OTL's observer chain) still wake the
      // caller. Returns true when the fallback handled the wait.
      function  TryKernelLargeSet(timeout_ms: cardinal;
                  var Signaller: IOmniSynchro; out waitResult: TWaitResult): boolean;
      {$ENDIF MSWINDOWS}
    public
      constructor Create(AController: TWaitFor);
      destructor  Destroy; override;
      function  Wait(timeout_ms: cardinal; var Signaller: IOmniSynchro): TWaitResult;
      function  Test(var Signaller: IOmniSynchro): boolean; virtual; abstract;
    end;
  strict private
    FAllSignalled    : TCondition;
    FGate            : IOmniCriticalSection;
    FOneSignalled    : TCondition;
    FSignalledCount  : integer;
    FSignalledHandles: THandles;
    FSynchObjects    : TSynchroList;
    FSynchClient     : IOmniSynchroObserver;
  strict protected
    {$IFDEF MSWINDOWS}
    function  GetWaitHandles: THandleArr;
    {$ENDIF MSWINDOWS}
  protected
    function  MapResult(waitResult: TWaitResult): TWaitForResult;
    procedure PopulateSignalled(const signaller: IOmniSynchro; waitAll: boolean);
    procedure RecomputeSignalledCount;
    property Gate: IOmniCriticalSection read FGate;
    property SignalledCount: integer read FSignalledCount;
    property SynchClient: IOmniSynchroObserver read FSynchClient;
    property SynchObjects: TSynchroList read FSynchObjects;
  public
    constructor Create(const synchObjects: array of IOmniSynchro; const AShareLock: IOmniCriticalSection = nil); overload;
    constructor Create; overload;
    {$IFDEF MSWINDOWS}
    constructor Create(const handles: array of THandle); overload;
    {$ENDIF MSWINDOWS}
    destructor  Destroy; override;
    procedure SetSynchObjects(const synchObjects: array of IOmniSynchro);
    {$IFDEF MSWINDOWS}
    function  MsgWaitAny(timeout_ms, wakeMask, flags: cardinal): TWaitForResult;
    procedure SetHandles(const handles: array of THandle);
    {$ENDIF MSWINDOWS}
    function  WaitAll(timeout_ms: cardinal): TWaitForResult; overload; inline;
    function  WaitAll(timeout_ms: cardinal; var Signaller: IOmniSynchro): TWaitForResult; overload;
    function  WaitAny(timeout_ms: cardinal): TWaitForResult; overload; inline;
    function  WaitAny(timeout_ms: cardinal; var Signaller: IOmniSynchro): TWaitForResult; overload;
    property Signalled: THandles read FSignalledHandles;
    {$IFDEF MSWINDOWS}
    property WaitHandles: THandleArr read GetWaitHandles;
    {$ENDIF MSWINDOWS}
  end; { TWaitFor }

  TOmniSingleThreadUseChecker = record
  private
    FLock    : TOmniCS;
    FThreadID: TThreadID;
  public
    procedure AttachToCurrentThread; inline;
    procedure Check; inline;
    procedure DebugCheck; inline;
  end; { TOmniSingleThreadUseChecker }

  // Compatibility layer for interlocked operations.
  TInterlockedEx = class
  public
    class function Add(var Target: NativeInt; Increment: NativeInt): NativeInt; overload; static; inline;
    class function CAS(const oldValue, newValue: NativeInt; var destination): boolean; overload; static; inline;
    class function CAS(const oldValue, newValue: pointer; var destination): boolean; overload; static; inline;
    class function CompareExchange(var Target: NativeInt; Value: NativeInt; Comparand: NativeInt): NativeInt; static; inline;
  end; { TInterlockedEx }

function CreateOmniCriticalSection: IOmniCriticalSection;
function CreateOmniCancellationToken: IOmniCancellationToken;
function CreateResourceCount(initialCount: integer): IOmniResourceCount;

function CreateOmniCountdownEvent(Count: Integer; SpinCount: Integer; const AShareLock: IOmniCriticalSection = nil): IOmniCountdownEvent;
function CreateOmniEvent(AManualReset, InitialState: boolean; const AShareLock: IOmniCriticalSection = nil): IOmniEvent; overload;
{$IFDEF MSWINDOWS}
function CreateOmniEvent(AExternalEvent: THandle; ATakeOwnership: boolean = false): IOmniEvent; overload;
{$ENDIF MSWINDOWS}

procedure NInterlockedExchangeAdd(var addend; value: NativeInt);
procedure MFence; inline;

function CAS8(const oldValue, newValue: byte; var destination): boolean;
function CAS16(const oldValue, newValue: word; var destination): boolean;
function CAS32(const oldValue, newValue: cardinal; var destination): boolean; overload;
{$IFNDEF CPUX64}
function CAS32(const oldValue: pointer; newValue: pointer; var destination): boolean; overload;
{$ENDIF ~CPUX64}
function CAS64(const oldData, newData: int64; var destination): boolean; overload;

function CAS(const oldValue, newValue: NativeInt; var destination): boolean; overload;
function CAS(const oldValue, newValue: pointer; var destination): boolean; overload;
function CAS(const oldData: pointer; oldReference: NativeInt; newData: pointer;
  newReference: NativeInt; var destination): boolean; overload;

{$IFNDEF CPUX64}
procedure Move64(var Source, Destination); overload;
procedure Move64(newData: pointer; newReference: cardinal; var Destination); overload;
{$ENDIF ~CPUX64}

procedure Move128(var Source, Destination);
procedure MoveDPtr(var Source, Destination); overload;
procedure MoveDPtr(newData: pointer; newReference: NativeInt; var Destination); overload;

{$IFDEF MSWINDOWS}
///<summary>Waits on any number of handles.</summary>
///<returns>True on success, False on timeout.</returns>
function WaitForAllObjects(const handles: array of THandle; timeout_ms: cardinal): boolean;
{$ENDIF MSWINDOWS}

function GetCPUTimeStamp: int64;

function SetEvent(event: IOmniEvent): boolean;

var
  GOmniCancellationToken: IOmniCancellationToken;
  CASAlignment: integer; //required alignment for the CAS function - 8 or 16, depending on the platform

implementation

uses
  OtlPlatform;

type
  {$IFDEF CPUX64}
  TInt128 = record
    Lo: int64;
    Hi: int64;
  end;
  {$ENDIF CPUX64}

  TOmniCriticalSection = class(TInterfacedObject, IOmniCriticalSection)
  strict private
    ocsCritSect : TSynchroObject;
    ocsLockCount: integer;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure Acquire; inline;
    function  GetLockCount: integer;
    function  GetSyncObj: TSynchroObject;
    procedure Release; inline;
  end; { TOmniCriticalSection }

  TOmniCancellationToken = class(TInterfacedObject, IOmniCancellationToken)
  private
    FEvent: IOmniEvent;
  protected
    function  GetEvent: IOmniEvent; inline;
    {$IFDEF MSWINDOWS}
    function  GetHandle: THandle; inline;
    {$ENDIF MSWINDOWS}
  public
    constructor Create;
    procedure Clear; inline;
    function  IsSignalled: boolean; inline;
    procedure Signal; inline;
    property Event: IOmniEvent read GetEvent;
    {$IFDEF MSWINDOWS}
    property Handle: THandle read GetHandle;
    {$ENDIF MSWINDOWS}
  end; { TOmniCancellationToken }

  TOmniSynchroObject = class abstract(TSynchroObject, IInterface, IOmniSynchro)
  private
    procedure PerformObservableAction(Action: TProc; DoLock: boolean);
    function  Base: TSynchroObject;
    {$IFDEF MSWINDOWS}
    function  Handle: THandle;
    function  HasKernelHandle: boolean;
    procedure AckKernelConsumed; virtual;
    {$ENDIF}
  strict protected
    FBase     : TSynchroObject;
    FOwnsBase : boolean;
    FLock     : TSpinLock;
    FObservers: TList<IOmniSynchroObserver>;
    FData     : TArray<TObject>;
    [Volatile]
    FRefCount : integer;
    FShareLock: IOmniCriticalSection;
  private
    function QueryInterface(const IID: TGUID; out Obj): HResult; stdcall;
    function _AddRef: Integer; stdcall;
    function _Release: Integer; stdcall;
  protected
    property Lock: TSpinLock read FLock;
    property ShareLock: IOmniCriticalSection read FShareLock;
  public
    procedure AfterConstruction; override;
    class function NewInstance: TObject; override;
  public
    constructor Create(ABase: TSynchroObject; OwnsIt: boolean; const AShareLock: IOmniCriticalSection = nil);
    destructor  Destroy; override;
    function  EnterSpinLock: IInterface;
    procedure Acquire; override;
    procedure Release; override;
    procedure Signal; virtual;
    function  WaitFor(timeout: cardinal = INFINITE): TWaitResult; override;
    procedure ConsumeSignalFromObserver(const Observer: IOmniSynchroObserver); virtual; abstract;
    function  IsSignalled: boolean; virtual; abstract;
    procedure AddObserver(const Observer: IOmniSynchroObserver);
    procedure RemoveObserver(const Observer: IOmniSynchroObserver);
  end; { TOmniSynchroObject }

  TSynchroSpin = class(TInterfacedObject)
  private
    FController: TOmniSynchroObject;
  public
    constructor Create(AController: TOmniSynchroObject);
    destructor Destroy; override;
  end; { TSynchroSpin }

  TOmniCountdownEvent = class(TOmniSynchroObject, IOmniCountdownEvent)
  strict protected
    FCountdown: TCountdownEvent;
  public
    constructor Create(Count: Integer; SpinCount: Integer; const AShareLock: IOmniCriticalSection = nil);
    procedure Reset;
    procedure ConsumeSignalFromObserver(const Observer: IOmniSynchroObserver);  override;
    function  IsSignalled: boolean; override;
    function  BaseCountdown: TCountdownEvent;
  end; { TOmniCountdownEvent }

  {$IFDEF MSWINDOWS}
  TOmniWrappedEvent = class(TEvent)
  // NOTE: the FHandle we mutate here is THandleObject.FHandle (protected in the
  // parent). Declaring our own FHandle in this class would SHADOW the parent's,
  // causing TEvent/THandleObject methods (SetEvent, ResetEvent, WaitFor, Handle)
  // to keep operating on the internally-created event while we stored the caller's
  // handle in the shadow field — so external SetEvent/WaitFor would see two
  // different kernel objects.
  strict private
    FIsOwner: boolean;
  public
    constructor Create(AExternalEvent: THandle; ATakeOwnership: boolean = false);
    destructor Destroy; override;
  end; { TOmniWrappedEvent }
  {$ENDIF MSWINDOWS}

  TOmniEvent = class(TOmniSynchroObject, IOmniEvent)
  strict protected
    FEvent      : TEvent;
    FManualReset: boolean;
    [Volatile]
    FState      : boolean;
  public
    constructor Create(AManualReset, InitialState: boolean; const AShareLock: IOmniCriticalSection = nil); overload;
    {$IFDEF MSWINDOWS}
    constructor Create(AExternalEvent: THandle; ATakeOwnership: boolean = false; AManualReset: boolean = false); overload;
    {$ENDIF MSWINDOWS}
    procedure Reset;
    procedure Signal; override;
    procedure SetEvent;
    function  BaseEvent: TEvent;
    procedure ConsumeSignalFromObserver(const Observer: IOmniSynchroObserver);  override;
    function  WaitFor(timeout: cardinal = INFINITE): TWaitResult; override;
    function  IsSignalled: boolean; override;
    {$IFDEF MSWINDOWS}
    procedure AckKernelConsumed; override;
    {$ENDIF}
  end; { TOmniEvent }

  TOneCondition = class(TWaitFor.TCondition)
  public
    function  Test(var Signaller: IOmniSynchro): boolean; override;
  end; { TOneCondition }

  TAllCondition = class(TWaitFor.TCondition)
  public
    function  Test(var Signaller: IOmniSynchro): boolean; override;
  end; { TAllCondition }

  TPreSignalData = class
  public
    OneSignalled: boolean;
    AllSignalled: boolean;
    constructor Create(AOneSignalled, AAllSignalled: boolean);
  end; { TPreSignalData }

var
  GOmniCSInitializer: TOmniCriticalSection;

{$IF (not Defined(MSWINDOWS)) and Defined(CPUX64)}
// Temporary non-Windows x86_64 fallback for the Windows API InterlockedCompareExchange128.
// dcclinux64 does not support inline ASM, so we cannot emit CMPXCHG16B directly. This
// coarse global-spinlock implementation is *not* lock-free — it defeats the point of
// the OTL lock-free containers — but it preserves correctness and unblocks compilation
// and smoke-testing under WSL2.
// TODO: replace the TInt128-based atomics with a cross-platform design; CMPXCHG16B does
// not exist on ARM64/Android either, so the callers need redesign before those targets
// can work.
var
  GInterlockedCompareExchange128Lock: integer = 0;

function InterlockedCompareExchange128(Destination: Pointer;
  ExchangeHigh, ExchangeLow: int64; Comparand: Pointer): Boolean;
var
  dst: ^TInt128 absolute Destination;
  cmp: ^TInt128 absolute Comparand;
begin
  while TInterlocked.CompareExchange(GInterlockedCompareExchange128Lock, 1, 0) <> 0 do
    TThread.Yield;
  try
    if (dst^.Lo = cmp^.Lo) and (dst^.Hi = cmp^.Hi) then begin
      dst^.Lo := ExchangeLow;
      dst^.Hi := ExchangeHigh;
      Result := true;
    end
    else begin
      cmp^.Lo := dst^.Lo;
      cmp^.Hi := dst^.Hi;
      Result := false;
    end;
  finally TInterlocked.Exchange(GInterlockedCompareExchange128Lock, 0); end;
end; { InterlockedCompareExchange128 }
{$ENDIF}

{ transitional }

function SetEvent(event: IOmniEvent): boolean;
begin
  Result := true;
  if assigned(event) then
    event.SetEvent;
end; { SetEvent }

{ exports }

function CreateOmniCriticalSection: IOmniCriticalSection;
begin
  Result := TOmniCriticalSection.Create;
end; { CreateOmniCriticalSection }

function CreateOmniCancellationToken: IOmniCancellationToken;
begin
  Result := TOmniCancellationToken.Create;
end; { CreateOmniCancellationToken }

function CreateResourceCount(initialCount: integer): IOmniResourceCount;
begin
  Result := TOmniResourceCount.Create(initialCount);
end; { CreateResourceCount }

function CreateOmniCountdownEvent(Count: Integer; SpinCount: Integer; const AShareLock: IOmniCriticalSection = nil): IOmniCountdownEvent;
begin
  Result := TOmniCountdownEvent.Create(Count, SpinCount, AShareLock);
end; { CreateOmniCountdownEvent }

function CreateOmniEvent(AManualReset, InitialState: boolean; const AShareLock: IOmniCriticalSection = nil): IOmniEvent;
begin
  Result := TOmniEvent.Create(AManualReset, InitialState, AShareLock);
end; { CreateOmniEvent }

{$IFDEF MSWINDOWS}
function CreateOmniEvent(AExternalEvent: THandle; ATakeOwnership: boolean): IOmniEvent;
begin
  Result := TOmniEvent.Create(AExternalEvent, ATakeOwnership);
end; { CreateOmniEvent }
{$ENDIF MSWINDOWS}

{ Atomic compare-and-swap operations — pure Pascal, no inline assembly }

function CAS8(const oldValue, newValue: byte; var destination): boolean;
var
  alignedPtr: PInteger;
  offset    : integer;
  oldWord   : integer;
  newWord   : integer;
begin
  alignedPtr := PInteger(NativeUInt(@destination) and not NativeUInt(3));
  offset := integer(NativeUInt(@destination) and 3) * 8;
  repeat
    oldWord := alignedPtr^;
    if byte(oldWord shr offset) <> oldValue then
      Exit(false);
    newWord := (oldWord and not ($FF shl offset)) or (integer(newValue) shl offset);
    if TInterlocked.CompareExchange(alignedPtr^, newWord, oldWord) = oldWord then
      Exit(true);
  until false;
end; { CAS8 }

function CAS16(const oldValue, newValue: word; var destination): boolean;
var
  alignedPtr: PInteger;
  offset    : integer;
  oldWord   : integer;
  newWord   : integer;
begin
  Assert(NativeUInt(@destination) and 1 = 0, 'CAS16: destination must be 2-byte aligned');
  alignedPtr := PInteger(NativeUInt(@destination) and not NativeUInt(3));
  offset := integer(NativeUInt(@destination) and 3) * 8;
  repeat
    oldWord := alignedPtr^;
    if word(oldWord shr offset) <> oldValue then
      Exit(false);
    newWord := (oldWord and not ($FFFF shl offset)) or (integer(newValue) shl offset);
    if TInterlocked.CompareExchange(alignedPtr^, newWord, oldWord) = oldWord then
      Exit(true);
  until false;
end; { CAS16 }

function CAS32(const oldValue, newValue: cardinal; var destination): boolean; overload;
begin
  Result := TInterlocked.CompareExchange(integer(destination), integer(newValue), integer(oldValue)) = integer(oldValue);
end; { CAS32 }

{$IFNDEF CPUX64}
function CAS32(const oldValue: pointer; newValue: pointer; var destination): boolean; overload;
begin
  Result := TInterlocked.CompareExchange(integer(destination), integer(newValue), integer(oldValue)) = integer(oldValue);
end; { CAS32 }
{$ENDIF ~CPUX64}

function CAS64(const oldData, newData: int64; var destination): boolean; overload;
begin
  Result := TInterlocked.CompareExchange(int64(destination), newData, oldData) = oldData;
end; { CAS64 }

function CAS(const oldValue, newValue: NativeInt; var destination): boolean; overload;
begin
  {$IFDEF CPUX64}
  Result := TInterlocked.CompareExchange(int64(destination), int64(newValue), int64(oldValue)) = int64(oldValue);
  {$ELSE}
  Result := TInterlocked.CompareExchange(integer(destination), integer(newValue), integer(oldValue)) = integer(oldValue);
  {$ENDIF}
end; { CAS }

function CAS(const oldValue, newValue: pointer; var destination): boolean; overload;
begin
  {$IFDEF CPUX64}
  Result := TInterlocked.CompareExchange(int64(destination), int64(newValue), int64(oldValue)) = int64(oldValue);
  {$ELSE}
  Result := TInterlocked.CompareExchange(integer(destination), integer(newValue), integer(oldValue)) = integer(oldValue);
  {$ENDIF}
end; { CAS }

//Either 8-byte or 16-byte CAS, depending on the platform; destination must be properly aligned (8- or 16-byte)
function CAS(const oldData: pointer; oldReference: NativeInt; newData: pointer;
  newReference: NativeInt; var destination): boolean; overload;
{$IFNDEF CPUX64}
var
  oldPacked: int64;
  newPacked: int64;
begin
  Int64Rec(oldPacked).Lo := cardinal(oldData);
  Int64Rec(oldPacked).Hi := cardinal(oldReference);
  Int64Rec(newPacked).Lo := cardinal(newData);
  Int64Rec(newPacked).Hi := cardinal(newReference);
  Result := TInterlocked.CompareExchange(int64(destination), newPacked, oldPacked) = oldPacked;
end; { CAS }
{$ELSE CPUX64}
var
  comparand: TInt128;
begin
  comparand.Lo := int64(oldData);
  comparand.Hi := int64(oldReference);
  Result := InterlockedCompareExchange128(@destination, newReference, int64(newData), @comparand);
end; { CAS }
{$ENDIF ~CPUX64}

{ Atomic move operations — pure Pascal, no inline assembly }

{$IFNDEF CPUX64}
procedure Move64(var Source, Destination); overload;
//Move 8 bytes atomically from 8-byte aligned Source to Destination
var
  value: int64;
begin
  value := int64(Source);
  int64(Destination) := TInterlocked.Exchange(int64(Destination), value);
end; { Move64 }

procedure Move64(newData: pointer; newReference: cardinal; var Destination); overload;
//Move 8 bytes atomically into 8-byte aligned Destination
var
  packedVal: int64;
begin
  Int64Rec(packedVal).Lo := cardinal(newData);
  Int64Rec(packedVal).Hi := newReference;
  TInterlocked.Exchange(int64(Destination), packedVal);
end; { Move64 }
{$ENDIF ~CPUX64}

procedure Move128(var Source, Destination);
//Move 16 bytes atomically from Source to properly aligned Destination
{$IFNDEF CPUX64}
var
  value: int64;
begin
  value := int64(Source);
  TInterlocked.Exchange(int64(Destination), value);
end; { Move128 }
{$ELSE CPUX64}
var
  comparand: TInt128;
  newLo    : int64;
  newHi    : int64;
begin
  newLo := PInt64(@Source)^;
  newHi := PInt64(PByte(@Source) + 8)^;
  comparand.Lo := PInt64(@Destination)^;
  comparand.Hi := PInt64(PByte(@Destination) + 8)^;
  while not InterlockedCompareExchange128(@Destination, newHi, newLo, @comparand) do
    ; //retry — comparand is updated by InterlockedCompareExchange128 on failure
end; { Move128 }
{$ENDIF ~CPUX64}

//Either 8-byte or 16-byte atomic Move, depending on the platform; destination must be properly aligned (8- or 16-byte)
procedure MoveDPtr(newData: pointer; newReference: NativeInt; var Destination); overload;
{$IFNDEF CPUX64}
var
  packedVal: int64;
begin
  Int64Rec(packedVal).Lo := cardinal(newData);
  Int64Rec(packedVal).Hi := cardinal(newReference);
  TInterlocked.Exchange(int64(Destination), packedVal);
end; { MoveDPtr }
{$ELSE CPUX64}
var
  comparand: TInt128;
begin
  comparand.Lo := PInt64(@Destination)^;
  comparand.Hi := PInt64(PByte(@Destination) + 8)^;
  while not InterlockedCompareExchange128(@Destination, newReference, int64(newData), @comparand) do
    ; //retry — comparand is updated by InterlockedCompareExchange128 on failure
end; { MoveDPtr }
{$ENDIF ~CPUX64}

//Either 8-byte or 16-byte atomic Move, depending on the platform; destination must be properly aligned (8- or 16-byte)
procedure MoveDPtr(var Source, Destination);
{$IFNDEF CPUX64}
var
  value: int64;
begin
  value := int64(Source);
  TInterlocked.Exchange(int64(Destination), value);
end; { MoveDPtr }
{$ELSE CPUX64}
var
  comparand: TInt128;
  newLo    : int64;
  newHi    : int64;
begin
  newLo := PInt64(@Source)^;
  newHi := PInt64(PByte(@Source) + 8)^;
  comparand.Lo := PInt64(@Destination)^;
  comparand.Hi := PInt64(PByte(@Destination) + 8)^;
  while not InterlockedCompareExchange128(@Destination, newHi, newLo, @comparand) do
    ; //retry — comparand is updated by InterlockedCompareExchange128 on failure
end; { MoveDPtr }
{$ENDIF ~CPUX64}

function GetCPUTimeStamp: int64;
begin
  Result := TStopwatch.GetTimestamp;
end; { GetCPUTimeStamp }

procedure NInterlockedExchangeAdd(var addend; value: NativeInt);
begin
  TInterlockedEx.Add(NativeInt(addend), value);
end; { NInterlockedExchangeAdd }

procedure MFence;
begin
  MemoryBarrier;
end; { MFence }

{$IFDEF MSWINDOWS}
function WaitForAllObjects(const handles: array of THandle; timeout_ms: cardinal):
  boolean;
var
  waiter: TWaitFor;
begin
  waiter := TWaitFor.Create(handles);
  try
    Result := (waiter.WaitAll(timeout_ms) = waAwaited);
  finally FreeAndNil(waiter); end;
end; { WaitForAllObjects }
{$ENDIF MSWINDOWS}

{ TOmniCS }

procedure TOmniCS.Acquire;
begin
  Initialize;
  ocsSync.Acquire;
end; { TOmniCS.Acquire }

function TOmniCS.GetLockCount: integer;
begin
  Result := 0;
  if Assigned(ocsSync) then
    Result := ocsSync.LockCount;
end; { TOmniCS.GetLockCount }

function TOmniCS.GetSyncObj: TSynchroObject;
begin
  Initialize;
  Result := ocsSync.GetSyncObj;
end; { TOmniCS.GetSyncObj }

procedure TOmniCS.Initialize;
begin
  if not assigned(ocsSync) then begin
    GOmniCSInitializer.Acquire;
    try
      if not assigned(ocsSync) then
        ocsSync := CreateOmniCriticalSection;
    finally GOmniCSInitializer.Release; end;
  end;
end; { TOmniCS.Initialize }

procedure TOmniCS.Release;
begin
  ocsSync.Release;
end; { TOmniCS.Release }

{ TOmniCriticalSection }

constructor TOmniCriticalSection.Create;
begin
  inherited Create;
  ocsCritSect := TFixedCriticalSection.Create;
end; { TOmniCriticalSection.Create }

destructor TOmniCriticalSection.Destroy;
begin
  FreeAndNil(ocsCritSect);
  inherited;
end; { TOmniCriticalSection.Destroy }

procedure TOmniCriticalSection.Acquire;
begin
  ocsCritSect.Acquire;
  Inc(ocsLockCount);
end; { TOmniCriticalSection.Acquire }

function TOmniCriticalSection.GetLockCount: integer;
begin
  Result := ocsLockCount;
end; { TOmniCriticalSection.GetLockCount }

function TOmniCriticalSection.GetSyncObj: TSynchroObject;
begin
  Result := ocsCritSect;
end; { TOmniCriticalSection.GetSyncObj }

procedure TOmniCriticalSection.Release;
begin
  Dec(ocsLockCount);
  ocsCritSect.Release;
end; { TOmniCriticalSection.Release }

{ TOmniCancellationToken }

constructor TOmniCancellationToken.Create;
begin
  FEvent := CreateOmniEvent(true, false);
end; { TOmniCancellationToken.Create }

procedure TOmniCancellationToken.Clear;
begin
  FEvent.Reset;
end; { TOmniCancellationToken.Clear }

function TOmniCancellationToken.GetEvent: IOmniEvent;
begin
  Result := FEvent;
end; { TOmniCancellationToken.GetEvent }

{$IFDEF MSWINDOWS}
function TOmniCancellationToken.GetHandle: THandle;
begin
  Result := (FEvent as IOmniSynchro).Handle;
end; { TOmniCancellationToken.GetHandle }
{$ENDIF MSWINDOWS}

function TOmniCancellationToken.IsSignalled: boolean;
begin
  Result := FEvent.IsSignalled;
end; { TOmniCancellationToken.IsSignalled }

procedure TOmniCancellationToken.Signal;
begin
  FEvent.Signal;
end; { TOmniCancellationToken.Signal }

{ TOmniMREW }

procedure TOmniMREW.EnterReadLock;
var
  currentReference: NativeInt;
  spinCount       : integer;
begin
  //Wait on writer to reset write flag so Reference.Bit0 must be 0 than increase Reference
  spinCount := 0;
  repeat
    currentReference := NativeInt(omrewReference) AND NOT 1;
    if not TInterlockedEx.CAS(currentReference, currentReference + 2, NativeInt(omrewReference)) then begin
      TThread.SpinWait(spinCount);
      if spinCount < 20 then
        Inc(spinCount);
    end
    else
      break; //repeat
  until false;
end; { TOmniMREW.EnterReadLock }

procedure TOmniMREW.EnterWriteLock;
var
  currentReference: NativeInt;
  spinCount       : integer;
begin
  //Wait on writer to reset write flag so omrewReference.Bit0 must be 0 then set omrewReference.Bit0
  spinCount := 0;
  repeat
    currentReference := NativeInt(omrewReference) AND NOT 1;
    if not TInterlockedEx.CAS(currentReference, currentReference + 1, NativeInt(omrewReference)) then begin
      TThread.SpinWait(spinCount);
      if spinCount < 20 then
        Inc(spinCount);
    end
    else
      break; //repeat
  until false;
  //Now wait on all readers
  spinCount := 0;
  while NativeInt(omrewReference) <> 1 do begin
    TThread.SpinWait(spinCount);
    if spinCount < 20 then
      Inc(spinCount);
  end;
end; { TOmniMREW.EnterWriteLock }

procedure TOmniMREW.ExitReadLock;
begin
  //Decrease omrewReference
  TInterlockedEx.Add(NativeInt(omrewReference), -2);
end; { TOmniMREW.ExitReadLock }

procedure TOmniMREW.ExitWriteLock;
begin
{$IFDEF CPU64BITS}
  TInterlocked.Exchange(int64(omrewReference), int64(0));
{$ELSE}
  TInterlocked.Exchange(integer(omrewReference), integer(0));
{$ENDIF}
end; { TOmniMREW.ExitWriteLock }

function TOmniMREW.TryEnterReadLock(timeout_ms: integer): boolean;
var
  currentReference: NativeInt;
  startWait_ms    : int64;

  function Timeout(var gotLock: boolean): boolean;
  begin
    Result := Time.HasElapsed(startWait_ms, timeout_ms);
    if Result then
      gotLock := false;
  end; { Timeout }

begin
  Result := true;
  startWait_ms := Time.Timestamp_ms;
  //Wait on writer to reset write flag so Reference.Bit0 must be 0 than increase Reference
  repeat
    currentReference := NativeInt(omrewReference) AND NOT 1;
  until TInterlockedEx.CAS(currentReference, currentReference + 2, NativeInt(omrewReference))
        or Timeout(Result);
end; { TOmniMREW.TryEnterReadLock }

function TOmniMREW.TryEnterWriteLock(timeout_ms: integer): boolean;
var
  currentReference: NativeInt;
  startWait_ms    : int64;

  function Timeout(var gotLock: boolean): boolean;
  begin
    Result := Time.HasElapsed(startWait_ms, timeout_ms);
    if Result then
      gotLock := false;
  end; { Timeout }

begin
  Result := true;
  startWait_ms := Time.Timestamp_ms;

  //Wait on writer to reset write flag so omrewReference.Bit0 must be 0 then set omrewReference.Bit0
  repeat
    currentReference := NativeInt(omrewReference) AND NOT 1;
  until TInterlockedEx.CAS(currentReference, currentReference + 1, NativeInt(omrewReference))
        or Timeout(Result);
  if Result then begin
    //Now wait on all readers
    repeat
    until (NativeInt(omrewReference) = 1) or Timeout(Result);
    if not Result then
      //Clear the write flag
      repeat
        currentReference := NativeInt(omrewReference);
      until TinterlockedEx.CAS(currentReference,  currentReference AND NOT 1, NativeInt(omrewReference));
  end;
end; { TOmniMREW.TryEnterWriteLock }

{ TOmniResourceCount }

constructor TOmniResourceCount.Create(initialCount: cardinal);
begin
  inherited Create;
  orcZero := CreateOmniEvent(true, (initialCount = 0));
  orcAvailable := CreateOmniEvent(true, (initialCount <> 0));
  orcNumResources.Value := initialCount;
end; { TOmniResourceCount.Create }

///<summary>Allocates resource and returns number of remaining resources.
///  If the initial number of resources is 0, then the call will block until a resource
///  becomes available.
///  If there are no remaining resources (Result is 0), sets externally visible event.
///</summary>
function TOmniResourceCount.Allocate: cardinal;
begin
  TryAllocate(Result, INFINITE);
end; { TOmniResourceCount.Allocate }

{$IFDEF MSWINDOWS}
function TOmniResourceCount.GetHandle: THandle;
begin
  Result := (orcZero as IOmniSynchro).Handle;
end; { TOmniResourceCount.GetHandle }
{$ENDIF MSWINDOWS}

function TOmniResourceCount.GetSynchro: IOmniSynchro;
begin
  Result := orcZero as IOmniSynchro;
end; { TOmniResourceCount.GetSynchro }

///<summary>Releases resource and returns number of remaining resources.
///  Resets the externally visible event if necessary.
///</summary>
function TOmniResourceCount.Release: cardinal;
begin
  orcLock.Acquire;
  try
    Result := cardinal(orcNumResources.Increment);
    if Result = 1 then begin
      orcZero.Reset;
      orcAvailable.SetEvent;
    end;
  finally orcLock.Release; end;
end; { TOmniResourceCount.Release }

///<summary>Like Allocate, but with a timeout.</summary>
function TOmniResourceCount.TryAllocate(var resourceCount: cardinal;
  timeout_ms: cardinal): boolean;
var
  startTime_ms: int64;
  waitResult  : TWaitResult;
  waitTime_ms : int64;
begin
  Result := false;
  startTime_ms := Time.Timestamp_ms;
  orcLock.Acquire;
  repeat
    if orcNumResources.Value = 0 then begin
      orcLock.Release;
      if timeout_ms <= 0 then
        Exit;
      if timeout_ms = INFINITE then
        waitTime_ms := INFINITE
      else begin
        waitTime_ms := timeout_ms - Time.Elapsed_ms(startTime_ms);
        if waitTime_ms <= 0 then
          Exit;
      end;
      waitResult := orcAvailable.WaitFor(waitTime_ms);
      if waitResult <> wrSignaled then
        Exit; // skip final Release
      orcLock.Acquire;
    end;
    if orcNumResources.Value > 0 then begin
      Result := true;
      resourceCount := cardinal(orcNumResources.Decrement);
      if resourceCount = 0 then begin
        orcAvailable.Reset; //reset before release - otherwise there's a race condition between this code and .Release
        orcLock.Release; //prevent race condition - another thread may wait on orcZero and destroy this instance
        orcZero.SetEvent;
        Exit; // skip final Release
      end;
      break; //repeat
    end;
  until false;
  orcLock.Release;
end; { TOmniResourceCount.TryAllocate }

{ Atomic<T> }

class function Atomic<T>.Initialize(var storage: T; factory: TFactory): T;
var
  interlockRes: pointer;
  tmpT        : T;
begin
  if not assigned(PPointer(@storage)^) then begin
    Assert(NativeUInt(@storage) mod SizeOf(pointer) = 0, 'Atomic<T>.Initialize: storage is not properly aligned!');
    Assert(NativeUInt(@tmpT) mod SizeOf(pointer) = 0, 'Atomic<T>.Initialize: tmpT is not properly aligned!');
    tmpT := factory();
    interlockRes := TInterlocked.CompareExchange(PPointer(@storage)^, PPointer(@tmpT)^, nil);
    case PTypeInfo(TypeInfo(T))^.Kind of
      tkInterface:
        if interlockRes = nil then
          PPointer(@tmpT)^ := nil;
      tkClass:
        if interlockRes <> nil then
          TObject(PPointer(@tmpT)^).Free;
      else
        raise Exception.Create('Atomic<T>.Initialize: Unsupported type');
    end; //case
  end;
  Result := storage;
end; { Atomic<T>.Initialize }

class function Atomic<T>.Initialize(var storage: T): T;
var
  factory: TFactory;
begin
  if not assigned(PPointer(@storage)^) then begin
    if PTypeInfo(TypeInfo(T))^.Kind  <> tkClass then
      raise Exception.Create('Atomic<T>.Initialize: Unsupported type');
    factory :=
      function: T
      var
        aMethCreate : TRttiMethod;
        instanceType: TRttiInstanceType;
        ctx         : TRttiContext;
        resValue    : TValue;
        rType       : TRttiType;
      begin
        Result := Default(T);
        ctx := TRttiContext.Create;
        rType := ctx.GetType(TypeInfo(T));
        for aMethCreate in rType.GetMethods do begin
          if (aMethCreate.IsConstructor) and (Length(aMethCreate.GetParameters) = 0) then begin
            instanceType := rType.AsInstance;
            resValue := AMethCreate.Invoke(instanceType.MetaclassType, []);
            Result := resValue.AsType<T>;
            break; //for
          end;
        end; //for
      end;
    Result := Atomic<T>.Initialize(storage, factory);
  end
  else
    Result := storage;
end; { Atomic<T>.Initialize }

{ ATomic<I,T> }

class function Atomic<I,T>.Initialize(var storage: I): I;
var
  factory: Atomic<I>.TFactory;
begin
  factory :=
    function: I
    begin
      Result := TValue.From<T>(T.Create).AsType<I>;
    end;
  Result := Atomic<I>.Initialize(storage, factory);
end; { Atomic<I,T>.Initialize }

{ TLightweightMREWEx }

function TLightweightMREWEx.GetLockOwner: TThreadID; //inline
begin
  // No-op CompareExchange is portable: overloads exist for both Cardinal
  // (Windows TThreadID) and UInt64 (POSIX pthread_t). TInterlocked.Read
  // has neither Cardinal nor generic overload.
  Result := TInterlocked.CompareExchange(FLockOwner, TThreadID(0), TThreadID(0));
end; { TLightweightMREWEx.GetLockOwner }

procedure TLightweightMREWEx.SetLockOwner(value: TThreadID); //inline
begin
  TInterlocked.Exchange(FLockOwner, value);
end; { TLightweightMREWEx.SetLockOwner }

class operator TLightweightMREWEx.Initialize(out dest: TLightweightMREWEx);
begin
  Dest.SetLockOwner(0);
  Dest.FWriteLockCount.Value := 0;
end; { TLightweightMREWEx.Initialize }

procedure TLightweightMREWEx.BeginRead;
begin
  FRWLock.BeginRead;
end; { TLightweightMREWEx.BeginRead }

procedure TLightweightMREWEx.BeginWrite;
begin
  if GetLockOwner = TThread.Current.ThreadID then
    // We are already an owner so no need for locking.
    // If another thread executes BeginWrite at this moment, it would enter
    // the 'else' part below and block in the call to FRWLock.BeginWrite.
    FWriteLockCount.Increment
  else begin
    FRWLock.BeginWrite;
    SetLockOwner(TThread.Current.ThreadID);
    FWriteLockCount.Value := 1;
  end;
end; { TLightweightMREWEx.BeginWrite }

procedure TLightweightMREWEx.EndRead;
begin
  FRWLock.EndRead;
end; { TLightweightMREWEx.EndRead }

procedure TLightweightMREWEx.EndWrite;
begin
  if GetLockOwner <> TThread.Current.ThreadID then
    raise Exception.Create('Not an owner');

  if FWriteLockCount.Value <= 0 then
    raise Exception.Create('Attempting to release write lock that was not acquired');
  if FWriteLockCount.Decrement = 0 then begin
    SetLockOwner(0);
    FRWLock.EndWrite;
  end;
end; { TLightweightMREWEx.EndWrite }

function TLightweightMREWEx.TryBeginRead: boolean;
begin
  Result := FRWLock.TryBeginRead;
end; { TLightweightMREWEx.TryBeginRead }

{$IF defined(LINUX) or defined(ANDROID)}
function TLightweightMREWEx.TryBeginRead(timeout: cardinal): boolean;
begin
  Result := FRWLock.TryBeginRead(timeout);
end; { TLightweightMREWEx.TryBeginRead }
{$ENDIF LINUX or ANDROID}

function TLightweightMREWEx.TryBeginWrite: boolean;
begin
  if GetLockOwner = TThread.Current.ThreadID then begin
    FWriteLockCount.Increment;
    Result := true;
  end
  else begin
    Result := FRWLock.TryBeginWrite;
    if Result then begin
      SetLockOwner(TThread.Current.ThreadID);
      FWriteLockCount.Value := 1;
    end;
  end;
end; { TLightweightMREWEx.TryBeginWrite }

{$IF defined(LINUX) or defined(ANDROID)}
function TLightweightMREWEx.TryBeginWrite(timeout: cardinal): boolean;
begin
  if GetLockOwner = TThread.Current.ThreadID then begin
    FWriteLockCount.Increment;
    Result := true;
  end
  else begin
    Result := FRWLock.TryBeginWrite(timeout);
    if Result then begin
      SetLockOwner(TThread.Current.ThreadID);
      FWriteLockCount.Value := 1;
    end;
  end;
end; { TLightweightMREWEx.TryBeginWrite }
{$ENDIF LINUX or ANDROID}

{ Locked<T> }

procedure Locked<T>.Clear;
begin
  FLifecycle := nil;
  FInitialized := false;
  FValue := Default(T);
  FOwnsObject := false;
end; { Locked }

constructor Locked<T>.Create(const value: T; ownsObject: boolean);
begin
  FLock := TLightweightMREWExImpl.Create;
  {$IFDEF DEBUG}
  FLockCount := CreateCounter;
  {$ENDIF DEBUG}

  Clear;
  FValue := value;
  if ownsObject and (PTypeInfo(TypeInfo(T))^.Kind = tkClass) then
    FLifecycle := CreateAutoDestroyObject(TObject(PPointer(@value)^));

  FInitialized := true;
end; { Locked<T>.Create }

class operator Locked<T>.Implicit(const value: Locked<T>): T;
begin
  Result := value.Value;
end; { Locked<T>.Implicit }

class operator Locked<T>.Implicit(const value: T): Locked<T>;
begin
  Result := Locked<T>.Create(value);
end; { Locked<T>.Implicit }

procedure Locked<T>.Acquire;
begin
  FLock.BeginWrite;
  {$IFDEF DEBUG}
  FLockCount.Increment;
  {$ENDIF DEBUG}
end; { Locked<T>.Acquire }

procedure Locked<T>.AssertLocked;
begin
  // This is just a debugging helper. It catches most bad cases of accessing
  // Locked<T>.Value while Locked<T> is not locked. It may fail (not detect a problem)
  // in multithreading code where one thread may lock the Locked<T> and
  // then another thread tries to access Locked<T>.Value.
  {$IFDEF DEBUG}
  Assert(FLockCount.Value > 0, 'Locked<T> is not locked!');
  {$ENDIF DEBUG}
end; { Locked<T>.AssertLocked }

function Locked<T>.BeginRead: T;
begin
  FLock.BeginRead;
  {$IFDEF DEBUG}
  FLockCount.Increment;
  {$ENDIF DEBUG}
  Result := FValue;
end; { Locked<T>.BeginRead }

function Locked<T>.BeginWrite: T;
begin
  FLock.BeginWrite;
  {$IFDEF DEBUG}
  FLockCount.Increment;
  {$ENDIF DEBUG}
  Result := FValue;
end; { Locked<T>.BeginWrite }

procedure Locked<T>.EndRead;
begin
  FLock.EndRead;
  {$IFDEF DEBUG}
  FLockCount.Decrement;
  {$ENDIF DEBUG}
end; { Locked<T>.EndRead }

procedure Locked<T>.EndWrite;
begin
  FLock.EndWrite;
  {$IFDEF DEBUG}
  FLockCount.Decrement;
  {$ENDIF DEBUG}
end; { Locked<T>.EndWrite }

function Locked<T>.Enter: T;
begin
  Acquire;
  Result := FValue;
end; { Locked<T>.Enter }

procedure Locked<T>.Leave;
begin
  FLock.EndWrite;
  {$IFDEF DEBUG}
  FLockCount.Decrement;
  {$ENDIF DEBUG}
end; { Locked<T>.Leave }

procedure Locked<T>.Release;
begin
  Leave;
end; { Locked<T>.Release }

procedure Locked<T>.Free;
begin
  if FInitialized then begin
    Acquire;
    try
      if assigned(FLifecycle) then
        Clear
      else if FInitialized then begin
        if (PTypeInfo(TypeInfo(T))^.Kind = tkClass) then
          TObject(PPointer(@FValue)^).Free;
        Clear;
      end;
    finally Release; end;
  end;
end; { Locked<T>.Free }

function Locked<T>.GetValue: T;
begin
  AssertLocked;
  Result := FValue;
end; { Locked<T>.GetValue }

procedure Locked<T>.SetValue(const value: T);
begin
  AssertLocked;
  FValue := value;
end; { Locked<T>.SetValue }

function Locked<T>.Initialize(factory: TFactory): T;
var
  newLock: ILightweightMREWEx;
begin
  if not FInitialized then begin
    if not assigned(FLock) then begin
      newLock := TLightweightMREWExImpl.Create;
      if TInterlocked.CompareExchange(pointer(FLock), pointer(newLock), nil) = nil then begin
        newLock._AddRef; // FLock now owns the reference
        {$IFDEF DEBUG}
        FLockCount := CreateCounter;
        {$ENDIF DEBUG}
      end;
      // else another thread won the race; newLock is released automatically
    end;

    Acquire;
    try
      if not FInitialized then begin
        FValue := factory();
        MFence;
        FInitialized := true;
      end;
    finally Release; end;
  end;
  Result := FValue;
end; { Locked<T>.Initialize }

function Locked<T>.Initialize: T;
var
  factory: TFactory;
begin
  if not FInitialized then begin
    if PTypeInfo(TypeInfo(T))^.Kind  <> tkClass then
      raise Exception.Create('Locked<T>.Initialize: Unsupported type');
    factory :=
      function: T
      var
        aMethCreate : TRttiMethod;
        instanceType: TRttiInstanceType;
        ctx         : TRttiContext;
        params      : TArray<TRttiParameter>;
        resValue    : TValue;
        rType       : TRttiType;
      begin
        Result := Default(T);
        ctx := TRttiContext.Create;
        rType := ctx.GetType(TypeInfo(T));
        for aMethCreate in rType.GetMethods do begin
          if aMethCreate.IsConstructor then begin
            params := aMethCreate.GetParameters;
            if Length(params) = 0 then begin
              instanceType := rType.AsInstance;
              resValue := AMethCreate.Invoke(instanceType.MetaclassType, []);
              Result := resValue.AsType<T>;
              break; //for
            end;
          end;
        end; //for
      end;
    Result := Initialize(factory);
  end
  else
    Result := FValue;
end; { Locked<T>.Initialize }

procedure Locked<T>.Locked(proc: TProc);
begin
  Acquire;
  try
    proc;
  finally Release; end;
end; { Locked<T>.Locked }

procedure Locked<T>.Locked(proc: TProcT);
begin
  Acquire;
  try
    proc(Value);
  finally Release; end;
end; { Locked<T>.Locked }

function Locked<T>.TryBeginRead: boolean;
begin
  Result := FLock.TryBeginRead;
  {$IFDEF DEBUG}
  if Result then
    FLockCount.Increment;
  {$ENDIF DEBUG}
end; { Locked<T>.TryBeginRead}

function Locked<T>.TryBeginWrite: boolean;
begin
  Result := FLock.TryBeginWrite;
  {$IFDEF DEBUG}
  if Result then
    FLockCount.Increment;
  {$ENDIF DEBUG}
end; { Locked<T>.TryBeginWrite }

{$IF defined(LINUX) or defined(ANDROID)}
function Locked<T>.TryBeginRead(timeout: cardinal): boolean;
begin
  Result := FLock.TryBeginRead(timeout);
  {$IFDEF DEBUG}
  if Result then
    FLockCount.Increment;
  {$ENDIF DEBUG}
end; { Locked<T>.TryBeginRead }

function Locked<T>.TryBeginWrite(timeout: cardinal): boolean;
begin
  Result := FLock.TryBeginWrite(timeout);
  {$IFDEF DEBUG}
  if Result then
    FLockCount.Increment;
  {$ENDIF DEBUG}
end; { Locked<T>.TryBeginWrite }
{$ENDIF LINUX or ANDROID}

{ TOmniLockManager<K>.TNotifyPair<K> }

constructor TOmniLockManager<K>.TNotifyPair.Create(const aKey: K; aNotify: IOmniEvent);
begin
  inherited Create;
  Key := aKey;
  Notify := aNotify;
end; { TOmniLockManager<K>.TNotifyPair.Create }

{ TOmniLockManager<K>.TAutoUnlock }

constructor TOmniLockManager<K>.TAutoUnlock.Create(unlockProc: TProc);
begin
  inherited Create;
  FUnlockProc := unlockProc;
end; { TOmniLockManager<K>.TAutoUnlock.Create }

destructor TOmniLockManager<K>.TAutoUnlock.Destroy;
begin
  Unlock;
  inherited;
end; { TOmniLockManager<K>.TAutoUnlock.Destroy }

procedure TOmniLockManager<K>.TAutoUnlock.Unlock;
begin
  if assigned(FUnlockProc) then
    FUnlockProc;
  FUnlockProc := nil;
end; { TOmniLockManager<K>.TAutoUnlock.Unlock }

{ TOmniLockManager<K>.TLockValue }

constructor TOmniLockManager<K>.TLockValue.Create(aThreadID: TThreadID; aLockCount: integer);
begin
  ThreadID := aThreadID;
  LockCount := aLockCount;
end; { TOmniLockManager<K>.TLockValue }

{ TOmniLockManager<K> }

class function TOmniLockManager<K>.CreateInterface(comparer: IEqualityComparer<K>;
  capacity: integer): IOmniLockManager<K>;
begin
  Result := TOmniLockManager<K>.Create(comparer, capacity);
end; { TOmniLockManager<K>.CreateInterface }

class function TOmniLockManager<K>.CreateInterface(capacity: integer):
  IOmniLockManager<K>;
begin
  Result := TOmniLockManager<K>.Create(capacity);
end; { TOmniLockManager<K>.CreateInterface }

constructor TOmniLockManager<K>.Create(const comparer: IEqualityComparer<K>;
  capacity: integer);
begin
  inherited Create;
  FComparer := comparer;
  if not assigned(FComparer) then
    FComparer := TEqualityComparer<K>.Default;
  FLockList := TDictionary<K,TLockValue>.Create(capacity, FComparer);
  FNotifyList := TObjectList<TNotifyPair>.Create(true);
end; { TOmniLockManager }

constructor TOmniLockManager<K>.Create(capacity: integer);
begin
  Create(nil, capacity);
end; { TOmniLockManager }

destructor TOmniLockManager<K>.Destroy;
begin
  FreeAndNil(FLockList);
  FreeAndNil(FNotifyList);
  inherited;
end; { TOmniLockManager }

function TOmniLockManager<K>.Lock(const key: K; timeout_ms: cardinal): boolean;
var
  lockData  : TLockValue;
  startWait : int64;
  waitEvent : IOmniEvent;
  waitResult: TWaitResult;
  wait_ms   : integer;
begin
  Result := false;
  waitEvent := nil;
  startWait := Time.Timestamp_ms;

  repeat
    FLock.Acquire;
    try
      if not FLockList.TryGetValue(key, lockData) then begin
        // Unlocked
        FLockList.Add(key, TLockValue.Create(GetCurrentThreadID, 1));
        Result := true;
        break; //repeat
      end
      else if lockData.ThreadID = GetCurrentThreadID then begin
        // Already locked by this thread, increase the lock count
        Inc(lockData.LockCount);
        FLockList.AddOrSetValue(key, lockData);
        Result := true;
        break; //repeat
      end
      else if not assigned(waitEvent) then begin
        waitEvent := CreateOmniEvent(false, false);
        FNotifyList.Add(TNotifyPair.Create(key, waitEvent));
      end;
    finally FLock.Release; end;
    wait_ms := integer(timeout_ms) - integer(Time.Elapsed_ms(startWait));
    if (timeout_ms <> INFINITE) and (wait_ms <= 0) then
      break; //repeat
    waitResult := waitEvent.WaitFor(cardinal(wait_ms));
  until waitResult = wrTimeout;

  if assigned(waitEvent) then begin
    FLock.Acquire;
    try
      for var i := FNotifyList.Count - 1 downto 0 do
        if FNotifyList[i].Notify = waitEvent then begin
          FNotifyList.Delete(i);
          break; //for i
        end;
    finally FLock.Release; end;
  end;
end; { TOmniLockManager<K>.Lock }

function TOmniLockManager<K>.LockUnlock(const key: K; timeout_ms: cardinal): IOmniLockManagerAutoUnlock;
begin
  if not Lock(key, timeout_ms) then
    Result := nil
  else
    Result := TAutoUnlock.Create(
      procedure
      begin
        Unlock(key);
      end
    );
end; { TOmniLockManager<K>.LockUnlock }

procedure TOmniLockManager<K>.Unlock(const key: K);
var
  lockData: TLockValue;
begin
  FLock.Acquire;
  try
    if not FLockList.TryGetValue(key, lockData) then
      raise Exception.Create('TOmniLockManager<K>.Unlock: Key not locked');
    if lockData.ThreadID <> GetCurrentThreadID then
      raise Exception.Create('TOmniLockManager<K>.Unlock: Key was not locked by the current thread');
    if lockData.LockCount > 1 then begin
      Dec(lockData.LockCount);
      FLockList.AddOrSetValue(key, lockData);
    end
    else begin
      FLockList.Remove(key);
      for var i := 0 to FNotifyList.Count - 1 do
        if FComparer.Equals(FNotifyList[i].Key, key) then begin
          FNotifyList[i].Notify.SetEvent;
          break; //for i
        end;
    end;
  finally FLock.Release; end;
end; { TOmniLockManager<K>.Unlock }

{ TWaitFor.TSynchroClient }

constructor TWaitFor.TSynchroClient.Create(AController: TWaitFor);
begin
  FController := AController;
  FController.FSynchClient := Self;
end; { TWaitFor.TSynchroClient.Create }

procedure TWaitFor.TSynchroClient.EnterGate;
begin
  if assigned(FController) then begin
    FAcquiredGate := FController.FGate;
    FAcquiredGate.Acquire;
  end;
end; { TWaitFor.TSynchroClient.EnterGate }

procedure TWaitFor.TSynchroClient.LeaveGate;
begin
  if assigned(FAcquiredGate) then begin
    FAcquiredGate.Release;
    FAcquiredGate := nil;
  end;
end; { TWaitFor.TSynchroClient.LeaveGate }

procedure TWaitFor.TSynchroClient.GetGate(out gate: IOmniCriticalSection);
begin
  gate := FAcquiredGate;
end; { TWaitFor.TSynchroClient.GetGate }

procedure TWaitFor.TSynchroClient.Deref;
begin
  FController := nil;
end; { TWaitFor.TSynchroClient.Deref }

procedure TWaitFor.TSynchroClient.DereferenceSynchObj(const SynchObj: TObject;
  AllowInterface: boolean);
begin
  if not assigned(FController) then
    Exit;
end; { TWaitFor.TSynchroClient.DereferenceSynchObj }

procedure TWaitFor.TSynchroClient.BeforeSignal(const Signaller: TObject; var Data: TObject);
var
  synch: IOmniSynchro;
begin
  // Snapshot only the signaller's pre-state; AfterSignal compares with the
  // post-state to detect a transition and updates FSignalledCount O(1)
  // instead of scanning FSynchObjects via Test on every signal.
  // OneSignalled field is reused to carry the signaller's pre-state.
  if assigned(FController) and Supports(Signaller, IOmniSynchro, synch) then
    Data := TPreSignalData.Create(synch.IsSignalled, false);
end; { TWaitFor.TSynchroClient.BeforeSignal }

procedure TWaitFor.TSynchroClient.AfterSignal(const Signaller: TObject; var Data: TObject);
var
  newCount  : integer;
  postState : boolean;
  preState  : boolean;
  synch     : IOmniSynchro;
begin
  try
    if not assigned(FController) then
      Exit;
    if not assigned(Data) then
      Exit;
    if not Supports(Signaller, IOmniSynchro, synch) then
      Exit;
    preState  := TPreSignalData(Data).OneSignalled;
    postState := synch.IsSignalled;
    if preState = postState then
      Exit;
    if postState then
      newCount := TInterlocked.Increment(FController.FSignalledCount)
    else
      newCount := TInterlocked.Decrement(FController.FSignalledCount);
    // False→true transition on the signaller brings the total from
    // newCount-1 to newCount. If newCount = 1 the waiter's FOneSignalled
    // just transitioned from "none signalled" to "some signalled" — wake.
    if postState and (newCount = 1) then
      FController.FOneSignalled.FCondVar.Release;
    // FAllSignalled transitions to signalled only when every synch
    // object is signalled at once.
    if postState and (newCount = FController.FSynchObjects.Count) then
      FController.FAllSignalled.FCondVar.Release;
  finally FreeAndNil(Data); end;
end; { TWaitFor.TSynchroClient.AfterSignal }

{ TWaitFor.TCondition }

constructor TWaitFor.TCondition.Create(AController: TWaitFor);
begin
  inherited Create;
  FCondVar := TConditionVariableCS.Create;
  FController := AController;
end; { TWaitFor.TCondition.Create }

destructor TWaitFor.TCondition.Destroy;
begin
  FreeAndNil(FCondVar);
  inherited;
end; { TWaitFor.TCondition.Destroy }

{$IFDEF MSWINDOWS}
function TWaitFor.TCondition.TryKernelFastPath(timeout_ms: cardinal;
  var Signaller: IOmniSynchro; out waitResult: TWaitResult): boolean;
var
  count      : integer;
  handles    : TArray<THandle>;
  i, idx     : integer;
  idxToSynch : TArray<IOmniSynchro>;
  so         : IOmniSynchro;
  waitAll    : BOOL;
  waitRes    : DWORD;
begin
  Result := false;
  waitResult := wrError;

  // Snapshot under FGate so SynchObjects cannot mutate mid-scan.
  FController.FGate.Acquire;
  try
    count := FController.SynchObjects.Count;
    if (count = 0) or (count > MAXIMUM_WAIT_OBJECTS) then
      Exit;
    SetLength(handles, count);
    SetLength(idxToSynch, count);
    count := 0;
    for so in FController.SynchObjects do begin
      if not assigned(so) then continue;
      if not so.HasKernelHandle then Exit; // fall back to slow path
      idxToSynch[count] := so;
      handles[count]    := so.Handle;
      Inc(count);
    end;
    if count = 0 then Exit;
  finally FController.FGate.Release; end;

  SetLength(handles, count);
  SetLength(idxToSynch, count);

  waitAll := Self is TAllCondition;
  waitRes := WaitForMultipleObjects(DWORD(count), @handles[0], waitAll, timeout_ms);

  case waitRes of
    WAIT_TIMEOUT:
      waitResult := wrTimeout;
    WAIT_FAILED:
      waitResult := wrError;
  else
    if waitAll then begin
      if waitRes = WAIT_OBJECT_0 then begin
        waitResult := wrSignaled;
        // Kernel already auto-reset; just sync the shadow state.
        for i := 0 to count - 1 do
          idxToSynch[i].AckKernelConsumed;
        Signaller := idxToSynch[0];
      end
      else
        waitResult := wrError;
    end
    else begin
      if waitRes < WAIT_OBJECT_0 + DWORD(count) then begin
        idx := integer(waitRes - WAIT_OBJECT_0);
        waitResult := wrSignaled;
        idxToSynch[idx].AckKernelConsumed;
        Signaller := idxToSynch[idx];
      end
      else
        waitResult := wrError;
    end;
  end;
  Result := true;
end; { TWaitFor.TCondition.TryKernelFastPath }

type
  PLargeSetWaiter = ^TLargeSetWaiter;
  TLargeSetWaiter = record
    Index    : integer;    // position in SynchObjects
    Signalled: integer;    // 0/1, interlocked
    IdxSlot  : ^integer;   // WaitAny: shared "who signalled first"
    Counter  : IOmniResourceCount; // WaitAll: decremented on each fire
    SignalOK : ^THandle;   // manual-reset event the waiter signals on fire
  end;

procedure _LargeSetWaitCallback(Context: Pointer; TimerOrWaitFired: Boolean); stdcall;
// TWaitOrTimerCallback per MSDN: TimerOrWaitFired is TRUE when the timer
// expired (we pass INFINITE so that path won't fire) and FALSE when the
// waited event was signaled. Delphi's Winapi.Windows declaration names
// this parameter "Success" which is misleading — do NOT early-exit on
// "Success=False" — that's the signalled case we actually want.
var
  w: PLargeSetWaiter absolute Context;
begin
  if TimerOrWaitFired then Exit;
  if TInterlocked.CompareExchange(w.Signalled, 1, 0) <> 0 then
    Exit; // already counted this handle
  if assigned(w.Counter) then begin
    // WaitAll: decrement the shared counter; its Handle auto-signals at 0.
    w.Counter.Allocate;
  end
  else if assigned(w.IdxSlot) then begin
    // WaitAny: publish index to the first-writer slot, then signal.
    TInterlocked.CompareExchange(w.IdxSlot^, w.Index, -1);
    if assigned(w.SignalOK) then
      Winapi.Windows.SetEvent(w.SignalOK^);
  end;
end;

function TWaitFor.TCondition.TryKernelLargeSet(timeout_ms: cardinal;
  var Signaller: IOmniSynchro; out waitResult: TWaitResult): boolean;
// Port of the OTL v3 approach used when the handle count exceeds
// WaitForMultipleObjects' 64-handle limit. Each handle is registered
// with RegisterWaitForSingleObject; callbacks publish either into a
// shared "first-signalled index" slot (WaitAny) or into a resource
// count whose handle signals at zero (WaitAll). This path is what
// makes TWaitFor.Create(array of THandle) still work for > 64 raw
// handles signalled externally via Windows.SetEvent — those never
// drive OTL's observer chain, so the generic CV/observer slow path
// would never wake.
var
  count      : integer;
  handles    : TArray<THandle>;
  i          : integer;
  idxSlot    : integer;
  idxToSynch : TArray<IOmniSynchro>;
  pCounterH  : THandle;
  resCount   : IOmniResourceCount;
  signalEvent: THandle;
  so         : IOmniSynchro;
  waitAll    : boolean;
  waiters    : TArray<TLargeSetWaiter>;
  waitHandles: TArray<THandle>;
  waitRes    : DWORD;
begin
  Result := false;
  waitResult := wrError;
  waitAll := Self is TAllCondition;
  signalEvent := 0;
  resCount := nil;

  FController.FGate.Acquire;
  try
    count := FController.SynchObjects.Count;
    if count <= MAXIMUM_WAIT_OBJECTS then Exit; // fast path handles these
    SetLength(handles, count);
    SetLength(idxToSynch, count);
    count := 0;
    for so in FController.SynchObjects do begin
      if not assigned(so) then continue;
      if not so.HasKernelHandle then Exit; // fall through to observer slow path
      idxToSynch[count] := so;
      handles[count]    := so.Handle;
      Inc(count);
    end;
    if count = 0 then Exit;
  finally FController.FGate.Release; end;

  SetLength(handles, count);
  SetLength(idxToSynch, count);
  SetLength(waiters, count);
  SetLength(waitHandles, count);

  idxSlot := -1;
  if waitAll then begin
    resCount := CreateResourceCount(count); // signals when allocation count hits 0
    pCounterH := resCount.Handle;
  end
  else begin
    signalEvent := Winapi.Windows.CreateEvent(nil, True, False, nil); // manual reset
    if signalEvent = 0 then Exit;
    pCounterH := signalEvent;
  end;

  try
    // Register a waiter per handle. Each fires once and decrements the
    // resource count (WaitAll) or publishes its index + signals the event
    // (WaitAny).
    for i := 0 to count - 1 do begin
      waiters[i].Index := i;
      waiters[i].Signalled := 0;
      if waitAll then begin
        waiters[i].Counter := resCount;
      end
      else begin
        waiters[i].IdxSlot := @idxSlot;
        waiters[i].SignalOK := @signalEvent;
      end;
      if not Winapi.Windows.RegisterWaitForSingleObject(waitHandles[i],
              handles[i], _LargeSetWaitCallback, @waiters[i],
              INFINITE, WT_EXECUTEONLYONCE)
      then begin
        // Rollback any registrations done so far, bubble wrError.
        for var k := 0 to i - 1 do
          Winapi.Windows.UnregisterWaitEx(waitHandles[k], INVALID_HANDLE_VALUE);
        Exit;
      end;
    end;

    waitRes := Winapi.Windows.WaitForSingleObject(pCounterH, timeout_ms);

    // Unregister everyone. INVALID_HANDLE_VALUE makes UnregisterWaitEx block
    // until in-flight callbacks complete, so pending callbacks never
    // dereference our waiter records after this loop returns.
    for i := 0 to count - 1 do
      Winapi.Windows.UnregisterWaitEx(waitHandles[i], INVALID_HANDLE_VALUE);

    case waitRes of
      WAIT_TIMEOUT: waitResult := wrTimeout;
      WAIT_FAILED : waitResult := wrError;
      WAIT_OBJECT_0:
        begin
          waitResult := wrSignaled;
          if waitAll then begin
            for i := 0 to count - 1 do
              idxToSynch[i].AckKernelConsumed;
            Signaller := idxToSynch[0];
          end
          else if (idxSlot >= 0) and (idxSlot < count) then begin
            idxToSynch[idxSlot].AckKernelConsumed;
            Signaller := idxToSynch[idxSlot];
          end
          else
            waitResult := wrError;
        end;
    else
      waitResult := wrError;
    end;
  finally
    if signalEvent <> 0 then
      Winapi.Windows.CloseHandle(signalEvent);
    resCount := nil;
  end;

  Result := true;
end; { TWaitFor.TCondition.TryKernelLargeSet }
{$ENDIF MSWINDOWS}

function TWaitFor.TCondition.Wait(timeout_ms: cardinal;
  var Signaller: IOmniSynchro): TWaitResult;
var
  elapsed   : int64;
  signaller1: IOmniSynchro;
  so        : IOmniSynchro;
  timer     : TStopWatch;
  waitTime  : cardinal;
begin
  {$IFDEF MSWINDOWS}
  if TryKernelFastPath(timeout_ms, Signaller, Result) then
    Exit;
  // For > 64 kernel handles WaitForMultipleObjects is not usable; use the
  // RegisterWaitForSingleObject fallback so externally-signalled raw
  // HANDLE events still wake the caller (the generic observer slow path
  // below would never wake for those — it only notices state changes
  // routed through IOmniEvent.SetEvent / PerformObservableAction).
  if TryKernelLargeSet(timeout_ms, Signaller, Result) then
    Exit;
  {$ENDIF MSWINDOWS}
  waitTime := timeout_ms;
  if waitTime > 0 then
    timer := TStopWatch.StartNew;
  FController.FGate.Acquire;
  try
    if Test(signaller1) then
      Result := wrSignaled
    else if (timeout_ms <= 0) or (timeout_ms <= timer.ElapsedMilliseconds) then
      Result := wrTimeout
    else begin
      for so in FController.SynchObjects do
        if assigned(so) then
        so.AddObserver(FController.SynchClient);
      // Baseline the signalled count now that observers are attached and
      // the wait set is stable (FGate held). TSynchroClient.AfterSignal
      // maintains it atomically from here, so FCondVar.Release only fires
      // on real false→true transitions.
      FController.RecomputeSignalledCount;
      try
        if Test(signaller1) then
          Result := wrSignaled
        else begin
          repeat
            elapsed := timer.ElapsedMilliseconds;
            if elapsed >= timeout_ms then begin
              Result := wrTimeout;
              break; //repeat
            end;
            waitTime := timeout_ms - elapsed;
            case FCondVar.WaitFor(TCriticalSection(FController.FGate.GetSyncObj), waitTime) of
              wrSignaled:
                begin
                  if Test(signaller1) then begin
                    Result := wrSignaled;
                    break; //repeat
                  end;
                  // Spurious wakeup — loop back and re-wait
                end;
              wrTimeout:
                begin
                  Result := wrTimeout;
                  break; //repeat
                end;
              wrAbandoned,
              wrError,
              wrIOCompletion:
              begin
                Result := wrError;
                break; //repeat
              end;
            end; // case
          until false;
        end;
      finally
        for so in FController.SynchObjects do
          if assigned(so) then
          so.RemoveObserver(FController.SynchClient);
      end;
    end;

    if Result = wrSignaled then begin
      if assigned(signaller1) then begin
        signaller1.ConsumeSignalFromObserver(FController.FSynchClient);
        // ConsumeSignalFromObserver clears FState on auto-reset events
        // without going through PerformObservableAction, so the observer
        // AfterSignal callback never fires — decrement the count manually
        // if the signaller actually transitioned to not-signalled.
        if not signaller1.IsSignalled then
          TInterlocked.Decrement(FController.FSignalledCount);
      end;
      Signaller := signaller1;
    end;
  finally FController.FGate.Release; end;
end; { TWaitFor.TCondition.Wait }

{ TWaitFor }

constructor TWaitFor.Create(const synchObjects: array of IOmniSynchro;
  const AShareLock: IOmniCriticalSection = nil);
var
  member: IOmniSynchro;
begin
  if assigned(AShareLock) then
    FGate := AShareLock
  else
    FGate := CreateOmniCriticalSection;
  Assert(FGate.GetSyncObj is TCriticalSection);
  FSynchObjects := TSynchroList.Create;
  FOneSignalled := TOneCondition.Create(self);
  FAllSignalled := TAllCondition.Create(self);
  FSynchClient := TSynchroClient.Create(self);
  for member in synchObjects do
    FSynchObjects.Add(member);
end; { TWaitFor.Create }

constructor TWaitFor.Create;
var
  emptySynchros: array of IOmniSynchro;
begin
  Create(emptySynchros);
end; { TWaitFor.Create }

{$IFDEF MSWINDOWS}
constructor TWaitFor.Create(const handles: array of THandle);
var
  synchros: array of IOmniSynchro;
  i       : integer;
begin
  SetLength(synchros, Length(handles));
  for i := Low(handles) to High(handles) do
    synchros[i] := CreateOmniEvent(handles[i], false);
  Create(synchros);
end; { TWaitFor.Create }
{$ENDIF MSWINDOWS}

destructor TWaitFor.Destroy;
var
  SynchClientEx: ISynchroClientEx;
begin
  // Acquire FGate before Deref to serialize with PerformObservableAction,
  // which may hold a snapshot reference to the observer after releasing
  // the spin lock. This ensures FController (and thus FOneSignalled,
  // FAllSignalled) remain valid while PerformObservableAction holds the gate.
  if assigned(FGate) then
    FGate.Acquire;
  try
    if Supports(FSynchClient, ISynchroClientEx, SynchClientEx) then
      SynchClientEx.Deref;
    FSynchClient := nil;
  finally
    if assigned(FGate) then
      FGate.Release;
  end;
  FSynchObjects.Clear;
  FGate := nil;
  FreeAndNil(FSynchObjects);
  FreeAndNil(FOneSignalled);
  FreeAndNil(FAllSignalled);
  inherited;
end; { TWaitFor.Destroy }

{$IFDEF MSWINDOWS}
function TWaitFor.GetWaitHandles: THandleArr;
var
  i: integer;
begin
  SetLength(Result, FSynchObjects.Count);
  for i := 0 to FSynchObjects.Count - 1 do
    Result[i] := FSynchObjects[i].Handle;
end; { TWaitFor.GetWaitHandles }

function TWaitFor.MsgWaitAny(timeout_ms, wakeMask, flags: cardinal): TWaitForResult;
var
  handles  : array of THandle;
  i        : integer;
  winResult: cardinal;
begin
  SetLength(handles, FSynchObjects.Count);
  for i := 0 to FSynchObjects.Count - 1 do
    handles[i] := FSynchObjects[i].Handle;
  if Length(handles) = 0 then begin
    winResult := MsgWaitForMultipleObjectsEx(0, handles, timeout_ms, wakeMask, flags);
  end
  else
    winResult := MsgWaitForMultipleObjectsEx(Length(handles), handles[0], timeout_ms, wakeMask, flags);
  if winResult = (WAIT_OBJECT_0 + cardinal(Length(handles))) then begin
    SetLength(FSignalledHandles, 0);
    Result := waMessage;
  end
  else if winResult < (WAIT_OBJECT_0 + cardinal(Length(handles))) then begin
    SetLength(FSignalledHandles, 1);
    FSignalledHandles[0].Index := winResult - WAIT_OBJECT_0;
    Result := waAwaited;
  end
  else if winResult = WAIT_TIMEOUT then begin
    SetLength(FSignalledHandles, 0);
    Result := waTimeout;
  end
  else if winResult = WAIT_IO_COMPLETION then begin
    SetLength(FSignalledHandles, 0);
    Result := waIOCompletion;
  end
  else begin
    SetLength(FSignalledHandles, 0);
    Result := waFailed;
  end;
end; { TWaitFor.MsgWaitAny }

procedure TWaitFor.SetHandles(const handles: array of THandle);
var
  i: integer;
begin
  FSynchObjects.Clear;
  for i := Low(handles) to High(handles) do
    FSynchObjects.Add(CreateOmniEvent(handles[i], false));
end; { TWaitFor.SetHandles }
{$ENDIF MSWINDOWS}

procedure TWaitFor.SetSynchObjects(const synchObjects: array of IOmniSynchro);
var
  member: IOmniSynchro;
begin
  FSynchObjects.Clear;
  for member in synchObjects do
    FSynchObjects.Add(member);
end; { TWaitFor.SetSynchObjects }

function TWaitFor.MapResult(waitResult: TWaitResult): TWaitForResult;
begin
  case waitResult of
    wrSignaled:     Result := waAwaited;
    wrTimeout:      Result := waTimeout;
    wrAbandoned:    Result := waFailed;
    wrError:        Result := waFailed;
    wrIOCompletion: Result := waIOCompletion;
    else raise Exception.Create('Unexpected value: ' + Ord(waitResult).ToString);
  end;
end; { TWaitFor.MapResult }

procedure TWaitFor.RecomputeSignalledCount;
var
  count : integer;
  member: IOmniSynchro;
begin
  // Caller must hold FGate. Called after AddObserver in TCondition.Wait so
  // that TSynchroClient.AfterSignal has an accurate baseline to atomically
  // update — and so TestFast can read an O(1) snapshot instead of scanning
  // SynchObjects on every signal.
  count := 0;
  for member in FSynchObjects do
    if assigned(member) and member.IsSignalled then
      Inc(count);
  FSignalledCount := count;
end; { TWaitFor.RecomputeSignalledCount }

procedure TWaitFor.PopulateSignalled(const signaller: IOmniSynchro; waitAll: boolean);
var
  countSignalled: integer;
  i             : integer;
begin
  if waitAll then begin
    // For WaitAll, all objects are signalled
    SetLength(FSignalledHandles, FSynchObjects.Count);
    for i := 0 to FSynchObjects.Count - 1 do
      FSignalledHandles[i].Index := i;
  end
  else begin
    // For WaitAny, find all currently signalled objects
    SetLength(FSignalledHandles, FSynchObjects.Count);
    countSignalled := 0;
    for i := 0 to FSynchObjects.Count - 1 do begin
      if (FSynchObjects[i] = signaller) or FSynchObjects[i].IsSignalled then begin
        FSignalledHandles[countSignalled].Index := i;
        Inc(countSignalled);
      end;
    end;
    SetLength(FSignalledHandles, countSignalled);
  end;
end; { TWaitFor.PopulateSignalled }

function TWaitFor.WaitAll(timeout_ms: cardinal): TWaitForResult;
var
  signaller: IOmniSynchro;
begin
  Result := WaitAll(timeout_ms, signaller);
end; { TWaitFor.WaitAll }

function TWaitFor.WaitAll(timeout_ms: cardinal; var Signaller: IOmniSynchro): TWaitForResult;
begin
  Result := MapResult(FAllSignalled.Wait(timeout_ms, Signaller));
  FGate.Acquire;
  try
    if Result = waAwaited then
      PopulateSignalled(Signaller, true)
    else
      SetLength(FSignalledHandles, 0);
  finally FGate.Release; end;
end; { TWaitFor.WaitAll }

function TWaitFor.WaitAny(timeout_ms: cardinal): TWaitForResult;
var
  signaller: IOmniSynchro;
begin
  Result := WaitAny(timeout_ms, signaller);
end; { TWaitFor.WaitAny }

function TWaitFor.WaitAny(timeout_ms: cardinal; var Signaller: IOmniSynchro): TWaitForResult;
begin
  Result := MapResult(FOneSignalled.Wait(timeout_ms, Signaller));
  FGate.Acquire;
  try
    if Result = waAwaited then
      PopulateSignalled(Signaller, false)
    else
      SetLength(FSignalledHandles, 0);
  finally FGate.Release; end;
end; { TWaitFor.WaitAny }

{ TOneCondition }

function TOneCondition.Test(var Signaller: IOmniSynchro): boolean;
var
  member: IOmniSynchro;
begin
  Result := False;
  FController.Gate.Acquire;
  try
    for member in FController.SynchObjects do begin
      if not assigned(member) then
        continue;
      if member.IsSignalled then begin
        Signaller := member;
        Exit(true);
      end;
    end; //for
  finally FController.Gate.Release; end
end; { TOneCondition.Test }

{ TAllCondition }

function TAllCondition.Test(var Signaller: IOmniSynchro): boolean;
var
  member: IOmniSynchro;
begin
  Result := True;
  Signaller := nil;
  FController.Gate.Acquire;
  try
    for member in FController.SynchObjects do begin
      if not assigned(member) then
        continue;
      Result := member.IsSignalled;
      if not Result then
        break; //for
      if not assigned(Signaller) then
        Signaller := member;
    end; //for
  finally FController.Gate.Release; end;
end; { TAllCondition.Test }

{ TOmniSingleThreadUseChecker }

procedure TOmniSingleThreadUseChecker.AttachToCurrentThread;
begin
  FLock.Acquire;
  try
    FThreadID := GetCurrentThreadID;
  finally FLock.Release; end;
end; { TOmniSingleThreadUseChecker.AttachToCurrentThread }

procedure TOmniSingleThreadUseChecker.Check;
var
  thID: TThreadID;
begin
  FLock.Acquire;
  try
    thID := GetCurrentThreadID;
    if (FThreadID <> 0) and (FThreadID <> thID) then
      raise Exception.CreateFmt(
        'Unsafe use: Current thread ID: %d, previous thread ID: %d',
        [thID, FThreadID]);
    FThreadID := thId;
  finally FLock.Release; end;
end; { TOmniSingleThreadUseChecker.Check }

procedure TOmniSingleThreadUseChecker.DebugCheck;
{$IFDEF OTL_CheckThreadSafety}
var
  thID: TThreadID;
{$ENDIF OTL_CheckThreadSafety}
begin
  {$IFDEF OTL_CheckThreadSafety}
  FLock.Acquire;
  try
    thID := GetCurrentThreadID;
    if (FThreadID <> 0) and (FThreadID <> thID) then
      raise Exception.CreateFmt(
        'Unsafe use: Current thread ID: %d, previous thread ID: %d',
        [thID, FThreadID]);
    FThreadID := thId;
  finally FLock.Release; end;
  {$ENDIF OTL_CheckThreadSafety}
end; { TOmniSingleThreadUseChecker.DebugCheck }

{ TOmniSynchroObject }

constructor TOmniSynchroObject.Create(ABase: TSynchroObject; OwnsIt: boolean;
  const AShareLock: IOmniCriticalSection);
begin
  FBase := ABase;
  FOwnsBase := OwnsIt;
  if assigned(AShareLock) then
    FShareLock := AShareLock
  else
    FLock := TSpinLock.Create(False);
  FObservers := TList<IOmniSynchroObserver>.Create
end; { TOmniSynchroObject.Create }

destructor TOmniSynchroObject.Destroy;
var
  Obs: IOmniSynchroObserver;
begin
  if FRefCount <> 0 then
    raise Exception.Create('TOmniSynchroObject.Destroy RefCount not zero.');
  with EnterSpinLock do begin
    for Obs in FObservers do
      Obs.DereferenceSynchObj(self, False);
    if FOwnsBase then
      FreeAndNil(FBase);
    FObservers.Free;
  end;
  inherited;
end; { TOmniSynchroObject.Destroy }

class function TOmniSynchroObject.NewInstance: TObject;
var
  Inst: TOmniSynchroObject;
begin
  Inst := TOmniSynchroObject(inherited NewInstance);
  Inst.FrefCount := 1;
  Result := Inst;
end; { TOmniSynchroObject.NewInstance }

procedure TOmniSynchroObject.AfterConstruction;
begin
  inherited;
  TInterlocked.Decrement(FRefCount);
end; { TOmniSynchroObject.AfterConstruction }

function TOmniSynchroObject._AddRef: Integer;
begin
  Result := TInterlocked.Increment(FRefCount)
end; { TOmniSynchroObject._AddRef }

function TOmniSynchroObject._Release: Integer;
begin
  result := TInterlocked.Decrement(FRefCount);
  if result = 0 then
    Destroy;
end; { TOmniSynchroObject._Release }

function TOmniSynchroObject.Base: TSynchroObject;
begin
  Result := FBase;
end; { TOmniSynchroObject.Base }

function TOmniSynchroObject.EnterSpinLock: IInterface;
begin
  Result := TSynchroSpin.Create(Self)
end; { TOmniSynchroObject.EnterSpinLock }

function TOmniSynchroObject.QueryInterface(const IID: TGUID; out Obj): HResult;
begin
  if GetInterface(IID, Obj) then
    Result := 0
  else
    Result := E_NOINTERFACE;
end; { TOmniSynchroObject.QueryInterface }

procedure TOmniSynchroObject.PerformObservableAction(Action: TProc; DoLock: boolean);
var
  count        : integer;
  iObserver    : integer;
  localData    : TArray<TObject>;
  localGates   : TArray<IOmniCriticalSection>;
  observersCopy: TArray<IOmniSynchroObserver>;
  spinGuard    : IInterface;
begin
  // Lock-free fast path: when no observers are attached, skip spin-lock
  // acquire entirely. A racy-stale read of 0 is safe — slow-path waiters
  // re-test state after AddObserver, so any observer that transitions
  // Count from 0→1 concurrently with us will catch the Action's state
  // change on their re-test. Action still runs.
  if FObservers.Count = 0 then begin
    Action;
    Exit;
  end;
  if DoLock then begin
    // Phase 1: Snapshot observers under spin lock
    spinGuard := EnterSpinLock;
    count := FObservers.Count;
    if count = 0 then begin
      Action;
      Exit; // spinGuard released automatically
    end;
    SetLength(observersCopy, count);
    for iObserver := 0 to count - 1 do
      observersCopy[iObserver] := FObservers[iObserver];
    // Release spin lock BEFORE entering gates to prevent lock-order inversion:
    // TCondition.Wait acquires FGate then SpinLock (via AddObserver),
    // so we must not hold SpinLock while acquiring FGate (via EnterGate).
    spinGuard := nil;

    // Phase 2: Enter gates without holding spin lock.
    // Track acquired gates locally so we can always release them, even
    // if FController is nilled by TWaitFor.Destroy between Enter and Leave.
    SetLength(localData, count);
    SetLength(localGates, count);
    for iObserver := 0 to count - 1 do begin
      observersCopy[iObserver].EnterGate;
      observersCopy[iObserver].GetGate(localGates[iObserver]);
    end;
    try
      // Phase 3: Execute under gates (serialized with TCondition.Wait)
      for iObserver := 0 to count - 1 do
        observersCopy[iObserver].BeforeSignal(self, localData[iObserver]);
      Action;
      for iObserver := 0 to count - 1 do
        observersCopy[iObserver].AfterSignal(self, localData[iObserver]);
    finally
      for iObserver := 0 to count - 1 do
        if assigned(localGates[iObserver]) then
          localGates[iObserver].Release;
    end;
  end
  else begin
    if FObservers.Count = 0 then
      Action
    else begin
      count := FObservers.Count;
      SetLength(observersCopy, count);
      for iObserver := 0 to count - 1 do
        observersCopy[iObserver] := FObservers[iObserver];
      SetLength(localData, count);
      SetLength(localGates, count);
      for iObserver := 0 to count - 1 do begin
        observersCopy[iObserver].EnterGate;
        observersCopy[iObserver].GetGate(localGates[iObserver]);
      end;
      try
        for iObserver := 0 to count - 1 do
          observersCopy[iObserver].BeforeSignal(self, localData[iObserver]);
        Action;
        for iObserver := 0 to count - 1 do
          observersCopy[iObserver].AfterSignal(self, localData[iObserver]);
      finally
        for iObserver := 0 to count - 1 do
          if assigned(localGates[iObserver]) then
            localGates[iObserver].Release;
      end;
    end;
  end;
end; { TOmniSynchroObject.PerformObservableAction }

procedure TOmniSynchroObject.Release;
begin
  PerformObservableAction(procedure begin FBase.Release; end, True);
end; { TOmniSynchroObject.Release }

procedure TOmniSynchroObject.Signal;
begin
  Release;
end; { TOmniSynchroObject.Signal }

function TOmniSynchroObject.WaitFor(Timeout: Cardinal): TWaitResult;
begin
  if FObservers.Count > 0 then
    raise Exception.Create('Cannot wait directly on TOmniSynchroObject whilst it is enrolled in a compound syncro object.')
  else
    Result := FBase.WaitFor(Timeout);
end; { TOmniSynchroObject.WaitFor }

{$IFDEF MSWINDOWS}
function TOmniSynchroObject.Handle: THandle;
begin
  if FBase is THandleObject then
    Result := THandleObject(FBase).Handle
  else
    raise Exception.Create('TOmniSynchroObject.Handle: Handle is not available!');
end; { TOmniSynchroObject.Handle }

function TOmniSynchroObject.HasKernelHandle: boolean;
begin
  Result := FBase is THandleObject;
end; { TOmniSynchroObject.HasKernelHandle }

procedure TOmniSynchroObject.AckKernelConsumed;
begin
  // Default: nothing to sync. Subclasses that maintain a shadow signalled
  // flag (e.g. TOmniEvent.FState) override this to match the post-wait state.
end; { TOmniSynchroObject.AckKernelConsumed }
{$ENDIF}

procedure TOmniSynchroObject.Acquire;
begin
  WaitFor(INFINITE)
end; { TOmniSynchroObject.Acquire }

procedure TOmniSynchroObject.AddObserver(const Observer: IOmniSynchroObserver);
begin
  with EnterSpinLock do begin
    if FObservers.IndexOf(Observer) = -1 then
      FObservers.Add(Observer);
    SetLength(FData, FObservers.Count);
  end;
end; { TOmniSynchroObject.AddObserver }

procedure TOmniSynchroObject.RemoveObserver(const Observer: IOmniSynchroObserver);
begin
  with EnterSpinLock do begin
    if FObservers.Count = 0 then
      Exit;
    FObservers.Remove(Observer);
    Observer.DereferenceSynchObj(self, FRefCount > 0);
    SetLength(FData, FObservers.Count)
  end;
end; { TOmniSynchroObject.RemoveObserver }

{ TSynchroSpin }

constructor TSynchroSpin.Create(AController: TOmniSynchroObject);
begin
  FController := AController;
  if assigned(FController.ShareLock) then
    FController.ShareLock.Acquire
  else
    FController.Lock.Enter;
end; { TSynchroSpin.Create }

destructor TSynchroSpin.Destroy;
begin
  if assigned(FController.ShareLock) then
    FController.ShareLock.Release
  else
    FController.Lock.Exit(True);
  inherited;
end; { TSynchroSpin.Destroy }

{ TOmniCountdownEvent }

constructor TOmniCountdownEvent.Create(Count, SpinCount: Integer; const AShareLock: IOmniCriticalSection);
begin
  FCountdown := TCountdownEvent.Create(Count, SpinCount);
  inherited Create(FCountdown, True, AShareLock)
end; { TOmniCountdownEvent.Create }

function TOmniCountdownEvent.IsSignalled: boolean;
begin
  Result := FCountdown.IsSet;
end; { TOmniCountdownEvent.IsSignalled }

procedure TOmniCountdownEvent.Reset;
begin
  PerformObservableAction(procedure begin FCountdown.Reset; end, True);
end; { TOmniCountdownEvent.Reset }

function TOmniCountdownEvent.BaseCountdown: TCountdownEvent;
begin
  Result := FCountdown;
end; { TOmniCountdownEvent.BaseCountdown }

procedure TOmniCountdownEvent.ConsumeSignalFromObserver(const Observer: IOmniSynchroObserver);
begin
end; { TOmniCountdownEvent.ConsumeSignalFromObserver }

{$IFDEF MSWINDOWS}
{ TOmniWrappedEvent }

constructor TOmniWrappedEvent.Create(AExternalEvent: THandle; ATakeOwnership: boolean);
begin
  inherited Create(nil, false, false, '');
  if FHandle <> 0 then
    CloseHandle(FHandle);
  FHandle := AExternalEvent;
  FIsOwner := ATakeOwnership;
end; { TOmniWrappedEvent.Create }

destructor TOmniWrappedEvent.Destroy;
begin
  if FIsOwner and (FHandle <> 0) then
    CloseHandle(FHandle);
  FHandle := 0;
  inherited;
end; { TOmniWrappedEvent.Destroy }
{$ENDIF MSWINDOWS}

{ TOmniEvent }

constructor TOmniEvent.Create(AManualReset, InitialState: boolean; const AShareLock: IOmniCriticalSection);
begin
  FEvent := TEvent.Create(nil, AManualReset, InitialState, '', False);
  FState := InitialState;
  FManualReset := AManualReset;
  inherited Create(FEvent, True, AShareLock);
end; { TOmniEvent.Create }

{$IFDEF MSWINDOWS}
constructor TOmniEvent.Create(AExternalEvent: THandle; ATakeOwnership: boolean; AManualReset: boolean);
begin
  FEvent := TOmniWrappedEvent.Create(AExternalEvent, ATakeOwnership);
  FManualReset := AManualReset;
  FState := FEvent.WaitFor(0) = wrSignaled;
  inherited Create(FEvent, True, nil);
end;
{$ENDIF MSWINDOWS}

function TOmniEvent.BaseEvent: TEvent;
begin
  Result := FEvent;
end; { TOmniEvent.BaseEvent }

procedure TOmniEvent.ConsumeSignalFromObserver(const Observer: IOmniSynchroObserver);
begin
  // TODO at the moment, FManualReset is not set when event is created by wrapping an external THandle
  // Here we are already inside the lock.
  if not FManualReset then begin
    FEvent.ResetEvent;
    FState := False;
  end
end; { TOmniEvent.ConsumeSignalFromObserver }

{$IFDEF MSWINDOWS}
procedure TOmniEvent.AckKernelConsumed;
begin
  // WaitForMultipleObjects already auto-reset an auto-reset kernel event;
  // just sync the shadow flag so subsequent IsSignalled checks (slow path
  // or PopulateSignalled) return the correct value. Skipping the redundant
  // ResetEvent syscall vs. ConsumeSignalFromObserver saves ~1 µs per wake.
  if not FManualReset then
    FState := False;
end; { TOmniEvent.AckKernelConsumed }
{$ENDIF MSWINDOWS}

function TOmniEvent.IsSignalled: boolean;
begin
  Result := FState;
end; { TOmniEvent.IsSignalled }

procedure TOmniEvent.Reset;
begin
  PerformObservableAction(
    procedure
    begin
      FEvent.ResetEvent;
      FState := False;
    end,
    True);
end; { TOmniEvent.Reset }

procedure TOmniEvent.SetEvent;
begin
  PerformObservableAction(
    procedure
    begin
      FEvent.SetEvent;
      FState := True;
    end,
    True);
end; { TOmniEvent.SetEvent }

procedure TOmniEvent.Signal;
begin
  SetEvent;
end;

function TOmniEvent.WaitFor(Timeout: Cardinal): TWaitResult;
begin
  Result := inherited WaitFor(Timeout);
  if (Result = wrSignaled) and (not FManualReset) then
    PerformObservableAction(
      procedure
      begin
        FState := False;
      end,
      True);
end; { TOmniEvent.WaitFor }

{ TPreSignalData }

constructor TPreSignalData.Create(AOneSignalled, AAllSignalled: boolean);
begin
  OneSignalled := AOneSignalled;
  AllSignalled := AAllSignalled;
end; { TPreSignalData.Create }

{ TInterlockedEx }

class function TInterlockedEx.CompareExchange(var Target: NativeInt; Value: NativeInt; Comparand: NativeInt): NativeInt; //inline
begin
  {$IFDEF CPU64BITS}
  Result := TInterlocked.CompareExchange(Int64(Target), Int64(Value), Int64(Comparand));
  {$ELSE}
  Result := TInterlocked.CompareExchange(Integer(Target), Integer(Value), Integer(Comparand));
  {$ENDIF}
end; { TInterlockedEx.CompareExchange }

class function TInterlockedEx.Add(var Target: NativeInt; Increment: NativeInt): NativeInt;
begin
  {$IFDEF CPU64BITS}
  Result := TInterlocked.Add(Int64(Target), Int64(Increment));
  {$ELSE}
  Result := TInterlocked.Add(Integer(Target), Integer(Increment));
  {$ENDIF}
end; { TInterlockedEx.Add }

class function TInterlockedEx.CAS(const oldValue, newValue: pointer; var destination): boolean;
begin
  Result := CompareExchange(NativeInt(destination), NativeInt(newValue), NativeInt(oldValue)) = NativeInt(oldValue);
end; { TInterlockedEx.CAS }

class function TInterlockedEx.CAS(const oldValue, newValue: NativeInt;
  var destination): boolean;
begin
  Result := CompareExchange(NativeInt(destination), newValue, oldValue) = NativeInt(oldValue);
end; { TInterlockedEx.CAS }

constructor TFixedCriticalSection.Create(logMe: boolean);
begin
  inherited Create;
  FLogMe := logMe;
  if FLogMe then
    Writeln(Format('[%d] %s Create %p', [TThread.Current.ThreadID, FormatDateTime('hh:mm:ss.zzz', Now), pointer(Self)]));
end;

destructor TFixedCriticalSection.Destroy;
begin
  if FLogMe then
    Writeln(Format('[%d] %s Destroy %p', [TThread.Current.ThreadID, FormatDateTime('hh:mm:ss.zzz', Now), pointer(Self)]));
  inherited;
end;

procedure TFixedCriticalSection.Acquire;
begin
  if FLogMe then
    Writeln(Format('[%d] %s Acquire %p', [TThread.Current.ThreadID, FormatDateTime('hh:mm:ss.zzz', Now), pointer(Self)]));
  inherited;
  if FLogMe then
    Writeln(Format('[%d] %s Acquired %p', [TThread.Current.ThreadID, FormatDateTime('hh:mm:ss.zzz', Now), pointer(Self)]));
end;

procedure TFixedCriticalSection.Release;
begin
  if FLogMe then
    Writeln(Format('[%d] %s Release %p', [TThread.Current.ThreadID, FormatDateTime('hh:mm:ss.zzz', Now), pointer(Self)]));
  inherited;
end;

{ TLightweightMREWExImpl }

procedure TLightweightMREWExImpl.BeginRead;
begin
  FLock.BeginRead;
end; { TLightweightMREWExImpl.BeginRead }

procedure TLightweightMREWExImpl.BeginWrite;
begin
  FLock.BeginWrite;
end; { TLightweightMREWExImpl.BeginWrite }

procedure TLightweightMREWExImpl.EndRead;
begin
  FLock.EndRead;
end; { TLightweightMREWExImpl.EndRead }

procedure TLightweightMREWExImpl.EndWrite;
begin
  FLock.EndWrite;
end; { TLightweightMREWExImpl.EndWrite }

function TLightweightMREWExImpl.TryBeginRead: boolean;
begin
  Result := FLock.TryBeginRead;
end; { TLightweightMREWExImpl.TryBeginRead }

{$IF defined(LINUX) or defined(ANDROID)}
function TLightweightMREWExImpl.TryBeginRead(timeout: cardinal): boolean;
begin
  Result := FLock.TryBeginRead(timeout);
end; { TLightweightMREWExImpl.TryBeginRead }
{$ENDIF LINUX or ANDROID}

function TLightweightMREWExImpl.TryBeginWrite: boolean;
begin
  Result := FLock.TryBeginWrite;
end; { TLightweightMREWExImpl.TryBeginWrite }

{$IF defined(LINUX) or defined(ANDROID)}
function TLightweightMREWExImpl.TryBeginWrite(timeout: cardinal): boolean;
begin
  Result := FLock.TryBeginWrite(timeout);
end; { TLightweightMREWExImpl.TryBeginWrite }
{$ENDIF LINUX or ANDROID}

initialization
  GOmniCancellationToken := CreateOmniCancellationToken;
  GOmniCSInitializer := TOmniCriticalSection.Create;
  {$IFDEF CPUX64}
  CASAlignment := 16; // cmpxchg16b requires 16-byte alignment
  {$ELSE}
  CASAlignment := 8;
  {$ENDIF CPUX64}
  {$IFDEF CPU64BITS}
  Assert(SizeOf(NativeInt) = SizeOf(int64)); //assumption in TInterlockedEx.Add
  {$ELSE}
  Assert(SizeOf(NativeInt) = SizeOf(integer)); //assumption in TInterlockedEx.Add
  {$ENDIF CPU64BITS}
finalization
  FreeAndNil(GOmniCSInitializer);
end.

