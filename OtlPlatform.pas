///<summary>Platform compatibility layer for the OmniThreadLibrary project.</summary>
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
///   Contributors      : Claude AI
///   Creation date     : 2018-05-16
///   Last modification : 2026-04-24
///   Version           : 2.02
///</para><para>
///   History:
///     2.02: 2026-04-24
///       - POSIX ThreadAffinity is now wired up on Linux and Android via
///         sched_getaffinity / sched_setaffinity (pid=0 = calling thread).
///         The pthread_* variants were rejected because Android bionic
///         does not export pthread_setaffinity_np at the NDK sysroot API
///         level Delphi ships. sched_* have been in libc on both glibc
///         and bionic from day one. The CCPUIDs alphabet still caps at
///         64 CPUs to stay representation-compatible with the Windows
///         NativeUInt path. macOS / iOS remain no-op.
///       - AffinityMaskToString / StringToAffinityMask are now visible on
///         every platform (pure Pascal, no OS dependency) so POSIX callers
///         can build the mask themselves.
///     2.01: 2026-04-12
///       - Added AffinityMaskToString and StringToAffinityMask functions
///         (moved from DSiWin32 for use by OtlCommon.pas).
///     2.0: 2026-04-11 [OTL-NG]
///       - Removed DSiWin32 dependency.
///       - TTimeSource.Timestamp_ms now uses TStopwatch.ElapsedMilliseconds directly.
///       - Thread affinity uses direct Windows API (GetProcessAffinityMask,
///         SetThreadAffinityMask) instead of DSiWin32 wrappers.
///     1.0: 2018-05-16
///       - Released.
///</para></remarks>

unit OtlPlatform;

{$I OtlOptions.inc}

interface

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF MSWINDOWS}
  {$IF Defined(LINUX) or Defined(ANDROID)}
  Posix.Base,
  Posix.Errno,
  Posix.SysTypes,
  {$IFEND}
  System.Classes,
  System.Diagnostics,
  System.SysUtils;

type
  TTimeSource = record
  private
    FStopwatch: TStopwatch;
  public
    class function Create: TTimeSource; static;
    function  Elapsed_ms(startTime_ms: int64): int64; inline;
    function  HasElapsed(startTime_ms, timeout_ms: int64): boolean;
    function  Timestamp_ms: int64; inline;
  end; { TTimeSource }
  PTimeSource = ^TTimeSource;

  TPlatform = record
  private
    class function  GetThreadAffinity: string; static;
    class function  GetThreadID: TThreadID; static;
    class procedure SetThreadAffinity(const value: string); static;
  public
    class property ThreadAffinity: string read GetThreadAffinity write SetThreadAffinity;
    class property ThreadID: TThreadID read GetThreadID;
  end; { TPlatform }

function Time: PTimeSource; inline;

function AffinityMaskToString(affinityMask: NativeUInt): string;
function StringToAffinityMask(const affinity: string): NativeUInt;

// must be global for inlining
var
  GTimeSource: TTimeSource;

implementation

const
  CCPUIDs = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz@$';

function AffinityMaskToString(affinityMask: NativeUInt): string;
var
  idxID: integer;
begin
  Result := '';
  for idxID := 1 to Length(CCPUIDs) do begin
    if Odd(affinityMask) then
      Result := Result + CCPUIDs[idxID];
    affinityMask := affinityMask SHR 1;
  end;
end; { AffinityMaskToString }

function StringToAffinityMask(const affinity: string): NativeUInt;
var
  idxID: integer;
begin
  Result := 0;
  for idxID := Length(CCPUIDs) downto 1 do begin
    Result := Result SHL 1;
    if Pos(CCPUIDs[idxID], affinity) > 0 then
      Result := Result OR 1;
  end;
end; { StringToAffinityMask }

{$IF Defined(LINUX) or Defined(ANDROID)}
// cpu_set_t with the default CPU_SETSIZE (1024 bits / 128 bytes).
// glibc and bionic both use `unsigned long __bits[CPU_SETSIZE / NCPUBITS]`;
// on 64-bit POSIX (the only platforms OTL-NG targets under this IFDEF)
// `unsigned long` is 64 bits, so 16 slots × 8 bytes = 128 bytes. We only
// expose the lowest 64 CPUs through the CCPUIDs string alphabet, matching
// the Windows NativeUInt mask behaviour.
type
  TCpuSet = record
    Bits: array[0..15] of UInt64;
  end;
  PCpuSet = ^TCpuSet;

// sched_setaffinity / sched_getaffinity are preferred over the pthread_*_np
// variants because they live in libc on every glibc and bionic release that
// OTL-NG targets. pthread_setaffinity_np is only exported by Android bionic
// starting at API level 24 and Delphi's NDK sysroot happens to be older
// than that, so linking against pthread_setaffinity_np fails at link time.
// sched_setaffinity with pid=0 targets the calling thread, matching the
// pthread_self() semantics we actually want.
//
// Return value convention differs: sched_* returns -1 on error and sets
// errno (unlike pthread_*_np which returns the error code directly). Callers
// must read errno when the return value is non-zero.
function sched_getaffinity(pid: pid_t; cpusetsize: size_t;
  cpuset: PCpuSet): Integer; cdecl;
  external libc name _PU + 'sched_getaffinity';
