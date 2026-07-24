# Recursive Reader Locks for TLightweightMREWEx — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make read locks in `TLightweightMREWEx` recursion-safe (nested `BeginRead` never deadlocks behind a pending writer), grant read-under-write, and raise loud exceptions on upgrade attempts and unmatched releases.

**Architecture:** A unit-private `threadvar` linked list tracks, per thread, which `TLightweightMREWEx` instances that thread currently holds in shared mode (node = lock address, nest count, os-held flag). Nested read acquires bump the count instead of touching the OS lock. Write-path methods consult the same list to detect upgrade attempts. Only the owning thread touches its list — zero synchronization.

**Tech Stack:** Delphi 11–13, `OtlSync.pas` (record `TLightweightMREWEx` wrapping RTL `TLightweightMREW` = SRWLOCK / pthread_rwlock_t), DUnitX tests in `unittests/TestOtlSync1.pas`.

**Spec:** `docs/superpowers/specs/2026-07-24-recursive-reader-locks-design.md`

## Global Constraints

- Indentation 2 spaces; `end; { TClassName.MethodName }` block comments; lowercase `break`/`continue`; don't capitalize `assigned`.
- Exception messages: `'TLightweightMREWEx.MethodName: reason'`.
- POSIX-only overloads guarded `{$IF defined(LINUX) or defined(ANDROID)}` ... `{$ENDIF LINUX or ANDROID}`.
- Build Win32 (Delphi 13.1): `cd unittests && "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcc32.exe" ConsoleTestRunner.dpr -B "-U..;../FastMM4" "-NSSystem;System.Win;Winapi;Vcl" -DDEBUG -E"./Win32/Debug" -NU"./Win32/Debug"` (bash; quote args with semicolons).
- Run fixture: `./Win32/Debug/ConsoleTestRunner.exe --run:"TestOtlSync1.TestLightweightMREWEx"`.
- Tests that are EXPECTED to hang in their RED phase must be run isolated under `timeout 30 ...` — a hang IS the expected failure.
- Test units are already registered in both runners; no `.dpr` changes needed.
- The working tree starts with uncommitted v3.08 changes (`OtlSync.pas`, `OtlCollections.pas`, `unittests/TestOtlSync1.pas`) — Task 0 commits them first so later commits stay focused.
- dcc32 37.0 ICE warning: inside generic methods do not write `PInt64(@x)^` directly (see OtlCollections.pas 3.01 comment). Not relevant to this plan's code (no generics), listed for awareness.

---

### Task 0: Commit the pending v3.08 work

**Files:**
- Modify: none (commits only)

**Interfaces:**
- Consumes: current working tree (v3.08 read-after-write raise + ICE workaround, all tests green as of this morning).
- Produces: clean working tree so Task 1+ commits are single-purpose.

- [ ] **Step 1: Verify tree state and green suite**

Run: `cd /h/RAZVOJ/OmniThreadLibrary-NG && git status --short`
Expected: exactly three modified files: `OtlCollections.pas`, `OtlSync.pas`, `unittests/TestOtlSync1.pas`.

Run: `cd unittests && ./Win32/Debug/ConsoleTestRunner.exe --run:"TestOtlSync1.TestLightweightMREWEx" 2>&1 | tail -8`
Expected: `Tests Found : 7 ... Tests Passed : 7`.

- [ ] **Step 2: Commit in two focused pieces**

