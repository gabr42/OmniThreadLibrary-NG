///<summary>Lightweight ring-buffer trace probe for diagnosing cleanup-path
///   deadlocks under concurrent load. Compile-time gated by
///   <c>OTL_TRACE_PROBE</c>; no-op when undefined. Buffer is process-wide,
///   atomic-indexed; events are timestamped (QueryPerformanceCounter on
///   Windows, mach_absolute_time on macOS, clock_gettime on POSIX) and
///   tagged with the thread that emitted them. <c>DumpToFile</c> writes a
///   chronological trace, suitable for inspection after a test failure.
///   The buffer size is fixed at 4096 events — enough to capture multiple
///   task lifecycles. Old events are overwritten ring-style.</summary>
///<author>Claude AI</author>
///<remarks><para>
///   Creation date     : 2026-04-27
///   Last modification : 2026-04-27
///   Version           : 1.00
///</para><para>
///   History:
///     1.00: 2026-04-27
///       - Initial version. Used for the multi-process Unobserved-cleanup
///         deadlock investigation.
///</para></remarks>

unit OtlTraceProbe;

{$I OtlOptions.inc}

interface

{$IFDEF OTL_TRACE_PROBE}

// Master runtime switch. Even when the unit is compiled in (OTL_TRACE_PROBE
// defined), tracing is OFF by default — TraceMark short-circuits on this
// flag, so trace points scattered through OTL contribute essentially zero
// overhead. Enable for the specific test / region you want to inspect:
//
//   TraceEnable;
//   try
//     ... code under test ...
//   finally TraceDisable; end;
//
// Plain Boolean is fine: atomic-aligned read, single-bit flag. Late
// visibility of a transition by a few ns is acceptable for a diagnostic.
var
  TraceEnabled: Boolean;

procedure TraceEnable;
procedure TraceDisable;

// Tag is taken as PChar (raw pointer to immutable string literal). Storing
// raw pointers — instead of managed `string` references — avoids the
// refcount race that hits when ring-buffer wrap puts two concurrent writes
// on the same slot. Always pass a string literal; do NOT pass a dynamic
// `string` whose buffer might be freed before the trace is dumped.
procedure TraceMark(const tag: PChar); overload;
procedure TraceMark(const tag: PChar; uniqueID: int64); overload;
procedure TraceMark(const tag: PChar; uniqueID, payload: int64); overload;
procedure TraceDumpToFile(const fileName: string);
procedure TraceReset;

// Watchdog: dumps the current trace buffer to disk on a timer, even if no
// test has explicitly requested it. Useful when the test runner hangs and
// the user kills the process — at least one rolling snapshot survives.
// The watchdog only writes a snapshot when TraceEnabled is true, so an
// always-running watchdog combined with scoped TraceEnable/TraceDisable
// gives you a per-region dump without per-event overhead elsewhere.
procedure TraceWatchdogStart(const fileName: string; intervalMs: cardinal);
procedure TraceWatchdogStop;

{$ENDIF OTL_TRACE_PROBE}

implementation

{$IFDEF OTL_TRACE_PROBE}

uses
  System.Classes,
  System.SysUtils,
  System.SyncObjs,
  System.Diagnostics,
  System.Generics.Collections,
  Winapi.Windows;

const
  CBufferSize = 65536; // 2^16 — power-of-two for cheap modulo; ~2 MB total

type
  TTraceEvent = record
    Ticks   : int64;
    ThreadID: TThreadID;
    Tag     : PChar; // raw pointer to immutable string literal
    UniqueID: int64;
    Payload : int64;
  end;

var
  GBuffer    : array [0..CBufferSize - 1] of TTraceEvent;
  GIndex     : integer; // atomic counter, raw position; modulo at access
  GStartTicks: int64;

function CurTicks: int64; inline;
begin
  Result := TStopwatch.GetTimeStamp;
end;

procedure StoreEvent(const tag: PChar; uniqueID, payload: int64); inline;
var
  slot: integer;
begin
  slot := TInterlocked.Increment(GIndex) - 1;
  GBuffer[slot mod CBufferSize].Ticks    := CurTicks - GStartTicks;
  GBuffer[slot mod CBufferSize].ThreadID := TThread.CurrentThread.ThreadID;
  GBuffer[slot mod CBufferSize].Tag      := tag;
  GBuffer[slot mod CBufferSize].UniqueID := uniqueID;
  GBuffer[slot mod CBufferSize].Payload  := payload;
end;

procedure TraceEnable;
begin
  TraceEnabled := true;
end;

procedure TraceDisable;
begin
  TraceEnabled := false;
end;