function sched_setaffinity(pid: pid_t; cpusetsize: size_t;
  cpuset: PCpuSet): Integer; cdecl;
  external libc name _PU + 'sched_setaffinity';
{$IFEND}

{ exports }

function Time: PTimeSource;
begin
  Result := @GTimeSource;
end; { Time }

{ TTimeSource }

class function TTimeSource.Create: TTimeSource;
begin
  Result.FStopwatch := TStopwatch.StartNew;
end; { TTimeSource.Create }

function TTimeSource.Timestamp_ms: int64;
begin
  Result := FStopwatch.ElapsedMilliseconds;
end; { TTimeSource.Timestamp_ms }

function TTimeSource.Elapsed_ms(startTime_ms: int64): int64;
begin
  Result := Timestamp_ms - startTime_ms;
end; { TTimeSource.Elapsed_ms }

function TTimeSource.HasElapsed(startTime_ms, timeout_ms: int64): boolean;
begin
  if timeout_ms <= 0 then
    Result := true
  else if timeout_ms = INFINITE then
    Result := false
  else
    Result := (Elapsed_ms(startTime_ms) >= timeout_ms);
end; { TTimeSource.HasElapsed }

{ TPlatform }

class function TPlatform.GetThreadAffinity: string;
{$IFDEF MSWINDOWS}
var
  processAffinityMask: NativeUInt;
  systemAffinityMask : NativeUInt;
  threadAffinityMask : NativeUInt;
{$ENDIF}
{$IF Defined(LINUX) or Defined(ANDROID)}
var
  cpuSet: TCpuSet;
  rc    : integer;
{$IFEND}
begin
  {$IFDEF MSWINDOWS}
  GetProcessAffinityMask(GetCurrentProcess, processAffinityMask, systemAffinityMask);
  threadAffinityMask := SetThreadAffinityMask(GetCurrentThread, processAffinityMask);
  SetThreadAffinityMask(GetCurrentThread, threadAffinityMask);
  Result := AffinityMaskToString(threadAffinityMask);
  {$ELSEIF Defined(LINUX) or Defined(ANDROID)}
  FillChar(cpuSet, SizeOf(cpuSet), 0);
  // pid=0 → calling thread; matches pthread_self() semantics.
  if sched_getaffinity(0, SizeOf(cpuSet), @cpuSet) <> 0 then begin
    rc := errno;
    raise Exception.CreateFmt(
      'TPlatform.GetThreadAffinity: sched_getaffinity failed with errno %d: %s',
      [rc, SysErrorMessage(rc)]);
  end;
  // Only the lowest 64 CPUs are representable through the CCPUIDs string
  // alphabet; that matches the Windows NativeUInt mask behaviour. Higher
  // CPUs in the kernel cpu_set_t are silently truncated.
  Result := AffinityMaskToString(NativeUInt(cpuSet.Bits[0]));
  {$ELSE}
  // macOS / iOS: no pthread_setaffinity_np equivalent (thread_policy_set is
  // advisory on macOS, unavailable on iOS). Report "all processors" as a
  // stable fallback so callers see a non-empty string.
  Result := Copy(CCPUIDs, 1, TThread.ProcessorCount);
  {$IFEND}
end; { TPlatform.GetThreadAffinity }

class function TPlatform.GetThreadID: TThreadID;
begin
  Result := TThread.CurrentThread.ThreadID;
end; { TPlatform.GetThreadID }

class procedure TPlatform.SetThreadAffinity(const value: string);
{$IFDEF MSWINDOWS}
var
  processAffinityMask: NativeUInt;
  systemAffinityMask : NativeUInt;
  validatedMask      : NativeUInt;
{$ENDIF}
{$IF Defined(LINUX) or Defined(ANDROID)}
var
  cpuSet: TCpuSet;
  rc    : integer;
{$IFEND}
begin
  {$IFDEF MSWINDOWS}
  GetProcessAffinityMask(GetCurrentProcess, processAffinityMask, systemAffinityMask);
  validatedMask := processAffinityMask AND StringToAffinityMask(value);
  SetThreadAffinityMask(GetCurrentThread, validatedMask);
  {$ELSEIF Defined(LINUX) or Defined(ANDROID)}
  FillChar(cpuSet, SizeOf(cpuSet), 0);
  // The CCPUIDs alphabet addresses the lowest 64 CPUs; anything beyond is
  // not expressible through the string interface. If the caller passes an
  // empty string the mask is 0, and sched_setaffinity will reject it with
  // EINVAL — we surface that error unchanged.
  cpuSet.Bits[0] := UInt64(StringToAffinityMask(value));
  if sched_setaffinity(0, SizeOf(cpuSet), @cpuSet) <> 0 then begin
    rc := errno;
    raise Exception.CreateFmt(
      'TPlatform.SetThreadAffinity: sched_setaffinity failed with errno %d: %s',
      [rc, SysErrorMessage(rc)]);
  end;
  {$ELSE}
  // macOS / iOS: no-op (see GetThreadAffinity).
  {$IFEND}
end; { TPlatform.SetThreadAffinity }

initialization
  GTimeSource := TTimeSource.Create;
end.