```bash
cd /h/RAZVOJ/OmniThreadLibrary-NG
git add OtlCollections.pas
git commit -m "OtlCollections 3.01: work around dcc32 37.0 ICE (F2084 C3106) in InsertElement<T>

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git add OtlSync.pas unittests/TestOtlSync1.pas
git commit -m "TLightweightMREWEx 3.08: raise on read-inside-write, add class/method context to exceptions, extend tests

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

Expected: `git status --short` afterwards prints nothing.

---

### Task 1: Read-path recursion (nodes, nested reads, read-under-write grant, unmatched EndRead)

**Files:**
- Modify: `OtlSync.pas` — implementation section around `{ TLightweightMREWEx }` (~line 1730), record declaration (~line 512)
- Test: `unittests/TestOtlSync1.pas` — fixture `TestLightweightMREWEx`

**Interfaces:**
- Consumes: existing `TLightweightMREWEx` fields `FRWLock`, `FLockOwner` (via `GetLockOwner`), `FWriteLockCount`; existing raise-on-read-inside-write implementations (to be replaced).
- Produces: unit-private `PMREWReadNest`/`TMREWReadNest`, `threadvar GMREWReadNest`, functions `MREWReadNestFind(lock: pointer): PMREWReadNest`, `MREWReadNestPush(lock: pointer; osHeld: boolean)`, `MREWReadNestRemove(nest: PMREWReadNest)`. Task 2 calls `MREWReadNestFind`.

- [ ] **Step 1: Rewrite the two v3.08 raise-tests as grant-tests and add three new tests**

In the fixture declaration replace `TestReadInsideWriteRaises`/`TestTryReadInsideWriteRaises` and add three:

```pascal
  [TestFixture]
  TestLightweightMREWEx = class(TOtlTestBase)
  public
    [Test]
    procedure TestNestedWrite;
    [Test]
    procedure TestReadBlockedByWrite;
    [Test]
    procedure TestNestedTryWrite;
    [Test]
    procedure TestNestedWriteContention;
    [Test]
    procedure TestEndWriteNotOwnerRaises;
    [Test]
    procedure TestTryReadInsideWriteGranted;
    [Test]
    procedure TestReadInsideWriteGranted;
    [Test]
    procedure TestNestedReadDepth3;
    [Test]
    procedure TestEndReadWithoutBeginReadRaises;
    [Test]
    procedure TestRecursiveReadWithPendingWriter;
  end;
```

Delete the old `TestReadInsideWriteRaises` and `TestTryReadInsideWriteRaises` implementations and add:

```pascal
procedure TestLightweightMREWEx.TestReadInsideWriteGranted;
var
  entered: TOmniAlignedInt32;
  mrew   : ILightweightMREWEx;
begin
  mrew := TLightweightMREWExImpl.Create;
  entered.Value := 0;

  mrew.BeginWrite;
  mrew.BeginRead; // granted as nested: exclusive access implies read rights
  mrew.EndRead;
  mrew.EndWrite;

  Assert.IsTrue(
    System.Threading.TTask.Run(
      procedure
      begin
        if mrew.TryBeginWrite then begin
          entered.Value := 1;
          mrew.EndWrite;
        end;
      end).Wait(5000),
    'verification task completed');
  Assert.AreEqual<integer>(1, entered.Value, 'lock fully released after read-under-write');
end;

procedure TestLightweightMREWEx.TestTryReadInsideWriteGranted;
var
  entered: TOmniAlignedInt32;
  mrew   : ILightweightMREWEx;
begin
  mrew := TLightweightMREWExImpl.Create;
  entered.Value := 0;

  mrew.BeginWrite;
  Assert.IsTrue(mrew.TryBeginRead, 'TryBeginRead granted under owned write lock');
  mrew.EndRead;
  {$IF defined(LINUX) or defined(ANDROID)}
  Assert.IsTrue(mrew.TryBeginRead(0), 'TryBeginRead(timeout) granted under owned write lock');
  mrew.EndRead;
  {$ENDIF LINUX or ANDROID}
  mrew.EndWrite;

  Assert.IsTrue(
    System.Threading.TTask.Run(
      procedure
      begin
        if mrew.TryBeginWrite then begin
          entered.Value := 1;
          mrew.EndWrite;
        end;
      end).Wait(5000),
    'verification task completed');
  Assert.AreEqual<integer>(1, entered.Value, 'lock fully released after tryread-under-write');
end;

procedure TestLightweightMREWEx.TestNestedReadDepth3;
var
  mrew : ILightweightMREWEx;
  state: TOmniAlignedInt32;
  synch: IOmniSynchronizer<string>;
begin
  mrew := TLightweightMREWExImpl.Create;
  synch := TOmniSynchronizer<string>.Create;
  state.Value := 0;

  mrew.BeginRead;
  mrew.BeginRead;
  mrew.BeginRead;
  System.Threading.TTask.Run(
    procedure
    begin
      synch.Signal('started');
      state.Value := 1;
      mrew.BeginWrite;
      state.Value := 2;
      mrew.EndWrite;
      synch.Signal('done');
    end);

  synch.WaitFor('started');
  Sleep(200);
  Assert.AreEqual<integer>(1, state.Value, 'writer blocked at depth 3');
  mrew.EndRead;
  Sleep(200);
  Assert.AreEqual<integer>(1, state.Value, 'writer blocked at depth 2');
  mrew.EndRead;
  Sleep(200);
  Assert.AreEqual<integer>(1, state.Value, 'writer blocked at depth 1');
  mrew.EndRead;
  Assert.IsTrue(synch.WaitFor('done', 5000), 'writer acquired after last EndRead');
  Assert.AreEqual<integer>(2, state.Value, 'writer completed');
end;