procedure TraceMark(const tag: PChar);
begin
  if not TraceEnabled then Exit;
  StoreEvent(tag, 0, 0);
end;

procedure TraceMark(const tag: PChar; uniqueID: int64);
begin
  if not TraceEnabled then Exit;
  StoreEvent(tag, uniqueID, 0);
end;

procedure TraceMark(const tag: PChar; uniqueID, payload: int64);
begin
  if not TraceEnabled then Exit;
  StoreEvent(tag, uniqueID, payload);
end;

procedure TraceReset;
var
  i: integer;
begin
  GIndex := 0;
  for i := 0 to CBufferSize - 1 do begin
    GBuffer[i].Ticks    := 0;
    GBuffer[i].ThreadID := 0;
    GBuffer[i].Tag      := nil;
    GBuffer[i].UniqueID := 0;
    GBuffer[i].Payload  := 0;
  end;
  GStartTicks := CurTicks;
end;

procedure TraceDumpToFile(const fileName: string);
var
  freq      : int64;
  hdr       : string;
  i         : integer;
  lines     : TStringList;
  ms        : double;
  rawCount  : integer;
  startSlot : integer;
  totalSlots: integer;
begin
  rawCount := GIndex;
  if rawCount > CBufferSize then begin
    totalSlots := CBufferSize;
    startSlot := rawCount mod CBufferSize;
  end
  else begin
    totalSlots := rawCount;
    startSlot := 0;
  end;
  freq := TStopwatch.Frequency;
  if freq = 0 then
    freq := 1;
  lines := TStringList.Create;
  try
    hdr := Format('# OtlTraceProbe dump  pid=%d  events=%d (raw=%d, buffer=%d)',
      [GetCurrentProcessId, totalSlots, rawCount, CBufferSize]);
    lines.Add(hdr);
    lines.Add('# columns: ms_from_start  thread  tag  uniqueID  payload');
    for i := 0 to totalSlots - 1 do begin
      var slot := (startSlot + i) mod CBufferSize;
      ms := GBuffer[slot].Ticks * 1000.0 / freq;
      var tagStr: string := '';
      if GBuffer[slot].Tag <> nil then
        tagStr := string(GBuffer[slot].Tag);
      lines.Add(Format('%10.3f  tid=%-7d  %-28s  uid=%-12d  payload=%d',
        [ms, GBuffer[slot].ThreadID, tagStr,
         GBuffer[slot].UniqueID, GBuffer[slot].Payload]));
    end;
    lines.SaveToFile(fileName);
  finally FreeAndNil(lines); end;
end;

{ Watchdog implementation }

type
  TTraceWatchdogThread = class(TThread)
  strict private
    FFileName  : string;
    FIntervalMs: cardinal;
    FStopEvent : TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const aFileName: string; aIntervalMs: cardinal);
    destructor  Destroy; override;
    procedure SignalStop;
  end;

var
  GWatchdog: TTraceWatchdogThread;

constructor TTraceWatchdogThread.Create(const aFileName: string; aIntervalMs: cardinal);
begin
  FFileName   := aFileName;
  FIntervalMs := aIntervalMs;
  FStopEvent  := TEvent.Create(nil, true, false, '');
  FreeOnTerminate := false;
  inherited Create(false);
end;

destructor TTraceWatchdogThread.Destroy;
begin
  FreeAndNil(FStopEvent);
  inherited;
end;

procedure TTraceWatchdogThread.SignalStop;
begin
  Terminate;
  if assigned(FStopEvent) then
    FStopEvent.SetEvent;
end;

procedure TTraceWatchdogThread.Execute;
begin
  while (not Terminated)
        and (FStopEvent.WaitFor(FIntervalMs) <> wrSignaled)
  do begin
    if not TraceEnabled then
      Continue; // skip dump while tracing is gated off
    try
      TraceDumpToFile(FFileName);
    except
      // Swallow any I/O exception — watchdog must keep running and not
      // crash the host process. Likely cause: another snapshot still has
      // the file open from a previous tick, or the temp dir is gone.
    end;
  end;
end;

procedure TraceWatchdogStart(const fileName: string; intervalMs: cardinal);
begin
  if assigned(GWatchdog) then
    Exit;
  GWatchdog := TTraceWatchdogThread.Create(fileName, intervalMs);
end;

procedure TraceWatchdogStop;
begin
  if assigned(GWatchdog) then begin
    GWatchdog.SignalStop;
    GWatchdog.WaitFor;
    FreeAndNil(GWatchdog);
  end;
end;

initialization
  GStartTicks := CurTicks;

finalization
  TraceWatchdogStop;

{$ENDIF OTL_TRACE_PROBE}

end.
