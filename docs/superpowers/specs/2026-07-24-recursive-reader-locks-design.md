# Recursive reader locks for TLightweightMREWEx

**Date:** 2026-07-24
**Target:** `OtlSync.pas` v3.09, `TLightweightMREWEx` (+ `ILightweightMREWEx` / `TLightweightMREWExImpl`, which delegate unchanged)
**Status:** Approved

## Problem

Microsoft's SRWLOCK documentation forbids recursive shared acquisition: if thread
T1 holds a shared lock and thread T2 queues an exclusive request, T1's *nested*
shared acquisition parks behind T2's writer — T1 waits on T2, T2 waits on T1,
deadlock. The RTL's `TLightweightMREW` doc comment claims recursive shared
acquisition is safe; on Windows it is not. On POSIX it is safe only under
glibc's default reader-preference — a non-portable accident, not a guarantee
(writer-preference attributes and bionic differ).

`TLightweightMREWEx` already tracks the write-lock owner for nested exclusive
locks. This design extends it with per-thread tracking of *shared* holdings so
that nested read locks never touch the OS lock, eliminating the deadlock on
every platform.

## Approach (chosen: thread-local held-locks list)

Unit-private, shared by all lock instances:

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
  GMREWReadNest: PMREWReadNest;  // head of this thread's held-read-locks list
```

Only the owning thread touches its own list: zero synchronization, no memory
barriers, works for foreign threads. A node is allocated (heap) on the
outermost `BeginRead` and disposed on the outermost `EndRead`; list length =
number of distinct MREWEx locks the thread currently read-holds (typically
0–2), so lookup is a trivial scan.

Rejected alternatives: per-instance ThreadID→count table under a spinlock
(serializes all readers on one atomic — defeats the point of a MREW lock);
detect-only raising on nested reads (drops the recursive-read feature that RTL
documentation advertises and migrating code may rely on).

## Semantics

First matching row wins:

| Operation | Thread state | Action |
|---|---|---|
| BeginRead / TryBeginRead(±timeout) | has node for this lock | `Count++`, succeed; never touches the OS lock, so it cannot queue behind a pending writer |
| | owns write lock | push node `Count=1, OSHeld=false`, succeed (exclusive access implies read rights) |
| | neither | OS acquire (or try-acquire); on success push node `Count=1, OSHeld=true`; Try* failure pushes nothing |
| EndRead | no node | raise (unmatched EndRead; previously silent UB) |
| | `--Count > 0` | done |
| | `Count = 0` | pop + dispose node; call OS `EndRead` only if `OSHeld` |
| BeginWrite / TryBeginWrite(±timeout) | owns write lock | `FWriteLockCount++` (unchanged v3.08 behavior) |
| | has read node | raise (upgrade attempt; previously an undetectable deadlock on Windows / EDEADLK on POSIX). Try* variants also raise — returning False would invite a retry loop that can never succeed |
| | neither | OS acquire, set owner, count := 1 (unchanged) |
| EndWrite | non-owner | raise (unchanged) |
| | releasing outermost write while a read-under-write node remains | raise (`BeginRead` under write without matching `EndRead`); checked before the OS release, so the lock stays held |

Invariant: an `OSHeld=true` node can never coexist with write ownership on the
same thread, because `BeginWrite` raises the upgrade error first. Therefore the
`EndWrite` outstanding-read check can only ever see `OSHeld=false` nodes.

### Change vs v3.08

`BeginRead`/`TryBeginRead` while owning the write lock previously raised
(v3.08's stand-in for an undetectable deadlock). With tracking, the grant is
safe and friendlier to layered code (a write-locked method calling a
read-locked helper), so it now succeeds as a no-op nested acquire. The two
v3.08 raise-tests are rewritten as grant-tests.

### Amendment (v3.10, 2026-07-24): grant is opt-in

Post-implementation reconsideration: programmers migrating from strict
`TLightweightMREW` semantics never intentionally acquire a read lock while
holding the write lock (it used to deadlock), so a silent grant primarily
hides programming mistakes. Final policy:

- **Default:** `BeginRead`/`TryBeginRead` while owning the write lock raise
  (`'...: Thread owns the write lock (set AllowReadInsideWrite to permit
  this)'`).
- **Opt-in:** `property AllowReadInsideWrite: boolean` on the record and on
  `ILightweightMREWEx` enables the grant for layered code that wants it.
- **Safety:** the flag must be set before the lock's first acquisition; the
  setter raises afterwards (`FAccessed` flag set by every acquire path, same
  pattern as `TOmniBlockingCollection.SetThrottling`). This keeps the
  unsynchronized flag reads on the acquire paths safe: the flag is immutable
  once concurrency starts.
- Strict-by-default also preserves the compatibility asymmetry: relaxing
  later is non-breaking, restricting later would not be.

## Error handling

All usage errors raise `Exception` with `TLightweightMREWEx.<Method>: ...`
messages (house style). After this change no misuse of the class deadlocks
detectably: nested reads succeed, upgrades raise, unmatched releases raise.

## Lifecycle and constraints

- Lock identity is `@Self`: an instance must not be copied or relocated while
  any lock is held (already inherent to wrapping an OS lock; documented on the
  record).
- A thread exiting while holding a read lock is a usage bug; its node leaks —
  the same bug class as exiting while holding an SRWLOCK.
- No `Finalize` operator needed; nodes are owned by threads, not instances.
- Platform scope: uniform on Windows and POSIX, for identical semantics and
  upgrade detection everywhere.

## Documentation

Full XML-doc pass over the public surface so users can discover the new
semantics without reading the implementation:

- `TLightweightMREWEx` record: `<summary>` describing the capability set
  (nested exclusive locks, recursive/nested read locks safe against pending
  writers, read-under-write granted, upgrade attempts raise) and `<remarks>`
  covering the no-copy/no-relocate constraint and the thread-exit caveat.
- Every public method (`BeginRead`, `TryBeginRead` overloads, `EndRead`,
  `BeginWrite`, `TryBeginWrite` overloads, `EndWrite`): `<summary>` of
  behavior, including what happens on nested/recursive calls and which usage
  errors raise, mirroring the RTL's style on `TLightweightMREW` so the
  differences from the raw RTL type are obvious side by side.
- `ILightweightMREWEx` and `TLightweightMREWExImpl` reference the record's
  documentation rather than duplicating it.

## Testing (TDD)

New tests (RED first; deadlock-shaped REDs observed via external timeout):

1. Recursive read with pending writer — T1 `BeginRead`; T2 `BeginWrite`
   (blocks); T1 nested `BeginRead` must succeed; after both `EndRead`s T2
   acquires. This is the exact documented SRW deadlock.
2. Read under write granted (rewrite of v3.08 `TestReadInsideWriteRaises`).
3. TryRead under write granted, both overloads (rewrite of
   `TestTryReadInsideWriteRaises`).
4. Upgrade raises: `BeginWrite` and `TryBeginWrite` (both overloads) while
   holding a read lock.
5. Unmatched `EndRead` raises.
6. `EndWrite` with an outstanding read-under-write node raises.
7. Three-deep read nesting: writer admitted only after the last `EndRead`.

All other v3.08 tests stay green unchanged. Verification matrix: Win32/Win64
Delphi 13, Linux64 (WSL), Delphi 11/12 Win32. ARM64EC blocked (compiler
missing since the 2026-05-08 patch); Android on request.