procedure TestLightweightMREWEx.TestEndReadWithoutBeginReadRaises;
var
  mrew  : TLightweightMREWEx;
  raised: string;
begin
  raised := '<no exception>';
  try
    mrew.EndRead;
  except
    on E: Exception do
      raised := E.Message;
  end;
  Assert.IsTrue(Pos('TLightweightMREWEx.EndRead', raised) > 0,
    'unmatched EndRead raises with class/method context, got: ' + raised);
end;

procedure TestLightweightMREWEx.TestRecursiveReadWithPendingWriter;
var
  mrew : ILightweightMREWEx;
  state: TOmniAlignedInt32;
  synch: IOmniSynchronizer<string>;
begin
  mrew := TLightweightMREWExImpl.Create;
  synch := TOmniSynchronizer<string>.Create;
  state.Value := 0;

  mrew.BeginRead;
  System.Threading.TTask.Run(
    procedure
    begin
      synch.Signal('started');
      state.Value := 1;
      mrew.BeginWrite;
      state.Value := 2;
      mrew.EndWrite;
      synch.Signal('done');
    end);

  synch.WaitFor('started');
  Sleep(200); // let the writer become a pending exclusive waiter

  // Raw SRWLOCK deadlocks here: a nested shared acquire queues behind the
  // pending exclusive waiter. Recursion tracking must grant it immediately.
  mrew.BeginRead;
  Assert.AreEqual<integer>(1, state.Value, 'writer still blocked during nested read');
  mrew.EndRead;
  Sleep(200);
  Assert.AreEqual<integer>(1, state.Value, 'writer still blocked - outer read still held');
  mrew.EndRead;
  Assert.IsTrue(synch.WaitFor('done', 5000), 'writer acquired after last EndRead');
  Assert.AreEqual<integer>(2, state.Value, 'writer completed');
end;
```

- [ ] **Step 2: Build and verify RED**

Build Win32 (command in Global Constraints). Expected: compiles.

Run the non-hanging tests:
`./Win32/Debug/ConsoleTestRunner.exe --run:"TestOtlSync1.TestLightweightMREWEx.TestReadInsideWriteGranted,TestOtlSync1.TestLightweightMREWEx.TestTryReadInsideWriteGranted,TestOtlSync1.TestLightweightMREWEx.TestNestedReadDepth3,TestOtlSync1.TestLightweightMREWEx.TestEndReadWithoutBeginReadRaises" 2>&1 | tail -20`
Expected RED: `TestReadInsideWriteGranted` and `TestTryReadInsideWriteGranted` FAIL/ERROR (v3.08 raises on read-inside-write). `TestEndReadWithoutBeginReadRaises` FAILS (message mismatch or OS error; on Windows an unmatched `ReleaseSRWLockShared` may surface as an external exception or even crash the runner — any non-pass outcome counts as RED). `TestNestedReadDepth3` may PASS pre-change (SRW tolerates recursion when no writer is pending) — it is a regression guard for the new counting logic, not a RED test.

Run the deadlock test isolated:
`timeout 30 ./Win32/Debug/ConsoleTestRunner.exe --run:"TestOtlSync1.TestLightweightMREWEx.TestRecursiveReadWithPendingWriter" 2>&1 | tail -5`
Expected RED: output stops after `Executing Test :` and the process is killed at 30 s — the documented SRW deadlock.

- [ ] **Step 3: Implement the read path**

In `OtlSync.pas` implementation section, directly above `{ TLightweightMREWEx }` (~line 1710), add:

```pascal
type
  PMREWReadNest = ^TMREWReadNest;
  TMREWReadNest = record
    Lock  : pointer;       // @instance = lock identity
    Count : integer;       // nesting depth
    OSHeld: boolean;       // false when granted under an owned write lock
    Next  : PMREWReadNest;
  end;

threadvar
  GMREWReadNest: PMREWReadNest; // head of this thread's held-read-locks list

function MREWReadNestFind(lock: pointer): PMREWReadNest;
begin
  Result := GMREWReadNest;
  while assigned(Result) and (Result.Lock <> lock) do
    Result := Result.Next;
end; { MREWReadNestFind }

procedure MREWReadNestPush(lock: pointer; osHeld: boolean);
var
  nest: PMREWReadNest;
begin
  New(nest);
  nest.Lock := lock;
  nest.Count := 1;
  nest.OSHeld := osHeld;
  nest.Next := GMREWReadNest;
  GMREWReadNest := nest;
end; { MREWReadNestPush }

procedure MREWReadNestRemove(nest: PMREWReadNest);
var
  prev: PMREWReadNest;
begin
  if GMREWReadNest = nest then
    GMREWReadNest := nest.Next
  else begin
    prev := GMREWReadNest;
    while prev.Next <> nest do
      prev := prev.Next;
    prev.Next := nest.Next;
  end;
  Dispose(nest);
end; { MREWReadNestRemove }
```

Replace `BeginRead`, both `TryBeginRead` overloads, and `EndRead`:

```pascal
procedure TLightweightMREWEx.BeginRead;
var
  nest: PMREWReadNest;
begin
  nest := MREWReadNestFind(@Self);
  if assigned(nest) then
    // Nested read: never touches the OS lock, so it cannot queue behind a
    // pending writer (documented SRWLOCK deadlock).
    Inc(nest.Count)
  else if GetLockOwner = TThread.Current.ThreadID then
    // Read under owned write lock: exclusive access implies read rights.
    MREWReadNestPush(@Self, false)
  else begin
    FRWLock.BeginRead;
    MREWReadNestPush(@Self, true);
  end;
end; { TLightweightMREWEx.BeginRead }

function TLightweightMREWEx.TryBeginRead: boolean;
var
  nest: PMREWReadNest;
begin
  nest := MREWReadNestFind(@Self);
  if assigned(nest) then begin
    Inc(nest.Count);
    Exit(true);
  end;
  if GetLockOwner = TThread.Current.ThreadID then begin
    MREWReadNestPush(@Self, false);
    Exit(true);
  end;
  Result := FRWLock.TryBeginRead;
  if Result then
    MREWReadNestPush(@Self, true);
end; { TLightweightMREWEx.TryBeginRead }

{$IF defined(LINUX) or defined(ANDROID)}
function TLightweightMREWEx.TryBeginRead(timeout: cardinal): boolean;
var
  nest: PMREWReadNest;
begin
  nest := MREWReadNestFind(@Self);
  if assigned(nest) then begin
    Inc(nest.Count);
    Exit(true);
  end;
  if GetLockOwner = TThread.Current.ThreadID then begin
    MREWReadNestPush(@Self, false);
    Exit(true);
  end;
  Result := FRWLock.TryBeginRead(timeout);
  if Result then
    MREWReadNestPush(@Self, true);
end; { TLightweightMREWEx.TryBeginRead }
{$ENDIF LINUX or ANDROID}

procedure TLightweightMREWEx.EndRead;
var
  nest  : PMREWReadNest;
  osHeld: boolean;
begin
  nest := MREWReadNestFind(@Self);
  if not assigned(nest) then
    raise Exception.Create('TLightweightMREWEx.EndRead: Thread does not hold a read lock');
  Dec(nest.Count);
  if nest.Count = 0 then begin
    osHeld := nest.OSHeld;
    MREWReadNestRemove(nest);
    if osHeld then
      FRWLock.EndRead;
  end;
end; { TLightweightMREWEx.EndRead }
```

In the record declaration (~line 528) drop `inline;` from `EndRead` (it now contains a raise):

```pascal
    procedure EndRead;
```

- [ ] **Step 4: Build, verify GREEN, run whole fixture**

Build Win32, then:
`./Win32/Debug/ConsoleTestRunner.exe --run:"TestOtlSync1.TestLightweightMREWEx" 2>&1 | tail -10`
Expected: `Tests Found : 10 ... Tests Passed : 10` (no timeout needed — the deadlock test now completes in under a second).

- [ ] **Step 5: Commit**

```bash
git add OtlSync.pas unittests/TestOtlSync1.pas
git commit -m "TLightweightMREWEx: recursion-safe read locks via per-thread tracking

Nested BeginRead no longer touches the OS lock, so it cannot deadlock
behind a pending exclusive waiter (documented SRWLOCK hazard). Read
acquisition under an owned write lock is granted as a no-op nested
acquire (reverses the 3.08 raise). Unmatched EndRead raises.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Write-path guards (upgrade detection, EndWrite nested-read check)

**Files:**
- Modify: `OtlSync.pas` — `BeginWrite`, `TryBeginWrite` (both overloads), `EndWrite`
- Test: `unittests/TestOtlSync1.pas` — fixture `TestLightweightMREWEx`

**Interfaces:**
- Consumes: `MREWReadNestFind(lock: pointer): PMREWReadNest` from Task 1.
- Produces: final method behavior per spec; no new symbols.

- [ ] **Step 1: Add three tests**

Add to the fixture declaration:

```pascal
    [Test]
    procedure TestUpgradeTryBeginWriteRaises;
    [Test]
    procedure TestEndWriteWithNestedReadRaises;
    [Test]
    procedure TestUpgradeBeginWriteRaises;
```

Implementations:

```pascal
procedure TestLightweightMREWEx.TestUpgradeTryBeginWriteRaises;
var
  mrew  : TLightweightMREWEx;
  raised: string;
begin
  mrew.BeginRead;
  try
    raised := '<no exception>';
    try
      if mrew.TryBeginWrite then
        mrew.EndWrite;
    except
      on E: Exception do
        raised := E.Message;
    end;
    Assert.IsTrue(Pos('TLightweightMREWEx.TryBeginWrite', raised) > 0,
      'TryBeginWrite while holding a read lock raises, got: ' + raised);
    {$IF defined(LINUX) or defined(ANDROID)}
    raised := '<no exception>';
    try
      if mrew.TryBeginWrite(0) then
        mrew.EndWrite;
    except
      on E: Exception do
        raised := E.Message;
    end;
    Assert.IsTrue(Pos('TLightweightMREWEx.TryBeginWrite', raised) > 0,
      'TryBeginWrite(timeout) while holding a read lock raises, got: ' + raised);
    {$ENDIF LINUX or ANDROID}
  finally mrew.EndRead; end;
end;

procedure TestLightweightMREWEx.TestEndWriteWithNestedReadRaises;
var
  entered: TOmniAlignedInt32;
  mrew   : ILightweightMREWEx;
  raised : string;
begin
  mrew := TLightweightMREWExImpl.Create;
  entered.Value := 0;

  mrew.BeginWrite;
  mrew.BeginRead; // read-under-write (granted since Task 1)
  raised := '<no exception>';
  try
    mrew.EndWrite; // outermost write release with the nested read still held
  except
    on E: Exception do
      raised := E.Message;
  end;
  Assert.IsTrue(Pos('TLightweightMREWEx.EndWrite', raised) > 0,
    'EndWrite with outstanding nested read raises, got: ' + raised);

  // The raise must leave the lock intact: clean up in the correct order.
  mrew.EndRead;
  mrew.EndWrite;
  Assert.IsTrue(
    System.Threading.TTask.Run(
      procedure
      begin
        if mrew.TryBeginWrite then begin
          entered.Value := 1;
          mrew.EndWrite;
        end;
      end).Wait(5000),
    'verification task completed');
  Assert.AreEqual<integer>(1, entered.Value, 'lock fully released after correct-order cleanup');
end;

procedure TestLightweightMREWEx.TestUpgradeBeginWriteRaises;
var
  mrew  : TLightweightMREWEx;
  raised: string;
begin
  // Without upgrade detection this deadlocks on Windows (exclusive waits for
  // our own shared) - see TLightweightMREWEx.BeginWrite.
  mrew.BeginRead;
  try
    raised := '<no exception>';
    try
      mrew.BeginWrite;
      mrew.EndWrite;
    except
      on E: Exception do
        raised := E.Message;
    end;
    Assert.IsTrue(Pos('TLightweightMREWEx.BeginWrite', raised) > 0,
      'BeginWrite while holding a read lock raises, got: ' + raised);
  finally mrew.EndRead; end;
end;
```

- [ ] **Step 2: Build and verify RED**

Build Win32. Run the non-hanging tests:
`./Win32/Debug/ConsoleTestRunner.exe --run:"TestOtlSync1.TestLightweightMREWEx.TestUpgradeTryBeginWriteRaises,TestOtlSync1.TestLightweightMREWEx.TestEndWriteWithNestedReadRaises" 2>&1 | tail -14`
Expected RED: `TestUpgradeTryBeginWriteRaises` FAILS with `got: <no exception>` (Try returns False today). `TestEndWriteWithNestedReadRaises` FAILS with `got: <no exception>` (EndWrite releases despite the nested read today).

Run the deadlock-shaped test isolated:
`timeout 30 ./Win32/Debug/ConsoleTestRunner.exe --run:"TestOtlSync1.TestLightweightMREWEx.TestUpgradeBeginWriteRaises" 2>&1 | tail -5`
Expected RED: hang killed at 30 s (`BeginWrite` waits forever on our own shared lock).

- [ ] **Step 3: Implement the write-path guards**

Replace `BeginWrite`, both `TryBeginWrite` overloads, and `EndWrite`:

```pascal
procedure TLightweightMREWEx.BeginWrite;
begin
  if GetLockOwner = TThread.Current.ThreadID then
    // We are already an owner so no need for locking.
    // If another thread executes BeginWrite at this moment, it would enter
    // the 'else' part below and block in the call to FRWLock.BeginWrite.
    FWriteLockCount.Increment
  else if assigned(MREWReadNestFind(@Self)) then
    // Upgrade would deadlock on Windows and fail with EDEADLK on POSIX.
    raise Exception.Create('TLightweightMREWEx.BeginWrite: Read lock cannot be upgraded to a write lock')
  else begin
    FRWLock.BeginWrite;
    SetLockOwner(TThread.Current.ThreadID);
    FWriteLockCount.Value := 1;
  end;
end; { TLightweightMREWEx.BeginWrite }

function TLightweightMREWEx.TryBeginWrite: boolean;
begin
  if GetLockOwner = TThread.Current.ThreadID then begin
    FWriteLockCount.Increment;
    Result := true;
  end
  else if assigned(MREWReadNestFind(@Self)) then
    // Raise instead of returning False - an upgrade can never succeed, so
    // False would invite a retry loop that stalls forever.
    raise Exception.Create('TLightweightMREWEx.TryBeginWrite: Read lock cannot be upgraded to a write lock')
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
  else if assigned(MREWReadNestFind(@Self)) then
    raise Exception.Create('TLightweightMREWEx.TryBeginWrite: Read lock cannot be upgraded to a write lock')
  else begin
    Result := FRWLock.TryBeginWrite(timeout);
    if Result then begin
      SetLockOwner(TThread.Current.ThreadID);
      FWriteLockCount.Value := 1;
    end;
  end;
end; { TLightweightMREWEx.TryBeginWrite }
{$ENDIF LINUX or ANDROID}

procedure TLightweightMREWEx.EndWrite;
begin
  if GetLockOwner <> TThread.Current.ThreadID then
    raise Exception.Create('TLightweightMREWEx.EndWrite: Not an owner');

  if FWriteLockCount.Value <= 0 then
    raise Exception.Create('TLightweightMREWEx.EndWrite: Attempting to release write lock that was not acquired');
  if (FWriteLockCount.Value = 1) and assigned(MREWReadNestFind(@Self)) then
    // Only OSHeld=false nodes can exist here: a real (OSHeld=true) read lock
    // would have made BeginWrite raise the upgrade error instead of
    // acquiring. Checked before releasing, so the lock stays held.
    raise Exception.Create('TLightweightMREWEx.EndWrite: Releasing write lock while nested read locks are still held');
  if FWriteLockCount.Decrement = 0 then begin
    SetLockOwner(0);
    FRWLock.EndWrite;
  end;
end; { TLightweightMREWEx.EndWrite }
```

- [ ] **Step 4: Build, verify GREEN, run whole fixture**

Build Win32, then:
`./Win32/Debug/ConsoleTestRunner.exe --run:"TestOtlSync1.TestLightweightMREWEx" 2>&1 | tail -10`
Expected: `Tests Found : 13 ... Tests Passed : 13`.

- [ ] **Step 5: Commit**

```bash
git add OtlSync.pas unittests/TestOtlSync1.pas
git commit -m "TLightweightMREWEx: detect lock-upgrade attempts and unbalanced EndWrite

BeginWrite/TryBeginWrite while holding a read lock now raise (previously
a silent deadlock on Windows, EDEADLK on POSIX). EndWrite raises when a
read lock acquired under the write lock is still outstanding.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: XML documentation and version history

**Files:**
- Modify: `OtlSync.pas` — record declaration (~line 512), `ILightweightMREWEx`, `TLightweightMREWExImpl` declarations, unit header history

**Interfaces:**
- Consumes: final semantics from Tasks 1–2.
- Produces: documented public surface; version 3.09.

- [ ] **Step 1: Replace the record's doc comment and document every public method**

Replace the existing `///<summary>Extends TLightweightMREW...` block above `TLightweightMREWEx = record` with:

```pascal
  ///<summary>Reentrant multi-readers-exclusive-writer lock. Extends TLightweightMREW with:
  ///  nested (recursive) exclusive locks; nested (recursive) read locks that are safe
  ///  even when a writer is waiting (recursive shared acquisition of a raw SRWLOCK
  ///  deadlocks in that scenario); read acquisition while owning the write lock
  ///  (granted without touching the OS lock); and loud failure on misuse.</summary>
  ///<remarks><para>Usage errors raise Exception with a 'TLightweightMREWEx.Method: reason'
  ///  message: upgrading a read lock to a write lock via BeginWrite/TryBeginWrite,
  ///  EndRead without a matching BeginRead, EndWrite by a thread that does not own
  ///  the write lock, and EndWrite while a read lock acquired under the write lock
  ///  is still held.</para><para>
  ///  Instances must not be copied or moved in memory while any lock is held - the
  ///  lock's address is its identity.</para><para>
  ///  A thread must release all its locks before terminating; terminating while
  ///  holding a lock is undefined behavior (as with the underlying OS locks) and
  ///  leaks a small per-thread tracking node.</para></remarks>
```

Inside the record, document each public method:

```pascal
    ///<summary>Acquires the lock in shared (reader) mode; blocks until available.
    ///  Reentrant: nested calls on the same thread only increment a counter and are
    ///  safe even when a writer is waiting. Callable while owning the write lock
    ///  (granted immediately). Each call must be paired with EndRead.</summary>
    procedure BeginRead;
    ///<summary>Tries to acquire the lock in shared (reader) mode without blocking.
    ///  Nested calls and calls made while owning the write lock always succeed
    ///  immediately. Returns False only when another thread holds or waits for
    ///  the write lock.</summary>
    function  TryBeginRead: boolean; {$IF defined(LINUX) or defined(ANDROID)}overload;{$ENDIF}
    {$IF defined(LINUX) or defined(ANDROID)}
    ///<summary>Tries to acquire the lock in shared (reader) mode, waiting up to
    ///  timeout milliseconds. Nested calls and calls made while owning the write
    ///  lock always succeed immediately.</summary>
    function  TryBeginRead(timeout: cardinal): boolean; overload;
    {$ENDIF LINUX or ANDROID}
    ///<summary>Releases one level of shared (reader) lock. Raises if the calling
    ///  thread does not hold a read lock.</summary>
    procedure EndRead;
    ///<summary>Acquires the lock in exclusive (writer) mode; blocks until available.
    ///  Reentrant: the owning thread may call it again (counted). Raises if the
    ///  calling thread holds a read lock - upgrading is not possible.</summary>
    procedure BeginWrite;
    ///<summary>Tries to acquire the lock in exclusive (writer) mode without blocking.
    ///  Nested calls by the owner always succeed. Raises if the calling thread holds
    ///  a read lock - upgrading is not possible and could never succeed.</summary>
    function  TryBeginWrite: boolean; {$IF defined(LINUX) or defined(ANDROID)}overload;
    ///<summary>Tries to acquire the lock in exclusive (writer) mode, waiting up to
    ///  timeout milliseconds. Nested calls by the owner always succeed immediately.
    ///  Raises if the calling thread holds a read lock.</summary>
    function  TryBeginWrite(timeout: cardinal): boolean; overload;
    {$ENDIF LINUX or ANDROID}
    ///<summary>Releases one level of exclusive (writer) lock. Raises if the caller
    ///  is not the owner, or when releasing the outermost write lock while a read
    ///  lock acquired under it is still held.</summary>
    procedure EndWrite;
```

Placement note: the doc comment for `TryBeginWrite: boolean` sits before the declaration (outside the `{$IF}`), so it applies on all platforms; the timeout overload's comment sits inside the conditional block with its declaration. Mirror the exact placement shown above.

- [ ] **Step 2: Point the interface and impl class at the record docs**

Above `ILightweightMREWEx = interface`:

```pascal
  ///<summary>Interface wrapper for TLightweightMREWEx semantics - see
  ///  TLightweightMREWEx for full documentation of locking behavior.</summary>
```

Above `TLightweightMREWExImpl = class`:

```pascal
  ///<summary>Heap-allocated ILightweightMREWEx implementation delegating to an
  ///  embedded TLightweightMREWEx - see that record for behavior details.</summary>
```

- [ ] **Step 3: Update unit header to 3.09**

Change `Last modification` to `2026-07-24` and `Version` to `3.09`; add at the top of History:

```
///     3.09: 2026-07-24
///       - TLightweightMREWEx read locks are now reentrant and deadlock-safe:
///         per-thread tracking grants nested BeginRead/TryBeginRead without
///         touching the OS lock, so recursive shared acquisition can no longer
///         deadlock behind a pending writer (documented SRWLOCK hazard).
///       - BeginRead/TryBeginRead while owning the write lock is now granted
///         as a nested no-op acquire (3.08 raised here; with tracking the
///         grant is safe - exclusive access implies read rights).
///       - BeginWrite/TryBeginWrite while holding a read lock now raise
///         (upgrade is impossible; previously deadlocked on Windows).
///       - EndRead without a matching BeginRead raises.
///       - EndWrite releasing the outermost write lock while a read lock
///         acquired under it is still held raises.
///       - Full XML documentation on the TLightweightMREWEx public surface.
```

- [ ] **Step 4: Build and run fixture (docs must not change behavior)**

Build Win32; run fixture. Expected: `Tests Found : 13 ... Tests Passed : 13`.

- [ ] **Step 5: Commit**

```bash
git add OtlSync.pas
git commit -m "OtlSync 3.09: XML-document TLightweightMREWEx public surface

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Full verification matrix

**Files:**
- Modify: none (verification only; fixes go back through the relevant task's cycle)

**Interfaces:**
- Consumes: completed Tasks 1–3.
- Produces: green matrix evidence.

- [ ] **Step 1: Win32 + Win64 Delphi 13 full suites**

```bash
cd unittests
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcc32.exe" ConsoleTestRunner.dpr -B "-U..;../FastMM4" "-NSSystem;System.Win;Winapi;Vcl" -DDEBUG -E"./Win32/Debug" -NU"./Win32/Debug"
./Win32/Debug/ConsoleTestRunner.exe 2>&1 | tail -12
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcc64.exe" ConsoleTestRunner.dpr -B "-U..;../FastMM4" "-NSSystem;System.Win;Winapi;Vcl" -DDEBUG -E"./Win64/Debug" -NU"./Win64/Debug"
./Win64/Debug/ConsoleTestRunner.exe 2>&1 | tail -12
```

Expected: `Tests Failed : 0`, `Tests Errored : 0` on both (327/328 found respectively: baseline 321/322 plus 6 net-new tests).

- [ ] **Step 2: Linux64 build + WSL run**

```bash
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcclinux64.exe" ConsoleTestRunner.dpr -B "-U..;../FastMM4" "-NSSystem;Data;Xml" -DDEBUG -CC -E"./Linux64/Debug" -NU"./Linux64/Debug" --syslibroot:"C:/Users/gabr/Documents/Embarcadero/Studio/SDKs/ubuntu24.04.sdk" --libpath:"C:/Users/gabr/Documents/Embarcadero/Studio/SDKs/ubuntu24.04.sdk/usr/lib/x86_64-linux-gnu;C:/Users/gabr/Documents/Embarcadero/Studio/SDKs/ubuntu24.04.sdk/lib/x86_64-linux-gnu;C:/Users/gabr/Documents/Embarcadero/Studio/SDKs/ubuntu24.04.sdk/usr/lib/gcc/x86_64-linux-gnu/13;C:/Program Files (x86)/Embarcadero/Studio/37.0/lib/linux64/debug;C:/Program Files (x86)/Embarcadero/Studio/37.0/lib/linux64/release"
cp ./Linux64/Debug/ConsoleTestRunner /c/Temp/CTR
MSYS_NO_PATHCONV=1 WSLENV= wsl -- /mnt/c/Temp/CTR 2>&1 | tail -14
```

Expected: `Tests Failed : 0`, `Tests Errored : 0`, 3 known POSIX ignores.

- [ ] **Step 3: Delphi 12 and Delphi 11 Win32 builds + runs**

```bash
"e:\Delphi\23.0\bin\dcc32.exe" ConsoleTestRunner -b "-u..;../../fastmm4;x:/common/testinsight" -i.. "-nsSystem;System.Win;Winapi;Vcl;Vcl.Imaging;Vcl.Samples;Data;Xml"
./ConsoleTestRunner.exe 2>&1 | tail -8
"e:\Delphi\22.0\bin\dcc32.exe" ConsoleTestRunner -b "-u..;../../fastmm4;x:/common/testinsight" -i.. "-nsSystem;System.Win;Winapi;Vcl;Vcl.Imaging;Vcl.Samples;Data;Xml"
./ConsoleTestRunner.exe 2>&1 | tail -8
```

Expected: `Tests Failed : 0`, `Tests Errored : 0` on both. (ARM64EC skipped — `dccarm64ec.exe` missing since the 2026-05-08 Studio patch. Android on request only.)

- [ ] **Step 4: Repeat-run the new fixture for flake detection**

```bash
for i in 1 2 3 4 5; do ./Win32/Debug/ConsoleTestRunner.exe --run:"TestOtlSync1.TestLightweightMREWEx" 2>&1 | grep "Tests Passed"; done
```

Expected: `Tests Passed : 13` five times (the tests use Sleep-based writer-pending windows; repeat runs guard against timing flakes).

- [ ] **Step 5: Final commit check**

Run: `git status --short`
Expected: empty (everything committed in Tasks 0–3). If anything is dirty, it belongs to a task — go back through that task's cycle.
